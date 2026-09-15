// Modelos de la pestaña "Tienda Windows" — espejo del JSON de
// GET /tienda, GET /tienda/buscar y GET /tienda/tarea
// (backend/collector/tienda.go).

/// Nivel de cada línea del registro de avance (igual que Controladores).
class PasoTiendaNivel {
  static const info = 'info';
  static const ok = 'ok';
  static const aviso = 'aviso';
  static const error = 'error';
}

/// Arquitecturas y canales que acepta el instalador (mismos que la
/// herramienta original `mitiendawindows`).
class TiendaArch {
  static const opciones = ['Auto', 'x64', 'x86', 'arm64'];
}

class TiendaRing {
  static const opciones = ['Retail', 'RP', 'WIS', 'WIF'];
}

/// Una app de la Microsoft Store, identificada por su ProductId.
class AppTienda {
  final String nombre;
  final String productId;

  const AppTienda({this.nombre = '', this.productId = ''});

  factory AppTienda.fromJson(Map<String, dynamic> j) => AppTienda(
        nombre: j['nombre'] ?? '',
        productId: j['productId'] ?? '',
      );

  Map<String, dynamic> toJson() => {'nombre': nombre, 'productId': productId};
}

/// Extrae el ProductId de un enlace de la Store o lo deja tal cual si ya es
/// uno (12-14 alfanuméricos). Espejo en Dart de Get-ProductId
/// (tienda_windows.ps1): mismo criterio, para que la lista de espera muestre
/// el ID reconocido antes de instalar, no el enlace pegado.
///
/// Acepta:
///   https://apps.microsoft.com/detail/9WZDNCRFHVJL
///   https://www.microsoft.com/store/productId/9WZDNCRFHVJL
///   ms-windows-store://pdp/?productid=9WZDNCRFHVJL
///   9WZDNCRFHVJL
String? extraeProductId(String texto) {
  final t = texto.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty) return null;
  if (RegExp(r'^[A-Za-z0-9]{12,14}$').hasMatch(t)) return t.toUpperCase();
  final m1 = RegExp(
    r'(?:productid=|/detail/|/productId/|/apps/|/store/apps/|/p/[^/]+/)([A-Za-z0-9]{12,14})',
    caseSensitive: false,
  ).firstMatch(t);
  if (m1 != null) return m1.group(1)!.toUpperCase();
  final m2 = RegExp(r'\b([9Xx][A-Za-z0-9]{11,13})\b').firstMatch(t);
  if (m2 != null) return m2.group(1)!.toUpperCase();
  return null;
}

/// TiendaInfo es la respuesta de GET /tienda.
class TiendaInfo {
  final String os;
  final bool supported; // ¿el módulo existe en este sistema? (solo Windows)
  final bool elevated; // ¿el backend corre como administrador?
  final String reason;
  final List<AppTienda> catalogo;

  const TiendaInfo({
    this.os = '',
    this.supported = false,
    this.elevated = false,
    this.reason = '',
    this.catalogo = const [],
  });

  factory TiendaInfo.fromJson(Map<String, dynamic> j) => TiendaInfo(
        os: j['os'] ?? '',
        supported: j['supported'] ?? false,
        elevated: j['elevated'] ?? false,
        reason: j['reason'] ?? '',
        catalogo: (j['catalogo'] as List?)
                ?.map((e) => AppTienda.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  /// ¿Se puede instalar ya mismo? Todo el módulo escribe en el sistema y
  /// necesita administrador (DISM).
  bool get puedeOperar => supported && elevated;
}

class PasoTienda {
  final String when;
  final String text;
  final String level; // ver PasoTiendaNivel

  const PasoTienda({this.when = '', this.text = '', this.level = ''});

  factory PasoTienda.fromJson(Map<String, dynamic> j) => PasoTienda(
        when: j['when'] ?? '',
        text: j['text'] ?? '',
        level: j['level'] ?? '',
      );
}

class TareaTiendaInfo {
  final String id;
  final List<AppTienda> apps;
  final bool running;
  final bool done;
  final bool ok;
  final String started;
  final String finished;
  final String error;
  final String summary;
  final int omitted;
  final List<PasoTienda> steps;

  const TareaTiendaInfo({
    this.id = '',
    this.apps = const [],
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

  factory TareaTiendaInfo.fromJson(Map<String, dynamic> j) => TareaTiendaInfo(
        id: j['id'] ?? '',
        apps: (j['apps'] as List?)
                ?.map((e) => AppTienda.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        running: j['running'] ?? false,
        done: j['done'] ?? false,
        ok: j['ok'] ?? false,
        started: j['started'] ?? '',
        finished: j['finished'] ?? '',
        error: j['error'] ?? '',
        summary: j['summary'] ?? '',
        omitted: (j['omitted'] ?? 0) as int,
        steps: (j['steps'] as List?)
                ?.map((e) => PasoTienda.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  bool get existe => id.isNotEmpty;
}
