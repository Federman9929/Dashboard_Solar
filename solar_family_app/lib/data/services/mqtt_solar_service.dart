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
    this.isCloudConnection = false,
    this.cloudConfigured = false,
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
  final bool isCloudConnection;
  final bool cloudConfigured;
}

class _MqttEndpoint {
  const _MqttEndpoint({
    required this.host,
    required this.port,
    required this.isCloud,
    required this.useTls,
    required this.username,
    required this.password,
    required this.tcpTimeout,
  });

  final String host;
  final int port;
  final bool isCloud;
  final bool useTls;
  final String username;
  final String password;
  final Duration tcpTimeout;

  String get routeLabel => isCloud ? 'Nube TLS' : 'Red Local';
}

/// Servicio de conectividad MQTT ultra-ligero con failover automático:
/// intenta primero la IP local en Wi-Fi (latencia 0) y, si cambia de router
/// o está fuera de casa, conmuta automáticamente al broker seguro en la nube.
class MqttSolarService {
  MqttServerClient? _client;
  Timer? _watchdogTimer;
  Timer? _reconnectTimer;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>?>? _updatesSub;

  String _localHost = '192.168.0.224';
  int _localPort = 1883;
  String _cloudHost = '';
  int _cloudPort = 8883;
  String _cloudUsername = '';
  String _cloudPassword = '';
  bool _cloudUseTls = true;

  String _currentHost = '192.168.0.224';
  int _currentPort = 1883;
  bool _usingCloud = false;

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
  bool get isUsingCloud => _usingCloud;

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
        isCloudConnection: _usingCloud,
        cloudConfigured: _cloudHost.isNotEmpty,
      );

  List<ConnectionStepInfo> _buildDefaultSteps() {
    final route = _usingCloud ? 'Nube TLS' : 'Red Local';
    return [
      ConnectionStepInfo(
        stepNumber: 1,
        title: '1. Verificación de Ruta ($route)',
        detail: 'Destino configurado: $_currentHost:$_currentPort',
        state: DiagnosticStepState.pending,
      ),
      ConnectionStepInfo(
        stepNumber: 2,
        title: '2. Alcance TCP al Servidor',
        detail: 'Probando puerto TCP $_currentPort en $_currentHost',
        state: DiagnosticStepState.pending,
      ),
      const ConnectionStepInfo(
        stepNumber: 3,
        title: '3. Sesión con Broker MQTT',
        detail: 'Esperando handshake de protocolo MQTT',
        state: DiagnosticStepState.pending,
      ),
      const ConnectionStepInfo(
        stepNumber: 4,
        title: '4. Suscripción a Canales del Inversor',
        detail: 'Canales: telemetria (1s), historial_24h, alerta, ahorro',
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
    _lastError = error;
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(currentDiagnostics);
    }
  }

  Future<void> connect({
    required String host,
    int port = 1883,
    String? cloudHost,
    int? cloudPort,
    String? cloudUsername,
    String? cloudPassword,
    bool? cloudUseTls,
  }) async {
    if (_isConnecting) return;
    _isConnecting = true;
    _reconnectTimer?.cancel();

    _localHost = host.trim();
    _localPort = port;
    if (cloudHost != null) _cloudHost = cloudHost.trim();
    if (cloudPort != null) _cloudPort = cloudPort;
    if (cloudUsername != null) _cloudUsername = cloudUsername.trim();
    if (cloudPassword != null) _cloudPassword = cloudPassword;
    if (cloudUseTls != null) _cloudUseTls = cloudUseTls;

    _manualDisconnect = false;
    await _cleanupExistingClient();

    _updateStatus(
      _reconnectAttempt > 0
          ? MqttConnectionStateStatus.reconnecting
          : MqttConnectionStateStatus.connecting,
    );

    final hasCloud = _cloudHost.isNotEmpty;
    final endpoints = <_MqttEndpoint>[
      if (_localHost.isNotEmpty)
        _MqttEndpoint(
          host: _localHost,
          port: _localPort,
          isCloud: false,
          useTls: false,
          username: '',
          password: '',
          tcpTimeout: Duration(milliseconds: hasCloud ? 1100 : 2500),
        ),
      if (hasCloud)
        _MqttEndpoint(
          host: _cloudHost,
          port: _cloudPort,
          isCloud: true,
          useTls: _cloudUseTls,
          username: _cloudUsername,
          password: _cloudPassword,
          tcpTimeout: const Duration(milliseconds: 3000),
        ),
    ];

    if (endpoints.isEmpty) {
      _isConnecting = false;
      _emitDiagnostics(
        step: 1,
        error: 'No hay servidor MQTT configurado.',
        steps: _buildDefaultSteps(),
      );
      return;
    }

    for (var i = 0; i < endpoints.length; i++) {
      final endpoint = endpoints[i];
      final hasFallback = i + 1 < endpoints.length;
      final connected = await _tryConnectEndpoint(
        endpoint,
        hasFallback: hasFallback,
      );
      if (connected || _manualDisconnect) {
        _isConnecting = false;
        return;
      }
    }

    _isConnecting = false;
    _scheduleControlledReconnect();
  }

  Future<void> reconnectUsingSavedEndpoints() async {
    await connect(host: _localHost, port: _localPort);
  }

  Future<bool> _tryConnectEndpoint(
    _MqttEndpoint endpoint, {
    required bool hasFallback,
  }) async {
    _currentHost = endpoint.host;
    _currentPort = endpoint.port;
    _usingCloud = endpoint.isCloud;

    // PASO 1 y 2: Prueba rápida de alcance TCP
    _emitDiagnostics(
      step: 2,
      error: null,
      steps: [
        ConnectionStepInfo(
          stepNumber: 1,
          title: '1. Verificación de Ruta (${endpoint.routeLabel})',
          detail: 'Probando ${endpoint.host}:${endpoint.port}...',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 2,
          title: '2. Alcance TCP (${endpoint.routeLabel})',
          detail: 'Abriendo socket TCP a ${endpoint.host}:${endpoint.port}...',
          state: DiagnosticStepState.inProgress,
        ),
        const ConnectionStepInfo(
          stepNumber: 3,
          title: '3. Sesión con Broker MQTT',
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

    final sw = Stopwatch()..start();
    try {
      final testSocket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: endpoint.tcpTimeout,
      );
      await testSocket.close();
      sw.stop();
    } catch (e) {
      sw.stop();
      if (hasFallback) {
        _emitDiagnostics(
          step: 2,
          error:
              'Red local $_localHost no disponible en este router; cambiando a Nube TLS...',
          steps: _steps,
        );
        return false;
      }
      final friendlyErr = endpoint.isCloud
          ? 'Sin conexión al broker Nube ${endpoint.host}:${endpoint.port} (${e.runtimeType}). Revisa tu acceso a internet o las credenciales.'
          : 'No se alcanza la IP ${endpoint.host}:${endpoint.port} (${e.runtimeType}). '
              'Si cambiaste de router o saliste de casa, configura Conexión Remota (Nube TLS) en Ajustes (⚙️).';
      _emitDiagnostics(
        step: 2,
        error: friendlyErr,
        steps: [
          ConnectionStepInfo(
            stepNumber: 1,
            title: '1. Verificación de Ruta (${endpoint.routeLabel})',
            detail: 'Destino: ${endpoint.host}:${endpoint.port}',
            state: DiagnosticStepState.completed,
          ),
          ConnectionStepInfo(
            stepNumber: 2,
            title: '2. Alcance TCP (${endpoint.routeLabel})',
            detail:
                'FALLÓ: Sin respuesta en ${endpoint.host}:${endpoint.port} (${sw.elapsedMilliseconds}ms)',
            state: DiagnosticStepState.failed,
          ),
          const ConnectionStepInfo(
            stepNumber: 3,
            title: '3. Sesión con Broker MQTT',
            detail: 'Bloqueado por falta de alcance TCP',
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
      return false;
    }

    final tcpPingMs = sw.elapsedMilliseconds;

    // PASO 3: Handshake MQTT (plano local o TLS nube)
    _emitDiagnostics(
      step: 3,
      steps: [
        ConnectionStepInfo(
          stepNumber: 1,
          title: '1. Verificación de Ruta (${endpoint.routeLabel})',
          detail: 'Ruta activa • Destino: ${endpoint.host}',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 2,
          title: '2. Alcance TCP (${endpoint.routeLabel})',
          detail: 'Alcanzado en ${tcpPingMs}ms (Puerto ${endpoint.port})',
          state: DiagnosticStepState.completed,
        ),
        ConnectionStepInfo(
          stepNumber: 3,
          title: '3. Sesión con Broker MQTT',
          detail: endpoint.useTls
              ? 'Negociando sesión TLS segura...'
              : 'Negociando sesión MQTT con Mosquitto...',
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

    final client = MqttServerClient.withPort(
      endpoint.host,
      uniqueClientId,
      endpoint.port,
    );
    client.logging(on: false);
    client.keepAlivePeriod = 10;
    client.connectTimeoutPeriod = 3500;
    client.autoReconnect = false;

    if (endpoint.useTls) {
      client.secure = true;
      client.securityContext = SecurityContext.defaultContext;
    }

    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(uniqueClientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    client.connectionMessage = connMessage;

    _client = client;

    try {
      await client.connect(
        endpoint.username.isEmpty ? null : endpoint.username,
        endpoint.password.isEmpty ? null : endpoint.password,
      );
    } catch (e) {
      await _cleanupExistingClient();
      if (!hasFallback) {
        _emitDiagnostics(
          step: 3,
          error:
              'Fallo en protocolo MQTT (${endpoint.host}:${endpoint.port}): $e',
          steps: [
            ConnectionStepInfo(
              stepNumber: 1,
              title: '1. Verificación de Ruta (${endpoint.routeLabel})',
              detail: 'Red activa',
              state: DiagnosticStepState.completed,
            ),
            ConnectionStepInfo(
              stepNumber: 2,
              title: '2. Alcance TCP (${endpoint.routeLabel})',
              detail: 'Puerto ${endpoint.port} abierto (${tcpPingMs}ms)',
              state: DiagnosticStepState.completed,
            ),
            ConnectionStepInfo(
              stepNumber: 3,
              title: '3. Sesión con Broker MQTT',
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
      }
      return false;
    }

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      _reconnectAttempt = 0;
      _lastError = null;
      _setupSubscriptions(tcpPingMs: tcpPingMs, endpoint: endpoint);
      _startWatchdog();
      return true;
    }

    await _cleanupExistingClient();
    return false;
  }

  void _setupSubscriptions({
    required int tcpPingMs,
    required _MqttEndpoint endpoint,
  }) {
    final client = _client;
    if (client == null) return;

    client.subscribe(topicTelemetry, MqttQos.atMostOnce);
    client.subscribe(topicHistory, MqttQos.atLeastOnce);
    client.subscribe(topicAlert, MqttQos.atLeastOnce);
    client.subscribe(topicStats, MqttQos.atLeastOnce);

    _emitDiagnostics(
      step: 5,
      error: null,
      steps: _buildConnectedSteps(
        endpoint: endpoint,
        tcpPingMs: tcpPingMs,
        step5Detail: _packetsReceived > 0
            ? 'Recibiendo datos cada 1s ($_packetsReceived paquetes)'
            : 'Esperando primer paquete del servidor...',
        step5Done: _packetsReceived > 0,
      ),
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
              if (_packetsReceived == 1 || _packetsReceived % 5 == 0) {
                final src = decoded['source_mode'] ?? 'Inversor';
                _emitDiagnostics(
                  step: 5,
                  error: null,
                  steps: _buildConnectedSteps(
                    endpoint: endpoint,
                    tcpPingMs: tcpPingMs,
                    step5Detail:
                        'Activo (${endpoint.routeLabel}) • $_packetsReceived lecturas ($src)',
                    step5Done: true,
                  ),
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

  List<ConnectionStepInfo> _buildConnectedSteps({
    required _MqttEndpoint endpoint,
    required int tcpPingMs,
    required String step5Detail,
    required bool step5Done,
  }) {
    return [
      ConnectionStepInfo(
        stepNumber: 1,
        title: '1. Verificación de Ruta (${endpoint.routeLabel})',
        detail: 'Conectado a ${endpoint.host}:${endpoint.port}',
        state: DiagnosticStepState.completed,
      ),
      ConnectionStepInfo(
        stepNumber: 2,
        title: '2. Alcance TCP (${endpoint.routeLabel})',
        detail: 'Latencia de red: ${tcpPingMs}ms',
        state: DiagnosticStepState.completed,
      ),
      ConnectionStepInfo(
        stepNumber: 3,
        title: '3. Sesión con Broker MQTT',
        detail: endpoint.useTls
            ? 'Sesión TLS segura establecida'
            : 'Sesión MQTT local establecida',
        state: DiagnosticStepState.completed,
      ),
      const ConnectionStepInfo(
        stepNumber: 4,
        title: '4. Suscripción a Canales del Inversor',
        detail: 'Canales: telemetria (1s), historial_24h, alerta, ahorro',
        state: DiagnosticStepState.completed,
      ),
      ConnectionStepInfo(
        stepNumber: 5,
        title: '5. Flujo de Datos en Tiempo Real (1 seg)',
        detail: step5Detail,
        state: step5Done
            ? DiagnosticStepState.completed
            : DiagnosticStepState.inProgress,
      ),
    ];
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
    _watchdogTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_manualDisconnect || _isConnecting) return;
      final lastRx = _lastMessageReceivedAt;
      if (lastRx != null &&
          DateTime.now().difference(lastRx).inSeconds > 7 &&
          _status == MqttConnectionStateStatus.connected) {
        _lastError =
            'Sin paquetes durante >7s; reconectando automáticamente...';
        reconnectUsingSavedEndpoints();
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

    final delayMs = _reconnectAttempt <= 2 ? 1500 : 3000;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_manualDisconnect &&
          _status != MqttConnectionStateStatus.connected &&
          !_isConnecting) {
        reconnectUsingSavedEndpoints();
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
