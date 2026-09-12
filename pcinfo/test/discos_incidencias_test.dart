import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/hardware.dart';
import 'package:pcinfo/models/incidencias.dart';
import 'package:pcinfo/ui/discos_page.dart';

/// Las incidencias REALES del disco USB de 2 TB (12-sep-2026), tal como las
/// devolvió el backend: el registro del sistema tenía 7 318 errores de lectura
/// sobre 3 910 posiciones distintas, con 3 727 de ellas juntas en un tramo de
/// 1,2 GB — eso es daño del disco, no del índice de archivos.
const _json = '''
{"disponible":true,"motivo":"","fuente":"registro unificado de macOS (log show)","horas":24,
 "discos":[
  {"device":"/dev/disk4","etiqueta":"Tech","conectado":false,
   "erroresES":7318,"sectoresMalos":3910,"desconexiones":3,"reparaciones":3,
   "arranques":3,"falloInterno":true,
   "primera":"2026-09-12 09:38:42","ultima":"2026-09-12 12:55:22",
   "zonas":[{"desdeGB":164.1,"hastaGB":165.3,"sectores":3727,"mbIlegibles":123.4},
            {"desdeGB":1114.5,"hastaGB":1114.5,"sectores":160,"mbIlegibles":20.0}],
   "veredicto":"Este disco tiene una zona que NO se puede leer: unos 123 MB alrededor del GB 164.",
   "notas":[{"level":"fail","title":"Zona dañada en el GB 164","detail":"3 727 posiciones no respondieron."},
            {"level":"fail","title":"Se fue del bus sin avisar","detail":"3 veces."}]}
 ]}
''';

IncidenciasDiscos get _inc =>
    IncidenciasDiscos.fromJson(jsonDecode(_json) as Map<String, dynamic>);

final _discoConectado = DiskInfo.fromJson(<String, dynamic>{
  'name': '/dev/disk4',
  'model': 'JMicron Tech',
  'type': '',
  'bus': 'usb',
  'port': 'USB',
  'sizeBytes': 2000398934016,
  'smartAvailable': false,
  'verdict': 'macOS no puede leer la salud de un disco conectado por USB.',
  'notes': <dynamic>[],
});

void main() {
  testWidgets('un disco que ya no está conectado NO pierde su historial',
      (tester) async {
    // ⭐ Es el caso que importa: el disco que da problemas acaba
    // desconectándose, y si al irse se lleva la información, el usuario se
    // queda sin saber qué pasó justo con el disco que falló.
    tester.view.physicalSize = const Size(1280, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DiscosPage(discos: const [], incidencias: _inc),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('/dev/disk4'), findsWidgets,
        reason: 'debe salir el disco aunque ya no esté puesto');
    expect(find.textContaining('YA NO ESTÁ CONECTADO'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('las incidencias se pintan junto a su disco, con los números',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DiscosPage(discos: [_discoConectado], incidencias: _inc),
      ),
    ));
    await tester.pumpAndSettle();

    // Los números que el usuario busca de un vistazo.
    expect(find.textContaining('7 318'), findsWidgets,
        reason: 'la cantidad de errores de E/S es el dato que se pidió');
    expect(find.textContaining('3 910'), findsWidgets,
        reason: 'las posiciones distintas que fallaron');
    // Y DÓNDE falló, en GB: "el sector 2 176 016 128" no le dice nada a nadie.
    expect(find.textContaining('GB 164'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin incidencias no se pinta la tarjeta', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DiscosPage(
          discos: [_discoConectado],
          incidencias: const IncidenciasDiscos(disponible: true, discos: []),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Incidencias'), findsNothing,
        reason: 'un disco sin incidencias no lleva tarjeta de incidencias');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tampoco desborda en una ventana estrecha', (tester) async {
    // Regla del proyecto: nada se sale de la pantalla en un equipo chico.
    tester.view.physicalSize = const Size(820, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DiscosPage(discos: [_discoConectado], incidencias: _inc),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
