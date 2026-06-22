import 'package:flutter/material.dart';
import 'services/hardware_service.dart';
import 'theme.dart';
import 'ui/dashboard_page.dart';

void main() {
  runApp(const PcInfoApp());
}

class PcInfoApp extends StatelessWidget {
  const PcInfoApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Fuente de datos: backend Go en localhost; si no está corriendo, cae al
    // mock para que la GUI siga mostrándose.
    final service = HttpHardwareService(fallback: MockHardwareService());
    return MaterialApp(
      title: 'PCInfo',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: DashboardPage(service: service),
    );
  }
}
