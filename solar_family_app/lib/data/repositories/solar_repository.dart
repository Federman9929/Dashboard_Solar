import 'dart:async';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/solar_reading.dart';
import '../services/mqtt_solar_service.dart';
import '../services/notification_alert_service.dart';

/// Repositorio central del sistema solar familiar.
/// Coordina la conexión MQTT local con la MacBook, conserva las ventanas de
/// datos en tiempo real y de 24 horas, actualiza la notificación permanente
/// y dispara alertas críticas cuando la batería cae por debajo del 30%.
class SolarRepository {
  SolarRepository({
    required MqttSolarService mqttService,
    required NotificationAndAlertService notificationService,
  })  : _mqttService = mqttService,
        _notificationService = notificationService;

  final MqttSolarService _mqttService;
  final NotificationAndAlertService _notificationService;

  static const String _prefBrokerHost = 'mqtt_broker_host';
  static const String _prefBrokerPort = 'mqtt_broker_port';
  static const String _prefTelegramToken = 'telegram_bot_token';
  static const String _prefTelegramChatId = 'telegram_chat_id';
  static const String _prefDemoMode = 'demo_mode_enabled';

  String _brokerHost = '10.0.2.2';
  int _brokerPort = 1883;
  String _telegramBotToken = '';
  String _telegramChatId = '';
  bool _demoMode = true;
  Timer? _demoTimer;

  String get brokerHost => _brokerHost;
  int get brokerPort => _brokerPort;
  String get telegramBotToken => _telegramBotToken;
  String get telegramChatId => _telegramChatId;
  bool get demoMode => _demoMode;

  Stream<MqttConnectionStateStatus> get connectionStream =>
      _mqttService.connectionStream;

  final _readingStreamController = StreamController<SolarReading>.broadcast();
  final _history24hController =
      StreamController<List<SolarReading>>.broadcast();
  final _realtimeWindowController =
      StreamController<List<SolarReading>>.broadcast();
  final _criticalAlertBannerController =
      StreamController<SolarReading?>.broadcast();

  Stream<SolarReading> get readingStream => _readingStreamController.stream;
  Stream<List<SolarReading>> get history24hStream =>
      _history24hController.stream;
  Stream<List<SolarReading>> get realtimeWindowStream =>
      _realtimeWindowController.stream;
  Stream<SolarReading?> get criticalAlertBannerStream =>
      _criticalAlertBannerController.stream;

  final List<SolarReading> _history24h = [];
  final List<SolarReading> _realtimeReadings = [];

  List<SolarReading> get history24h => List.unmodifiable(_history24h);
  List<SolarReading> get realtimeReadings =>
      List.unmodifiable(_realtimeReadings);

  Future<void> initialize() async {
    await _notificationService.initialize();

    final prefs = await SharedPreferences.getInstance();
    _brokerHost = prefs.getString(_prefBrokerHost) ?? '10.0.2.2';
    _brokerPort = prefs.getInt(_prefBrokerPort) ?? 1883;
    _telegramBotToken = prefs.getString(_prefTelegramToken) ?? '';
    _telegramChatId = prefs.getString(_prefTelegramChatId) ?? '';
    _demoMode = prefs.getBool(_prefDemoMode) ?? true;

    // Pre-cargar curva inicial de 24h por si aún no responde la red local
    _seedInitialHistoryIfNeeded();

    // Escuchar telemetría MQTT en tiempo real (cada 1-2s)
    _mqttService.telemetryStream.listen((jsonMap) {
      if (_demoMode) return;
      final reading = SolarReading.fromJson(jsonMap);
      _processIncomingReading(reading);
    });

    // Escuchar lote de historial de 24h publicado por la MacBook
    _mqttService.historyStream.listen((pointsList) {
      if (_demoMode) return;
      final parsed = pointsList
          .map(SolarReading.fromJson)
          .toList(growable: false);
      if (parsed.isNotEmpty) {
        _history24h
          ..clear()
          ..addAll(parsed);
        _history24hController.add(List.unmodifiable(_history24h));
      }
    });

    // Escuchar alertas críticas emitidas por el backend en la MacBook
    _mqttService.alertStream.listen((alertJson) {
      final soc = (alertJson['battery_soc'] as num?)?.toDouble() ?? 25.0;
      final voltage =
          (alertJson['battery_voltage'] as num?)?.toDouble() ?? 46.2;
      final discharge =
          (alertJson['battery_discharge_w'] as num?)?.toDouble() ?? 1200.0;
      final criticalReading = SolarReading(
        timestamp: DateTime.now(),
        epochMs: DateTime.now().millisecondsSinceEpoch,
        batteryVoltage: voltage,
        batterySoc: soc,
        pvPowerW: 0.0,
        batteryPowerW: -discharge,
        batteryChargeW: 0.0,
        batteryDischargeW: discharge,
        loadPowerW: discharge,
        status: SolarSystemStatus.discharging,
        isCritical: true,
        sourceMode: 'ALERTA_MQTT',
      );
      _triggerCriticalAlertFlow(criticalReading, force: true);
    });

    if (_demoMode) {
      _startLocalDemoStream();
    } else {
      await _mqttService.connect(host: _brokerHost, port: _brokerPort);
    }
  }

  void _processIncomingReading(SolarReading reading) {
    // 1. Mantener ventana en tiempo real (últimos 120 puntos = ~3-4 minutos a 1.5s)
    _realtimeReadings.add(reading);
    if (_realtimeReadings.length > 120) {
      _realtimeReadings.removeAt(0);
    }

    // 2. Añadir al historial de 24h si pasaron al menos 5 minutos desde el último punto
    if (_history24h.isEmpty ||
        (reading.epochMs - _history24h.last.epochMs) >= 5 * 60 * 1000) {
      _history24h.add(reading);
      if (_history24h.length > 288) {
        _history24h.removeAt(0);
      }
      _history24hController.add(List.unmodifiable(_history24h));
    }

    _readingStreamController.add(reading);
    _realtimeWindowController.add(List.unmodifiable(_realtimeReadings));

    // 3. Actualizar Notificación Permanente en la barra de estado
    _notificationService.updatePersistentNotification(reading);

    // 4. Evaluar umbral crítico (< 30%)
    if (reading.batterySoc < 30.0 || reading.isCritical) {
      _triggerCriticalAlertFlow(reading);
    }
  }

  void _triggerCriticalAlertFlow(SolarReading reading, {bool force = false}) {
    _criticalAlertBannerController.add(reading);
    _notificationService.triggerCriticalBatteryAlert(
      reading: reading,
      telegramBotToken: _telegramBotToken,
      telegramChatId: _telegramChatId,
      force: force,
    );
  }

  Future<void> silenceCriticalAlert() async {
    _criticalAlertBannerController.add(null);
    await _notificationService.stopCriticalAlarmSound();
  }

  Future<void> simulateCriticalAlertTest() async {
    final fakeCritical = SolarReading(
      timestamp: DateTime.now(),
      epochMs: DateTime.now().millisecondsSinceEpoch,
      batteryVoltage: 45.8,
      batterySoc: 26.4,
      pvPowerW: 45.0,
      batteryPowerW: -1350.0,
      batteryChargeW: 0.0,
      batteryDischargeW: 1350.0,
      loadPowerW: 1395.0,
      status: SolarSystemStatus.discharging,
      isCritical: true,
      sourceMode: 'TEST_ALERTA',
    );
    _processIncomingReading(fakeCritical);
    _triggerCriticalAlertFlow(fakeCritical, force: true);
    _mqttService.sendCommand('TEST_CRITICAL_ALERT');
  }

  Future<void> updateSettings({
    required String host,
    required int port,
    required String telegramToken,
    required String telegramChatId,
    required bool demoMode,
  }) async {
    _brokerHost = host.trim();
    _brokerPort = port;
    _telegramBotToken = telegramToken.trim();
    _telegramChatId = telegramChatId.trim();
    _demoMode = demoMode;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefBrokerHost, _brokerHost);
    await prefs.setInt(_prefBrokerPort, _brokerPort);
    await prefs.setString(_prefTelegramToken, _telegramBotToken);
    await prefs.setString(_prefTelegramChatId, _telegramChatId);
    await prefs.setBool(_prefDemoMode, _demoMode);

    _demoTimer?.cancel();
    if (_demoMode) {
      _startLocalDemoStream();
    } else {
      await _mqttService.connect(host: _brokerHost, port: _brokerPort);
    }
  }

  void _seedInitialHistoryIfNeeded() {
    if (_history24h.isNotEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startMs = nowMs - (24 * 3600 * 1000);
    const stepMs = 10 * 60 * 1000; // cada 10 min (144 puntos)
    final rng = math.Random(42);
    double soc = 64.0;

    for (int ts = startMs; ts <= nowMs; ts += stepMs) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      final hour = dt.hour + dt.minute / 60.0;
      double pv = 0.0;
      if (hour >= 6.5 && hour <= 18.5) {
        final sun = math.sin(math.pi * (hour - 6.5) / 12.0);
        pv = math.max(0.0, 2300.0 * math.pow(sun, 1.3) + (rng.nextDouble() - 0.5) * 90);
      }
      final load = 360.0 + 210.0 * math.pow(math.sin((hour - 19.0) * math.pi / 12.0), 2);
      final netBatt = pv - load;
      final chargeW = netBatt > 0 ? netBatt : 0.0;
      final dischargeW = netBatt < 0 ? netBatt.abs() : 0.0;
      soc = (soc + (netBatt * (10.0 / 60.0)) / 5000.0 * 100.0).clamp(24.0, 100.0);
      final voltage = 46.0 + (soc / 100.0) * 8.2;
      final status = netBatt > 20
          ? SolarSystemStatus.charging
          : netBatt < -20
              ? SolarSystemStatus.discharging
              : SolarSystemStatus.idle;

      _history24h.add(
        SolarReading(
          timestamp: dt,
          epochMs: ts,
          batteryVoltage: double.parse(voltage.toStringAsFixed(2)),
          batterySoc: double.parse(soc.toStringAsFixed(1)),
          pvPowerW: double.parse(pv.toStringAsFixed(1)),
          batteryPowerW: double.parse(netBatt.toStringAsFixed(1)),
          batteryChargeW: double.parse(chargeW.toStringAsFixed(1)),
          batteryDischargeW: double.parse(dischargeW.toStringAsFixed(1)),
          loadPowerW: double.parse(load.toStringAsFixed(1)),
          status: status,
          isCritical: soc < 30.0,
          sourceMode: 'HISTORIAL',
        ),
      );
    }

    // Sembrar también los últimos 30 puntos en tiempo real para que las gráficas luzcan vivas al instante
    final nowRealtime = DateTime.now().millisecondsSinceEpoch;
    for (int i = 30; i >= 1; i--) {
      final ts = nowRealtime - (i * 1500);
      final wave = math.sin(ts / 12000.0);
      final pv = 1480.0 + 280.0 * wave;
      final load = 620.0 + 180.0 * math.cos(ts / 9000.0);
      final net = pv - load;
      _realtimeReadings.add(
        SolarReading(
          timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
          epochMs: ts,
          batteryVoltage: 52.4,
          batterySoc: 81.2,
          pvPowerW: pv,
          batteryPowerW: net,
          batteryChargeW: net > 0 ? net : 0.0,
          batteryDischargeW: net < 0 ? net.abs() : 0.0,
          loadPowerW: load,
          status: net > 20
              ? SolarSystemStatus.charging
              : SolarSystemStatus.discharging,
          isCritical: false,
          sourceMode: 'INICIAL',
        ),
      );
    }
  }

  void _startLocalDemoStream() {
    _demoTimer?.cancel();
    double demoSoc = 76.0;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      final now = DateTime.now();
      final t = now.millisecondsSinceEpoch / 1000.0;
      final pv = math.max(0.0, 1250.0 * math.sin(t / 18.0) + 950.0);
      final load = 720.0 + 380.0 * math.cos(t / 11.0);
      final net = pv - load;
      demoSoc = (demoSoc + net / 15000.0).clamp(25.0, 99.0);
      final voltage = 46.2 + (demoSoc / 100.0) * 8.0;

      final reading = SolarReading(
        timestamp: now,
        epochMs: now.millisecondsSinceEpoch,
        batteryVoltage: double.parse(voltage.toStringAsFixed(2)),
        batterySoc: double.parse(demoSoc.toStringAsFixed(1)),
        pvPowerW: double.parse(pv.toStringAsFixed(1)),
        batteryPowerW: double.parse(net.toStringAsFixed(1)),
        batteryChargeW: net > 0 ? double.parse(net.toStringAsFixed(1)) : 0.0,
        batteryDischargeW:
            net < 0 ? double.parse(net.abs().toStringAsFixed(1)) : 0.0,
        loadPowerW: double.parse(load.toStringAsFixed(1)),
        status: net > 20
            ? SolarSystemStatus.charging
            : net < -20
                ? SolarSystemStatus.discharging
                : SolarSystemStatus.idle,
        isCritical: demoSoc < 30.0,
        sourceMode: 'DEMO_LOCAL',
      );
      _processIncomingReading(reading);
    });
  }

  Future<void> dispose() async {
    _demoTimer?.cancel();
    await _mqttService.dispose();
    await _readingStreamController.close();
    await _history24hController.close();
    await _realtimeWindowController.close();
    await _criticalAlertBannerController.close();
  }
}
