// Modelos del "Software instalado" — espejo del JSON de GET /software
// (backend/collector/software.go). Mantener los nombres de campo sincronizados:
// este archivo ES el contrato de datos del módulo.

/// Clasificación de un programa (campo [SoftwareItem.kind]).
class SoftwareKind {
  static const programa = 'programa';
  static const tienda = 'tienda';
  static const actualizacion = 'actualizacion';
  static const componente = 'componente';

  /// Nombre en pantalla de cada categoría.
  static String etiqueta(String k) => switch (k) {
        programa => 'Programa',
        tienda => 'Tienda',
        actualizacion => 'Actualización',
        componente => 'Componente',
        _ => 'Otro',
      };
}

/// Quién puso el programa en el equipo (campo [SoftwareItem.origin]). Es el
/// criterio con el que se agrupa la exportación a .md.
class SoftwareOrigen {
  static const sistema = 'sistema';
  static const usuario = 'usuario';
}

class SoftwareItem {
  final String name;
  final String version;
  final String publisher;
  final String installed; // "2026-07-23" o vacío
  final int sizeMB; // 0 = desconocido
  final String location;
  final String arch;
  final String source; // de dónde salió el dato
  final String kind; // ver SoftwareKind
  final bool system; // componente/actualización: oculto por defecto
  final String origin; // ver SoftwareOrigen
  final String uninstall;

  const SoftwareItem({
    this.name = '',
    this.version = '',
    this.publisher = '',
    this.installed = '',
    this.sizeMB = 0,
    this.location = '',
    this.arch = '',
    this.source = '',
    this.kind = '',
    this.system = false,
    this.origin = '',
    this.uninstall = '',
  });

  factory SoftwareItem.fromJson(Map<String, dynamic> j) => SoftwareItem(
        name: j['name'] ?? '',
        version: j['version'] ?? '',
        publisher: j['publisher'] ?? '',
        installed: j['installed'] ?? '',
        sizeMB: (j['sizeMB'] ?? 0) as int,
        location: j['location'] ?? '',
        arch: j['arch'] ?? '',
        source: j['source'] ?? '',
        kind: j['kind'] ?? '',
        system: j['system'] ?? false,
        origin: j['origin'] ?? '',
        uninstall: j['uninstall'] ?? '',
      );

  bool get esDelSistema => origin == SoftwareOrigen.sistema;

  /// Versión mostrable: los instaladores que no la declaran dejan el campo
  /// vacío y en pantalla queda mejor un guion que un hueco.
  String get versionVisible => version.isEmpty ? '—' : version;

  /// Texto sobre el que actúa el buscador de la pestaña.
  String get buscable =>
      '$name $version $publisher $source'.toLowerCase();
}

class SoftwareInfo {
  final String os; // "windows" | "linux"
  final String source; // fuentes consultadas
  final bool available;
  final String reason; // aviso cuando algo no se pudo leer
  final int total; // todo lo encontrado (incluye componentes del sistema)
  final int visible; // lo que se muestra por defecto
  final List<SoftwareItem> items;

  const SoftwareInfo({
    this.os = '',
    this.source = '',
    this.available = false,
    this.reason = '',
    this.total = 0,
    this.visible = 0,
    this.items = const [],
  });

  factory SoftwareInfo.fromJson(Map<String, dynamic> j) => SoftwareInfo(
        os: j['os'] ?? '',
        source: j['source'] ?? '',
        available: j['available'] ?? false,
        reason: j['reason'] ?? '',
        total: (j['total'] ?? 0) as int,
        visible: (j['visible'] ?? 0) as int,
        items: (j['items'] as List?)
                ?.map((e) => SoftwareItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  /// Cómo se llama en pantalla cada grupo. En Windows el reparto es limpio
  /// ("lo instaló alguien" contra "vino con Windows"); en Linux la única señal
  /// disponible es `apt-mark showmanual`, que separa lo que se pidió
  /// expresamente de las dependencias que arrastró el sistema — parecido, pero
  /// no es lo mismo, así que el título lo dice tal cual.
  String get tituloUsuario => os == 'linux'
      ? 'Instalado a petición'
      : 'Instalado por el usuario';

  String get tituloSistema => switch (os) {
        'linux' => 'Dependencias y base del sistema',
        'windows' => 'Viene con Windows',
        _ => 'Viene con el sistema',
      };

  /// Lo que instaló alguien (lo que de verdad distingue a este equipo).
  List<SoftwareItem> get delUsuario =>
      items.where((e) => !e.esDelSistema).toList();

  /// Lo que vino con el sistema operativo: componentes, parches y apps de
  /// fábrica.
  List<SoftwareItem> get delSistema =>
      items.where((e) => e.esDelSistema).toList();
}
