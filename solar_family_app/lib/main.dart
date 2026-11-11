import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/repositories/solar_repository.dart';
import 'data/services/mqtt_solar_service.dart';
import 'data/services/notification_alert_service.dart';
import 'ui/features/dashboard/view_models/solar_dashboard_view_model.dart';
import 'ui/features/dashboard/views/solar_dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final mqttService = MqttSolarService();
  final notificationService = NotificationAndAlertService();
  final repository = SolarRepository(
    mqttService: mqttService,
    notificationService: notificationService,
  );
  final dashboardViewModel = SolarDashboardViewModel(repository: repository);

  // Iniciar la interfaz gráfica inmediatamente sin bloquear la pantalla de arranque
  runApp(SolarFamilyApp(viewModel: dashboardViewModel));

  // Inicializar notificaciones y conexión MQTT en segundo plano
  unawaited(dashboardViewModel.init());
}

class SolarFamilyApp extends StatelessWidget {
  const SolarFamilyApp({super.key, required this.viewModel});

  final SolarDashboardViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitor Solar Familiar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B101B),
      ),
      home: SolarDashboardScreen(viewModel: viewModel),
    );
  }
}
