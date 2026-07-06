import 'dart:async';
import 'dart:io';

/// Arranca el backend Go (pcinfo-backend) como subproceso si no hay ya uno
/// escuchando. En producción el backend YA corre como SERVICIO —systemd (root)
/// en Linux, servicio de Windows (LocalSystem) en Windows— y da datos completos
/// (dmidecode/WMI + SMART); por eso primero se sondea /healthz y, solo si nadie
/// responde (dev, portable, o el servicio caído), se lanza el binario
/// empaquetado. Así nunca choca con el servicio ni duplica el proceso en el
/// puerto. Nota: lanzado así (sin servicio) NO tiene privilegios de admin, por
/// lo que el SMART puede salir vacío; el modo normal es vía el servicio.
class BackendLauncher {
  /// Puerto/host fijo del backend (debe coincidir con HttpHardwareService y los
  /// instaladores: 127.0.0.1:51247).
  static const String host = '127.0.0.1';
  static const int port = 51247;

  Process? _proc;

  /// Garantiza que haya un backend respondiendo. Devuelve true si al terminar
  /// /healthz responde (sea el que ya estaba o el que se acaba de lanzar).
  /// Nunca lanza excepción: si algo falla, la GUI cae al mock.
  Future<bool> ensureRunning() async {
    if (await _healthy()) return true; // ya corre (servicio o instancia previa)

    final bin = _locateBinary();
    if (bin == null) return false; // sin binario empaquetado (p. ej. dev sin build)

    try {
      // Detached: el backend sobrevive como en producción; como ya sondeamos
      // /healthz antes, jamás se lanza un segundo proceso sobre el puerto.
      _proc = await Process.start(
        bin.path,
        ['--addr', '$host:$port'],
        mode: ProcessStartMode.detached,
        workingDirectory: bin.parent.path,
      );
    } catch (_) {
      return false;
    }

    // Esperar a que levante (poll ~5s). El arranque en frío del colector tarda
    // poco; si no responde a tiempo, la GUI usa el mock y reintenta en su load().
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await _healthy()) return true;
    }
    return false;
  }

  /// Detiene el backend SOLO si lo lanzamos nosotros (no toca el servicio).
  void stop() {
    _proc?.kill();
    _proc = null;
  }

  Future<bool> _healthy() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final req = await client.getUrl(Uri.parse('http://$host:$port/healthz'));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.drain<void>();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Busca el binario del backend junto al ejecutable de la app. Cubre los dos
  /// layouts de instalación y el de desarrollo:
  ///   - Windows / portable: pcinfo-backend.exe en la misma carpeta.
  ///   - Linux .deb: GUI en /opt/pcinfo/app, backend en /opt/pcinfo/backend.
  ///   - Repo (flutter run): backend compilado en la carpeta `backend`.
  File? _locateBinary() {
    final exe = File(Platform.resolvedExecutable);
    final dir = exe.parent;
    final name = Platform.isWindows ? 'pcinfo-backend.exe' : 'pcinfo-backend';
    final candidates = <String>[
      '${dir.path}${Platform.pathSeparator}$name',
      '${dir.parent.path}${Platform.pathSeparator}backend${Platform.pathSeparator}$name',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    return null;
  }
}
