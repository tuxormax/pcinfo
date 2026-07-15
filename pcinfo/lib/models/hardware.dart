// Modelos de hardware — espejo del JSON que entregará el backend Go (ghw).
// Mantener los nombres de campo sincronizados con backend/ (contrato de datos).

class HardwareInfo {
  final SystemInfo system;
  final CpuInfo cpu;
  final BoardInfo board;
  final MemoryInfo memory;
  final GpuInfo gpu;
  final List<DiskInfo> disks;

  const HardwareInfo({
    required this.system,
    required this.cpu,
    required this.board,
    required this.memory,
    required this.gpu,
    required this.disks,
  });

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
      );
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

  const DiskInfo({
    required this.name,
    required this.model,
    required this.vendor,
    required this.sizeBytes,
    required this.type,
    required this.serial,
    required this.bus,
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
  });

  factory DiskInfo.fromJson(Map<String, dynamic> j) => DiskInfo(
        name: j['name'] ?? '',
        model: j['model'] ?? '',
        vendor: j['vendor'] ?? '',
        sizeBytes: (j['sizeBytes'] ?? 0) as int,
        type: j['type'] ?? '',
        serial: j['serial'] ?? '',
        bus: j['bus'] ?? '',
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

  const BoardInfo({
    required this.vendor,
    required this.product,
    required this.version,
    required this.biosVendor,
    required this.biosVersion,
    required this.biosDate,
    required this.formFactor,
  });

  factory BoardInfo.fromJson(Map<String, dynamic> j) => BoardInfo(
        vendor: j['vendor'] ?? '',
        product: j['product'] ?? '',
        version: j['version'] ?? '',
        biosVendor: j['biosVendor'] ?? '',
        biosVersion: j['biosVersion'] ?? '',
        biosDate: j['biosDate'] ?? '',
        formFactor: j['formFactor'] ?? '',
      );
}

class MemoryInfo {
  final int totalBytes;
  final int usableBytes;
  final int totalSlots; // ranuras físicas (DMI Tipo 16). 0 = desconocido.
  final int maxCapacityBytes; // capacidad máxima soportada por la placa
  final bool soldered; // true si la RAM está soldada (no ampliable)
  final List<MemModule> modules; // solo ranuras ocupadas

  const MemoryInfo({
    required this.totalBytes,
    required this.usableBytes,
    required this.modules,
    this.totalSlots = 0,
    this.maxCapacityBytes = 0,
    this.soldered = false,
  });

  /// Ranuras libres (si se conoce el total). -1 si se desconoce.
  int get freeSlots => totalSlots > 0 ? totalSlots - modules.length : -1;

  factory MemoryInfo.fromJson(Map<String, dynamic> j) => MemoryInfo(
        totalBytes: (j['totalBytes'] ?? 0) as int,
        usableBytes: (j['usableBytes'] ?? 0) as int,
        totalSlots: (j['totalSlots'] ?? 0) as int,
        maxCapacityBytes: (j['maxCapacityBytes'] ?? 0) as int,
        soldered: j['soldered'] ?? false,
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
