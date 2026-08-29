import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/hardware.dart';
import 'package:pcinfo/ui/discos_page.dart';
import 'package:pcinfo/utils/report.dart';

/// Dos discos reales: el SSD sano del portátil del reporte y un disco mecánico
/// viejo con sectores reasignados. Es la respuesta del backend tal cual.
const _json = '''
{"discos":[
 {"name":"\\\\\\\\.\\\\PHYSICALDRIVE0","model":"Micron MTFDKBA256TFK","vendor":"","type":"SATA SSD",
  "serial":"00A0_7501_35A0_E2CB.","bus":"SATA","sizeBytes":256060514304,
  "usedBytes":31400000000,"availBytes":223900000000,"smartAvailable":true,
  "health":"SALUDABLE","healthLevel":"good","lifePercentUsed":16,
  "powerOnHours":11559,"powerCycles":90917,"reallocatedSectors":0,
  "writtenBytes":39035000000000,"readBytes":52800000000000,"issues":[],
  "verdict":"El disco está sano.",
  "notes":[{"level":"info","title":"Cuánta vida le queda","detail":"Le queda el 84 %."}]},
 {"name":"\\\\\\\\.\\\\PHYSICALDRIVE1","model":"WDC WD10EZEX-75WN4A0","vendor":"","type":"HDD",
  "serial":"WD-WCC6Y0HKZ1TP","bus":"SATA","sizeBytes":1000204886016,
  "usedBytes":820000000000,"availBytes":180204886016,"smartAvailable":true,
  "health":"PELIGRO","healthLevel":"warning","lifePercentUsed":-1,
  "powerOnHours":46320,"powerCycles":3120,"reallocatedSectors":18,
  "writtenBytes":0,"readBytes":0,
  "issues":[{"severity":"warning","title":"Sectores reasignados","detail":"Desgaste en marcha."}],
  "verdict":"Este disco da señales de desgaste.",
  "notes":[{"level":"warning","title":"Trozos dañados del disco","detail":"Ha apartado 18."}]}
]}
''';

List<DiskInfo> get _discos => ((jsonDecode(_json) as Map<String, dynamic>)['discos'] as List)
    .map((e) => DiskInfo.fromJson(e as Map<String, dynamic>))
    .toList();

void main() {
  testWidgets('la pestaña no desborda en una ventana normal', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DiscosPage(discos: _discos))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tampoco en una ventana estrecha', (tester) async {
    tester.view.physicalSize = const Size(820, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DiscosPage(discos: _discos))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('un disco mecánico no enseña porcentaje de vida inventado',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DiscosPage(discos: [_discos[1]]))));
    await tester.pumpAndSettle();
    expect(find.text('% de vida'), findsNothing);
    expect(find.text('CON DESGASTE'), findsOneWidget);
  });

  test('el reporte de discos lleva el veredicto y las explicaciones', () {
    final texto = buildDiscosReport(_discos, 'DESKTOP-0QAGG5O');
    expect(texto, contains('El disco está sano.'));
    expect(texto, contains('Este disco da señales de desgaste.'));
    expect(texto, contains('| Vida que le queda | 84 % |'));
    expect(texto, contains('11.559 h'));
    // El disco mecánico no reporta vida: no debe aparecer inventada.
    expect(texto.split('## Disco 2')[1], isNot(contains('Vida que le queda')));
  });
}
