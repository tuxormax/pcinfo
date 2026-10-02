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

/// Qué se hace con un componente del catálogo de casos conocidos.
class ViaCaso {
  static const quitar = 'quitar'; // no se le pone controlador: se quita
  static const generico = 'generico'; // se deja el de Microsoft a propósito
  static const fabricante = 'fabricante'; // hace falta uno concreto
}

/// Explicación de catálogo para un dispositivo que aparece sin controlador.
/// Espejo de CasoConocido (backend/collector/casos_conocidos.go).
class CasoConocido {
  final String id;
  final String nombre;
  final String descripcion; // qué ES el aparato, en llano
  final String via; // ver ViaCaso
  final String motivo; // por qué está así
  final String fuente;

  const CasoConocido({
    this.id = '',
    this.nombre = '',
    this.descripcion = '',
    this.via = '',
    this.motivo = '',
    this.fuente = '',
  });

  factory CasoConocido.fromJson(Map<String, dynamic> j) => CasoConocido(
        id: j['id'] ?? '',
        nombre: j['nombre'] ?? '',
        descripcion: j['descripcion'] ?? '',
        via: j['via'] ?? '',
        motivo: j['motivo'] ?? '',
        fuente: j['fuente'] ?? '',
      );

  /// Titular de la explicación. Las dos primeras vías dicen "está bien así";
  /// la tercera dice que de verdad falta algo, y por eso se pinta distinto.
  String get titular {
    switch (via) {
      case ViaCaso.quitar:
        return 'Está así a propósito';
      case ViaCaso.generico:
        return 'Usa el controlador de Windows a propósito';
      default:
        return 'Le falta un controlador concreto';
    }
  }

  /// ¿Es un "no te preocupes" o un "esto sí hay que atender"?
  bool get intencional => via == ViaCaso.quitar || via == ViaCaso.generico;
}

/// Dispositivo que Windows marca con un problema (sin controlador,
/// deshabilitado, detenido). SOLO LECTURA: PCInfo no instala nada aquí.
class DispositivoPendiente {
  final String nombre;
  final String clase; // vacío = Windows no sabe ni qué es
  final String instanceId;
  final String hardwareId;
  final int codigo; // el "Código 28" del Administrador de dispositivos
  final String estado; // ese código, ya redactado
  final CasoConocido? conocido; // null = no se reconoce (lo normal)

  const DispositivoPendiente({
    this.nombre = '',
    this.clase = '',
    this.instanceId = '',
    this.hardwareId = '',
    this.codigo = 0,
    this.estado = '',
    this.conocido,
  });

  factory DispositivoPendiente.fromJson(Map<String, dynamic> j) =>
      DispositivoPendiente(
        nombre: j['nombre'] ?? '',
        clase: j['clase'] ?? '',
        instanceId: j['instanceId'] ?? '',
        hardwareId: j['hardwareId'] ?? '',
        codigo: (j['codigo'] ?? 0) as int,
        estado: j['estado'] ?? '',
        conocido: j['conocido'] == null
            ? null
            : CasoConocido.fromJson(j['conocido'] as Map<String, dynamic>),
      );
}

class ControladoresInfo {
  final String os;
  final bool supported; // ¿el módulo existe en este sistema? (solo Windows)
  final bool elevated; // ¿el backend corre como administrador?
  final bool available;

  /// ¿Hay controladores y dispositivos pendientes? Solo en Windows; en Linux el módulo es solo WiFi.
  final bool driversAplica;
  final String reason;
  final List<DriverItem> drivers;
  final List<WifiProfile> wifi;

  /// Dispositivos con problema. A diferencia del resto del módulo, esto NO
  /// necesita administrador: sale aunque la lista de controladores venga vacía.
  final List<DispositivoPendiente> pendientes;

  const ControladoresInfo({
    this.os = '',
    this.supported = false,
    this.elevated = false,
    this.available = false,
    this.driversAplica = true,
    this.reason = '',
    this.drivers = const [],
    this.wifi = const [],
    this.pendientes = const [],
  });

  factory ControladoresInfo.fromJson(Map<String, dynamic> j) =>
      ControladoresInfo(
        os: j['os'] ?? '',
        supported: j['supported'] ?? false,
        elevated: j['elevated'] ?? false,
        available: j['available'] ?? false,
        driversAplica: j['driversAplica'] ?? true,
        reason: j['reason'] ?? '',
        drivers: (j['drivers'] as List?)
                ?.map((e) => DriverItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        wifi: (j['wifi'] as List?)
                ?.map((e) => WifiProfile.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        pendientes: (j['pendientes'] as List?)
                ?.map((e) =>
                    DispositivoPendiente.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  /// ¿Se puede respaldar/restaurar ya mismo? Todo el módulo escribe en el
  /// sistema y necesita administrador.
  bool get puedeOperar => supported && elevated;

  /// Los dispositivos con problema que el catálogo sabe explicar.
  List<DispositivoPendiente> get pendientesExplicados =>
      pendientes.where((d) => d.conocido != null).toList();
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
