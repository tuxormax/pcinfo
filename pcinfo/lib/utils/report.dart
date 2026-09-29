import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../models/arranques.dart';
import '../models/bateria.dart';
import '../models/controladores.dart';
import '../models/errores.dart';
import '../models/hardware.dart';
import '../models/software.dart';
import '../version.dart';
import 'format.dart';

// ---------------------------------------------------------------------------
// TODOS los reportes de PCInfo se guardan en Markdown (.md) — regla del
// proyecto. Un .md se sigue leyendo como texto plano en cualquier editor, pero
// pegado en un ticket, un correo o un repositorio queda con sus títulos y sus
// tablas, y así ningún dato depende del alineado a mano con espacios.
// ---------------------------------------------------------------------------

/// Genera un .md con TODO lo que se ve en pantalla (sistema, CPU, placa, RAM,
/// GPU y discos con uso + SMART). Pregunta DÓNDE guardarlo con el diálogo del
/// sistema. Devuelve la ruta escrita, o null si el usuario canceló.
Future<String?> saveReport(HardwareInfo hw) {
  final host = _safe(
    hw.system.hostname.isEmpty ? 'equipo' : hw.system.hostname,
  );
  return _guardaConDialogo(
    texto: buildReport(hw),
    nombre: 'PCInfo_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Guarda el "Historial de Errores" en un .md (equivalente al C:\bluescreen.md
/// del script de Windows, pero con TODO lo que muestra la pestaña y en ambos
/// sistemas). Devuelve la ruta escrita, o null si el usuario canceló.
Future<String?> saveErroresReport(ErroresInfo err, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildErroresReport(err, equipo),
    nombre: 'PCInfo_Errores_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Guarda "Encendidos y apagados" en un .md: las sesiones del equipo con cómo
/// terminó cada una, las tareas automáticas y los programas de inicio, tal como
/// se ven en la pestaña. Devuelve la ruta escrita, o null si se canceló.
Future<String?> saveArranquesReport(ArranquesInfo arr, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildArranquesReport(arr, equipo),
    nombre: 'PCInfo_Encendidos_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Guarda el informe de la batería en un .md. Devuelve la ruta escrita, o null
/// si se canceló.
Future<String?> saveBateriaReport(BateriaInfo bat, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildBateriaReport(bat, equipo),
    nombre: 'PCInfo_Bateria_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Guarda la salud de los discos en un .md: el veredicto de cada uno y las
/// explicaciones, tal como se ven en la pestaña. Devuelve la ruta escrita, o
/// null si se canceló.
Future<String?> saveDiscosReport(List<DiskInfo> discos, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildDiscosReport(discos, equipo),
    nombre: 'PCInfo_Discos_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Pide al usuario dónde guardar y escribe el archivo.
///
/// El reporte SIEMPRE pasa por el diálogo del sistema: antes se escribía solo
/// en la carpeta del usuario y quien lo guardaba no sabía dónde había quedado
/// (y menos aún podía mandarlo directo a una USB). El nombre sugerido ya viene
/// armado con el equipo y la fecha, así que aceptar sin tocar nada deja el
/// mismo archivo de siempre, pero en la carpeta que se eligió.
///
/// Devuelve la ruta escrita, o null si el usuario cerró el diálogo.
Future<String?> _guardaConDialogo({
  required String texto,
  required String nombre,
  required String extension,
}) async {
  final destino = await getSaveLocation(
    suggestedName: nombre,
    initialDirectory: _reportDir(),
    confirmButtonText: 'Guardar',
    acceptedTypeGroups: [
      XTypeGroup(
        label: extension == 'md' ? 'Markdown' : 'Texto',
        extensions: [extension],
      ),
    ],
  );
  if (destino == null) return null; // el usuario canceló

  // GTK (Linux) no agrega la extensión si el usuario la borró del nombre; sin
  // ella el archivo se abre con cualquier cosa. Se repone aquí.
  var path = destino.path;
  if (!path.toLowerCase().endsWith('.$extension')) path = '$path.$extension';

  await File(path).writeAsString(texto);
  return path;
}

/// Carpeta que propone el diálogo la primera vez: HOME en Linux, USERPROFILE en
/// Windows; cae al directorio actual si ninguna está definida.
String _reportDir() {
  final env = Platform.environment;
  final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  if (home != null && home.isNotEmpty) return home;
  return Directory.current.path;
}

String _two(int x) => x.toString().padLeft(2, '0');

String _fileStamp() {
  final n = DateTime.now();
  return '${n.year}-${_two(n.month)}-${_two(n.day)}_${_two(n.hour)}${_two(n.minute)}';
}

String _humanStamp() {
  final n = DateTime.now();
  return '${n.year}-${_two(n.month)}-${_two(n.day)} '
      '${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}';
}

/// Reemplaza lo que no sea apto para un nombre de archivo.
String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

// ---------------------------------------------------------------------------
// Piezas comunes de los reportes en Markdown.
// ---------------------------------------------------------------------------

/// Cabecera de todos los reportes: título de primer nivel y la línea de quién
/// lo generó y cuándo (sin eso, un reporte pegado en un chat no dice de qué
/// equipo ni de qué versión salió).
void _cabecera(StringBuffer b, String titulo, String equipo) {
  final nombre = equipo.isEmpty ? 'este equipo' : equipo;
  b
    ..writeln('# $titulo — $nombre')
    ..writeln()
    ..writeln(
      'Generado por $appName v$appVersion Rev $appRevision '
      'el ${_humanStamp()}.',
    )
    ..writeln();
}

/// Pie común: la línea de licencia, separada del cuerpo.
void _pie(StringBuffer b) {
  b
    ..writeln('---')
    ..writeln()
    ..writeln('_$appCopyright · $appEmail · Licencia ${appLicense}_');
}

/// Abre una tabla Markdown con los encabezados dados.
void _tabla(StringBuffer b, List<String> columnas) {
  b
    ..writeln('| ${columnas.join(' | ')} |')
    ..writeln('| ${columnas.map((_) => '---').join(' | ')} |');
}

/// Escribe una fila de tabla escapando cada celda. Una celda vacía sale como
/// raya: en una tabla, un hueco no se distingue de un dato que faltó leer.
void _fila(StringBuffer b, List<String> celdas) {
  b.writeln(
    '| ${celdas.map((c) {
      final v = _md(c);
      return v.isEmpty ? '—' : v;
    }).join(' | ')} |',
  );
}

/// Encierra un texto crudo (mensaje del sistema, traza) en un bloque de código.
/// La valla se alarga si el propio texto trae acentos graves, para que no parta
/// el bloque a la mitad.
String _bloque(String texto) {
  var valla = 3;
  for (final m in RegExp(r'`{3,}').allMatches(texto)) {
    if (m.group(0)!.length >= valla) valla = m.group(0)!.length + 1;
  }
  final cerca = '`' * valla;
  final b = StringBuffer()..writeln('${cerca}text');
  for (final l in texto.split('\n')) {
    b.writeln(l.trimRight());
  }
  b.writeln(cerca);
  return b.toString();
}

/// Sección "Ranuras y puertos": qué sitios de ampliación tiene la placa y
/// cuáles quedan libres. Responde lo que el inventario no decía —cuántos SATA,
/// si hay M.2, si queda un PCIe— sin tener que abrir el gabinete.
void _ranurasYPuertos(StringBuffer b, BoardInfo bd) {
  if (!bd.tieneExpansion) {
    b
      ..writeln('## Ranuras y puertos')
      ..writeln()
      ..writeln('_El firmware de esta placa no declara sus ranuras y el modelo '
          'no está en el catálogo verificado._')
      ..writeln();
    return;
  }

  b
    ..writeln('## Ranuras y puertos')
    ..writeln();
  _tabla(b, ['Dato', 'Valor']);
  if (bd.sataTotal > 0) {
    _fila(b, [
      'Puertos SATA',
      bd.sataVerificado
          ? '${bd.sataTotal} conectores'
          : '${bd.sataTotal} puertos (los que presenta el chipset)'
    ]);
    _fila(b, ['SATA con disco', '${bd.sataUsed}']);
    if (bd.sataFree >= 0) _fila(b, ['SATA libres', '${bd.sataFree}']);
  }
  final m2 = bd.m2Slots;
  if (m2.isNotEmpty) {
    _fila(b, ['Ranuras M.2', BoardInfo.resumenRanuras(m2)]);
  }
  final pcie = bd.pcieSlots;
  if (pcie.isNotEmpty) {
    _fila(b, ['Ranuras PCIe', BoardInfo.resumenRanuras(pcie)]);
  }
  b.writeln();

  if (bd.portsNote.isNotEmpty) {
    b
      ..writeln('> ℹ️ ${_md(bd.portsNote)}')
      ..writeln();
  }

  if (bd.portsSource != 'catalogo') {
    b
      ..writeln('> ⚠️ Ranuras y puertos según el firmware; el chipset puede '
          'exponer más puertos de los que la placa trae cableados (modelo no '
          'verificado en el catálogo).')
      ..writeln();
  }

  if (bd.slots.isNotEmpty) {
    _tabla(b, ['Ranura', 'Admite', 'Estado']);
    for (final s in bd.slots) {
      _fila(b, [s.label, s.spec, s.estadoTexto]);
    }
    b.writeln();
  }

  // Detalle de los conectores SATA con disco: en Linux se sabe el número de
  // puerto de cada uno; en Windows solo el tipo de conexión, así que la tabla
  // se omite entera en vez de salir vacía.
  final ocupados = bd.sataPorts.where((p) => p.used).toList();
  if (ocupados.isNotEmpty) {
    _tabla(b, ['Puerto SATA', 'Disco']);
    for (final p in ocupados) {
      _fila(b, [p.label, p.usedBy]);
    }
    b.writeln();
  }
}

/// Construye el reporte de hardware en Markdown, espejo de las fichas del
/// dashboard.
String buildReport(HardwareInfo hw) {
  final b = StringBuffer();
  _cabecera(b, 'Reporte de hardware', hw.system.hostname);

  void seccion(String t) {
    b
      ..writeln('## $t')
      ..writeln();
  }

  void kv(String k, String v) => _fila(b, [k, v]);

  // Sistema operativo
  seccion('Sistema operativo');
  _tabla(b, ['Dato', 'Valor']);
  kv('Sistema', hw.system.distro);
  kv('Nombre del equipo', hw.system.hostname);
  kv('Kernel', hw.system.kernel);
  kv('Arquitectura', hw.system.arch);
  if (hw.system.desktop.isNotEmpty) kv('Escritorio', hw.system.desktop);
  b.writeln();

  // CPU
  final c = hw.cpu;
  seccion('Procesador (CPU)');
  _tabla(b, ['Dato', 'Valor']);
  kv('Fabricante', cleanVendor(c.vendor));
  kv('Modelo', c.model);
  kv('Núcleos', '${c.cores}');
  kv('Hilos', '${c.threads}');
  kv('Frecuencia base', formatMhz(c.baseMhz));
  if (c.maxMhz > 0) kv('Frecuencia máxima', formatMhz(c.maxMhz));
  b.writeln();

  // Tarjeta madre
  final bd = hw.board;
  seccion('Tarjeta madre');
  _tabla(b, ['Dato', 'Valor']);
  kv('Fabricante', bd.vendor);
  kv('Modelo', bd.product);
  if (bd.formFactor.isNotEmpty) kv('Tamaño', bd.formFactor);
  if (bd.version.isNotEmpty) kv('Versión', bd.version);
  kv('BIOS', '${bd.biosVendor} ${bd.biosVersion}'.trim());
  kv('Fecha BIOS', bd.biosDate);
  b.writeln();

  _ranurasYPuertos(b, bd);

  // RAM
  final m = hw.memory;
  seccion('Memoria RAM');
  _tabla(b, ['Dato', 'Valor']);
  kv('Total', formatBytes(m.totalBytes));
  kv(
    'Montaje',
    m.soldered
        ? 'Soldada (no ampliable)'
        : m.mixed
            ? 'Mixta (soldada + ranura)'
            : 'Ranuras (ampliable)',
  );
  if (m.mixed) kv('RAM soldada', formatBytes(m.solderedBytes));
  if (m.totalSlots > 0) {
    kv('Ranuras', '${m.slotModules.length} de ${m.totalSlots} ocupadas');
    kv('Ranuras libres', '${m.freeSlots}');
  } else {
    kv('Módulos', '${m.slotModules.length}');
  }
  if (m.maxCapacityBytes > 0) {
    kv('Capacidad máx.', formatBytes(m.maxCapacityBytes));
  }
  b.writeln();
  if (!m.slotsVerified && !m.soldered && m.totalSlots > 0) {
    b
      ..writeln(
        '> ⚠️ Ranuras y capacidad máx. según el firmware; puede no '
        'coincidir con la placa (modelo no verificado en el catálogo).',
      )
      ..writeln();
  }
  if (m.modules.isNotEmpty || m.freeSlots > 0) {
    _tabla(b, ['Ranura', 'Formato', 'Capacidad', 'Tipo', 'Velocidad']);
    for (final mod in m.modules) {
      _fila(b, [
        mod.location,
        mod.isSoldered ? 'Soldada' : mod.formFactor,
        formatBytes(mod.sizeBytes),
        mod.type,
        mod.speedMhz > 0 ? '${mod.speedMhz} MHz' : '',
      ]);
    }
    for (var i = 0; i < m.freeSlots; i++) {
      _fila(b, ['Ranura libre', '', 'Vacía', '', '']);
    }
    b.writeln();
  }

  // GPU — una sección por tarjeta (espejo de las fichas del dashboard).
  if (hw.gpu.cards.isEmpty) {
    seccion('Tarjeta gráfica (GPU)');
    _tabla(b, ['Dato', 'Valor']);
    kv('Estado', 'No detectada');
    b.writeln();
  } else {
    final multi = hw.gpu.cards.length > 1;
    for (final (i, card) in hw.gpu.cards.indexed) {
      seccion(
        multi
            ? 'Tarjeta gráfica ${i + 1} · ${_gpuKind(card)}'
            : 'Tarjeta gráfica (GPU)',
      );
      _tabla(b, ['Dato', 'Valor']);
      kv('Fabricante', cleanVendor(card.vendor));
      kv('Modelo', card.product);
      kv('Tipo', _gpuKind(card));
      if (card.memoryBytes > 0) kv('VRAM', formatBytes(card.memoryBytes));
      kv('Driver', card.driver);
      b.writeln();
    }
  }

  // Almacenamiento
  seccion('Almacenamiento');
  if (hw.disks.isEmpty) {
    b
      ..writeln('_No se detectaron discos._')
      ..writeln();
  } else {
    for (final (i, d) in hw.disks.indexed) {
      b
        ..writeln('### Disco ${i + 1} — ${_md(d.model)}')
        ..writeln();
      _tabla(b, ['Dato', 'Valor']);
      kv('Tipo', d.type);
      kv('Salud', _saludDisco(d));
      kv('Dispositivo', d.name);
      kv('Serie', d.serial);
      kv('Bus', d.bus.toUpperCase());
      if (d.port.isNotEmpty) kv('Conectado en', d.port);
      kv('Capacidad', formatDiskCap(d.sizeBytes));
      if (d.hasUsage) {
        kv('Ocupado', '${formatGB(d.usedBytes)} (${d.usedPercent.round()}%)');
        kv(
          'Disponible',
          '${formatGB(d.availBytes)} (${d.availPercent.round()}%)',
        );
      }
      if (d.smartAvailable) {
        if (d.writtenBytes > 0) {
          kv('Escrituras totales', formatBytes(d.writtenBytes));
        }
        if (d.readBytes > 0) kv('Lecturas totales', formatBytes(d.readBytes));
        if (d.lifePercentUsed >= 0) {
          kv('Vida restante', '${100 - d.lifePercentUsed}%');
        }
        kv('Horas encendido', '${d.powerOnHours} h');
        kv('Ciclos de encendido', '${d.powerCycles}');
        kv('Sectores reasignados', '${d.reallocatedSectors}');
      }
      b.writeln();
    }
  }

  _pie(b);
  return b.toString();
}

/// Construye el historial de errores en Markdown, espejo de la pestaña
/// "Historial de Errores". Si se agrega o quita un dato en `errores_page.dart`,
/// reflejarlo aquí (misma regla de concordancia que el reporte de hardware).
String buildErroresReport(ErroresInfo err, String equipo) {
  final b = StringBuffer();
  _cabecera(b, 'Historial de errores del sistema', equipo);

  _tabla(b, ['Dato', 'Valor']);
  _fila(b, ['Sistema', err.os]);
  _fila(b, ['Fuente', err.source]);
  // Qué instalación se leyó: sin esto, un reporte hecho desde un medio de
  // rescate parecería del propio medio y no del equipo averiado.
  if (err.target.isNotEmpty) {
    if (err.targetLabel.isNotEmpty) {
      _fila(b, ['Instalación analizada', err.targetLabel]);
    }
    _fila(b, ['Carpeta de esa instalación', err.target]);
  }
  _fila(b, ['Periodo analizado', 'últimos ${err.scanDays} días']);
  _fila(b, ['Administrador/root', err.elevated ? 'sí' : 'no']);
  if (err.target.isNotEmpty && err.offline) {
    _fila(b, ['Estado de esa instalación', 'NO estaba en ejecución']);
  }
  b.writeln();
  if (err.reason.isNotEmpty) {
    b
      ..writeln('> ⚠️ ${_md(err.reason)}')
      ..writeln();
  }

  // La conclusión va ANTES del listado: quien lea el reporte pegado en un chat
  // tiene que ver primero qué controlador cambiar, no deducirlo de 30 entradas.
  if (err.culprits.isNotEmpty) {
    b
      ..writeln('## Controladores señalados (${err.etiquetaAnalizados})')
      ..writeln();
    for (final n in err.notaCulpables) {
      b.writeln('> ${_md(n)}');
    }
    if (err.notaCulpables.isNotEmpty) b.writeln();
    for (final c in err.culprits) {
      b
        ..writeln('### ${_md(c.titulo)}')
        ..writeln();
      _tabla(b, ['Dato', 'Valor']);
      if (c.device.isNotEmpty) _fila(b, ['Archivo', c.driver]);
      if (c.vendor.isNotEmpty) _fila(b, ['Fabricante', c.vendor]);
      if (c.version.isNotEmpty) _fila(b, ['Versión', c.version]);
      if (c.path.isNotEmpty) _fila(b, ['Ruta', c.path]);
      if (c.why.isNotEmpty) _fila(b, ['Señalado', c.why]);
      b.writeln();
    }
  }

  b
    ..writeln('## Errores registrados (${err.items.length})')
    ..writeln();
  if (err.items.isEmpty) {
    b
      ..writeln(
        err.available
            ? '_No se registraron errores en el periodo analizado._'
            : '_No hay información disponible (ver el aviso de arriba)._',
      )
      ..writeln();
  }

  for (final (i, e) in err.items.indexed) {
    b
      ..writeln(
        '### ${i + 1}. [${_sevTexto(e.severity)}] '
        '[${_tipoTexto(e.kind)}] ${_md(e.title)}',
      )
      ..writeln();
    _tabla(b, ['Dato', 'Valor']);
    _fila(b, [
      'Cuándo',
      '${e.when}${e.repetido ? " (${e.count} veces, desde ${e.firstWhen})" : ""}',
    ]);
    _fila(b, ['Origen', e.source]);
    if (e.code.isNotEmpty) {
      _fila(b, [
        'Código',
        '${e.code}${e.codeName.isNotEmpty ? "  ${e.codeName}" : ""}',
      ]);
    }
    if (e.culprit.isNotEmpty) {
      _fila(b, [
        'Causante',
        '${e.culprit}'
            '${e.confidence.isNotEmpty ? " (confianza ${e.confidence})" : ""}',
      ]);
      if (e.culpritInfo.isNotEmpty) {
        _fila(b, ['Datos del causante', e.culpritInfo]);
      }
    }
    if (e.cause.isNotEmpty) _fila(b, ['Qué pasó', e.cause]);
    if (e.fix.isNotEmpty) _fila(b, ['Solución', e.fix]);
    b.writeln();

    // Por qué se le acusa: sin esto "confianza alta" no se puede juzgar.
    if (e.evidence.isNotEmpty) {
      b.writeln('**Evidencia:**');
      b.writeln();
      for (final ev in e.evidence) {
        b.writeln('- ${_md(ev)}');
      }
      b.writeln();
    }
    final otros = e.suspects.skip(1).toList();
    if (otros.isNotEmpty) {
      b.writeln('**Otros sospechosos:**');
      b.writeln();
      for (final s in otros) {
        b.writeln('- ${_md(s)}');
      }
      b.writeln();
    }
    if (e.detail.isNotEmpty) {
      b
        ..writeln('**Mensaje original del sistema:**')
        ..writeln()
        ..write(_bloque(e.detail))
        ..writeln();
    }
  }

  if (err.dumps.isNotEmpty) {
    b
      ..writeln('## Volcados de memoria presentes en el disco')
      ..writeln();
    _tabla(b, ['Cuándo', 'Tamaño', 'Archivo']);
    for (final d in err.dumps) {
      _fila(b, [d.when, formatBytes(d.sizeBytes), d.path]);
    }
    b.writeln();
  }

  _pie(b);
  return b.toString();
}

String _sevTexto(String sev) {
  switch (sev) {
    case 'critico':
      return 'CRÍTICO';
    case 'aviso':
      return 'AVISO';
    default:
      return 'ERROR';
  }
}

String _tipoTexto(String kind) {
  switch (kind) {
    case 'pantallazo':
      return 'PANTALLAZO';
    case 'apagado':
      return 'APAGÓN';
    case 'hardware':
      return 'HARDWARE';
    case 'disco':
      return 'DISCO';
    case 'grafica':
      return 'GRÁFICOS';
    case 'servicio':
      return 'SERVICIO';
    case 'aplicacion':
      return 'PROGRAMA';
    case 'memoria':
      return 'MEMORIA';
    default:
      return 'SISTEMA';
  }
}

/// Salud tal como se ve en la pantalla: un medio extraíble (memoria USB,
/// tarjeta) no reporta salud por su naturaleza, así que se dice eso y no
/// "SIN SMART", que sugiere un fallo (concordancia con la ficha del dashboard).
String _saludDisco(DiskInfo d) => d.removable && !d.smartAvailable
    ? 'MEMORIA EXTRAÍBLE'
    : _healthLabel(d.healthStatus);

String _healthLabel(DiskHealth h) {
  switch (h) {
    case DiskHealth.good:
      return 'SALUDABLE';
    case DiskHealth.warning:
      return 'ADVERTENCIA';
    case DiskHealth.fail:
      return 'FALLA';
    case DiskHealth.unknown:
      return 'SIN SMART';
  }
}

/// Misma heurística integrada/dedicada que el dashboard (normaliza "(tm)"/"(r)"
/// para que "AMD Radeon(TM) Graphics" cuente como integrada).
String _gpuKind(GpuCard card) {
  final v = card.vendor.toLowerCase();
  final p = card.product
      .toLowerCase()
      .replaceAll('(tm)', '')
      .replaceAll('(r)', '');
  final integrada =
      v.contains('intel') ||
      p.contains('uhd') ||
      p.contains('iris') ||
      p.contains('vega') ||
      p.contains('radeon graphics') ||
      p.contains('raphael') ||
      p.contains('cezanne') ||
      p.contains('renoir') ||
      p.contains('phoenix') ||
      p.contains('rembrandt') ||
      p.contains('hawk point');
  return integrada ? 'Integrada' : 'Dedicada';
}

// ---------------------------------------------------------------------------
// Exportación del "Software instalado" y de la pestaña "Controladores".
//
// Como todos los reportes de PCInfo, salen en MARKDOWN (.md): la lista de
// software es una tabla larga, y en .md se puede pegar en un ticket, un informe
// o un repositorio y sigue leyéndose ordenada.
// ---------------------------------------------------------------------------

/// Guarda el inventario de software en un .md agrupado por quién instaló cada
/// programa. Pregunta dónde guardarlo. Devuelve la ruta escrita, o null si el
/// usuario canceló.
Future<String?> saveSoftwareReport(SoftwareInfo sw, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildSoftwareMarkdown(sw, equipo),
    nombre: 'PCInfo_Software_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Guarda el inventario de controladores y redes WiFi en un .md. Pregunta dónde
/// guardarlo. Devuelve la ruta escrita, o null si el usuario canceló.
Future<String?> saveControladoresReport(ControladoresInfo ctl, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildControladoresMarkdown(ctl, equipo),
    nombre: 'PCInfo_Controladores_${host}_${_fileStamp()}.md',
    extension: 'md',
  );
}

/// Construye el .md del software instalado.
///
/// La organización es la que pidió el uso real: PRIMERO lo que instaló el
/// usuario —que es lo que distingue a este equipo y lo que hay que reponer si se
/// formatea— y después lo que vino con el sistema operativo. Dentro de cada
/// grupo se separa por tipo (programas, apps de la Tienda, componentes,
/// actualizaciones) para que la tabla no mezcle un antivirus con un parche.
String buildSoftwareMarkdown(SoftwareInfo sw, String equipo) {
  final b = StringBuffer();
  final nombre = equipo.isEmpty ? 'este equipo' : equipo;

  b
    ..writeln('# Software instalado — $nombre')
    ..writeln()
    ..writeln(
      'Generado por $appName v$appVersion Rev $appRevision '
      'el ${_humanStamp()}.',
    )
    ..writeln();
  if (sw.source.isNotEmpty) b.writeln('- **Fuentes:** ${sw.source}');
  b
    ..writeln(
      '- **Total:** ${sw.items.length} elementos '
      '(${sw.delUsuario.length} · ${sw.tituloUsuario.toLowerCase()}, '
      '${sw.delSistema.length} · ${sw.tituloSistema.toLowerCase()})',
    )
    ..writeln();
  if (sw.reason.isNotEmpty) {
    b
      ..writeln('> ⚠️ ${sw.reason}')
      ..writeln();
  }

  _grupoMarkdown(b, sw.tituloUsuario, sw.delUsuario);
  _grupoMarkdown(b, sw.tituloSistema, sw.delSistema);

  return b.toString();
}

/// Escribe un grupo (usuario / sistema) con una tabla por tipo de elemento.
void _grupoMarkdown(StringBuffer b, String titulo, List<SoftwareItem> items) {
  b
    ..writeln('## $titulo (${items.length})')
    ..writeln();
  if (items.isEmpty) {
    b
      ..writeln('_Ninguno._')
      ..writeln();
    return;
  }
  // Orden fijo de los subgrupos: primero lo que un humano reconoce como
  // "programa", al final el ruido (parches).
  const orden = [
    SoftwareKind.programa,
    SoftwareKind.tienda,
    SoftwareKind.componente,
    SoftwareKind.actualizacion,
  ];
  const titulos = {
    SoftwareKind.programa: 'Programas',
    SoftwareKind.tienda: 'Apps de la Tienda',
    SoftwareKind.componente: 'Componentes y runtimes',
    SoftwareKind.actualizacion: 'Actualizaciones y parches',
  };

  for (final tipo in orden) {
    final grupo = items.where((e) => e.kind == tipo).toList();
    if (grupo.isEmpty) continue;
    b
      ..writeln('### ${titulos[tipo]} (${grupo.length})')
      ..writeln()
      ..writeln('| Programa | Versión | Fabricante | Instalado | Tamaño |')
      ..writeln('| --- | --- | --- | --- | --- |');
    for (final e in grupo) {
      b.writeln(
        '| ${_md(e.name)} | ${_md(e.versionVisible)} | '
        '${_md(e.publisher)} | ${_md(e.installed)} | '
        '${e.sizeMB > 0 ? '${e.sizeMB} MB' : ''} |',
      );
    }
    b.writeln();
  }

  // Lo que no encaje en ningún subgrupo conocido no se pierde: si el backend
  // añade un tipo nuevo, sigue apareciendo en el reporte.
  final resto = items.where((e) => !orden.contains(e.kind)).toList();
  if (resto.isNotEmpty) {
    b
      ..writeln('### Otros (${resto.length})')
      ..writeln()
      ..writeln('| Programa | Versión | Fabricante |')
      ..writeln('| --- | --- | --- |');
    for (final e in resto) {
      b.writeln(
        '| ${_md(e.name)} | ${_md(e.versionVisible)} | ${_md(e.publisher)} |',
      );
    }
    b.writeln();
  }
}

/// Construye el .md de controladores y redes WiFi.
String buildControladoresMarkdown(ControladoresInfo ctl, String equipo) {
  final b = StringBuffer();
  final nombre = equipo.isEmpty ? 'este equipo' : equipo;

  b
    ..writeln('# Controladores y redes WiFi — $nombre')
    ..writeln()
    ..writeln(
      'Generado por $appName v$appVersion Rev $appRevision '
      'el ${_humanStamp()}.',
    )
    ..writeln();
  if (ctl.reason.isNotEmpty) {
    b
      ..writeln('> ⚠️ ${ctl.reason}')
      ..writeln();
  }

  _pendientesMarkdown(b, ctl);

  b
    ..writeln('## Controladores de terceros (${ctl.drivers.length})')
    ..writeln();
  if (ctl.drivers.isEmpty) {
    b
      ..writeln(
        '_Ninguno: los controladores en uso vienen en la propia imagen '
        'del sistema._',
      )
      ..writeln();
  } else {
    b
      ..writeln(
        '| Controlador | Fabricante | Tipo | Versión | Fecha | Windows |',
      )
      ..writeln('| --- | --- | --- | --- | --- | --- |');
    for (final c in ctl.drivers) {
      b.writeln(
        '| ${_md(c.visible)} | ${_md(c.provider)} | ${_md(c.clase)} | '
        '${_md(c.version)} | ${_md(c.date)} | ${_md(c.name)} |',
      );
    }
    b.writeln();
  }

  b
    ..writeln('## Redes WiFi guardadas (${ctl.wifi.length})')
    ..writeln();
  if (ctl.wifi.isEmpty) {
    b
      ..writeln('_Ninguna._')
      ..writeln();
    return b.toString();
  }
  // Las contraseñas van en el reporte a propósito (sin ellas no sirve para
  // reponer las redes), pero el archivo queda avisado: es información sensible.
  b
    ..writeln(
      '> ⚠️ **Este archivo contiene las contraseñas de las redes en '
      'texto legible.** Guárdalo donde corresponda o bórralo al terminar.',
    )
    ..writeln()
    ..writeln('| Red | Seguridad | Contraseña |')
    ..writeln('| --- | --- | --- |');
  for (final r in ctl.wifi) {
    final clave = r.abierta
        ? '_red abierta_'
        : r.password.isEmpty
        ? '_no se pudo leer_'
        : _md(r.password);
    b.writeln('| ${_md(r.name)} | ${_md(r.auth)} | $clave |');
  }
  b.writeln();
  return b.toString();
}

/// Sección de dispositivos con problema. Va ANTES que los controladores porque
/// es lo que se lleva el técnico a leer: qué le falta al equipo y qué de eso
/// está así a propósito.
void _pendientesMarkdown(StringBuffer b, ControladoresInfo ctl) {
  if (!ctl.supported) return;

  b
    ..writeln('## Dispositivos sin controlador (${ctl.pendientes.length})')
    ..writeln();
  if (ctl.pendientes.isEmpty) {
    b
      ..writeln(
        '_Ninguno: Windows no marca ningún dispositivo como sin controlador, '
        'deshabilitado ni detenido._',
      )
      ..writeln();
    return;
  }

  b
    ..writeln('| Dispositivo | Tipo | Qué le pasa | ID de hardware |')
    ..writeln('| --- | --- | --- | --- |');
  for (final p in ctl.pendientes) {
    b.writeln(
      '| ${_md(p.nombre)} | ${_md(p.clase)} | ${_md(p.estado)} | '
      '${_md(p.hardwareId)} |',
    );
  }
  b.writeln();

  final explicados = ctl.pendientesExplicados;
  if (explicados.isEmpty) return;

  b
    ..writeln('### De estos, ${explicados.length} son casos conocidos')
    ..writeln();
  for (final p in explicados) {
    final caso = p.conocido!;
    b
      ..writeln('**${_md(p.nombre)} — ${_md(caso.titular)}: ${_md(caso.nombre)}**')
      ..writeln()
      ..writeln('- ${_md(caso.descripcion)}')
      ..writeln('- ${_md(caso.motivo)}')
      ..writeln('- _Fuente: ${_md(caso.fuente)}_')
      ..writeln();
  }
}

/// Escapa lo que rompería una celda de tabla Markdown: la barra vertical la
/// interpreta como separador de columna y el salto de línea corta la fila.
///
/// Lo que trae contrabarras (rutas de Windows como `\\.\\PHYSICALDRIVE0` o
/// `C:\\Windows\\...`) se envuelve en acentos graves: sin eso, al mostrar el .md
/// la contrabarra se come el carácter siguiente y la ruta que se copia del
/// reporte ya no es la del equipo.
String _md(String s) {
  final v = s.replaceAll('|', '\\|').replaceAll('\n', ' ').trim();
  if (s.contains('\\') && !v.contains('`')) return '`$v`';
  return v;
}

// ---------------------------------------------------------------------------
// Reporte de la pestaña "Batería".
//
// Mismo criterio que en pantalla: primero el veredicto, después las cifras y
// por último la explicación. Los textos NO se redactan aquí: vienen del backend
// (verdict y notes) para que digan exactamente lo mismo que la app.
// ---------------------------------------------------------------------------

String buildBateriaReport(BateriaInfo bat, String equipo) {
  final b = StringBuffer();
  _cabecera(b, 'Estado de la batería', equipo);
  if (bat.source.isNotEmpty) {
    b
      ..writeln('Fuente: ${_md(bat.source)}.')
      ..writeln();
  }

  final p = bat.principal;
  if (p == null) {
    b
      ..writeln(
        _md(
          bat.reason.isNotEmpty ? bat.reason : 'Este equipo no tiene batería.',
        ),
      )
      ..writeln();
    _pie(b);
    return b.toString();
  }

  b
    ..writeln('## ¿Cómo está la batería?')
    ..writeln()
    ..writeln('**${_md(p.verdict)}**')
    ..writeln();
  if (p.healthPercent >= 0) {
    b.writeln(
      '- Salud: ${p.healthPercent} % de la capacidad que tenía nueva '
      '(${_md(p.etiquetaSalud)}).',
    );
  }
  if (p.chargePercent >= 0) {
    b.writeln(
      '- Ahora mismo: ${p.chargePercent} % de carga · '
      '${_md(BateriaEstado.etiqueta(p.state))}.',
    );
  }
  b.writeln();

  b
    ..writeln('## Cifras')
    ..writeln();
  _tabla(b, ['Dato', 'Valor']);
  _fila(b, [
    'Cuando era nueva aguantaba',
    '${energiaEnPalabras(p.designMWh)}'
        '${p.designMWh > 0 ? " (${p.designMWh} mWh)" : ""}',
  ]);
  _fila(b, [
    'Hoy, cargada al 100 %',
    '${energiaEnPalabras(p.fullMWh)}'
        '${p.fullMWh > 0 ? " (${p.fullMWh} mWh)" : ""}',
  ]);
  if (p.remainingMWh > 0) {
    _fila(b, ['En este momento', energiaEnPalabras(p.remainingMWh)]);
  }
  _fila(b, [
    'Veces que se ha cargado',
    p.cycleCount > 0 ? '${p.cycleCount}' : 'el equipo no lleva esa cuenta',
  ]);
  b.writeln();

  b
    ..writeln('## Cuánto dura sin enchufar')
    ..writeln()
    ..writeln(
      '> La cuenta del sistema sale del uso habitual; usándolo a tope '
      'dura bastante menos.',
    )
    ..writeln();
  _tabla(b, ['Situación', 'Duración']);
  if (bat.runtimeHeavyMin > 0) {
    _fila(b, [
      'Usándolo a tope (vídeo, brillo alto)',
      'unos ${duracionEnPalabras(bat.runtimeHeavyMin)}',
    ]);
  }
  if (bat.runtimeFullMin > 0) {
    _fila(b, [
      'En el uso de siempre, al 100 %',
      duracionEnPalabras(bat.runtimeFullMin),
    ]);
  }
  if (bat.runtimeNowMin > 0) {
    _fila(b, [
      'Con la carga que le queda ahora',
      duracionEnPalabras(bat.runtimeNowMin),
    ]);
  }
  if (bat.wattsTypicalMW > 0) {
    _fila(b, [
      'Consumo medido del equipo',
      '${vatiosEnPalabras(bat.wattsTypicalMW)} en uso habitual'
          '${bat.wattsHeavyMW > 0 ? ", ${vatiosEnPalabras(bat.wattsHeavyMW)} a tope" : ""}',
    ]);
  }
  b.writeln();

  b
    ..writeln('## Para pedir una batería nueva')
    ..writeln();
  _tabla(b, ['Dato', 'Valor']);
  _fila(b, [
    'Modelo de la batería',
    p.model.isNotEmpty ? p.model : 'no lo publica el equipo',
  ]);
  if (p.manufacturer.isNotEmpty) _fila(b, ['Fabricante', p.manufacturer]);
  if (bat.equipment.isNotEmpty) _fila(b, ['Para el equipo', bat.equipment]);
  if (p.voltageMV > 0) {
    _fila(b, [
      'Voltaje',
      '${voltiosEnPalabras(p.voltageMV)} (con otro voltaje NO sirve, aunque encaje)',
    ]);
  }
  _fila(b, [
    'Capacidad',
    '${energiaEnPalabras(p.designMWh)}'
        '${p.designMAh > 0 ? " · ${p.designMAh} mAh" : ""}',
  ]);
  final quimicaRepuesto = p.chemistryText.isNotEmpty
      ? p.chemistryText
      : p.chemistry;
  if (quimicaRepuesto.isNotEmpty) {
    _fila(b, ['De qué está hecha', quimicaRepuesto]);
  }
  b.writeln();

  if (p.notes.isNotEmpty) {
    b
      ..writeln('## Qué significa todo esto')
      ..writeln();
    for (final n in p.notes) {
      b
        ..writeln('### ${_md(n.title)}')
        ..writeln()
        ..writeln(_md(n.detail))
        ..writeln();
    }
  }

  b
    ..writeln('## Datos técnicos')
    ..writeln();
  _tabla(b, ['Dato', 'Valor']);
  if (p.name.isNotEmpty) _fila(b, ['Como la llama el equipo', p.name]);
  if (p.serial.isNotEmpty) _fila(b, ['Número de serie', p.serial]);
  if (p.designMWh > 0) _fila(b, ['Capacidad de fábrica', '${p.designMWh} mWh']);
  if (p.fullMWh > 0) _fila(b, ['Capacidad actual', '${p.fullMWh} mWh']);
  if (bat.onAcKnown) {
    _fila(b, ['Corriente', bat.onAc ? 'enchufado' : 'funcionando con batería']);
  }
  b.writeln();

  if (bat.history.length > 1) {
    b
      ..writeln('## Cómo ha ido bajando')
      ..writeln();
    _tabla(b, ['Periodo', 'Capacidad', 'Salud']);
    for (final h in bat.history) {
      _fila(b, [
        h.period,
        energiaEnPalabras(h.fullMWh),
        h.healthPercent >= 0
            ? '${h.healthPercent} % de su capacidad de fábrica'
            : '',
      ]);
    }
    b.writeln();
  }

  if (bat.reason.isNotEmpty) {
    b
      ..writeln('> ⚠️ ${_md(bat.reason)}')
      ..writeln();
  }

  _pie(b);
  return b.toString();
}

// ---------------------------------------------------------------------------
// Reporte de la pestaña "Discos".
//
// Mismo criterio que la batería: primero el veredicto de cada disco y después
// el porqué. Los textos vienen del backend (verdict y notes) para que digan
// exactamente lo mismo que la app.
// ---------------------------------------------------------------------------

String buildDiscosReport(List<DiskInfo> discos, String equipo) {
  final b = StringBuffer();
  _cabecera(b, 'Salud de los discos', equipo);

  if (discos.isEmpty) {
    b
      ..writeln('_No se encontró ningún disco._')
      ..writeln();
    _pie(b);
    return b.toString();
  }

  for (final (i, d) in discos.indexed) {
    b
      ..writeln('## Disco ${i + 1} — ${_md(d.titulo)}')
      ..writeln()
      ..writeln('**${_md(d.verdict)}**')
      ..writeln();
    _tabla(b, ['Dato', 'Valor']);
    if (d.lifePercentLeft >= 0) {
      _fila(b, ['Vida que le queda', '${d.lifePercentLeft} %']);
    }
    _fila(b, ['Tipo', d.type]);
    _fila(b, ['Capacidad', formatDiskCap(d.sizeBytes)]);
    if (d.hasUsage) {
      _fila(b, [
        'Espacio usado',
        '${formatBytes(d.usedBytes)} de ${formatBytes(d.fsTotalBytes)} '
            '(${d.usedPercent.round()} %), libres ${formatBytes(d.availBytes)}',
      ]);
    }
    if (d.powerOnHours > 0) {
      _fila(b, ['Tiempo encendido', '${formatEntero(d.powerOnHours)} h']);
      if (d.powerCycles > 0) {
        _fila(b, ['Veces que se ha encendido', formatEntero(d.powerCycles)]);
      }
    }
    if (d.writtenBytes > 0) {
      _fila(b, ['Datos escritos', formatBytes(d.writtenBytes)]);
    }
    if (d.smartAvailable) {
      _fila(b, ['Trozos dañados', '${d.reallocatedSectors}']);
    }
    if (d.serial.isNotEmpty) _fila(b, ['Número de serie', d.serial]);
    _fila(b, ['Dispositivo', d.name]);
    b.writeln();

    if (d.notes.isNotEmpty) {
      b
        ..writeln('### Qué significa todo esto')
        ..writeln();
      for (final n in d.notes) {
        b
          ..writeln('**${_md(n.title)}**')
          ..writeln()
          ..writeln(_md(n.detail))
          ..writeln();
      }
    }
  }

  _pie(b);
  return b.toString();
}


/// Construye "Encendidos y apagados" en Markdown, espejo de la pestaña
/// `arranques_page.dart`. Si se agrega o quita un dato allí, reflejarlo aquí
/// (misma regla de concordancia que el resto de los reportes).
String buildArranquesReport(ArranquesInfo arr, String equipo) {
  final b = StringBuffer();
  _cabecera(b, 'Encendidos y apagados', equipo);

  _tabla(b, ['Dato', 'Valor']);
  _fila(b, ['Sistema', arr.os]);
  _fila(b, ['Fuente', arr.source]);
  _fila(b, ['Periodo analizado', 'últimos ${arr.scanDays} días']);
  _fila(b, ['Administrador/root', arr.elevated ? 'sí' : 'no']);
  b.writeln();

  if (arr.reason.isNotEmpty) {
    b
      ..writeln('> ⚠️ ${_md(arr.reason)}')
      ..writeln();
  }

  // El resumen va primero: quien reciba el reporte tiene que ver de una si el
  // equipo se está apagando mal, no deducirlo contando filas.
  b
    ..writeln('## Resumen')
    ..writeln()
    ..writeln(_md(arr.resumen))
    ..writeln();
  _tabla(b, ['Concepto', 'Cuántos']);
  _fila(b, ['Encendidos registrados', '${arr.sessions.length}']);
  _fila(b, ['Apagados normales', '${arr.normales}']);
  _fila(b, ['Reinicios', '${arr.reinicios}']);
  _fila(b, ['Apagones bruscos', '${arr.bruscos}']);
  _fila(b, ['Tareas automáticas propias', '${arr.tareasPropias.length}']);
  _fila(b, ['Tareas que fallaron', '${arr.tareasFallidas.length}']);
  _fila(b, ['Programas al iniciar sesión', '${arr.startup.length}']);
  b.writeln();

  b
    ..writeln('## Encendidos y apagados (${arr.sessions.length})')
    ..writeln();
  if (arr.sessionsNote.isNotEmpty) {
    b
      ..writeln('> ${_md(arr.sessionsNote)}')
      ..writeln();
  }
  if (arr.sessions.isEmpty) {
    b
      ..writeln('_No hay historial de encendidos disponible._')
      ..writeln();
  } else {
    // Mismo agrupado que la pantalla (día · encendió · se apagó), en columnas
    // para que la tabla se siga pudiendo ordenar y pegar entera.
    _tabla(b, [
      'Día', 'Encendió', 'Se apagó', 'Estuvo encendido', 'Cómo terminó', 'Núcleo',
    ]);
    for (final g in arr.sesionesPorDia) {
      for (final (i, s) in g.sesiones.indexed) {
        _fila(b, [
          i == 0 ? fechaLarga(g.dia) : '',
          s.horaInicio,
          s.enCurso
              ? 'sigue encendido'
              // El mismo letrero que la pantalla: lo que no ocurrió se dice, no
              // se deja en blanco para que lo adivine quien lea el reporte.
              : (s.fueBrusco
                  ? 'NO SE REALIZÓ EL APAGADO'
                  : s.horaFin + (s.apagadoOtroDia ? ' del ${s.diaFinCorto}' : '')),
          s.duracion,
          FinSesion.etiqueta(s.ended),
          s.kernel,
        ]);
      }
    }
    b.writeln();

    // El detalle solo de los cortes bruscos: del resto no hay nada que contar.
    final cortes = arr.sessions.where((s) => s.fueBrusco).toList();
    if (cortes.isNotEmpty) {
      b
        ..writeln('### Detalle de los apagones bruscos (${cortes.length})')
        ..writeln();
      for (final s in cortes) {
        b
          ..writeln('**Sesión del ${_md(s.start)}**')
          ..writeln()
          ..writeln(_md(s.note))
          ..writeln();
        if (s.lastLine.isNotEmpty) {
          b
            ..writeln('Última línea registrada antes del corte:')
            ..writeln()
            ..writeln(_bloque(s.lastLine));
        }
      }
    }
  }

  b
    ..writeln('## Tareas automáticas (${arr.tasks.length})')
    ..writeln();
  if (arr.tasksNote.isNotEmpty) {
    b
      ..writeln('> ${_md(arr.tasksNote)}')
      ..writeln();
  }
  _seccionTareas(b, 'Añadidas a este equipo', arr.tareasPropias);
  _seccionTareas(b, 'Vienen con el sistema', arr.tareasDelSistema);

  b
    ..writeln('## Programas al iniciar sesión (${arr.startup.length})')
    ..writeln();
  if (arr.startupNote.isNotEmpty) {
    b
      ..writeln('> ${_md(arr.startupNote)}')
      ..writeln();
  }
  _seccionInicio(b, 'De este usuario', arr.inicioPropio);
  _seccionInicio(b, 'Del escritorio, para todos los usuarios', arr.inicioDelSistema);

  _pie(b);
  return b.toString();
}

void _seccionTareas(StringBuffer b, String titulo, List<TareaAutomatica> items) {
  if (items.isEmpty) return;
  b
    ..writeln('### $titulo (${items.length})')
    ..writeln();
  _tabla(b, ['Tarea', 'Tipo', 'Cuándo', 'Última vez', 'Resultado', 'Estado', 'Ejecuta']);
  for (final t in items) {
    _fila(b, [
      t.name,
      TipoTarea.etiqueta(t.kind),
      t.trigger,
      t.ultimaVezTexto,
      t.result,
      EstadoTarea.etiqueta(t.state),
      t.command,
    ]);
  }
  b.writeln();
}

void _seccionInicio(StringBuffer b, String titulo, List<ProgramaInicio> items) {
  if (items.isEmpty) return;
  b
    ..writeln('### $titulo (${items.length})')
    ..writeln();
  _tabla(b, ['Programa', 'Estado', 'Corriendo ahora', 'Ejecuta', 'Archivo']);
  for (final p in items) {
    _fila(b, [
      p.name,
      p.enabled ? 'activo' : 'desactivado',
      p.running ? 'sí' : 'no',
      p.command,
      p.source,
    ]);
  }
  b.writeln();
}
