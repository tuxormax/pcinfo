import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/red.dart';
import '../services/red/diagnostico_service.dart';
import '../services/red/escaner_service.dart';
import '../services/red/velocidad_service.dart';
import '../services/red_service.dart';
import '../theme.dart';
import '../version.dart';

const _ambar = Color(0xFFE3A84B);
const _rojo = Color(0xFFF2768D);

/// Pestaña "Red": diagnóstico de Internet por capas (¿hay internet y, si no,
/// de quién es la culpa?) y test de velocidad. Portado del motor de RedScan
/// (proyecto primo, pensado para móvil) a escritorio — ver
/// services/red/diagnostico_service.dart.
///
/// SOLO LECTURA: a diferencia de Controladores, esta pestaña no escribe nada
/// en el equipo ni necesita administrador.
class RedPage extends StatefulWidget {
  final RedService service;

  const RedPage({super.key, required this.service});

  @override
  State<RedPage> createState() => _RedPageState();
}

class _RedPageState extends State<RedPage> {
  RedInfo? _red;
  String _redError = '';

  final _diagSvc = DiagnosticoService();
  StreamSubscription<DiagnosticoEvento>? _diagSub;
  List<PasoDiagnostico> _pasos = const [];
  List<SaltoRuta> _ruta = const [];
  ResultadoDiagnostico? _resultado;
  double _diagProgreso = 0;
  bool _diagCorriendo = false;
  bool _diagCopiado = false;

  final _velSvc = VelocidadService();
  bool _velCorriendo = false;
  String _velFase = '';
  double? _ping;
  double? _descarga;
  double? _subida;

  final _escSvc = EscanerService();
  StreamSubscription<ProgresoEscaneo>? _escSub;
  List<Dispositivo> _equipos = const [];
  bool _escCorriendo = false;
  double _escProgreso = 0;
  String _escFase = '';

  @override
  void initState() {
    super.initState();
    _cargaRed();
  }

  void _cargaRed() {
    widget.service.load().then((v) {
      if (mounted) setState(() => _red = v);
    }).catchError((Object e) {
      if (mounted) setState(() => _redError = '$e');
    });
  }

  @override
  void dispose() {
    _diagSub?.cancel();
    _diagSvc.cancelar();
    _velSvc.cancelar();
    _escSub?.cancel();
    _escSvc.cancelar();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tarjetaRedLocal(),
          const SizedBox(height: 14),
          _tarjetaDiagnostico(),
          const SizedBox(height: 14),
          _tarjetaEscaner(),
          const SizedBox(height: 14),
          _tarjetaVelocidad(),
        ],
      ),
    );
  }

  // ---- Tarjeta de red local ----

  Widget _tarjetaRedLocal() {
    final r = _red;
    final subtitulo = r == null
        ? (_redError.isEmpty ? 'Leyendo…' : 'No se pudo leer')
        : (r.hayRed ? 'IP ${r.localIp}' : 'Sin conexión de red');
    return _Tarjeta(
      icono: Icons.lan_rounded,
      color: AppColors.ram,
      titulo: 'Esta conexión',
      subtitulo: subtitulo,
      acciones: const [],
      hijo: r == null
          ? (_redError.isEmpty
              ? _nota('Leyendo la IP local y la puerta de enlace…')
              : _caja(_rojo, Icons.error_outline_rounded, _redError))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _filaDato('IP local', r.localIp.isEmpty ? '—' : r.localIp),
                _filaDato(
                    'Puerta de enlace', r.gateway.isEmpty ? '—' : r.gateway),
                if (r.interfaceName.isNotEmpty)
                  _filaDato('Interfaz', r.interfaceName),
              ],
            ),
    );
  }

  Widget _filaDato(String etiqueta, String valor) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 155,
              child: Text(etiqueta,
                  style:
                      const TextStyle(color: AppColors.textLow, fontSize: kFont)),
            ),
            Expanded(
              child: SelectableText(valor,
                  style: const TextStyle(
                      color: AppColors.textHi, fontSize: kFont)),
            ),
          ],
        ),
      );

  // ---- Tarjeta de escáner de red (estilo Angry IP Scanner) ----

  void _iniciarEscaner() {
    final red = _red;
    if (_escCorriendo || red == null || !red.hayRed) return;
    setState(() {
      _escCorriendo = true;
      _escProgreso = 0;
      _escFase = 'Iniciando…';
      _equipos = const [];
    });
    _escSub?.cancel();
    _escSub = _escSvc
        .escanear(
            baseRed: red.baseRed, ipLocal: red.localIp, gateway: red.gateway)
        .listen(
      (ev) {
        if (!mounted) return;
        setState(() {
          _escProgreso = ev.porcentaje;
          _escFase = ev.fase;
          if (ev.nuevo != null) {
            _equipos = [..._equipos, ev.nuevo!]
              ..sort((a, b) => _octeto(a.ip).compareTo(_octeto(b.ip)));
          }
          if (ev.resultado != null) {
            _equipos = ev.resultado!;
            _escCorriendo = false;
          }
        });
      },
      onError: (_) {
        if (mounted) setState(() => _escCorriendo = false);
      },
      onDone: () {
        if (mounted) setState(() => _escCorriendo = false);
      },
    );
  }

  void _detenerEscaner() {
    _escSvc.cancelar();
    setState(() => _escFase = 'Deteniendo…');
  }

  static int _octeto(String ip) => int.tryParse(ip.split('.').last) ?? 0;

  static IconData _iconoTipo(String tipo) => switch (tipo) {
        'router' => Icons.router_rounded,
        'impresora' => Icons.print_rounded,
        'tv' => Icons.tv_rounded,
        'iot' => Icons.sensors_rounded,
        'web' => Icons.language_rounded,
        'servidor' => Icons.dns_rounded,
        'pc' => Icons.computer_rounded,
        'telefono' => Icons.smartphone_rounded,
        _ => Icons.devices_other_rounded,
      };

  Widget _tarjetaEscaner() {
    final base = _red?.baseRed ?? '';
    return _Tarjeta(
      icono: Icons.radar_rounded,
      color: AppColors.board,
      titulo: 'Escáner de red',
      subtitulo: _escCorriendo || _equipos.isNotEmpty
          ? '$_escFase · ${_equipos.length} equipos'
          : (base.isEmpty
              ? 'Sin red'
              : 'Escanea $base.1 – $base.254 y lista quién responde al ping'),
      acciones: [
        _botonPrincipal(
          _escCorriendo ? 'Detener' : 'Escanear red',
          _escCorriendo ? Icons.stop_rounded : Icons.play_arrow_rounded,
          _escCorriendo ? _detenerEscaner : _iniciarEscaner,
          rojo: _escCorriendo,
        ),
      ],
      hijo: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_escCorriendo) ...[
            LinearProgressIndicator(
              value: _escProgreso == 0 ? null : _escProgreso,
              backgroundColor: AppColors.bg,
              color: AppColors.board,
            ),
            const SizedBox(height: 12),
          ],
          ..._equipos.map(_filaEquipo),
          if (_equipos.isEmpty && !_escCorriendo)
            _nota('Detecta tu IP y escanea todo el rango de la red. Solo se '
                'muestran los equipos que responden al ping.'),
        ],
      ),
    );
  }

  Widget _filaEquipo(Dispositivo d) {
    final detalle = [
      if (d.mac.isNotEmpty) d.mac,
      if (d.fabricante != null) d.fabricante!,
      if (d.latenciaMs != null) '${d.latenciaMs} ms',
      if (d.puertos.isNotEmpty) 'puertos ${(d.puertos.toList()..sort()).join(', ')}',
    ].join(' · ');
    final marca = d.esEsteEquipo
        ? ' (este equipo)'
        : d.esGateway
            ? ' (router)'
            : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(_iconoTipo(d.tipo), size: 20, color: AppColors.board),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText('${d.etiqueta}$marca',
                      style: const TextStyle(
                          color: AppColors.textHi,
                          fontSize: kFont,
                          fontWeight: FontWeight.w600)),
                  SelectableText(d.ip,
                      style: const TextStyle(
                          color: AppColors.textMid, fontSize: kFont)),
                  if (detalle.isNotEmpty)
                    Text(detalle,
                        style: const TextStyle(
                            color: AppColors.textLow, fontSize: kFont)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Tarjeta de diagnóstico de Internet ----

  Widget _tarjetaDiagnostico() {
    return _Tarjeta(
      icono: Icons.travel_explore_rounded,
      color: AppColors.accent,
      titulo: 'Diagnóstico de Internet',
      subtitulo: _resultado == null
          ? '¿Hay internet? Y si no, ¿de quién es la culpa?'
          : _resultado!.titulo,
      acciones: [
        _botonPrincipal(
          _diagCorriendo ? 'Detener' : 'Comprobar Internet',
          _diagCorriendo ? Icons.stop_rounded : Icons.play_arrow_rounded,
          _diagCorriendo ? _detenerDiagnostico : _iniciarDiagnostico,
          rojo: _diagCorriendo,
        ),
      ],
      hijo: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_diagCorriendo) ...[
            LinearProgressIndicator(
              value: _diagProgreso == 0 ? null : _diagProgreso,
              backgroundColor: AppColors.bg,
              color: AppColors.accent,
            ),
            const SizedBox(height: 12),
          ],
          if (_resultado != null) ...[
            _veredicto(_resultado!),
            const SizedBox(height: 12),
          ],
          ..._pasos.map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _filaPaso(p),
              )),
          if (_ruta.isNotEmpty) ...[
            const SizedBox(height: 4),
            _rutaBox(),
          ],
          if (_resultado != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: _boton(
                _diagCopiado ? 'Copiado' : 'Copiar diagnóstico',
                _diagCopiado ? Icons.check_rounded : Icons.copy_rounded,
                _copiarDiagnostico,
              ),
            ),
          ],
          if (_pasos.isEmpty && !_diagCorriendo)
            _nota('Comprueba si hay internet y, si no lo hay, de quién es la '
                'falla: el punto de acceso, el módem o el proveedor.'),
        ],
      ),
    );
  }

  Future<void> _iniciarDiagnostico() async {
    if (_diagCorriendo) return;
    final red = _red;
    if (red == null) return;
    setState(() {
      _diagCorriendo = true;
      _diagProgreso = 0;
      _resultado = null;
      _diagCopiado = false;
      _pasos = const [];
      _ruta = const [];
    });
    _diagSub?.cancel();
    _diagSub = _diagSvc.ejecutar(red).listen(
      (ev) {
        if (!mounted) return;
        setState(() {
          _pasos = List.of(ev.pasos);
          _ruta = List.of(ev.ruta);
          _diagProgreso = ev.porcentaje;
          if (ev.resultado != null) _resultado = ev.resultado;
          if (ev.finalizado) _diagCorriendo = false;
        });
      },
      onError: (_) {
        if (mounted) setState(() => _diagCorriendo = false);
      },
      onDone: () {
        if (mounted) setState(() => _diagCorriendo = false);
      },
    );
  }

  void _detenerDiagnostico() {
    _diagSvc.cancelar();
    _diagSub?.cancel();
    setState(() => _diagCorriendo = false);
  }

  Widget _veredicto(ResultadoDiagnostico r) {
    final color = _colorCulpable(r.culpable);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_iconoCulpable(r.culpable), color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(r.titulo,
                    style: TextStyle(
                        color: color,
                        fontSize: kFont + 1,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(r.explicacion,
              style: const TextStyle(
                  color: AppColors.textHi, fontSize: kFont, height: 1.4)),
          if (r.acciones.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Qué hacer',
                style: TextStyle(
                    color: color, fontSize: kFont, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            ...r.acciones.map((a) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('•  $a',
                      style: const TextStyle(
                          color: AppColors.textMid, fontSize: kFont, height: 1.35)),
                )),
          ],
        ],
      ),
    );
  }

  Color _colorCulpable(Culpable c) => switch (c) {
        Culpable.ninguno => AppColors.accent,
        Culpable.dns || Culpable.portal => _ambar,
        Culpable.desconocido => AppColors.textLow,
        _ => _rojo,
      };

  IconData _iconoCulpable(Culpable c) => switch (c) {
        Culpable.ninguno => Icons.check_circle_rounded,
        Culpable.sinRed => Icons.signal_wifi_off_rounded,
        Culpable.ap => Icons.router_rounded,
        Culpable.modem => Icons.settings_input_hdmi_rounded,
        Culpable.isp => Icons.cell_tower_rounded,
        Culpable.dns => Icons.dns_rounded,
        Culpable.portal => Icons.lock_person_rounded,
        Culpable.desconocido => Icons.help_outline_rounded,
      };

  Widget _filaPaso(PasoDiagnostico p) {
    final color = _colorEstado(p.estado);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: color, width: p.estado == EstadoPaso.corriendo ? 1.6 : 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: p.estado == EstadoPaso.corriendo
                ? CircularProgressIndicator(strokeWidth: 2, color: color)
                : Icon(_iconoEstado(p.estado), color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.titulo,
                    style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: kFont,
                        fontWeight: FontWeight.w600)),
                if (p.detalle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: SelectableText(p.detalle,
                        style: const TextStyle(
                            color: AppColors.textMid,
                            fontSize: kFont,
                            height: 1.3)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _colorEstado(EstadoPaso e) => switch (e) {
        EstadoPaso.ok => AppColors.accent,
        EstadoPaso.aviso => _ambar,
        EstadoPaso.fallo => _rojo,
        EstadoPaso.corriendo => AppColors.ram,
        _ => AppColors.border,
      };

  IconData _iconoEstado(EstadoPaso e) => switch (e) {
        EstadoPaso.ok => Icons.check_circle_rounded,
        EstadoPaso.aviso => Icons.warning_amber_rounded,
        EstadoPaso.fallo => Icons.cancel_rounded,
        EstadoPaso.omitido => Icons.remove_circle_outline_rounded,
        _ => Icons.radio_button_unchecked_rounded,
      };

  Widget _rutaBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Camino hacia internet',
              style: TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ..._ruta.map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                        width: 22,
                        child: Text('${s.numero}.',
                            style: const TextStyle(
                                color: AppColors.textLow, fontSize: kFont))),
                    Expanded(
                      child: SelectableText(s.ip ?? 'sin respuesta',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: kFont,
                              color: s.ip == null
                                  ? AppColors.textLow
                                  : AppColors.textHi)),
                    ),
                    Text(_etiquetaSalto(s),
                        style: const TextStyle(
                            color: AppColors.textLow, fontSize: kFont - 1)),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  String _etiquetaSalto(SaltoRuta s) {
    if (s.esDestino) return 'internet ✓';
    if (s.ip == null) return '';
    if (s.numero == 1) return 'punto de acceso';
    return _privada(s.ip!) ? 'equipo propio' : 'red del operador';
  }

  bool _privada(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? 0;
    final b = int.tryParse(p[1]) ?? 0;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127);
  }

  void _copiarDiagnostico() {
    final r = _resultado;
    final b = StringBuffer()
      ..writeln('[PCInfo] Diagnóstico de Internet')
      ..writeln(DateTime.now().toIso8601String().split('.').first)
      ..writeln('App: $appName v$appVersion Rev $appRevision');
    final red = _red;
    if (red != null) {
      b
        ..writeln('IP local: ${red.localIp.isEmpty ? '—' : red.localIp}')
        ..writeln(
            'Puerta de enlace: ${red.gateway.isEmpty ? '—' : red.gateway}');
    }
    if (r != null) {
      b
        ..writeln()
        ..writeln('Veredicto: ${r.titulo}')
        ..writeln(r.explicacion);
      for (final a in r.acciones) {
        b.writeln('  - $a');
      }
    }
    b
      ..writeln()
      ..writeln('--- Pruebas ---');
    for (final p in _pasos) {
      b.writeln('[${_marca(p.estado)}] ${p.titulo}: ${p.detalle}');
    }
    if (_ruta.isNotEmpty) {
      b
        ..writeln()
        ..writeln('--- Ruta ---');
      for (final s in _ruta) {
        b.writeln(
            '${s.numero}. ${s.ip ?? 'sin respuesta'}${s.esDestino ? ' (destino)' : ''}');
      }
    }
    Clipboard.setData(ClipboardData(text: b.toString()));
    setState(() => _diagCopiado = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _diagCopiado = false);
    });
  }

  String _marca(EstadoPaso e) => switch (e) {
        EstadoPaso.ok => 'OK',
        EstadoPaso.aviso => '! ',
        EstadoPaso.fallo => 'X ',
        EstadoPaso.omitido => '- ',
        _ => '  ',
      };

  // ---- Tarjeta de velocidad ----

  Widget _tarjetaVelocidad() {
    return _Tarjeta(
      icono: Icons.speed_rounded,
      color: AppColors.gpu,
      titulo: 'Test de velocidad',
      subtitulo: _velFase.isEmpty
          ? 'Ping, descarga y subida contra Cloudflare'
          : _velFase,
      acciones: [
        _botonPrincipal(
          _velCorriendo ? 'Detener' : 'Medir velocidad',
          _velCorriendo ? Icons.stop_rounded : Icons.play_arrow_rounded,
          _velCorriendo ? _detenerVelocidad : _iniciarVelocidad,
          rojo: _velCorriendo,
        ),
      ],
      hijo: Column(
        children: [
          _filaVelocidad('Ping', _ping?.toStringAsFixed(0), 'ms',
              Icons.network_ping_rounded, AppColors.ram, _velCorriendo && _velFase.contains('latencia')),
          const SizedBox(height: 10),
          _filaVelocidad('Descarga', _descarga?.toStringAsFixed(1), 'Mbps',
              Icons.download_rounded, AppColors.board, _velCorriendo && _velFase.contains('descarga')),
          const SizedBox(height: 10),
          _filaVelocidad('Subida', _subida?.toStringAsFixed(1), 'Mbps',
              Icons.upload_rounded, _rojo, _velCorriendo && _velFase.contains('subida')),
        ],
      ),
    );
  }

  // El resaltado va en el botón "Medir velocidad" (_botonPrincipal), no aquí:
  // estas filas solo muestran el valor y, con el spinner, cuál fase corre.
  Widget _filaVelocidad(String titulo, String? valor, String unidad,
      IconData icono, Color color, bool activa) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icono, color: color, size: 20),
          const SizedBox(width: 10),
          Text(titulo,
              style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w600)),
          if (activa) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
          ],
          const Spacer(),
          Text(valor ?? '—',
              style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont + 4,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(unidad,
                style:
                    const TextStyle(color: AppColors.textLow, fontSize: kFont)),
          ),
        ],
      ),
    );
  }

  Future<void> _iniciarVelocidad() async {
    if (_velCorriendo) return;
    setState(() {
      _velCorriendo = true;
      _ping = null;
      _descarga = null;
      _subida = null;
      _velFase = 'Midiendo latencia…';
    });
    _velSvc.reiniciar();

    final p = await _velSvc.ping();
    if (!mounted) return;
    setState(() {
      _ping = p;
      _velFase = 'Midiendo descarga…';
    });

    final d = await _velSvc.descarga(
      onProgreso: (mbps) {
        if (mounted) setState(() => _descarga = mbps);
      },
    );
    if (!mounted) return;
    setState(() {
      _descarga = d;
      _velFase = 'Midiendo subida…';
    });

    final s = await _velSvc.subida(
      onProgreso: (mbps) {
        if (mounted) setState(() => _subida = mbps);
      },
    );
    if (!mounted) return;
    setState(() {
      _subida = s;
      _velCorriendo = false;
      _velFase = 'Test completado';
    });
  }

  void _detenerVelocidad() {
    _velSvc.cancelar();
    setState(() {
      _velCorriendo = false;
      _velFase = 'Detenido';
    });
  }

  // ---- Comunes ----

  Widget _boton(String texto, IconData icono, VoidCallback accion,
      {bool rojo = false}) {
    final color = rojo ? _rojo : AppColors.textMid;
    return Material(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: accion,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, size: 16, color: color),
              const SizedBox(width: 7),
              Text(texto,
                  style: TextStyle(
                      color: color, fontSize: kFont, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  /// Botón principal de cada tarjeta ("Comprobar Internet" / "Medir
  /// velocidad"): resaltado, a diferencia de las filas de resultado
  /// (ping/descarga/subida o los pasos), que solo informan.
  Widget _botonPrincipal(String texto, IconData icono, VoidCallback accion,
      {bool rojo = false}) {
    return FilledButton.icon(
      onPressed: accion,
      style: FilledButton.styleFrom(
        backgroundColor: rojo ? _rojo : AppColors.accentDim,
        foregroundColor: AppColors.textHi,
      ),
      icon: Icon(icono, size: 16),
      label: Text(texto,
          style: const TextStyle(fontSize: kFont, fontWeight: FontWeight.w600)),
    );
  }

  static Widget _nota(String texto) => Text(texto,
      style: const TextStyle(color: AppColors.textLow, fontSize: kFont));

  static Widget _caja(Color color, IconData icono, String texto) {
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
}

/// Tarjeta con encabezado, botones de acción y contenido (mismo estilo que
/// controladores_page.dart).
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
                    Text(titulo,
                        style: const TextStyle(
                            color: AppColors.textHi,
                            fontSize: kFont,
                            fontWeight: FontWeight.w700)),
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(subtitulo,
                          style: const TextStyle(
                              color: AppColors.textLow, fontSize: kFont)),
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
