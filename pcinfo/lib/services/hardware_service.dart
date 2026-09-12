import '../models/hardware.dart';
import '../models/incidencias.dart';
import 'backend_http.dart';

/// Fuente de datos de hardware.
/// MockHardwareService: datos de ejemplo. HttpHardwareService: backend Go real.
abstract class HardwareService {
  /// Primera fase: todo el inventario MENOS la salud de los discos. Es lo que
  /// se pinta al abrir la app.
  Future<HardwareInfo> load();

  /// Segunda fase: los discos ya con S.M.A.R.T. Se pide en segundo plano
  /// porque es lo único lento del inventario (un disco que no contesta —lector
  /// de tarjetas, gabinete USB— se lleva segundos por cada tipo de conexión que
  /// se prueba) y antes hacía que la app se pasara de los 30 s de espera.
  /// [forzar] = nombre de dispositivo de un disco al que hay que leerle la
  /// salud aunque se haya clasificado como memoria extraíble (lo pide el botón
  /// "Leer salud igual" cuando un gabinete externo se declara removible).
  Future<List<DiskInfo>> loadDiscos({String forzar = ''});

  /// Tercera fase, solo cuando el usuario abre la pestaña Discos: lo que le ha
  /// PASADO a cada disco según el registro del sistema (errores de lectura y
  /// escritura, desconexiones, reparaciones del sistema de archivos).
  ///
  /// Va aparte porque consultar el registro cuesta segundos —unos 6 s por 24 h
  /// en un Apple Silicon— y porque contesta otra pregunta: el S.M.A.R.T. es lo
  /// que el disco opina de sí mismo; esto es lo que el sistema vio fallar. En un
  /// disco USB de macOS, además, es la ÚNICA fuente de salud que existe.
  Future<IncidenciasDiscos> loadIncidencias({int horas = 24});
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

  /// Endpoint de la segunda fase (los discos con S.M.A.R.T.).
  Uri get _endpointDiscos => endpoint.replace(path: '/discos');

  /// Endpoint del historial de incidencias de disco.
  Uri get _endpointIncidencias => endpoint.replace(path: '/discos/incidencias');

  @override
  Future<HardwareInfo> load() async {
    try {
      // ?smart=0 → el backend responde sin consultar los discos, que es lo
      // único lento; la salud llega después por loadDiscos(). Margen amplio de
      // todos modos: el primer arranque en frío del colector (WMI) tarda unos
      // segundos en algunas máquinas.
      final json = await pideJson(
        endpoint.replace(queryParameters: const {'smart': '0'}),
        espera: const Duration(seconds: 30),
        que: 'al leer el hardware',
      );
      return HardwareInfo.fromJson(json);
    } catch (e) {
      if (fallback != null) return fallback!.load();
      rethrow;
    }
  }

  @override
  Future<List<DiskInfo>> loadDiscos({String forzar = ''}) async {
    try {
      // Espera larga a propósito: aquí ya no hay nadie mirando una pantalla en
      // blanco —el resto del hardware está pintado— y el backend acota por su
      // cuenta cuánto sondea los discos que no contestan.
      final json = await pideJson(
        forzar.isEmpty
            ? _endpointDiscos
            : _endpointDiscos.replace(queryParameters: {'forzar': forzar}),
        espera: const Duration(seconds: 120),
        que: 'al leer la salud de los discos',
      );
      return (json['discos'] as List?)
              ?.map((e) => DiskInfo.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [];
    } catch (e) {
      if (fallback != null) return fallback!.loadDiscos(forzar: forzar);
      rethrow;
    }
  }

  @override
  Future<IncidenciasDiscos> loadIncidencias({int horas = 24}) async {
    try {
      final json = await pideJson(
        _endpointIncidencias
            .replace(queryParameters: {'horas': '\$horas'}),
        espera: const Duration(seconds: 90),
        que: 'al leer el historial de incidencias de los discos',
      );
      return IncidenciasDiscos.fromJson(json);
    } catch (e) {
      if (fallback != null) return fallback!.loadIncidencias(horas: horas);
      rethrow;
    }
  }
}

class MockHardwareService implements HardwareService {
  @override
  Future<List<DiskInfo>> loadDiscos({String forzar = ''}) async =>
      (await load()).disks;

  @override
  Future<IncidenciasDiscos> loadIncidencias({int horas = 24}) async =>
      const IncidenciasDiscos(
        disponible: true,
        fuente: 'datos de ejemplo',
        horas: 24,
        discos: [],
      );

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
