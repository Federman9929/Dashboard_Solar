import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:solar_family_monitor/data/repositories/solar_repository.dart';
import 'package:solar_family_monitor/data/services/mqtt_solar_service.dart';
import 'package:solar_family_monitor/domain/models/solar_reading.dart';

class SolarDashboardViewModel extends ChangeNotifier {
  SolarDashboardViewModel({required SolarRepository repository})
      : _repository = repository;

  final SolarRepository _repository;

  SolarReading? _currentReading;
  SolarReading? get currentReading => _currentReading;

  List<SolarReading> _history24h = const [];
  List<SolarReading> get history24h => _history24h;

  List<SolarReading> _realtimeReadings = const [];
  List<SolarReading> get realtimeReadings => _realtimeReadings;

  SolarReading? _activeCriticalAlert;
  SolarReading? get activeCriticalAlert => _activeCriticalAlert;

  MqttConnectionStateStatus _connectionStatus =
      MqttConnectionStateStatus.disconnected;
  MqttConnectionStateStatus get connectionStatus => _connectionStatus;

  MqttDiagnosticsSnapshot? _diagnostics;
  MqttDiagnosticsSnapshot get diagnostics =>
      _diagnostics ?? _repository.currentDiagnostics;

  /// Índice de la gráfica activa en el selector inferior de solo íconos:
  /// 0 = Batería (SOC 24h), 1 = Paneles Solares PV (W), 2 = Carga de la Casa (W)
  int _selectedChartIndex = 0;
  int get selectedChartIndex => _selectedChartIndex;

  String get brokerHost => _repository.brokerHost;
  int get brokerPort => _repository.brokerPort;
  String get telegramBotToken => _repository.telegramBotToken;
  String get telegramChatId => _repository.telegramChatId;
  bool get demoMode => _repository.demoMode;
  double get criticalSocThreshold => _repository.criticalSocThreshold;

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Future<void> init() async {
    // 1. Actualizar lista de ventana en tiempo real sin doble notifyListeners()
    _subscriptions.add(
      _repository.realtimeWindowStream.listen((realtime) {
        _realtimeReadings = realtime;
      }),
    );

    // 2. Un único notifyListeners() por cada segundo de lectura recibida
    _subscriptions.add(
      _repository.readingStream.listen((reading) {
        _currentReading = reading;
        notifyListeners();
      }),
    );

    _subscriptions.add(
      _repository.history24hStream.listen((history) {
        _history24h = history;
        notifyListeners();
      }),
    );

    _subscriptions.add(
      _repository.connectionStream.listen((status) {
        _connectionStatus = status;
        notifyListeners();
      }),
    );

    _subscriptions.add(
      _repository.diagnosticsStream.listen((diag) {
        _diagnostics = diag;
        notifyListeners();
      }),
    );

    _subscriptions.add(
      _repository.criticalAlertBannerStream.listen((alertReading) {
        _activeCriticalAlert = alertReading;
        notifyListeners();
      }),
    );

    await _repository.initialize();
    _history24h = _repository.history24h;
    _realtimeReadings = _repository.realtimeReadings;
    _diagnostics = _repository.currentDiagnostics;
    if (_realtimeReadings.isNotEmpty) {
      _currentReading = _realtimeReadings.last;
    }
    notifyListeners();
  }

  void selectChart(int index) {
    if (_selectedChartIndex == index) return;
    _selectedChartIndex = index.clamp(0, 2);
    notifyListeners();
  }

  Future<void> retryConnectionNow() async {
    await _repository.retryConnectionNow();
  }

  Future<void> silenceCriticalAlert() async {
    await _repository.silenceCriticalAlert();
  }

  Future<void> triggerTestCriticalAlert() async {
    await _repository.simulateCriticalAlertTest();
  }

  Future<void> updateCriticalThreshold(double newThreshold) async {
    await _repository.updateCriticalThreshold(newThreshold);
    notifyListeners();
  }

  Future<void> saveSettings({
    required String host,
    required int port,
    required String telegramToken,
    required String telegramChatId,
    required bool demoMode,
    double? criticalThreshold,
  }) async {
    await _repository.updateSettings(
      host: host,
      port: port,
      telegramToken: telegramToken,
      telegramChatId: telegramChatId,
      demoMode: demoMode,
      criticalThreshold: criticalThreshold,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _repository.dispose();
    super.dispose();
  }
}
