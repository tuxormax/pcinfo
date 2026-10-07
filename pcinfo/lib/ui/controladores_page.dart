import 'dart:io' show Platform;
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/controladores.dart';
import '../services/backend_http.dart';
import '../services/controladores_service.dart';
import '../theme.dart';

/// Ámbar de "ojo con esto" (mismo tono que los avisos del resto de la app).
const _ambar = Color(0xFFE3A84B);
const _rojo = Color(0xFFF2768D);

/// Pestaña "Controladores": respaldar y restaurar los controladores de terceros
/// y las redes WiFi guardadas del equipo.
///
/// Es la ÚNICA pantalla de PCInfo que modifica el equipo, y eso marca su diseño:
///   - Restaurar pide confirmación explícita diciendo qué va a pasar.
///   - La carpeta SIEMPRE se elige a mano (un respaldo suele ir a una USB para
///     llevarlo a otro equipo, no a Documentos).
///   - El avance se muestra línea a línea: exportar los controladores tarda
///     minutos y sin eso la app parecería colgada.
class ControladoresPage extends StatefulWidget {
  final ControladoresInfo data;
  final ControladoresService service;

  /// Botón opcional que acompaña al aviso de "hace falta administrador"
  /// (Windows). Lo aporta el dashboard, que es quien sabe elevar el backend.
  final Widget? avisoAccion;

  /// Se llama al terminar una restauración: el inventario cambió y hay que
  /// volver a pedirlo.
  final VoidCallback? onRecargar;

  const ControladoresPage({
    super.key,
    required this.data,
    required this.service,
    this.avisoAccion,
    this.onRecargar,
  });

  @override
  State<ControladoresPage> createState() => _ControladoresPageState();
}

class _ControladoresPageState extends State<ControladoresPage> {
  /// Tarea en curso o la última que terminó. null = todavía no hubo ninguna.
  TareaInfo? _tarea;

  /// Sondeo del avance mientras la tarea corre.
  Timer? _reloj;

  /// Mensaje de fallo al arrancar la tarea (el backend se negó).
  String _fallo = '';

  /// ¿Se mostrarán las contraseñas de las redes en pantalla?
  bool _verClaves = false;

  /// Controladores del catálogo del fabricante que el usuario DESMARCÓ. Se
  /// guarda lo desmarcado (no lo marcado) para que lo recomendado salga marcado
  /// sin inicializar nada; lo no recomendado se guarda como marcado a mano.
  final Set<String> _desmarcados = {};
  final Set<String> _marcadosAMano = {};

  bool _marcado(CandidatoWeb c) => c.recomendado
      ? !_desmarcados.contains(c.id)
      : _marcadosAMano.contains(c.id);

  @override
  void dispose() {
    _reloj?.cancel();
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
          if (!d.elevated) ...[
            _avisoAdmin(d),
            const SizedBox(height: 14),
          ] else if (d.reason.isNotEmpty) ...[
            _caja(_ambar, Icons.info_outline_rounded, d.reason),
            const SizedBox(height: 14),
          ],
          if (_fallo.isNotEmpty) ...[
            _caja(_rojo, Icons.error_outline_rounded, _fallo),
            const SizedBox(height: 14),
          ],
          if (_tarea != null && _tarea!.existe) ...[
            _panelTarea(_tarea!),
            const SizedBox(height: 14),
          ],
          // Va PRIMERA, aunque sea la única tarjeta que no hace nada: es la
          // pregunta con la que el usuario abre esta pestaña ("¿por qué me sale
          // un dispositivo sin controlador?"), y además es lo único que
          // funciona sin administrador.
          if (d.available && d.driversAplica) ...[
            _tarjetaPendientes(d),
            const SizedBox(height: 14),
          ],
          if (d.available && d.driversAplica) ...[
            _tarjetaWeb(d),
            const SizedBox(height: 14),
          ],
          if (d.driversAplica) ...[
            _tarjetaControladores(d),
            const SizedBox(height: 14),
          ],
          _tarjetaWifi(d),
        ],
      ),
    );
  }

  // ---- Estados especiales ----

  Widget _noDisponible(ControladoresInfo d) {
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

  Widget _avisoAdmin(ControladoresInfo d) {
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
          const Icon(
            Icons.admin_panel_settings_rounded,
            size: 18,
            color: _ambar,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              d.reason.isEmpty
                  ? 'Respaldar y restaurar controladores y redes WiFi necesita permisos '
                        'de administrador.'
                  : d.reason,
              style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
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
            child: SelectableText(
              texto,
              style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Tarjeta de dispositivos sin controlador (solo lectura) ----

  /// Dispositivos que Windows marca con un problema, con la explicación del
  /// catálogo cuando el caso se reconoce.
  ///
  /// NO tiene botones a propósito: aquí no se instala nada. Es la contraparte
  /// informativa del "triángulo amarillo" del Administrador de dispositivos,
  /// que en un equipo bien atendido suele ser algo que se dejó así a conciencia.
  Widget _tarjetaPendientes(ControladoresInfo d) {
    final explicados = d.pendientesExplicados.length;
    final subtitulo = d.pendientes.isEmpty
        ? 'Ningún dispositivo del equipo está sin controlador'
        : '${d.pendientes.length} con aviso'
              '${explicados > 0 ? ' · $explicados con explicación' : ''}';

    return _Tarjeta(
      icono: Icons.help_outline_rounded,
      color: AppColors.gpu,
      titulo: 'Dispositivos sin controlador',
      subtitulo: subtitulo,
      acciones: const [],
      hijo: d.pendientes.isEmpty
          ? _nota(
              'Windows no marca ningún dispositivo como sin controlador, '
              'deshabilitado ni detenido.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _nota(
                  'Esta lista solo informa: PCInfo no instala ni quita '
                  'nada. Varios de estos avisos son normales porque el '
                  'componente se dejó así a propósito.',
                ),
                const SizedBox(height: 10),
                ...d.pendientes.map(_filaPendiente),
              ],
            ),
    );
  }

  Widget _filaPendiente(DispositivoPendiente p) {
    final caso = p.conocido;
    final detalle = <String>[
      if (p.clase.isNotEmpty) p.clase,
      p.estado,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            p.nombre,
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: kFont,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            detalle,
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
          ),
          if (p.hardwareId.isNotEmpty)
            SelectableText(
              p.hardwareId,
              style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
            ),
          if (caso != null) ...[const SizedBox(height: 6), _explicacion(caso)],
        ],
      ),
    );
  }

  Widget _explicacion(CasoConocido caso) {
    final color = caso.intencional ? AppColors.accent : _ambar;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                caso.intencional
                    ? Icons.verified_outlined
                    : Icons.build_outlined,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${caso.titular} — ${caso.nombre}',
                  style: TextStyle(
                    color: color,
                    fontSize: kFont,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            caso.descripcion,
            style: const TextStyle(
              color: AppColors.textMid,
              fontSize: kFont,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            caso.motivo,
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: kFont,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // ---- Tarjeta de controladores ----

  Widget _tarjetaWeb(ControladoresInfo d) {
    final elegidos = d.web.where(_marcado).toList();
    return _Tarjeta(
      icono: Icons.cloud_download_rounded,
      color: AppColors.accent,
      titulo: 'Controladores del fabricante',
      subtitulo: d.web.isEmpty
          ? 'Sin coincidencias en el catálogo'
          : '${d.web.length} disponibles para dispositivos sin controlador',
      acciones: [
        if (d.web.isNotEmpty)
          _boton(
            'Descargar e instalar (${elegidos.length})',
            Icons.cloud_download_rounded,
            elegidos.isEmpty ? () {} : () => _descargar(elegidos),
          ),
      ],
      hijo: d.web.isEmpty
          ? _nota(
              d.pendientes.isEmpty
                  ? 'No hay dispositivos sin controlador que buscar.'
                  : 'El catálogo del fabricante no tiene un controlador para '
                        'ninguno de los dispositivos sin controlador de este equipo.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _nota(
                  'Se descargan del sitio del fabricante, se verifica que '
                  'el archivo sea el del catálogo y se instalan. No usa '
                  'Windows Update. Marca solo los que quieras instalar.',
                ),
                const SizedBox(height: 8),
                ...d.web.map(_filaWeb),
              ],
            ),
    );
  }

  Widget _filaWeb(CandidatoWeb c) {
    final detalle = <String>[
      if (c.fabricante.isNotEmpty) c.fabricante,
      if (c.version.isNotEmpty) 'versión ${c.version}',
      'para: ${c.dispositivo}',
    ].join(' · ');
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: AppColors.accent,
      value: _marcado(c),
      onChanged: (v) => setState(() {
        final on = v ?? false;
        if (c.recomendado) {
          on ? _desmarcados.remove(c.id) : _desmarcados.add(c.id);
        } else {
          on ? _marcadosAMano.add(c.id) : _marcadosAMano.remove(c.id);
        }
      }),
      title: Text(
        c.nombre,
        style: const TextStyle(
          color: AppColors.textHi,
          fontSize: kFont,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detalle,
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
          ),
          if (c.nota.isNotEmpty)
            Text(
              c.nota,
              style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
          if (c.aviso.isNotEmpty)
            Text(
              c.aviso,
              style: const TextStyle(color: _ambar, fontSize: kFont),
            ),
        ],
      ),
    );
  }

  Future<void> _descargar(List<CandidatoWeb> elegidos) async {
    setState(() => _fallo = '');
    final aProposito = elegidos.where((c) => !c.recomendado).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Descargar e instalar controladores',
          style: TextStyle(
            color: AppColors.textHi,
            fontSize: kFont,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'Se descargarán e instalarán ${elegidos.length} controlador(es) '
          'del sitio del fabricante.'
          '${aProposito > 0 ? '\n\nOJO: $aProposito de ellos se habían dejado sin controlador a propósito; instalarlos puede deshacer ese ajuste.' : ''}'
          '\n\nPuede pedir reiniciar al terminar.',
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
              'Instalar',
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
    try {
      final t = await widget.service.descarga(
        elegidos.map((c) => c.id).toList(),
      );
      if (!mounted) return;
      setState(() => _tarea = t);
      _sondea();
    } on BackendError catch (e) {
      if (!mounted) return;
      setState(() => _fallo = e.toString());
    }
  }

  Widget _tarjetaControladores(ControladoresInfo d) {
    return _Tarjeta(
      icono: Icons.settings_input_component_rounded,
      color: AppColors.board,
      titulo: 'Controladores del equipo',
      subtitulo: d.drivers.isEmpty
          ? 'No se encontraron controladores de terceros'
          : '${d.drivers.length} controladores de terceros instalados',
      acciones: [
        _boton(
          'Respaldar controladores',
          Icons.download_rounded,
          () => _operacion(TareaKind.respaldar, drivers: true, wifi: false),
        ),
        _boton(
          'Restaurar controladores',
          Icons.upload_rounded,
          () => _operacion(TareaKind.restaurar, drivers: true, wifi: false),
        ),
      ],
      hijo: d.drivers.isEmpty
          ? _nota(
              d.elevated
                  ? 'Windows no reporta controladores de terceros: los que usa el equipo '
                        'vienen en la propia imagen del sistema y no hace falta respaldarlos.'
                  : 'La lista aparecerá al ejecutar PCInfo como administrador.',
            )
          : Column(children: d.drivers.map(_filaDriver).toList()),
    );
  }

  Widget _filaDriver(DriverItem c) {
    final detalle = <String>[
      if (c.provider.isNotEmpty) c.provider,
      if (c.clase.isNotEmpty) c.clase,
      if (c.version.isNotEmpty) 'v${c.version}',
      if (c.date.isNotEmpty) c.date,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  c.visible,
                  style: const TextStyle(
                    color: AppColors.textHi,
                    fontSize: kFont,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detalle.isNotEmpty)
                  Text(
                    detalle,
                    style: const TextStyle(
                      color: AppColors.textLow,
                      fontSize: kFont,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            c.name,
            style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
          ),
        ],
      ),
    );
  }

  // ---- Tarjeta de redes WiFi ----

  Widget _tarjetaWifi(ControladoresInfo d) {
    return _Tarjeta(
      icono: Icons.wifi_rounded,
      color: AppColors.ram,
      titulo: 'Redes WiFi guardadas',
      subtitulo: d.wifi.isEmpty
          ? 'No hay redes guardadas en este equipo'
          : '${d.wifi.length} redes guardadas',
      acciones: [
        _boton(
          'Respaldar redes WiFi',
          Icons.download_rounded,
          () => _operacion(TareaKind.respaldar, drivers: false, wifi: true),
        ),
        _boton(
          'Restaurar redes WiFi',
          Icons.upload_rounded,
          () => _operacion(TareaKind.restaurar, drivers: false, wifi: true),
        ),
      ],
      hijo: d.wifi.isEmpty
          ? _nota(
              'Aparecerán aquí en cuanto el equipo se conecte a alguna red '
              'inalámbrica.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _caja(
                  _ambar,
                  Icons.lock_open_rounded,
                  'El respaldo guarda las contraseñas en texto legible dentro de los '
                  'archivos .xml: cualquiera que llegue a esa carpeta puede leerlas. '
                  'Es lo único que permite restaurar las redes en otro equipo sin '
                  'teclearlas.',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: _verClaves,
                        activeThumbColor: AppColors.accent,
                        onChanged: (v) => setState(() => _verClaves = v),
                      ),
                    ),
                    const Text(
                      'Ver contraseñas',
                      style: TextStyle(
                        color: AppColors.textMid,
                        fontSize: kFont,
                      ),
                    ),
                  ],
                ),
                ...d.wifi.map(_filaWifi),
              ],
            ),
    );
  }

  Widget _filaWifi(WifiProfile r) {
    final clave = r.abierta
        ? 'red abierta'
        : r.password.isEmpty
        ? 'no se pudo leer'
        : _verClaves
        ? r.password
        : '••••••••';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: SelectableText(
              r.name,
              style: const TextStyle(
                color: AppColors.textHi,
                fontSize: kFont,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              r.auth,
              style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
            ),
          ),
          Expanded(
            flex: 3,
            child: SelectableText(
              clave,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: _verClaves && r.password.isNotEmpty
                    ? AppColors.accent
                    : AppColors.textMid,
                fontSize: kFont,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _nota(String texto) => Text(
    texto,
    style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
  );

  // ---- Panel de avance ----

  Widget _panelTarea(TareaInfo t) {
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
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                )
              else
                Icon(
                  t.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                  size: 18,
                  color: color,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.running
                      ? '${t.verbo} en curso — ${t.folder}'
                      : t.ok
                      ? t.summary
                      : (t.error.isEmpty ? 'La operación falló.' : t.error),
                  style: TextStyle(
                    color: color,
                    fontSize: kFont,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (t.running)
                TextButton(
                  onPressed: _cancela,
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: AppColors.textMid, fontSize: kFont),
                  ),
                ),
            ],
          ),
          if (t.steps.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: SelectableText(
                t.steps
                    .map(
                      (p) => p.when.isEmpty ? p.text : '${p.when}  ${p.text}',
                    )
                    .join('\n'),
                style: const TextStyle(
                  color: AppColors.textMid,
                  fontSize: kFont,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Acciones ----

  Widget _boton(String texto, IconData icono, VoidCallback accion) {
    final corriendo = _tarea?.running ?? false;
    final habilitado = widget.data.puedeOperar && !corriendo;
    return Material(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: habilitado ? accion : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icono,
                size: 16,
                color: habilitado ? AppColors.textMid : AppColors.textLow,
              ),
              const SizedBox(width: 7),
              Text(
                texto,
                style: TextStyle(
                  color: habilitado ? AppColors.textMid : AppColors.textLow,
                  fontSize: kFont,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Flujo completo de una operación: elegir carpeta → confirmar → arrancar la
  /// tarea → sondear el avance.
  Future<void> _operacion(
    String kind, {
    required bool drivers,
    required bool wifi,
  }) async {
    setState(() => _fallo = '');

    final restaurar = kind == TareaKind.restaurar;
    final carpeta = await getDirectoryPath(
      confirmButtonText: restaurar ? 'Restaurar desde aquí' : 'Respaldar aquí',
    );
    if (carpeta == null || !mounted) return; // el usuario cerró el selector

    if (!await _confirma(kind, carpeta, drivers: drivers, wifi: wifi)) return;

    try {
      final t = await widget.service.inicia(
        kind: kind,
        carpeta: carpeta,
        drivers: drivers,
        wifi: wifi,
      );
      if (!mounted) return;
      setState(() => _tarea = t);
      _sondea();
    } on BackendError catch (e) {
      if (!mounted) return;
      setState(() => _fallo = e.toString());
    }
  }

  /// Confirmación previa. Restaurar toca el equipo de verdad, así que dice con
  /// todas sus letras qué va a pasar antes de hacerlo.
  Future<bool> _confirma(
    String kind,
    String carpeta, {
    required bool drivers,
    required bool wifi,
  }) async {
    final que = drivers ? 'los controladores' : 'las redes WiFi';
    final restaurar = kind == TareaKind.restaurar;
    final sub = drivers ? CarpetaRespaldo.drivers : CarpetaRespaldo.wifi;
    final sep = Platform.isWindows ? '\\' : '/';

    final texto = restaurar
        ? (drivers
              ? 'Se instalarán en ESTE equipo los controladores guardados en '
                    '$carpeta$sep$sub.\n\nLos que no correspondan a este hardware Windows '
                    'los rechazará solo. Puede pedir reiniciar al terminar.'
              : 'Se añadirán a ESTE equipo las redes WiFi guardadas en '
                    '$carpeta$sep$sub.\n\nLas redes que ya existan se sobrescribirán con '
                    'las del respaldo.')
        : (drivers
              ? 'Se copiarán los controladores instalados a $carpeta$sep$sub.\n\n'
                    'Puede tardar varios minutos y ocupar bastante espacio.'
              : 'Se copiarán las redes WiFi guardadas a $carpeta$sep$sub.\n\n'
                    'Los archivos incluirán las contraseñas en texto legible.');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          restaurar ? 'Restaurar $que' : 'Respaldar $que',
          style: const TextStyle(
            color: AppColors.textHi,
            fontSize: kFont,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          texto,
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
            child: Text(
              restaurar ? 'Restaurar' : 'Respaldar',
              style: TextStyle(
                color: restaurar ? _ambar : AppColors.accent,
                fontSize: kFont,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Pregunta el avance cada segundo mientras la tarea corre.
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
          // Restaurar cambia el inventario (controladores nuevos, redes nuevas):
          // hay que volver a pedirlo para no dejar en pantalla lo de antes.
          if ((info.kind == TareaKind.restaurar ||
                  info.kind == TareaKind.descargar) &&
              info.ok) {
            widget.onRecargar?.call();
          }
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
}

/// Tarjeta con encabezado, botones de acción y contenido.
class _Tarjeta extends StatelessWidget {
  final IconData icono;
  final Color color;
  final String titulo;
  final String subtitulo;
  final List<Widget> acciones;
  final Widget hijo;

  const _Tarjeta({
    required this.icono,
    required this.color,
    required this.titulo,
    required this.subtitulo,
    required this.acciones,
    required this.hijo,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icono, color: color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: kFont,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        subtitulo,
                        style: const TextStyle(
                          color: AppColors.textLow,
                          fontSize: kFont,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Wrap(spacing: 8, children: acciones),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 12),
          hijo,
        ],
      ),
    );
  }
}
