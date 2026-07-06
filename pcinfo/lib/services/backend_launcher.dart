import 'dart:async';
import 'dart:io';

/// Arranca el backend Go (pcinfo-backend) como proceso HIJO mientras la app está
/// abierta y lo mata al cerrar (estilo HWiNFO: NO hay servicio en 2º plano). El
/// backend hereda la elevación de la GUI (manifest requireAdministrator en
/// Windows), así que puede leer el SMART. Primero sondea /healthz por si ya hay
/// una instancia (p. ej. otra ventana abierta) para no duplicar el proceso; si
/// nadie responde, lanza el binario empaquetado. `stop()` lo termina al cerrar.
/// En Linux el .deb sí usa un servicio systemd (root); ahí ensureRunning ve el
/// /healthz y no lanza nada.
class BackendLauncher {
  /// Puerto/host fijo del backend (debe coincidir con HttpHardwareService y los
  /// instaladores: 127.0.0.1:51247).
  static const String host = '127.0.0.1';
  static const int port = 51247;

  Process? _proc;

  /// Garantiza que haya un backend respondiendo. Devuelve true si al terminar
  /// /healthz responde (sea el que ya estaba o el que se acaba de lanzar).
  /// Nunca lanza excepción: si algo falla, la GUI muestra el estado de error.
  Future<bool> ensureRunning() async {
    if (await _healthy()) return true; // ya corre (otra ventana, o servicio en Linux)

    final bin = _locateBinary();
    if (bin == null) return false; // sin binario empaquetado (p. ej. dev sin build)

    try {
      // Detached (sin consola/pipes); guardamos el Process para matarlo en
      // stop(). Como ya sondeamos /healthz, no se duplica el proceso.
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
