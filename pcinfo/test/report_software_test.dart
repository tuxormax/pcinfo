import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/controladores.dart';
import 'package:pcinfo/models/software.dart';
import 'package:pcinfo/utils/report.dart';

/// El .md de software es lo que se pega en un informe o un ticket, así que lo
/// que se prueba es justo eso: que agrupe por quién instaló cada programa y que
/// una tabla no se rompa por un carácter del nombre.
void main() {
  const sw = SoftwareInfo(
    os: 'windows',
    source: 'Registro de Windows',
    available: true,
    items: [
      SoftwareItem(
        name: 'Google Earth Pro',
        version: '7.3.6.9345',
        publisher: 'Google LLC',
        installed: '2026-04-02',
        sizeMB: 512,
        kind: SoftwareKind.programa,
        origin: SoftwareOrigen.usuario,
      ),
      SoftwareItem(
        name: 'WhatsApp',
        version: '2.2536.4.0',
        kind: SoftwareKind.tienda,
        origin: SoftwareOrigen.usuario,
      ),
      SoftwareItem(
        name: 'Microsoft Visual C++ 2015-2022 Redistributable',
        version: '14.40.33810',
        kind: SoftwareKind.componente,
        system: true,
        origin: SoftwareOrigen.sistema,
      ),
    ],
  );

  test('agrupa por quién instaló cada programa', () {
    final md = buildSoftwareMarkdown(sw, 'TALLER1');

    expect(md, contains('# Software instalado — TALLER1'));
    expect(md, contains('## Instalado por el usuario (2)'));
    expect(md, contains('## Viene con Windows (1)'));
    // Dentro de cada grupo se separa por tipo: un antivirus no debe salir en la
    // misma tabla que un parche.
    expect(md, contains('### Programas (1)'));
    expect(md, contains('### Apps de la Tienda (1)'));
    expect(md, contains('### Componentes y runtimes (1)'));
    // El programa y su versión, que es lo que se va a buscar en el reporte.
    expect(md, contains('| Google Earth Pro | 7.3.6.9345 | Google LLC | 2026-04-02 | 512 MB |'));
    // Sin versión declarada se pone un guion, no un hueco que descuadre la fila.
    expect(md, contains('| WhatsApp | 2.2536.4.0 |'));
  });

  test('en Linux el grupo no se llama "instalado por el usuario"', () {
    // apt-mark solo distingue lo pedido a mano de las dependencias: decir
    // "instalado por el usuario" ahí sería mentir sobre lo que se sabe.
    const linux = SoftwareInfo(os: 'linux');
    expect(linux.tituloUsuario, 'Instalado a petición');
    expect(linux.tituloSistema, 'Dependencias y base del sistema');
  });

  test('un nombre con barra vertical no rompe la tabla', () {
    const raro = SoftwareInfo(
      os: 'windows',
      items: [
        SoftwareItem(
          name: 'Editor | Pro',
          version: '1.0',
          kind: SoftwareKind.programa,
          origin: SoftwareOrigen.usuario,
        ),
      ],
    );
    final md = buildSoftwareMarkdown(raro, '');
    expect(md, contains(r'| Editor \| Pro | 1.0 |'));
  });

  test('el reporte de redes WiFi avisa de que lleva las contraseñas', () {
    const ctl = ControladoresInfo(
      os: 'windows',
      supported: true,
      elevated: true,
      available: true,
      wifi: [WifiProfile(name: 'INFINITUM', auth: 'WPA2PSK', password: 'secreta')],
    );
    final md = buildControladoresMarkdown(ctl, 'TALLER1');
    expect(md, contains('contraseñas de las redes en texto legible'));
    expect(md, contains('| INFINITUM | WPA2PSK | secreta |'));
  });
}
