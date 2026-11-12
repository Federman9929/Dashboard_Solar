import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

enum DiagnosticStepState {
  pending,
  inProgress,
  completed,
  failed,
}

class ConnectionStepInfo {
  const ConnectionStepInfo({
    required this.stepNumber,
    required this.title,
    required this.detail,
    required this.state,
  });

  final int stepNumber;
  final String title;
  final String detail;
  final DiagnosticStepState state;
}

class MqttDiagnosticsSnapshot {
  const MqttDiagnosticsSnapshot({
    required this.targetHost,
    required this.targetPort,
    required this.overallStatus,
    required this.currentStepIndex,
    required this.reconnectAttempt,
    required this.packetsReceived,
    required this.lastPacketTime,
    required this.lastError,
    required this.steps,
  });

  final String targetHost;
  final int targetPort;
  final MqttConnectionStateStatus overallStatus;
  final int currentStepIndex;
  final int reconnectAttempt;
  final int packetsReceived;
  final DateTime? lastPacketTime;
  final String? lastError;
  final List<ConnectionStepInfo> steps;
}

/// Servicio de conectividad MQTT ultra-ligero y con diagnóstico paso a paso.
/// Evita tormentas de reconexión usando un único temporizador controlado.
class MqttSolarService {
  MqttServerClient? _client;
  Timer? _watchdogTimer;
  Timer? _reconnectTimer;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>?>? _updatesSub;

  String _currentHost = '192.168.0.224';
  int _currentPort = 1883;
  bool _manualDisconnect = false;
  bool _isConnecting = false;

  DateTime? _lastMessageReceivedAt;
  int _reconnectAttempt = 0;
  int _packetsReceived = 0;
  String? _lastError;
  int _currentStep = 0;
  List<ConnectionStepInfo> _steps = const [];

  static const String topicTelemetry = 'hogar/solar/telemetria';
  static const String topicHistory = 'hogar/solar/historial_24h';
  static const String topicAlert = 'hogar/solar/alerta';
  static const String topicCommand = 'hogar/solar/comando';
  static const String topicStats = 'hogar/solar/estadisticas';

  final _telemetryController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _historyController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _alertController = StreamController<Map<String, dynamic>>.broadcast();
  final _statsController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController =
      StreamController<MqttConnectionStateStatus>.broadcast();
  final _diagnosticsController =
      StreamController<MqttDiagnosticsSnapshot>.broadcast();

  Stream<Map<String, dynamic>> get telemetryStream =>
      _telemetryController.stream;
  Stream<List<Map<String, dynamic>>> get historyStream =>
      _historyController.stream;
  Stream<Map<String, dynamic>> get alertStream => _alertController.stream;
  Stream<Map<String, dynamic>> get statsStream => _statsController.stream;
  Stream<MqttConnectionStateStatus> get connectionStream =>
      _connectionController.stream;
  Stream<MqttDiagnosticsSnapshot> get diagnosticsStream =>
      _diagnosticsController.stream;

  MqttConnectionStateStatus _status = MqttConnectionStateStatus.disconnected;
  MqttConnectionStateStatus get status => _status;

  MqttDiagnosticsSnapshot get currentDiagnostics => MqttDiagnosticsSnapshot(
        targetHost: _currentHost,
        targetPort: _currentPort,
        overallStatus: _status,
        currentStepIndex: _currentStep,
        reconnectAttempt: _reconnectAttempt,
        packetsReceived: _packetsReceived,
        lastPacketTime: _lastMessageReceivedAt,
        lastError: _lastError,
        steps: _steps.isEmpty ? _buildDefaultSteps() : _steps,
      );

  List<ConnectionStepInfo> _buildDefaultSteps() {
    return [
      ConnectionStepInfo(
        stepNumber: 1,
        title: '1. Verificación de Red Local',
        detail: 'Destino configurado: $_currentHost:$_currentPort',
        state: DiagnosticStepState.pending,
      ),
      ConnectionStepInfo(
        stepNumber: 2,
        title: '2. Alcance TCP al Servidor (MacBook)',
        detail: 'Probando puerto TCP $_currentPort en $_currentHost',
        state: DiagnosticStepState.pending,
      ),
      const ConnectionStepInfo(
        stepNumber: 3,
        title: '3. Sesión con Broker Mosquitto MQTT',
        detail: 'Esperando handshake de protocolo MQTT',
        state: DiagnosticStepState.pending,
      ),
      const ConnectionStepInfo(
        stepNumber: 4,
        title: '4. Suscripción a Canales del Inversor',
        detail: 'Canales: telemetria (1s), historial_24h, alerta',
        state: DiagnosticStepState.pending,
      ),
      const ConnectionStepInfo(
        stepNumber: 5,
        title: '5. Flujo de Datos en Tiempo Real (1 seg)',
        detail: 'Esperando primer paquete del inversor...',
        state: DiagnosticStepState.pending,
      ),
    ];
  }

  void _emitDiagnostics({
    required int step,
    required List<ConnectionStepInfo> steps,
    String? error,
  }) {
    _currentStep = step;
    _steps = steps;
    if (error != null) {
      _lastError = error;
    }
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(currentDiagnostics);
    }
  }

  Future<void> connect({
    required String host,
    int port = 1883,
  }) async {
    if (_isConnecting) return;
    _isConnecting = true;
    _reconnectTimer?.cancel();

    _currentHost = host.trim();
    _currentPort = port;
    _manualDisconnect = false;

    await _cleanupExistingClient();
    _updateStatus(
      _reconnectAttempt > 0
          ? MqttConnectionStateStatus.reconnecting
          : MqttConnectionStateStatus.connecting,
    );

    // PASO 1: Verificación de parámetros de red local
    _emitDiagnostics(
      step: 1,
      error: null,
      steps: [
        ConnectionStepInfo(
          stepNumber: 1,
          title: '1. Verificación de Red Local',
          detail: 'Conectando hacia $_currentHost:$_currentPort...',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 2,
          title: '2. Alcance TCP al Servidor (MacBook)',
          detail: 'Abriendo socket TCP a $_currentHost:$_currentPort...',
          state: DiagnosticStepState.inProgress,
        ),
        const ConnectionStepInfo(
          stepNumber: 3,
          title: '3. Sesión con Broker Mosquitto MQTT',
          detail: 'Pendiente de conexión TCP',
          state: DiagnosticStepState.pending,
        ),
        const ConnectionStepInfo(
          stepNumber: 4,
          title: '4. Suscripción a Canales del Inversor',
          detail: 'Pendiente de sesión MQTT',
          state: DiagnosticStepState.pending,
        ),
        const ConnectionStepInfo(
          stepNumber: 5,
          title: '5. Flujo de Datos en Tiempo Real (1 seg)',
          detail: 'Esperando conexión...',
          state: DiagnosticStepState.pending,
        ),
      ],
    );

    // PASO 2: Prueba rápida de socket TCP para diagnosticar si la IP es alcanzable
    final sw = Stopwatch()..start();
    try {
      final testSocket = await Socket.connect(
        _currentHost,
        _currentPort,
        timeout: const Duration(milliseconds: 2500),
      );
      await testSocket.close();
      sw.stop();
    } catch (e) {
      sw.stop();
      _isConnecting = false;
      final friendlyErr =
          'No se alcanza la IP $_currentHost:$_currentPort (${e.runtimeType}). '
          'Verifica que: (1) el celular y la Mac estén en el mismo Wi-Fi, '
          '(2) la IP en Configuración (⚙️) sea la de tu Mac, y '
          '(3) el servidor esté encendido en la Mac.';
      _emitDiagnostics(
        step: 2,
        error: friendlyErr,
        steps: [
          ConnectionStepInfo(
            stepNumber: 1,
            title: '1. Verificación de Red Local',
            detail: 'Red activa en el dispositivo • Destino: $_currentHost',
            state: DiagnosticStepState.completed,
          ),
          ConnectionStepInfo(
            stepNumber: 2,
            title: '2. Alcance TCP al Servidor (MacBook)',
            detail:
                'FALLÓ: Sin respuesta en $_currentHost:$_currentPort tras ${sw.elapsedMilliseconds}ms',
            state: DiagnosticStepState.failed,
          ),
          const ConnectionStepInfo(
            stepNumber: 3,
            title: '3. Sesión con Broker Mosquitto MQTT',
            detail: 'Bloqueado por falta de alcance TCP en Paso 2',
            state: DiagnosticStepState.pending,
          ),
          const ConnectionStepInfo(
            stepNumber: 4,
            title: '4. Suscripción a Canales del Inversor',
            detail: 'Pendiente',
            state: DiagnosticStepState.pending,
          ),
          const ConnectionStepInfo(
            stepNumber: 5,
            title: '5. Flujo de Datos en Tiempo Real (1 seg)',
            detail: 'Sin datos',
            state: DiagnosticStepState.pending,
          ),
        ],
      );
      _scheduleControlledReconnect();
      return;
    }

    final tcpPingMs = sw.elapsedMilliseconds;

    // PASO 3: Handshake MQTT con Mosquitto
    _emitDiagnostics(
      step: 3,
      steps: [
        ConnectionStepInfo(
          stepNumber: 1,
          title: '1. Verificación de Red Local',
          detail: 'Red Wi-Fi lista • Destino: $_currentHost',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 2,
          title: '2. Alcance TCP al Servidor (MacBook)',
          detail: 'Servidor alcanzado en ${tcpPingMs}ms (Puerto $_currentPort abierto)',
          state: DiagnosticStepState.completed,
        ),
        const ConnectionStepInfo(
          stepNumber: 3,
          title: '3. Sesión con Broker Mosquitto MQTT',
          detail: 'Negociando sesión MQTT con Mosquitto...',
          state: DiagnosticStepState.inProgress,
        ),
        const ConnectionStepInfo(
          stepNumber: 4,
          title: '4. Suscripción a Canales del Inversor',
          detail: 'Pendiente',
          state: DiagnosticStepState.pending,
        ),
        const ConnectionStepInfo(
          stepNumber: 5,
          title: '5. Flujo de Datos en Tiempo Real (1 seg)',
          detail: 'Pendiente',
          state: DiagnosticStepState.pending,
        ),
      ],
    );

    final uniqueClientId =
        'solar_familia_${Random().nextInt(999999).toString().padLeft(6, '0')}';

    final client =
        MqttServerClient.withPort(_currentHost, uniqueClientId, _currentPort);
    client.logging(on: false);
    client.keepAlivePeriod = 15;
    client.connectTimeoutPeriod = 3000;
    // Desactivar autoReconnect interno para evitar tormentas exponenciales de timers
    client.autoReconnect = false;

    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(uniqueClientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    client.connectionMessage = connMessage;

    _client = client;

    try {
      await client.connect();
    } catch (e) {
      _isConnecting = false;
      final errStr = 'Fallo en protocolo MQTT ($_currentHost:$_currentPort): $e';
      _emitDiagnostics(
        step: 3,
        error: errStr,
        steps: [
          ConnectionStepInfo(
            stepNumber: 1,
            title: '1. Verificación de Red Local',
            detail: 'Red Wi-Fi lista',
            state: DiagnosticStepState.completed,
          ),
          ConnectionStepInfo(
            stepNumber: 2,
            title: '2. Alcance TCP al Servidor (MacBook)',
            detail: 'Puerto $_currentPort abierto (${tcpPingMs}ms)',
            state: DiagnosticStepState.completed,
          ),
          ConnectionStepInfo(
            stepNumber: 3,
            title: '3. Sesión con Broker Mosquitto MQTT',
            detail: 'FALLÓ handshake MQTT: $e',
            state: DiagnosticStepState.failed,
          ),
          const ConnectionStepInfo(
            stepNumber: 4,
            title: '4. Suscripción a Canales del Inversor',
            detail: 'Pendiente',
            state: DiagnosticStepState.pending,
          ),
          const ConnectionStepInfo(
            stepNumber: 5,
            title: '5. Flujo de Datos en Tiempo Real (1 seg)',
            detail: 'Pendiente',
            state: DiagnosticStepState.pending,
          ),
        ],
      );
      _scheduleControlledReconnect();
      return;
    }

    _isConnecting = false;

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      _reconnectAttempt = 0;
      _lastError = null;
      _setupSubscriptions(tcpPingMs: tcpPingMs);
      _startWatchdog();
    } else {
      _scheduleControlledReconnect();
    }
  }

  void _setupSubscriptions({int tcpPingMs = 5}) {
    final client = _client;
    if (client == null) return;

    client.subscribe(topicTelemetry, MqttQos.atMostOnce);
    client.subscribe(topicHistory, MqttQos.atLeastOnce);
    client.subscribe(topicAlert, MqttQos.atLeastOnce);
    client.subscribe(topicStats, MqttQos.atLeastOnce);

    _emitDiagnostics(
      step: 5,
      error: null,
      steps: [
        ConnectionStepInfo(
          stepNumber: 1,
          title: '1. Verificación de Red Local',
          detail: 'Conectado a $_currentHost:$_currentPort',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 2,
          title: '2. Alcance TCP al Servidor (MacBook)',
          detail: 'Latencia de red local: ${tcpPingMs}ms',
          state: DiagnosticStepState.completed,
        ),
        const ConnectionStepInfo(
          stepNumber: 3,
          title: '3. Sesión con Broker Mosquitto MQTT',
          detail: 'Sesión MQTT establecida y activa',
          state: DiagnosticStepState.completed,
        ),
        const ConnectionStepInfo(
          stepNumber: 4,
          title: '4. Suscripción a Canales del Inversor',
          detail: 'Suscrito a telemetria (1s), historial_24h y alerta',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 5,
          title: '5. Flujo de Datos en Tiempo Real (1 seg)',
          detail: _packetsReceived > 0
              ? 'Recibiendo datos cada 1s ($_packetsReceived paquetes)'
              : 'Esperando primer paquete de solar_monitor.py...',
          state: _packetsReceived > 0
              ? DiagnosticStepState.completed
              : DiagnosticStepState.inProgress,
        ),
      ],
    );

    _updatesSub?.cancel();
    _updatesSub = client.updates?.listen(
      (List<MqttReceivedMessage<MqttMessage?>>? events) {
        if (events == null || events.isEmpty) return;

        for (final event in events) {
          final pubMessage = event.payload as MqttPublishMessage?;
          if (pubMessage == null) continue;

          final payloadString = MqttPublishPayload.bytesToStringAsString(
            pubMessage.payload.message,
          );
          _lastMessageReceivedAt = DateTime.now();
          _packetsReceived++;

          try {
            final decoded = jsonDecode(payloadString) as Map<String, dynamic>;
            if (event.topic == topicTelemetry) {
              _telemetryController.add(decoded);
              // Actualizar diagnóstico del paso 5 sin sobrecargar
              if (_packetsReceived == 1 || _packetsReceived % 5 == 0) {
                final src = decoded['source_mode'] ?? 'Inversor';
                _emitDiagnostics(
                  step: 5,
                  error: null,
                  steps: [
                    ConnectionStepInfo(
                      stepNumber: 1,
                      title: '1. Verificación de Red Local',
                      detail: 'Conectado a $_currentHost:$_currentPort',
                      state: DiagnosticStepState.completed,
                    ),
                    ConnectionStepInfo(
                      stepNumber: 2,
                      title: '2. Alcance TCP al Servidor (MacBook)',
                      detail: 'Socket TCP estable en puerto $_currentPort',
                      state: DiagnosticStepState.completed,
                    ),
                    const ConnectionStepInfo(
                      stepNumber: 3,
                      title: '3. Sesión con Broker Mosquitto MQTT',
                      detail: 'Broker Mosquitto respondiendo OK',
                      state: DiagnosticStepState.completed,
                    ),
                    const ConnectionStepInfo(
                      stepNumber: 4,
                      title: '4. Suscripción a Canales del Inversor',
                      detail: 'Canales activos: telemetria, historial_24h',
                      state: DiagnosticStepState.completed,
                    ),
                    ConnectionStepInfo(
                      stepNumber: 5,
                      title: '5. Flujo de Datos en Tiempo Real (1 seg)',
                      detail:
                          'Activo • $_packetsReceived lecturas recibidas ($src)',
                      state: DiagnosticStepState.completed,
                    ),
                  ],
                );
              }
            } else if (event.topic == topicHistory) {
              final pointsRaw = decoded['points'] as List<dynamic>? ?? [];
              final points = pointsRaw
                  .whereType<Map<String, dynamic>>()
                  .toList(growable: false);
              _historyController.add(points);
            } else if (event.topic == topicAlert) {
              _alertController.add(decoded);
            } else if (event.topic == topicStats) {
              _statsController.add(decoded);
            }
          } catch (e) {
            debugPrint('Error decodificando JSON de ${event.topic}: $e');
          }
        }
      },
    );

    sendCommand('GET_HISTORY');
  }

  void sendCommand(String command) {
    final client = _client;
    if (client?.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(command);
    client!.publishMessage(
      topicCommand,
      MqttQos.atMostOnce,
      builder.payload!,
    );
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_manualDisconnect || _isConnecting) return;
      final lastRx = _lastMessageReceivedAt;
      if (lastRx != null &&
          DateTime.now().difference(lastRx).inSeconds > 15 &&
          _status == MqttConnectionStateStatus.connected) {
        _lastError =
            'El broker MQTT está conectado pero solar_monitor.py no envió datos en 15s.';
        connect(host: _currentHost, port: _currentPort);
      }
    });
  }

  void _onConnected() {
    _lastMessageReceivedAt = DateTime.now();
    _updateStatus(MqttConnectionStateStatus.connected);
  }

  void _onDisconnected() {
    if (_manualDisconnect) {
      _updateStatus(MqttConnectionStateStatus.disconnected);
      return;
    }
    _scheduleControlledReconnect();
  }

  void _scheduleControlledReconnect() {
    if (_manualDisconnect) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    _updateStatus(MqttConnectionStateStatus.reconnecting);

    // Backoff suave de 3 segundos (un único timer activo a la vez)
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_manualDisconnect &&
          _status != MqttConnectionStateStatus.connected &&
          !_isConnecting) {
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
    await _updatesSub?.cancel();
    _updatesSub = null;
    final oldClient = _client;
    _client = null;
    if (oldClient != null) {
      oldClient.onDisconnected = null;
      oldClient.onConnected = null;
      try {
        oldClient.disconnect();
      } catch (_) {}
    }
  }

  Future<void> disconnectManual() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _cleanupExistingClient();
    _updateStatus(MqttConnectionStateStatus.disconnected);
  }

  Future<void> dispose() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _cleanupExistingClient();
    await _telemetryController.close();
    await _historyController.close();
    await _alertController.close();
    await _statsController.close();
    await _connectionController.close();
    await _diagnosticsController.close();
  }
}
