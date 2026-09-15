import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/tienda.dart';
import '../services/backend_http.dart';
import '../services/tienda_service.dart';
import '../theme.dart';

const _ambar = Color(0xFFE3A84B);
const _rojo = Color(0xFFF2768D);

/// Pestaña "Tienda Windows": instala apps de la Microsoft Store SIN abrir la
/// Store, desde un catálogo curado, el buscador de la Store o un enlace /
/// ProductId pegado a mano.
///
/// Portada de la herramienta suelta `windows/mitiendawindows` (WinForms) al
/// mismo patrón de Controladores: escribe en el sistema, necesita
/// administrador, y la instalación corre en 2º plano con avance en vivo.
///
/// ⚠️ Depende de DOS servicios de terceros fuera del control de PCInfo:
/// store.rg-adguard.net (resuelve las descargas; detrás de Cloudflare) y el
/// buscador no oficial de la Store. Si Cloudflare bloquea la petición, el
/// mensaje de error lo explica — no es un fallo de PCInfo.
class TiendaPage extends StatefulWidget {
  final TiendaInfo data;
  final TiendaService service;
  final Widget? avisoAccion;
  final VoidCallback? onRecargar;

  const TiendaPage({
    super.key,
    required this.data,
    required this.service,
    this.avisoAccion,
    this.onRecargar,
  });

  @override
  State<TiendaPage> createState() => _TiendaPageState();
}

class _TiendaPageState extends State<TiendaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  // Cola de apps a instalar (evita duplicados por ProductId).
  final List<AppTienda> _cola = [];

  // Catálogo: qué está marcado.
  final Set<int> _marcadosCatalogo = {};

  // Buscador.
  final _buscarCtrl = TextEditingController();
  List<AppTienda> _resultados = const [];
  bool _buscando = false;
  String _falloBusqueda = '';

  // Enlace / ProductId.
  final _enlaceCtrl = TextEditingController();
  String _falloEnlace = '';

  // Opciones.
  String _arch = TiendaArch.opciones.first;
  String _ring = TiendaRing.opciones.first;
  bool _todosLosUsuarios = true;

  // Tarea en curso.
  TareaTiendaInfo? _tarea;
  Timer? _reloj;
  String _fallo = '';

  @override
  void dispose() {
    _reloj?.cancel();
    _buscarCtrl.dispose();
    _enlaceCtrl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    if (!d.supported) return _noDisponible(d);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!d.elevated) ...[_avisoAdmin(d), const SizedBox(height: 14)],
          if (_fallo.isNotEmpty) ...[
            _caja(_rojo, Icons.error_outline_rounded, _fallo),
            const SizedBox(height: 14),
          ],
          _tarjetaTerceros(),
          const SizedBox(height: 14),
          _tarjetaOrigen(d),
          // El avance de la instalación va DEBAJO de las pestañas, no antes:
          // la cola de apps ya se ve arriba (en el panel de opciones de cada
          // pestaña), así que aquí solo hace falta el registro de la tarea.
          if (_tarea != null && _tarea!.existe) ...[
            const SizedBox(height: 14),
            _panelTarea(_tarea!),
          ],
        ],
      ),
    );
  }

  // ---- Estados especiales ----

  Widget _noDisponible(TiendaInfo d) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.block_rounded, size: 40, color: AppColors.textLow),
            const SizedBox(height: 14),
            Text(
              d.reason.isEmpty
                  ? 'Esta función solo está disponible en Windows.'
                  : d.reason,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avisoAdmin(TiendaInfo d) {
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
          const Icon(Icons.admin_panel_settings_rounded, size: 18, color: _ambar),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Instalar apps de la Tienda necesita permisos de administrador.',
              style: TextStyle(color: AppColors.textHi, fontSize: kFont),
            ),
          ),
          if (widget.avisoAccion != null) ...[
            const SizedBox(width: 12),
            widget.avisoAccion!,
          ],
        ],
      ),
    );
  }

  Widget _caja(Color color, IconData icono, String texto) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(texto,
                style: const TextStyle(color: AppColors.textHi, fontSize: kFont)),
          ),
        ],
      ),
    );
  }

  Widget _tarjetaTerceros() => _caja(
        AppColors.textLow,
        Icons.info_outline_rounded,
        'Los paquetes los sirve Microsoft; los enlaces de descarga los resuelve '
        'store.rg-adguard.net (terceros, solo recibe el ProductId) y el '
        'buscador usa la API de la Store (también de terceros). Si Cloudflare '
        'bloquea la petición, el error lo explica: no es un fallo de PCInfo.',
      );

  // ---- Tarjeta de origen: Catálogo / Buscar / Enlace ----

  Widget _tarjetaOrigen(TiendaInfo d) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            controller: _tabs,
            labelColor: AppColors.accent,
            unselectedLabelColor: AppColors.textMid,
            indicatorColor: AppColors.accent,
            labelStyle: const TextStyle(fontSize: kFont, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(text: 'Catálogo'),
              Tab(text: 'Buscar en la Tienda'),
              Tab(text: 'Enlace o ProductId'),
            ],
          ),
          const Divider(color: AppColors.border, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: SizedBox(
              height: 400,
              child: TabBarView(
                controller: _tabs,
                children: [
                  _panelCatalogo(d),
                  _panelBuscar(),
                  _panelEnlace(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelCatalogo(TiendaInfo d) {
    if (d.catalogo.isEmpty) {
      return _nota('El catálogo llegó vacío.');
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Izquierda: la lista (60%).
        Expanded(
          flex: 6,
          child: ListView.builder(
            itemCount: d.catalogo.length,
            itemBuilder: (context, i) {
              final app = d.catalogo[i];
              final marcado = _marcadosCatalogo.contains(i);
              // Material propio: sin él, el ripple del checkbox pinta sobre el
              // fondo de la tarjeta (DecoratedBox) y Flutter avisa en debug
              // que la tinta queda invisible.
              return Material(
                type: MaterialType.transparency,
                child: CheckboxListTile(
                  dense: true,
                  value: marcado,
                  activeColor: AppColors.accent,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(app.nombre,
                      style: const TextStyle(
                          color: AppColors.textHi, fontSize: kFont)),
                  onChanged: (v) => setState(() {
                    if (v ?? false) {
                      _marcadosCatalogo.add(i);
                    } else {
                      _marcadosCatalogo.remove(i);
                    }
                  }),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 18),
        VerticalDivider(color: AppColors.border, width: 1),
        const SizedBox(width: 18),
        // Derecha: opciones e instalar (40%).
        Expanded(flex: 4, child: _panelCatalogoOpciones(d)),
      ],
    );
  }

  Widget _panelCatalogoOpciones(TiendaInfo d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Arquitectura',
            style: TextStyle(color: AppColors.textLow, fontSize: kFont)),
        const SizedBox(height: 4),
        _dropdown(_arch, TiendaArch.opciones, (v) => setState(() => _arch = v)),
        const SizedBox(height: 14),
        const Text('Canal',
            style: TextStyle(color: AppColors.textLow, fontSize: kFont)),
        const SizedBox(height: 4),
        _dropdown(_ring, TiendaRing.opciones, (v) => setState(() => _ring = v)),
        const SizedBox(height: 14),
        Row(
          children: [
            Transform.scale(
              scale: 0.8,
              alignment: Alignment.centerLeft,
              child: Switch(
                value: _todosLosUsuarios,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => setState(() => _todosLosUsuarios = v),
              ),
            ),
            const Expanded(
              child: Text('Todos los usuarios',
                  style: TextStyle(color: AppColors.textMid, fontSize: kFont)),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (_marcadosCatalogo.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${_marcadosCatalogo.length} seleccionada(s)',
                style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
          ),
        SizedBox(
          width: double.infinity,
          child: _botonPrincipal(
            'Instalar todo',
            Icons.download_rounded,
            (widget.data.puedeOperar && !_instalando && _marcadosCatalogo.isNotEmpty)
                ? () => _instalarCatalogoMarcado(d)
                : null,
          ),
        ),
        const SizedBox(height: 15),
        SizedBox(
          width: double.infinity,
          child: _boton('Instalar desde carpeta…', Icons.folder_open_rounded,
              _instalando ? null : _instalarDesdeCarpeta),
        ),
      ],
    );
  }

  Future<void> _instalarCatalogoMarcado(TiendaInfo d) async {
    for (final i in _marcadosCatalogo) {
      _agregarACola(d.catalogo[i]);
    }
    setState(_marcadosCatalogo.clear);
    await _instalarCola();
  }

  Widget _panelBuscar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _buscarCtrl,
                style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
                decoration: const InputDecoration(
                  hintText: 'Nombre de la app…',
                  hintStyle: TextStyle(color: AppColors.textLow),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _buscar(),
              ),
            ),
            const SizedBox(width: 15),
            _boton('Buscar', Icons.search_rounded, _buscando ? null : _buscar),
          ],
        ),
        const SizedBox(height: 10),
        if (_falloBusqueda.isNotEmpty) ...[
          _caja(_rojo, Icons.error_outline_rounded, _falloBusqueda),
          const SizedBox(height: 10),
        ],
        Expanded(
          child: _buscando
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.accent))
              : _resultados.isEmpty
                  ? _nota('Escribe un nombre y pulsa Buscar.')
                  : ListView.builder(
                      itemCount: _resultados.length,
                      itemBuilder: (context, i) {
                        final app = _resultados[i];
                        return Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                            dense: true,
                            title: Text(app.nombre,
                                style: const TextStyle(
                                    color: AppColors.textHi, fontSize: kFont)),
                            trailing: _boton('Instalar', Icons.download_rounded,
                                _instalando ? null : () => _instalarUna(app)),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _panelEnlace() {
    final id = extraeProductId(_enlaceCtrl.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _enlaceCtrl,
          style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
          decoration: const InputDecoration(
            hintText: 'Enlace de la app o ProductId…',
            hintStyle: TextStyle(color: AppColors.textLow),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _instalarDesdeEnlace(),
        ),
        const SizedBox(height: 6),
        Text(
          'Ej: https://apps.microsoft.com/detail/9WZDNCRFHVJL — también vale '
          'solo el ProductId.',
          style: const TextStyle(color: AppColors.textLow, fontSize: kFont - 1),
        ),
        const SizedBox(height: 15),
        if (_falloEnlace.isNotEmpty) ...[
          _caja(_rojo, Icons.error_outline_rounded, _falloEnlace),
          const SizedBox(height: 15),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: _boton('Instalar', Icons.download_rounded,
              (id == null || _instalando) ? null : _instalarDesdeEnlace),
        ),
      ],
    );
  }

  Future<void> _buscar() async {
    final q = _buscarCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _buscando = true;
      _falloBusqueda = '';
      _resultados = const [];
    });
    try {
      final r = await widget.service.buscar(q);
      if (!mounted) return;
      setState(() => _resultados = r);
    } on BackendError catch (e) {
      if (!mounted) return;
      setState(() => _falloBusqueda = e.toString());
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }

  Future<void> _instalarDesdeEnlace() async {
    final id = extraeProductId(_enlaceCtrl.text);
    if (id == null) {
      setState(() => _falloEnlace = 'No se reconoció ningún ProductId ahí.');
      return;
    }
    setState(() => _falloEnlace = '');
    await _instalarUna(AppTienda(nombre: id, productId: id));
    _enlaceCtrl.clear();
  }

  /// Instala una sola app de un jalón (Buscar y Enlace no arman lista: cada
  /// resultado tiene su propio botón "Instalar" y se instalan una por una).
  Future<void> _instalarUna(AppTienda app) async {
    if (!await _confirma('Se instalará "${app.nombre}" en ESTE equipo, '
        'descargándola de los servidores de Microsoft.')) {
      return;
    }
    await _arrancaInstalacion(apps: [app]);
  }

  void _agregarACola(AppTienda app) {
    if (_cola.any((a) => a.productId == app.productId)) return;
    setState(() => _cola.add(app));
  }

  // ---- Tarjeta de la cola ----

  bool get _instalando => _tarea?.running ?? false;

  Widget _dropdown(String valor, List<String> opciones, void Function(String) onCambia) {
    return DropdownButton<String>(
      value: valor,
      dropdownColor: AppColors.surfaceAlt,
      style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
      underline: Container(height: 1, color: AppColors.border),
      items: opciones
          .map((o) => DropdownMenuItem(value: o, child: Text(o)))
          .toList(),
      onChanged: (v) {
        if (v != null) onCambia(v);
      },
    );
  }

  Future<void> _instalarCola() async {
    if (!await _confirma('Se instalarán ${_cola.length} app(s) en ESTE equipo, '
        'descargándolas de los servidores de Microsoft.')) {
      return;
    }
    await _arrancaInstalacion(apps: List.of(_cola));
  }

  Future<void> _instalarDesdeCarpeta() async {
    final carpeta = await getDirectoryPath(
      confirmButtonText: 'Instalar desde aquí',
    );
    if (carpeta == null || !mounted) return;
    if (!await _confirma(
        'Se instalarán los paquetes .appx/.msix que haya en:\n$carpeta')) {
      return;
    }
    await _arrancaInstalacion(carpeta: carpeta);
  }

  Future<bool> _confirma(String texto) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Instalar apps de la Tienda',
            style: TextStyle(
                color: AppColors.textHi, fontSize: kFont, fontWeight: FontWeight.w700)),
        content: Text(texto,
            style: const TextStyle(
                color: AppColors.textMid, fontSize: kFont, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar',
                style: TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Instalar',
                style: TextStyle(
                    color: AppColors.accent, fontSize: kFont, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _arrancaInstalacion({
    List<AppTienda> apps = const [],
    String? carpeta,
  }) async {
    setState(() => _fallo = '');
    try {
      final t = await widget.service.instala(
        apps: apps,
        carpeta: carpeta,
        arch: _arch,
        ring: _ring,
        todos: _todosLosUsuarios,
      );
      if (!mounted) return;
      setState(() {
        _tarea = t;
        if (apps.isNotEmpty) _cola.clear();
      });
      _sondea();
    } on BackendError catch (e) {
      if (!mounted) return;
      setState(() => _fallo = e.toString());
    }
  }

  void _sondea() {
    _reloj?.cancel();
    _reloj = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      try {
        final info = await widget.service.tarea();
        if (!mounted) return;
        setState(() => _tarea = info);
        if (!info.running) {
          t.cancel();
          if (info.ok) widget.onRecargar?.call();
        }
      } on BackendError catch (e) {
        t.cancel();
        if (!mounted) return;
        setState(() => _fallo = e.toString());
      }
    });
  }

  Future<void> _cancela() async {
    try {
      await widget.service.cancela();
    } on BackendError catch (e) {
      if (!mounted) return;
      setState(() => _fallo = e.toString());
    }
  }

  // ---- Panel de avance ----

  Widget _panelTarea(TareaTiendaInfo t) {
    final color = t.running
        ? AppColors.accent
        : t.ok
            ? AppColors.accent
            : _rojo;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (t.running)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accent),
                )
              else
                Icon(t.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                    size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.running
                      ? 'Instalando…'
                      : t.ok
                          ? t.summary
                          : (t.error.isEmpty ? 'La instalación falló.' : t.error),
                  style: TextStyle(
                      color: color, fontSize: kFont, fontWeight: FontWeight.w600),
                ),
              ),
              if (t.running)
                TextButton(
                  onPressed: _cancela,
                  child: const Text('Cancelar',
                      style: TextStyle(color: AppColors.textMid, fontSize: kFont)),
                ),
            ],
          ),
          if (t.steps.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  t.steps
                      .map((p) => p.when.isEmpty ? p.text : '${p.when}  ${p.text}')
                      .join('\n'),
                  style: const TextStyle(
                      color: AppColors.textMid, fontSize: kFont, height: 1.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Comunes ----

  Widget _boton(String texto, IconData icono, VoidCallback? accion) {
    final habilitado = accion != null;
    return Material(
      color: AppColors.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(
            color: habilitado ? AppColors.accent : AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: accion,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono,
                  size: 16,
                  color: habilitado ? AppColors.textMid : AppColors.textLow),
              const SizedBox(width: 7),
              Text(texto,
                  style: TextStyle(
                      color: habilitado ? AppColors.textMid : AppColors.textLow,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _botonPrincipal(String texto, IconData icono, VoidCallback? accion) {
    final habilitado = accion != null;
    return FilledButton.icon(
      onPressed: accion,
      style: FilledButton.styleFrom(
        backgroundColor: habilitado ? AppColors.accentDim : AppColors.surfaceAlt,
        foregroundColor: AppColors.textHi,
        side: BorderSide(
            color: habilitado ? AppColors.accent : AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      icon: Icon(icono, size: 16),
      label: Text(texto,
          style: const TextStyle(fontSize: kFont, fontWeight: FontWeight.w600)),
    );
  }

  Widget _nota(String texto) => Center(
        child: Text(texto,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
      );
}
