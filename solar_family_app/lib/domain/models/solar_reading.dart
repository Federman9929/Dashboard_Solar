enum SolarSystemStatus {
  charging('cargando', 'Cargando'),
  discharging('descargando', 'Descargando'),
  idle('en_reposo', 'En Reposo');

  const SolarSystemStatus(this.rawValue, this.displayName);
  final String rawValue;
  final String displayName;

  static SolarSystemStatus fromString(String value) {
    final normalized = value.trim().toLowerCase();
    for (final status in SolarSystemStatus.values) {
      if (status.rawValue == normalized) return status;
    }
    return SolarSystemStatus.idle;
  }
}

class SolarReading {
  const SolarReading({
    required this.timestamp,
    required this.epochMs,
    required this.batteryVoltage,
    required this.batterySoc,
    required this.pvPowerW,
    required this.batteryPowerW,
    required this.batteryChargeW,
    required this.batteryDischargeW,
    required this.loadPowerW,
    required this.status,
    required this.isCritical,
    required this.sourceMode,
  });

  final DateTime timestamp;
  final int epochMs;
  final double batteryVoltage;
  final double batterySoc;
  final double pvPowerW;
  final double batteryPowerW;
  final double batteryChargeW;
  final double batteryDischargeW;
  final double loadPowerW;
  final SolarSystemStatus status;
  final bool isCritical;
  final String sourceMode;

  /// Determina si el indicador visual de la notificación permanente y UI
  /// debe ser verde (cargando o nivel saludable por encima del umbral)
  /// o rojo (descargando o nivel por debajo del umbral configurado).
  bool isHealthyForThreshold(double threshold) =>
      batterySoc >= threshold &&
      (status == SolarSystemStatus.charging ||
          (status == SolarSystemStatus.idle && batterySoc >= threshold));

  bool get isHealthyGreen => isHealthyForThreshold(30.0);

  String statusEmojiForThreshold(double threshold) =>
      isHealthyForThreshold(threshold) ? '🟢' : '🔴';

  String get statusEmoji => isHealthyGreen ? '🟢' : '🔴';

  factory SolarReading.fromJson(Map<String, dynamic> json) {
    final epoch = (json['epoch_ms'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final soc = (json['battery_soc'] as num?)?.toDouble() ?? 0.0;
    final netBattW = (json['battery_power_w'] as num?)?.toDouble() ?? 0.0;
    final dischargeW = (json['battery_discharge_w'] as num?)?.toDouble() ??
        (netBattW < 0 ? netBattW.abs() : 0.0);
    final chargeW = (json['battery_charge_w'] as num?)?.toDouble() ??
        (netBattW > 0 ? netBattW : 0.0);

    return SolarReading(
      timestamp: DateTime.fromMillisecondsSinceEpoch(epoch),
      epochMs: epoch,
      batteryVoltage: (json['battery_voltage'] as num?)?.toDouble() ?? 0.0,
      batterySoc: soc,
      pvPowerW: (json['pv_power_w'] as num?)?.toDouble() ?? 0.0,
      batteryPowerW: netBattW,
      batteryChargeW: chargeW,
      batteryDischargeW: dischargeW,
      loadPowerW: (json['load_power_w'] as num?)?.toDouble() ?? 0.0,
      status: SolarSystemStatus.fromString(
        (json['status'] as String?) ?? 'en_reposo',
      ),
      isCritical: (json['is_critical'] as bool?) ?? (soc < 30.0),
      sourceMode: (json['source_mode'] as String?) ?? 'LOCAL',
    );
  }

  /// Calcula la autonomía restante estimada en base a la capacidad efectiva
  /// del banco (4910 Wh = 49.1 Wh por 1% SOC) y el consumo o carga actual.
  String estimateAutonomy({required double threshold}) {
    const double whPerSocPoint = 49.1;

    if (status == SolarSystemStatus.discharging || batteryPowerW < -15.0) {
      final double dischargeRateW = batteryDischargeW > 15.0
          ? batteryDischargeW
          : (batteryPowerW < 0 ? batteryPowerW.abs() : loadPowerW);

      if (dischargeRateW <= 15.0) {
        return 'Consumo mínimo';
      }

      final double availableSoc = batterySoc - threshold;
      if (availableSoc <= 0) {
        return 'Batería en umbral ($batterySoc%)';
      }

      final double availableWh = availableSoc * whPerSocPoint;
      final double hoursLeft = availableWh / dischargeRateW;

      final int h = hoursLeft.floor();
      final int m = ((hoursLeft - h) * 60).round();
      if (h == 0 && m == 0) return '< 1 min restante';
      if (h == 0) return '${m}m hasta ${threshold.toStringAsFixed(0)}%';
      return '${h}h ${m.toString().padLeft(2, '0')}m hasta ${threshold.toStringAsFixed(0)}%';
    } else if (status == SolarSystemStatus.charging || batteryPowerW > 15.0) {
      final double chargeRateW = batteryChargeW > 15.0
          ? batteryChargeW
          : (batteryPowerW > 0 ? batteryPowerW : (pvPowerW - loadPowerW));

      if (chargeRateW <= 15.0) {
        return 'Carga lenta';
      }

      final double neededSoc = (100.0 - batterySoc).clamp(0.0, 100.0);
      if (neededSoc <= 0.5) {
        return 'Batería llena (100%)';
      }

      final double neededWh = neededSoc * whPerSocPoint;
      final double hoursLeft = neededWh / chargeRateW;

      final int h = hoursLeft.floor();
      final int m = ((hoursLeft - h) * 60).round();
      if (h == 0 && m == 0) return 'Casi completa';
      if (h == 0) return '${m}m para 100%';
      return '${h}h ${m.toString().padLeft(2, '0')}m para 100%';
    }

    return 'En reposo / Estable';
  }
}
