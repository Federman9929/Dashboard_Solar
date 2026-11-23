import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';

import '../../domain/models/solar_reading.dart';

/// Actualiza los datos del Widget nativo en la pantalla principal de Android.
class SolarHomeWidgetService {
  static const String _androidProviderName = 'SolarHomeWidgetProvider';
  static DateTime? _lastForegroundUpdate;
  static String? _lastSocTag;

  static Future<void> updateFromReading({
    required SolarReading reading,
    required double todaySavingsCop,
    double threshold = 30.0,
    bool force = false,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;

    final now = DateTime.now();
    final socTag = '${reading.batterySoc.toStringAsFixed(0)}_${reading.status.name}';
    if (!force &&
        _lastForegroundUpdate != null &&
        _lastSocTag == socTag &&
        now.difference(_lastForegroundUpdate!).inSeconds < 12) {
      return;
    }
    _lastForegroundUpdate = now;
    _lastSocTag = socTag;

    final socText = '${reading.batterySoc.toStringAsFixed(1)}%';
    final socColor = reading.batterySoc < threshold
        ? '#FFFF5252'
        : reading.batterySoc < (threshold + 12.0)
            ? '#FFFFB300'
            : '#FF00E676';

    final String stateLabel;
    final String battPowerStr;
    if (reading.status == SolarSystemStatus.charging ||
        reading.batteryPowerW > 15.0) {
      final w = reading.batteryChargeW > 0
          ? reading.batteryChargeW
          : reading.batteryPowerW.abs();
      stateLabel = '⚡ Cargando';
      battPowerStr = '+${w.toStringAsFixed(0)} W • ${reading.batteryVoltage.toStringAsFixed(1)} V';
    } else if (reading.status == SolarSystemStatus.discharging ||
        reading.batteryPowerW < -15.0) {
      final w = reading.batteryDischargeW > 0
          ? reading.batteryDischargeW
          : reading.batteryPowerW.abs();
      stateLabel = '🔋 Descargando';
      battPowerStr = '-${w.toStringAsFixed(0)} W • ${reading.batteryVoltage.toStringAsFixed(1)} V';
    } else {
      stateLabel = '⏸️ En reposo';
      battPowerStr = '0 W • ${reading.batteryVoltage.toStringAsFixed(1)} V';
    }

    final pvText = '${reading.pvPowerW.toStringAsFixed(0)} W';
    final loadText = '${reading.loadPowerW.toStringAsFixed(0)} W';
    final savingsFormatted =
        '\$${NumberFormat('#,##0', 'es_CO').format(todaySavingsCop.round())} COP';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    try {
      await Future.wait([
        HomeWidget.saveWidgetData<String>('soc_text', socText),
        HomeWidget.saveWidgetData<String>('soc_color', socColor),
        HomeWidget.saveWidgetData<String>('battery_state_text', stateLabel),
        HomeWidget.saveWidgetData<String>('battery_power_text', battPowerStr),
        HomeWidget.saveWidgetData<String>('pv_power_text', pvText),
        HomeWidget.saveWidgetData<String>('load_power_text', loadText),
        HomeWidget.saveWidgetData<String>('today_savings_text', savingsFormatted),
        HomeWidget.saveWidgetData<String>('updated_at_text', timeStr),
      ]);
      await HomeWidget.updateWidget(androidName: _androidProviderName);
    } catch (e) {
      debugPrint('Error actualizando widget de inicio: $e');
    }
  }
}
