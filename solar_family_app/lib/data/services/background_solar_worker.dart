import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../domain/models/battery_alert_mode.dart';
import '../../domain/models/solar_reading.dart';
import 'mqtt_solar_service.dart';
import 'notification_alert_service.dart';

/// Dispatcher de WorkManager en aislado nativo de Android.
/// Vigila la batería periódicamente aunque la app esté cerrada, conectándose
/// 1–2 segundos para leer el último estado y desconectándose de inmediato.
@pragma('vm:entry-point')
void solarBackgroundDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    final isTest = taskName == BackgroundSolarMonitor.testTaskName;
    return BackgroundSolarMonitor.runPeriodicCheck(isManualTest: isTest);
  });
}

class BackgroundSolarMonitor {
  static const String uniqueTaskName = 'solar_periodic_battery_check';
  static const String taskName = 'solarBatteryCheckTask';
  static const String testUniqueName = 'solar_bg_self_test';
  static const String testTaskName = 'solarBatteryTestTask';

  static const String prefBgLastAlertMs = 'bg_last_critical_alert_ms';
  static const String prefBgLastCheckMs = 'bg_last_check_ms';
  static const String prefBgLastCheckStatus = 'bg_last_check_status';

  static const MethodChannel _batteryOptChannel =
      MethodChannel('com.hogar.solar_family_monitor/battery_opt');

  static Future<void> initializeAndSchedule() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().initialize(solarBackgroundDispatcher);
      await Workmanager().registerPeriodicTask(
        uniqueTaskName,
        taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('No se pudo programar WorkManager en segundo plano: $e');
    }
  }

  /// Programa una prueba única en 5 segundos para verificar notificaciones
  /// reales en segundo plano con la app cerrada.
  static Future<bool> scheduleBackgroundTestIn5Seconds() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      await Workmanager().registerOneOffTask(
        testUniqueName,
        testTaskName,
        initialDelay: const Duration(seconds: 5),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
      return true;
    } catch (e) {
      debugPrint('Error programando prueba en segundo plano: $e');
      return false;
    }
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final result = await _batteryOptChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final result = await _batteryOptChannel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Determina si una lectura recibida en segundo plano debe disparar alerta.
  /// Evita falsas alarmas por mensajes retenidos antiguos si el servidor estuvo apagado.
  static bool shouldTriggerBackgroundAlert({
    required SolarReading reading,
    required double threshold,
    required int nowMs,
    int? lastAlertEpochMs,
    Duration maxReadingAge = const Duration(minutes: 25),
    Duration cooldown = const Duration(minutes: 12),
  }) {
    final ageMs = (nowMs - reading.epochMs).abs();
    if (ageMs > maxReadingAge.inMilliseconds) {
      return false;
    }
    if (!reading.shouldTriggerLowBatteryAlert(threshold: threshold)) {
      return false;
    }
    if (lastAlertEpochMs != null &&
        (nowMs - lastAlertEpochMs) < cooldown.inMilliseconds) {
      return false;
    }
    return true;
  }

  static Future<bool> runPeriodicCheck({bool isManualTest = false}) async {
    SharedPreferences? prefs;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    try {
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final notificationService = NotificationAndAlertService();
      // IMPORTANTE: requestPermissions=false porque en WorkManager NO hay Activity
      await notificationService.initialize(requestPermissions: false);

      final threshold = prefs.getDouble('critical_soc_threshold') ?? 30.0;
      final alertMode =
          BatteryAlertMode.fromCode(prefs.getString('battery_alert_mode'));
      final tgToken = (prefs.getString('telegram_bot_token') ?? '').trim();
      final tgChat = (prefs.getString('telegram_chat_id') ?? '').trim();

      if (isManualTest) {
        final simulatedReading = SolarReading(
          timestamp: DateTime.now(),
          epochMs: nowMs,
          batteryVoltage: 46.5,
          batterySoc: (threshold - 4.0).clamp(1.0, 99.0),
          pvPowerW: 0.0,
          batteryPowerW: -850.0,
          batteryChargeW: 0.0,
          batteryDischargeW: 850.0,
          loadPowerW: 850.0,
          status: SolarSystemStatus.discharging,
          isCritical: true,
          sourceMode: 'TEST_BG',
        );
        await _saveBgStatus(
          prefs,
          nowMs,
          'Prueba 2.º plano OK (${alertMode.displayName})',
        );
        await notificationService.triggerCriticalBatteryAlert(
          reading: simulatedReading,
          threshold: threshold,
          alertMode: alertMode,
          telegramBotToken: tgToken,
          telegramChatId: tgChat,
          force: true,
          requestPermissions: false,
          startLoopingRingtone: false,
          backgroundRingDuration: alertMode == BatteryAlertMode.immediateAlarm
              ? const Duration(seconds: 8)
              : null,
        );
        return true;
      }

      final demoMode = prefs.getBool('demo_mode_enabled') ?? false;
      if (demoMode) {
        await _saveBgStatus(prefs, nowMs, 'Modo Demo activo (omitido)');
        return true;
      }

      final localHost =
          (prefs.getString('mqtt_broker_host') ?? '192.168.0.224').trim();
      final localPort = prefs.getInt('mqtt_broker_port') ?? 1883;
      final cloudHost = (prefs.getString('cloud_mqtt_host') ?? '').trim();
      final cloudPort = prefs.getInt('cloud_mqtt_port') ?? 8883;
      final cloudUser = (prefs.getString('cloud_mqtt_user') ?? '').trim();
      final cloudPass = prefs.getString('cloud_mqtt_pass') ?? '';
      final cloudTls = prefs.getBool('cloud_mqtt_tls') ?? true;

      final reading = await _fetchLatestReadingOnce(
        localHost: localHost,
        localPort: localPort,
        cloudHost: cloudHost,
        cloudPort: cloudPort,
        cloudUser: cloudUser,
        cloudPass: cloudPass,
        cloudTls: cloudTls,
      );
      if (reading == null) {
        await _saveBgStatus(prefs, nowMs, 'Sin respuesta MQTT en 2.º plano');
        return true;
      }

      final ageMs = (nowMs - reading.epochMs).abs();
      if (ageMs > const Duration(minutes: 25).inMilliseconds) {
        await _saveBgStatus(
          prefs,
          nowMs,
          'Dato antiguo (${ageMs ~/ 60000}m) • Servidor Mac offline',
        );
        return true;
      }

      await notificationService.updatePersistentNotification(
        reading,
        threshold: threshold,
        requestPermissions: false,
      );

      // Si la carga de la casa se desconectó (red pública), está cargando neto
      // o ya superó el umbral: silenciar alerta previa y limpiar cooldown.
      if (!reading.shouldTriggerLowBatteryAlert(threshold: threshold)) {
        await prefs.remove(prefBgLastAlertMs);
        await notificationService.stopCriticalAlarmSound();
        final reason = reading.loadPowerW <= 15.0
            ? 'En red pública (sin carga) • ${reading.batterySoc.toStringAsFixed(1)}%'
            : 'OK • Batería ${reading.batterySoc.toStringAsFixed(1)}%';
        await _saveBgStatus(prefs, nowMs, reason);
        return true;
      }

      final lastAlertMs = prefs.getInt(prefBgLastAlertMs);
      if (shouldTriggerBackgroundAlert(
        reading: reading,
        threshold: threshold,
        nowMs: nowMs,
        lastAlertEpochMs: lastAlertMs,
      )) {
        await prefs.setInt(prefBgLastAlertMs, nowMs);
        await _saveBgStatus(
          prefs,
          nowMs,
          '🚨 Alerta enviada (${reading.batterySoc.toStringAsFixed(1)}%)',
        );
        await notificationService.triggerCriticalBatteryAlert(
          reading: reading,
          threshold: threshold,
          alertMode: alertMode,
          telegramBotToken: tgToken,
          telegramChatId: tgChat,
          force: true,
          requestPermissions: false,
          startLoopingRingtone: false,
          backgroundRingDuration: alertMode == BatteryAlertMode.immediateAlarm
              ? const Duration(seconds: 12)
              : null,
        );
      } else {
        await _saveBgStatus(
          prefs,
          nowMs,
          'En cooldown • Batería ${reading.batterySoc.toStringAsFixed(1)}%',
        );
      }
      return true;
    } catch (e) {
      if (prefs != null) {
        await _saveBgStatus(prefs, nowMs, 'Error 2.º plano: $e');
      }
      debugPrint('Error en chequeo periódico WorkManager: $e');
      return true;
    }
  }

  static Future<void> _saveBgStatus(
    SharedPreferences prefs,
    int nowMs,
    String status,
  ) async {
    await prefs.setInt(prefBgLastCheckMs, nowMs);
    await prefs.setString(prefBgLastCheckStatus, status);
  }

  static Future<SolarReading?> _fetchLatestReadingOnce({
    required String localHost,
    required int localPort,
    required String cloudHost,
    required int cloudPort,
    required String cloudUser,
    required String cloudPass,
    required bool cloudTls,
  }) async {
    final hasCloud = cloudHost.isNotEmpty;
    if (localHost.isNotEmpty) {
      final reading = await _probeAndReadOnce(
        host: localHost,
        port: localPort,
        useTls: false,
        username: '',
        password: '',
        tcpTimeout: Duration(milliseconds: hasCloud ? 700 : 1800),
      );
      if (reading != null) return reading;
    }
    if (hasCloud) {
      return _probeAndReadOnce(
        host: cloudHost,
        port: cloudPort,
        useTls: cloudTls,
        username: cloudUser,
        password: cloudPass,
        tcpTimeout: const Duration(milliseconds: 2800),
      );
    }
    return null;
  }

  static Future<SolarReading?> _probeAndReadOnce({
    required String host,
    required int port,
    required bool useTls,
    required String username,
    required String password,
    required Duration tcpTimeout,
  }) async {
    try {
      final sock = await Socket.connect(host, port, timeout: tcpTimeout);
      await sock.close();
    } catch (_) {
      return null;
    }

    final clientId =
        'solar_bg_${Random().nextInt(999999).toString().padLeft(6, '0')}';
    final client = MqttServerClient.withPort(host, clientId, port);
    client.logging(on: false);
    client.keepAlivePeriod = 10;
    client.connectTimeoutPeriod = 3500;
    client.autoReconnect = false;
    if (useTls) {
      client.secure = true;
      client.securityContext = SecurityContext.defaultContext;
    }
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);

    StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>?>? sub;
    try {
      await client.connect(
        username.isEmpty ? null : username,
        password.isEmpty ? null : password,
      );
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        return null;
      }

      final completer = Completer<SolarReading?>();
      sub = client.updates?.listen((events) {
        if (completer.isCompleted) return;
        for (final event in events) {
          if (event.topic != MqttSolarService.topicTelemetry) continue;
          final msg = event.payload as MqttPublishMessage?;
          if (msg == null) continue;
          final raw =
              MqttPublishPayload.bytesToStringAsString(msg.payload.message);
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            completer.complete(SolarReading.fromJson(map));
            return;
          } catch (_) {}
        }
      });

      client.subscribe(MqttSolarService.topicTelemetry, MqttQos.atMostOnce);

      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      try {
        client.disconnect();
      } catch (_) {}
    }
  }
}
