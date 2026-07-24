import 'package:flutter/material.dart';
import 'services/backend_launcher.dart';
import 'services/errores_service.dart';
import 'services/hardware_service.dart';
import 'theme.dart';
import 'ui/dashboard_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Arranca el backend Go si no hay uno corriendo (en producción ya está como
  // servicio/autostart; esto cubre dev y portable). Acotado por su propio poll;
  // si no levanta, la GUI muestra el mock igualmente.
  final launcher = BackendLauncher();
  await launcher.ensureRunning();
  runApp(PcInfoApp(launcher: launcher));
}

class PcInfoApp extends StatefulWidget {
  final BackendLauncher launcher;
  const PcInfoApp({super.key, required this.launcher});

  @override
  State<PcInfoApp> createState() => _PcInfoAppState();
}

class _PcInfoAppState extends State<PcInfoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al cerrar la app, detener SOLO el backend que lanzamos nosotros (si fue el
    // servicio/autostart, BackendLauncher.stop() no lo toca).
    if (state == AppLifecycleState.detached) widget.launcher.stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.launcher.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fuente de datos: backend Go en localhost. SIN fallback al mock: si el
    // backend no responde preferimos mostrar un error claro con "Reintentar"
    // antes que datos de ejemplo que el usuario podría confundir con los reales.
    final service = HttpHardwareService();
    return MaterialApp(
      title: 'PCInfo',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: DashboardPage(
        service: service,
        erroresService: HttpErroresService(),
        launcher: widget.launcher,
      ),
    );
  }
}
