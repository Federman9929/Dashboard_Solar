/// Modo de alerta cuando la batería solar baja del umbral configurado (setpoint).
enum BatteryAlertMode {
  simpleNotification(
    'simple',
    'Notificación Simple',
    'Aviso notorio con sonido del sistema y vibración (sin sirena continua)',
  ),
  immediateAlarm(
    'alarm',
    'Alarma Inmediata',
    'Alarma sonora continua tipo sirena que alerta de inmediato hasta silenciar',
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
