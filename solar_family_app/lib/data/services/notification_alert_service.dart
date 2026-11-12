import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/battery_alert_mode.dart';
import '../../domain/models/solar_reading.dart';

/// Gestiona:
/// 1. La Notificación Permanente (Foreground / Ongoing) en la barra de estado
///    con el porcentaje de batería, estado actual y círculo de color (🟢/🔴).
/// 2. Las Alertas de Umbral de Batería Baja según el modo seleccionado por el usuario:
///    - [BatteryAlertMode.simpleNotification]: Notificación al celular sencilla pero
///      notoria (sonido de aviso + vibración distintiva sin bucle).
///    - [BatteryAlertMode.immediateAlarm]: Alarma sonora continua inmediata con sirena
///      audible tipo llamada/despertador hasta que el usuario la silencie.
class NotificationAndAlertService {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final FlutterRingtonePlayer _ringtonePlayer = FlutterRingtonePlayer();

  static const int _ongoingNotificationId = 1001;
  static const int _criticalAlertNotificationId = 9999;

  static const String _ongoingChannelId = 'solar_ongoing_status_channel';
  static const String _simpleNoticeChannelId = 'solar_battery_notice_channel_v2';
  static const String _immediateAlarmChannelId = 'solar_battery_alarm_channel_v2';

  bool _isInitialized = false;
  bool _isRinging = false;
  DateTime? _lastOngoingUpdate;
  bool? _lastOngoingIsGreen;
  DateTime? _lastCriticalTrigger;

  bool get isRinging => _isRinging;

  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Al tocar la notificación de alerta en la barra de estado, silenciar de inmediato
        stopCriticalAlarmSound();
      },
    );

    // Solicitar permisos en Android 13+
    final androidImplementation =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();

    _isInitialized = true;
  }

  /// Actualiza la Notificación Permanente (Ongoing) en la barra de estado.
  /// Incluye círculo verde (🟢) si está cargando/saludable, o rojo (🔴) si
  /// está descargando o con batería baja según el umbral configurado.
  Future<void> updatePersistentNotification(
    SolarReading reading, {
    double threshold = 30.0,
  }) async {
    if (!_isInitialized) await initialize();

    final isGreen = reading.isHealthyForThreshold(threshold);
    final now = DateTime.now();
    // Evitar saturar el canal nativo de Android actualizando la notificación del sistema
    // máximo cada 15 segundos o cuando cambia el semáforo.
    if (_lastOngoingUpdate != null &&
        _lastOngoingIsGreen == isGreen &&
        now.difference(_lastOngoingUpdate!).inSeconds < 15) {
      return;
    }
    _lastOngoingUpdate = now;
    _lastOngoingIsGreen = isGreen;

    final circleIndicator = reading.statusEmojiForThreshold(threshold); // 🟢 o 🔴
    final indicatorColor =
        isGreen ? const Color(0xFF00E676) : const Color(0xFFFF1744);

    final powerDetail = reading.status == SolarSystemStatus.charging
        ? '+${reading.batteryChargeW.toStringAsFixed(0)} W'
        : reading.status == SolarSystemStatus.discharging
            ? '-${reading.batteryDischargeW.toStringAsFixed(0)} W'
            : '0 W';

    final title =
        '$circleIndicator Batería: ${reading.batterySoc.toStringAsFixed(1)}% • ${reading.status.displayName}';
    final body =
        'Paneles: ${reading.pvPowerW.toStringAsFixed(0)} W  |  Bat: $powerDetail (${reading.batteryVoltage.toStringAsFixed(1)}V)';

    final androidDetails = AndroidNotificationDetails(
      _ongoingChannelId,
      'Estado Solar Permanente',
      channelDescription:
          'Muestra permanentemente el nivel de batería y estado del sistema solar',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showWhen: true,
      when: reading.epochMs,
      color: indicatorColor,
      colorized: true,
      category: AndroidNotificationCategory.service,
      visibility: NotificationVisibility.public,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    await _notificationsPlugin.show(
      _ongoingNotificationId,
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }

  /// Dispara la alerta de batería baja según la preferencia del usuario:
  /// - Notificación Sencilla pero Notoria: aviso sonoro + vibración del sistema sin bucle.
  /// - Alarma Inmediata: timbre continuo de alarma que alerta al instante hasta silenciar.
  Future<void> triggerCriticalBatteryAlert({
    required SolarReading reading,
    double threshold = 30.0,
    BatteryAlertMode alertMode = BatteryAlertMode.simpleNotification,
    String? telegramBotToken,
    String? telegramChatId,
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    final now = DateTime.now();
    // Cooldown de 3 minutos para no saturar notificaciones repetidas, salvo prueba manual
    if (!force &&
        _lastCriticalTrigger != null &&
        now.difference(_lastCriticalTrigger!).inMinutes < 3) {
      return;
    }
    _lastCriticalTrigger = now;

    if (alertMode == BatteryAlertMode.immediateAlarm) {
      // 1. Iniciar timbre de alarma continua en bucle
      _startCriticalAlarmSound();

      // 2. Notificación de alta prioridad tipo alarma
      final vibrationPattern =
          Int64List.fromList([0, 800, 400, 800, 400, 1200]);
      final androidDetails = AndroidNotificationDetails(
        _immediateAlarmChannelId,
        'Alarma Inmediata de Batería',
        channelDescription:
            'Alarma sonora continua urgente cuando la batería baja del umbral',
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: true,
        vibrationPattern: vibrationPattern,
        color: const Color(0xFFFF1744),
        colorized: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      );

      await _notificationsPlugin.show(
        _criticalAlertNotificationId,
        '🚨 ¡ALARMA DE BATERÍA AL ${reading.batterySoc.toStringAsFixed(1)}%!',
        'Batería bajo el umbral (${threshold.toStringAsFixed(0)}%). Descargando ${reading.batteryDischargeW.toStringAsFixed(0)}W (${reading.batteryVoltage.toStringAsFixed(1)}V). Toca para silenciar.',
        NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
    } else {
      // Modo Notificación Sencilla pero Notoria:
      // Tono de aviso del sistema + vibración marcada (sin sirena continua)
      _playNoticeSound();

      final vibrationPattern = Int64List.fromList([0, 450, 200, 450]);
      final androidDetails = AndroidNotificationDetails(
        _simpleNoticeChannelId,
        'Avisos de Batería',
        channelDescription:
            'Notificación notoria cuando la batería baja del umbral configurado',
        importance: Importance.high,
        priority: Priority.high,
        fullScreenIntent: false,
        ongoing: false,
        autoCancel: true,
        onlyAlertOnce: false,
        vibrationPattern: vibrationPattern,
        color: const Color(0xFFFFB300),
        visibility: NotificationVisibility.public,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      );

      await _notificationsPlugin.show(
        _criticalAlertNotificationId,
        '⚠️ Batería en ${reading.batterySoc.toStringAsFixed(1)}% (Umbral: ${threshold.toStringAsFixed(0)}%)',
        'Nivel por debajo de ${threshold.toStringAsFixed(0)}%. Voltaje: ${reading.batteryVoltage.toStringAsFixed(1)}V • Consumo: ${reading.loadPowerW.toStringAsFixed(0)}W.',
        NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
    }

    // Si el usuario configuró Telegram, enviar alerta
    if (telegramBotToken != null &&
        telegramBotToken.isNotEmpty &&
        telegramChatId != null &&
        telegramChatId.isNotEmpty) {
      await _sendDirectTelegramAlert(
        botToken: telegramBotToken,
        chatId: telegramChatId,
        reading: reading,
        threshold: threshold,
        alertMode: alertMode,
      );
    }
  }

  void _startCriticalAlarmSound() {
    try {
      _isRinging = true;
      _ringtonePlayer.playAlarm(
        volume: 1.0,
        looping: true,
        asAlarm: true,
      );
    } catch (e) {
      debugPrint('No se pudo reproducir la alarma de batería: $e');
    }
  }

  void _playNoticeSound() {
    try {
      _ringtonePlayer.playNotification(
        volume: 1.0,
        looping: false,
        asAlarm: false,
      );
    } catch (e) {
      debugPrint('No se pudo reproducir sonido de notificación: $e');
    }
  }

  Future<void> stopCriticalAlarmSound() async {
    try {
      _isRinging = false;
      await _ringtonePlayer.stop();
      await _notificationsPlugin.cancel(_criticalAlertNotificationId);
    } catch (e) {
      debugPrint('Error al silenciar alarma: $e');
    }
  }

  Future<void> _sendDirectTelegramAlert({
    required String botToken,
    required String chatId,
    required SolarReading reading,
    required double threshold,
    required BatteryAlertMode alertMode,
  }) async {
    try {
      final uri =
          Uri.parse('https://api.telegram.org/bot$botToken/sendMessage');
      final header = alertMode == BatteryAlertMode.immediateAlarm
          ? '🚨 *¡ALARMA DE BATERÍA CRÍTICA (<${threshold.toStringAsFixed(0)}%)* 🚨'
          : '⚠️ *AVISO SOLAR FAMILIAR (<${threshold.toStringAsFixed(0)}%)*';

      final message = '$header\n'
          '• Batería actual: *${reading.batterySoc.toStringAsFixed(1)}%* (${reading.batteryVoltage.toStringAsFixed(1)}V)\n'
          '• Descarga actual: *${reading.batteryDischargeW.toStringAsFixed(0)} W*\n'
          '• Paneles solares: *${reading.pvPowerW.toStringAsFixed(0)} W*';

      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'chat_id': chatId,
              'text': message,
              'parse_mode': 'Markdown',
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Error enviando alerta directa a Telegram: $e');
    }
  }
}
