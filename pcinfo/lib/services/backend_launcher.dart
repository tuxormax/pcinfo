import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../version.dart';

/// Identidad del backend que está contestando en el puerto. La publica /healthz
/// desde la Rev 31; un backend anterior responde sólo "ok" y queda [identificado]
/// en false, que ya es señal de que es viejo.
class BackendInfo {
  const BackendInfo({
    this.vivo = false,
    this.version = '',
    this.revision = '',
    this.exe = '',
    this.pid = 0,
  });

  final bool vivo;
  final String version;
  final String revision;
  final String exe;
  final int pid;

  bool get identificado => version.isNotEmpty;

  /// Backend compilado a mano (sin los -ldflags de los scripts de construcción).
  /// No se toca: es el flujo de desarrollo.
  bool get esDesarrollo => version == 'dev';

  /// Coincide con la versión de ESTA app.
  bool get coincide => version == appVersion && revision == '$appRevision';

  String get etiqueta => identificado
      ? 'v$version Rev $revision'
      : 'una versión anterior a la Rev 31';
}

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

  /// Backend que quedó contestando tras [ensureRunning]. Si [desfasado] es true,
  /// es de OTRA versión y no se pudo reemplazar: la GUI lo avisa, porque explica
  /// que sigan apareciendo fallos ya corregidos en la versión instalada.
  BackendInfo info = const BackendInfo();
  bool desfasado = false;

  /// Garantiza que haya un backend respondiendo Y que sea el de ESTA versión.
  /// Devuelve true si al terminar /healthz responde (el que ya estaba, o el que
  /// se acaba de lanzar). Nunca lanza excepción: si algo falla, la GUI muestra
  /// el estado de error.
  ///
  /// El puerto es fijo (51247), así que un backend VIEJO que siguiera vivo tras
  /// actualizar (típico: instalar encima sin cerrar la app) se quedaría con él y
  /// la versión nueva hablaría con el binario anterior. Por eso aquí no basta
  /// con que "algo responda": se comprueba QUIÉN responde y, si no es el nuestro,
  /// se intenta reemplazar. Si no se puede (corre elevado, o es el servicio root
  /// de Linux), se usa igual y se marca [desfasado] en vez de dejar la app sin
  /// datos.
  Future<bool> ensureRunning() async {
    final bin = _locateBinary();
    info = await _estado();
    if (info.vivo && _esNuestro(info)) return true;

    if (bin == null) {
      // Sin binario propio (dev sin build): usar lo que haya, si hay algo.
      desfasado = info.vivo;
      return info.vivo;
    }

    if (info.vivo) {
      // Backend de otra versión ocupando el puerto: quitarlo de en medio.
      await _mataAjeno(info);
      if (!await _waitUnhealthy(25)) {
        desfasado = true;
        return true; // no se pudo: mejor datos de la versión vieja que nada
      }
    }

    // Argumentos comunes: dirección + PID de esta GUI (para que el backend se
    // cierre solo cuando la app se cierre, incluso si corre elevado).
    final args = <String>['--addr', '$host:$port', '--parent-pid', '$pid'];

    // Windows: intentar ELEVADO (UAC) para tener SMART; si se cancela, caer a
    // no elevado. En Linux/otros, lanzar normal (el servicio ya da privilegios).
    if (Platform.isWindows) {
      if (await _startElevated(bin, args)) {
        // el UAC puede tardar en aceptarse
        if (await _waitHealthy(60)) return _confirma();
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
    if (!await _waitHealthy(25)) return false;
    return _confirma();
  }

  /// Relee /healthz tras lanzar el backend para dejar [info]/[desfasado] al día.
  Future<bool> _confirma() async {
    info = await _estado();
    desfasado = info.vivo && !_esNuestro(info);
    return info.vivo;
  }

  /// ¿El backend que contesta es el de esta versión?
  ///  - sin identificar → es anterior a la Rev 31 (no publica su versión);
  ///  - "dev" → compilado a mano: se respeta (flujo de desarrollo);
  ///  - si no, tiene que coincidir versión + revisión con la app.
  bool _esNuestro(BackendInfo h) {
    if (!h.identificado) return false;
    if (h.esDesarrollo) return true;
    return h.coincide;
  }

  /// Termina el backend de otra versión que ocupa el puerto.
  /// En Windows por nombre de imagen (si corre ELEVADO y la GUI no lo está, el
  /// taskkill falla: el llamador lo detecta porque el puerto sigue ocupado).
  /// En Linux NO se toca: ahí el backend es el servicio root del paquete, que se
  /// actualiza con el .deb; matarlo desde la GUI ni se puede ni corresponde.
  Future<void> _mataAjeno(BackendInfo h) async {
    stop(); // por si fue uno lanzado por esta misma app
    if (!Platform.isWindows) return;
    // Por PID si /healthz lo dijo (preciso); si no, por nombre de imagen (el
    // backend anterior a la Rev 31 no publica su PID).
    final args = h.pid > 0
        ? <String>['/F', '/PID', '${h.pid}']
        : <String>['/F', '/IM', 'pcinfo-backend.exe'];
    try {
      await Process.run('taskkill', args);
    } catch (_) {
      // sin permisos o sin taskkill: se sigue con el que hay
    }
  }

  /// Reintenta dejar el backend corriendo ELEVADO (Windows). Se usa cuando el
  /// arranque cayó a modo no elevado (UAC cancelado) y el usuario pulsa
  /// "Reintentar como administrador" en la ficha de discos. Primero MATA el
  /// backend no elevado que lanzamos como respaldo (ocupa el puerto 51247),
  /// espera a que el puerto se libere y relanza con UAC. Devuelve true si el
  /// backend elevado quedó respondiendo. Idempotente: si ya está elevado y sano,
  /// el llamador simplemente refresca.
  Future<bool> retryElevated() async {
    if (!Platform.isWindows) return false;
    final bin = _locateBinary();
    if (bin == null) return false;
    final args = <String>['--addr', '$host:$port', '--parent-pid', '$pid'];
    stop(); // mata el backend no elevado (si lo lanzamos nosotros)
    await _waitUnhealthy(25); // dar tiempo a que el puerto quede libre
    if (!await _startElevated(bin, args)) return false; // UAC cancelado / error
    if (!await _waitHealthy(60)) return false; // el UAC puede tardar en aceptarse
    return _confirma();
  }

  /// Sondea hasta que /healthz DEJE de responder (puerto liberado) o se agoten
  /// los intentos. Necesario antes de relanzar: el nuevo backend no puede
  /// enlazar el puerto si el anterior sigue vivo.
  Future<bool> _waitUnhealthy(int maxTries) async {
    for (var i = 0; i < maxTries; i++) {
      if (!await _healthy()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
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

  Future<bool> _healthy() async => (await _estado()).vivo;

  /// Pregunta a /healthz QUIÉN está contestando. Un backend anterior a la Rev 31
  /// responde el texto "ok" (sin identificarse): eso deja [BackendInfo.vivo] en
  /// true e [identificado] en false, que es justo lo que hay que detectar.
  Future<BackendInfo> _estado() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final req = await client.getUrl(Uri.parse('http://$host:$port/healthz'));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      final cuerpo = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return const BackendInfo();
      try {
        final j = jsonDecode(cuerpo) as Map<String, dynamic>;
        return BackendInfo(
          vivo: true,
          version: '${j['version'] ?? ''}',
          revision: '${j['revision'] ?? ''}',
          exe: '${j['exe'] ?? ''}',
          pid: (j['pid'] as num?)?.toInt() ?? 0,
        );
      } catch (_) {
        return const BackendInfo(vivo: true); // backend viejo: solo dice "ok"
      }
    } catch (_) {
      return const BackendInfo();
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
