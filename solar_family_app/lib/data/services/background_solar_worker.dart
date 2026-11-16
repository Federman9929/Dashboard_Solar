import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../domain/models/battery_alert_mode.dart';
import '../../domain/models/solar_reading.dart';
import 'mqtt_solar_service.dart';
import 'notification_alert_service.dart';

/// Dispatcher de WorkManager en aislado nativo de Android.
/// Permite vigilar el nivel de batería cada ~15 minutos aunque la app esté cerrada,
/// conectándose 1–2 segundos para leer el último dato y cerrándose inmediatamente.
@pragma('vm:entry-point')
void solarBackgroundDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    return BackgroundSolarMonitor.runPeriodicCheck();
  });
}

class BackgroundSolarMonitor {
  static const String uniqueTaskName = 'solar_periodic_battery_check';
  static const String taskName = 'solarBatteryCheckTask';
  static const String prefBgLastAlertMs = 'bg_last_critical_alert_ms';

  static Future<void> initializeAndSchedule() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().initialize(solarBackgroundDispatcher);
      await Workmanager().registerPeriodicTask(
        uniqueTaskName,
        taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    } catch (e) {
      debugPrint('No se pudo programar WorkManager en segundo plano: $e');
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
    if (reading.batterySoc >= threshold) {
      return false;
    }
    if (lastAlertEpochMs != null &&
        (nowMs - lastAlertEpochMs) < cooldown.inMilliseconds) {
      return false;
    }
    return true;
  }

  static Future<bool> runPeriodicCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final demoMode = prefs.getBool('demo_mode_enabled') ?? false;
      if (demoMode) return true;

      final localHost = (prefs.getString('mqtt_broker_host') ?? '192.168.0.224').trim();
      final localPort = prefs.getInt('mqtt_broker_port') ?? 1883;
      final cloudHost = (prefs.getString('cloud_mqtt_host') ?? '').trim();
      final cloudPort = prefs.getInt('cloud_mqtt_port') ?? 8883;
      final cloudUser = (prefs.getString('cloud_mqtt_user') ?? '').trim();
      final cloudPass = prefs.getString('cloud_mqtt_pass') ?? '';
      final cloudTls = prefs.getBool('cloud_mqtt_tls') ?? true;

      final threshold = prefs.getDouble('critical_soc_threshold') ?? 30.0;
      final alertMode =
          BatteryAlertMode.fromCode(prefs.getString('battery_alert_mode'));
      final tgToken = (prefs.getString('telegram_bot_token') ?? '').trim();
      final tgChat = (prefs.getString('telegram_chat_id') ?? '').trim();

      final reading = await _fetchLatestReadingOnce(
        localHost: localHost,
        localPort: localPort,
        cloudHost: cloudHost,
        cloudPort: cloudPort,
        cloudUser: cloudUser,
        cloudPass: cloudPass,
        cloudTls: cloudTls,
      );
      if (reading == null) return true;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final ageMs = (nowMs - reading.epochMs).abs();
      if (ageMs > const Duration(minutes: 25).inMilliseconds) {
        return true;
      }

      final notificationService = NotificationAndAlertService();
      await notificationService.initialize();
      await notificationService.updatePersistentNotification(
        reading,
        threshold: threshold,
      );

      // Si la batería se recuperó (+2% histéresis), limpiar cooldown guardado
      if (reading.batterySoc >= threshold + 2.0) {
        await prefs.remove(prefBgLastAlertMs);
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
        await notificationService.triggerCriticalBatteryAlert(
          reading: reading,
          threshold: threshold,
          alertMode: alertMode,
          telegramBotToken: tgToken,
          telegramChatId: tgChat,
          force: true,
          startLoopingRingtone: false,
        );
      }
      return true;
    } catch (e) {
      debugPrint('Error en chequeo periódico WorkManager: $e');
      return true;
    }
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
