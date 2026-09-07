// Modelos de "Encendidos y apagados" — espejo del JSON de GET /arranques
// (backend/collector/arranques.go). Mantener los nombres de campo
// sincronizados: este archivo ES el contrato de datos del módulo.

/// Cómo terminó una sesión del equipo.
class FinSesion {
  static const normal = 'normal';
  static const reinicio = 'reinicio';
  static const brusco = 'brusco';
  static const enCurso = 'encurso';

  static String etiqueta(String v) => switch (v) {
        normal => 'Apagado normal',
        reinicio => 'Reinicio',
        brusco => 'Apagón brusco',
        enCurso => 'Encendido ahora',
        _ => 'Sin determinar',
      };
}

/// Tipo de tarea automática.
class TipoTarea {
  static const temporizador = 'temporizador';
  static const cron = 'cron';
  static const servicio = 'servicio';

  static String etiqueta(String v) => switch (v) {
        temporizador => 'Temporizador',
        cron => 'Tarea de cron',
        servicio => 'Servicio',
        _ => 'Tarea',
      };
}

/// Estado de una tarea automática.
class EstadoTarea {
  static const activo = 'activo';
  static const fallido = 'fallido';
  static const deshabilitado = 'deshabilitado';

  static String etiqueta(String v) => switch (v) {
        activo => 'Activa',
        fallido => 'Falló',
        deshabilitado => 'Desactivada',
        _ => 'Sin determinar',
      };
}

/// Una sesión del equipo: del encendido al apagado.
class Sesion {
  final int index; // 0 = la actual; hacia atrás, negativos
  final String start;
  final String end;
  final int secondsUp;
  final String ended;
  final String kernel;
  final String lastLine; // última línea antes de un corte brusco
  final String note;

  const Sesion({
    this.index = 0,
    this.start = '',
    this.end = '',
    this.secondsUp = 0,
    this.ended = '',
    this.kernel = '',
    this.lastLine = '',
    this.note = '',
  });

  factory Sesion.fromJson(Map<String, dynamic> j) => Sesion(
        index: (j['index'] ?? 0) as int,
        start: j['start'] ?? '',
        end: j['end'] ?? '',
        secondsUp: (j['secondsUp'] ?? 0) as int,
        ended: j['ended'] ?? '',
        kernel: j['kernel'] ?? '',
        lastLine: j['lastLine'] ?? '',
        note: j['note'] ?? '',
      );

  bool get enCurso => ended == FinSesion.enCurso;
  bool get fueBrusco => ended == FinSesion.brusco;

  /// Cuánto estuvo encendido, en palabras ("1 d 3 h", "45 min").
  String get duracion {
    if (secondsUp <= 0) return '';
    final d = secondsUp ~/ 86400;
    final h = (secondsUp % 86400) ~/ 3600;
    final m = (secondsUp % 3600) ~/ 60;
    final partes = <String>[
      if (d > 0) '$d d',
      if (h > 0) '$h h',
      if (m > 0 && d == 0) '$m min',
    ];
    return partes.isEmpty ? 'menos de 1 min' : partes.join(' ');
  }

  /// "2026-09-06 06:30:12" → "06:30" (la fecha va aparte, en su encabezado).
  String get horaInicio => _hora(start);
  String get horaFin => _hora(end);

  /// Día del encendido, "2026-09-06". Es la clave por la que se agrupan las
  /// sesiones en la pantalla.
  String get dia => _dia(start);

  /// Día del apagado. Distinto del anterior cuando el equipo se quedó encendido
  /// pasada la medianoche, que es de lo más normal.
  String get diaFin => _dia(end);

  /// El apagado cayó en otro día que el encendido. Sin avisarlo, en el grupo del
  /// lunes aparecería un "22:10 → 07:30" que se lee como si hubiera estado
  /// encendido nueve horas hacia atrás.
  bool get apagadoOtroDia =>
      end.isNotEmpty && diaFin.isNotEmpty && diaFin != dia;

  static String _hora(String t) => t.length >= 16 ? t.substring(11, 16) : t;

  static String _dia(String t) => t.length >= 10 ? t.substring(0, 10) : t;

  /// "2026-09-06" → "6 sep", para decir en qué día cayó el apagado sin repetir
  /// la fecha entera dentro de la fila.
  String get diaFinCorto => fechaCorta(diaFin);
}

const _meses = [
  'ene', 'feb', 'mar', 'abr', 'may', 'jun',
  'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
];

const _mesesLargos = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

const _diasSemana = [
  'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo',
];

/// "2026-09-06" → "6 sep".
String fechaCorta(String iso) {
  final f = DateTime.tryParse(iso);
  if (f == null) return iso;
  return '${f.day} ${_meses[f.month - 1]}';
}

/// "2026-09-06" → "domingo 6 de septiembre", y "Hoy" / "Ayer" cuando toca: en un
/// historial que se lee para saber qué pasó anoche, esas dos palabras ahorran
/// tener que calcular la fecha de cabeza.
String fechaLarga(String iso, {DateTime? hoy}) {
  final f = DateTime.tryParse(iso);
  if (f == null) return iso;
  final texto =
      '${_diasSemana[f.weekday - 1]} ${f.day} de ${_mesesLargos[f.month - 1]}';
  final ahora = hoy ?? DateTime.now();
  final dias = DateTime(ahora.year, ahora.month, ahora.day)
      .difference(DateTime(f.year, f.month, f.day))
      .inDays;
  if (dias == 0) return 'Hoy · $texto';
  if (dias == 1) return 'Ayer · $texto';
  return texto;
}

/// Algo que el equipo ejecuta solo.
class TareaAutomatica {
  final String name;
  final String kind;
  final String description;
  final String trigger;
  final String command;
  final String state;
  final String lastRun;
  final String nextRun;
  final String result;
  final String source;
  final bool fromSystem;

  /// Se ejecuta AL APAGAR el equipo. Cambia cómo se lee [lastRun].
  final bool atShutdown;

  const TareaAutomatica({
    this.name = '',
    this.kind = '',
    this.description = '',
    this.trigger = '',
    this.command = '',
    this.state = '',
    this.lastRun = '',
    this.nextRun = '',
    this.result = '',
    this.source = '',
    this.fromSystem = false,
    this.atShutdown = false,
  });

  factory TareaAutomatica.fromJson(Map<String, dynamic> j) => TareaAutomatica(
        name: j['name'] ?? '',
        kind: j['kind'] ?? '',
        description: j['description'] ?? '',
        trigger: j['trigger'] ?? '',
        command: j['command'] ?? '',
        state: j['state'] ?? '',
        lastRun: j['lastRun'] ?? '',
        nextRun: j['nextRun'] ?? '',
        result: j['result'] ?? '',
        source: j['source'] ?? '',
        fromSystem: j['fromSystem'] ?? false,
        atShutdown: j['atShutdown'] ?? false,
      );

  bool get fallo => state == EstadoTarea.fallido;

  /// Cuándo corrió por última vez, dicho con propiedad.
  ///
  /// Los tres vacíos que significan cosas distintas, y confundirlos manda a
  /// buscar una avería donde no la hay:
  ///
  /// - **cron** no anota en ninguna parte cuándo corrió → "no se sabe".
  /// - Un servicio **de apagado** corre cuando la sesión termina, y systemd
  ///   olvida el estado al reiniciar: desde la sesión siguiente SIEMPRE se ve
  ///   sin ejecutar, haya corrido o no. Decir "nunca" ahí acusaría todos los
  ///   días a un respaldo que sí se está haciendo.
  /// - En lo demás (temporizadores, servicios de arranque) systemd sí lo sabe,
  ///   y el vacío significa de verdad que nunca llegó a ejecutarse.
  String get ultimaVezTexto {
    if (lastRun.isNotEmpty) return lastRun;
    if (kind == TipoTarea.cron) return 'cron no lo anota';
    if (atShutdown) return 'no consta en esta sesión';
    return 'nunca ha corrido';
  }

  String get buscable =>
      '$name $description $trigger $command $source'.toLowerCase();
}

/// Un programa que se lanza al iniciar sesión.
class ProgramaInicio {
  final String name;
  final String command;
  final String source;
  final String scope;
  final bool enabled;
  final bool running;
  final String note;

  const ProgramaInicio({
    this.name = '',
    this.command = '',
    this.source = '',
    this.scope = '',
    this.enabled = false,
    this.running = false,
    this.note = '',
  });

  factory ProgramaInicio.fromJson(Map<String, dynamic> j) => ProgramaInicio(
        name: j['name'] ?? '',
        command: j['command'] ?? '',
        source: j['source'] ?? '',
        scope: j['scope'] ?? '',
        enabled: j['enabled'] ?? false,
        running: j['running'] ?? false,
        note: j['note'] ?? '',
      );

  /// Los de /etc/xdg/autostart valen para todo el equipo: son los que trae el
  /// escritorio, y no es lo que se anda buscando cuando falta un programa.
  bool get delSistema => scope == 'todos los usuarios';

  String get buscable => '$name $command $source $scope'.toLowerCase();
}

/// Las sesiones de un mismo día.
class GrupoDia {
  final String dia; // "2026-09-06"
  final List<Sesion> sesiones;

  GrupoDia(this.dia, this.sesiones);

  int get bruscos => sesiones.where((s) => s.fueBrusco).length;
}

/// Raíz del JSON de GET /arranques.
class ArranquesInfo {
  final String os;
  final bool elevated;
  final String source;
  final bool available;
  final String reason;
  final int scanDays;

  /// El diario del sistema no se guarda en disco: se borra en cada apagado. La
  /// pestaña ofrece activarlo, porque sin él nunca se sabrá QUÉ pasó en una
  /// sesión anterior, solo a qué hora empezó y terminó.
  final bool journalVolatile;

  final List<Sesion> sessions;
  final List<TareaAutomatica> tasks;
  final List<ProgramaInicio> startup;

  final String sessionsNote;
  final String tasksNote;
  final String startupNote;

  const ArranquesInfo({
    this.os = '',
    this.elevated = false,
    this.source = '',
    this.available = false,
    this.reason = '',
    this.scanDays = 30,
    this.journalVolatile = false,
    this.sessions = const [],
    this.tasks = const [],
    this.startup = const [],
    this.sessionsNote = '',
    this.tasksNote = '',
    this.startupNote = '',
  });

  factory ArranquesInfo.fromJson(Map<String, dynamic> j) => ArranquesInfo(
        os: j['os'] ?? '',
        elevated: j['elevated'] ?? false,
        source: j['source'] ?? '',
        available: j['available'] ?? false,
        reason: j['reason'] ?? '',
        scanDays: (j['scanDays'] ?? 30) as int,
        journalVolatile: j['journalVolatile'] ?? false,
        sessions: (j['sessions'] as List?)
                ?.map((e) => Sesion.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        tasks: (j['tasks'] as List?)
                ?.map((e) => TareaAutomatica.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        startup: (j['startup'] as List?)
                ?.map((e) => ProgramaInicio.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        sessionsNote: j['sessionsNote'] ?? '',
        tasksNote: j['tasksNote'] ?? '',
        startupNote: j['startupNote'] ?? '',
      );

  int get bruscos => sessions.where((s) => s.fueBrusco).length;
  int get reinicios =>
      sessions.where((s) => s.ended == FinSesion.reinicio).length;
  int get normales => sessions.where((s) => s.ended == FinSesion.normal).length;

  Sesion? get actual {
    for (final s in sessions) {
      if (s.enCurso) return s;
    }
    return null;
  }

  /// Tareas que se le añadieron a este equipo (no las que trae el sistema): son
  /// las que alguien puso ahí a propósito y las que se echan de menos.
  List<TareaAutomatica> get tareasPropias =>
      tasks.where((t) => !t.fromSystem).toList();

  List<TareaAutomatica> get tareasDelSistema =>
      tasks.where((t) => t.fromSystem).toList();

  List<TareaAutomatica> get tareasFallidas =>
      tasks.where((t) => t.fallo).toList();

  List<ProgramaInicio> get inicioPropio =>
      startup.where((p) => !p.delSistema).toList();

  List<ProgramaInicio> get inicioDelSistema =>
      startup.where((p) => p.delSistema).toList();

  /// Las sesiones agrupadas por el día en que se encendió el equipo, en el
  /// mismo orden en que llegan (de lo más reciente a lo más viejo). Un día con
  /// tres encendidos se lee como tres encendidos de ese día, no como tres
  /// fechas sueltas.
  List<GrupoDia> get sesionesPorDia {
    final grupos = <GrupoDia>[];
    for (final s in sessions) {
      if (grupos.isNotEmpty && grupos.last.dia == s.dia) {
        grupos.last.sesiones.add(s);
      } else {
        grupos.add(GrupoDia(s.dia, [s]));
      }
    }
    return grupos;
  }

  /// Frase de cabecera: lo primero que hay que saber al abrir la pestaña.
  String get resumen {
    if (sessions.isEmpty) return 'Sin historial de encendidos.';
    final partes = <String>['${sessions.length} encendidos en $scanDays días'];
    if (bruscos > 0) {
      partes.add(bruscos == 1
          ? '1 terminó de golpe'
          : '$bruscos terminaron de golpe');
    } else {
      partes.add('todos terminaron bien');
    }
    final a = actual;
    if (a != null && a.duracion.isNotEmpty) {
      partes.add('encendido desde hace ${a.duracion}');
    }
    return partes.join(' · ');
  }
}
