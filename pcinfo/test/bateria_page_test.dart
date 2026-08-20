import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/bateria.dart';
import 'package:pcinfo/ui/bateria_page.dart';
import 'package:pcinfo/utils/report.dart';

/// Datos reales de un portátil Lenovo Yoga 910, tal como los devuelve el
/// backend. Se usan los mismos números del informe de batería de Windows con el
/// que se diseñó la pestaña.
const _json = '''
{
  "os": "windows", "supported": true, "available": true, "hasBattery": true,
  "reason": "", "source": "Informe de batería de Windows (powercfg) y WMI",
  "generated": "2026-08-20 09:24", "onAc": true, "onAcKnown": true,
  "equipment": "Lenovo YOGA 910-13IKB (80VF)",
  "batteries": [{
    "name": "BASE-BAT", "model": "", "manufacturer": "Simplo",
    "serial": "123456789", "chemistry": "LiP",
    "chemistryText": "Polímero de litio", "voltageMV": 7680,
    "designMWh": 78000, "fullMWh": 67900, "remainingMWh": 66250,
    "chargePercent": 98, "cycleCount": 0, "state": "conectada",
    "healthPercent": 87, "healthLevel": "good",
    "verdict": "La batería está en buen estado.",
    "notes": [{"level":"info","title":"Cuánta carga aguanta hoy","detail":"…"}]
  }],
  "history": [
    {"period":"27/06/2026 – 04/07/2026","fullMWh":66040,"designMWh":78000,"healthPercent":84},
    {"period":"04/07/2026 – 11/07/2026","fullMWh":65382,"designMWh":78000,"healthPercent":83},
    {"period":"19/08/2026","fullMWh":63862,"designMWh":78000,"healthPercent":81}
  ],
  "runtimeFullMin": 392, "runtimeNowMin": 0, "runtimeHeavyMin": 156,
  "wattsTypicalMW": 10392, "wattsHeavyMW": 25980
}
''';

BateriaInfo get _bat =>
    BateriaInfo.fromJson(jsonDecode(_json) as Map<String, dynamic>);

void main() {
  // La gráfica "Cómo ha ido bajando" vive en una caja de alto fijo: si se toca
  // el tamaño de la letra o se añade una línea a la etiqueta del periodo, se
  // desborda y aparece la franja amarilla encima de las barras (pasó al
  // estrenarla). Esta prueba lo caza sin tener que abrir la app.
  testWidgets('la pestaña no desborda en una ventana normal', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BateriaPage(data: _bat))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tampoco en una ventana estrecha', (tester) async {
    tester.view.physicalSize = const Size(820, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BateriaPage(data: _bat))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('un equipo sin batería lo dice, no se queda en blanco',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: BateriaPage(
          data: BateriaInfo(
            os: 'linux',
            supported: true,
            available: true,
            reason: 'Este equipo no tiene batería: es de escritorio.',
          ),
        ),
      ),
    ));
    expect(find.text('Este equipo no tiene batería'), findsOneWidget);
  });

  test('el reporte lleva lo necesario para comprar el repuesto', () {
    final texto = buildBateriaReport(_bat, 'DESKTOP-0QAGG5O');
    expect(texto, contains('La batería está en buen estado.'));
    expect(texto, contains('Lenovo YOGA 910-13IKB (80VF)'));
    expect(texto, contains('7,68 V'));
    expect(texto, contains('10156 mAh'));
    // La duración "cuando era nueva" se quitó a propósito: no debe volver.
    expect(texto, isNot(contains('cuando era nueva')));
    expect(texto, contains('Usándolo a tope'));
  });
}
