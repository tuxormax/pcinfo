import 'dart:io';

import '../models/hardware.dart';
import '../version.dart';
import 'format.dart';

/// Genera un .txt con TODO lo que se ve en pantalla (sistema, CPU, placa, RAM,
/// GPU y discos con uso + SMART) y lo guarda en la carpeta del usuario. Devuelve
/// la ruta del archivo escrito.
Future<String> saveReport(HardwareInfo hw) async {
  final text = buildReport(hw);
  final dir = _reportDir();
  final host = _safe(hw.system.hostname.isEmpty ? 'equipo' : hw.system.hostname);
  final path = '$dir${Platform.pathSeparator}PCInfo_${host}_${_fileStamp()}.txt';
  await File(path).writeAsString(text);
  return path;
}

/// Carpeta destino: HOME en Linux, USERPROFILE en Windows; cae al directorio
/// actual si ninguna está definida.
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
      kv('Salud', _healthLabel(d.healthStatus));
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
