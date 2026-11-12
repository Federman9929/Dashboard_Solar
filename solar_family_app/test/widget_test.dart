import 'package:flutter_test/flutter_test.dart';
import 'package:solar_family_monitor/domain/models/battery_alert_mode.dart';
import 'package:solar_family_monitor/domain/models/solar_energy_stats.dart';
import 'package:solar_family_monitor/domain/models/solar_reading.dart';

void main() {
  test('SolarReading parsea JSON y asigna semáforo verde/rojo', () {
    final reading = SolarReading.fromJson({
      'epoch_ms': 1700000000000,
      'battery_voltage': 52.4,
      'battery_soc': 85.0,
      'pv_power_w': 1500.0,
      'battery_power_w': 900.0,
      'battery_charge_w': 900.0,
      'battery_discharge_w': 0.0,
      'load_power_w': 600.0,
      'status': 'cargando',
      'is_critical': false,
      'source_mode': 'SIMULATOR',
    });

    expect(reading.batterySoc, 85.0);
    expect(reading.isHealthyGreen, isTrue);
    expect(reading.statusEmoji, '🟢');
  });

  test('BatteryAlertMode parsea correctamente código de modo', () {
    expect(BatteryAlertMode.fromCode('alarm'), BatteryAlertMode.immediateAlarm);
    expect(BatteryAlertMode.fromCode('simple'), BatteryAlertMode.simpleNotification);
    expect(BatteryAlertMode.fromCode(null), BatteryAlertMode.simpleNotification);
    expect(BatteryAlertMode.fromCode('other'), BatteryAlertMode.simpleNotification);
  });

  test('SolarEnergyStatsBundle integra consumo de casa en vivo y calcula ahorro COP', () {
    final initial = SolarEnergyStatsBundle.initial(tariff: 850.0);
    // Simular consumo de 2.0 kWh de carga de casa y 3.0 kWh solar
    final updated = initial.addLiveDelta(
      deltaPvKwh: 3.0,
      deltaLoadKwh: 2.0,
      tariffCop: 850.0,
      startTimeIfEmpty: '08:25',
    );

    expect(updated.day.loadEnergyKwh, closeTo(2.0, 0.001));
    expect(updated.day.pvEnergyKwh, closeTo(3.0, 0.001));
    expect(updated.day.savingsCop, closeTo(1700.0, 0.1));
    expect(updated.day.solarStartTime, '08:25');

    // Cambiar tarifa a 1000 COP/kWh debe recalcular el ahorro sobre consumo de casa
    final withNewTariff = updated.withTariff(1000.0);
    expect(withNewTariff.day.savingsCop, closeTo(2000.0, 0.1));
  });

  test('SolarReading estima autonomía en descarga y carga', () {
    final discharging = SolarReading(
      timestamp: DateTime.now(),
      epochMs: 1700000000000,
      batteryVoltage: 52.0,
      batterySoc: 70.0,
      pvPowerW: 0.0,
      batteryPowerW: -491.0,
      batteryChargeW: 0.0,
      batteryDischargeW: 491.0,
      loadPowerW: 491.0,
      status: SolarSystemStatus.discharging,
      isCritical: false,
      sourceMode: 'LOCAL',
    );
    // (70 - 30) * 49.1 Wh = 1964 Wh / 491 W = 4h 00m
    expect(discharging.estimateAutonomy(threshold: 30.0), '4h 00m hasta 30%');
  });
}
