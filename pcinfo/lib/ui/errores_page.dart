import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/errores.dart';
import '../theme.dart';
import '../utils/format.dart';

/// Pestaña "Historial de Errores": muestra lo que el sistema operativo registró
/// (pantallazos azules y registro de eventos en Windows; journald y kernel en
/// Linux) ya traducido a "qué pasó · por qué · cómo se resuelve".
///
/// La carga y los estados de error viven en el dashboard; aquí solo se pinta el
/// reporte ya obtenido y se filtra por categoría.
class ErroresPage extends StatefulWidget {
  final ErroresInfo data;

  /// Botón opcional que acompaña al aviso (p. ej. "Reintentar como
  /// administrador" en Windows cuando el backend no está elevado).
  final Widget? avisoAccion;

  const ErroresPage({super.key, required this.data, this.avisoAccion});

  @override
  State<ErroresPage> createState() => _ErroresPageState();
}

class _ErroresPageState extends State<ErroresPage> {
  /// Categoría activa del filtro; null = todas.
  String? _filtro;

  @override
  void didUpdateWidget(ErroresPage old) {
    super.didUpdateWidget(old);
    // Si tras refrescar ya no existe la categoría filtrada, se vuelve a "Todos"
    // para no dejar la lista vacía sin explicación.
    if (_filtro != null && !widget.data.conteoPorTipo.containsKey(_filtro)) {
      _filtro = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final items =
        _filtro == null ? d.items : d.items.where((e) => e.kind == _filtro).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _resumen(d),
          if (d.reason.isNotEmpty) ...[
            const SizedBox(height: 14),
            _aviso(d),
          ],
          if (d.items.isNotEmpty) ...[
            const SizedBox(height: 16),
            _filtros(d),
          ],
          const SizedBox(height: 16),
          if (d.items.isEmpty)
            _sinErrores(d)
          else
            ...items.map((e) => _ErrorCard(item: e)),
          if (d.dumps.isNotEmpty) ...[
            const SizedBox(height: 8),
            _volcados(d),
          ],
        ],
      ),
    );
  }

  // ---- Resumen y avisos ----

  Widget _resumen(ErroresInfo d) {
    final graves = d.items
        .where((e) => e.severity == 'critico' || e.kind == 'pantallazo')
        .length;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (graves > 0 ? _colorSeveridad('critico') : AppColors.accent)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              graves > 0
                  ? Icons.report_gmailerrorred_rounded
                  : Icons.fact_check_rounded,
              color: graves > 0 ? _colorSeveridad('critico') : AppColors.accent,
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.items.isEmpty
                      ? 'Sin errores registrados'
                      : '${d.items.length} problema(s) detectado(s)'
                          '${graves > 0 ? "  ·  $graves grave(s)" : ""}',
                  style: const TextStyle(
                    color: AppColors.textHi,
                    fontSize: kFont,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Últimos ${d.scanDays} días  ·  ${d.source}'
                  '${d.totalOcurrencias > d.items.length ? "  ·  ${d.totalOcurrencias} apariciones en total" : ""}',
                  style: const TextStyle(
                      color: AppColors.textLow, fontSize: kFont),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _aviso(ErroresInfo d) {
    // Si no se pudo leer nada es un problema (rojo); si se leyó pero con
    // limitaciones, es solo un matiz (ámbar).
    final color =
        d.available ? const Color(0xFFE3A84B) : const Color(0xFFF2768D);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
              d.available
                  ? Icons.info_outline_rounded
                  : Icons.report_gmailerrorred_rounded,
              size: 20,
              color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.available
                      ? 'La lista podría estar incompleta'
                      : 'No se pudieron leer los registros del sistema',
                  style: TextStyle(
                      color: color,
                      fontSize: kFont,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(d.reason,
                    style: const TextStyle(
                        color: AppColors.textMid, fontSize: kFont, height: 1.35)),
                if (widget.avisoAccion != null) ...[
                  const SizedBox(height: 12),
                  widget.avisoAccion!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sinErrores(ErroresInfo d) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(
            d.available ? Icons.verified_rounded : Icons.help_outline_rounded,
            size: 40,
            color: d.available ? const Color(0xFF3FB950) : AppColors.textLow,
          ),
          const SizedBox(height: 12),
          Text(
            d.available
                ? 'Ningún error en los últimos ${d.scanDays} días'
                : 'No hay información disponible',
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: kFont,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            d.available
                ? 'No se encontraron pantallazos, apagados inesperados ni fallos '
                    'registrados por el sistema operativo.'
                : 'Revisa el aviso de arriba para saber qué falta para poder leerlos.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
          ),
        ],
      ),
    );
  }

  Widget _filtros(ErroresInfo d) {
    final conteo = d.conteoPorTipo;
    final tipos = _ordenTipos.where(conteo.containsKey).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chipFiltro('Todos', d.items.length, null),
        for (final t in tipos) _chipFiltro(_nombreTipo(t), conteo[t]!, t),
      ],
    );
  }

  Widget _chipFiltro(String texto, int n, String? tipo) {
    final activo = _filtro == tipo;
    final color = tipo == null ? AppColors.accent : _colorTipo(tipo);
    return Material(
      color: activo ? color.withValues(alpha: 0.18) : AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _filtro = tipo),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: activo
                    ? color.withValues(alpha: 0.55)
                    : AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tipo != null) ...[
                Icon(_iconoTipo(tipo), size: 14, color: color),
                const SizedBox(width: 6),
              ],
              Text(texto,
                  style: TextStyle(
                      color: activo ? AppColors.textHi : AppColors.textMid,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('$n',
                  style: TextStyle(
                      color: activo ? color : AppColors.textLow,
                      fontSize: kFont,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _volcados(ErroresInfo d) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Volcados de memoria guardados en el disco',
              style: TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text(
            'Son la "foto" de la memoria en el momento del fallo. Sirven para un '
            'análisis a fondo con herramientas de depuración.',
            style: TextStyle(color: AppColors.textLow, fontSize: kFont),
          ),
          const SizedBox(height: 10),
          for (final dm in d.dumps)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined,
                      size: 14, color: AppColors.textLow),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(dm.path,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textMid, fontSize: kFont)),
                  ),
                  const SizedBox(width: 10),
                  Text('${dm.when}   ${formatBytes(dm.sizeBytes)}',
                      style: const TextStyle(
                          color: AppColors.textLow, fontSize: kFont)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta de un error (plegable)
// ---------------------------------------------------------------------------

class _ErrorCard extends StatefulWidget {
  final ErrorItem item;
  const _ErrorCard({required this.item});

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> {
  bool _abierto = false;
  bool _copiado = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.item;
    final color = _colorSeveridad(e.severity);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _abierto = !_abierto),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _colorTipo(e.kind).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(_iconoTipo(e.kind),
                          size: 19, color: _colorTipo(e.kind)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.title,
                              style: const TextStyle(
                                  color: AppColors.textHi,
                                  fontSize: kFont,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _badge(_nombreSeveridad(e.severity), color),
                              _badge(_nombreTipo(e.kind), _colorTipo(e.kind)),
                              if (e.repetido)
                                _badge('${e.count} veces', AppColors.textMid),
                              if (e.code.isNotEmpty)
                                _badge(e.code, AppColors.textMid),
                              Text(
                                e.repetido && e.firstWhen.isNotEmpty
                                    ? 'Última vez: ${e.when}  ·  desde ${e.firstWhen}'
                                    : e.when,
                                style: const TextStyle(
                                    color: AppColors.textLow, fontSize: kFont),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                        _abierto
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: AppColors.textMid,
                        size: 20),
                  ],
                ),
              ),
            ),
          ),
          if (_abierto) _detalle(e),
        ],
      ),
    );
  }

  Widget _detalle(ErrorItem e) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 14),
          if (e.culprit.isNotEmpty) _culpable(e),
          if (e.cause.isNotEmpty)
            _bloque(Icons.help_outline_rounded, 'Qué lo provocó', e.cause,
                AppColors.textMid),
          if (e.fix.isNotEmpty)
            _bloque(Icons.build_circle_outlined, 'Cómo resolverlo', e.fix,
                AppColors.accent),
          if (e.suspects.length > 1) _sospechosos(e),
          if (e.source.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Text(
                'Origen: ${e.source}'
                '${e.codeName.isNotEmpty ? "  ·  ${e.codeName}" : ""}',
                style:
                    const TextStyle(color: AppColors.textLow, fontSize: kFont),
              ),
            ),
          if (e.detail.isNotEmpty) _crudo(e),
        ],
      ),
    );
  }

  Widget _culpable(ErrorItem e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.board.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.gps_fixed_rounded, size: 18, color: AppColors.board),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Probable causante',
                        style: TextStyle(
                            color: AppColors.board,
                            fontSize: kFont,
                            fontWeight: FontWeight.w700)),
                    if (e.confidence.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      _badge('confianza ${e.confidence}', AppColors.textMid),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(e.culprit,
                    style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: kFont,
                        fontWeight: FontWeight.w700)),
                if (e.culpritInfo.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  SelectableText(e.culpritInfo,
                      style: const TextStyle(
                          color: AppColors.textMid, fontSize: kFont)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bloque(IconData icono, String titulo, String texto, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 15, color: color),
              const SizedBox(width: 7),
              Text(titulo,
                  style: TextStyle(
                      color: color,
                      fontSize: kFont,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(texto,
              style: const TextStyle(
                  color: AppColors.textMid, fontSize: kFont, height: 1.4)),
        ],
      ),
    );
  }

  Widget _sospechosos(ErrorItem e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Otros drivers de terceros cargados al fallar',
              style: TextStyle(
                  color: AppColors.textMid,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final s in e.suspects.skip(1))
            Text('·  $s',
                style:
                    const TextStyle(color: AppColors.textLow, fontSize: kFont)),
        ],
      ),
    );
  }

  Widget _crudo(ErrorItem e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Mensaje original del sistema',
                style: TextStyle(
                    color: AppColors.textLow,
                    fontSize: kFont,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _copiar(e),
              icon: Icon(
                  _copiado ? Icons.check_rounded : Icons.copy_all_rounded,
                  size: 15),
              label: Text(_copiado ? 'Copiado' : 'Copiar'),
              style: TextButton.styleFrom(
                foregroundColor:
                    _copiado ? const Color(0xFF3FB950) : AppColors.textMid,
                textStyle: const TextStyle(fontSize: kFont),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 30),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SelectableText(
            e.detail,
            style: const TextStyle(
              color: AppColors.textMid,
              fontSize: kFont - 1,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  /// Copia el problema COMPLETO (no solo el texto crudo): así el usuario puede
  /// pegarlo tal cual al pedir soporte.
  Future<void> _copiar(ErrorItem e) async {
    final b = StringBuffer()
      ..writeln(e.title)
      ..writeln('Cuándo: ${e.when}'
          '${e.repetido ? " (${e.count} veces desde ${e.firstWhen})" : ""}')
      ..writeln('Origen: ${e.source}');
    if (e.code.isNotEmpty) {
      b.writeln('Código: ${e.code} ${e.codeName}'.trimRight());
    }
    if (e.culprit.isNotEmpty) {
      b.writeln('Probable causante: ${e.culprit} ${e.culpritInfo}'.trimRight());
    }
    if (e.cause.isNotEmpty) b.writeln('Causa: ${e.cause}');
    if (e.fix.isNotEmpty) b.writeln('Solución: ${e.fix}');
    b
      ..writeln()
      ..writeln('--- Mensaje original ---')
      ..writeln(e.detail);
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (!mounted) return;
    setState(() => _copiado = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copiado = false);
  }

  Widget _badge(String texto, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Text(texto,
            style: TextStyle(
                color: color, fontSize: kFont - 2, fontWeight: FontWeight.w700)),
      );
}

// ---------------------------------------------------------------------------
// Traducción de categorías y severidades (compartida por la página y la tarjeta)
// ---------------------------------------------------------------------------

/// Orden en que se ofrecen los filtros: de lo más grave a lo más anecdótico.
const _ordenTipos = [
  'pantallazo',
  'apagado',
  'hardware',
  'disco',
  'memoria',
  'grafica',
  'servicio',
  'aplicacion',
  'sistema',
];

String _nombreTipo(String kind) {
  switch (kind) {
    case 'pantallazo':
      return 'Pantallazos';
    case 'apagado':
      return 'Apagones';
    case 'hardware':
      return 'Hardware';
    case 'disco':
      return 'Disco';
    case 'grafica':
      return 'Gráficos';
    case 'servicio':
      return 'Servicios';
    case 'aplicacion':
      return 'Programas';
    case 'memoria':
      return 'Memoria';
    default:
      return 'Sistema';
  }
}

IconData _iconoTipo(String kind) {
  switch (kind) {
    case 'pantallazo':
      return Icons.dangerous_rounded;
    case 'apagado':
      return Icons.power_settings_new_rounded;
    case 'hardware':
      return Icons.developer_board_rounded;
    case 'disco':
      return Icons.storage_rounded;
    case 'grafica':
      return Icons.videogame_asset_rounded;
    case 'servicio':
      return Icons.settings_suggest_rounded;
    case 'aplicacion':
      return Icons.apps_rounded;
    case 'memoria':
      return Icons.memory_rounded;
    default:
      return Icons.computer_rounded;
  }
}

Color _colorTipo(String kind) {
  switch (kind) {
    case 'pantallazo':
      return const Color(0xFFF2768D);
    case 'apagado':
      return const Color(0xFFE3A84B);
    case 'hardware':
      return AppColors.cpu;
    case 'disco':
      return AppColors.disk;
    case 'grafica':
      return AppColors.gpu;
    case 'servicio':
      return AppColors.system;
    case 'aplicacion':
      return AppColors.ram;
    case 'memoria':
      return AppColors.ram;
    default:
      return AppColors.textMid;
  }
}

String _nombreSeveridad(String sev) {
  switch (sev) {
    case 'critico':
      return 'CRÍTICO';
    case 'aviso':
      return 'AVISO';
    default:
      return 'ERROR';
  }
}

Color _colorSeveridad(String sev) {
  switch (sev) {
    case 'critico':
      return const Color(0xFFF2768D);
    case 'aviso':
      return AppColors.textMid;
    default:
      return const Color(0xFFE3A84B);
  }
}
