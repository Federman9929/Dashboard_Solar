import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/solar_reading.dart';

/// Gestiona:
/// 1. La Notificación Permanente (Foreground / Ongoing) en la barra de estado
///    con el porcentaje de batería, estado actual y círculo de color (🟢/🔴).
/// 2. La Alerta Crítica (< 30% de batería) con sirena tipo llamada entrante
///    y envío opcional a Telegram Bot API sin costo.
class NotificationAndAlertService {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final FlutterRingtonePlayer _ringtonePlayer = FlutterRingtonePlayer();

  static const int _ongoingNotificationId = 1001;
  static const int _criticalAlertNotificationId = 9999;

  static const String _ongoingChannelId = 'solar_ongoing_status_channel';
  static const String _criticalChannelId = 'solar_critical_alarm_channel';

  bool _isInitialized = false;
  bool _isRinging = false;
  DateTime? _lastOngoingUpdate;
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
        // Si el usuario toca la notificación de alarma crítica, silenciar el timbre
        if (response.id == _criticalAlertNotificationId) {
          stopCriticalAlarmSound();
        }
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
  /// está descargando o con batería baja.
  Future<void> updatePersistentNotification(SolarReading reading) async {
    if (!_isInitialized) await initialize();

    // Limitar actualizaciones de barra de estado a máximo 1 cada 2 segundos
    final now = DateTime.now();
    if (_lastOngoingUpdate != null &&
        now.difference(_lastOngoingUpdate!).inMilliseconds < 1800) {
      return;
    }
    _lastOngoingUpdate = now;

    final isGreen = reading.isHealthyGreen;
    final circleIndicator = reading.statusEmoji; // 🟢 o 🔴
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

  /// Dispara una Alerta Crítica tipo Llamada Entrante + Notificación FullScreen
  /// cuando el nivel de batería baja del 30%.
  Future<void> triggerCriticalBatteryAlert({
    required SolarReading reading,
    String? telegramBotToken,
    String? telegramChatId,
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    final now = DateTime.now();
    // Cooldown de 5 minutos para no saturar una vez atendida, salvo prueba manual
    if (!force &&
        _lastCriticalTrigger != null &&
        now.difference(_lastCriticalTrigger!).inMinutes < 5) {
      return;
    }
    _lastCriticalTrigger = now;

    // 1. Reproducir sonido persistente de llamada/alarma en el teléfono
    _startCriticalAlarmSound();

    // 2. Mostrar notificación crítica de máxima prioridad (tipo llamada entrante)
    final vibrationPattern = Int64List.fromList([0, 800, 400, 800, 400, 1200]);
    final androidDetails = AndroidNotificationDetails(
      _criticalChannelId,
      'Alertas Críticas de Batería (<30%)',
      channelDescription:
          'Alerta sonora tipo llamada cuando la batería solar baja del 30%',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      color: const Color(0xFFD50000),
      colorized: true,
      ongoing: true,
      autoCancel: true,
      vibrationPattern: vibrationPattern,
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
      '🚨 ¡ALERTA CRÍTICA: BATERÍA AL ${reading.batterySoc.toStringAsFixed(1)}%!',
      'Descargando a ${reading.batteryDischargeW.toStringAsFixed(0)}W (${reading.batteryVoltage.toStringAsFixed(1)}V). Toca para silenciar la alarma.',
      NotificationDetails(android: androidDetails, iOS: iosDetails),
    );

    // 3. Si el usuario configuró credenciales de Telegram en la App, enviar mensaje directo
    if (telegramBotToken != null &&
        telegramBotToken.isNotEmpty &&
        telegramChatId != null &&
        telegramChatId.isNotEmpty) {
      await _sendDirectTelegramAlert(
        botToken: telegramBotToken,
        chatId: telegramChatId,
        reading: reading,
      );
    }
  }

  void _startCriticalAlarmSound() {
    try {
      _isRinging = true;
      _ringtonePlayer.play(
        android: AndroidSounds.alarm,
        ios: IosSounds.alarm,
        looping: true,
        volume: 1.0,
        asAlarm: true,
      );
    } catch (e) {
      debugPrint('No se pudo reproducir el tono de llamada crítica: $e');
    }
  }

  Future<void> stopCriticalAlarmSound() async {
    try {
      _isRinging = false;
      await _ringtonePlayer.stop();
      await _notificationsPlugin.cancel(_criticalAlertNotificationId);
    } catch (e) {
      debugPrint('Error al detener alarma: $e');
    }
  }

  Future<void> _sendDirectTelegramAlert({
    required String botToken,
    required String chatId,
    required SolarReading reading,
  }) async {
    try {
      final uri =
          Uri.parse('https://api.telegram.org/bot$botToken/sendMessage');
      final message = '🚨 *ALERTA SOLAR FAMILIAR (<30%)* 🚨\n'
          '🔴 Batería crítica: *${reading.batterySoc.toStringAsFixed(1)}%* (${reading.batteryVoltage.toStringAsFixed(1)}V)\n'
          '⚡ Descarga actual: *${reading.batteryDischargeW.toStringAsFixed(0)} W*\n'
          '☀️ Paneles solares: *${reading.pvPowerW.toStringAsFixed(0)} W*';

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
      debugPrint('Error enviando alerta a Telegram desde app: $e');
    }
  }
}
