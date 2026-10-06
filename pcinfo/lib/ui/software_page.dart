import 'package:flutter/material.dart';

import '../models/software.dart';
import '../services/backend_http.dart';
import '../services/software_service.dart';
import '../theme.dart';

/// Ámbar de "ojo con esto" (mismo tono que los avisos del resto de la app).
const _ambar = Color(0xFFE3A84B);

/// Pestaña "Software instalado": qué programas hay en el equipo y con qué
/// versión, agrupados por quién los puso ahí.
///
/// El backend devuelve TODO (también los componentes y parches del sistema) y
/// aquí se filtra: por defecto se muestra lo que instaló el usuario, que es lo
/// que de verdad distingue a un equipo de otro, y un interruptor deja ver
/// también lo que vino con el sistema operativo.
class SoftwarePage extends StatefulWidget {
  final SoftwareInfo data;

  /// Si viene, las apps de la Tienda ofrecen el botón "Quitar".
  final SoftwareService? service;

  const SoftwarePage({super.key, required this.data, this.service});

  @override
  State<SoftwarePage> createState() => _SoftwarePageState();
}

class _SoftwarePageState extends State<SoftwarePage> {
  /// Texto del buscador (nombre, fabricante o versión).
  String _busca = '';

  /// ¿Mostrar también lo que vino con el sistema (componentes y parches)?
  bool _verSistema = false;

  /// Apps ya quitadas en esta sesión (se ocultan sin volver a leer todo) y la
  /// que se está quitando ahora.
  final Set<String> _quitadas = {};
  String? _quitando;
  String _falloQuitar = '';

  Future<void> _quitar(SoftwareItem it) async {
    final svc = widget.service;
    if (svc == null || _quitando != null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Quitar app de la Tienda',
          style: TextStyle(
            color: AppColors.textHi,
            fontSize: kFont,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'Se quitará "${it.name}" de este usuario de Windows. '
          'Podrás volver a instalarla desde la Tienda.',
          style: const TextStyle(
            color: AppColors.textMid,
            fontSize: kFont,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Quitar',
              style: TextStyle(
                color: AppColors.accent,
                fontSize: kFont,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _quitando = it.package;
      _falloQuitar = '';
    });
    try {
      await svc.quitaTienda(it.package);
      if (!mounted) return;
      setState(() {
        _quitadas.add(it.package);
        _quitando = null;
      });
    } on BackendError catch (e) {
      if (!mounted) return;
      setState(() {
        _quitando = null;
        _falloQuitar = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final usuario = _filtra(d.delUsuario);
    final sistema = _verSistema
        ? _filtra(d.delSistema)
        : const <SoftwareItem>[];
    Widget fila(SoftwareItem e) => _Fila(
      item: e,
      quitando: _quitando != null && _quitando == e.package,
      onQuitar: (widget.service != null && e.sePuedeQuitar && _quitando == null)
          ? () => _quitar(e)
          : null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _barra(d),
              if (d.reason.isNotEmpty) ...[
                const SizedBox(height: 14),
                _aviso(d.reason),
              ],
              if (_falloQuitar.isNotEmpty) ...[
                const SizedBox(height: 14),
                _aviso(_falloQuitar),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: (usuario.isEmpty && sistema.isEmpty)
              ? _vacio(d)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    if (usuario.isNotEmpty) ...[
                      _grupo(
                        d.tituloUsuario,
                        usuario.length,
                        Icons.person_rounded,
                        AppColors.accent,
                      ),
                      ...usuario.map(fila),
                    ],
                    if (sistema.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _grupo(
                        d.tituloSistema,
                        sistema.length,
                        Icons.settings_suggest_rounded,
                        AppColors.textMid,
                      ),
                      ...sistema.map(fila),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  List<SoftwareItem> _filtra(List<SoftwareItem> items) {
    final vivos = items
        .where((e) => !_quitadas.contains(e.package) || e.package.isEmpty)
        .toList();
    if (_busca.isEmpty) return vivos;
    final q = _busca.toLowerCase();
    return vivos.where((e) => e.buscable.contains(q)).toList();
  }

  // ---- Barra superior: contador, buscador e interruptor ----

  Widget _barra(SoftwareInfo d) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.apps_rounded, size: 18, color: AppColors.textMid),
          const SizedBox(width: 10),
          Text(
            '${d.delUsuario.length} ${d.tituloUsuario.toLowerCase()} · '
            '${d.delSistema.length} del sistema',
            style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
          ),
          const SizedBox(width: 18),
          Expanded(child: _buscador()),
          const SizedBox(width: 14),
          _interruptorSistema(),
        ],
      ),
    );
  }

  Widget _buscador() {
    return SizedBox(
      height: 34,
      child: TextField(
        style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
        cursorColor: AppColors.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AppColors.surfaceAlt,
          hintText: 'Buscar programa, fabricante o versión…',
          hintStyle: const TextStyle(color: AppColors.textLow, fontSize: kFont),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 17,
            color: AppColors.textLow,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 34,
            minHeight: 34,
          ),
          contentPadding: const EdgeInsets.symmetric(
            vertical: 8,
            horizontal: 6,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.accentDim),
          ),
        ),
        onChanged: (v) => setState(() => _busca = v.trim()),
      ),
    );
  }

  Widget _interruptorSistema() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.scale(
          scale: 0.8,
          child: Switch(
            value: _verSistema,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => setState(() => _verSistema = v),
          ),
        ),
        const Text(
          'Ver lo del sistema',
          style: TextStyle(color: AppColors.textMid, fontSize: kFont),
        ),
      ],
    );
  }

  Widget _grupo(String titulo, int cuantos, IconData icono, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        children: [
          Icon(icono, size: 17, color: color),
          const SizedBox(width: 8),
          Text(
            titulo,
            style: TextStyle(
              color: color,
              fontSize: kFont,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '($cuantos)',
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }

  Widget _aviso(String texto) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: _ambar.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _ambar.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 17, color: _ambar),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              texto,
              style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
            ),
          ),
        ],
      ),
    );
  }

  Widget _vacio(SoftwareInfo d) {
    final texto = _busca.isNotEmpty
        ? 'Ningún programa coincide con "$_busca".'
        : d.available
        ? 'No se encontró ningún programa instalado.'
        : 'No se pudo leer la lista de programas instalados.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          texto,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
        ),
      ),
    );
  }
}

/// Una fila de la lista: nombre + versión bien visibles, y el resto (fabricante,
/// fecha, tamaño, origen del dato) como detalle secundario.
class _Fila extends StatelessWidget {
  final SoftwareItem item;
  final VoidCallback? onQuitar;
  final bool quitando;
  const _Fila({required this.item, this.onQuitar, this.quitando = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  item.name,
                  style: const TextStyle(
                    color: AppColors.textHi,
                    fontSize: kFont,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_secundario.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _secundario,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLow,
                        fontSize: kFont,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: SelectableText(
              item.versionVisible,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: kFont,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (item.sePuedeQuitar) ...[
            const SizedBox(width: 8),
            quitando
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Quitar app',
                    visualDensity: VisualDensity.compact,
                    onPressed: onQuitar,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  ),
          ],
        ],
      ),
    );
  }

  /// Línea de detalle: solo lo que se sabe, sin huecos ni separadores sueltos.
  String get _secundario {
    final partes = <String>[
      if (item.publisher.isNotEmpty) item.publisher,
      if (item.installed.isNotEmpty) 'instalado el ${item.installed}',
      if (item.sizeMB > 0) '${item.sizeMB} MB',
      if (item.arch.isNotEmpty) item.arch,
      SoftwareKind.etiqueta(item.kind),
    ];
    return partes.join(' · ');
  }
}
