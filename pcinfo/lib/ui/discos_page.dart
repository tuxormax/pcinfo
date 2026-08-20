import 'package:flutter/material.dart';

import '../models/hardware.dart';
import '../theme.dart';
import '../utils/format.dart';

/// Ámbar de "ojo con esto" (mismo tono que los avisos del resto de la app).
const _ambar = Color(0xFFE3A84B);
const _rojo = Color(0xFFF2768D);

/// Pestaña "Discos": la salud de cada disco duro o SSD contada como la de la
/// batería —anillo con el porcentaje, una frase que dice qué hacer y el porqué
/// en palabras normales—.
///
/// Por qué separada de Hardware: en la ficha de Almacenamiento la salud es una
/// etiqueta pequeña que hay que pulsar para entender. Un disco que se está
/// muriendo es lo más caro que le puede pasar a alguien (se pierden las fotos,
/// no el disco), así que se merece una pantalla que lo diga sin rodeos.
///
/// Los textos (verdict y notes) llegan REDACTADOS del backend: son los mismos
/// que salen en el reporte que se guarda.
class DiscosPage extends StatelessWidget {
  final List<DiskInfo> discos;

  /// true mientras la salud sigue leyéndose (segunda fase del arranque).
  final bool cargando;

  /// Botón "Reintentar como administrador" cuando hace falta (solo Windows).
  final Widget? avisoAccion;

  /// Fuerza la lectura de salud de un disco tomado por memoria extraíble.
  final void Function(DiskInfo)? onForzar;

  /// Discos a los que se les está forzando la lectura ahora mismo.
  final Set<String> forzando;

  const DiscosPage({
    super.key,
    required this.discos,
    this.cargando = false,
    this.avisoAccion,
    this.onForzar,
    this.forzando = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (discos.isEmpty) {
      return _mensaje(
        Icons.storage_rounded,
        cargando ? 'Buscando los discos…' : 'No se encontró ningún disco',
        cargando
            ? 'Un momento.'
            : 'Puede que el servicio de PCInfo no esté respondiendo.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        if (cargando) ...[_leyendo(), const SizedBox(height: 14)],
        for (final d in discos) ...[
          _disco(d),
          const SizedBox(height: 18),
        ],
      ],
    );
  }

  Widget _leyendo() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.accent),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Preguntándole la salud a los discos… tarda unos segundos.',
              style: TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Un disco completo ----

  Widget _disco(DiskInfo d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _veredicto(d),
        if (d.smartAvailable) ...[
          const SizedBox(height: 12),
          _cifras(d),
        ],
        if (d.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _explicaciones(d),
        ],
        const SizedBox(height: 12),
        _ficha(d),
      ],
    );
  }

  Widget _veredicto(DiskInfo d) {
    final color = _color(d);
    final vida = d.lifePercentLeft;
    return _tarjeta(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _anillo(d, color),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _distintivo(_etiqueta(d), color),
                    _distintivo(
                      [
                        if (d.type.isNotEmpty) d.type,
                        formatDiskCap(d.sizeBytes),
                        // El bus solo si aporta: en un "SATA SSD" repetir
                        // "SATA" no dice nada nuevo.
                        if (d.bus.isNotEmpty &&
                            !d.type.toLowerCase().contains(d.bus.toLowerCase()))
                          d.bus.toUpperCase(),
                      ].join(' · '),
                      AppColors.textMid,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  d.titulo,
                  style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: kFont + 4,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  d.verdict.isNotEmpty ? d.verdict : _veredictoLocal(d),
                  style: const TextStyle(
                      color: AppColors.textMid, fontSize: kFont + 1, height: 1.45),
                ),
                if (vida >= 0) ...[
                  const SizedBox(height: 6),
                  Text('Le queda el $vida % de su vida útil.',
                      style: const TextStyle(
                          color: AppColors.textMid, fontSize: kFont)),
                ],
                if (_ofreceForzar(d)) ...[
                  const SizedBox(height: 12),
                  _botonForzar(d),
                ],
                if (avisoAccion != null && !d.smartAvailable && !d.removable) ...[
                  const SizedBox(height: 12),
                  avisoAccion!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// El anillo enseña la VIDA que le queda al SSD. Un disco mecánico no la mide,
  /// así que en su lugar va el icono del estado: mentir con un porcentaje
  /// inventado sería peor que no ponerlo.
  Widget _anillo(DiskInfo d, Color color) {
    final vida = d.lifePercentLeft;
    if (vida < 0) {
      return SizedBox(
        width: 104,
        height: 104,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.5), width: 3),
          ),
          child: Icon(_icono(d), color: color, size: 42),
        ),
      );
    }
    return SizedBox(
      width: 104,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 104,
            height: 104,
            child: CircularProgressIndicator(
              value: vida / 100,
              strokeWidth: 9,
              backgroundColor: AppColors.surfaceAlt,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$vida',
                  style: TextStyle(
                      color: color,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      height: 1)),
              const Text('% de vida',
                  style: TextStyle(color: AppColors.textMid, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  // ---- Las cifras que importan ----

  Widget _cifras(DiskInfo d) {
    final cifras = <Widget>[
      _cifra(
        Icons.favorite_rounded,
        'Vida que le queda',
        d.lifePercentLeft >= 0 ? '${d.lifePercentLeft} %' : '—',
        d.lifePercentLeft >= 0
            ? 'Lo que el disco dice de sí mismo'
            : 'Los discos mecánicos no lo miden',
      ),
      _cifra(
        Icons.timelapse_rounded,
        'Tiempo encendido',
        d.powerOnHours > 0 ? '${formatEntero(d.powerOnHours)} h' : '—',
        d.powerCycles > 0
            ? 'Se ha encendido ${formatEntero(d.powerCycles)} veces'
            : 'Horas reales de funcionamiento',
      ),
      _cifra(
        Icons.edit_note_rounded,
        'Datos escritos',
        d.writtenBytes > 0 ? formatBytes(d.writtenBytes) : '—',
        d.writtenBytes > 0 && d.sizeBytes > 0
            ? 'Como llenarlo ${d.writtenBytes ~/ d.sizeBytes} veces'
            : 'Total escrito desde que se estrenó',
      ),
      _cifra(
        Icons.healing_rounded,
        'Trozos dañados',
        '${d.reallocatedSectors}',
        d.reallocatedSectors == 0
            ? 'Ninguno: buena señal'
            : 'Vigila que no aumenten',
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final columnas = c.maxWidth < 720 ? 2 : 4;
        final ancho = (c.maxWidth - (columnas - 1) * 12) / columnas;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final w in cifras) SizedBox(width: ancho, child: w)],
        );
      },
    );
  }

  Widget _cifra(IconData icono, String titulo, String valor, String pie) {
    return _tarjeta(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 15, color: AppColors.textMid),
              const SizedBox(width: 7),
              Expanded(
                child: Text(titulo,
                    style: const TextStyle(
                        color: AppColors.textMid, fontSize: kFont - 1)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(valor,
              style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont + 6,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(pie,
              style:
                  const TextStyle(color: AppColors.textLow, fontSize: kFont - 2)),
        ],
      ),
    );
  }

  // ---- El porqué ----

  Widget _explicaciones(DiskInfo d) {
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.help_outline_rounded, 'Qué significa todo esto'),
          const SizedBox(height: 6),
          for (final n in d.notes) _nota(n),
        ],
      ),
    );
  }

  Widget _nota(DiscoNota n) {
    final color = switch (n.level) {
      'warning' => _ambar,
      'fail' => _rojo,
      _ => AppColors.accent,
    };
    final icono = switch (n.level) {
      'warning' => Icons.warning_amber_rounded,
      'fail' => Icons.error_outline_rounded,
      _ => Icons.info_outline_rounded,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icono, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.title,
                    style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: kFont,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                SelectableText(n.detail,
                    style: const TextStyle(
                        color: AppColors.textMid, fontSize: kFont, height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Datos del disco ----

  Widget _ficha(DiskInfo d) {
    final filas = <List<String>>[
      ['Modelo', d.titulo],
      if (d.vendor.isNotEmpty) ['Fabricante', d.vendor],
      ['Tipo', d.type.isEmpty ? '—' : d.type],
      ['Capacidad', formatDiskCap(d.sizeBytes)],
      if (d.hasUsage)
        [
          'Espacio usado',
          '${formatBytes(d.usedBytes)} de ${formatBytes(d.fsTotalBytes)} '
              '(${d.usedPercent.round()} %) · libres ${formatBytes(d.availBytes)}'
        ],
      if (d.serial.isNotEmpty) ['Número de serie', d.serial],
      ['Dispositivo', d.name],
      if (d.readBytes > 0) ['Datos leídos', formatBytes(d.readBytes)],
    ];
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.storage_rounded, 'Datos del disco'),
          const SizedBox(height: 10),
          for (final f in filas)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 170,
                    child: Text(f[0],
                        style: const TextStyle(
                            color: AppColors.textMid, fontSize: kFont)),
                  ),
                  Expanded(
                    child: SelectableText(f[1],
                        style: const TextStyle(
                            color: AppColors.textHi, fontSize: kFont)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- Piezas comunes ----

  bool _ofreceForzar(DiskInfo d) =>
      onForzar != null && d.removable && !d.smartAvailable;

  Widget _botonForzar(DiskInfo d) {
    final ocupado = forzando.contains(d.name);
    return OutlinedButton.icon(
      onPressed: ocupado ? null : () => onForzar!(d),
      icon: ocupado
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.monitor_heart_rounded, size: 16),
      label: Text(ocupado ? 'Preguntando…' : 'Leer salud igual'),
    );
  }

  Widget _tarjeta({required Widget child, EdgeInsets? padding}) {
    return Container(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _titulo(IconData icono, String texto) {
    return Row(
      children: [
        Icon(icono, size: 17, color: AppColors.accent),
        const SizedBox(width: 9),
        Text(texto,
            style: const TextStyle(
                color: AppColors.textHi,
                fontSize: kFont + 1,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _distintivo(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(texto,
          style: TextStyle(
              color: color, fontSize: kFont - 2, fontWeight: FontWeight.w700)),
    );
  }

  Widget _mensaje(IconData icono, String titulo, String detalle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, color: AppColors.textMid, size: 52),
            const SizedBox(height: 16),
            Text(titulo,
                style: const TextStyle(
                    color: AppColors.textHi,
                    fontSize: kFont + 2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(detalle,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ],
        ),
      ),
    );
  }

  static Color _color(DiskInfo d) => switch (d.healthStatus) {
        DiskHealth.good => AppColors.accent,
        DiskHealth.warning => _ambar,
        DiskHealth.fail => _rojo,
        DiskHealth.unknown => AppColors.textMid,
      };

  static IconData _icono(DiskInfo d) => switch (d.healthStatus) {
        DiskHealth.good => Icons.check_rounded,
        DiskHealth.warning => Icons.priority_high_rounded,
        DiskHealth.fail => Icons.close_rounded,
        DiskHealth.unknown => Icons.question_mark_rounded,
      };

  static String _etiqueta(DiskInfo d) {
    if (d.removable) return 'MEMORIA EXTRAÍBLE';
    return switch (d.healthStatus) {
      DiskHealth.good => 'SANO',
      DiskHealth.warning => 'CON DESGASTE',
      DiskHealth.fail => 'PELIGRO',
      DiskHealth.unknown => 'SIN DATOS',
    };
  }

  /// Respaldo por si contesta un backend viejo que aún no redacta el veredicto.
  static String _veredictoLocal(DiskInfo d) => switch (d.healthStatus) {
        DiskHealth.good => 'El disco está sano.',
        DiskHealth.warning => 'El disco da señales de desgaste.',
        DiskHealth.fail =>
          'El disco está fallando: haz copia de seguridad y cámbialo.',
        DiskHealth.unknown => 'No hay datos de salud de este disco.',
      };
}
