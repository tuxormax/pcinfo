import 'package:flutter_test/flutter_test.dart';
import 'package:pcinfo/models/arranques.dart';
import 'package:pcinfo/utils/report.dart';

/// El .md de encendidos es lo que se manda por chat cuando un equipo "no se
/// apagó" o "no hizo lo suyo de noche", así que lo que se prueba es que el
/// reporte diga de una las dos cosas que se van a buscar: qué sesión terminó de
/// golpe y si la tarea automática llegó a correr.
void main() {
  const arr = ArranquesInfo(
    os: 'linux',
    source: 'registro de accesos (wtmp), journald, systemd y cron',
    available: true,
    scanDays: 30,
    sessions: [
      Sesion(
        index: 0,
        start: '2026-09-07 06:30:12',
        secondsUp: 21600,
        ended: FinSesion.enCurso,
        kernel: '6.8.0-138-generi',
      ),
      Sesion(
        index: -1,
        start: '2026-09-06 06:30:20',
        secondsUp: 48600,
        ended: FinSesion.brusco,
        kernel: '6.8.0-138-generi',
        lastLine: 'kernel: watchdog: BUG: soft lockup - CPU#2 stuck',
        note: 'El registro se corta de golpe, sin las líneas del apagado ordenado.',
      ),
      Sesion(
        index: -2,
        start: '2026-09-05 06:30:10',
        end: '2026-09-05 20:00:44',
        secondsUp: 48634,
        ended: FinSesion.normal,
      ),
    ],
    tasks: [
      TareaAutomatica(
        name: 'pg-backup-apagado.service',
        kind: TipoTarea.servicio,
        description: 'Backup PostgreSQL antes de apagar',
        trigger: 'Al apagar o reiniciar el equipo',
        command: '/usr/local/bin/pg_backup.sh apagado',
        state: EstadoTarea.activo,
        atShutdown: true,
      ),
      TareaAutomatica(
        name: 'man-db.timer',
        kind: TipoTarea.temporizador,
        trigger: 'Todos los días a las 00:00',
        state: EstadoTarea.activo,
        fromSystem: true,
      ),
    ],
    startup: [
      ProgramaInicio(
        name: 'PG Backup Manager',
        command: 'pg-backup-manager --minimizado',
        source: '/home/victor/.config/autostart/pg_backup_manager.desktop',
        scope: 'usuario victor',
        enabled: true,
        running: false,
      ),
    ],
  );

  test('el resumen cuenta los apagones bruscos', () {
    expect(arr.bruscos, 1);
    expect(arr.normales, 1);
    expect(arr.resumen, contains('1 terminó de golpe'));
  });

  test('el reporte detalla las sesiones cortadas y no las demás', () {
    final md = buildArranquesReport(arr, 'victor-B550M');

    expect(md, contains('# Encendidos y apagados — victor-B550M'));
    // La tabla resume las tres; el detalle es solo del corte.
    expect(md, contains('2026-09-06 06:30:20'));
    expect(md, contains('Apagón brusco'));
    expect(md, contains('Detalle de los apagones bruscos (1)'));
    expect(md, contains('soft lockup'));
    // La sesión en curso no lleva hora de apagado inventada.
    expect(md, contains('sigue encendido'));
  });

  test('separa lo que se le añadió al equipo de lo que trae el sistema', () {
    final md = buildArranquesReport(arr, 'victor-B550M');
    final propias = md.indexOf('### Añadidas a este equipo (1)');
    final sistema = md.indexOf('### Vienen con el sistema (1)');

    expect(propias, greaterThan(-1));
    expect(sistema, greaterThan(propias));
    expect(md, contains('pg-backup-apagado.service'));
    expect(md, contains('Al apagar o reiniciar el equipo'));
  });

  test('una tarea que nunca corrió lo dice, no aparece en blanco', () {
    final md = buildArranquesReport(arr, 'equipo');
    expect(md, contains('| nunca ha corrido |'));
  });

  // Un servicio de apagado corre cuando la sesión termina y systemd olvida el
  // estado al reiniciar: decir "nunca" acusaría todos los días a un respaldo
  // que sí se está haciendo.
  test('un servicio de apagado no se acusa de no haber corrido', () {
    final md = buildArranquesReport(arr, 'equipo');
    expect(md, contains('no consta en esta sesión'));
    final tarea = arr.tasks.firstWhere((t) => t.atShutdown);
    expect(tarea.ultimaVezTexto, 'no consta en esta sesión');
  });

  test('el programa de autoarranque muestra si está corriendo', () {
    final md = buildArranquesReport(arr, 'equipo');
    expect(md, contains('PG Backup Manager'));
    expect(md, contains('### De este usuario (1)'));
    // enabled=true, running=false → "activo" y "no".
    expect(md, contains('| activo | no |'));
  });
}
