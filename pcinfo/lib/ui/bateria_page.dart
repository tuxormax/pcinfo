import 'package:flutter/material.dart';

import '../models/bateria.dart';
import '../theme.dart';

/// Ámbar de "ojo con esto" (mismo tono que los avisos del resto de la app).
const _ambar = Color(0xFFE3A84B);
const _rojo = Color(0xFFF2768D);

/// Pestaña "Batería": el informe de salud que Windows genera con powercfg (y en
/// Linux lo que publica el kernel), pero en español y explicado.
///
/// Por qué existe: el informe de Windows es una página en inglés, llena de mWh
/// y de tablas, que no dice en ningún momento si la batería está bien o hay que
/// cambiarla. Aquí lo primero que se ve es justo eso —el veredicto—, y debajo el
/// porqué en palabras normales. Los textos vienen redactados del backend para
/// que sean IDÉNTICOS en pantalla y en el reporte que se guarda.
class BateriaPage extends StatelessWidget {
  final BateriaInfo data;

  const BateriaPage({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final b = data.principal;
    if (b == null) {
      return _sinBateria(data);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _veredicto(b),
        const SizedBox(height: 14),
        _cifras(b),
        const SizedBox(height: 14),
        _repuesto(b),
        if (_hayDuraciones) ...[
          const SizedBox(height: 14),
          _duraciones(),
        ],
        if (b.notes.isNotEmpty) ...[
          const SizedBox(height: 14),
          _explicaciones(b),
        ],
        if (data.history.length > 1) ...[
          const SizedBox(height: 14),
          _historial(),
        ],
        const SizedBox(height: 14),
        _ficha(b),
        if (data.reason.isNotEmpty) ...[
          const SizedBox(height: 14),
          _aviso(data.reason),
        ],
        const SizedBox(height: 10),
        _pie(),
      ],
    );
  }

  bool get _hayDuraciones =>
      data.runtimeFullMin > 0 ||
      data.runtimeHeavyMin > 0 ||
      data.runtimeNowMin > 0;

  // ---- Lo primero que se ve: ¿cómo está la batería? ----

  Widget _veredicto(BateriaItem b) {
    final color = _colorSalud(b.healthLevel);
    final salud = b.healthPercent;
    return _tarjeta(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _anillo(salud, color),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wrap y no Row: el distintivo de la carga es una frase larga y
                // en una ventana estrecha desbordaba la fila.
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _distintivo(b.etiquetaSalud, color),
                    if (b.chargePercent >= 0)
                      _distintivo(
                        '${b.chargePercent} % de carga · '
                        '${BateriaEstado.etiqueta(b.state).toLowerCase()}',
                        AppColors.textMid,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  b.verdict,
                  style: const TextStyle(
                    color: AppColors.textHi,
                    fontSize: kFont + 4,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                if (salud >= 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Le queda el $salud % de la capacidad que tenía nueva.',
                    style: const TextStyle(
                        color: AppColors.textMid, fontSize: kFont, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Anillo con el porcentaje de salud. Un número grande y un color: es lo único
  /// que mucha gente va a mirar.
  Widget _anillo(int salud, Color color) {
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
              value: salud < 0 ? 1 : salud / 100,
              strokeWidth: 9,
              backgroundColor: AppColors.surfaceAlt,
              valueColor: AlwaysStoppedAnimation<Color>(
                  salud < 0 ? AppColors.border : color),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                salud < 0 ? '—' : '$salud',
                style: TextStyle(
                  color: salud < 0 ? AppColors.textMid : color,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
              const Text('% de salud',
                  style: TextStyle(color: AppColors.textMid, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  // ---- Las cuatro cifras que importan ----

  Widget _cifras(BateriaItem b) {
    final cifras = <Widget>[
      _cifra(Icons.battery_charging_full_rounded, 'Cuando era nueva',
          energiaEnPalabras(b.designMWh), 'Carga que aguantaba de fábrica'),
      _cifra(Icons.battery_5_bar_rounded, 'Hoy, llena al 100 %',
          energiaEnPalabras(b.fullMWh), 'Lo máximo que puede guardar ahora'),
      _cifra(
        Icons.bolt_rounded,
        'En este momento',
        b.chargePercent >= 0 ? '${b.chargePercent} %' : '—',
        b.remainingMWh > 0
            ? 'Le quedan ${energiaEnPalabras(b.remainingMWh)}'
            : BateriaEstado.etiqueta(b.state),
      ),
      _cifra(
        Icons.autorenew_rounded,
        'Veces que se ha cargado',
        b.cycleCount > 0 ? '${b.cycleCount}' : '—',
        b.cycleCount > 0
            ? 'Suelen aguantar entre 300 y 1000'
            : 'El equipo no lleva esa cuenta',
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final columnas = c.maxWidth < 720 ? 2 : 4;
        final ancho = (c.maxWidth - (columnas - 1) * 14) / columnas;
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final w in cifras) SizedBox(width: ancho, child: w),
          ],
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

  // ---- Con qué se pide una batería nueva ----

  /// Lo que hay que llevar a la tienda. Es el dato por el que se abre esta
  /// pestaña cuando la batería ya está gastada, así que va arriba y no
  /// escondido entre los datos técnicos: referencia de la pieza si el equipo la
  /// publica y, si no, el modelo del portátil con el voltaje y los Wh, que es
  /// con lo que se busca un repuesto compatible.
  Widget _repuesto(BateriaItem b) {
    final filas = <List<String>>[
      ['Modelo de la batería', b.model.isNotEmpty ? b.model : 'no lo publica el equipo'],
      if (b.manufacturer.isNotEmpty) ['Fabricante', b.manufacturer],
      if (data.equipment.isNotEmpty) ['Para el equipo', data.equipment],
      if (b.voltageMV > 0) ['Voltaje', voltiosEnPalabras(b.voltageMV)],
      [
        'Capacidad',
        [
          energiaEnPalabras(b.designMWh),
          if (b.designMAh > 0) '${b.designMAh} mAh',
        ].join(' · ')
      ],
      if (b.chemistryText.isNotEmpty) ['De qué está hecha', b.chemistryText],
    ];
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.shopping_cart_rounded, 'Para pedir una batería nueva'),
          const SizedBox(height: 4),
          Text(
            b.model.isNotEmpty
                ? 'Pide esta referencia. Si no la encuentran, sirve buscar por '
                    'el modelo del equipo con el mismo voltaje y capacidad.'
                : 'Este equipo no publica la referencia de la pieza. Búscala por '
                    'el modelo del portátil, y comprueba que el repuesto tenga el '
                    'MISMO voltaje: con otro voltaje no sirve, aunque encaje.',
            style: const TextStyle(
                color: AppColors.textLow, fontSize: kFont - 1, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final f in filas) _filaDato(f[0], f[1]),
          const SizedBox(height: 10),
          _copiable(b),
        ],
      ),
    );
  }

  /// Una línea lista para pegar en un buscador o en un mensaje al proveedor.
  Widget _copiable(BateriaItem b) {
    final partes = <String>[
      if (b.model.isNotEmpty) b.model,
      if (data.equipment.isNotEmpty) 'batería para ${data.equipment}',
      if (b.voltageMV > 0) voltiosEnPalabras(b.voltageMV),
      if (b.designMWh > 0) energiaEnPalabras(b.designMWh),
      if (b.designMAh > 0) '${b.designMAh} mAh',
    ];
    if (partes.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: SelectableText(
        partes.join(' · '),
        style: const TextStyle(
            color: AppColors.textHi, fontSize: kFont, fontFamily: 'monospace'),
      ),
    );
  }

  Widget _filaDato(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 190,
            child: Text(etiqueta,
                style:
                    const TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ),
          Expanded(
            child: SelectableText(valor,
                style:
                    const TextStyle(color: AppColors.textHi, fontSize: kFont)),
          ),
        ],
      ),
    );
  }

  // ---- Cuánto dura ----

  Widget _duraciones() {
    final filas = <Widget>[];
    if (data.runtimeHeavyMin > 0) {
      filas.add(_filaDuracion(
          'Usándolo a tope (vídeo a pantalla completa, brillo alto)',
          'unos ${duracionEnPalabras(data.runtimeHeavyMin)}',
          true));
    }
    if (data.runtimeFullMin > 0) {
      filas.add(_filaDuracion('En tu uso de siempre, cargada al 100 %',
          duracionEnPalabras(data.runtimeFullMin), false));
    }
    if (data.runtimeNowMin > 0) {
      filas.add(_filaDuracion('Con la carga que le queda ahora',
          duracionEnPalabras(data.runtimeNowMin), false));
    }
    final consumo = <String>[
      if (data.wattsTypicalMW > 0)
        'en tu uso habitual gasta ${vatiosEnPalabras(data.wattsTypicalMW)}',
      if (data.wattsHeavyMW > 0)
        'a tope se cuentan ${vatiosEnPalabras(data.wattsHeavyMW)}',
    ];
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.schedule_rounded, 'Cuánto dura sin enchufar'),
          const SizedBox(height: 4),
          Text(
            'La cuenta del sistema sale de lo que sueles hacer con el equipo, '
            'así que se queda MUY corta viendo vídeo a pantalla completa o con '
            'el brillo al máximo. Por eso lo primero es el mínimo: lo que dura '
            'exigiéndole${consumo.isEmpty ? '' : ' (${consumo.join('; ')})'}.',
            style: const TextStyle(
                color: AppColors.textLow, fontSize: kFont - 1, height: 1.4),
          ),
          const SizedBox(height: 12),
          ...filas,
        ],
      ),
    );
  }

  Widget _filaDuracion(String etiqueta, String valor, bool destacado) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (destacado) ...[
            const Icon(Icons.speed_rounded, size: 15, color: _ambar),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(etiqueta,
                style: TextStyle(
                    color: destacado ? AppColors.textHi : AppColors.textMid,
                    fontSize: kFont)),
          ),
          Text(valor,
              style: TextStyle(
                color: destacado ? _ambar : AppColors.textMid,
                fontSize: destacado ? kFont + 3 : kFont + 1,
                fontWeight: destacado ? FontWeight.w700 : FontWeight.w500,
              )),
        ],
      ),
    );
  }

  // ---- El porqué, en palabras normales ----

  Widget _explicaciones(BateriaItem b) {
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.help_outline_rounded, 'Qué significa todo esto'),
          const SizedBox(height: 6),
          for (final n in b.notes) _nota(n),
        ],
      ),
    );
  }

  Widget _nota(BateriaNota n) {
    final color = switch (n.level) {
      BateriaNivel.aviso => _ambar,
      BateriaNivel.mal => _rojo,
      _ => AppColors.accent,
    };
    final icono = switch (n.level) {
      BateriaNivel.aviso => Icons.warning_amber_rounded,
      BateriaNivel.mal => Icons.error_outline_rounded,
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
                        color: AppColors.textMid,
                        fontSize: kFont,
                        height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Cómo ha ido bajando ----

  Widget _historial() {
    final puntos = data.history;
    final maximo = puntos
        .map((p) => p.designMWh > 0 ? p.designMWh : p.fullMWh)
        .fold<int>(1, (a, b) => b > a ? b : a);
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.show_chart_rounded, 'Cómo ha ido bajando'),
          const SizedBox(height: 4),
          const Text(
            'Cada barra es un periodo: la altura es la carga que aguantaba la '
            'batería entonces. Si baja poco a poco, es el desgaste normal; si '
            'cae de golpe, algo le pasó.',
            style: TextStyle(
                color: AppColors.textLow, fontSize: kFont - 1, height: 1.4),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 152,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final p in puntos) _barra(p, maximo),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barra(BateriaPunto p, int maximo) {
    final alto = maximo <= 0 ? 0.0 : (p.fullMWh / maximo).clamp(0.0, 1.0) * 96;
    final color = _colorSaludPorcentaje(p.healthPercent);
    return Tooltip(
      message: '${p.period}\n'
          'Aguantaba ${energiaEnPalabras(p.fullMWh)}'
          '${p.healthPercent >= 0 ? ' (${p.healthPercent} % de su capacidad de fábrica)' : ''}',
      child: Padding(
        padding: const EdgeInsets.only(right: 5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(p.healthPercent >= 0 ? '${p.healthPercent}' : '',
                style:
                    const TextStyle(color: AppColors.textLow, fontSize: 10)),
            const SizedBox(height: 4),
            Container(
              width: 16,
              height: alto < 3 ? 3 : alto,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3)),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 34,
              child: Text(_etiquetaCorta(p.period),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(color: AppColors.textLow, fontSize: 9)),
            ),
          ],
        ),
      ),
    );
  }

  /// Del periodo "27/06/2026 – 04/07/2026" solo cabe el día y el mes de inicio.
  String _etiquetaCorta(String periodo) {
    final t = periodo.trim();
    if (t.length >= 5) return t.substring(0, 5);
    return t;
  }

  // ---- Datos de la batería (los técnicos, al final) ----

  Widget _ficha(BateriaItem b) {
    final filas = <List<String>>[
      if (b.name.isNotEmpty) ['Como la llama el equipo', b.name],
      if (b.serial.isNotEmpty) ['Número de serie', b.serial],
      if (b.designMWh > 0)
        ['Capacidad de fábrica', '${b.designMWh} mWh (${energiaEnPalabras(b.designMWh)})'],
      if (b.fullMWh > 0)
        ['Capacidad actual', '${b.fullMWh} mWh (${energiaEnPalabras(b.fullMWh)})'],
      if (b.remainingMWh > 0)
        ['Carga en este momento', '${b.remainingMWh} mWh'],
      if (data.onAcKnown)
        ['Corriente', data.onAc ? 'Enchufado' : 'Funcionando con batería'],
    ];
    return _tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titulo(Icons.battery_std_rounded, 'Datos técnicos'),
          const SizedBox(height: 10),
          for (final f in filas) _filaDato(f[0], f[1]),
        ],
      ),
    );
  }

  Widget _pie() {
    final partes = <String>[
      if (data.source.isNotEmpty) data.source,
      if (data.generated.isNotEmpty) 'Leído el ${data.generated}',
    ];
    if (partes.isEmpty) return const SizedBox.shrink();
    return Text(partes.join(' · '),
        style: const TextStyle(color: AppColors.textLow, fontSize: kFont - 2));
  }

  // ---- Equipo sin batería o sin datos ----

  Widget _sinBateria(BateriaInfo d) {
    final esFallo = !d.available || !d.supported;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                esFallo
                    ? Icons.error_outline_rounded
                    : Icons.power_rounded,
                color: AppColors.textMid,
                size: 52),
            const SizedBox(height: 16),
            Text(
              esFallo
                  ? 'No se pudo leer la batería'
                  : 'Este equipo no tiene batería',
              style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont + 2,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SelectableText(
                d.reason.isNotEmpty
                    ? d.reason
                    : 'Es un equipo de escritorio, o la batería está '
                        'desconectada. Esta pestaña solo tiene sentido en un '
                        'portátil.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textMid, fontSize: kFont, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Piezas comunes ----

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

  Widget _aviso(String texto) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _ambar.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _ambar.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: _ambar),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(texto,
                style: const TextStyle(
                    color: AppColors.textMid, fontSize: kFont, height: 1.4)),
          ),
        ],
      ),
    );
  }

  static Color _colorSalud(String nivel) => switch (nivel) {
        BateriaNivel.bien => AppColors.accent,
        BateriaNivel.aviso => _ambar,
        BateriaNivel.mal => _rojo,
        _ => AppColors.textMid,
      };

  static Color _colorSaludPorcentaje(int salud) {
    if (salud < 0) return AppColors.textLow;
    if (salud >= 80) return AppColors.accent;
    if (salud >= 60) return _ambar;
    return _rojo;
  }
}
