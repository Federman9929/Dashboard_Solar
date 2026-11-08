// Prueba básica de modelo de telemetría solar
import 'package:flutter_test/flutter_test.dart';
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
}
