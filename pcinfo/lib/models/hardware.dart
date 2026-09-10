// Modelos de hardware — espejo del JSON que entregará el backend Go (ghw).
// Mantener los nombres de campo sincronizados con backend/ (contrato de datos).

class HardwareInfo {
  final SystemInfo system;
  final CpuInfo cpu;
  final BoardInfo board;
  final MemoryInfo memory;
  final GpuInfo gpu;
  final List<DiskInfo> disks;
  final DiagInfo diag;

  const HardwareInfo({
    required this.system,
    required this.cpu,
    required this.board,
    required this.memory,
    required this.gpu,
    required this.disks,
    this.diag = const DiagInfo(),
  });

  /// Copia con otros discos. La GUI la usa cuando llega la segunda fase del
  /// arranque (los discos ya con S.M.A.R.T.) para reemplazar los provisionales
  /// sin volver a pedir todo el inventario.
  HardwareInfo conDiscos(List<DiskInfo> discos) => HardwareInfo(
        system: system,
        cpu: cpu,
        board: board,
        memory: memory,
        gpu: gpu,
        disks: discos,
        diag: diag,
      );

  factory HardwareInfo.fromJson(Map<String, dynamic> j) => HardwareInfo(
        system: SystemInfo.fromJson(j['system'] ?? const {}),
        cpu: CpuInfo.fromJson(j['cpu'] ?? const {}),
        board: BoardInfo.fromJson(j['board'] ?? const {}),
        memory: MemoryInfo.fromJson(j['memory'] ?? const {}),
        gpu: GpuInfo.fromJson(j['gpu'] ?? const {}),
        disks: (j['disks'] as List?)
                ?.map((e) => DiskInfo.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        diag: DiagInfo.fromJson(j['diag'] ?? const {}),
      );
}

/// Diagnósticos del recolector (espejo de backend/collector DiagInfo). La GUI los
/// usa para explicar por qué un disco salió "SIN SMART" y ofrecer solución: en
/// Windows el SMART requiere que el backend corra ELEVADO y que smartctl.exe esté
/// empaquetado. Con esto se distingue "falta admin" de "falta smartctl" de una
/// limitación real (puente USB / controladora RAID).
class DiagInfo {
  final String os; // "windows" | "linux" | ...
  final bool elevated; // ¿corre como admin/root?
  final bool smartctlFound; // ¿se localizó el ejecutable de smartctl?

  const DiagInfo({
    this.os = '',
    this.elevated = false,
    this.smartctlFound = false,
  });

  factory DiagInfo.fromJson(Map<String, dynamic> j) => DiagInfo(
        os: j['os'] ?? '',
        elevated: j['elevated'] ?? false,
        smartctlFound: j['smartctlFound'] ?? false,
      );

  bool get isWindows => os == 'windows';
}

class SystemInfo {
  final String hostname;
  final String distro; // "Ubuntu 24.04.1 LTS" / "Windows 11 Pro 23H2"
  final String kernel; // "6.8.0-124-generic" / build de Windows
  final String arch; // "x86_64"
  final String desktop; // "GNOME 46 (Wayland)" — vacío en Windows/servidor

  const SystemInfo({
    required this.hostname,
    required this.distro,
    required this.kernel,
    required this.arch,
    this.desktop = '',
  });

  factory SystemInfo.fromJson(Map<String, dynamic> j) => SystemInfo(
        hostname: j['hostname'] ?? '',
        distro: j['distro'] ?? '',
        kernel: j['kernel'] ?? '',
        arch: j['arch'] ?? '',
        desktop: j['desktop'] ?? '',
      );
}

class DiskInfo {
  final String name; // /dev/nvme0n1
  final String model;
  final String vendor;
  final int sizeBytes;
  final String type; // "NVMe SSD", "SATA SSD", "HDD"
  final String serial;
  final String bus; // "nvme", "sata", "usb"

  /// Dónde está enchufado: "SATA 3", "M.2 / PCIe (nvme0n1)", "USB". Vacío si el
  /// sistema no lo dice (en Windows solo se sabe el tipo de conexión).
  final String port;

  // true si el MEDIO es extraíble (memoria USB, tarjeta SD, lector). Esos no
  // reportan S.M.A.R.T. y tardan en contestar que no, así que el backend no se
  // los pregunta salvo que el usuario lo pida a mano. Un SSD/NVMe dentro de un
  // gabinete USB NO es removible: a ese sí se le lee la salud.
  final bool removable;

  // Uso del sistema de archivos (suma de particiones montadas). 0 si el disco
  // no tiene particiones montadas.
  final int usedBytes;
  final int availBytes;

  // S.M.A.R.T. (lo llena smartctl en el backend). smartAvailable=false si el
  // disco no reporta SMART (USB, VM, sin permisos).
  final bool smartAvailable;
  final String health; // "PASSED", "FAILED", "" (desconocido)
  final int writtenBytes; // total escrito por el host
  final int readBytes; // total leído por el host
  final int powerOnHours;
  final int powerCycles;
  final int lifePercentUsed; // SSD: % de vida consumida (-1 si N/A)
  final int reallocatedSectors;

  // Salud derivada de los atributos SMART (no solo del PASSED/FAILED global):
  // "good" | "warning" | "fail" ("" si no hay SMART). issues = problemas
  // detectados con su consecuencia (para el modal al tocar la etiqueta).
  final String healthLevel;
  final List<DiskIssue> issues;

  /// La misma salud EXPLICADA (pestaña "Discos"): una frase que dice qué hacer
  /// y las notas que traducen cada número. Las redacta el backend para que el
  /// texto sea idéntico en pantalla y en el reporte guardado.
  final String verdict;
  final List<DiscoNota> notes;

  const DiskInfo({
    required this.name,
    required this.model,
    required this.vendor,
    required this.sizeBytes,
    required this.type,
    required this.serial,
    required this.bus,
    this.port = '',
    this.removable = false,
    this.usedBytes = 0,
    this.availBytes = 0,
    this.smartAvailable = false,
    this.health = '',
    this.writtenBytes = 0,
    this.readBytes = 0,
    this.powerOnHours = 0,
    this.powerCycles = 0,
    this.lifePercentUsed = -1,
    this.reallocatedSectors = 0,
    this.healthLevel = '',
    this.issues = const [],
    this.verdict = '',
    this.notes = const [],
  });

  factory DiskInfo.fromJson(Map<String, dynamic> j) => DiskInfo(
        name: j['name'] ?? '',
        model: j['model'] ?? '',
        vendor: j['vendor'] ?? '',
        sizeBytes: (j['sizeBytes'] ?? 0) as int,
        type: j['type'] ?? '',
        serial: j['serial'] ?? '',
        bus: j['bus'] ?? '',
        port: j['port'] ?? '',
        removable: j['removable'] ?? false,
        usedBytes: (j['usedBytes'] ?? 0) as int,
        availBytes: (j['availBytes'] ?? 0) as int,
        smartAvailable: j['smartAvailable'] ?? false,
        health: j['health'] ?? '',
        writtenBytes: (j['writtenBytes'] ?? 0) as int,
        readBytes: (j['readBytes'] ?? 0) as int,
        powerOnHours: (j['powerOnHours'] ?? 0) as int,
        powerCycles: (j['powerCycles'] ?? 0) as int,
        lifePercentUsed: (j['lifePercentUsed'] ?? -1) as int,
        reallocatedSectors: (j['reallocatedSectors'] ?? 0) as int,
        healthLevel: j['healthLevel'] ?? '',
        issues: (j['issues'] as List?)
                ?.map((e) => DiskIssue.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        verdict: j['verdict'] ?? '',
        notes: (j['notes'] as List?)
                ?.map((e) => DiscoNota.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  /// Total del sistema de archivos (ocupado + disponible). 0 si no hay
  /// particiones montadas.
  int get fsTotalBytes => usedBytes + availBytes;

  /// true si el disco tiene particiones montadas (hay uso que mostrar).
  bool get hasUsage => fsTotalBytes > 0;

  /// % ocupado respecto al total montado (0 si no aplica).
  double get usedPercent =>
      fsTotalBytes > 0 ? usedBytes / fsTotalBytes * 100 : 0;

  /// % disponible respecto al total montado.
  double get availPercent =>
      fsTotalBytes > 0 ? availBytes / fsTotalBytes * 100 : 0;

  /// Vida útil que le QUEDA a un SSD (%), o -1 si el disco no lo reporta (los
  /// mecánicos nunca lo hacen). El backend guarda la vida consumida.
  int get lifePercentLeft =>
      lifePercentUsed < 0 ? -1 : (100 - lifePercentUsed).clamp(0, 100);

  /// Nombre para la ficha: el modelo, y si no lo hay, el dispositivo.
  String get titulo => model.isNotEmpty ? model : name;

  /// Estado de salud legible: saludable / advertencia / falla / desconocido.
  /// Se prioriza el `healthLevel` que calcula el backend a partir de TODOS los
  /// atributos SMART; si no viene (backend viejo), se cae a la heurística local.
  DiskHealth get healthStatus {
    if (!smartAvailable) return DiskHealth.unknown;
    switch (healthLevel) {
      case 'fail':
        return DiskHealth.fail;
      case 'warning':
        return DiskHealth.warning;
      case 'good':
        return DiskHealth.good;
    }
    // Respaldo (backend sin healthLevel).
    if (health.isEmpty) return DiskHealth.unknown;
    if (health.toUpperCase() != 'PASSED') return DiskHealth.fail;
    if (reallocatedSectors > 0) return DiskHealth.warning;
    if (lifePercentUsed >= 0 && lifePercentUsed >= 80) return DiskHealth.warning;
    return DiskHealth.good;
  }
}

enum DiskHealth { good, warning, fail, unknown }

/// Una explicación del estado del disco en palabras sencillas. Misma forma que
/// las notas de la batería (el backend usa un solo tipo para las dos).
class DiscoNota {
  final String level; // info | warning | fail
  final String title;
  final String detail;

  const DiscoNota({this.level = '', this.title = '', this.detail = ''});

  factory DiscoNota.fromJson(Map<String, dynamic> j) => DiscoNota(
        level: j['level'] ?? '',
        title: j['title'] ?? '',
        detail: j['detail'] ?? '',
      );
}

/// Un problema detectado en el disco: severidad, nombre y qué implica.
class DiskIssue {
  final String severity; // "warning" | "fail"
  final String title;
  final String detail; // qué significa + consecuencia

  const DiskIssue({
    required this.severity,
    required this.title,
    required this.detail,
  });

  factory DiskIssue.fromJson(Map<String, dynamic> j) => DiskIssue(
        severity: j['severity'] ?? 'warning',
        title: j['title'] ?? '',
        detail: j['detail'] ?? '',
      );
}

class CpuInfo {
  final String vendor;
  final String model;
  final int cores;
  final int threads;
  final double baseMhz; // frecuencia base
  final double maxMhz; // frecuencia máxima (turbo/boost)

  const CpuInfo({
    required this.vendor,
    required this.model,
    required this.cores,
    required this.threads,
    required this.baseMhz,
    required this.maxMhz,
  });

  factory CpuInfo.fromJson(Map<String, dynamic> j) => CpuInfo(
        vendor: j['vendor'] ?? '',
        model: j['model'] ?? '',
        cores: (j['cores'] ?? 0) as int,
        threads: (j['threads'] ?? 0) as int,
        baseMhz: ((j['baseMhz'] ?? 0) as num).toDouble(),
        maxMhz: ((j['maxMhz'] ?? 0) as num).toDouble(),
      );
}

class BoardInfo {
  final String vendor;
  final String product;
  final String version;
  final String biosVendor;
  final String biosVersion;
  final String biosDate;
  final String formFactor; // tamaño: "ATX", "Micro-ATX", "Mini-ITX", etc.

  /// Ranuras de expansión de la placa (PCIe, M.2), con si están libres.
  final List<ExpansionSlot> slots;

  /// Puertos SATA que ve el sistema. OJO: son los que presenta la CONTROLADORA,
  /// no los conectores de la placa (un chipset puede exponer 12 y la placa
  /// cablear 6). Para la cuenta real está [sataDeclared].
  final List<SataPort> sataPorts;

  /// Conectores SATA que trae la placa según el catálogo verificado. 0 = placa
  /// no catalogada todavía.
  final int sataDeclared;

  /// Conectores SATA con un disco puesto ahora mismo.
  final int sataUsed;

  /// De dónde salieron ranuras y puertos: "catalogo" (hoja de datos),
  /// "firmware" (SMBIOS, miente en algunas placas) o "" (no se pudo leer).
  final String portsSource;

  /// Advertencia de la hoja de datos sobre carriles compartidos ("al usar el
  /// M.2 se apagan los SATA 5 y 6"). Vacía si no aplica o no está catalogada.
  final String portsNote;

  const BoardInfo({
    required this.vendor,
    required this.product,
    required this.version,
    required this.biosVendor,
    required this.biosVersion,
    required this.biosDate,
    required this.formFactor,
    this.slots = const [],
    this.sataPorts = const [],
    this.sataDeclared = 0,
    this.sataUsed = 0,
    this.portsSource = '',
    this.portsNote = '',
  });

  factory BoardInfo.fromJson(Map<String, dynamic> j) => BoardInfo(
        vendor: j['vendor'] ?? '',
        product: j['product'] ?? '',
        version: j['version'] ?? '',
        biosVendor: j['biosVendor'] ?? '',
        biosVersion: j['biosVersion'] ?? '',
        biosDate: j['biosDate'] ?? '',
        formFactor: j['formFactor'] ?? '',
        slots: (j['slots'] as List?)
                ?.map((e) => ExpansionSlot.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        sataPorts: (j['sataPorts'] as List?)
                ?.map((e) => SataPort.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        sataDeclared: (j['sataDeclared'] ?? 0) as int,
        sataUsed: (j['sataUsed'] ?? 0) as int,
        portsSource: j['portsSource'] ?? '',
        portsNote: j['portsNote'] ?? '',
      );

  /// Conectores SATA a mostrar: los de la placa si está catalogada; si no, los
  /// que ve el sistema (que pueden ser más que los cableados).
  int get sataTotal => sataDeclared > 0 ? sataDeclared : sataPorts.length;

  /// Conectores SATA libres. -1 si no se conoce el total.
  int get sataFree => sataTotal > 0 ? (sataTotal - sataUsed).clamp(0, 99) : -1;

  /// true si la cuenta de conectores SATA sale del catálogo verificado (dato de
  /// fábrica) y no de lo que presenta el chipset.
  bool get sataVerificado => sataDeclared > 0;

  /// Ranuras M.2 para SSD (las de WiFi no cuentan: llevan otra llave y no
  /// admiten un disco).
  List<ExpansionSlot> get m2Slots =>
      slots.where((s) => s.kind == 'm2').toList();

  /// Ranuras PCIe (para gráfica, controladora, red…).
  List<ExpansionSlot> get pcieSlots =>
      slots.where((s) => s.kind == 'pcie').toList();

  /// true si hay algo que enseñar en la ficha de ranuras y puertos.
  bool get tieneExpansion => slots.isNotEmpty || sataTotal > 0;
}

/// Una ranura de expansión de la placa: PCIe (gráfica, controladora, red) o M.2
/// (SSD NVMe o SATA).
class ExpansionSlot {
  final String label; // serigrafía: "PCIEX16_1", "M.2_1"
  final String kind; // "pcie" | "m2" | "m2wifi" | "pci" | "otra"
  final String spec; // "PCIe 3.0 x16", "M.2 llave M (PCIe x4 / NVMe)"

  /// "ocupada" | "libre" | "" (no se pudo saber). El vacío se muestra como
  /// "sin dato", nunca como libre: mandar a alguien con una tarjeta a una
  /// ranura que quizá esté ocupada es peor que no decir nada.
  final String state;
  final String usedBy; // qué la ocupa, si se averiguó
  final String source; // "catalogo" | "firmware"

  const ExpansionSlot({
    this.label = '',
    this.kind = '',
    this.spec = '',
    this.state = '',
    this.usedBy = '',
    this.source = '',
  });

  factory ExpansionSlot.fromJson(Map<String, dynamic> j) => ExpansionSlot(
        label: j['label'] ?? '',
        kind: j['kind'] ?? '',
        spec: j['spec'] ?? '',
        state: j['state'] ?? '',
        usedBy: j['usedBy'] ?? '',
        source: j['source'] ?? '',
      );

  bool get ocupada => state == 'ocupada';
  bool get libre => state == 'libre';

  /// Texto del estado para la ficha y el reporte.
  String get estadoTexto {
    if (ocupada) return usedBy.isNotEmpty ? 'Ocupada — $usedBy' : 'Ocupada';
    if (libre) return 'Libre';
    return 'Sin dato';
  }
}

/// Un conector SATA y qué disco cuelga de él.
class SataPort {
  final String label; // "SATA 3" (orden del sistema, no serigrafía)
  final bool used;
  final String usedBy;

  const SataPort({this.label = '', this.used = false, this.usedBy = ''});

  factory SataPort.fromJson(Map<String, dynamic> j) => SataPort(
        label: j['label'] ?? '',
        used: j['used'] ?? false,
        usedBy: j['usedBy'] ?? '',
      );
}

class MemoryInfo {
  final int totalBytes;
  final int usableBytes;
  final int totalSlots; // ranuras físicas (DMI Tipo 16). 0 = desconocido.
  final int maxCapacityBytes; // capacidad máxima soportada por la placa
  final bool soldered; // true si la RAM está soldada (no ampliable)
  final bool slotsVerified; // true = ranuras/máx del catálogo verificado; false = del firmware (puede mentir)
  final List<MemModule> modules; // solo ranuras ocupadas

  const MemoryInfo({
    required this.totalBytes,
    required this.usableBytes,
    required this.modules,
    this.totalSlots = 0,
    this.maxCapacityBytes = 0,
    this.soldered = false,
    this.slotsVerified = false,
  });

  /// Ranuras libres (si se conoce el total). -1 si se desconoce.
  int get freeSlots => totalSlots > 0 ? totalSlots - modules.length : -1;

  factory MemoryInfo.fromJson(Map<String, dynamic> j) => MemoryInfo(
        totalBytes: (j['totalBytes'] ?? 0) as int,
        usableBytes: (j['usableBytes'] ?? 0) as int,
        totalSlots: (j['totalSlots'] ?? 0) as int,
        maxCapacityBytes: (j['maxCapacityBytes'] ?? 0) as int,
        soldered: j['soldered'] ?? false,
        slotsVerified: j['slotsVerified'] ?? false,
        modules: (j['modules'] as List?)
                ?.map((e) => MemModule.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

class MemModule {
  final String label; // "DIMM 0"
  final String location; // "P0 CHANNEL A"
  final String vendor;
  final int sizeBytes;
  final String type; // "DDR4"
  final int speedMhz;
  final String formFactor; // "DIMM", "SODIMM", "Row Of Chips" (soldada)

  const MemModule({
    required this.label,
    required this.location,
    required this.vendor,
    required this.sizeBytes,
    required this.type,
    required this.speedMhz,
    this.formFactor = '',
  });

  factory MemModule.fromJson(Map<String, dynamic> j) => MemModule(
        label: j['label'] ?? '',
        location: j['location'] ?? '',
        vendor: j['vendor'] ?? '',
        sizeBytes: (j['sizeBytes'] ?? 0) as int,
        type: j['type'] ?? '',
        speedMhz: (j['speedMhz'] ?? 0) as int,
        formFactor: j['formFactor'] ?? '',
      );
}

class GpuInfo {
  final List<GpuCard> cards;
  const GpuInfo({required this.cards});

  factory GpuInfo.fromJson(Map<String, dynamic> j) => GpuInfo(
        cards: (j['cards'] as List?)
                ?.map((e) => GpuCard.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

class GpuCard {
  final String vendor;
  final String product;
  final String driver;
  final int memoryBytes; // VRAM si disponible

  const GpuCard({
    required this.vendor,
    required this.product,
    required this.driver,
    required this.memoryBytes,
  });

  factory GpuCard.fromJson(Map<String, dynamic> j) => GpuCard(
        vendor: j['vendor'] ?? '',
        product: j['product'] ?? '',
        driver: j['driver'] ?? '',
        memoryBytes: (j['memoryBytes'] ?? 0) as int,
      );
}
