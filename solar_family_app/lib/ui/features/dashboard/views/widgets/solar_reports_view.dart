import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'package:solar_family_monitor/domain/models/solar_energy_stats.dart';
import 'package:solar_family_monitor/domain/models/solar_reading.dart';
import 'package:solar_family_monitor/ui/features/dashboard/view_models/solar_dashboard_view_model.dart';

class SolarReportsView extends StatefulWidget {
  const SolarReportsView({
    super.key,
    required this.viewModel,
    required this.currentReading,
  });

  final SolarDashboardViewModel viewModel;
  final SolarReading? currentReading;

  @override
  State<SolarReportsView> createState() => _SolarReportsViewState();
}

class _SolarReportsViewState extends State<SolarReportsView> {
  int _selectedPeriodIndex = 0; // 0: Día, 1: Semana, 2: Mes
  int _reportExportPeriodIndex = 0; // 0: Día, 1: Semana, 2: Mes

  static const List<String> _periods = ['Día', 'Semana', 'Mes'];

  String _formatCop(double value) {
    final int rounded = value.round();
    final String s = rounded.abs().toString();
    final buffer = StringBuffer();
    int count = 0;
    for (int i = s.length - 1; i >= 0; i--) {
      buffer.write(s[i]);
      count++;
      if (count % 3 == 0 && i > 0) {
        buffer.write('.');
      }
    }
    final prefix = rounded < 0 ? '-\$' : '\$';
    return '$prefix${buffer.toString().split('').reversed.join('')} COP';
  }

  SolarEnergyPeriodStats _periodStatsFor(int index, SolarEnergyStatsBundle stats) {
    return switch (index) {
      0 => stats.day,
      1 => stats.week,
      2 => stats.month,
      _ => stats.day,
    };
  }

  String _buildReportText(int periodIndex) {
    final stats = widget.viewModel.energyStats;
    final reading = widget.currentReading;
    final autonomy = widget.viewModel.autonomyText;
    final tariff = widget.viewModel.kwhTariffCop;
    final String periodName = _periods[periodIndex];
    final periodStat = _periodStatsFor(periodIndex, stats);
    final double savingsCop = periodStat.loadEnergyKwh * tariff;

    final now = DateTime.now();
    final nowStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final startLine = (periodIndex == 0 && periodStat.solarStartTime.isNotEmpty)
        ? '⏱️ Inicio consumo solar hoy: ${periodStat.solarStartTime}\n'
        : '';

    final batteryLine = reading != null
        ? '🔋 Batería actual: ${reading.batterySoc.toStringAsFixed(1)}% (${reading.batteryVoltage.toStringAsFixed(1)}V)\n'
        : '';

    return '''☀️ INFORME DE RENDIMIENTO SOLAR
Periodo: $periodName • $nowStr
--------------------------------------
${startLine}🏠 Consumo casa atendido: ${periodStat.loadEnergyKwh.toStringAsFixed(2)} kWh
🌞 Energía solar producida: ${periodStat.pvEnergyKwh.toStringAsFixed(2)} kWh
💰 Ahorro económico: ${_formatCop(savingsCop)}
⚡ Tarifa aplicada: \$${tariff.toStringAsFixed(0)} COP/kWh
🌿 Cobertura solar: ${periodStat.solarCoveragePercent.toStringAsFixed(1)}%
${batteryLine}⏳ Autonomía: $autonomy
--------------------------------------
Monitor Solar Familiar''';
  }

  Future<void> _shareReport(int periodIndex) async {
    final String periodName = _periods[periodIndex];
    final String reportText = _buildReportText(periodIndex);
    await SharePlus.instance.share(
      ShareParams(
        text: reportText,
        subject: 'Informe Solar Familiar - $periodName',
      ),
    );
  }

  Future<void> _copyReport(BuildContext context, int periodIndex) async {
    final String reportText = _buildReportText(periodIndex);
    await Clipboard.setData(ClipboardData(text: reportText));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Informe copiado al portapapeles'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.viewModel.energyStats;
    final reading = widget.currentReading;
    final autonomy = widget.viewModel.autonomyText;
    final tariff = widget.viewModel.kwhTariffCop;

    final activePeriodStat = _periodStatsFor(_selectedPeriodIndex, stats);
    final double activeSavingsCop = activePeriodStat.loadEnergyKwh * tariff;
    final reportPreviewStat = _periodStatsFor(_reportExportPeriodIndex, stats);
    final double reportPreviewSavingsCop =
        reportPreviewStat.loadEnergyKwh * tariff;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Tarjeta de Autonomía de Batería
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF161F30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFFB388FF).withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFB388FF).withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.timelapse_rounded,
                  color: Color(0xFFB388FF),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AUTONOMÍA ESTIMADA',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      autonomy,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (reading != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Batería: ${reading.batterySoc.toStringAsFixed(1)}% • ${reading.batteryVoltage.toStringAsFixed(1)}V',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // 2. Tarjeta de Ahorro Económico en Pesos (calculado en vivo sobre consumo de la casa)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF161F30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF00E676).withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.savings_outlined,
                        color: Color(0xFF00E676),
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'AHORRO ENERGÉTICO',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '\$${tariff.toStringAsFixed(0)} / kWh',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Selector de Periodo (Día / Semana / Mes)
              Container(
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  children: List.generate(_periods.length, (idx) {
                    final isSel = _selectedPeriodIndex == idx;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedPeriodIndex = idx),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: isSel
                                ? const Color(0xFF00E676)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _periods[idx],
                            style: TextStyle(
                              color: isSel ? Colors.black : Colors.white70,
                              fontWeight:
                                  isSel ? FontWeight.w800 : FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),

              const SizedBox(height: 14),

              // Valor del Ahorro en COP en tiempo real
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      _formatCop(activeSavingsCop),
                      style: const TextStyle(
                        color: Color(0xFF00E676),
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (reading != null && reading.loadPowerW > 5)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '+${reading.loadPowerW.toStringAsFixed(0)}W en vivo',
                        style: const TextStyle(
                          color: Color(0xFF00E676),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    'Consumo: ${activePeriodStat.loadEnergyKwh.toStringAsFixed(2)} kWh',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Solar: ${activePeriodStat.pvEnergyKwh.toStringAsFixed(2)} kWh',
                    style: const TextStyle(
                      color: Color(0xFFFFB300),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_selectedPeriodIndex == 0 &&
                      activePeriodStat.solarStartTime.isNotEmpty)
                    Text(
                      'Desde ${activePeriodStat.solarStartTime}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // 3. Generador y Exportador de Informes
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF161F30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    color: Color(0xFF40C4FF),
                    size: 19,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'INFORME',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Rango de tiempo para el informe
              Row(
                children: [
                  const Text(
                    'Rango:',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SegmentedButton<int>(
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: Colors.black26,
                        selectedBackgroundColor: const Color(0xFF40C4FF),
                        selectedForegroundColor: Colors.black,
                        foregroundColor: Colors.white70,
                      ),
                      segments: const [
                        ButtonSegment(value: 0, label: Text('Día')),
                        ButtonSegment(value: 1, label: Text('Semana')),
                        ButtonSegment(value: 2, label: Text('Mes')),
                      ],
                      selected: {_reportExportPeriodIndex},
                      onSelectionChanged: (val) {
                        setState(() => _reportExportPeriodIndex = val.first);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Vista previa en vivo del informe generado
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPreviewRow(
                      'Consumo atendido',
                      '${reportPreviewStat.loadEnergyKwh.toStringAsFixed(2)} kWh',
                      Colors.white,
                    ),
                    _buildPreviewRow(
                      'Energía solar producida',
                      '${reportPreviewStat.pvEnergyKwh.toStringAsFixed(2)} kWh',
                      const Color(0xFFFFB300),
                    ),
                    _buildPreviewRow(
                      'Ahorro acumulado',
                      _formatCop(reportPreviewSavingsCop),
                      const Color(0xFF00E676),
                    ),
                    _buildPreviewRow(
                      'Cobertura solar',
                      '${reportPreviewStat.solarCoveragePercent.toStringAsFixed(1)}%',
                      const Color(0xFF40C4FF),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF40C4FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => _shareReport(_reportExportPeriodIndex),
                      icon: const Icon(Icons.share_rounded, size: 18),
                      label: const Text(
                        'Generar y Compartir',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () =>
                          _copyReport(context, _reportExportPeriodIndex),
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text(
                        'Copiar',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
