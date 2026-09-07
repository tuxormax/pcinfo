import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/arranques.dart';
import 'package:pcinfo/services/arranques_service.dart';
import 'package:pcinfo/ui/arranques_page.dart';

/// Respuesta del backend tal cual, con el caso que motivó el módulo: un equipo
/// que se apaga solo cada noche y un día no lo hizo.
const _json = '''
{"os":"linux","elevated":false,"available":true,"reason":"","scanDays":30,
 "source":"registro de accesos (wtmp), journald, systemd y cron",
 "sessions":[
  {"index":0,"start":"2026-09-07 06:30:12","end":"","secondsUp":21600,
   "ended":"encurso","kernel":"6.8.0-138-generi","lastLine":"","note":"Es la sesión en curso."},
  {"index":-1,"start":"2026-09-06 06:30:20","end":"","secondsUp":48600,
   "ended":"brusco","kernel":"6.8.0-138-generi",
   "lastLine":"kernel: watchdog: BUG: soft lockup - CPU#2 stuck",
   "note":"El registro se corta de golpe, sin las líneas del apagado ordenado."},
  {"index":-2,"start":"2026-09-05 06:30:10","end":"2026-09-05 20:00:44",
   "secondsUp":48634,"ended":"normal","kernel":"6.8.0-138-generi","lastLine":"","note":""}],
 "tasks":[
  {"name":"pg-backup-apagado.service","kind":"servicio",
   "description":"Backup PostgreSQL antes de apagar","trigger":"Al apagar o reiniciar el equipo",
   "command":"/usr/local/bin/pg_backup.sh apagado","state":"activo",
   "lastRun":"2026-09-05 20:00:12","nextRun":"","result":"Terminó correctamente",
   "source":"/etc/systemd/system/pg-backup-apagado.service","fromSystem":false},
  {"name":"man-db.timer","kind":"temporizador","description":"Daily man-db regeneration",
   "trigger":"Todos los días a las 00:00","command":"","state":"activo",
   "lastRun":"","nextRun":"2026-09-08 00:00:00","result":"","source":"","fromSystem":true}],
 "startup":[
  {"name":"PG Backup Manager","command":"pg-backup-manager --minimizado",
   "source":"/home/victor/.config/autostart/pg_backup_manager.desktop",
   "scope":"usuario victor","enabled":true,"running":false,
   "note":"No está en ejecución ahora mismo."},
  {"name":"Caribou","command":"/usr/lib/caribou/caribou","source":"/etc/xdg/autostart/caribou.desktop",
   "scope":"todos los usuarios","enabled":true,"running":false,"note":""}],
 "journalVolatile":true,
 "sessionsNote":"El diario del sistema de este equipo es volátil.",
 "tasksNote":"","startupNote":""}
''';

ArranquesInfo get _datos =>
    ArranquesInfo.fromJson(jsonDecode(_json) as Map<String, dynamic>);

Future<void> _monta(
  WidgetTester tester,
  Size tamano, {
  Future<ResultadoAccion> Function()? onActivarDiario,
  VoidCallback? onRecargar,
}) async {
  tester.view.physicalSize = tamano;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ArranquesPage(
    data: _datos,
    onActivarDiario: onActivarDiario,
    onRecargar: onRecargar,
  ))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('la pestaña no desborda en una ventana normal', (tester) async {
    await _monta(tester, const Size(1280, 1600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tampoco en una ventana estrecha', (tester) async {
    await _monta(tester, const Size(820, 1400));
    expect(tester.takeException(), isNull);
  });

  // El tamaño de las tabletas de mostrador: nada puede quedarse fuera de la
  // pantalla, porque lo que queda fuera no se puede tocar.
  testWidgets('ni en una pantalla de 800x480', (tester) async {
    await _monta(tester, const Size(800, 480));
    expect(tester.takeException(), isNull);
  });

  // El rótulo tiene que nombrar las dos cosas: la lista trae los apagados y con
  // "Encendidos" a secas no se sabe dónde mirarlos.
  testWidgets('la sección se llama por las dos cosas que muestra',
      (tester) async {
    await _monta(tester, const Size(1280, 1600));
    expect(find.textContaining('Encendidos y apagados ('), findsOneWidget);
  });

  // Las sesiones van agrupadas por día, con la fecha en español y el número de
  // encendidos de ese día (que un día tenga cinco ya es un dato en sí mismo).
  testWidgets('agrupa por día, con la fecha escrita', (tester) async {
    await _monta(tester, const Size(1280, 1600));
    expect(find.textContaining('lunes 7 de septiembre'), findsOneWidget);
    expect(find.textContaining('domingo 6 de septiembre'), findsOneWidget);
    expect(find.textContaining('sábado 5 de septiembre'), findsOneWidget);
    expect(find.text('(1 encendido)'), findsNWidgets(3));
  });

  // Cada sesión son dos cuadros, siempre en el mismo sitio y del mismo color.
  testWidgets('cada sesión tiene su cuadro de encendido y el de apagado',
      (tester) async {
    await _monta(tester, const Size(1280, 1600));
    expect(find.text('ENCENDIDO'), findsNWidgets(3));
    expect(find.text('APAGADO'), findsNWidgets(3));
    // Horas sueltas, sin la fecha repetida: esa ya está en el encabezado.
    expect(find.text('06:30'), findsNWidgets(3)); // los tres encendidos
    expect(find.text('20:00'), findsOneWidget); // el único apagado que hubo
  });

  testWidgets('el apagón brusco lo dice con todas sus letras', (tester) async {
    await _monta(tester, const Size(1280, 1600));
    // Está en el resumen de arriba…
    expect(find.textContaining('1 terminó de golpe'), findsWidgets);
    expect(find.text('1 apagones bruscos'), findsOneWidget);
    // …y en su cuadro, en rojo, con el motivo y el último registro del sistema.
    expect(find.text('NO SE REALIZÓ EL APAGADO'), findsOneWidget);
    expect(find.textContaining('El registro se corta de golpe'), findsOneWidget);
    expect(find.textContaining('soft lockup'), findsOneWidget);
  });

  testWidgets('la sesión en curso no es un fallo ni inventa una hora',
      (tester) async {
    await _monta(tester, const Size(1280, 1600));
    expect(find.text('sigue encendido'), findsOneWidget);
    // Que todavía no se haya apagado no es un apagado fallido.
    expect(find.text('NO SE REALIZÓ EL APAGADO'), findsOneWidget);
  });

  testWidgets('las tareas del sistema se esconden hasta que se piden',
      (tester) async {
    await _monta(tester, const Size(1280, 1600));
    await tester.tap(find.textContaining('Tareas automáticas ('));
    await tester.pumpAndSettle();

    // La propia del equipo sí, la del sistema no: entre treinta temporizadores
    // de Linux no se distingue la que alguien puso ahí.
    expect(find.text('pg-backup-apagado.service'), findsOneWidget);
    expect(find.text('man-db.timer'), findsNothing);
    expect(find.textContaining('Al apagar o reiniciar el equipo'), findsOneWidget);
    expect(find.textContaining('última vez: 2026-09-05 20:00:12'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('man-db.timer'), findsOneWidget);
    expect(find.textContaining('nunca ha corrido'), findsOneWidget);
  });

  testWidgets('el autoarranque dice si el programa está vivo', (tester) async {
    await _monta(tester, const Size(1280, 1600));
    await tester.tap(find.textContaining('Al iniciar sesión ('));
    await tester.pumpAndSettle();

    expect(find.text('PG Backup Manager'), findsOneWidget);
    expect(find.text('No está corriendo'), findsOneWidget);
    // Los sesenta programas del escritorio quedan fuera hasta que se piden.
    expect(find.text('Caribou'), findsNothing);
  });

  // El aviso del diario volátil no puede quedarse en "hay que crear una
  // carpeta": eso obliga a abrir una terminal como administrador. La pestaña lo
  // hace, y solo cuando hay servicio detrás que pueda hacerlo.
  testWidgets('el diario volátil se puede activar desde la propia pestaña',
      (tester) async {
    var llamado = false;
    var recargado = false;
    await _monta(tester, const Size(1280, 1600), onActivarDiario: () async {
      llamado = true;
      return const ResultadoAccion(ok: true, message: 'Listo: ya se guarda.');
    }, onRecargar: () => recargado = true);

    expect(find.text('Activar el diario permanente'), findsOneWidget);
    await tester.tap(find.text('Activar el diario permanente'));
    await tester.pumpAndSettle();

    // Antes de tocar el sistema se dice qué se va a cambiar y que pedirá clave.
    expect(find.textContaining('contraseña de administrador'), findsOneWidget);
    expect(llamado, isFalse);
    await tester.tap(find.text('Activar'));
    await tester.pumpAndSettle();

    expect(llamado, isTrue);
    expect(recargado, isTrue); // salió bien: se releen los datos
    expect(find.textContaining('Listo: ya se guarda.'), findsOneWidget);
  });

  testWidgets('sin servicio detrás, el aviso no ofrece un botón que no haría nada',
      (tester) async {
    await _monta(tester, const Size(1280, 1600));
    expect(find.textContaining('El diario del sistema'), findsOneWidget);
    expect(find.text('Activar el diario permanente'), findsNothing);
  });
}
