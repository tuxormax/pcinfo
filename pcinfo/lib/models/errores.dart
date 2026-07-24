// Modelos del "Historial de Errores" — espejo del JSON de GET /errores
// (backend/collector/errors.go). Mantener los nombres de campo sincronizados:
// este archivo ES el contrato de datos del módulo.

class ErroresInfo {
  final String os; // "windows" | "linux"
  final bool elevated; // ¿el backend corre como administrador/root?
  final String source; // fuente consultada (registro de eventos, journald…)
  final bool available; // ¿se pudo leer alguna fuente?
  final String reason; // aviso/motivo cuando algo no se pudo leer
  final int scanDays; // días de historial analizados
  final List<ErrorItem> items;
  final List<DumpFile> dumps;

  const ErroresInfo({
    this.os = '',
    this.elevated = false,
    this.source = '',
    this.available = false,
    this.reason = '',
    this.scanDays = 30,
    this.items = const [],
    this.dumps = const [],
  });

  factory ErroresInfo.fromJson(Map<String, dynamic> j) => ErroresInfo(
        os: j['os'] ?? '',
        elevated: j['elevated'] ?? false,
        source: j['source'] ?? '',
        available: j['available'] ?? false,
        reason: j['reason'] ?? '',
        scanDays: (j['scanDays'] ?? 30) as int,
        items: (j['items'] as List?)
                ?.map((e) => ErrorItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        dumps: (j['dumps'] as List?)
                ?.map((e) => DumpFile.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  bool get isWindows => os == 'windows';

  /// Cuántos problemas hay de cada categoría (para los filtros de la GUI).
  Map<String, int> get conteoPorTipo {
    final m = <String, int>{};
    for (final it in items) {
      m[it.kind] = (m[it.kind] ?? 0) + 1;
    }
    return m;
  }

  /// Total de ocurrencias (los repetidos vienen agrupados con su contador).
  int get totalOcurrencias =>
      items.fold(0, (a, b) => a + (b.count <= 0 ? 1 : b.count));
}

/// Un problema del sistema operativo ya interpretado: qué pasó, por qué y cómo
/// se resuelve. Los eventos repetidos llegan agrupados con [count] > 1.
class ErrorItem {
  final String id;
  final String when; // última vez "2026-07-23 14:02:11"
  final String firstWhen; // primera vez (vacío si count == 1)
  final int count;
  final String severity; // critico | error | aviso
  final String kind; // pantallazo | apagado | hardware | disco | grafica |
  //                    servicio | aplicacion | memoria | sistema
  final String title;
  final String source;
  final String code; // STOP code / id de evento / señal
  final String codeName; // nombre del STOP code

  final String culprit; // driver o programa señalado
  final String culpritInfo; // fabricante, versión y ruta
  final String confidence; // alta | media | baja
  final List<String> suspects;

  final String cause;
  final String fix;
  final String detail; // texto crudo del registro

  const ErrorItem({
    this.id = '',
    this.when = '',
    this.firstWhen = '',
    this.count = 1,
    this.severity = 'error',
    this.kind = 'sistema',
    this.title = '',
    this.source = '',
    this.code = '',
    this.codeName = '',
    this.culprit = '',
    this.culpritInfo = '',
    this.confidence = '',
    this.suspects = const [],
    this.cause = '',
    this.fix = '',
    this.detail = '',
  });

  factory ErrorItem.fromJson(Map<String, dynamic> j) => ErrorItem(
        id: j['id'] ?? '',
        when: j['when'] ?? '',
        firstWhen: j['firstWhen'] ?? '',
        count: (j['count'] ?? 1) as int,
        severity: j['severity'] ?? 'error',
        kind: j['kind'] ?? 'sistema',
        title: j['title'] ?? '',
        source: j['source'] ?? '',
        code: j['code'] ?? '',
        codeName: j['codeName'] ?? '',
        culprit: j['culprit'] ?? '',
        culpritInfo: j['culpritInfo'] ?? '',
        confidence: j['confidence'] ?? '',
        suspects:
            (j['suspects'] as List?)?.map((e) => '$e').toList() ?? const [],
        cause: j['cause'] ?? '',
        fix: j['fix'] ?? '',
        detail: j['detail'] ?? '',
      );

  bool get repetido => count > 1;
}

/// Volcado de memoria presente en el disco (minidump/MEMORY.DMP en Windows,
/// coredump/apport en Linux).
class DumpFile {
  final String path;
  final String when;
  final int sizeBytes;

  const DumpFile({this.path = '', this.when = '', this.sizeBytes = 0});

  factory DumpFile.fromJson(Map<String, dynamic> j) => DumpFile(
        path: j['path'] ?? '',
        when: j['when'] ?? '',
        sizeBytes: (j['sizeBytes'] ?? 0) as int,
      );
}
