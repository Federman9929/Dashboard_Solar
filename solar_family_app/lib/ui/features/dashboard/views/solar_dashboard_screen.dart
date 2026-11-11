import 'package:flutter/material.dart';

import 'package:solar_family_monitor/data/services/mqtt_solar_service.dart';
import 'package:solar_family_monitor/domain/models/solar_reading.dart';
import 'package:solar_family_monitor/ui/features/dashboard/view_models/solar_dashboard_view_model.dart';
import 'widgets/interactive_solar_chart.dart';

class SolarDashboardScreen extends StatelessWidget {
  const SolarDashboardScreen({super.key, required this.viewModel});

  final SolarDashboardViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final reading = viewModel.currentReading;
        final criticalAlert = viewModel.activeCriticalAlert;
        final threshold = viewModel.criticalSocThreshold;
        final selectedChart = viewModel.selectedChartIndex;

        return Scaffold(
          backgroundColor: const Color(0xFF0B101B),
          appBar: AppBar(
            backgroundColor: const Color(0xFF111927),
            elevation: 0,
            titleSpacing: 12,
            title: Row(
              children: [
                const Icon(
                  Icons.wb_sunny_rounded,
                  color: Color(0xFFFFB300),
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Monitor Solar',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                _buildConnectionBadge(
                  context: context,
                  status: viewModel.connectionStatus,
                  demoMode: viewModel.demoMode,
                  diagnostics: viewModel.diagnostics,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip:
                    'Probar Notificación (<${threshold.toStringAsFixed(0)}%)',
                icon: const Icon(
                  Icons.notifications_none_rounded,
                  color: Color(0xFFFFB300),
                ),
                onPressed: viewModel.triggerTestCriticalAlert,
              ),
              IconButton(
                tooltip: 'Configurar Broker MacBook / Alertas',
                icon: const Icon(Icons.settings_rounded, color: Colors.white70),
                onPressed: () => _openSettingsSheet(context),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (criticalAlert != null)
                  _buildSimpleAlertBanner(criticalAlert, threshold),

                if (reading != null)
                  _buildPersistentNotificationPreviewBar(reading, threshold),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (reading != null) ...[
                          _buildPrimaryTelemetryGrid(reading, threshold),
                          const SizedBox(height: 12),
                          _buildThresholdSetpointCard(threshold),
                          const SizedBox(height: 16),
                        ],

                        // Renderizar ÚNICAMENTE la gráfica seleccionada para
                        // reducir el consumo de CPU/GPU en un 70% y evitar calentamiento
                        RepaintBoundary(
                          child: _buildSelectedChart(
                            selectedIndex: selectedChart,
                            threshold: threshold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: _buildMinimalIconChartSelector(selectedChart),
        );
      },
    );
  }

  /// Renderiza únicamente 1 gráfica activa según el ícono seleccionado abajo:
  /// 0 = Batería (%), 1 = Generación PV (W), 2 = Carga de la Casa (W)
  Widget _buildSelectedChart({
    required int selectedIndex,
    required double threshold,
  }) {
    switch (selectedIndex) {
      case 0:
        return InteractiveSolarChart(
          key: const ValueKey('chart_battery'),
          title: 'Nivel de Batería (SOC %)',
          subtitle:
              'Historial 24h y umbral configurado en ${threshold.toStringAsFixed(0)}%',
          unit: '%',
          readings: viewModel.history24h,
          valueSelector: (r) => r.batterySoc,
          lineColor: const Color(0xFF00E676),
          gradientColor: const Color(0xFF00C853),
          minY: 0,
          maxY: 100,
          thresholdY: threshold,
          thresholdLabel: 'Umbral ${threshold.toStringAsFixed(0)}%',
          showSecondsInTooltip: false,
        );
      case 1:
        return InteractiveSolarChart(
          key: const ValueKey('chart_pv'),
          title: 'Generación Solar PV (Tiempo Real 1s)',
          subtitle: 'Potencia entregada por los paneles solares segundo a segundo',
          unit: 'W',
          readings: viewModel.realtimeReadings,
          valueSelector: (r) => r.pvPowerW,
          lineColor: const Color(0xFFFFB300),
          gradientColor: const Color(0xFFFF8F00),
          minY: 0,
          showSecondsInTooltip: true,
        );
      case 2:
      default:
        return InteractiveSolarChart(
          key: const ValueKey('chart_load'),
          title: 'Carga / Consumo de la Casa (Tiempo Real 1s)',
          subtitle: 'Potencia consumida por el hogar segundo a segundo',
          unit: 'W',
          readings: viewModel.realtimeReadings,
          valueSelector: (r) => r.loadPowerW,
          lineColor: const Color(0xFF40C4FF),
          gradientColor: const Color(0xFF00B0FF),
          minY: 0,
          showSecondsInTooltip: true,
        );
    }
  }

  /// Selector inferior minimalista de gráficas: SOLO ÍCONOS (sin texto)
  /// [Batería] • [Paneles PV] • [Carga Casa]
  Widget _buildMinimalIconChartSelector(int selectedIndex) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111927),
        border: Border(
          top: BorderSide(color: Colors.white12, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildChartIconButton(
                index: 0,
                selectedIndex: selectedIndex,
                icon: Icons.battery_charging_full_rounded,
                activeColor: const Color(0xFF00E676),
              ),
              _buildChartIconButton(
                index: 1,
                selectedIndex: selectedIndex,
                icon: Icons.wb_sunny_rounded,
                activeColor: const Color(0xFFFFB300),
              ),
              _buildChartIconButton(
                index: 2,
                selectedIndex: selectedIndex,
                icon: Icons.home_rounded,
                activeColor: const Color(0xFF40C4FF),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChartIconButton({
    required int index,
    required int selectedIndex,
    required IconData icon,
    required Color activeColor,
  }) {
    final isSelected = index == selectedIndex;
    return InkWell(
      onTap: () => viewModel.selectChart(index),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withOpacity(0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? activeColor.withOpacity(0.6)
                : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Icon(
          icon,
          size: 26,
          color: isSelected ? activeColor : Colors.white38,
        ),
      ),
    );
  }

  /// Botón interactivo de estado de conexión: al tocarlo abre la ventana
  /// de diagnóstico paso a paso para saber exactamente en qué paso va.
  Widget _buildConnectionBadge({
    required BuildContext context,
    required MqttConnectionStateStatus status,
    required bool demoMode,
    required MqttDiagnosticsSnapshot diagnostics,
  }) {
    final (String label, Color color) = demoMode
        ? ('MODO DEMO', const Color(0xFF448AFF))
        : switch (status) {
            MqttConnectionStateStatus.connected => (
                'EN LÍNEA (1s)',
                const Color(0xFF00E676)
              ),
            MqttConnectionStateStatus.connecting ||
            MqttConnectionStateStatus.reconnecting =>
              (
                'PASO ${diagnostics.currentStepIndex}/5...',
                const Color(0xFFFFB300)
              ),
            MqttConnectionStateStatus.disconnected => (
                'SIN RED',
                const Color(0xFFFF5252)
              ),
          };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openConnectionDiagnosticsDialog(context),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.7)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.info_outline_rounded,
                size: 13,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Ventana emergente en vivo que desglosa todas las conexiones y muestra
  /// en qué paso exacto va si está reconectando o dónde ocurrió un fallo.
  void _openConnectionDiagnosticsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: viewModel,
          builder: (ctx, _) {
            final diag = viewModel.diagnostics;
            final isDemo = viewModel.demoMode;
            final lastRxStr = diag.lastPacketTime != null
                ? '${diag.lastPacketTime!.hour.toString().padLeft(2, '0')}:'
                    '${diag.lastPacketTime!.minute.toString().padLeft(2, '0')}:'
                    '${diag.lastPacketTime!.second.toString().padLeft(2, '0')}'
                : 'Ninguno aún';

            return AlertDialog(
              backgroundColor: const Color(0xFF141D2E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Colors.white12),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              title: Row(
                children: [
                  const Icon(
                    Icons.hub_rounded,
                    color: Color(0xFF40C4FF),
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Diagnóstico de Conexión',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1522),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isDemo
                                ? 'Modo actual: Simulador Local en Celular'
                                : 'Servidor destino: ${diag.targetHost}:${diag.targetPort}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Paquetes 1s recibidos: ${diag.packetsReceived}  •  Último: $lastRxStr',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                          if (diag.reconnectAttempt > 0 && !isDemo) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Intentos de reconexión: #${diag.reconnectAttempt}',
                              style: const TextStyle(
                                color: Color(0xFFFFB300),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Lista de los 5 pasos de conexión en tiempo real
                    ...diag.steps.map(_buildDiagnosticStepTile),

                    if (diag.lastError != null && !isDemo) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF5252).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFFFF5252).withOpacity(0.5),
                          ),
                        ),
                        child: Text(
                          '⚠️ Causa detectada:\n${diag.lastError}',
                          style: const TextStyle(
                            color: Color(0xFFFF8A80),
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              actions: [
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openSettingsSheet(context);
                  },
                  icon: const Icon(Icons.settings_rounded, size: 16),
                  label: const Text('Cambiar IP'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () => viewModel.retryConnectionNow(),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Reintentar Ahora'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDiagnosticStepTile(ConnectionStepInfo step) {
    final (IconData icon, Color color) = switch (step.state) {
      DiagnosticStepState.completed => (
          Icons.check_circle_rounded,
          const Color(0xFF00E676)
        ),
      DiagnosticStepState.inProgress => (
          Icons.sync_rounded,
          const Color(0xFFFFB300)
        ),
      DiagnosticStepState.failed => (
          Icons.error_rounded,
          const Color(0xFFFF5252)
        ),
      DiagnosticStepState.pending => (
          Icons.radio_button_unchecked_rounded,
          Colors.white24
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: TextStyle(
                    color: step.state == DiagnosticStepState.pending
                        ? Colors.white54
                        : Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  step.detail,
                  style: TextStyle(
                    color: step.state == DiagnosticStepState.failed
                        ? const Color(0xFFFF8A80)
                        : Colors.white60,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleAlertBanner(SolarReading alertReading, double threshold) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2C221E),
        border: Border(
          bottom: BorderSide(
            color: const Color(0xFFFFB300).withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.notifications_active_outlined,
            color: Color(0xFFFFB300),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aviso: Batería en ${alertReading.batterySoc.toStringAsFixed(1)}% (Umbral: ${threshold.toStringAsFixed(0)}%)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                Text(
                  'Voltaje: ${alertReading.batteryVoltage.toStringAsFixed(1)}V • Consumo: ${alertReading.loadPowerW.toStringAsFixed(0)}W',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFFFB300),
            ),
            onPressed: viewModel.silenceCriticalAlert,
            child: const Text(
              'OK',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersistentNotificationPreviewBar(
    SolarReading reading,
    double threshold,
  ) {
    final isGreen = reading.isHealthyForThreshold(threshold);
    final indicatorColor =
        isGreen ? const Color(0xFF00E676) : const Color(0xFFFF1744);
    final timeStr =
        '${reading.timestamp.hour.toString().padLeft(2, '0')}:'
        '${reading.timestamp.minute.toString().padLeft(2, '0')}:'
        '${reading.timestamp.second.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141C2B),
        border: Border(
          bottom: BorderSide(color: indicatorColor.withOpacity(0.4), width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: indicatorColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${reading.batterySoc.toStringAsFixed(1)}% • ${reading.status.displayName.toUpperCase()} (${reading.batteryVoltage.toStringAsFixed(2)}V)',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '⏱ $timeStr',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryTelemetryGrid(SolarReading reading, double threshold) {
    final isGreen = reading.isHealthyForThreshold(threshold);
    final statusColor =
        isGreen ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    final cleanSource = reading.sourceMode.contains('Casa_Falla')
        ? 'Casa_Falla (1s)'
        : reading.sourceMode;

    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildMetricCard(
                  title: 'BATERÍA (SOC)',
                  value: '${reading.batterySoc.toStringAsFixed(1)}%',
                  subtitle:
                      'Voltaje: ${reading.batteryVoltage.toStringAsFixed(2)} V',
                  icon: Icons.battery_charging_full_rounded,
                  accentColor: statusColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  title: 'PANELES SOLARES',
                  value: '${reading.pvPowerW.toStringAsFixed(1)} W',
                  subtitle: 'Generación PV actual',
                  icon: Icons.solar_power_rounded,
                  accentColor: const Color(0xFFFFB300),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildMetricCard(
                  title: 'FLUJO DE BATERÍA',
                  value: reading.status == SolarSystemStatus.charging
                      ? '+${reading.batteryChargeW.toStringAsFixed(1)} W'
                      : reading.status == SolarSystemStatus.discharging
                          ? '-${reading.batteryDischargeW.toStringAsFixed(1)} W'
                          : '0.0 W',
                  subtitle: 'Estado: ${reading.status.displayName}',
                  icon: reading.status == SolarSystemStatus.charging
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded,
                  accentColor: statusColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  title: 'CONSUMO HOGAR',
                  value: '${reading.loadPowerW.toStringAsFixed(1)} W',
                  subtitle: 'Fuente: $cleanSource',
                  icon: Icons.home_rounded,
                  accentColor: const Color(0xFF40C4FF),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
  }) {
    return Container(
      height: 112,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accentColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 19),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: accentColor,
                fontSize: 25,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThresholdSetpointCard(double threshold) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.tune_rounded,
                color: Color(0xFFFFB300),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'UMBRAL DE AVISO DE BATERÍA (SETPOINT)',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _buildSetpointStepButton(
                label: '-5%',
                onTap: () => viewModel.updateCriticalThreshold(
                  (threshold - 5).clamp(5.0, 95.0),
                ),
              ),
              const SizedBox(width: 6),
              _buildSetpointStepButton(
                label: '-1%',
                onTap: () => viewModel.updateCriticalThreshold(
                  (threshold - 1).clamp(5.0, 95.0),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '${threshold.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: Color(0xFFFFB300),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _buildSetpointStepButton(
                label: '+1%',
                onTap: () => viewModel.updateCriticalThreshold(
                  (threshold + 1).clamp(5.0, 95.0),
                ),
              ),
              const SizedBox(width: 6),
              _buildSetpointStepButton(
                label: '+5%',
                onTap: () => viewModel.updateCriticalThreshold(
                  (threshold + 5).clamp(5.0, 95.0),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: const Color(0xFFFFB300),
              inactiveTrackColor: Colors.white12,
              thumbColor: const Color(0xFFFFB300),
              overlayColor: const Color(0xFFFFB300).withOpacity(0.15),
            ),
            child: Slider(
              value: threshold.clamp(5.0, 95.0),
              min: 5.0,
              max: 95.0,
              divisions: 90,
              label: '${threshold.toStringAsFixed(0)}%',
              onChanged: (val) =>
                  viewModel.updateCriticalThreshold(val.roundToDouble()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSetpointStepButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  void _openSettingsSheet(BuildContext context) {
    final hostCtrl = TextEditingController(text: viewModel.brokerHost);
    final portCtrl =
        TextEditingController(text: viewModel.brokerPort.toString());
    final tgTokenCtrl = TextEditingController(text: viewModel.telegramBotToken);
    final tgChatCtrl = TextEditingController(text: viewModel.telegramChatId);
    bool demoMode = viewModel.demoMode;
    double threshold = viewModel.criticalSocThreshold;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161F30),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Configuración de Red Local y Avisos',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Umbral de aviso de batería (Setpoint):',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        Text(
                          '${threshold.toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: Color(0xFFFFB300),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: threshold.clamp(5.0, 95.0),
                      min: 5.0,
                      max: 95.0,
                      divisions: 90,
                      activeColor: const Color(0xFFFFB300),
                      label: '${threshold.toStringAsFixed(0)}%',
                      onChanged: (val) =>
                          setSheetState(() => threshold = val.roundToDouble()),
                    ),
                    const Divider(color: Colors.white12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Modo Simulador en el Celular (Sin red MQTT)',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Útil para probar gráficas y avisos cuando estás fuera de casa',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: demoMode,
                      activeColor: const Color(0xFF00E676),
                      onChanged: (val) => setSheetState(() => demoMode = val),
                    ),
                    const Divider(color: Colors.white12),
                    TextField(
                      controller: hostCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'IP Local de la MacBook (Mosquitto MQTT)',
                        hintText: 'Ej: 192.168.0.224',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Puerto MQTT',
                        hintText: '1883',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Aviso por Telegram (<${threshold.toStringAsFixed(0)}% Batería)',
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextField(
                      controller: tgTokenCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Telegram Bot Token (Opcional)',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tgChatCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Telegram Chat ID Familiar (Opcional)',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E676),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () {
                          viewModel.saveSettings(
                            host: hostCtrl.text,
                            port: int.tryParse(portCtrl.text) ?? 1883,
                            telegramToken: tgTokenCtrl.text,
                            telegramChatId: tgChatCtrl.text,
                            demoMode: demoMode,
                            criticalThreshold: threshold,
                          );
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.save_rounded),
                        label: const Text(
                          'GUARDAR Y CONECTAR',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
