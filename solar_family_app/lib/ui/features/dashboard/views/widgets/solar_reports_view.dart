import 'package:flutter/material.dart';
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
    final String s = rounded.toString();
    final buffer = StringBuffer();
    int count = 0;
    for (int i = s.length - 1; i >= 0; i--) {
      buffer.write(s[i]);
      count++;
      if (count % 3 == 0 && i > 0) {
        buffer.write('.');
      }
    }
    return '\$${buffer.toString().split('').reversed.join('')} COP';
  }

  void _generateAndShareReport() {
    final stats = widget.viewModel.energyStats;
    final reading = widget.currentReading;
    final autonomy = widget.viewModel.autonomyText;
    final tariff = widget.viewModel.kwhTariffCop;

    final String periodName = _periods[_reportExportPeriodIndex];
    final SolarEnergyPeriodStats periodStat = switch (_reportExportPeriodIndex) {
      0 => stats.day,
      1 => stats.week,
      2 => stats.month,
      _ => stats.day,
    };

    final nowStr = DateTime.now().toString().substring(0, 16);
    final String reportText = '''
☀️ INFORME DE RENDIMIENTO SOLAR
Periodo: $periodName ($nowStr)
--------------------------------------
🔋 Autonomía restante: $autonomy
⚡ Tarifa aplicada: \$${tariff.toStringAsFixed(0)} COP/kWh
🌞 Energía solar producida: ${periodStat.pvEnergyKwh.toStringAsFixed(2)} kWh
🏠 Consumo atendido: ${periodStat.loadEnergyKwh.toStringAsFixed(2)} kWh
💰 Ahorro económico: ${_formatCop(periodStat.savingsCop)}
🌿 Cobertura solar: ${periodStat.solarCoveragePercent.toStringAsFixed(1)}%
${reading != null ? '🔋 Nivel actual de batería: ${reading.batterySoc.toStringAsFixed(1)}% (${reading.batteryVoltage.toStringAsFixed(1)}V)' : ''}
--------------------------------------
Generado por Monitor Solar Familiar
''';

    Share.share(
      reportText,
      subject: 'Informe Solar Familiar - $periodName',
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.viewModel.energyStats;
    final reading = widget.currentReading;
    final autonomy = widget.viewModel.autonomyText;
    final tariff = widget.viewModel.kwhTariffCop;

    final SolarEnergyPeriodStats activePeriodStat = switch (_selectedPeriodIndex) {
      0 => stats.day,
      1 => stats.week,
      2 => stats.month,
      _ => stats.day,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Tarjeta de Autonomía de Batería
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF161F30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFB388FF).withOpacity(0.4)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFB388FF).withOpacity(0.18),
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

        // 2. Tarjeta de Ahorro Económico en Pesos
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF161F30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00E676).withOpacity(0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: const [
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

              // Valor del Ahorro en COP
              Text(
                _formatCop(activePeriodStat.savingsCop),
                style: const TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    'Generación: ${activePeriodStat.pvEnergyKwh.toStringAsFixed(2)} kWh',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '• Cobertura: ${activePeriodStat.solarCoveragePercent.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Color(0xFFFFB300),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
              Row(
                children: const [
                  Icon(
                    Icons.description_outlined,
                    color: Color(0xFF40C4FF),
                    size: 19,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'GENERAR INFORME',
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
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF40C4FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _generateAndShareReport,
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: const Text(
                    'Compartir Informe',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
