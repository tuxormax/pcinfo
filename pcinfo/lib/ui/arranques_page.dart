import 'package:flutter/material.dart';

import '../models/arranques.dart';
import '../services/arranques_service.dart';
import '../theme.dart';

const _ambar = Color(0xFFE3A84B);
const _rojo = Color(0xFFF2768D);
const _azul = Color(0xFF6AA9FF);

/// Las dos horas de cada fila van de colores distintos y siempre los mismos:
/// **amarillo el encendido, verde el apagado**. Leyendo la columna en vertical
/// se ve a qué hora prende y a qué hora se apaga el equipo sin leer una palabra,
/// y salta a la vista el día que se salió de su horario.
const _colorEncendido = _ambar;
const _colorApagado = AppColors.accent;

/// Pestaña "Encendidos y apagados": qué le pasó al equipo mientras nadie lo
/// miraba.
///
/// Tres listas, cada una con su pregunta:
///   · Encendidos — ¿cuándo estuvo prendido y cómo terminó cada vez?
///   · Tareas automáticas — ¿qué hace el equipo solo, y corrió la última vez?
///   · Al iniciar sesión — ¿qué se lanza con la sesión y está vivo ahora?
///
/// Por defecto se muestra lo que se le AÑADIÓ al equipo y se esconde lo que trae
/// el sistema: un escritorio corriente trae sesenta programas de autoarranque y
/// treinta temporizadores, y entre ese ruido no se distingue lo propio.
class ArranquesPage extends StatefulWidget {
  final ArranquesInfo data;

  /// Sección que se muestra al abrir (0 encendidos, 1 tareas, 2 inicio). Solo
  /// lo usan la vista previa de `tool/` y las pruebas para entrar directos a
  /// una sección; la app siempre abre por los encendidos.
  final int seccionInicial;

  /// Activa el diario permanente del sistema (pide contraseña de
  /// administrador). Null = sin conexión al servicio: el aviso se muestra sin
  /// botón, con la explicación de siempre.
  final Future<ResultadoAccion> Function()? onActivarDiario;

  /// Vuelve a pedir los datos. Se llama tras activar el diario.
  final VoidCallback? onRecargar;

  const ArranquesPage({
    super.key,
    required this.data,
    this.seccionInicial = 0,
    this.onActivarDiario,
    this.onRecargar,
  });

  @override
  State<ArranquesPage> createState() => _ArranquesPageState();
}

class _ArranquesPageState extends State<ArranquesPage> {
  late int _seccion = widget.seccionInicial;
  bool _verSistema = false;
  String _busca = '';

  /// true mientras se está pidiendo la contraseña y aplicando el cambio.
  bool _activandoDiario = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _resumen(d),
              if (d.reason.isNotEmpty) ...[
                const SizedBox(height: 12),
                _aviso(d.reason),
              ],
              const SizedBox(height: 12),
              _selector(d),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _cuerpo(d)),
      ],
    );
  }

  // ---- Resumen: lo primero que hay que saber ----

  Widget _resumen(ArranquesInfo d) {
    final fallidas = d.tareasFallidas.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: d.bruscos > 0 ? _rojo.withValues(alpha: 0.45) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.power_settings_new_rounded,
                  size: 18, color: d.bruscos > 0 ? _rojo : AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  d.resumen,
                  style: const TextStyle(
                    color: AppColors.textHi,
                    fontSize: kFont,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pastilla('${d.normales} apagados normales', AppColors.accent),
              if (d.reinicios > 0) _pastilla('${d.reinicios} reinicios', _azul),
              if (d.bruscos > 0) _pastilla('${d.bruscos} apagones bruscos', _rojo),
              _pastilla('${d.tareasPropias.length} tareas propias del equipo',
                  AppColors.textMid),
              if (fallidas > 0) _pastilla('$fallidas tareas fallaron', _rojo),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pastilla(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(texto,
          style: TextStyle(
              color: color, fontSize: kFont, fontWeight: FontWeight.w600)),
    );
  }

  // ---- Selector de sección ----

  Widget _selector(ArranquesInfo d) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _botonSeccion(0, Icons.history_rounded, 'Encendidos y apagados',
              d.sessions.length),
          const SizedBox(width: 8),
          _botonSeccion(1, Icons.schedule_rounded, 'Tareas automáticas',
              d.tasks.length),
          const SizedBox(width: 8),
          _botonSeccion(2, Icons.rocket_launch_rounded, 'Al iniciar sesión',
              d.startup.length),
        ],
      ),
    );
  }

  Widget _botonSeccion(int idx, IconData icono, String texto, int cuantos) {
    final activo = _seccion == idx;
    return Material(
      color: activo ? AppColors.surfaceAlt : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() {
          _seccion = idx;
          _busca = '';
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: activo ? AppColors.accentDim : AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono,
                  size: 15,
                  color: activo ? AppColors.accent : AppColors.textMid),
              const SizedBox(width: 7),
              Text('$texto ($cuantos)',
                  style: TextStyle(
                      color: activo ? AppColors.textHi : AppColors.textMid,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cuerpo(ArranquesInfo d) => switch (_seccion) {
        1 => _listaTareas(d),
        2 => _listaInicio(d),
        _ => _listaSesiones(d),
      };

  // ---- Sección 1: encendidos ----

  Widget _listaSesiones(ArranquesInfo d) {
    if (d.sessions.isEmpty) {
      return _vacio('No hay historial de encendidos que mostrar.');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        if (d.sessionsNote.isNotEmpty) ...[
          _aviso(d.sessionsNote,
              accion: d.journalVolatile && widget.onActivarDiario != null
                  ? _botonActivarDiario()
                  : null),
          const SizedBox(height: 12),
        ],
        for (final g in d.sesionesPorDia) ...[
          _encabezadoDia(g),
          ...g.sesiones.map((s) => _FilaSesion(sesion: s)),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// Encabezado de cada día. Lleva el número de encendidos porque un día con
  /// cinco es en sí mismo un dato: el equipo se estuvo reiniciando.
  Widget _encabezadoDia(GrupoDia g) {
    final rojo = g.bruscos > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        children: [
          Icon(rojo ? Icons.warning_amber_rounded : Icons.calendar_today_rounded,
              size: 15, color: rojo ? _rojo : AppColors.textMid),
          const SizedBox(width: 8),
          Text(fechaLarga(g.dia),
              style: TextStyle(
                  color: rojo ? _rojo : AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2)),
          const SizedBox(width: 8),
          Text(
              g.sesiones.length == 1
                  ? '(1 encendido)'
                  : '(${g.sesiones.length} encendidos)',
              style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }

  // ---- Sección 2: tareas automáticas ----

  Widget _listaTareas(ArranquesInfo d) {
    final propias = _filtraTareas(d.tareasPropias);
    final sistema =
        _verSistema ? _filtraTareas(d.tareasDelSistema) : <TareaAutomatica>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: _barraFiltro(
            'Buscar tarea, comando o archivo…',
            'Ver también las del sistema',
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: (propias.isEmpty && sistema.isEmpty)
              ? _vacio(_busca.isNotEmpty
                  ? 'Ninguna tarea coincide con "$_busca".'
                  : 'Este equipo no tiene tareas automáticas propias. '
                      'Activa "ver también las del sistema" para ver las que trae Linux.')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    if (d.tasksNote.isNotEmpty) ...[
                      _aviso(d.tasksNote),
                      const SizedBox(height: 12),
                    ],
                    if (propias.isNotEmpty) ...[
                      _grupo('Añadidas a este equipo', propias.length,
                          Icons.push_pin_rounded, AppColors.accent),
                      ...propias.map((t) => _FilaTarea(tarea: t)),
                    ],
                    if (sistema.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _grupo('Vienen con el sistema', sistema.length,
                          Icons.settings_suggest_rounded, AppColors.textMid),
                      ...sistema.map((t) => _FilaTarea(tarea: t)),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  List<TareaAutomatica> _filtraTareas(List<TareaAutomatica> items) {
    if (_busca.isEmpty) return items;
    final q = _busca.toLowerCase();
    return items.where((e) => e.buscable.contains(q)).toList();
  }

  // ---- Sección 3: al iniciar sesión ----

  Widget _listaInicio(ArranquesInfo d) {
    final propios = _filtraInicio(d.inicioPropio);
    final sistema =
        _verSistema ? _filtraInicio(d.inicioDelSistema) : <ProgramaInicio>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: _barraFiltro(
            'Buscar programa o comando…',
            'Ver también los del escritorio',
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: (propios.isEmpty && sistema.isEmpty)
              ? _vacio(_busca.isNotEmpty
                  ? 'Ningún programa coincide con "$_busca".'
                  : 'Ningún programa propio se lanza al iniciar sesión. '
                      'Activa "ver también los del escritorio" para ver los del sistema.')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    if (d.startupNote.isNotEmpty) ...[
                      _aviso(d.startupNote),
                      const SizedBox(height: 12),
                    ],
                    if (propios.isNotEmpty) ...[
                      _grupo('De este usuario', propios.length,
                          Icons.person_rounded, AppColors.accent),
                      ...propios.map((p) => _FilaInicio(item: p)),
                    ],
                    if (sistema.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _grupo('Del escritorio, para todos los usuarios',
                          sistema.length, Icons.desktop_windows_rounded,
                          AppColors.textMid),
                      ...sistema.map((p) => _FilaInicio(item: p)),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  List<ProgramaInicio> _filtraInicio(List<ProgramaInicio> items) {
    if (_busca.isEmpty) return items;
    final q = _busca.toLowerCase();
    return items.where((e) => e.buscable.contains(q)).toList();
  }

  // ---- Piezas compartidas ----

  Widget _barraFiltro(String pista, String etiquetaInterruptor) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(child: _buscador(pista)),
          const SizedBox(width: 14),
          Transform.scale(
            scale: 0.8,
            child: Switch(
              value: _verSistema,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => setState(() => _verSistema = v),
            ),
          ),
          Flexible(
            child: Text(etiquetaInterruptor,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textMid, fontSize: kFont)),
          ),
        ],
      ),
    );
  }

  Widget _buscador(String pista) {
    return SizedBox(
      height: 34,
      child: TextField(
        style: const TextStyle(color: AppColors.textHi, fontSize: kFont),
        cursorColor: AppColors.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AppColors.surfaceAlt,
          hintText: pista,
          hintStyle: const TextStyle(color: AppColors.textLow, fontSize: kFont),
          prefixIcon: const Icon(Icons.search_rounded,
              size: 17, color: AppColors.textLow),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 34, minHeight: 34),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
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

  Widget _grupo(String titulo, int cuantos, IconData icono, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        children: [
          Icon(icono, size: 17, color: color),
          const SizedBox(width: 8),
          Text(titulo,
              style: TextStyle(
                  color: color,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2)),
          const SizedBox(width: 8),
          Text('($cuantos)',
              style:
                  const TextStyle(color: AppColors.textLow, fontSize: kFont)),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }

  Widget _aviso(String texto, {Widget? accion}) {
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(texto,
                    style: const TextStyle(
                        color: AppColors.textHi, fontSize: kFont)),
                if (accion != null) ...[
                  const SizedBox(height: 10),
                  accion,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Un aviso que solo dice "esto se arregla creando una carpeta" deja el
  /// trabajo a medias: quien lo lee tiene que abrir una terminal y teclear tres
  /// comandos como administrador. El botón lo hace, pidiendo la contraseña con
  /// el diálogo del propio escritorio.
  Widget _botonActivarDiario() {
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: _activandoDiario ? null : _activarDiario,
        icon: _activandoDiario
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.shield_rounded, size: 16),
        label: Text(_activandoDiario
            ? 'Pidiendo permiso…'
            : 'Activar el diario permanente'),
      ),
    );
  }

  Future<void> _activarDiario() async {
    final accion = widget.onActivarDiario;
    if (accion == null) return;
    final seguir = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Activar el diario permanente',
            style: TextStyle(color: AppColors.textHi, fontSize: kFont + 3)),
        content: const Text(
          'El diario del sistema pasará a guardarse en disco, con un tope de '
          '500 MB, en vez de borrarse en cada apagado.\n\n'
          'Desde el próximo apagado quedará constancia de QUÉ ocurrió en cada '
          'sesión, no solo a qué hora empezó y terminó.\n\n'
          'Hace falta la contraseña de administrador: la pedirá el sistema.',
          style: TextStyle(color: AppColors.textMid, fontSize: kFont),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Activar')),
        ],
      ),
    );
    if (seguir != true) return;

    setState(() => _activandoDiario = true);
    ResultadoAccion r;
    try {
      r = await accion();
    } catch (e) {
      r = ResultadoAccion(
          ok: false,
          message: 'No se pudo activar el diario permanente.',
          detail: '$e');
    }
    if (!mounted) return;
    setState(() => _activandoDiario = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: AppColors.surfaceAlt,
      duration: const Duration(seconds: 8),
      content: SelectableText(
        r.detail.isEmpty ? r.message : '${r.message}\n\n${r.detail}',
        style: TextStyle(
            color: r.ok ? AppColors.textHi : _rojo, fontSize: kFont),
      ),
    ));
    if (r.ok) widget.onRecargar?.call();
  }

  Widget _vacio(String texto) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(texto,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMid, fontSize: kFont)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filas
// ---------------------------------------------------------------------------

/// Una sesión, en dos cuadros: **ENCENDIDO** con borde amarillo y **APAGADO**
/// con borde verde.
///
/// Los dos colores son siempre los mismos y están siempre en el mismo sitio, así
/// que recorriendo la columna se ve a qué hora prende y a qué hora se apaga el
/// equipo sin leer una palabra — y el día que se salió de su horario salta solo.
///
/// ⭐ Cuando una de las dos cosas **no llegó a ocurrir**, su cuadro se pone rojo
/// y lo dice con todas sus letras ("NO SE REALIZÓ EL APAGADO"), con el motivo
/// debajo y el último registro del sistema si lo hay. Es el caso que se viene a
/// buscar: pintar de verde un tirón de corriente diría lo contrario de lo que
/// pasó, y dejar el hueco en blanco obliga a adivinar.
class _FilaSesion extends StatelessWidget {
  final Sesion sesion;
  const _FilaSesion({required this.sesion});

  /// Debajo de este ancho los dos cuadros se apilan. Con menos, cada uno se
  /// queda en unos 250 px y la hora y su detalle empiezan a partirse.
  static const _anchoParaDosColumnas = 560.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < _anchoParaDosColumnas) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _cuadroEncendido(),
              const SizedBox(height: 8),
              _cuadroApagado(),
            ],
          );
        }
        // IntrinsicHeight para que los dos cuadros midan lo mismo: dentro de
        // una lista la altura no está acotada, y sin esto "estirar hasta la
        // altura del hermano" no tiene contra qué estirarse (constraints
        // infinitas) y el renderizado revienta.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _cuadroEncendido()),
              const SizedBox(width: 10),
              Expanded(child: _cuadroApagado()),
            ],
          ),
        );
      }),
    );
  }

  Widget _cuadroEncendido() {
    // Defensivo: si el registro no trae la hora de encendido, se dice, no se
    // deja el cuadro vacío.
    if (sesion.horaInicio.isEmpty) {
      return _cuadro(
        titulo: 'ENCENDIDO',
        icono: Icons.play_arrow_rounded,
        color: _rojo,
        fallo: 'NO SE REGISTRÓ EL ENCENDIDO',
        motivo: 'El registro de accesos no guarda la hora en que se encendió '
            'esta sesión.',
      );
    }
    return _cuadro(
      titulo: 'ENCENDIDO',
      icono: Icons.play_arrow_rounded,
      color: _colorEncendido,
      hora: sesion.horaInicio,
      detalles: [
        if (sesion.kernel.isNotEmpty) 'núcleo ${sesion.kernel}',
      ],
    );
  }

  Widget _cuadroApagado() {
    // No hubo apagado: ni ordenado ni de ninguna clase. Se dice en rojo, con el
    // porqué y con la última línea que el sistema alcanzó a escribir.
    if (sesion.fueBrusco) {
      return _cuadro(
        titulo: 'APAGADO',
        icono: Icons.flash_off_rounded,
        color: _rojo,
        fallo: 'NO SE REALIZÓ EL APAGADO',
        motivo: sesion.note.isNotEmpty
            ? sesion.note
            : 'El registro se corta de golpe, sin las líneas del apagado '
                'ordenado: corte de luz, apagado forzado o un cuelgue.',
        error: sesion.lastLine,
        detalles: [
          if (sesion.end.isNotEmpty) 'último registro a las ${sesion.horaFin}',
          if (sesion.duracion.isNotEmpty) 'estuvo encendido ${sesion.duracion}',
        ],
      );
    }
    // La sesión en curso no es un fallo: el apagado todavía no toca.
    if (sesion.enCurso) {
      return _cuadro(
        titulo: 'APAGADO',
        icono: Icons.play_circle_outline_rounded,
        color: AppColors.textMid,
        hora: 'sigue encendido',
        horaChica: true,
        detalles: [
          if (sesion.duracion.isNotEmpty) 'lleva ${sesion.duracion} encendido',
        ],
      );
    }
    return _cuadro(
      titulo: 'APAGADO',
      icono: sesion.ended == FinSesion.reinicio
          ? Icons.restart_alt_rounded
          : Icons.power_settings_new_rounded,
      color: sesion.ended == FinSesion.reinicio ? _azul : _colorApagado,
      hora: sesion.horaFin,
      detalles: [
        if (sesion.apagadoOtroDia) 'del ${sesion.diaFinCorto}',
        FinSesion.etiqueta(sesion.ended),
        if (sesion.duracion.isNotEmpty) 'estuvo encendido ${sesion.duracion}',
      ],
    );
  }

  /// Un cuadro. O lleva [hora] (ocurrió) o lleva [fallo] (no ocurrió), nunca
  /// las dos: es lo que separa de un vistazo un apagado de un apagón.
  Widget _cuadro({
    required String titulo,
    required IconData icono,
    required Color color,
    String hora = '',
    String fallo = '',
    String motivo = '',
    String error = '',
    List<String> detalles = const [],
    bool horaChica = false,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
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
                      fontSize: kFont - 2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1)),
            ],
          ),
          const SizedBox(height: 6),
          if (fallo.isNotEmpty)
            SelectableText(fallo,
                style: const TextStyle(
                    color: _rojo,
                    fontSize: kFont + 2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    height: 1.15))
          else
            SelectableText(hora,
                style: TextStyle(
                    color: color,
                    fontSize: horaChica ? kFont + 1 : kFont + 7,
                    fontWeight: FontWeight.w700,
                    height: 1.1)),
          if (motivo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(motivo,
                  style:
                      const TextStyle(color: AppColors.textHi, fontSize: kFont)),
            ),
          if (detalles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(detalles.join(' · '),
                  style: const TextStyle(
                      color: AppColors.textMid, fontSize: kFont)),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  'Último registro antes del corte:\n$error',
                  style: const TextStyle(
                      color: AppColors.textMid,
                      fontSize: kFont,
                      fontFamily: 'monospace'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Una tarea automática, con lo único que de verdad importa: cuándo corrió por
/// última vez y si terminó bien.
class _FilaTarea extends StatelessWidget {
  final TareaAutomatica tarea;
  const _FilaTarea({required this.tarea});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
            color: tarea.fallo
                ? _rojo.withValues(alpha: 0.45)
                : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icono, size: 16, color: _color),
              const SizedBox(width: 9),
              Expanded(
                child: SelectableText(tarea.name,
                    style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: kFont,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Text(EstadoTarea.etiqueta(tarea.state),
                  style: TextStyle(
                      color: _color,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          if (tarea.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 25),
              child: Text(tarea.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textMid, fontSize: kFont)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 25),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                if (tarea.trigger.isNotEmpty)
                  _dato(Icons.schedule_rounded, tarea.trigger),
                _dato(
                  Icons.history_rounded,
                  tarea.lastRun.isEmpty
                      ? tarea.ultimaVezTexto
                      : 'última vez: ${tarea.lastRun}'
                          '${tarea.result.isEmpty ? '' : ' · ${tarea.result}'}',
                  color: tarea.fallo ? _rojo : null,
                ),
                // Sin esta línea, un respaldo que sí se hace todas las noches se
                // lee como uno que no ha corrido nunca.
                if (tarea.lastRun.isEmpty && tarea.atShutdown)
                  _dato(Icons.info_outline_rounded,
                      'corre al apagar: no se puede saber desde la sesión siguiente'),
                if (tarea.nextRun.isNotEmpty)
                  _dato(Icons.event_rounded, 'próxima: ${tarea.nextRun}'),
              ],
            ),
          ),
          if (tarea.command.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 25),
              child: SelectableText(tarea.command,
                  maxLines: 2,
                  style: const TextStyle(
                      color: AppColors.textLow,
                      fontSize: kFont,
                      fontFamily: 'monospace')),
            ),
        ],
      ),
    );
  }

  Widget _dato(IconData icono, String texto, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icono, size: 13, color: color ?? AppColors.textLow),
        const SizedBox(width: 5),
        Text(texto,
            style: TextStyle(
                color: color ?? AppColors.textMid, fontSize: kFont)),
      ],
    );
  }

  Color get _color => switch (tarea.state) {
        EstadoTarea.fallido => _rojo,
        EstadoTarea.deshabilitado => AppColors.textLow,
        _ => AppColors.accent,
      };

  IconData get _icono => switch (tarea.kind) {
        TipoTarea.temporizador => Icons.timer_outlined,
        TipoTarea.cron => Icons.event_repeat_rounded,
        _ => Icons.settings_rounded,
      };
}

/// Un programa de autoarranque, con la columna que importa: si está corriendo.
class _FilaInicio extends StatelessWidget {
  final ProgramaInicio item;
  const _FilaInicio({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = !item.enabled
        ? AppColors.textLow
        : (item.running ? AppColors.accent : _ambar);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  !item.enabled
                      ? Icons.block_rounded
                      : (item.running
                          ? Icons.check_circle_outline_rounded
                          : Icons.radio_button_unchecked_rounded),
                  size: 16,
                  color: color),
              const SizedBox(width: 9),
              Expanded(
                child: SelectableText(item.name,
                    style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: kFont,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Text(
                  !item.enabled
                      ? 'Desactivado'
                      : (item.running ? 'En ejecución' : 'No está corriendo'),
                  style: TextStyle(
                      color: color,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          if (item.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 25),
              child: Text(item.note,
                  style: const TextStyle(
                      color: AppColors.textMid, fontSize: kFont)),
            ),
          if (item.command.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 25),
              child: SelectableText(item.command,
                  maxLines: 2,
                  style: const TextStyle(
                      color: AppColors.textLow,
                      fontSize: kFont,
                      fontFamily: 'monospace')),
            ),
        ],
      ),
    );
  }
}
