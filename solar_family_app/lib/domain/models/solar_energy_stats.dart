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

class SolarDailyStat {
  const SolarDailyStat({
    required this.dateStr,
    required this.pvEnergyKwh,
    required this.loadEnergyKwh,
    required this.minSoc,
    required this.maxSoc,
    required this.solarCoveragePercent,
    required this.savingsCop,
    this.solarStartTime = '',
  });

  final String dateStr;
  final double pvEnergyKwh;
  final double loadEnergyKwh;
  final double minSoc;
  final double maxSoc;
  final double solarCoveragePercent;
  final double savingsCop;
  final String solarStartTime;

  factory SolarDailyStat.fromJson(Map<String, dynamic> json) {
    return SolarDailyStat(
      dateStr: (json['date_str'] as String?) ?? '',
      pvEnergyKwh: (json['pv_energy_kwh'] as num?)?.toDouble() ?? 0.0,
      loadEnergyKwh: (json['load_energy_kwh'] as num?)?.toDouble() ?? 0.0,
      minSoc: (json['min_soc'] as num?)?.toDouble() ?? 0.0,
      maxSoc: (json['max_soc'] as num?)?.toDouble() ?? 100.0,
      solarCoveragePercent:
          (json['solar_coverage_percent'] as num?)?.toDouble() ?? 100.0,
      savingsCop: (json['savings_cop'] as num?)?.toDouble() ?? 0.0,
      solarStartTime: (json['solar_start_time'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'date_str': dateStr,
        'pv_energy_kwh': pvEnergyKwh,
        'load_energy_kwh': loadEnergyKwh,
        'min_soc': minSoc,
        'max_soc': maxSoc,
        'solar_coverage_percent': solarCoveragePercent,
        'savings_cop': savingsCop,
        'solar_start_time': solarStartTime,
      };

  SolarDailyStat withTariff(double tariffCop) => SolarDailyStat(
        dateStr: dateStr,
        pvEnergyKwh: pvEnergyKwh,
        loadEnergyKwh: loadEnergyKwh,
        minSoc: minSoc,
        maxSoc: maxSoc,
        solarCoveragePercent: solarCoveragePercent,
        savingsCop: loadEnergyKwh * tariffCop,
        solarStartTime: solarStartTime,
      );
}

class SolarEnergyStatsBundle {
  const SolarEnergyStatsBundle({
    required this.tariffCop,
    required this.day,
    required this.week,
    required this.month,
    required this.updatedAtMs,
    this.isFromBackend = false,
    this.dailyBreakdown = const [],
  });

  final double tariffCop;
  final SolarEnergyPeriodStats day;
  final SolarEnergyPeriodStats week;
  final SolarEnergyPeriodStats month;
  final int updatedAtMs;
  final bool isFromBackend;
  final List<SolarDailyStat> dailyBreakdown;

  factory SolarEnergyStatsBundle.initial({double tariff = 850.0}) {
    return SolarEnergyStatsBundle(
      tariffCop: tariff,
      day: SolarEnergyPeriodStats.empty('Día'),
      week: SolarEnergyPeriodStats.empty('Semana'),
      month: SolarEnergyPeriodStats.empty('Mes'),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      isFromBackend: false,
      dailyBreakdown: const [],
    );
  }

  factory SolarEnergyStatsBundle.fromJson(
    Map<String, dynamic> json, {
    bool isFromBackend = true,
  }) {
    final tariff = (json['tariff_cop'] as num?)?.toDouble() ?? 850.0;
    final rawDaily = json['daily_breakdown'] as List<dynamic>? ?? const [];
    final dailyList = rawDaily
        .whereType<Map<String, dynamic>>()
        .map(SolarDailyStat.fromJson)
        .toList(growable: false);
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
      dailyBreakdown: dailyList,
    );
  }

  Map<String, dynamic> toJson() => {
        'tariff_cop': tariffCop,
        'day': day.toJson(),
        'week': week.toJson(),
        'month': month.toJson(),
        'daily_breakdown': dailyBreakdown.map((e) => e.toJson()).toList(),
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
      dailyBreakdown: dailyBreakdown
          .map((d) => d.withTariff(newTariffCop))
          .toList(growable: false),
    );
  }

  SolarEnergyStatsBundle addLiveDelta({
    required double deltaPvKwh,
    required double deltaLoadKwh,
    required double tariffCop,
    String? startTimeIfEmpty,
  }) {
    final newDay = day.addDelta(
      deltaPvKwh: deltaPvKwh,
      deltaLoadKwh: deltaLoadKwh,
      tariffCop: tariffCop,
      startTimeOverride: startTimeIfEmpty,
    );
    final now = DateTime.now();
    final todayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final updatedDaily = dailyBreakdown.isEmpty
        ? const <SolarDailyStat>[]
        : dailyBreakdown.map((d) {
            if (d.dateStr != todayKey) return d;
            return SolarDailyStat(
              dateStr: d.dateStr,
              pvEnergyKwh: newDay.pvEnergyKwh,
              loadEnergyKwh: newDay.loadEnergyKwh,
              minSoc: d.minSoc,
              maxSoc: d.maxSoc,
              solarCoveragePercent: newDay.solarCoveragePercent,
              savingsCop: newDay.savingsCop,
              solarStartTime: newDay.solarStartTime,
            );
          }).toList(growable: false);

    return SolarEnergyStatsBundle(
      tariffCop: tariffCop,
      day: newDay,
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
      dailyBreakdown: updatedDaily,
    );
  }
}
