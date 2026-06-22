import '../models/hardware.dart';

/// Fuente de datos de hardware.
/// Hoy: MockHardwareService (datos de ejemplo para construir la GUI).
/// Después: HttpHardwareService que consume el backend Go en localhost.
abstract class HardwareService {
  Future<HardwareInfo> load();
}

class MockHardwareService implements HardwareService {
  @override
  Future<HardwareInfo> load() async {
    // Simula la latencia de leer el hardware.
    await Future.delayed(const Duration(milliseconds: 450));
    return const HardwareInfo(
      system: SystemInfo(
        hostname: 'tuxor-pc',
        distro: 'Ubuntu 24.04.1 LTS',
        kernel: '6.8.0-124-generic',
        arch: 'x86_64',
        desktop: 'GNOME 46 (Wayland)',
      ),
      cpu: CpuInfo(
        vendor: 'AuthenticAMD',
        model: 'AMD Ryzen 7 5800X 8-Core Processor',
        cores: 8,
        threads: 16,
        baseMhz: 3800,
        maxMhz: 4700,
      ),
      board: BoardInfo(
        vendor: 'ASUSTeK COMPUTER INC.',
        product: 'TUF GAMING B550-PLUS',
        version: 'Rev X.0x',
        biosVendor: 'American Megatrends',
        biosVersion: '2803',
        biosDate: '2023-03-15',
        formFactor: 'ATX',
      ),
      memory: MemoryInfo(
        totalBytes: 34359738368, // 32 GiB
        usableBytes: 34091302912,
        totalSlots: 4,
        maxCapacityBytes: 137438953472, // 128 GiB
        soldered: false,
        modules: [
          MemModule(
            label: 'DIMM 0',
            location: 'DIMM_A2',
            vendor: 'Corsair',
            sizeBytes: 17179869184,
            type: 'DDR4',
            speedMhz: 3600,
            formFactor: 'DIMM',
          ),
          MemModule(
            label: 'DIMM 1',
            location: 'DIMM_B2',
            vendor: 'Corsair',
            sizeBytes: 17179869184,
            type: 'DDR4',
            speedMhz: 3600,
            formFactor: 'DIMM',
          ),
        ],
      ),
      gpu: GpuInfo(
        cards: [
          GpuCard(
            vendor: 'NVIDIA Corporation',
            product: 'GeForce RTX 3070 (GA104)',
            driver: 'nvidia 550.120',
            memoryBytes: 8589934592, // 8 GiB
          ),
        ],
      ),
      disks: [
        DiskInfo(
          name: '/dev/nvme0n1',
          model: 'Samsung SSD 980 PRO 1TB',
          vendor: 'Samsung',
          sizeBytes: 1000204886016,
          type: 'NVMe SSD',
          serial: 'S5GXNX0R123456',
          bus: 'nvme',
          smartAvailable: true,
          health: 'PASSED',
          writtenBytes: 48922361036800, // ~44.5 TiB escritos
          readBytes: 71300357488640, // ~64.8 TiB leídos
          powerOnHours: 4210,
          powerCycles: 318,
          lifePercentUsed: 6, // 6% de vida consumida
          reallocatedSectors: 0,
        ),
        DiskInfo(
          name: '/dev/sda',
          model: 'WDC WD20EZBX-00AYRA0',
          vendor: 'Western Digital',
          sizeBytes: 2000398934016,
          type: 'HDD',
          serial: 'WD-WCC4M1234567',
          bus: 'sata',
          smartAvailable: true,
          health: 'PASSED',
          writtenBytes: 0, // los HDD ATA no reportan total escrito por host
          readBytes: 0,
          powerOnHours: 28640,
          powerCycles: 1422,
          lifePercentUsed: -1, // N/A en HDD
          reallocatedSectors: 12, // sectores reasignados → advertencia
        ),
      ],
    );
  }
}
