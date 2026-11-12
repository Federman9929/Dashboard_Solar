/// Modo de alerta cuando la batería solar baja del umbral configurado (setpoint).
enum BatteryAlertMode {
  simpleNotification(
    'simple',
    'Silenciosa',
    'Notificación simple con sonido y vibración',
  ),
  immediateAlarm(
    'alarm',
    'Alarma',
    'Alarma sonora continua inmediata',
  );

  const BatteryAlertMode(this.code, this.displayName, this.description);

  final String code;
  final String displayName;
  final String description;

  static BatteryAlertMode fromCode(String? code) {
    if (code == 'alarm') return BatteryAlertMode.immediateAlarm;
    return BatteryAlertMode.simpleNotification;
  }
}
