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
    // Fuente de datos. Hoy mock; al integrar el backend Go se cambia por
    // HttpHardwareService sin tocar la UI.
    final service = MockHardwareService();
    return MaterialApp(
      title: 'PCInfo',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: DashboardPage(service: service),
    );
  }
}
