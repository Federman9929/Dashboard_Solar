import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

enum MqttConnectionStateStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Servicio de conectividad MQTT ultra-resiliente.
/// Diseñado para soportar microcortes de Wi-Fi cuando el inversor solar
/// conmuta entre la red eléctrica y el banco de baterías.
class MqttSolarService {
  MqttServerClient? _client;
  Timer? _watchdogTimer;
  String _currentHost = '192.168.1.100';
  int _currentPort = 1883;
  bool _manualDisconnect = false;
  DateTime? _lastMessageReceivedAt;

  static const String topicTelemetry = 'hogar/solar/telemetria';
  static const String topicHistory = 'hogar/solar/historial_24h';
  static const String topicAlert = 'hogar/solar/alerta';
  static const String topicCommand = 'hogar/solar/comando';

  final _telemetryController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _historyController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _alertController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController =
      StreamController<MqttConnectionStateStatus>.broadcast();

  Stream<Map<String, dynamic>> get telemetryStream =>
      _telemetryController.stream;
  Stream<List<Map<String, dynamic>>> get historyStream =>
      _historyController.stream;
  Stream<Map<String, dynamic>> get alertStream => _alertController.stream;
  Stream<MqttConnectionStateStatus> get connectionStream =>
      _connectionController.stream;

  MqttConnectionStateStatus _status = MqttConnectionStateStatus.disconnected;
  MqttConnectionStateStatus get status => _status;

  Future<void> connect({
    required String host,
    int port = 1883,
  }) async {
    _currentHost = host.trim();
    _currentPort = port;
    _manualDisconnect = false;

    await _cleanupExistingClient();
    _updateStatus(MqttConnectionStateStatus.connecting);

    final uniqueClientId =
        'solar_familia_${Random().nextInt(999999).toString().padLeft(6, '0')}';

    final client = MqttServerClient.withPort(_currentHost, uniqueClientId, _currentPort);
    client.logging(on: false);
    client.keepAlivePeriod = 10; // Detecta microcortes rápidamente
    client.connectTimeoutPeriod = 4000;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;

    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.onAutoReconnect = _onAutoReconnect;
    client.onAutoReconnected = _onAutoReconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(uniqueClientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    client.connectionMessage = connMessage;

    _client = client;

    try {
      await client.connect();
    } catch (e) {
      debugPrint('Error conectando a MQTT ($_currentHost:$_currentPort): $e');
      client.disconnect();
      _scheduleInstantReconnect();
      return;
    }

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      _setupSubscriptions();
      _startWatchdog();
    } else {
      _scheduleInstantReconnect();
    }
  }

  void _setupSubscriptions() {
    final client = _client;
    if (client == null) return;

    client.subscribe(topicTelemetry, MqttQos.atLeastOnce);
    client.subscribe(topicHistory, MqttQos.atLeastOnce);
    client.subscribe(topicAlert, MqttQos.atLeastOnce);

    client.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? events) {
      if (events == null || events.isEmpty) return;

      for (final event in events) {
        final pubMessage = event.payload as MqttPublishMessage?;
        if (pubMessage == null) continue;

        final payloadString = MqttPublishPayload.bytesToStringAsString(
          pubMessage.payload.message,
        );
        _lastMessageReceivedAt = DateTime.now();

        try {
          final decoded = jsonDecode(payloadString) as Map<String, dynamic>;
          if (event.topic == topicTelemetry) {
            _telemetryController.add(decoded);
          } else if (event.topic == topicHistory) {
            final pointsRaw = decoded['points'] as List<dynamic>? ?? [];
            final points = pointsRaw
                .whereType<Map<String, dynamic>>()
                .toList(growable: false);
            _historyController.add(points);
          } else if (event.topic == topicAlert) {
            _alertController.add(decoded);
          }
        } catch (e) {
          debugPrint('Error decodificando JSON de ${event.topic}: $e');
        }
      }
    });

    // Solicitar el historial de 24h al conectar
    sendCommand('GET_HISTORY');
  }

  /// Envía un comando al backend en la MacBook (ej. GET_HISTORY o TEST_CRITICAL_ALERT)
  void sendCommand(String command) {
    final client = _client;
    if (client?.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(command);
    client!.publishMessage(
      topicCommand,
      MqttQos.atLeastOnce,
      builder.payload!,
    );
  }

  /// Watchdog que verifica que sigan llegando lecturas cada pocos segundos.
  /// Si hay un microcorte de red silencioso (socket zombie), fuerza la reconexión.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (_manualDisconnect) return;
      final lastRx = _lastMessageReceivedAt;
      if (lastRx != null &&
          DateTime.now().difference(lastRx).inSeconds > 10 &&
          _status == MqttConnectionStateStatus.connected) {
        debugPrint('Watchdog MQTT: Sin datos por >10s, forzando reconexión...');
        connect(host: _currentHost, port: _currentPort);
      }
    });
  }

  void _onConnected() {
    _lastMessageReceivedAt = DateTime.now();
    _updateStatus(MqttConnectionStateStatus.connected);
  }

  void _onDisconnected() {
    _updateStatus(MqttConnectionStateStatus.disconnected);
    if (!_manualDisconnect) {
      _scheduleInstantReconnect();
    }
  }

  void _onAutoReconnect() {
    _updateStatus(MqttConnectionStateStatus.reconnecting);
  }

  void _onAutoReconnected() {
    _lastMessageReceivedAt = DateTime.now();
    _updateStatus(MqttConnectionStateStatus.connected);
    _setupSubscriptions();
  }

  void _scheduleInstantReconnect() {
    if (_manualDisconnect) return;
    _updateStatus(MqttConnectionStateStatus.reconnecting);
    Future.delayed(const Duration(seconds: 2), () {
      if (!_manualDisconnect &&
          _status != MqttConnectionStateStatus.connected) {
        connect(host: _currentHost, port: _currentPort);
      }
    });
  }

  void _updateStatus(MqttConnectionStateStatus newStatus) {
    _status = newStatus;
    if (!_connectionController.isClosed) {
      _connectionController.add(newStatus);
    }
  }

  Future<void> _cleanupExistingClient() async {
    _watchdogTimer?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }

  Future<void> dispose() async {
    _manualDisconnect = true;
    await _cleanupExistingClient();
    await _telemetryController.close();
    await _historyController.close();
    await _alertController.close();
    await _connectionController.close();
  }
}
