import 'dart:async';
import 'dart:io';

/// Arranca el backend Go (pcinfo-backend) como proceso HIJO mientras la app está
/// abierta (estilo HWiNFO: NO hay servicio en 2º plano). Primero sondea /healthz
/// por si ya hay una instancia (otra ventana, o el servicio systemd en Linux)
/// para no duplicar el proceso.
///
/// ELEVACIÓN (Windows): la GUI corre como asInvoker (abre siempre, sin UAC). Para
/// leer el S.M.A.R.T. hace falta admin, así que el backend se lanza ELEVADO con
/// `Start-Process -Verb RunAs` (un único UAC, solo para el disco). Si el usuario
/// CANCELA el UAC o algo falla, se cae a lanzar el backend NORMAL (sin elevación):
/// la app funciona igual, solo el disco sale sin salud. Como un proceso elevado no
/// se puede matar desde una GUI no elevada, el backend recibe `--parent-pid` y se
/// autodestruye al cerrarse la GUI. `stop()` mata además el backend no elevado que
/// sí lanzamos nosotros. En Linux ensureRunning ve el /healthz del servicio root y
/// no lanza nada.
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

    // Argumentos comunes: dirección + PID de esta GUI (para que el backend se
    // cierre solo cuando la app se cierre, incluso si corre elevado).
    final args = <String>['--addr', '$host:$port', '--parent-pid', '$pid'];

    // Windows: intentar ELEVADO (UAC) para tener SMART; si se cancela, caer a
    // no elevado. En Linux/otros, lanzar normal (el servicio ya da privilegios).
    if (Platform.isWindows) {
      if (await _startElevated(bin, args)) {
        if (await _waitHealthy(60)) return true; // el UAC puede tardar en aceptarse
      }
      // Respaldo: sin elevación (la app abre, el disco sale sin salud).
    }

    try {
      // Detached (sin consola/pipes); guardamos el Process para matarlo en
      // stop(). Como ya sondeamos /healthz, no se duplica el proceso.
      _proc = await Process.start(
        bin.path,
        args,
        mode: ProcessStartMode.detached,
        workingDirectory: bin.parent.path,
      );
    } catch (_) {
      return false;
    }
    return _waitHealthy(25);
  }

  /// Lanza el backend ELEVADO en Windows vía `Start-Process -Verb RunAs` (UAC).
  /// Devuelve true si PowerShell reportó que lo lanzó (exit 0); false si el
  /// usuario canceló el UAC o hubo error → el llamador cae al lanzamiento normal.
  /// No se guarda handle: el backend elevado se autodestruye por --parent-pid.
  Future<bool> _startElevated(File bin, List<String> args) async {
    // ArgumentList de PowerShell: cada token entre comillas simples.
    final list = args.map((a) => "'$a'").join(',');
    final ps =
        "try { Start-Process -FilePath '${bin.path}' "
        "-WorkingDirectory '${bin.parent.path}' "
        "-ArgumentList $list -Verb RunAs -WindowStyle Hidden -ErrorAction Stop } "
        "catch { exit 1 }";
    try {
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', ps],
      );
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Sondea /healthz hasta [maxTries] veces (200 ms c/u). El arranque en frío del
  /// colector tarda poco; con elevación, además hay que esperar a que el usuario
  /// acepte el UAC, por eso el llamador usa una ventana más larga.
  Future<bool> _waitHealthy(int maxTries) async {
    for (var i = 0; i < maxTries; i++) {
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
