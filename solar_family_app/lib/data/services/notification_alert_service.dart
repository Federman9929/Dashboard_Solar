import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/solar_reading.dart';

/// Gestiona:
/// 1. La Notificación Permanente (Foreground / Ongoing) en la barra de estado
///    con el porcentaje de batería, estado actual y círculo de color (🟢/🔴).
/// 2. El Aviso de Batería Baja mediante una notificación simple y discreta
///    (sin sirenas ni alarmas prolongadas) cuando baja del umbral configurado.
class NotificationAndAlertService {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const int _ongoingNotificationId = 1001;
  static const int _criticalAlertNotificationId = 9999;

  static const String _ongoingChannelId = 'solar_ongoing_status_channel';
  static const String _simpleAlertChannelId = 'solar_battery_notice_channel';

  bool _isInitialized = false;
  DateTime? _lastOngoingUpdate;
  bool? _lastOngoingIsGreen;
  DateTime? _lastCriticalTrigger;

  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _notificationsPlugin.initialize(initSettings);

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
    // Evitar saturar el canal nativo de Android (que causa ANR "La aplicación no responde")
    // actualizando la notificación del sistema máximo cada 15 segundos o si cambia el semáforo.
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
      importance: Importance.low, // No interrumpe con sonido cada 2s
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

  /// Muestra una notificación simple y normal (sin alarma estridente ni bucle)
  /// cuando el nivel de batería baja del umbral configurado por el usuario.
  Future<void> triggerCriticalBatteryAlert({
    required SolarReading reading,
    double threshold = 30.0,
    String? telegramBotToken,
    String? telegramChatId,
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    final now = DateTime.now();
    // Cooldown de 5 minutos para no repetir notificaciones seguidas, salvo prueba manual
    if (!force &&
        _lastCriticalTrigger != null &&
        now.difference(_lastCriticalTrigger!).inMinutes < 5) {
      return;
    }
    _lastCriticalTrigger = now;

    const androidDetails = AndroidNotificationDetails(
      _simpleAlertChannelId,
      'Avisos de Nivel de Batería',
      channelDescription:
          'Notificación simple cuando la batería baja del umbral configurado',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      fullScreenIntent: false,
      ongoing: false,
      autoCancel: true,
      onlyAlertOnce: true,
      color: Color(0xFFFFB300),
      visibility: NotificationVisibility.public,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.active,
    );

    await _notificationsPlugin.show(
      _criticalAlertNotificationId,
      '🔋 Batería en ${reading.batterySoc.toStringAsFixed(1)}% (Umbral: ${threshold.toStringAsFixed(0)}%)',
      'Nivel por debajo del ajuste (${threshold.toStringAsFixed(0)}%). Voltaje: ${reading.batteryVoltage.toStringAsFixed(1)}V • Consumo: ${reading.loadPowerW.toStringAsFixed(0)}W.',
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
    );

    // Si el usuario configuró credenciales de Telegram en la App, enviar mensaje directo
    if (telegramBotToken != null &&
        telegramBotToken.isNotEmpty &&
        telegramChatId != null &&
        telegramChatId.isNotEmpty) {
      await _sendDirectTelegramAlert(
        botToken: telegramBotToken,
        chatId: telegramChatId,
        reading: reading,
        threshold: threshold,
      );
    }
  }

  Future<void> stopCriticalAlarmSound() async {
    try {
      await _notificationsPlugin.cancel(_criticalAlertNotificationId);
    } catch (e) {
      debugPrint('Error al cerrar notificación: $e');
    }
  }

  Future<void> _sendDirectTelegramAlert({
    required String botToken,
    required String chatId,
    required SolarReading reading,
    required double threshold,
  }) async {
    try {
      final uri =
          Uri.parse('https://api.telegram.org/bot$botToken/sendMessage');
      final message =
          '🔋 *AVISO SOLAR FAMILIAR (<${threshold.toStringAsFixed(0)}%)*\n'
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
