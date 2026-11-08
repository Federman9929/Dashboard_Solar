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
  /// debe ser verde (cargando o nivel saludable >= 50% sin descarga severa)
  /// o rojo (descargando o nivel bajo < 30%).
  bool get isHealthyGreen =>
      !isCritical &&
      batterySoc >= 30.0 &&
      (status == SolarSystemStatus.charging ||
          (status == SolarSystemStatus.idle && batterySoc >= 50.0));

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
}
