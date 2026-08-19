// Modelos de la pestaña "Controladores" — espejo del JSON de GET /controladores
// y GET /controladores/tarea (backend/collector/drivers.go). Mantener los
// nombres de campo sincronizados: este archivo ES el contrato de datos del
// módulo.

/// Acciones que puede ejecutar la pestaña.
class TareaKind {
  static const respaldar = 'respaldar';
  static const restaurar = 'restaurar';
}

/// Nivel de cada línea del registro de avance.
class PasoNivel {
  static const info = 'info';
  static const ok = 'ok';
  static const aviso = 'aviso';
  static const error = 'error';
}

/// Subcarpetas que crea el respaldo dentro de la carpeta elegida. Deben coincidir
/// con las constantes CarpetaDrivers/CarpetaWifi del backend.
class CarpetaRespaldo {
  static const drivers = 'Controladores';
  static const wifi = 'RedesWiFi';
}

class DriverItem {
  final String name; // oem12.inf
  final String original; // nombre original del .inf del fabricante
  final String clase; // Sistema, Impresoras, Red…
  final String provider;
  final String version;
  final String date;

  const DriverItem({
    this.name = '',
    this.original = '',
    this.clase = '',
    this.provider = '',
    this.version = '',
    this.date = '',
  });

  factory DriverItem.fromJson(Map<String, dynamic> j) => DriverItem(
        name: j['name'] ?? '',
        original: j['original'] ?? '',
        clase: j['class'] ?? '',
        provider: j['provider'] ?? '',
        version: j['version'] ?? '',
        date: j['date'] ?? '',
      );

  /// Nombre útil: el original del fabricante si se conoce, y si no el oemN.inf
  /// con el que lo guardó Windows.
  String get visible => original.isEmpty ? name : original;
}

class WifiProfile {
  final String name; // SSID
  final String auth; // WPA2PSK, WPA3SAE, open…
  final String password; // vacío si no se pudo leer (hace falta admin)

  const WifiProfile({this.name = '', this.auth = '', this.password = ''});

  factory WifiProfile.fromJson(Map<String, dynamic> j) => WifiProfile(
        name: j['name'] ?? '',
        auth: j['auth'] ?? '',
        password: j['password'] ?? '',
      );

  bool get abierta => auth.toLowerCase() == 'open';
}

class ControladoresInfo {
  final String os;
  final bool supported; // ¿el módulo existe en este sistema? (solo Windows)
  final bool elevated; // ¿el backend corre como administrador?
  final bool available;
  final String reason;
  final List<DriverItem> drivers;
  final List<WifiProfile> wifi;

  const ControladoresInfo({
    this.os = '',
    this.supported = false,
    this.elevated = false,
    this.available = false,
    this.reason = '',
    this.drivers = const [],
    this.wifi = const [],
  });

  factory ControladoresInfo.fromJson(Map<String, dynamic> j) =>
      ControladoresInfo(
        os: j['os'] ?? '',
        supported: j['supported'] ?? false,
        elevated: j['elevated'] ?? false,
        available: j['available'] ?? false,
        reason: j['reason'] ?? '',
        drivers: (j['drivers'] as List?)
                ?.map((e) => DriverItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        wifi: (j['wifi'] as List?)
                ?.map((e) => WifiProfile.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  /// ¿Se puede respaldar/restaurar ya mismo? Todo el módulo escribe en el
  /// sistema y necesita administrador.
  bool get puedeOperar => supported && elevated;
}

class PasoTarea {
  final String when; // "14:02:11"
  final String text;
  final String level; // ver PasoNivel

  const PasoTarea({this.when = '', this.text = '', this.level = ''});

  factory PasoTarea.fromJson(Map<String, dynamic> j) => PasoTarea(
        when: j['when'] ?? '',
        text: j['text'] ?? '',
        level: j['level'] ?? '',
      );
}

class TareaInfo {
  final String id;
  final String kind; // respaldar | restaurar
  final bool drivers;
  final bool wifi;
  final String folder;
  final bool running;
  final bool done;
  final bool ok;
  final String started;
  final String finished;
  final String error;
  final String summary;
  final int omitted;
  final List<PasoTarea> steps;

  const TareaInfo({
    this.id = '',
    this.kind = '',
    this.drivers = false,
    this.wifi = false,
    this.folder = '',
    this.running = false,
    this.done = false,
    this.ok = false,
    this.started = '',
    this.finished = '',
    this.error = '',
    this.summary = '',
    this.omitted = 0,
    this.steps = const [],
  });

  factory TareaInfo.fromJson(Map<String, dynamic> j) => TareaInfo(
        id: j['id'] ?? '',
        kind: j['kind'] ?? '',
        drivers: j['drivers'] ?? false,
        wifi: j['wifi'] ?? false,
        folder: j['folder'] ?? '',
        running: j['running'] ?? false,
        done: j['done'] ?? false,
        ok: j['ok'] ?? false,
        started: j['started'] ?? '',
        finished: j['finished'] ?? '',
        error: j['error'] ?? '',
        summary: j['summary'] ?? '',
        omitted: (j['omitted'] ?? 0) as int,
        steps: (j['steps'] as List?)
                ?.map((e) => PasoTarea.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  /// ¿Hay algo que mostrar? Al arrancar la app no hay ninguna tarea todavía.
  bool get existe => id.isNotEmpty;

  String get verbo => kind == TareaKind.restaurar ? 'Restauración' : 'Respaldo';
}
