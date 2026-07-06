import 'dart:convert';
import 'dart:io';

import '../models/hardware.dart';

/// Fuente de datos de hardware.
/// MockHardwareService: datos de ejemplo. HttpHardwareService: backend Go real.
abstract class HardwareService {
  Future<HardwareInfo> load();
}

/// Consume el backend Go (GET /hardware en localhost). Si no responde y se
/// definió [fallback], usa esos datos (p. ej. el mock) en vez de fallar.
class HttpHardwareService implements HardwareService {
  final Uri endpoint;
  final HardwareService? fallback;

  HttpHardwareService({
    String url = 'http://127.0.0.1:51247/hardware',
    this.fallback,
  }) : endpoint = Uri.parse(url);

  @override
  Future<HardwareInfo> load() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(endpoint);
      // Margen amplio: el primer arranque en frío del colector (WMI + smartctl
      // por disco) puede tardar varios segundos en algunas máquinas.
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: endpoint);
      }
      final body = await resp.transform(utf8.decoder).join();
      return HardwareInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (e) {
      if (fallback != null) return fallback!.load();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
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
          usedBytes: 442000000000, // ~442 GB ocupados
          availBytes: 558000000000, // ~558 GB disponibles
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
          usedBytes: 1480000000000, // ~1.48 TB ocupados
          availBytes: 520000000000, // ~520 GB disponibles
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
