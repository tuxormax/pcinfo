import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/hardware.dart';
import 'package:pcinfo/utils/report.dart';

/// El reporte de hardware es lo que se manda por chat cuando alguien pregunta
/// "¿le cabe otro disco?". Lo que se prueba es que conteste eso: cuántos
/// conectores SATA quedan libres, si hay una M.2 y si un PCIe está ocupado — y
/// que NO diga "libre" cuando en realidad no se pudo leer el dato.
HardwareInfo _equipo(BoardInfo board, {List<DiskInfo> discos = const []}) =>
    HardwareInfo(
      system: const SystemInfo(
          hostname: 'ambio-server', distro: 'Linux Mint 21.3', kernel: '5.15', arch: 'x86_64'),
      cpu: const CpuInfo(
          vendor: 'AMD', model: 'Ryzen 5 3400G', cores: 4, threads: 8, baseMhz: 1400, maxMhz: 3900),
      board: board,
      memory: const MemoryInfo(totalBytes: 0, usableBytes: 0, modules: []),
      gpu: const GpuInfo(cards: []),
      disks: discos,
    );

const _placa = BoardInfo(
  vendor: 'ASUSTeK COMPUTER INC.',
  product: 'PRIME B450M-A',
  version: 'Rev X.0x',
  biosVendor: 'AMI',
  biosVersion: '1201',
  biosDate: '25/04/2019',
  formFactor: 'Desktop',
  sataDeclared: 6,
  sataUsed: 2,
  portsSource: 'catalogo',
  portsNote: 'Al usar la ranura M.2_1 se apagan los puertos SATA 5 y 6.',
  slots: [
    ExpansionSlot(
        label: 'PCIEX16_1', kind: 'pcie', spec: 'PCIe 3.0 x16', state: 'libre', source: 'catalogo'),
    ExpansionSlot(
        label: 'M.2_1',
        kind: 'm2',
        spec: 'llave M, PCIe 3.0 x4, SATA',
        state: 'ocupada',
        usedBy: '/dev/nvme0n1 — WD SN570',
        source: 'catalogo'),
    ExpansionSlot(label: 'PCIEX1_1', kind: 'pcie', spec: 'PCIe 2.0 x1', source: 'catalogo'),
  ],
  sataPorts: [
    SataPort(label: 'SATA 4', used: true, usedBy: '/dev/sda — KINGSTON SA400S37240G'),
    SataPort(label: 'SATA 5', used: true, usedBy: '/dev/sdb — WDC WD2000F9YZ'),
    SataPort(label: 'SATA 6'),
  ],
);

void main() {
  test('el reporte dice cuántos sitios quedan libres', () {
    final md = buildReport(_equipo(_placa));

    expect(md, contains('## Ranuras y puertos'));
    expect(md, contains('6 conectores'));
    expect(md, contains('| SATA con disco | 2 |'));
    expect(md, contains('| SATA libres | 4 |'));
    expect(md, contains('Ranuras M.2'));
    // Con una M.2 ocupada y una PCIe libre de tres, el resumen los cuenta.
    expect(md, contains('| Ranuras PCIe | 2 (1 libre) |'));
    // La ranura ocupada dice QUÉ la ocupa, que es lo que evita abrir el equipo.
    expect(md, contains('/dev/nvme0n1 — WD SN570'));
    // Y el detalle de qué disco está en qué conector.
    expect(md, contains('| SATA 4 | /dev/sda — KINGSTON SA400S37240G |'));
  });

  test('una ranura sin dato NO se reporta como libre', () {
    final md = buildReport(_equipo(_placa));
    expect(md, contains('Sin dato'));
    // La PCIEX1_1 no tiene estado: no puede aparecer como libre.
    final linea = md
        .split('\n')
        .firstWhere((l) => l.startsWith('| PCIEX1_1'), orElse: () => '');
    expect(linea, isNot(contains('Libre')));
    expect(linea, contains('Sin dato'));
  });

  test('la advertencia de la hoja de datos sale en el reporte', () {
    final md = buildReport(_equipo(_placa));
    expect(md, contains('se apagan los puertos SATA 5 y 6'));
  });

  test('placa no catalogada: avisa de que los puertos son del firmware', () {
    const board = BoardInfo(
      vendor: 'Marca',
      product: 'XYZ',
      version: '',
      biosVendor: 'AMI',
      biosVersion: '1',
      biosDate: '',
      formFactor: '',
      portsSource: 'firmware',
      sataPorts: [SataPort(label: 'SATA 1', used: true, usedBy: '/dev/sda')],
      sataUsed: 1,
    );
    final md = buildReport(_equipo(board));
    expect(md, contains('puertos (los que presenta el chipset)'));
    expect(md, contains('no verificado en el catálogo'));
  });

  test('sin ningún dato de expansión lo dice, no inventa una tabla vacía', () {
    const board = BoardInfo(
      vendor: 'Marca',
      product: 'XYZ',
      version: '',
      biosVendor: '',
      biosVersion: '',
      biosDate: '',
      formFactor: '',
    );
    final md = buildReport(_equipo(board));
    expect(md, contains('no declara sus ranuras'));
  });

  test('si no se sabe qué ranuras están ocupadas, no dice "0 libres"', () {
    const board = BoardInfo(
      vendor: 'ASUSTeK COMPUTER INC.',
      product: 'PRIME B450M-A',
      version: '',
      biosVendor: '',
      biosVersion: '',
      biosDate: '',
      formFactor: '',
      sataDeclared: 6,
      sataUsed: 2,
      portsSource: 'catalogo',
      // Del catálogo salen las ranuras, pero sin firmware nadie sabe si están
      // ocupadas: decir "0 libres" se leería como "no cabe nada más".
      slots: [ExpansionSlot(label: 'M.2_1', kind: 'm2', spec: 'llave M', source: 'catalogo')],
    );
    final md = buildReport(_equipo(board));
    expect(md, contains('sin dato de ocupación'));
    expect(md, isNot(contains('| Ranuras M.2 | 1 (0 libres) |')));
  });

  test('cada disco dice en qué puerto está enchufado', () {
    final md = buildReport(_equipo(_placa, discos: [
      const DiskInfo(
        name: '/dev/sda',
        model: 'KINGSTON SA400S37240G',
        vendor: 'Kingston',
        sizeBytes: 240057409536,
        type: 'SATA SSD',
        serial: '50026B7782D43C72',
        bus: 'sata',
        port: 'SATA 4',
      ),
    ]));
    expect(md, contains('| Conectado en | SATA 4 |'));
  });
}
