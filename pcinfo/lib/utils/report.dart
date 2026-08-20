import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../models/bateria.dart';
import '../models/controladores.dart';
import '../models/errores.dart';
import '../models/hardware.dart';
import '../models/software.dart';
import '../version.dart';
import 'format.dart';

/// Genera un .txt con TODO lo que se ve en pantalla (sistema, CPU, placa, RAM,
/// GPU y discos con uso + SMART). Pregunta DÓNDE guardarlo con el diálogo del
/// sistema. Devuelve la ruta escrita, o null si el usuario canceló.
Future<String?> saveReport(HardwareInfo hw) {
  final host = _safe(hw.system.hostname.isEmpty ? 'equipo' : hw.system.hostname);
  return _guardaConDialogo(
    texto: buildReport(hw),
    nombre: 'PCInfo_${host}_${_fileStamp()}.txt',
    extension: 'txt',
  );
}

/// Guarda el "Historial de Errores" en un .txt (equivalente al C:\bluescreen.txt
/// del script de Windows, pero con TODO lo que muestra la pestaña y en ambos
/// sistemas). Devuelve la ruta escrita, o null si el usuario canceló.
Future<String?> saveErroresReport(ErroresInfo err, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildErroresReport(err, equipo),
    nombre: 'PCInfo_Errores_${host}_${_fileStamp()}.txt',
    extension: 'txt',
  );
}

/// Guarda el informe de la batería en un .txt. Sale en texto plano (no en .md)
/// porque es una explicación para leer, no una tabla: se pega tal cual en un
/// correo o en un ticket. Devuelve la ruta escrita, o null si se canceló.
Future<String?> saveBateriaReport(BateriaInfo bat, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildBateriaReport(bat, equipo),
    nombre: 'PCInfo_Bateria_${host}_${_fileStamp()}.txt',
    extension: 'txt',
  );
}

/// Guarda la salud de los discos en un .txt: el veredicto de cada uno y las
/// explicaciones, tal como se ven en la pestaña. Devuelve la ruta escrita, o
/// null si se canceló.
Future<String?> saveDiscosReport(List<DiskInfo> discos, String equipo) {
  final host = _safe(equipo.isEmpty ? 'equipo' : equipo);
  return _guardaConDialogo(
    texto: buildDiscosReport(discos, equipo),
    nombre: 'PCInfo_Discos_${host}_${_fileStamp()}.txt',
    extension: 'txt',
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
          extensions: [extension]),
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

/// Construye el texto del reporte, espejo de las fichas del dashboard.
String buildReport(HardwareInfo hw) {
  final b = StringBuffer();
  void line([String s = '']) => b.writeln(s);
  void kv(String k, String v) => line('  $k: $v');
  void section(String t) {
    line();
    line('== $t ==');
  }

  line('$appName v$appVersion Rev $appRevision');
  line('Reporte de hardware generado: ${_humanStamp()}');
  line('Equipo: ${hw.system.hostname}');
  line('=' * 60);

  // Sistema operativo
  section('Sistema operativo');
  kv('Sistema', hw.system.distro);
  kv('Nombre del equipo', hw.system.hostname);
  kv('Kernel', hw.system.kernel);
  kv('Arquitectura', hw.system.arch);
  if (hw.system.desktop.isNotEmpty) kv('Escritorio', hw.system.desktop);

  // CPU
  final c = hw.cpu;
  section('Procesador (CPU)');
  kv('Fabricante', cleanVendor(c.vendor));
  kv('Modelo', c.model);
  kv('Núcleos', '${c.cores}');
  kv('Hilos', '${c.threads}');
  kv('Frecuencia base', formatMhz(c.baseMhz));
  if (c.maxMhz > 0) kv('Frecuencia máxima', formatMhz(c.maxMhz));

  // Tarjeta madre
  final bd = hw.board;
  section('Tarjeta madre');
  kv('Fabricante', bd.vendor);
  kv('Modelo', bd.product);
  if (bd.formFactor.isNotEmpty) kv('Tamaño', bd.formFactor);
  if (bd.version.isNotEmpty) kv('Versión', bd.version);
  kv('BIOS', '${bd.biosVendor} ${bd.biosVersion}'.trim());
  kv('Fecha BIOS', bd.biosDate);

  // RAM
  final m = hw.memory;
  section('Memoria RAM');
  kv('Total', formatBytes(m.totalBytes));
  kv('Montaje', m.soldered ? 'Soldada (no ampliable)' : 'Ranuras (ampliable)');
  if (m.totalSlots > 0) {
    kv('Ranuras', '${m.modules.length} de ${m.totalSlots} ocupadas');
    kv('Ranuras libres', '${m.freeSlots}');
  } else {
    kv('Módulos', '${m.modules.length}');
  }
  if (m.maxCapacityBytes > 0) kv('Capacidad máx.', formatBytes(m.maxCapacityBytes));
  if (!m.slotsVerified && !m.soldered && m.totalSlots > 0) {
    line('    (!) Ranuras y capacidad máx. según el firmware; puede no coincidir '
        'con la placa (modelo no verificado en el catálogo).');
  }
  for (final mod in m.modules) {
    final ff = mod.formFactor.isEmpty ? '' : ' · ${mod.formFactor}';
    final spd = mod.speedMhz > 0 ? ' ${mod.speedMhz}MHz' : '';
    line('    - ${mod.location}$ff: ${formatBytes(mod.sizeBytes)} ${mod.type}$spd'
        .trimRight());
  }
  final libres = m.freeSlots;
  for (var i = 0; i < libres; i++) {
    line('    - Ranura libre: Vacía');
  }

  // GPU — una sección por tarjeta (espejo de las fichas del dashboard).
  if (hw.gpu.cards.isEmpty) {
    section('Tarjeta gráfica (GPU)');
    kv('Estado', 'No detectada');
  } else {
    final multi = hw.gpu.cards.length > 1;
    for (final (i, card) in hw.gpu.cards.indexed) {
      section(multi
          ? 'Tarjeta gráfica ${i + 1} · ${_gpuKind(card)}'
          : 'Tarjeta gráfica (GPU)');
      kv('Fabricante', cleanVendor(card.vendor));
      kv('Modelo', card.product);
      kv('Tipo', _gpuKind(card));
      if (card.memoryBytes > 0) kv('VRAM', formatBytes(card.memoryBytes));
      kv('Driver', card.driver);
    }
  }

  // Almacenamiento
  section('Almacenamiento');
  if (hw.disks.isEmpty) {
    line('  No se detectaron discos');
  } else {
    for (final (i, d) in hw.disks.indexed) {
      line();
      line('  Disco ${i + 1}: ${d.model}');
      kv('Tipo', d.type.isEmpty ? '—' : d.type);
      kv('Salud', _saludDisco(d));
      kv('Dispositivo', d.name);
      kv('Serie', d.serial);
      kv('Bus', d.bus.toUpperCase());
      kv('Capacidad', formatDiskCap(d.sizeBytes));
      if (d.hasUsage) {
        kv('Ocupado',
            '${formatGB(d.usedBytes)} (${d.usedPercent.round()}%)');
        kv('Disponible',
            '${formatGB(d.availBytes)} (${d.availPercent.round()}%)');
      }
      if (d.smartAvailable) {
        if (d.writtenBytes > 0) kv('Escrituras totales', formatBytes(d.writtenBytes));
        if (d.readBytes > 0) kv('Lecturas totales', formatBytes(d.readBytes));
        if (d.lifePercentUsed >= 0) {
          kv('Vida restante', '${100 - d.lifePercentUsed}%');
        }
        kv('Horas encendido', '${d.powerOnHours} h');
        kv('Ciclos de encendido', '${d.powerCycles}');
        kv('Sectores reasignados', '${d.reallocatedSectors}');
      }
    }
  }

  line();
  line('=' * 60);
  line('$appCopyright · $appEmail · Licencia $appLicense');
  return b.toString();
}

/// Construye el texto del historial de errores, espejo de la pestaña
/// "Historial de Errores". Si se agrega o quita un dato en `errores_page.dart`,
/// reflejarlo aquí (misma regla de concordancia que el reporte de hardware).
String buildErroresReport(ErroresInfo err, String equipo) {
  final b = StringBuffer();
  void line([String s = '']) => b.writeln(s);

  line('$appName v$appVersion Rev $appRevision');
  line('Historial de errores del sistema · generado: ${_humanStamp()}');
  if (equipo.isNotEmpty) line('Equipo: $equipo');
  // Qué instalación se leyó: sin esto, un reporte hecho desde un medio de
  // rescate parecería del propio medio y no del equipo averiado.
  if (err.target.isNotEmpty) {
    line('Instalación analizada: ${err.targetLabel.isEmpty ? err.target : err.targetLabel}'
        '   (${err.target})'
        '${err.offline ? "   [NO estaba en ejecución]" : ""}');
  }
  line('Sistema: ${err.os}   ·   Fuente: ${err.source}');
  line('Periodo analizado: últimos ${err.scanDays} días');
  line('Administrador/root: ${err.elevated ? "sí" : "no"}');
  if (err.reason.isNotEmpty) line('Aviso: ${err.reason}');
  line('=' * 78);

  if (err.items.isEmpty) {
    line();
    line(err.available
        ? 'No se registraron errores en el periodo analizado.'
        : 'No hay información disponible (ver el aviso de arriba).');
  }

  for (final (i, e) in err.items.indexed) {
    line();
    line('-' * 78);
    line('#${i + 1}  [${_sevTexto(e.severity)}] [${_tipoTexto(e.kind)}]  ${e.title}');
    line('-' * 78);
    line('Cuándo      : ${e.when}'
        '${e.repetido ? "   (${e.count} veces, desde ${e.firstWhen})" : ""}');
    line('Origen      : ${e.source}');
    if (e.code.isNotEmpty) {
      line('Código      : ${e.code}${e.codeName.isNotEmpty ? "  ${e.codeName}" : ""}');
    }
    if (e.culprit.isNotEmpty) {
      line('Causante    : ${e.culprit}'
          '${e.confidence.isNotEmpty ? "   (confianza ${e.confidence})" : ""}');
      if (e.culpritInfo.isNotEmpty) line('              ${e.culpritInfo}');
    }
    for (final s in e.suspects.skip(1)) {
      line('Sospechoso  : $s');
    }
    if (e.cause.isNotEmpty) line('Qué pasó    : ${e.cause}');
    if (e.fix.isNotEmpty) line('Solución    : ${e.fix}');
    if (e.detail.isNotEmpty) {
      line();
      line('--- Mensaje original del sistema ---');
      for (final l in e.detail.split('\n')) {
        line(l.trimRight());
      }
    }
  }

  if (err.dumps.isNotEmpty) {
    line();
    line('=' * 78);
    line('Volcados de memoria presentes en el disco');
    for (final d in err.dumps) {
      line('  ${d.when}   ${formatBytes(d.sizeBytes).padLeft(10)}   ${d.path}');
    }
  }

  line();
  line('=' * 78);
  line('$appCopyright · $appEmail · Licencia $appLicense');
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
String _saludDisco(DiskInfo d) =>
    d.removable && !d.smartAvailable ? 'MEMORIA EXTRAÍBLE' : _healthLabel(d.healthStatus);

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
  final integrada = v.contains('intel') ||
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
// Estos dos reportes salen en MARKDOWN (.md) y no en .txt como los de hardware
// y errores: la lista de software es una tabla larga, y en .md se puede pegar
// en un ticket, un informe o un repositorio y sigue leyéndose ordenada.
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
Future<String?> saveControladoresReport(
    ControladoresInfo ctl, String equipo) {
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
    ..writeln('Generado por $appName v$appVersion Rev $appRevision '
        'el ${_humanStamp()}.')
    ..writeln();
  if (sw.source.isNotEmpty) b.writeln('- **Fuentes:** ${sw.source}');
  b
    ..writeln('- **Total:** ${sw.items.length} elementos '
        '(${sw.delUsuario.length} · ${sw.tituloUsuario.toLowerCase()}, '
        '${sw.delSistema.length} · ${sw.tituloSistema.toLowerCase()})')
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
      b.writeln('| ${_md(e.name)} | ${_md(e.versionVisible)} | '
          '${_md(e.publisher)} | ${_md(e.installed)} | '
          '${e.sizeMB > 0 ? '${e.sizeMB} MB' : ''} |');
    }
    b.writeln();
  }

  // Lo que no encaje en ningún subgrupo conocido no se pierde: si el backend
  // añade un tipo nuevo, sigue apareciendo en el reporte.
  final resto =
      items.where((e) => !orden.contains(e.kind)).toList();
  if (resto.isNotEmpty) {
    b
      ..writeln('### Otros (${resto.length})')
      ..writeln()
      ..writeln('| Programa | Versión | Fabricante |')
      ..writeln('| --- | --- | --- |');
    for (final e in resto) {
      b.writeln(
          '| ${_md(e.name)} | ${_md(e.versionVisible)} | ${_md(e.publisher)} |');
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
    ..writeln('Generado por $appName v$appVersion Rev $appRevision '
        'el ${_humanStamp()}.')
    ..writeln();
  if (ctl.reason.isNotEmpty) {
    b
      ..writeln('> ⚠️ ${ctl.reason}')
      ..writeln();
  }

  b
    ..writeln('## Controladores de terceros (${ctl.drivers.length})')
    ..writeln();
  if (ctl.drivers.isEmpty) {
    b
      ..writeln('_Ninguno: los controladores en uso vienen en la propia imagen '
          'del sistema._')
      ..writeln();
  } else {
    b
      ..writeln('| Controlador | Fabricante | Tipo | Versión | Fecha | Windows |')
      ..writeln('| --- | --- | --- | --- | --- | --- |');
    for (final c in ctl.drivers) {
      b.writeln('| ${_md(c.visible)} | ${_md(c.provider)} | ${_md(c.clase)} | '
          '${_md(c.version)} | ${_md(c.date)} | ${_md(c.name)} |');
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
    ..writeln('> ⚠️ **Este archivo contiene las contraseñas de las redes en '
        'texto legible.** Guárdalo donde corresponda o bórralo al terminar.')
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

/// Escapa lo que rompería una celda de tabla Markdown: la barra vertical la
/// interpreta como separador de columna y el salto de línea corta la fila.
String _md(String s) =>
    s.replaceAll('|', '\\|').replaceAll('\n', ' ').trim();

// ---------------------------------------------------------------------------
// Reporte de la pestaña "Batería".
//
// Mismo criterio que en pantalla: primero el veredicto, después las cifras y
// por último la explicación. Los textos NO se redactan aquí: vienen del backend
// (verdict y notes) para que digan exactamente lo mismo que la app.
// ---------------------------------------------------------------------------

String buildBateriaReport(BateriaInfo bat, String equipo) {
  final b = StringBuffer();
  void line([String s = '']) => b.writeln(s);

  line('$appName v$appVersion Rev $appRevision');
  line('Estado de la batería · generado: ${_humanStamp()}');
  if (equipo.isNotEmpty) line('Equipo: $equipo');
  if (bat.source.isNotEmpty) line('Fuente: ${bat.source}');
  line('=' * 60);

  final p = bat.principal;
  if (p == null) {
    line();
    line(bat.reason.isNotEmpty
        ? bat.reason
        : 'Este equipo no tiene batería.');
    return b.toString();
  }

  line();
  line('== ¿Cómo está la batería? ==');
  line('  ${p.verdict}');
  if (p.healthPercent >= 0) {
    line('  Salud: ${p.healthPercent} % de la capacidad que tenía nueva '
        '(${p.etiquetaSalud}).');
  }
  if (p.chargePercent >= 0) {
    line('  Ahora mismo: ${p.chargePercent} % de carga · '
        '${BateriaEstado.etiqueta(p.state)}.');
  }

  line();
  line('== Cifras ==');
  line('  Cuando era nueva aguantaba : ${energiaEnPalabras(p.designMWh)}'
      '${p.designMWh > 0 ? " (${p.designMWh} mWh)" : ""}');
  line('  Hoy, cargada al 100 %      : ${energiaEnPalabras(p.fullMWh)}'
      '${p.fullMWh > 0 ? " (${p.fullMWh} mWh)" : ""}');
  if (p.remainingMWh > 0) {
    line('  En este momento            : ${energiaEnPalabras(p.remainingMWh)}');
  }
  line('  Veces que se ha cargado    : '
      '${p.cycleCount > 0 ? "${p.cycleCount}" : "el equipo no lleva esa cuenta"}');

  line();
  line('== Cuánto dura sin enchufar ==');
  line('  (la cuenta del sistema sale del uso habitual; usándolo a tope dura '
      'bastante menos)');
  if (bat.runtimeHeavyMin > 0) {
    line('  Usándolo a tope (vídeo, brillo alto): unos '
        '${duracionEnPalabras(bat.runtimeHeavyMin)}');
  }
  if (bat.runtimeFullMin > 0) {
    line('  En el uso de siempre, al 100 %      : '
        '${duracionEnPalabras(bat.runtimeFullMin)}');
  }
  if (bat.runtimeNowMin > 0) {
    line('  Con la carga que le queda ahora     : '
        '${duracionEnPalabras(bat.runtimeNowMin)}');
  }
  if (bat.wattsTypicalMW > 0) {
    line('  Consumo medido del equipo           : '
        '${vatiosEnPalabras(bat.wattsTypicalMW)} en uso habitual'
        '${bat.wattsHeavyMW > 0 ? ", ${vatiosEnPalabras(bat.wattsHeavyMW)} a tope" : ""}');
  }

  line();
  line('== Para pedir una batería nueva ==');
  line('  Modelo de la batería: '
      '${p.model.isNotEmpty ? p.model : "no lo publica el equipo"}');
  if (p.manufacturer.isNotEmpty) line('  Fabricante          : ${p.manufacturer}');
  if (bat.equipment.isNotEmpty) line('  Para el equipo      : ${bat.equipment}');
  if (p.voltageMV > 0) {
    line('  Voltaje             : ${voltiosEnPalabras(p.voltageMV)}'
        '   (con otro voltaje NO sirve, aunque encaje)');
  }
  line('  Capacidad           : ${energiaEnPalabras(p.designMWh)}'
      '${p.designMAh > 0 ? " · ${p.designMAh} mAh" : ""}');
  final quimicaRepuesto = p.chemistryText.isNotEmpty ? p.chemistryText : p.chemistry;
  if (quimicaRepuesto.isNotEmpty) line('  De qué está hecha   : $quimicaRepuesto');

  if (p.notes.isNotEmpty) {
    line();
    line('== Qué significa todo esto ==');
    for (final n in p.notes) {
      line();
      line('  ${n.title}');
      line('    ${n.detail}');
    }
  }

  line();
  line('== Datos técnicos ==');
  if (p.name.isNotEmpty) line('  Como la llama el equipo: ${p.name}');
  if (p.serial.isNotEmpty) line('  Número de serie        : ${p.serial}');
  if (p.designMWh > 0) line('  Capacidad de fábrica   : ${p.designMWh} mWh');
  if (p.fullMWh > 0) line('  Capacidad actual       : ${p.fullMWh} mWh');
  if (bat.onAcKnown) {
    line('  Corriente              : '
        '${bat.onAc ? "enchufado" : "funcionando con batería"}');
  }

  if (bat.history.length > 1) {
    line();
    line('== Cómo ha ido bajando ==');
    for (final h in bat.history) {
      line('  ${h.period.padRight(26)} ${energiaEnPalabras(h.fullMWh).padLeft(9)}'
          '${h.healthPercent >= 0 ? "   ${h.healthPercent} % de su capacidad de fábrica" : ""}');
    }
  }

  if (bat.reason.isNotEmpty) {
    line();
    line('Aviso: ${bat.reason}');
  }

  line();
  line('=' * 60);
  line('$appCopyright · $appEmail · Licencia $appLicense');
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
  void line([String s = '']) => b.writeln(s);

  line('$appName v$appVersion Rev $appRevision');
  line('Salud de los discos · generado: ${_humanStamp()}');
  if (equipo.isNotEmpty) line('Equipo: $equipo');
  line('=' * 60);

  if (discos.isEmpty) {
    line();
    line('No se encontró ningún disco.');
    return b.toString();
  }

  for (final (i, d) in discos.indexed) {
    line();
    line('-' * 60);
    line('Disco ${i + 1}: ${d.titulo}');
    line('-' * 60);
    line('  ${d.verdict}');
    if (d.lifePercentLeft >= 0) {
      line('  Vida que le queda   : ${d.lifePercentLeft} %');
    }
    line('  Tipo                : ${d.type.isEmpty ? "—" : d.type}'
        '   ·   Capacidad: ${formatDiskCap(d.sizeBytes)}');
    if (d.hasUsage) {
      line('  Espacio usado       : ${formatBytes(d.usedBytes)} de '
          '${formatBytes(d.fsTotalBytes)} (${d.usedPercent.round()} %), '
          'libres ${formatBytes(d.availBytes)}');
    }
    if (d.powerOnHours > 0) {
      line('  Tiempo encendido    : ${formatEntero(d.powerOnHours)} h'
          '${d.powerCycles > 0 ? "   ·   se ha encendido ${formatEntero(d.powerCycles)} veces" : ""}');
    }
    if (d.writtenBytes > 0) {
      line('  Datos escritos      : ${formatBytes(d.writtenBytes)}');
    }
    if (d.smartAvailable) {
      line('  Trozos dañados      : ${d.reallocatedSectors}');
    }
    if (d.serial.isNotEmpty) line('  Número de serie     : ${d.serial}');
    line('  Dispositivo         : ${d.name}');

    if (d.notes.isNotEmpty) {
      line();
      line('  Qué significa todo esto:');
      for (final n in d.notes) {
        line();
        line('    ${n.title}');
        line('      ${n.detail}');
      }
    }
  }

  line();
  line('=' * 60);
  line('$appCopyright · $appEmail · Licencia $appLicense');
  return b.toString();
}
