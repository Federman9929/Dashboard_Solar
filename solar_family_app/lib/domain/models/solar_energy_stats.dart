/// Estadísticas de generación y ahorro de energía acumuladas (Día, Semana, Mes).
class SolarEnergyPeriodStats {
  const SolarEnergyPeriodStats({
    required this.periodLabel,
    required this.pvEnergyKwh,
    required this.loadEnergyKwh,
    required this.savingsCop,
    required this.solarCoveragePercent,
    this.solarStartTime = '',
  });

  final String periodLabel;
  final double pvEnergyKwh;
  final double loadEnergyKwh;
  final double savingsCop;
  final double solarCoveragePercent;
  final String solarStartTime;

  factory SolarEnergyPeriodStats.empty(String label) => SolarEnergyPeriodStats(
        periodLabel: label,
        pvEnergyKwh: 0.0,
        loadEnergyKwh: 0.0,
        savingsCop: 0.0,
        solarCoveragePercent: 100.0,
        solarStartTime: '',
      );

  factory SolarEnergyPeriodStats.fromJson(Map<String, dynamic> json, String label) {
    return SolarEnergyPeriodStats(
      periodLabel: label,
      pvEnergyKwh: (json['pv_energy_kwh'] as num?)?.toDouble() ?? 0.0,
      loadEnergyKwh: (json['load_energy_kwh'] as num?)?.toDouble() ?? 0.0,
      savingsCop: (json['savings_cop'] as num?)?.toDouble() ?? 0.0,
      solarCoveragePercent:
          (json['solar_coverage_percent'] as num?)?.toDouble() ?? 100.0,
      solarStartTime: (json['solar_start_time'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'pv_energy_kwh': pvEnergyKwh,
        'load_energy_kwh': loadEnergyKwh,
        'savings_cop': savingsCop,
        'solar_coverage_percent': solarCoveragePercent,
        'solar_start_time': solarStartTime,
      };

  /// Recalcula el ahorro en pesos (COP) estrictamente en base a la energía
  /// acumulada consumida por la casa (`loadEnergyKwh`) * tarifa $/kWh.
  SolarEnergyPeriodStats withTariff(double tariffCop) {
    final double sav = loadEnergyKwh * tariffCop;
    return SolarEnergyPeriodStats(
      periodLabel: periodLabel,
      pvEnergyKwh: pvEnergyKwh,
      loadEnergyKwh: loadEnergyKwh,
      savingsCop: sav,
      solarCoveragePercent: solarCoveragePercent,
      solarStartTime: solarStartTime,
    );
  }

  SolarEnergyPeriodStats addDelta({
    required double deltaPvKwh,
    required double deltaLoadKwh,
    required double tariffCop,
    String? startTimeOverride,
  }) {
    final newPv = pvEnergyKwh + deltaPvKwh;
    final newLoad = loadEnergyKwh + deltaLoadKwh;
    final newCov = newLoad > 0.01
        ? ((newPv / newLoad) * 100.0).clamp(0.0, 100.0)
        : (newPv > 0 ? 100.0 : solarCoveragePercent);
    return SolarEnergyPeriodStats(
      periodLabel: periodLabel,
      pvEnergyKwh: newPv,
      loadEnergyKwh: newLoad,
      savingsCop: newLoad * tariffCop,
      solarCoveragePercent: newCov,
      solarStartTime: (solarStartTime.isEmpty && startTimeOverride != null)
          ? startTimeOverride
          : solarStartTime,
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
    this.isFromBackend = false,
  });

  final double tariffCop;
  final SolarEnergyPeriodStats day;
  final SolarEnergyPeriodStats week;
  final SolarEnergyPeriodStats month;
  final int updatedAtMs;
  final bool isFromBackend;

  factory SolarEnergyStatsBundle.initial({double tariff = 850.0}) {
    return SolarEnergyStatsBundle(
      tariffCop: tariff,
      day: SolarEnergyPeriodStats.empty('Día'),
      week: SolarEnergyPeriodStats.empty('Semana'),
      month: SolarEnergyPeriodStats.empty('Mes'),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      isFromBackend: false,
    );
  }

  factory SolarEnergyStatsBundle.fromJson(
    Map<String, dynamic> json, {
    bool isFromBackend = true,
  }) {
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
      isFromBackend: isFromBackend,
    );
  }

  Map<String, dynamic> toJson() => {
        'tariff_cop': tariffCop,
        'day': day.toJson(),
        'week': week.toJson(),
        'month': month.toJson(),
        'updated_at_ms': updatedAtMs,
      };

  SolarEnergyStatsBundle withTariff(double newTariffCop) {
    return SolarEnergyStatsBundle(
      tariffCop: newTariffCop,
      day: day.withTariff(newTariffCop),
      week: week.withTariff(newTariffCop),
      month: month.withTariff(newTariffCop),
      updatedAtMs: updatedAtMs,
      isFromBackend: isFromBackend,
    );
  }

  SolarEnergyStatsBundle addLiveDelta({
    required double deltaPvKwh,
    required double deltaLoadKwh,
    required double tariffCop,
    String? startTimeIfEmpty,
  }) {
    return SolarEnergyStatsBundle(
      tariffCop: tariffCop,
      day: day.addDelta(
        deltaPvKwh: deltaPvKwh,
        deltaLoadKwh: deltaLoadKwh,
        tariffCop: tariffCop,
        startTimeOverride: startTimeIfEmpty,
      ),
      week: week.addDelta(
        deltaPvKwh: deltaPvKwh,
        deltaLoadKwh: deltaLoadKwh,
        tariffCop: tariffCop,
      ),
      month: month.addDelta(
        deltaPvKwh: deltaPvKwh,
        deltaLoadKwh: deltaLoadKwh,
        tariffCop: tariffCop,
      ),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      isFromBackend: isFromBackend,
    );
  }
}
