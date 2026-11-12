/// Estadísticas de generación y ahorro de energía acumuladas (Día, Semana, Mes).
class SolarEnergyPeriodStats {
  const SolarEnergyPeriodStats({
    required this.periodLabel,
    required this.pvEnergyKwh,
    required this.loadEnergyKwh,
    required this.savingsCop,
    required this.solarCoveragePercent,
  });

  final String periodLabel;
  final double pvEnergyKwh;
  final double loadEnergyKwh;
  final double savingsCop;
  final double solarCoveragePercent;

  factory SolarEnergyPeriodStats.empty(String label) => SolarEnergyPeriodStats(
        periodLabel: label,
        pvEnergyKwh: 0.0,
        loadEnergyKwh: 0.0,
        savingsCop: 0.0,
        solarCoveragePercent: 100.0,
      );

  factory SolarEnergyPeriodStats.fromJson(Map<String, dynamic> json, String label) {
    return SolarEnergyPeriodStats(
      periodLabel: label,
      pvEnergyKwh: (json['pv_energy_kwh'] as num?)?.toDouble() ?? 0.0,
      loadEnergyKwh: (json['load_energy_kwh'] as num?)?.toDouble() ?? 0.0,
      savingsCop: (json['savings_cop'] as num?)?.toDouble() ?? 0.0,
      solarCoveragePercent:
          (json['solar_coverage_percent'] as num?)?.toDouble() ?? 100.0,
    );
  }
}

class SolarEnergyStatsBundle {
  const SolarEnergyStatsBundle({
    required this.tariffCop,
    required this.day,
    required this.week,
    required this.month,
    required this.updatedAtMs,
  });

  final double tariffCop;
  final SolarEnergyPeriodStats day;
  final SolarEnergyPeriodStats week;
  final SolarEnergyPeriodStats month;
  final int updatedAtMs;

  factory SolarEnergyStatsBundle.initial({double tariff = 850.0}) {
    return SolarEnergyStatsBundle(
      tariffCop: tariff,
      day: SolarEnergyPeriodStats.empty('Día'),
      week: SolarEnergyPeriodStats.empty('Semana'),
      month: SolarEnergyPeriodStats.empty('Mes'),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory SolarEnergyStatsBundle.fromJson(Map<String, dynamic> json) {
    final tariff = (json['tariff_cop'] as num?)?.toDouble() ?? 850.0;
    return SolarEnergyStatsBundle(
      tariffCop: tariff,
      day: json['day'] is Map<String, dynamic>
          ? SolarEnergyPeriodStats.fromJson(
              json['day'] as Map<String, dynamic>, 'Día')
          : SolarEnergyPeriodStats.empty('Día'),
      week: json['week'] is Map<String, dynamic>
          ? SolarEnergyPeriodStats.fromJson(
              json['week'] as Map<String, dynamic>, 'Semana')
          : SolarEnergyPeriodStats.empty('Semana'),
      month: json['month'] is Map<String, dynamic>
          ? SolarEnergyPeriodStats.fromJson(
              json['month'] as Map<String, dynamic>, 'Mes')
          : SolarEnergyPeriodStats.empty('Mes'),
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}
