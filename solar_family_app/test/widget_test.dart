import 'package:flutter_test/flutter_test.dart';
import 'package:solar_family_monitor/data/services/background_solar_worker.dart';
import 'package:solar_family_monitor/data/services/mqtt_solar_service.dart';
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

  test('MqttSolarService intenta failover automático a broker Nube si falla red local', () async {
    final service = MqttSolarService();
    // Usar puertos locales cerrados para verificar que intenta local y luego conmuta a nube
    await service.connect(
      host: '127.0.0.1',
      port: 39881,
      cloudHost: '127.0.0.1',
      cloudPort: 39882,
      cloudUsername: 'u',
      cloudPassword: 'p',
      cloudUseTls: true,
    );

    final diag = service.currentDiagnostics;
    expect(diag.cloudConfigured, isTrue);
    expect(diag.isCloudConnection, isTrue);
    expect(diag.targetHost, '127.0.0.1');
    expect(diag.targetPort, 39882);

    await service.dispose();
  });

  test('BackgroundSolarMonitor filtra lecturas antiguas y respeta cooldown y umbral', () {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    SolarReading makeReading(double soc, int epochMs) => SolarReading(
          timestamp: DateTime.fromMillisecondsSinceEpoch(epochMs),
          epochMs: epochMs,
          batteryVoltage: 48.0,
          batterySoc: soc,
          pvPowerW: 0.0,
          batteryPowerW: -500.0,
          batteryChargeW: 0.0,
          batteryDischargeW: 500.0,
          loadPowerW: 500.0,
          status: SolarSystemStatus.discharging,
          isCritical: soc < 30.0,
          sourceMode: 'CLOUD',
        );

    // Lectura vieja (> 25 min) no debe disparar falsa alarma
    expect(
      BackgroundSolarMonitor.shouldTriggerBackgroundAlert(
        reading: makeReading(20.0, nowMs - 30 * 60 * 1000),
        threshold: 30.0,
        nowMs: nowMs,
      ),
      isFalse,
    );

    // Lectura fresca bajo el umbral sin cooldown sí dispara
    expect(
      BackgroundSolarMonitor.shouldTriggerBackgroundAlert(
        reading: makeReading(25.0, nowMs - 10 * 1000),
        threshold: 30.0,
        nowMs: nowMs,
      ),
      isTrue,
    );

    // Lectura fresca bajo el umbral dentro del cooldown (5 min) no repite
    expect(
      BackgroundSolarMonitor.shouldTriggerBackgroundAlert(
        reading: makeReading(25.0, nowMs - 10 * 1000),
        threshold: 30.0,
        nowMs: nowMs,
        lastAlertEpochMs: nowMs - 5 * 60 * 1000,
      ),
      isFalse,
    );

    // Lectura fresca sobre el umbral no dispara
    expect(
      BackgroundSolarMonitor.shouldTriggerBackgroundAlert(
        reading: makeReading(40.0, nowMs - 10 * 1000),
        threshold: 30.0,
        nowMs: nowMs,
      ),
      isFalse,
    );

    // En red pública (loadPowerW == 0, batería al 8%) NO debe disparar alertas
    final onPublicGrid = SolarReading(
      timestamp: DateTime.fromMillisecondsSinceEpoch(nowMs),
      epochMs: nowMs,
      batteryVoltage: 50.0,
      batterySoc: 8.0,
      pvPowerW: 0.0,
      batteryPowerW: 0.0,
      batteryChargeW: 0.0,
      batteryDischargeW: 0.0,
      loadPowerW: 0.0,
      status: SolarSystemStatus.idle,
      isCritical: true,
      sourceMode: 'SMARTESS_CLOUD',
    );
    expect(onPublicGrid.shouldTriggerLowBatteryAlert(threshold: 30.0), isFalse);
    expect(
      BackgroundSolarMonitor.shouldTriggerBackgroundAlert(
        reading: onPublicGrid,
        threshold: 30.0,
        nowMs: nowMs,
      ),
      isFalse,
    );

    // Cargando por paneles solares (25% pero carga neta +500 W) NO debe alarmar
    final chargingSolar = SolarReading(
      timestamp: DateTime.fromMillisecondsSinceEpoch(nowMs),
      epochMs: nowMs,
      batteryVoltage: 51.5,
      batterySoc: 25.0,
      pvPowerW: 800.0,
      batteryPowerW: 500.0,
      batteryChargeW: 500.0,
      batteryDischargeW: 0.0,
      loadPowerW: 300.0,
      status: SolarSystemStatus.charging,
      isCritical: false,
      sourceMode: 'SMARTESS_CLOUD',
    );
    expect(chargingSolar.shouldTriggerLowBatteryAlert(threshold: 30.0), isFalse);
  });
}
