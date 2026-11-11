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

        return Scaffold(
          backgroundColor: const Color(0xFF0B101B),
          appBar: AppBar(
            backgroundColor: const Color(0xFF111927),
            elevation: 0,
            title: Row(
              children: [
                const Icon(Icons.wb_sunny_rounded, color: Color(0xFFFFB300)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Monitor Solar Familiar',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ),
                _buildConnectionBadge(
                  viewModel.connectionStatus,
                  viewModel.demoMode,
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
                // Banner discreto de aviso cuando la batería está bajo el umbral
                if (criticalAlert != null)
                  _buildSimpleAlertBanner(criticalAlert, threshold),

                // Barra previa de la Notificación Permanente (espejo de barra de estado)
                if (reading != null)
                  _buildPersistentNotificationPreviewBar(reading, threshold),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (reading != null) ...[
                          _buildPrimaryTelemetryGrid(reading, threshold),
                          const SizedBox(height: 12),
                          _buildThresholdSetpointCard(threshold),
                          const SizedBox(height: 20),
                        ],

                        const Text(
                          'GRÁFICAS DINÁMICAS E INTERACTIVAS',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Pellizca con dos dedos o usa +/- para hacer zoom. Toca cualquier punto para ver el valor y hora exacta.',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 14),

                        // 1. Gráfica de Nivel de Batería de las últimas 24 horas (%)
                        InteractiveSolarChart(
                          title: '1. Nivel de Batería - Últimas 24 Horas',
                          subtitle:
                              'Evolución histórica del SOC (%) y umbral configurado en ${threshold.toStringAsFixed(0)}%',
                          unit: '%',
                          readings: viewModel.history24h,
                          valueSelector: (r) => r.batterySoc,
                          lineColor: const Color(0xFF00E676),
                          gradientColor: const Color(0xFF00C853),
                          minY: 0,
                          maxY: 100,
                          thresholdY: threshold,
                          thresholdLabel:
                              'Umbral ${threshold.toStringAsFixed(0)}%',
                          showSecondsInTooltip: false,
                        ),

                        // 2. Gráfica de Potencia Entregada por los Paneles Solares en Tiempo Real (W)
                        InteractiveSolarChart(
                          title: '2. Potencia de Paneles Solares (Tiempo Real)',
                          subtitle:
                              'Generación fotovoltaica instantánea recibida cada ~1.5s',
                          unit: 'W',
                          readings: viewModel.realtimeReadings,
                          valueSelector: (r) => r.pvPowerW,
                          lineColor: const Color(0xFFFFB300),
                          gradientColor: const Color(0xFFFF8F00),
                          minY: 0,
                          showSecondsInTooltip: true,
                        ),

                        // 3. Gráfica de Potencia de Descarga de la Batería (W)
                        InteractiveSolarChart(
                          title: '3. Potencia de Descarga de Batería',
                          subtitle:
                              'Energía extraída del banco de baterías en tiempo real',
                          unit: 'W',
                          readings: viewModel.realtimeReadings,
                          valueSelector: (r) => r.batteryDischargeW,
                          lineColor: const Color(0xFFFF5252),
                          gradientColor: const Color(0xFFD50000),
                          minY: 0,
                          showSecondsInTooltip: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectionBadge(
    MqttConnectionStateStatus status,
    bool demoMode,
  ) {
    if (demoMode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF2962FF).withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF448AFF)),
        ),
        child: const Text(
          'MODO DEMO',
          style: TextStyle(
            color: Color(0xFF82B1FF),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    final (label, color) = switch (status) {
      MqttConnectionStateStatus.connected => (
          'MQTT ACTIVO',
          const Color(0xFF00E676)
        ),
      MqttConnectionStateStatus.connecting ||
      MqttConnectionStateStatus.reconnecting =>
        ('RECONECTANDO...', const Color(0xFFFFB300)),
      MqttConnectionStateStatus.disconnected => (
          'SIN RED LOCAL',
          const Color(0xFFFF5252)
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141C2B),
        border: Border(
          bottom: BorderSide(color: indicatorColor.withOpacity(0.4), width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: indicatorColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: indicatorColor.withOpacity(0.6),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Barra de Estado Fija: ${reading.batterySoc.toStringAsFixed(1)}% • ${reading.status.displayName.toUpperCase()} (${reading.batteryVoltage.toStringAsFixed(1)}V)',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isGreen ? 'ÓPTIMO' : 'ATENCIÓN',
            style: TextStyle(
              color: indicatorColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
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

    // Formatear fuente para que sea limpia y concisa
    final cleanSource = reading.sourceMode.contains('Casa_Falla')
        ? 'SmartESS (Casa_Falla)'
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
                  value: '${reading.pvPowerW.toStringAsFixed(0)} W',
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
                      ? '+${reading.batteryChargeW.toStringAsFixed(0)} W'
                      : reading.status == SolarSystemStatus.discharging
                          ? '-${reading.batteryDischargeW.toStringAsFixed(0)} W'
                          : '0 W',
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
                  value: '${reading.loadPowerW.toStringAsFixed(0)} W',
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
