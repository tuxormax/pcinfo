import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../version.dart';
import '../models/arranques.dart';
import '../models/bateria.dart';
import '../models/controladores.dart';
import '../models/errores.dart';
import '../models/hardware.dart';
import '../models/software.dart';
import '../services/backend_http.dart';
import '../services/arranques_service.dart';
import '../services/bateria_service.dart';
import '../services/backend_launcher.dart';
import '../services/controladores_service.dart';
import '../services/errores_service.dart';
import '../services/hardware_service.dart';
import '../services/software_service.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../utils/report.dart';
import 'arranques_page.dart';
import 'bateria_page.dart';
import 'controladores_page.dart';
import 'discos_page.dart';
import 'errores_page.dart';
import 'software_page.dart';
import 'widgets/spec_card.dart';

class DashboardPage extends StatefulWidget {
  final HardwareService service;

  /// Fuente del "Historial de Errores" (GET /errores). Si es null, esa pestaña
  /// avisa que no hay datos (p. ej. en pruebas con el mock de hardware).
  final ErroresService? erroresService;

  /// Fuente del "Software instalado" (GET /software). Null = pestaña sin datos.
  final SoftwareService? softwareService;

  /// Fuente de la pestaña "Controladores" (GET/POST /controladores).
  final ControladoresService? controladoresService;

  /// Fuente de la pestaña "Batería" (GET /bateria). Null = pestaña sin datos.
  final BateriaService? bateriaService;

  /// Fuente de "Encendidos y apagados" (GET /arranques). Null = sin datos.
  final ArranquesService? arranquesService;

  /// Launcher del backend. Solo se usa para "Reintentar como administrador"
  /// (Windows) cuando el SMART salió vacío por falta de elevación. Puede ser null
  /// (p. ej. en pruebas con el mock).
  final BackendLauncher? launcher;

  const DashboardPage({
    super.key,
    required this.service,
    this.erroresService,
    this.softwareService,
    this.controladoresService,
    this.bateriaService,
    this.arranquesService,
    this.launcher,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<HardwareInfo> _future;

  /// Pestaña activa: 0 = Hardware, 1 = Historial de Errores, 2 = Software,
  /// 3 = Controladores, 4 = Batería, 5 = Discos, 6 = Encendidos.
  int _tab = 0;

  static const _tabHardwareIdx = 0;
  static const _tabErroresIdx = 1;
  static const _tabSoftwareIdx = 2;
  static const _tabControladoresIdx = 3;
  static const _tabBateriaIdx = 4;
  static const _tabDiscosIdx = 5;
  static const _tabArranquesIdx = 6;

  /// El historial de errores se pide SOLO al abrir su pestaña: en Windows
  /// recorre 30 días de registro de eventos y analiza los volcados, así que
  /// cargarlo al inicio retrasaría el arranque de la app.
  Future<ErroresInfo>? _erroresFuture;

  /// Igual que el historial: el software y los controladores se piden SOLO al
  /// abrir su pestaña. Recorrer el registro de programas y consultar las apps de
  /// la Tienda tarda segundos, y listar los controladores lanza PowerShell.
  Future<SoftwareInfo>? _softwareFuture;
  Future<ControladoresInfo>? _controladoresFuture;

  /// La batería también: en Windows hay que pedirle a powercfg que genere su
  /// informe de batería, y eso se lleva unos segundos.
  Future<BateriaInfo>? _bateriaFuture;

  /// Los encendidos también van aparte: recorren el registro de accesos, el
  /// diario del sistema y consultan a systemd unidad por unidad.
  Future<ArranquesInfo>? _arranquesFuture;

  /// Últimos datos cargados de cada pestaña (para el botón Guardar y para la
  /// barra superior, que se dibuja fuera del FutureBuilder).
  HardwareInfo? _hw;
  ErroresInfo? _errores;
  SoftwareInfo? _software;
  ControladoresInfo? _controladores;
  BateriaInfo? _bateria;
  ArranquesInfo? _arranques;

  /// true mientras se reintenta elevar el backend (UAC en curso).
  bool _elevating = false;

  /// Discos a los que se les está forzando la lectura de salud a mano (botón
  /// "Leer salud igual"), por nombre de dispositivo.
  final Set<String> _forzandoSalud = {};

  /// true mientras está en camino la segunda fase del arranque: la salud
  /// (S.M.A.R.T.) de los discos. El resto del hardware ya está pintado; la ficha
  /// de Almacenamiento avisa que la salud sigue leyéndose.
  bool _discosCargando = false;

  @override
  void initState() {
    super.initState();
    _cargaHardware();
  }

  /// Arranque en DOS tiempos: primero el inventario sin la salud de los discos
  /// (responde de inmediato) y enseguida, en segundo plano, los discos con
  /// S.M.A.R.T. Consultar un disco que no contesta —un lector de tarjetas o un
  /// gabinete USB— se lleva varios segundos, y antes eso retrasaba TODA la
  /// pantalla hasta pasarse de la espera máxima ("tardó demasiado").
  void _cargaHardware() {
    final f = widget.service.load();
    _future = f;
    _discosCargando = true;
    f.then((v) {
      if (mounted) setState(() => _hw = v);
      _cargaDiscos(f);
    }).catchError((Object _) {
      if (mounted) setState(() => _discosCargando = false);
    });
  }

  /// Segunda fase. [origen] es el future del inventario que la disparó: si
  /// mientras tanto se refrescó (o se relanzó el backend elevado), estos discos
  /// ya son de una carga vieja y se descartan.
  void _cargaDiscos(Future<HardwareInfo> origen) {
    widget.service.loadDiscos().then((discos) {
      if (!mounted || _future != origen) return;
      setState(() {
        _discosCargando = false;
        final hw = _hw;
        if (hw != null) _hw = hw.conDiscos(discos);
      });
    }).catchError((Object _) {
      // Si falla, se quedan los discos sin salud y el aviso de siempre.
      if (mounted && _future == origen) {
        setState(() => _discosCargando = false);
      }
    });
  }

  /// Instalación de Windows cuyo historial se está viendo. Vacío = la del
  /// sistema en ejecución. Se llena al elegir otra unidad en el selector de la
  /// pestaña de errores (equipo que no arranca, visto desde un medio de rescate).
  String _raizErrores = '';

  void _cargaErrores() {
    final svc = widget.erroresService;
    if (svc == null) return;
    final f = svc.load(raiz: _raizErrores);
    _erroresFuture = f;
    f.then((v) {
      if (mounted) setState(() => _errores = v);
    }).catchError((Object _) {});
  }

  void _cargaSoftware() {
    final svc = widget.softwareService;
    if (svc == null) return;
    final f = svc.load();
    _softwareFuture = f;
    f.then((v) {
      if (mounted) setState(() => _software = v);
    }).catchError((Object _) {});
  }

  void _cargaControladores() {
    final svc = widget.controladoresService;
    if (svc == null) return;
    final f = svc.load();
    _controladoresFuture = f;
    f.then((v) {
      if (mounted) setState(() => _controladores = v);
    }).catchError((Object _) {});
  }

  void _cargaBateria() {
    final svc = widget.bateriaService;
    if (svc == null) return;
    final f = svc.load();
    _bateriaFuture = f;
    f.then((v) {
      if (mounted) setState(() => _bateria = v);
    }).catchError((Object _) {});
  }

  void _cargaArranques() {
    final svc = widget.arranquesService;
    if (svc == null) return;
    final f = svc.load();
    _arranquesFuture = f;
    f.then((v) {
      if (mounted) setState(() => _arranques = v);
    }).catchError((Object _) {});
  }

  /// Fuerza la lectura de salud de un disco clasificado como memoria extraíble.
  /// Existe para el gabinete externo que se declara removible: ahí la salud sí
  /// se puede leer, pero por el tipo de medio no se sondea sola.
  Future<void> _forzarSalud(DiskInfo d) async {
    if (_forzandoSalud.contains(d.name)) return;
    setState(() => _forzandoSalud.add(d.name));
    try {
      final discos = await widget.service.loadDiscos(forzar: d.name);
      if (!mounted) return;
      final hw = _hw;
      if (hw != null) setState(() => _hw = hw.conDiscos(discos));
      final leido = discos.firstWhere(
        (x) => x.name == d.name,
        orElse: () => d,
      );
      if (!leido.smartAvailable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: AppColors.surfaceAlt,
          content: Text(
            '${d.model.isEmpty ? d.name : d.model} no entregó datos de salud: '
            'es una memoria extraíble o su adaptador no traduce los comandos.',
            style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
          ),
        ));
      }
    } catch (_) {
      // El fallo ya se ve en la ficha: el disco sigue sin salud.
    } finally {
      if (mounted) setState(() => _forzandoSalud.remove(d.name));
    }
  }

  /// Cambia la instalación analizada y recarga el historial.
  void _cambiaInstalacion(String raiz) {
    if (raiz == _raizErrores) return;
    setState(() {
      _raizErrores = raiz;
      _errores = null;
      _cargaErrores();
    });
  }

  /// Refresca SOLO la pestaña visible (recargar el historial de errores es caro).
  void _refresh() {
    setState(() {
      switch (_tab) {
        case _tabErroresIdx:
          _cargaErrores();
        case _tabSoftwareIdx:
          _software = null;
          _cargaSoftware();
        case _tabControladoresIdx:
          _controladores = null;
          _cargaControladores();
        case _tabBateriaIdx:
          _bateria = null;
          _cargaBateria();
        case _tabArranquesIdx:
          _arranques = null;
          _cargaArranques();
        case _tabDiscosIdx:
          // La salud de los discos viaja con el inventario: se recarga entero.
          _cargaHardware();
        default:
          _cargaHardware();
      }
    });
  }

  void _cambiaTab(int i) {
    setState(() {
      _tab = i;
      switch (i) {
        case _tabErroresIdx:
          if (_erroresFuture == null) _cargaErrores();
        case _tabSoftwareIdx:
          if (_softwareFuture == null) _cargaSoftware();
        case _tabControladoresIdx:
          if (_controladoresFuture == null) _cargaControladores();
        case _tabBateriaIdx:
          if (_bateriaFuture == null) _cargaBateria();
        case _tabArranquesIdx:
          if (_arranquesFuture == null) _cargaArranques();
      }
    });
  }

  /// Relanza el backend elevado (UAC) y, si lo logra, recarga el hardware para
  /// que aparezca la salud/desgaste de los discos. Si el usuario cancela el UAC,
  /// avisa sin bloquear la app.
  Future<void> _retryElevated() async {
    final launcher = widget.launcher;
    if (launcher == null || _elevating) return;
    setState(() => _elevating = true);
    final ok = await launcher.retryElevated();
    if (!mounted) return;
    setState(() => _elevating = false);
    if (ok) {
      // Al elevarse cambian AMBAS pestañas (SMART de los discos y los registros
      // protegidos), así que se recarga lo que ya estuviera cargado.
      setState(() {
        _cargaHardware();
        if (_erroresFuture != null) _cargaErrores();
        // Los controladores no se pueden ni LISTAR sin administrador: tras
        // elevar hay que volver a pedirlos o la pestaña seguiría vacía.
        if (_controladoresFuture != null) _cargaControladores();
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: AppColors.surfaceAlt,
        content: Text(
          'No se pudo obtener permisos de administrador (¿se canceló el aviso de Windows?). Inténtalo de nuevo.',
          style: TextStyle(color: Color(0xFFF2768D), fontSize: kFont),
        ),
      ));
    }
  }

  // Estado cuando la lectura falla: NO se muestran datos de ejemplo, sino la
  // CAUSA concreta (backend caído, tardanza, o el error interno con su traza) y
  // un botón para copiarla. Antes todo terminaba en "el servicio no responde",
  // que es indistinguible entre un backend que no arrancó y uno que se rompió
  // leyendo el equipo, y deja sin nada que reportar.
  Widget _estadoFallo(String titulo, Object? error) {
    final err = error is BackendError
        ? error
        : BackendError(
            'El servicio de PCInfo no está respondiendo.',
            detalle: error == null ? '' : '$error',
          );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.textMid, size: 48),
            const SizedBox(height: 16),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textHi,
                fontSize: kFont + 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              err.mensaje,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
            if (err.detalle.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720, maxHeight: 220),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      err.detalle,
                      style: const TextStyle(
                        color: AppColors.textMid,
                        fontSize: kFont - 1,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
                if (err.detalle.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _copiaFallo(titulo, err),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copiar detalles'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Copia el fallo con la versión de la app y del backend: sin eso un reporte
  /// no dice contra qué versión ocurrió.
  Future<void> _copiaFallo(String titulo, BackendError err) async {
    final info = widget.launcher?.info;
    final texto = StringBuffer()
      ..writeln('[PCInfo] $titulo')
      ..writeln(err.mensaje)
      ..writeln()
      ..writeln('App: $appName v$appVersion Rev $appRevision')
      ..writeln('Backend: ${info == null || !info.vivo ? 'no responde' : info.etiqueta}')
      ..writeln('Sistema: ${Platform.operatingSystemVersion}')
      ..writeln()
      ..writeln(err.detalle);
    await Clipboard.setData(ClipboardData(text: texto.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      backgroundColor: AppColors.surfaceAlt,
      content: Text('Detalles copiados al portapapeles',
          style: TextStyle(color: AppColors.textHi, fontSize: kFont)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _topBar(),
            _tabsBar(),
            _avisoBackendViejo(),
            Expanded(child: _cuerpo()),
          ],
        ),
      ),
      bottomNavigationBar: _footer(),
    );
  }

  Widget _cuerpo() => switch (_tab) {
        _tabErroresIdx => _tabErrores(),
        _tabSoftwareIdx => _tabSoftware(),
        _tabControladoresIdx => _tabControladores(),
        _tabBateriaIdx => _tabBateria(),
        _tabDiscosIdx => _tabDiscos(),
        _tabArranquesIdx => _tabArranques(),
        _ => _tabHardware(),
      };

  Widget _tabHardware() {
    return FutureBuilder<HardwareInfo>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          );
        }
        if (snap.hasError) {
          return _estadoFallo('No se pudo leer el hardware', snap.error);
        }
        // _hw, no snap.data: es el que se actualiza cuando llega la salud de
        // los discos (segunda fase).
        return _content(_hw ?? snap.data!);
      },
    );
  }

  Widget _tabErrores() {
    if (widget.erroresService == null) {
      return _mensajeCentrado(
        Icons.help_outline_rounded,
        'Historial de errores no disponible',
        'Esta ventana se abrió sin conexión al servicio de PCInfo.',
      );
    }
    return FutureBuilder<ErroresInfo>(
      future: _erroresFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.accent),
                SizedBox(height: 16),
                Text(
                  'Leyendo los registros del sistema…\n'
                  'La primera vez puede tardar un poco.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMid, fontSize: kFont),
                ),
              ],
            ),
          );
        }
        if (snap.hasError) {
          return _estadoFallo(
              'No se pudo leer el historial de errores', snap.error);
        }
        final data = snap.data!;
        // En Windows, si el backend no está elevado se ofrece relanzarlo con
        // permisos de administrador (mismo botón que usa la ficha de discos).
        final puedeElevar =
            data.isWindows && !data.elevated && widget.launcher != null;
        return ErroresPage(
          data: data,
          onInstalacion: _cambiaInstalacion,
          avisoAccion: !puedeElevar
              ? null
              : FilledButton.icon(
                  onPressed: _elevating ? null : _retryElevated,
                  icon: _elevating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.shield_rounded, size: 16),
                  label: Text(_elevating
                      ? 'Solicitando permiso…'
                      : 'Reintentar como administrador'),
                ),
        );
      },
    );
  }

  Widget _tabSoftware() {
    if (widget.softwareService == null) {
      return _mensajeCentrado(
        Icons.help_outline_rounded,
        'Software instalado no disponible',
        'Esta ventana se abrió sin conexión al servicio de PCInfo.',
      );
    }
    return FutureBuilder<SoftwareInfo>(
      future: _softwareFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _cargando('Leyendo los programas instalados…');
        }
        if (snap.hasError) {
          return _estadoFallo(
              'No se pudo leer el software instalado', snap.error);
        }
        return SoftwarePage(data: snap.data!);
      },
    );
  }

  Widget _tabControladores() {
    final svc = widget.controladoresService;
    if (svc == null) {
      return _mensajeCentrado(
        Icons.help_outline_rounded,
        'Controladores no disponible',
        'Esta ventana se abrió sin conexión al servicio de PCInfo.',
      );
    }
    return FutureBuilder<ControladoresInfo>(
      future: _controladoresFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _cargando('Leyendo los controladores y las redes guardadas…');
        }
        if (snap.hasError) {
          return _estadoFallo(
              'No se pudo leer los controladores', snap.error);
        }
        final data = snap.data!;
        return ControladoresPage(
          data: data,
          service: svc,
          onRecargar: () => setState(_cargaControladores),
          avisoAccion: _botonElevar(data.supported && !data.elevated),
        );
      },
    );
  }

  /// Pestaña "Discos": la salud de cada disco, explicada. Se apoya en los MISMOS
  /// datos que la pestaña Hardware (el inventario ya trae los discos con su
  /// S.M.A.R.T.), así que no vuelve a preguntar nada al backend.
  Widget _tabDiscos() {
    return FutureBuilder<HardwareInfo>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _cargando('Buscando los discos del equipo…');
        }
        if (snap.hasError) {
          return _estadoFallo('No se pudieron leer los discos', snap.error);
        }
        final hw = _hw ?? snap.data!;
        final faltaAdmin =
            hw.disks.any((d) => !d.smartAvailable && !d.removable) &&
                !hw.diag.elevated;
        return DiscosPage(
          discos: hw.disks,
          cargando: _discosCargando,
          avisoAccion: _botonElevar(faltaAdmin),
          onForzar: _forzarSalud,
          forzando: _forzandoSalud,
        );
      },
    );
  }

  Widget _tabBateria() {
    if (widget.bateriaService == null) {
      return _mensajeCentrado(
        Icons.help_outline_rounded,
        'Batería no disponible',
        'Esta ventana se abrió sin conexión al servicio de PCInfo.',
      );
    }
    return FutureBuilder<BateriaInfo>(
      future: _bateriaFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _cargando('Leyendo el estado de la batería…\n'
              'Windows tarda unos segundos en preparar su informe.');
        }
        if (snap.hasError) {
          return _estadoFallo('No se pudo leer la batería', snap.error);
        }
        return BateriaPage(data: snap.data!);
      },
    );
  }

  Widget _tabArranques() {
    if (widget.arranquesService == null) {
      return _mensajeCentrado(
        Icons.help_outline_rounded,
        'Encendidos no disponibles',
        'Esta ventana se abrió sin conexión al servicio de PCInfo.',
      );
    }
    return FutureBuilder<ArranquesInfo>(
      future: _arranquesFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _cargando('Leyendo el historial de encendidos y apagados…');
        }
        if (snap.hasError) {
          return _estadoFallo(
              'No se pudo leer el historial de encendidos', snap.error);
        }
        return ArranquesPage(
          data: snap.data!,
          onActivarDiario: widget.arranquesService?.activarDiario,
          onRecargar: () => setState(() {
            _arranques = null;
            _cargaArranques();
          }),
        );
      },
    );
  }

  /// Botón "Reintentar como administrador" (solo Windows y solo si hay launcher).
  /// Todo el módulo de controladores escribe en el equipo y necesita elevación,
  /// así que sin este botón la pestaña sería un callejón sin salida.
  Widget? _botonElevar(bool haceFalta) {
    if (!haceFalta || !Platform.isWindows || widget.launcher == null) {
      return null;
    }
    return FilledButton.icon(
      onPressed: _elevating ? null : _retryElevated,
      icon: _elevating
          ? const SizedBox(
              width: 14,
              height: 14,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.shield_rounded, size: 16),
      label: Text(_elevating
          ? 'Solicitando permiso…'
          : 'Reintentar como administrador'),
    );
  }

  Widget _cargando(String texto) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppColors.accent),
          const SizedBox(height: 16),
          Text(texto,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMid, fontSize: kFont)),
        ],
      ),
    );
  }

  Widget _mensajeCentrado(IconData icono, String titulo, String detalle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, color: AppColors.textMid, size: 48),
            const SizedBox(height: 16),
            Text(titulo,
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont + 2,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: 8),
            Text(detalle,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: AppColors.textMid, fontSize: kFont)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  /// Aviso cuando quien contesta en el puerto es un backend de OTRA versión que
  /// no se pudo reemplazar (quedó vivo de una instalación anterior y corre con
  /// permisos que esta ventana no puede tocar). Importa porque, sin saberlo, la
  /// app nueva muestra los resultados del binario viejo: siguen apareciendo
  /// fallos ya corregidos y da la impresión de que la actualización no sirvió.
  Widget _avisoBackendViejo() {
    final l = widget.launcher;
    if (l == null || !l.desfasado) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0x33E0A33A),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: Color(0xFFE0A33A)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Los datos los está entregando ${l.info.etiqueta} de PCInfo, no la '
              'versión instalada (v$appVersion Rev $appRevision). Cierra todas las '
              'ventanas de PCInfo y vuelve a abrir para que se use la nueva.',
              style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
            ),
          ),
        ],
      ),
    );
  }

  /// Barra de pestañas: Hardware | Historial de Errores | Software |
  /// Controladores.
  Widget _tabsBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // Desplazable en horizontal: con tantas pestañas la fila ya no cabe en una
      // ventana estrecha, y sin esto Flutter pinta la franja de desbordamiento.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _tabBoton(_tabHardwareIdx, Icons.memory_rounded, 'Hardware'),
            _tabBoton(_tabErroresIdx, Icons.rule_folder_rounded,
                'Historial de Errores'),
            _tabBoton(_tabSoftwareIdx, Icons.apps_rounded, 'Software'),
            _tabBoton(_tabControladoresIdx,
                Icons.settings_input_component_rounded, 'Controladores'),
            _tabBoton(_tabBateriaIdx, Icons.battery_5_bar_rounded, 'Batería'),
            _tabBoton(_tabDiscosIdx, Icons.storage_rounded, 'Discos'),
            _tabBoton(_tabArranquesIdx, Icons.power_settings_new_rounded,
                'Encendidos y apagados'),
          ],
        ),
      ),
    );
  }

  Widget _tabBoton(int indice, IconData icono, String texto) {
    final activo = _tab == indice;
    final color = activo ? AppColors.accent : AppColors.textMid;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _cambiaTab(indice),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: activo ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, size: 16, color: color),
              const SizedBox(width: 7),
              Text(texto,
                  style: TextStyle(
                      color: color,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Text(
            '$appName v$appVersion Rev $appRevision',
            style: const TextStyle(
              color: AppColors.textMid,
              fontSize: kFont,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          _dot(),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              '$appCopyright  ·  $appEmail  ·  Licencia $appLicense',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot() => Container(
        width: 4,
        height: 4,
        decoration: const BoxDecoration(
          color: AppColors.textLow,
          shape: BoxShape.circle,
        ),
      );

  Widget _content(HardwareInfo hw) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: LayoutBuilder(
              builder: (context, c) {
                const gap = 18.0;
                // 2 columnas si hay espacio; si no, 1.
                final twoCols = c.maxWidth > 720;
                final gpuCards = _gpuCardList(hw.gpu);
                if (!twoCols) {
                  // Una sola columna: todas las fichas con el mismo gap (una por
                  // GPU intercaladas antes de Almacenamiento).
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _systemCard(hw.system),
                      const SizedBox(height: gap),
                      _cpuCard(hw.cpu),
                      const SizedBox(height: gap),
                      _boardCard(hw.board),
                      const SizedBox(height: gap),
                      _portsCard(hw.board),
                      const SizedBox(height: gap),
                      _ramCard(hw.memory),
                      for (final gc in gpuCards) ...[
                        const SizedBox(height: gap),
                        gc,
                      ],
                      const SizedBox(height: gap),
                      _disksCard(hw),
                    ],
                  );
                }
                // Masonry real: cada ficha se coloca en la columna más corta,
                // así no quedan huecos por diferencia de altura.
                final cards = [
                  _systemCard(hw.system),
                  _cpuCard(hw.cpu),
                  _boardCard(hw.board),
                  _portsCard(hw.board),
                  _ramCard(hw.memory),
                  ...gpuCards,
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MasonryGridView.count(
                      crossAxisCount: 2,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: cards.length,
                      itemBuilder: (context, i) => cards[i],
                    ),
                    const SizedBox(height: gap),
                    _disksCard(hw),
                  ],
                );
        },
      ),
    );
  }

  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 18, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory_rounded, color: AppColors.accent, size: 26),
          const SizedBox(width: 10),
          const Text(
            'PCInfo',
            style: TextStyle(
              color: AppColors.textHi,
              fontSize: kFont,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              children: [
                Flexible(
                    child: _chip(
                        Icons.dns_rounded, _hw?.system.hostname ?? '—')),
                const SizedBox(width: 8),
                Flexible(
                    child: _chip(
                        Icons.terminal_rounded, _hw?.system.distro ?? '—')),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _saveButton(),
          const SizedBox(width: 8),
          _refreshButton(),
        ],
      ),
    );
  }

  /// Guardar: exporta lo que se está viendo, según la pestaña activa. TODOS los
  /// reportes salen en Markdown (.md) — regla del proyecto: se leen igual en
  /// cualquier editor y pegados en un informe o un ticket conservan sus tablas.
  /// Siempre abre el diálogo del sistema para elegir carpeta y nombre (ver
  /// `_guardaConDialogo` en report.dart).
  Widget _saveButton() {
    final habilitado = switch (_tab) {
      _tabErroresIdx => _errores != null,
      _tabSoftwareIdx => _software != null,
      _tabControladoresIdx => _controladores != null,
      _tabBateriaIdx => _bateria != null,
      _tabDiscosIdx => _hw != null && !_discosCargando,
      _tabArranquesIdx => _arranques != null,
      // Hardware: hasta que llegue la salud de los discos el reporte saldría
      // sin S.M.A.R.T. y parecería que el equipo no la reporta.
      _ => _hw != null && !_discosCargando,
    };
    return Material(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: habilitado ? _onSave : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.save_alt_rounded,
                  size: 16,
                  color: habilitado ? AppColors.textMid : AppColors.textLow),
              const SizedBox(width: 6),
              Text('Guardar',
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

  Future<void> _onSave() async {
    try {
      final equipo = _hw?.system.hostname ?? '';
      final path = switch (_tab) {
        _tabErroresIdx => await saveErroresReport(_errores!, equipo),
        _tabSoftwareIdx => await saveSoftwareReport(_software!, equipo),
        _tabControladoresIdx =>
          await saveControladoresReport(_controladores!, equipo),
        _tabBateriaIdx => await saveBateriaReport(_bateria!, equipo),
        _tabDiscosIdx => await saveDiscosReport(_hw!.disks, equipo),
        _tabArranquesIdx => await saveArranquesReport(_arranques!, equipo),
        _ => await saveReport(_hw!),
      };
      if (path == null) return; // el usuario cerró el selector: no guardó nada
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.surfaceAlt,
        content: Text('Reporte guardado en: $path',
            style: const TextStyle(color: AppColors.textHi, fontSize: kFont)),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.surfaceAlt,
        content: Text('No se pudo guardar el reporte: $e',
            style: const TextStyle(color: Color(0xFFF2768D), fontSize: kFont)),
      ));
    }
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textMid),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style:
                    const TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ),
        ],
      ),
    );
  }

  Widget _refreshButton() {
    return Material(
      color: AppColors.accentDim.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: _refresh,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh_rounded, size: 16, color: AppColors.accent),
              SizedBox(width: 6),
              Text('Refrescar',
                  style: TextStyle(
                      color: AppColors.accent,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Tarjetas por categoría ----

  Widget _systemCard(SystemInfo s) {
    return SpecCard(
      icon: Icons.computer_rounded,
      accent: AppColors.system,
      title: 'Sistema operativo',
      rows: [
        SpecRow('Sistema', s.distro),
        SpecRow('Nombre del equipo', s.hostname),
        SpecRow('Kernel', s.kernel),
        SpecRow('Arquitectura', s.arch),
        if (s.desktop.isNotEmpty) SpecRow('Escritorio', s.desktop),
      ],
    );
  }

  Widget _cpuCard(CpuInfo c) {
    return SpecCard(
      icon: Icons.developer_board_rounded,
      accent: AppColors.cpu,
      title: 'Procesador (CPU)',
      rows: [
        SpecRow('Fabricante', cleanVendor(c.vendor)),
        SpecRow('Modelo', c.model),
        SpecRow('Núcleos', '${c.cores}'),
        SpecRow('Hilos', '${c.threads}'),
        SpecRow('Frecuencia base', formatMhz(c.baseMhz)),
        // La máxima (turbo) no está disponible en todas las plataformas (Windows
        // no la expone) → solo se muestra si el backend la reportó.
        if (c.maxMhz > 0) SpecRow('Frecuencia máxima', formatMhz(c.maxMhz)),
      ],
    );
  }

  Widget _boardCard(BoardInfo b) {
    return SpecCard(
      icon: Icons.dashboard_customize_rounded,
      accent: AppColors.board,
      title: 'Tarjeta madre',
      rows: [
        SpecRow('Fabricante', b.vendor),
        SpecRow('Modelo', b.product),
        // Tamaño y Versión solo si el hardware los reporta (muchas placas no
        // exponen el form factor en DMI, y algunas ponen versiones basura).
        if (b.formFactor.isNotEmpty) SpecRow('Tamaño', b.formFactor),
        if (b.version.isNotEmpty) SpecRow('Versión', b.version),
        SpecRow('BIOS', '${b.biosVendor} ${b.biosVersion}'.trim()),
        SpecRow('Fecha BIOS', b.biosDate),
      ],
    );
  }

  /// Ficha "Ranuras y puertos": qué sitios de ampliación tiene la placa y
  /// cuáles quedan libres. Es la pregunta de taller que el inventario no
  /// respondía —"¿le cabe otro disco?", "¿tiene M.2?"— porque solo enseñaba lo
  /// que ya está conectado.
  Widget _portsCard(BoardInfo b) {
    final rows = <SpecRow>[];

    if (b.sataTotal > 0) {
      final det = b.sataVerificado
          ? '${b.sataTotal} conectores'
          : '${b.sataTotal} puertos (del chipset)';
      rows.add(SpecRow('Puertos SATA', det));
      rows.add(SpecRow('SATA con disco', '${b.sataUsed}'));
      if (b.sataFree >= 0) rows.add(SpecRow('SATA libres', '${b.sataFree}'));
    }

    final m2 = b.m2Slots;
    if (m2.isNotEmpty) {
      rows.add(SpecRow('Ranuras M.2', BoardInfo.resumenRanuras(m2)));
    }
    final pcie = b.pcieSlots;
    if (pcie.isNotEmpty) {
      rows.add(SpecRow('Ranuras PCIe', BoardInfo.resumenRanuras(pcie)));
    }
    if (rows.isEmpty) {
      rows.add(const SpecRow('Estado', 'No disponible'));
    }

    return SpecCard(
      icon: Icons.settings_input_component_rounded,
      accent: AppColors.ports,
      title: 'Ranuras y puertos',
      rows: rows,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _slotsExpansion(b),
          if (b.portsNote.isNotEmpty) _avisoPuertos(b.portsNote),
          if (b.slots.isEmpty && b.sataTotal == 0)
            _avisoPuertos(
                'El firmware de esta placa no declara sus ranuras y el modelo '
                'no está en el catálogo verificado.')
          else if (b.portsSource != 'catalogo')
            _avisoPuertos(
                'Ranuras y puertos según el firmware; el chipset puede exponer '
                'más puertos de los que la placa trae cableados (modelo no '
                'verificado en el catálogo).'),
        ],
      ),
    );
  }

  /// Lista de ranuras, una por línea, con su estado. Las ocupadas dicen QUÉ las
  /// ocupa; las que no se pudieron leer dicen "Sin dato" en vez de "Libre".
  Widget _slotsExpansion(BoardInfo b) {
    if (b.slots.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (final s in b.slots) {
      final etiqueta = s.label == s.spec ? s.spec : '${s.label}  ·  ${s.spec}';
      // Quién ocupa la ranura va a la IZQUIERDA, con el resto del texto: a la
      // derecha solo cabe una palabra sin que se salga en pantalla estrecha.
      final izq = s.ocupada && s.usedBy.isNotEmpty ? '$etiqueta  ·  ${s.usedBy}' : etiqueta;
      rows.add(_slotTile(
        icon: s.ocupada ? Icons.check_box_rounded : Icons.crop_square_rounded,
        iconColor: s.ocupada ? AppColors.ports : AppColors.textLow,
        left: izq,
        right: s.ocupada ? 'Ocupada' : (s.libre ? 'Libre' : 'Sin dato'),
        rightColor: s.ocupada ? AppColors.textHi : AppColors.textLow,
        dimmed: !s.ocupada,
      ));
    }
    return Column(children: rows);
  }

  /// Aviso al pie de la ficha de ranuras (mismo estilo que el de la RAM).
  Widget _avisoPuertos(String texto) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 14, color: AppColors.textLow),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              texto,
              style: const TextStyle(
                color: AppColors.textLow,
                fontSize: kFont - 1,
                fontStyle: FontStyle.italic,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ramCard(MemoryInfo m) {
    final rows = <SpecRow>[
      SpecRow('Total', formatBytes(m.totalBytes)),
      SpecRow('Montaje', m.soldered ? 'Soldada (no ampliable)' : 'Ranuras (ampliable)'),
    ];
    if (m.totalSlots > 0) {
      final libres = m.freeSlots;
      rows.add(SpecRow('Ranuras',
          '${m.modules.length} de ${m.totalSlots} ocupadas'));
      rows.add(SpecRow('Ranuras libres', '$libres'));
    } else {
      rows.add(SpecRow('Módulos', '${m.modules.length}'));
    }
    if (m.maxCapacityBytes > 0) {
      rows.add(SpecRow('Capacidad máx.', formatBytes(m.maxCapacityBytes)));
    }
    // Aviso: cuando ranuras/capacidad NO vienen del catálogo verificado sino del
    // firmware SMBIOS, que en algunas placas miente (ranuras fantasma). No aplica
    // a RAM soldada (ahí no hay ranuras que ampliar).
    final mostrarAviso = !m.slotsVerified && !m.soldered && m.totalSlots > 0;
    return SpecCard(
      icon: Icons.memory_rounded,
      accent: AppColors.ram,
      title: 'Memoria RAM',
      rows: rows,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _slotsList(m),
          if (mostrarAviso) _firmwareCaveat(),
        ],
      ),
    );
  }

  /// Aviso sutil de que ranuras/capacidad máx. salen del firmware (no del
  /// catálogo verificado) y por tanto podrían no coincidir con la placa real.
  Widget _firmwareCaveat() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: AppColors.textLow),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Ranuras y capacidad máx. según el firmware; puede no coincidir '
              'con la placa (modelo no verificado en el catálogo).',
              style: TextStyle(
                color: AppColors.textLow,
                fontSize: kFont - 1,
                fontStyle: FontStyle.italic,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Una ficha POR tarjeta gráfica: si hay 1, 2 o N GPU, se crea una ficha por
  /// cada una (no una sola ficha con GPU 1 / GPU 2). Si no hay ninguna, una
  /// ficha de "No detectada".
  List<Widget> _gpuCardList(GpuInfo g) {
    if (g.cards.isEmpty) {
      return const [
        SpecCard(
          icon: Icons.videogame_asset_rounded,
          accent: AppColors.gpu,
          title: 'Tarjeta gráfica (GPU)',
          rows: [SpecRow('Estado', 'No detectada')],
        ),
      ];
    }
    final multi = g.cards.length > 1;
    return [
      for (final (i, card) in g.cards.indexed)
        SpecCard(
          icon: Icons.videogame_asset_rounded,
          accent: AppColors.gpu,
          // Con varias GPU se numera y se indica integrada/dedicada en el título.
          title: multi
              ? 'Tarjeta gráfica ${i + 1} · ${_gpuKind(card)}'
              : 'Tarjeta gráfica (GPU)',
          rows: [
            SpecRow('Fabricante', cleanVendor(card.vendor)),
            SpecRow('Modelo', card.product),
            SpecRow('Tipo', _gpuKind(card)),
            if (card.memoryBytes > 0)
              SpecRow('VRAM', formatBytes(card.memoryBytes)),
            SpecRow('Driver', card.driver),
          ],
        ),
    ];
  }

  /// Heurística para distinguir GPU integrada (del CPU) de dedicada. Se normaliza
  /// el modelo quitando "(tm)"/"(r)" para que "AMD Radeon(TM) Graphics" (el iGPU
  /// de los Ryzen) cuente como integrada y no como dedicada.
  String _gpuKind(GpuCard card) {
    final v = card.vendor.toLowerCase();
    final p = card.product
        .toLowerCase()
        .replaceAll('(tm)', '')
        .replaceAll('(r)', '');
    final integrada = v.contains('intel') ||
        p.contains('uhd') ||
        p.contains('iris') ||
        p.contains('vega') ||
        p.contains('radeon graphics') ||
        p.contains('raphael') ||
        p.contains('cezanne') ||
        p.contains('renoir') ||
        p.contains('phoenix') ||
        p.contains('rembrandt') ||
        p.contains('hawk point');
    return integrada ? 'Integrada' : 'Dedicada';
  }

  Widget _disksCard(HardwareInfo hw) {
    final disks = hw.disks;
    // Mientras llega la segunda fase no se puede saber todavía si un disco
    // reporta salud o no: se avisa que se está leyendo, en vez de mostrar el
    // aviso de "SIN SMART" (que aparecería siempre y sería falso).
    final warning = _discosCargando ? _leyendoSaludBox() : _smartWarning(hw);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.disk.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.storage_rounded,
                    color: AppColors.disk, size: 21),
              ),
              const SizedBox(width: 12),
              const Text(
                'Almacenamiento',
                style: TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (warning != null) ...[
            warning,
            const SizedBox(height: 14),
          ],
          if (disks.isEmpty)
            const Text('No se detectaron discos',
                style: TextStyle(color: AppColors.textMid, fontSize: kFont))
          else
            ...disks.map(_diskRow),
        ],
      ),
    );
  }

  /// Aviso accionable cuando hay discos SIN SMART. Distingue la causa con el
  /// diagnóstico del backend:
  ///   - falta smartctl.exe  → reinstalar (rojo).
  ///   - sin permisos admin  → botón "Reintentar como administrador" (ámbar).
  ///   - elevado y con smartctl pero igual sin SMART → limitación real (gris):
  ///     puente USB o controladora RAID que no traducen los comandos.
  /// Devuelve null si no hay nada que avisar (todos con SMART, o Linux con root).
  Widget? _smartWarning(HardwareInfo hw) {
    // Los medios extraíbles (memoria USB, tarjeta) no reportan salud por su
    // naturaleza: no son motivo para avisar de que falta smartctl o permisos.
    final anyMissing = hw.disks.any((d) => !d.smartAvailable && !d.removable);
    if (!anyMissing) return null;
    final diag = hw.diag;

    if (!diag.smartctlFound) {
      return _warnBox(
        color: const Color(0xFFF2768D),
        icon: Icons.report_gmailerrorred_rounded,
        title: 'Falta el componente para leer discos (smartctl)',
        detail:
            'La salud de los discos no se puede leer porque no se encontró smartctl. '
            'Reinstala PCInfo desde el instalador oficial para restaurarlo.',
      );
    }

    // Sin elevación → requiere admin/root. En Windows la GUI puede relanzar el
    // backend elevado con UAC (botón); en Linux el backend va como servicio root,
    // así que solo se informa cómo restaurarlo.
    if (!diag.elevated) {
      final canRetry = diag.isWindows && widget.launcher != null;
      return _warnBox(
        color: const Color(0xFFE3A84B),
        icon: Icons.admin_panel_settings_rounded,
        title: diag.isWindows
            ? 'La salud de los discos requiere permisos de administrador'
            : 'La salud de los discos requiere ejecutarse como root',
        detail: diag.isWindows
            ? 'Para leer el estado y el desgaste (S.M.A.R.T.) de los discos, PCInfo '
                'necesita ejecutarse como administrador. Windows pedirá confirmación.'
            : 'El servicio de PCInfo debe correr como root para leer el S.M.A.R.T. '
                'de los discos. Reinstala el paquete o inicia el servicio con privilegios.',
        action: !canRetry
            ? null
            : FilledButton.icon(
                onPressed: _elevating ? null : _retryElevated,
                icon: _elevating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.shield_rounded, size: 16),
                label: Text(_elevating
                    ? 'Solicitando permiso…'
                    : 'Reintentar como administrador'),
              ),
      );
    }

    // Elevado y con smartctl, pero algún disco sigue sin SMART: limitación real.
    return _warnBox(
      color: AppColors.textMid,
      icon: Icons.info_outline_rounded,
      title: 'Algunos discos no exponen S.M.A.R.T.',
      detail:
          'Suele pasar con discos en gabinetes USB o tras una controladora RAID, '
          'que no dejan pasar los comandos de estado. El resto de datos es correcto.',
    );
  }

  Widget _warnBox({
    required Color color,
    required IconData icon,
    required String title,
    required String detail,
    Widget? action,
  }) {
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
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: kFont,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(detail,
                    style: const TextStyle(
                        color: AppColors.textMid, fontSize: kFont, height: 1.35)),
                if (action != null) ...[
                  const SizedBox(height: 12),
                  action,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _diskRow(DiskInfo d) {
    final isSsd = d.type.toLowerCase().contains('ssd') ||
        d.bus.toLowerCase() == 'nvme';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isSsd ? Icons.bolt_rounded : Icons.album_rounded,
                  size: 20, color: AppColors.disk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.model,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textHi,
                              fontSize: kFont,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _typeBadge(d.type),
                        const SizedBox(width: 8),
                        _healthBadge(d),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${d.name}   ·   Serie: ${d.serial}   ·   Bus: ${d.bus.toUpperCase()}'
                      '${d.port.isEmpty ? "" : "   ·   Conectado en: ${d.port}"}',
                      style: const TextStyle(
                          color: AppColors.textLow, fontSize: kFont),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                formatDiskCap(d.sizeBytes),
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (d.hasUsage) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 12),
            _diskUsage(d),
          ],
          if (d.smartAvailable) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 12),
            _diskMetrics(d),
          ],
          // Solo en Windows: ahí la salud de un disco externo se consigue
          // sondeando tipos de puente USB, y eso es lo que fuerza el botón. En
          // Linux el S.M.A.R.T. se pide igual a todos los discos, no hay nada
          // que forzar.
          if (d.removable &&
              !d.smartAvailable &&
              !_discosCargando &&
              (_hw?.diag.isWindows ?? false)) ...[
            const SizedBox(height: 10),
            _botonForzarSalud(d),
          ],
        ],
      ),
    );
  }

  /// Uso del sistema de archivos: Capacidad / Ocupado / Disponible (GB y %)
  /// más una barra visual del porcentaje ocupado.
  Widget _diskUsage(DiskInfo d) {
    final usedPct = d.usedPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            _metric('Capacidad', formatDiskCap(d.sizeBytes)),
            _metric('Ocupado',
                '${formatGB(d.usedBytes)}  (${usedPct.round()}%)'),
            _metric('Disponible',
                '${formatGB(d.availBytes)}  (${d.availPercent.round()}%)'),
          ],
        ),
        const SizedBox(height: 10),
        _usageBar(usedPct),
      ],
    );
  }

  Widget _usageBar(double usedPct) {
    final value = (usedPct / 100).clamp(0.0, 1.0);
    // Verde si hay espacio; ámbar al llenarse; rojo casi lleno.
    final color = usedPct >= 90
        ? const Color(0xFFF2768D)
        : usedPct >= 75
            ? const Color(0xFFE3A84B)
            : AppColors.disk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            backgroundColor: AppColors.bg,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text('${usedPct.round()}% usado',
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
      ],
    );
  }

  Widget _diskMetrics(DiskInfo d) {
    final items = <Widget>[];
    if (d.writtenBytes > 0) {
      items.add(_metric('Escrituras totales', formatBytes(d.writtenBytes)));
    }
    if (d.readBytes > 0) {
      items.add(_metric('Lecturas totales', formatBytes(d.readBytes)));
    }
    if (d.lifePercentUsed >= 0) {
      items.add(_metric('Vida restante', '${100 - d.lifePercentUsed}%'));
    }
    items.add(_metric('Horas encendido', '${d.powerOnHours} h'));
    items.add(_metric('Ciclos de encendido', '${d.powerCycles}'));
    items.add(_metric('Sectores reasignados', '${d.reallocatedSectors}',
        warn: d.reallocatedSectors > 0));
    return Wrap(spacing: 28, runSpacing: 12, children: items);
  }

  Widget _metric(String label, String value, {bool warn = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: warn ? const Color(0xFFE3A84B) : AppColors.textHi,
                fontSize: kFont,
                fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _typeBadge(String type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.disk.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.disk.withValues(alpha: 0.30)),
      ),
      child: Text(type,
          style: const TextStyle(color: AppColors.disk, fontSize: kFont)),
    );
  }

  /// Botón para leer la salud de un disco tomado por memoria extraíble. Es la
  /// salida para el gabinete externo (SSD/NVMe por USB) que se declara removible:
  /// ahí sí hay salud que leer, pero sondearlo tarda y por eso no se hace solo.
  Widget _botonForzarSalud(DiskInfo d) {
    final leyendo = _forzandoSalud.contains(d.name);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: leyendo ? null : () => _forzarSalud(d),
        icon: leyendo
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent),
              )
            : const Icon(Icons.health_and_safety_outlined, size: 16),
        label: Text(
          leyendo
              ? 'Leyendo la salud…'
              : 'Leer salud igual (si es un disco en gabinete USB)',
          style: const TextStyle(fontSize: kFont),
        ),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      ),
    );
  }

  /// Aviso mientras se lee la salud de los discos (segunda fase del arranque).
  Widget _leyendoSaludBox() => _warnBox(
        color: AppColors.textLow,
        icon: Icons.hourglass_top_rounded,
        title: 'Leyendo la salud de los discos (S.M.A.R.T.)…',
        detail:
            'El resto del inventario ya está listo. Esta parte puede tardar unos '
            'segundos más si hay memorias USB, lectores de tarjetas o discos '
            'externos conectados, porque hay que preguntarle a cada uno.',
      );

  /// Etiqueta de estado del disco. [extra] agrega el iconito de "ver detalles".
  Widget _badgeSimple(Color c, String label, IconData icon,
          {bool extra = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: c, fontSize: kFont, fontWeight: FontWeight.w600)),
            if (extra) ...[
              const SizedBox(width: 4),
              Icon(Icons.info_outline_rounded, size: 12, color: c),
            ],
          ],
        ),
      );

  Widget _healthBadge(DiskInfo d) {
    if ((_discosCargando || _forzandoSalud.contains(d.name)) &&
        !d.smartAvailable) {
      return _badgeSimple(
          AppColors.textLow, 'LEYENDO…', Icons.hourglass_top_rounded);
    }
    // Una memoria USB o una tarjeta no reporta salud: decirlo así es más honesto
    // que "SIN SMART", que sugiere que algo falló.
    if (d.removable && !d.smartAvailable) {
      return _badgeSimple(AppColors.textLow, 'MEMORIA EXTRAÍBLE', Icons.usb_rounded);
    }
    final h = d.healthStatus;
    late final Color c;
    late final String label;
    late final IconData icon;
    switch (h) {
      case DiskHealth.good:
        c = const Color(0xFF3FB950);
        label = 'SALUDABLE';
        icon = Icons.check_circle_rounded;
        break;
      case DiskHealth.warning:
        c = const Color(0xFFE3A84B);
        label = 'ADVERTENCIA';
        icon = Icons.warning_amber_rounded;
        break;
      case DiskHealth.fail:
        c = const Color(0xFFF2768D);
        label = 'PELIGRO';
        icon = Icons.error_rounded;
        break;
      case DiskHealth.unknown:
        c = AppColors.textLow;
        label = 'SIN SMART';
        icon = Icons.help_outline_rounded;
        break;
    }
    // Si hay problemas, la etiqueta es clicable y abre el modal explicativo.
    final clickable = d.issues.isNotEmpty;
    final badge = _badgeSimple(c, label, icon, extra: clickable);
    if (!clickable) return badge;
    return Tooltip(
      message: 'Ver ${d.issues.length} problema(s) detectado(s)',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _showDiskIssues(d),
          child: badge,
        ),
      ),
    );
  }

  /// Modal con la lista de problemas del disco: cada uno con su severidad, qué
  /// significa y la consecuencia. Se abre al tocar la etiqueta de salud.
  void _showDiskIssues(DiskInfo d) {
    final fail = d.healthStatus == DiskHealth.fail;
    final headColor =
        fail ? const Color(0xFFF2768D) : const Color(0xFFE3A84B);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Encabezado.
              Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 16, 16),
                decoration: BoxDecoration(
                  color: headColor.withValues(alpha: 0.12),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(14)),
                ),
                child: Row(
                  children: [
                    Icon(
                        fail
                            ? Icons.error_rounded
                            : Icons.warning_amber_rounded,
                        color: headColor,
                        size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fail
                                ? 'Disco en peligro'
                                : 'Disco con advertencias',
                            style: TextStyle(
                                color: headColor,
                                fontSize: kFont + 3,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            d.model,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textMid, fontSize: kFont),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: AppColors.textMid, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              // Aviso general.
              if (fail)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Text(
                    'Este disco muestra daños. NO es fiable: respalda tus datos '
                    'y considera reemplazarlo.',
                    style:
                        TextStyle(color: AppColors.textHi, fontSize: kFont),
                  ),
                ),
              // Lista de problemas.
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final iss in d.issues) _issueTile(iss),
                    ],
                  ),
                ),
              ),
              // Pie.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cerrar'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _issueTile(DiskIssue iss) {
    final danger = iss.severity == 'fail';
    final c = danger ? const Color(0xFFF2768D) : const Color(0xFFE3A84B);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
              danger
                  ? Icons.error_rounded
                  : Icons.warning_amber_rounded,
              size: 18,
              color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(iss.title,
                          style: TextStyle(
                              color: AppColors.textHi,
                              fontSize: kFont,
                              fontWeight: FontWeight.w700)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(danger ? 'PELIGRO' : 'ADVERTENCIA',
                          style: TextStyle(
                              color: c,
                              fontSize: kFont - 2,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(iss.detail,
                    style: const TextStyle(
                        color: AppColors.textMid,
                        fontSize: kFont,
                        height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Auxiliares ----

  Widget _slotsList(MemoryInfo m) {
    if (m.modules.isEmpty && m.freeSlots <= 0) return const SizedBox.shrink();
    final rows = <Widget>[];
    // Ranuras ocupadas.
    for (final mod in m.modules) {
      final ff = mod.formFactor.isEmpty ? '' : '  ·  ${mod.formFactor}';
      rows.add(_slotTile(
        icon: Icons.sd_card_rounded,
        iconColor: AppColors.ram,
        left: '${mod.location}$ff',
        right:
            '${formatBytes(mod.sizeBytes)}  ${mod.type} ${mod.speedMhz > 0 ? "${mod.speedMhz}MHz" : ""}'
                .trim(),
        rightColor: AppColors.textHi,
      ));
    }
    // Ranuras libres (placeholder por cada una).
    final libres = m.freeSlots;
    for (var i = 0; i < libres; i++) {
      rows.add(_slotTile(
        icon: Icons.crop_square_rounded,
        iconColor: AppColors.textLow,
        left: 'Ranura libre',
        right: 'Vacía',
        rightColor: AppColors.textLow,
        dimmed: true,
      ));
    }
    return Column(children: rows);
  }

  Widget _slotTile({
    required IconData icon,
    required Color iconColor,
    required String left,
    required String right,
    required Color rightColor,
    bool dimmed = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: dimmed ? AppColors.bg : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: dimmed
                ? AppColors.border.withValues(alpha: 0.5)
                : AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 9),
          Expanded(
            child: Text(left,
                style:
                    TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ),
          Text(right,
              style: TextStyle(
                  color: rightColor,
                  fontSize: kFont,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
