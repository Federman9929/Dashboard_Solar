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
                tooltip: 'Probar Alerta Crítica (<30%)',
                icon: const Icon(
                  Icons.notification_important_rounded,
                  color: Color(0xFFFF5252),
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
                // Banner de Alerta Crítica (< 30%) con botón para silenciar llamada sonora
                if (criticalAlert != null)
                  _buildCriticalEmergencyBanner(criticalAlert),

                // Barra previa de la Notificación Permanente (espejo de barra de estado)
                if (reading != null)
                  _buildPersistentNotificationPreviewBar(reading),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (reading != null) ...[
                          _buildPrimaryTelemetryGrid(reading),
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
                              'Evolución histórica del SOC (%) y umbral crítico del 30%',
                          unit: '%',
                          readings: viewModel.history24h,
                          valueSelector: (r) => r.batterySoc,
                          lineColor: const Color(0xFF00E676),
                          gradientColor: const Color(0xFF00C853),
                          minY: 0,
                          maxY: 100,
                          thresholdY: 30.0,
                          thresholdLabel: 'Alerta Crítica 30%',
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

  Widget _buildCriticalEmergencyBanner(SolarReading alertReading) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFFD50000),
      child: Row(
        children: [
          const Icon(
            Icons.ring_volume_rounded,
            color: Colors.white,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🚨 ¡ALERTA CRÍTICA: BATERÍA AL ${alertReading.batterySoc.toStringAsFixed(1)}%!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                Text(
                  'Voltaje: ${alertReading.batteryVoltage.toStringAsFixed(1)}V • Descarga: ${alertReading.batteryDischargeW.toStringAsFixed(0)}W',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFFD50000),
            ),
            onPressed: viewModel.silenceCriticalAlert,
            icon: const Icon(Icons.volume_off_rounded, size: 18),
            label: const Text(
              'SILENCIAR',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersistentNotificationPreviewBar(SolarReading reading) {
    final isGreen = reading.isHealthyGreen;
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
          // Indicador visual circular exigido: Verde si carga/está bien, Rojo si descarga/bajo
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
            ),
          ),
          Text(
            reading.isHealthyGreen ? 'ÓPTIMO' : 'ATENCIÓN',
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

  Widget _buildPrimaryTelemetryGrid(SolarReading reading) {
    final isGreen = reading.isHealthyGreen;
    final statusColor =
        isGreen ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    return Column(
      children: [
        Row(
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
        const SizedBox(height: 12),
        Row(
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
                subtitle: 'Fuente: ${reading.sourceMode}',
                icon: Icons.home_rounded,
                accentColor: const Color(0xFF40C4FF),
              ),
            ),
          ],
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accentColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: accentColor,
              fontSize: 26,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
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
                      'Configuración de Red Local y Alertas',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Modo Simulador en el Celular (Sin red MQTT)',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Útil para probar gráficas y alertas cuando estás fuera de casa',
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
                        hintText: 'Ej: 192.168.1.100',
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
                    const Text(
                      'Alerta Crítica Directa por Telegram (<30% Batería)',
                      style: TextStyle(
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
