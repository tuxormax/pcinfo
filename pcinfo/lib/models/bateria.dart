// Modelos de la pestaña "Batería" — espejo del JSON de GET /bateria
// (backend/collector/bateria.go). Mantener los nombres de campo sincronizados:
// este archivo ES el contrato de datos del módulo.
//
// El veredicto y las explicaciones ("está en buen estado", "conviene
// cambiarla") vienen YA REDACTADOS del backend, igual que los problemas de los
// discos: así el texto es idéntico en pantalla y en el reporte que se guarda.

/// Nivel de salud de la batería y de cada explicación.
class BateriaNivel {
  static const bien = 'good';
  static const aviso = 'warning';
  static const mal = 'fail';
  static const info = 'info';
}

/// Estado de carga en este momento.
class BateriaEstado {
  static const cargando = 'cargando';
  static const descargando = 'descargando';
  static const llena = 'llena';
  static const conectada = 'conectada';

  /// Cómo se dice en pantalla.
  static String etiqueta(String e) => switch (e) {
        cargando => 'Cargándose',
        descargando => 'Gastándose (va con batería)',
        llena => 'Llena y enchufada',
        conectada => 'Enchufada a la corriente',
        _ => 'Sin dato',
      };
}

/// Una explicación en palabras sencillas: qué se midió y qué significa.
class BateriaNota {
  final String level;
  final String title;
  final String detail;

  const BateriaNota({this.level = '', this.title = '', this.detail = ''});

  factory BateriaNota.fromJson(Map<String, dynamic> j) => BateriaNota(
        level: j['level'] ?? '',
        title: j['title'] ?? '',
        detail: j['detail'] ?? '',
      );
}

/// La capacidad de la batería en un periodo concreto. Con la serie completa se
/// ve cómo ha ido bajando con el tiempo (solo lo guarda Windows).
class BateriaPunto {
  final String period;
  final int fullMWh;
  final int designMWh;
  final int healthPercent;

  const BateriaPunto({
    this.period = '',
    this.fullMWh = 0,
    this.designMWh = 0,
    this.healthPercent = -1,
  });

  factory BateriaPunto.fromJson(Map<String, dynamic> j) => BateriaPunto(
        period: j['period'] ?? '',
        fullMWh: (j['fullMWh'] ?? 0) as int,
        designMWh: (j['designMWh'] ?? 0) as int,
        healthPercent: (j['healthPercent'] ?? -1) as int,
      );
}

class BateriaItem {
  final String name;

  /// Referencia de la pieza (L15M4PC0, 45N1049…): el dato con el que se COMPRA
  /// una batería nueva. Vacío en los equipos que no la publican.
  final String model;
  final String manufacturer;
  final String serial;
  final String chemistry;
  final String chemistryText;
  final int voltageMV; // voltaje nominal; 0 si no se sabe
  final int designMWh;
  final int fullMWh;
  final int remainingMWh;
  final int chargePercent; // -1 desconocido
  final int cycleCount; // -1 desconocido, 0 = el equipo no lo cuenta
  final String state;
  final int healthPercent; // -1 si no se puede calcular
  final String healthLevel;
  final String verdict;
  final List<BateriaNota> notes;

  const BateriaItem({
    this.name = '',
    this.model = '',
    this.manufacturer = '',
    this.serial = '',
    this.chemistry = '',
    this.chemistryText = '',
    this.voltageMV = 0,
    this.designMWh = 0,
    this.fullMWh = 0,
    this.remainingMWh = 0,
    this.chargePercent = -1,
    this.cycleCount = -1,
    this.state = '',
    this.healthPercent = -1,
    this.healthLevel = '',
    this.verdict = '',
    this.notes = const [],
  });

  factory BateriaItem.fromJson(Map<String, dynamic> j) => BateriaItem(
        name: j['name'] ?? '',
        model: j['model'] ?? '',
        manufacturer: j['manufacturer'] ?? '',
        serial: j['serial'] ?? '',
        chemistry: j['chemistry'] ?? '',
        chemistryText: j['chemistryText'] ?? '',
        voltageMV: (j['voltageMV'] ?? 0) as int,
        designMWh: (j['designMWh'] ?? 0) as int,
        fullMWh: (j['fullMWh'] ?? 0) as int,
        remainingMWh: (j['remainingMWh'] ?? 0) as int,
        chargePercent: (j['chargePercent'] ?? -1) as int,
        cycleCount: (j['cycleCount'] ?? -1) as int,
        state: j['state'] ?? '',
        healthPercent: (j['healthPercent'] ?? -1) as int,
        healthLevel: j['healthLevel'] ?? '',
        verdict: j['verdict'] ?? '',
        notes: ((j['notes'] as List?) ?? const [])
            .map((e) => BateriaNota.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Nombre para la ficha: muchos equipos no le ponen uno legible.
  String get titulo {
    if (model.isNotEmpty && manufacturer.isNotEmpty) return '$manufacturer $model';
    if (model.isNotEmpty) return model;
    if (manufacturer.isNotEmpty) return manufacturer;
    return 'Batería';
  }

  /// Capacidad en mAh, que es como la anuncian muchas tiendas de repuestos.
  /// Sale de los Wh y el voltaje; sin voltaje no se puede calcular.
  int get designMAh =>
      (designMWh > 0 && voltageMV > 0) ? (designMWh * 1000) ~/ voltageMV : 0;

  /// Etiqueta corta del estado de salud, la que va en el distintivo de color.
  String get etiquetaSalud => switch (healthLevel) {
        BateriaNivel.bien => 'BUENA',
        BateriaNivel.aviso => 'DESGASTADA',
        BateriaNivel.mal => 'CAMBIARLA',
        _ => 'SIN DATO',
      };
}

class BateriaInfo {
  final String os;
  /// El equipo tal como lo pide una tienda de repuestos ("Lenovo YOGA 910-13IKB
  /// (80VF)"). Cuando la batería no publica su referencia, esto es lo que hay.
  final String equipment;
  final bool supported;
  final bool available;
  final bool hasBattery;
  final String reason;
  final String source;
  final String generated;
  final bool onAc;
  final bool onAcKnown;
  final List<BateriaItem> batteries;
  final List<BateriaPunto> history;
  final int runtimeFullMin;
  final int runtimeNowMin;
  final int runtimeHeavyMin;
  final int wattsTypicalMW;
  final int wattsHeavyMW;

  const BateriaInfo({
    this.os = '',
    this.equipment = '',
    this.supported = false,
    this.available = false,
    this.hasBattery = false,
    this.reason = '',
    this.source = '',
    this.generated = '',
    this.onAc = false,
    this.onAcKnown = false,
    this.batteries = const [],
    this.history = const [],
    this.runtimeFullMin = 0,
    this.runtimeNowMin = 0,
    this.runtimeHeavyMin = 0,
    this.wattsTypicalMW = 0,
    this.wattsHeavyMW = 0,
  });

  factory BateriaInfo.fromJson(Map<String, dynamic> j) => BateriaInfo(
        os: j['os'] ?? '',
        equipment: j['equipment'] ?? '',
        supported: j['supported'] ?? false,
        available: j['available'] ?? false,
        hasBattery: j['hasBattery'] ?? false,
        reason: j['reason'] ?? '',
        source: j['source'] ?? '',
        generated: j['generated'] ?? '',
        onAc: j['onAc'] ?? false,
        onAcKnown: j['onAcKnown'] ?? false,
        batteries: ((j['batteries'] as List?) ?? const [])
            .map((e) => BateriaItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        history: ((j['history'] as List?) ?? const [])
            .map((e) => BateriaPunto.fromJson(e as Map<String, dynamic>))
            .toList(),
        runtimeFullMin: (j['runtimeFullMin'] ?? 0) as int,
        runtimeNowMin: (j['runtimeNowMin'] ?? 0) as int,
        runtimeHeavyMin: (j['runtimeHeavyMin'] ?? 0) as int,
        wattsTypicalMW: (j['wattsTypicalMW'] ?? 0) as int,
        wattsHeavyMW: (j['wattsHeavyMW'] ?? 0) as int,
      );

  /// La batería del equipo (el primer elemento). Null si no hay ninguna.
  BateriaItem? get principal => batteries.isEmpty ? null : batteries.first;
}

/// Convierte minutos en "6 h 32 min", que es como lo diría una persona.
String duracionEnPalabras(int minutos) {
  if (minutos <= 0) return '';
  final h = minutos ~/ 60;
  final m = minutos % 60;
  if (h == 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}

/// Energía en Wh, que es lo que viene escrito en la etiqueta de la batería.
/// Los mWh del informe de Windows no le dicen nada a nadie. Con coma decimal,
/// como se escribe en español ("67,9 Wh").
String energiaEnPalabras(int mwh) {
  if (mwh <= 0) return '—';
  final wh = mwh / 1000;
  final texto = wh >= 10 ? wh.toStringAsFixed(1) : wh.toStringAsFixed(2);
  return '${texto.replaceAll(RegExp(r'\.?0+$'), '').replaceAll('.', ',')} Wh';
}

/// Consumo en vatios, con coma decimal ("10,4 W").
String vatiosEnPalabras(int mw) {
  if (mw <= 0) return '';
  final w = mw / 1000;
  return '${w.toStringAsFixed(1).replaceAll('.', ',')} W';
}

/// Voltaje en voltios ("7,68 V"). Con DOS decimales a propósito: las baterías
/// se venden por su voltaje exacto (7,68 V, 11,55 V, 15,2 V) y redondearlo a un
/// decimal haría pedir una pieza que no es.
String voltiosEnPalabras(int mv) {
  if (mv <= 0) return '';
  final v = mv / 1000;
  final texto = v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  return '${texto.replaceAll(RegExp(r'\.$'), '').replaceAll('.', ',')} V';
}
