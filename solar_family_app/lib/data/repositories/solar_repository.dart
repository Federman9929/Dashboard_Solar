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
  static const String _prefCriticalThreshold = 'critical_soc_threshold';

  String _brokerHost = '192.168.0.224';
  int _brokerPort = 1883;
  String _telegramBotToken = '';
  String _telegramChatId = '';
  bool _demoMode = false;
  double _criticalSocThreshold = 30.0;
  Timer? _demoTimer;

  String get brokerHost => _brokerHost;
  int get brokerPort => _brokerPort;
  String get telegramBotToken => _telegramBotToken;
  String get telegramChatId => _telegramChatId;
  bool get demoMode => _demoMode;
  double get criticalSocThreshold => _criticalSocThreshold;

  Stream<MqttConnectionStateStatus> get connectionStream =>
      _mqttService.connectionStream;
  Stream<MqttDiagnosticsSnapshot> get diagnosticsStream =>
      _mqttService.diagnosticsStream;
  MqttDiagnosticsSnapshot get currentDiagnostics =>
      _mqttService.currentDiagnostics;

  bool _hasActiveAlertBanner = false;

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
  double? _lastSmoothedSoc;

  List<SolarReading> get history24h => List.unmodifiable(_history24h);
  List<SolarReading> get realtimeReadings =>
      List.unmodifiable(_realtimeReadings);

  /// Línea de tiempo unificada e inmutable hacia el pasado que combina el
  /// historial de 24h con la ventana de alta resolución (1s).
  List<SolarReading> get unifiedTimeline {
    if (_realtimeReadings.isEmpty) return List.unmodifiable(_history24h);
    if (_history24h.isEmpty) return List.unmodifiable(_realtimeReadings);

    final firstRealtimeMs = _realtimeReadings.first.epochMs;
    final merged = <SolarReading>[
      for (final h in _history24h)
        if (h.epochMs < firstRealtimeMs) h,
      ..._realtimeReadings,
    ];
    return merged;
  }

  Future<void> initialize() async {
    // Inicializar notificaciones sin bloquear si el usuario tarda en aceptar el diálogo de permisos
    unawaited(_notificationService.initialize());

    final prefs = await SharedPreferences.getInstance();
    _brokerHost = prefs.getString(_prefBrokerHost) ?? '192.168.0.224';
    _brokerPort = prefs.getInt(_prefBrokerPort) ?? 1883;
    _telegramBotToken = prefs.getString(_prefTelegramToken) ?? '';
    _telegramChatId = prefs.getString(_prefTelegramChatId) ?? '';
    _demoMode = prefs.getBool(_prefDemoMode) ?? false;
    _criticalSocThreshold = prefs.getDouble(_prefCriticalThreshold) ?? 30.0;

    // Solo pre-cargar curva sintética si el usuario activó explícitamente el modo Demo
    if (_demoMode) {
      _seedInitialHistoryIfNeeded();
      _history24hController.add(List.unmodifiable(_history24h));
    }

    // Escuchar telemetría MQTT en tiempo real (cada 1-2s)
    _mqttService.telemetryStream.listen((jsonMap) {
      if (_demoMode) return;
      final reading = SolarReading.fromJson(jsonMap);
      _processIncomingReading(reading);
    });

    // Escuchar lote de historial de 24h publicado por la MacBook
    // Garantiza inmutabilidad del pasado: nunca altera puntos históricos ya consolidados.
    _mqttService.historyStream.listen((pointsList) {
      if (_demoMode) return;
      final parsed = pointsList
          .map(SolarReading.fromJson)
          .toList(growable: false);
      if (parsed.isEmpty) return;

      final hasOnlySynthetic = _history24h.isNotEmpty &&
          _history24h.every((r) => r.sourceMode == 'HISTORIAL');

      if (_history24h.isEmpty || hasOnlySynthetic) {
        _history24h
          ..clear()
          ..addAll(parsed);
      } else {
        final firstExistingMs = _history24h.first.epochMs;
        final lastExistingMs = _history24h.last.epochMs;
        final olderPoints = parsed
            .where((p) => p.epochMs < firstExistingMs)
            .toList(growable: false);
        final newerPoints = parsed
            .where((p) => p.epochMs > lastExistingMs + 10000)
            .toList(growable: false);
        if (olderPoints.isNotEmpty) {
          _history24h.insertAll(0, olderPoints);
        }
        if (newerPoints.isNotEmpty) {
          _history24h.addAll(newerPoints);
        }
      }
      _history24hController.add(List.unmodifiable(_history24h));
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

  void _processIncomingReading(SolarReading rawReading) {
    // Suavizado causal sobre el nuevo punto actual sin tocar jamás los puntos pasados
    double effectiveSoc = rawReading.batterySoc;
    if (_lastSmoothedSoc != null && rawReading.sourceMode != 'TEST_ALERTA') {
      final diff = (effectiveSoc - _lastSmoothedSoc!).abs();
      if (diff <= 2.5) {
        effectiveSoc = double.parse(
          (_lastSmoothedSoc! * 0.80 + effectiveSoc * 0.20).toStringAsFixed(1),
        );
      }
    }
    _lastSmoothedSoc = effectiveSoc;

    final reading = effectiveSoc == rawReading.batterySoc
        ? rawReading
        : SolarReading(
            timestamp: rawReading.timestamp,
            epochMs: rawReading.epochMs,
            batteryVoltage: rawReading.batteryVoltage,
            batterySoc: effectiveSoc,
            pvPowerW: rawReading.pvPowerW,
            batteryPowerW: rawReading.batteryPowerW,
            batteryChargeW: rawReading.batteryChargeW,
            batteryDischargeW: rawReading.batteryDischargeW,
            loadPowerW: rawReading.loadPowerW,
            status: rawReading.status,
            isCritical: effectiveSoc < _criticalSocThreshold,
            sourceMode: rawReading.sourceMode,
          );

    // 1. Mantener ventana en tiempo real de 10 minutos a 1s (600 puntos en RAM = <40KB)
    _realtimeReadings.add(reading);
    if (_realtimeReadings.length > 600) {
      _realtimeReadings.removeAt(0);
    }

    // 2. Añadir al historial cada 15 segundos de forma estrictamente append-only (inmutable)
    if (_history24h.isEmpty ||
        (reading.epochMs - _history24h.last.epochMs) >= 15 * 1000) {
      _history24h.add(reading);
      if (_history24h.length > 720) {
        _history24h.removeAt(0);
      }
      _history24hController.add(List.unmodifiable(_history24h));
    }

    _realtimeWindowController.add(List.unmodifiable(_realtimeReadings));
    _readingStreamController.add(reading);

    // 3. Actualizar Notificación Permanente (con limitador de 15s para no bloquear Android)
    _notificationService.updatePersistentNotification(
      reading,
      threshold: _criticalSocThreshold,
    );

    // 4. Evaluar umbral crítico configurable por el usuario
    if (reading.batterySoc < _criticalSocThreshold) {
      _triggerCriticalAlertFlow(reading);
    } else if (_hasActiveAlertBanner) {
      _hasActiveAlertBanner = false;
      _criticalAlertBannerController.add(null);
    }
  }

  void _triggerCriticalAlertFlow(SolarReading reading, {bool force = false}) {
    _hasActiveAlertBanner = true;
    _criticalAlertBannerController.add(reading);
    _notificationService.triggerCriticalBatteryAlert(
      reading: reading,
      threshold: _criticalSocThreshold,
      telegramBotToken: _telegramBotToken,
      telegramChatId: _telegramChatId,
      force: force,
    );
  }

  Future<void> silenceCriticalAlert() async {
    _hasActiveAlertBanner = false;
    _criticalAlertBannerController.add(null);
    await _notificationService.stopCriticalAlarmSound();
  }

  Future<void> retryConnectionNow() async {
    if (_demoMode) return;
    await _mqttService.connect(host: _brokerHost, port: _brokerPort);
  }

  Future<void> simulateCriticalAlertTest() async {
    final testSoc = (_criticalSocThreshold - 3.5).clamp(1.0, 99.0);
    final fakeCritical = SolarReading(
      timestamp: DateTime.now(),
      epochMs: DateTime.now().millisecondsSinceEpoch,
      batteryVoltage: 45.8,
      batterySoc: double.parse(testSoc.toStringAsFixed(1)),
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

  Future<void> updateCriticalThreshold(double newThreshold) async {
    _criticalSocThreshold = newThreshold.clamp(5.0, 95.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefCriticalThreshold, _criticalSocThreshold);

    _mqttService.sendCommand(
      'SET_THRESHOLD:${_criticalSocThreshold.toStringAsFixed(1)}',
    );

    if (_realtimeReadings.isNotEmpty) {
      final latest = _realtimeReadings.last;
      _notificationService.updatePersistentNotification(
        latest,
        threshold: _criticalSocThreshold,
      );
      if (latest.batterySoc < _criticalSocThreshold) {
        _triggerCriticalAlertFlow(latest, force: true);
      } else {
        await silenceCriticalAlert();
      }
    }
  }

  Future<void> updateSettings({
    required String host,
    required int port,
    required String telegramToken,
    required String telegramChatId,
    required bool demoMode,
    double? criticalThreshold,
  }) async {
    _brokerHost = host.trim();
    _brokerPort = port;
    _telegramBotToken = telegramToken.trim();
    _telegramChatId = telegramChatId.trim();
    _demoMode = demoMode;
    if (criticalThreshold != null) {
      _criticalSocThreshold = criticalThreshold.clamp(5.0, 95.0);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefBrokerHost, _brokerHost);
    await prefs.setInt(_prefBrokerPort, _brokerPort);
    await prefs.setString(_prefTelegramToken, _telegramBotToken);
    await prefs.setString(_prefTelegramChatId, _telegramChatId);
    await prefs.setBool(_prefDemoMode, _demoMode);
    await prefs.setDouble(_prefCriticalThreshold, _criticalSocThreshold);

    _mqttService.sendCommand(
      'SET_THRESHOLD:${_criticalSocThreshold.toStringAsFixed(1)}',
    );

    _demoTimer?.cancel();
    if (_demoMode) {
      await _mqttService.disconnectManual();
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
          batteryVoltage: 56.6,
          batterySoc: 100.0,
          pvPowerW: double.parse(pv.toStringAsFixed(1)),
          batteryPowerW: double.parse(netBatt.toStringAsFixed(1)),
          batteryChargeW: double.parse(chargeW.toStringAsFixed(1)),
          batteryDischargeW: double.parse(dischargeW.toStringAsFixed(1)),
          loadPowerW: double.parse(load.toStringAsFixed(1)),
          status: status,
          isCritical: false,
          sourceMode: 'HISTORIAL',
        ),
      );
    }
  }

  void _startLocalDemoStream() {
    _demoTimer?.cancel();
    double demoSoc = 76.0;
    _demoTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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
