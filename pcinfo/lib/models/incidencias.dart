import 'hardware.dart' show DiscoNota;

/// INCIDENCIAS DE DISCO — lo que le ha PASADO a cada disco según el registro del
/// sistema: errores de lectura y escritura (y en qué punto del disco),
/// desconexiones y reparaciones del sistema de archivos.
///
/// Es una pregunta distinta de la que contesta el S.M.A.R.T.: eso es lo que el
/// disco opina de sí mismo; esto es lo que el sistema VIO fallar. Y en un disco
/// USB de macOS es la única fuente que hay, porque por ahí no hay S.M.A.R.T.
///
/// Los textos (veredicto y notas) llegan REDACTADOS del backend, igual que en la
/// salud del disco y en la batería: así dicen lo mismo en la pantalla y en el
/// reporte que se guarda.
class IncidenciasDiscos {
  final bool disponible;

  /// Por qué no hay datos, cuando no los hay. Nunca vacío si [disponible] es
  /// false: una ficha en blanco no explica nada.
  final String motivo;

  /// De dónde salieron ("registro unificado de macOS", "journald"…).
  final String fuente;
  final int horas;
  final List<IncidenciaDisco> discos;

  const IncidenciasDiscos({
    this.disponible = false,
    this.motivo = '',
    this.fuente = '',
    this.horas = 0,
    this.discos = const [],
  });

  factory IncidenciasDiscos.fromJson(Map<String, dynamic> j) =>
      IncidenciasDiscos(
        disponible: j['disponible'] == true,
        motivo: j['motivo'] ?? '',
        fuente: j['fuente'] ?? '',
        horas: (j['horas'] as num?)?.toInt() ?? 0,
        discos: ((j['discos'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(IncidenciaDisco.fromJson)
            .toList(),
      );

  /// La ficha de un disco concreto, o null si ese disco no tuvo incidencias.
  IncidenciaDisco? de(String device) {
    for (final d in discos) {
      if (d.device == device) return d;
    }
    return null;
  }

  /// Las de discos que ya NO están conectados: su historial se muestra aparte,
  /// porque es justo lo que hace falta cuando un disco acaba de irse.
  List<IncidenciaDisco> get ausentes =>
      discos.where((d) => !d.conectado).toList();
}

class IncidenciaDisco {
  final String device;

  /// Cómo nombra el sistema a este disco en el registro. Sirve para que el
  /// usuario reconozca las líneas si va a mirarlo él mismo.
  final String etiqueta;

  /// ¿Sigue puesto ahora? Un disco ausente aparece igual, marcado.
  final bool conectado;

  final int erroresES;
  final int sectoresMalos;
  final int desconexiones;
  final int reparaciones;
  final int arranques;

  /// El disco contestó "error de hardware, fallo interno". Es la diferencia
  /// entre "no contestó" (cable, corriente) y "contestó que no pudo".
  final bool falloInterno;

  final String primera;
  final String ultima;
  final List<ZonaDanada> zonas;
  final String veredicto;
  final List<DiscoNota> notas;

  const IncidenciaDisco({
    this.device = '',
    this.etiqueta = '',
    this.conectado = false,
    this.erroresES = 0,
    this.sectoresMalos = 0,
    this.desconexiones = 0,
    this.reparaciones = 0,
    this.arranques = 0,
    this.falloInterno = false,
    this.primera = '',
    this.ultima = '',
    this.zonas = const [],
    this.veredicto = '',
    this.notas = const [],
  });

  factory IncidenciaDisco.fromJson(Map<String, dynamic> j) => IncidenciaDisco(
        device: j['device'] ?? '',
        etiqueta: j['etiqueta'] ?? '',
        conectado: j['conectado'] == true,
        erroresES: (j['erroresES'] as num?)?.toInt() ?? 0,
        sectoresMalos: (j['sectoresMalos'] as num?)?.toInt() ?? 0,
        desconexiones: (j['desconexiones'] as num?)?.toInt() ?? 0,
        reparaciones: (j['reparaciones'] as num?)?.toInt() ?? 0,
        arranques: (j['arranques'] as num?)?.toInt() ?? 0,
        falloInterno: j['falloInterno'] == true,
        primera: j['primera'] ?? '',
        ultima: j['ultima'] ?? '',
        zonas: ((j['zonas'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZonaDanada.fromJson)
            .toList(),
        veredicto: j['veredicto'] ?? '',
        notas: ((j['notas'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DiscoNota.fromJson)
            .toList(),
      );

  /// ¿Hay algo que contar de este disco?
  bool get hayAlgo =>
      erroresES > 0 ||
      desconexiones > 0 ||
      reparaciones > 0 ||
      sectoresMalos > 0;

  /// La zona con más fallos, que es la que decide el veredicto.
  ZonaDanada? get peorZona => zonas.isEmpty ? null : zonas.first;

  /// Nombre para mostrar: el dispositivo, o la etiqueta si el disco ya se fue.
  String get titulo => device.isNotEmpty
      ? (etiqueta.isEmpty ? device : '$device  ·  $etiqueta')
      : (etiqueta.isEmpty ? 'Disco desconocido' : etiqueta);
}

/// Un tramo del disco con fallos de lectura agrupados. Que los fallos estén
/// JUNTOS o dispersos es lo que distingue un disco con una zona dañada de uno
/// que simplemente dejó de responder.
class ZonaDanada {
  final double desdeGB;
  final double hastaGB;
  final int sectores;
  final double mbIlegibles;

  const ZonaDanada({
    this.desdeGB = 0,
    this.hastaGB = 0,
    this.sectores = 0,
    this.mbIlegibles = 0,
  });

  factory ZonaDanada.fromJson(Map<String, dynamic> j) => ZonaDanada(
        desdeGB: (j['desdeGB'] as num?)?.toDouble() ?? 0,
        hastaGB: (j['hastaGB'] as num?)?.toDouble() ?? 0,
        sectores: (j['sectores'] as num?)?.toInt() ?? 0,
        mbIlegibles: (j['mbIlegibles'] as num?)?.toDouble() ?? 0,
      );
}
