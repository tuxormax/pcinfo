// Modelo de la pestaña "Red" — espejo del JSON de GET /red
// (backend/collector/red.go).

class RedInfo {
  final String os;
  final String localIp;
  final String gateway; // vacío si no se pudo determinar
  final String interfaceName;

  const RedInfo({
    this.os = '',
    this.localIp = '',
    this.gateway = '',
    this.interfaceName = '',
  });

  factory RedInfo.fromJson(Map<String, dynamic> j) => RedInfo(
        os: j['os'] ?? '',
        localIp: j['localIp'] ?? '',
        gateway: j['gateway'] ?? '',
        interfaceName: j['interface'] ?? '',
      );

  bool get hayRed => localIp.isNotEmpty;

  /// Los tres primeros octetos de la IP local, para mostrar contexto de red
  /// (ej. "192.168.1"). No se usa para barrer nada: esta pestaña no escanea
  /// la red, solo diagnostica Internet.
  String get baseRed {
    final p = localIp.split('.');
    return p.length == 4 ? '${p[0]}.${p[1]}.${p[2]}' : '';
  }
}
