import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/controladores.dart';
import 'package:pcinfo/services/controladores_service.dart';
import 'package:pcinfo/ui/controladores_page.dart';
import 'package:pcinfo/utils/report.dart';

/// Respuesta del backend en un portátil con dos avisos: el DPTF quitado a
/// propósito (caso conocido del catálogo) y un aparato que nadie reconoce.
const _json = '''
{
  "os": "windows", "supported": true, "elevated": false, "available": true,
  "reason": "", "drivers": [], "wifi": [],
  "pendientes": [
    {
      "nombre": "Intel(R) Dynamic Platform and Thermal Framework Manager",
      "clase": "", "instanceId": "ACPI\\\\INT3400\\\\2&DABA3FF&1",
      "hardwareId": "ACPI\\\\INT3400", "codigo": 28,
      "estado": "No tiene controlador instalado.",
      "conocido": {
        "id": "dptf", "nombre": "Intel DPTF / Dynamic Tuning",
        "descripcion": "Reparte el calor y la energía entre el procesador y la gráfica.",
        "via": "quitar",
        "motivo": "Se quita a propósito: con él el equipo se congela al conectar el cargador.",
        "fuente": "windows/arreglador, catálogo \$CATALOGO, entrada «dptf»"
      }
    },
    {
      "nombre": "Dispositivo desconocido", "clase": "",
      "instanceId": "PCI\\\\VEN_1AF4&DEV_1000", "hardwareId": "PCI\\\\VEN_1AF4",
      "codigo": 28, "estado": "No tiene controlador instalado."
    }
  ]
}
''';

ControladoresInfo get _ctl =>
    ControladoresInfo.fromJson(jsonDecode(_json) as Map<String, dynamic>);

class _ServicioMudo implements ControladoresService {
  @override
  Future<ControladoresInfo> load() async => _ctl;
  @override
  Future<TareaInfo> inicia({
    required String kind,
    required String carpeta,
    required bool drivers,
    required bool wifi,
  }) async =>
      const TareaInfo();
  @override
  Future<TareaInfo> tarea() async => const TareaInfo();
  @override
  Future<void> cancela() async {}
}

Future<void> _pinta(WidgetTester tester, ControladoresInfo d) async {
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ControladoresPage(data: d, service: _ServicioMudo()),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('el dispositivo sin controlador viene con su explicación',
      (tester) async {
    await _pinta(tester, _ctl);

    expect(find.text('Dispositivos sin controlador'), findsOneWidget);
    expect(
      find.text('Está así a propósito — Intel DPTF / Dynamic Tuning'),
      findsOneWidget,
    );
    expect(
      find.textContaining('se congela al conectar el cargador'),
      findsOneWidget,
    );
  });

  // El aviso existe justamente para que el usuario NO crea que algo se rompió.
  // Si la tarjeta apareciera con botones, parecería que hay algo que instalar.
  testWidgets('la tarjeta no ofrece ninguna acción', (tester) async {
    await _pinta(tester, _ctl);
    expect(find.text('Respaldar controladores'), findsOneWidget);
    expect(find.textContaining('Instalar'), findsNothing);
    expect(find.textContaining('Reparar'), findsNothing);
  });

  // Sin administrador el resto de la pestaña se queda vacío; esta parte no,
  // porque leer los dispositivos no necesita permisos.
  testWidgets('sale aunque no haya administrador', (tester) async {
    await _pinta(tester, _ctl);
    expect(_ctl.elevated, isFalse);
    expect(find.textContaining('Intel(R) Dynamic Platform'), findsOneWidget);
  });

  testWidgets('sin avisos lo dice, en vez de dejar un hueco', (tester) async {
    await _pinta(
      tester,
      const ControladoresInfo(
          os: 'windows', supported: true, available: true, elevated: true),
    );
    expect(
      find.text('Ningún dispositivo del equipo está sin controlador'),
      findsOneWidget,
    );
  });

  test('el .md separa los casos conocidos del resto', () {
    final md = buildControladoresMarkdown(_ctl, 'EQUIPO-TALLER');

    expect(md, contains('## Dispositivos sin controlador (2)'));
    expect(md, contains('Dispositivo desconocido'));
    expect(md, contains('### De estos, 1 son casos conocidos'));
    expect(md, contains('Está así a propósito'));
    // El motivo sin su fuente no se publica: es lo que permite auditar el dato
    // años después, igual que en el catálogo de placas.
    expect(md, contains('windows/arreglador'));
  });

  test('en Linux la sección no aparece', () {
    final md = buildControladoresMarkdown(
      const ControladoresInfo(os: 'linux', supported: false),
      'equipo',
    );
    expect(md, isNot(contains('Dispositivos sin controlador')));
  });
}
