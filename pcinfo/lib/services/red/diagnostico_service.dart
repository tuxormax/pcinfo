import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';

import '../../models/red.dart';
import 'cgnat_service.dart';

// Portado de RedScan (proyecto primo, lib/services/diagnostico_service.dart):
// mismo motor de 7 pasos, adaptado a escritorio — en vez de SSID/WiFi (RedScan
// es móvil) solo hace falta la IP local y la puerta de enlace, que PCInfo lee
// de su propio backend (ver services/red_service.dart) en vez de
// network_info_plus (pensado para WiFi, no para Ethernet de escritorio).

/// Estado de cada prueba del diagnóstico.
enum EstadoPaso { pendiente, corriendo, ok, aviso, fallo, omitido }

/// Una prueba concreta dentro del diagnóstico (una capa de la conexión).
class PasoDiagnostico {
  final String clave;
  final String titulo;
  EstadoPaso estado;
  String detalle;

  PasoDiagnostico(
    this.clave,
    this.titulo, {
    this.estado = EstadoPaso.pendiente,
    this.detalle = '',
  });
}

/// Un salto de la ruta hacia internet (traceroute corto por TTL).
class SaltoRuta {
  final int numero;
  final String? ip;
  final bool esDestino;

  const SaltoRuta(this.numero, this.ip, {this.esDestino = false});
}

/// A quién se le atribuye la falla.
enum Culpable {
  /// Todo bien: hay internet.
  ninguno,

  /// El equipo no está conectado a ninguna red.
  sinRed,

  /// El punto de acceso / router al que está conectado no responde.
  ap,

  /// El módem (o su enlace con el operador) no da salida a internet.
  modem,

  /// Sale de la casa pero internet no responde: red del proveedor.
  isp,

  /// Se llega por IP pero los nombres no se resuelven.
  dns,

  /// La red exige iniciar sesión en una página antes de dar internet.
  portal,

  /// No hay evidencia suficiente para señalar una capa.
  desconocido,
}

/// Veredicto final en lenguaje simple.
class ResultadoDiagnostico {
  final Culpable culpable;
  final String titulo;
  final String explicacion;
  final List<String> acciones;

  const ResultadoDiagnostico({
    required this.culpable,
    required this.titulo,
    required this.explicacion,
    this.acciones = const [],
  });

  bool get hayInternet => culpable == Culpable.ninguno;
}

/// Evento emitido mientras corre el diagnóstico.
class DiagnosticoEvento {
  final List<PasoDiagnostico> pasos;
  final List<SaltoRuta> ruta;
  final double porcentaje;
  final bool finalizado;
  final ResultadoDiagnostico? resultado;

  const DiagnosticoEvento({
    required this.pasos,
    required this.ruta,
    required this.porcentaje,
    this.finalizado = false,
    this.resultado,
  });
}

/// Comprueba si hay internet y, si no lo hay, en qué capa se rompe:
/// punto de acceso (AP) → módem / enlace del operador → red del ISP,
/// más los dos casos que parecen "sin internet" pero no lo son:
/// DNS caído y portal cautivo.
class DiagnosticoService {
  static const List<String> _ipsInternet = ['1.1.1.1', '8.8.8.8', '9.9.9.9'];
  static const int _puertoInternet = 443;
  static const String _destinoRuta = '1.1.1.1';
  static const int _maxSaltos = 5;

  /// Endpoint que devuelve 204 sin cuerpo: si contesta otra cosa hay portal.
  static const String _urlPortal =
      'http://connectivitycheck.gstatic.com/generate_204';
  static const String _urlPortalAlt =
      'http://captive.apple.com/hotspot-detect.html';

  final _cgnat = CgnatService();

  bool _cancelado = false;
  void cancelar() => _cancelado = true;

  Stream<DiagnosticoEvento> ejecutar(RedInfo red) async* {
    _cancelado = false;

    final pasos = <PasoDiagnostico>[
      PasoDiagnostico('red', 'Conexión a la red local'),
      PasoDiagnostico('ap', 'Punto de acceso / router'),
      PasoDiagnostico('ruta', 'Ruta hacia internet'),
      PasoDiagnostico('modem', 'Módem / enlace con el operador'),
      PasoDiagnostico('internet', 'Internet por IP'),
      PasoDiagnostico('dns', 'Resolución de nombres (DNS)'),
      PasoDiagnostico('web', 'Navegación web'),
    ];
    final ruta = <SaltoRuta>[];
    PasoDiagnostico paso(String c) => pasos.firstWhere((p) => p.clave == c);

    DiagnosticoEvento ev({
      double? pct,
      bool fin = false,
      ResultadoDiagnostico? res,
    }) =>
        DiagnosticoEvento(
          pasos: pasos,
          ruta: ruta,
          porcentaje: pct ?? 0,
          finalizado: fin,
          resultado: res,
        );

    // --- 1. Red local -----------------------------------------------------
    paso('red').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.02);

    if (!red.hayRed) {
      paso('red')
        ..estado = EstadoPaso.fallo
        ..detalle = 'El equipo no tiene dirección IP en ninguna red.';
      for (final p in pasos.skip(1)) {
        p.estado = EstadoPaso.omitido;
        p.detalle = 'No se probó: no hay red.';
      }
      yield ev(pct: 1, fin: true, res: _veredictoSinRed());
      return;
    }

    // Sin gateway reportado se asume el .1 de la red (caso doméstico).
    var gateway = red.gateway;
    var gatewaySupuesto = false;
    if (gateway.isEmpty || gateway == '0.0.0.0') {
      gateway = red.baseRed.isNotEmpty ? '${red.baseRed}.1' : '';
      gatewaySupuesto = gateway.isNotEmpty;
    }

    paso('red')
      ..estado = gatewaySupuesto ? EstadoPaso.aviso : EstadoPaso.ok
      ..detalle = [
        'IP ${red.localIp}',
        if (gateway.isNotEmpty)
          'puerta de enlace $gateway${gatewaySupuesto ? ' (supuesta)' : ''}'
        else
          'sin puerta de enlace',
      ].join(' · ');
    yield ev(pct: 0.06);

    if (gateway.isEmpty) {
      for (final p in pasos.skip(1)) {
        p.estado = EstadoPaso.omitido;
        p.detalle = 'No se probó: no se conoce la puerta de enlace.';
      }
      yield ev(pct: 1, fin: true, res: _veredictoSinRed());
      return;
    }

    // --- 2. Punto de acceso ----------------------------------------------
    paso('ap').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.08);

    final ap = await _probarGateway(gateway);
    if (_cancelado) return;
    paso('ap')
      ..estado = ap.estado
      ..detalle = ap.detalle;
    yield ev(pct: 0.30);

    // --- 3. Ruta hacia internet (traceroute corto) ------------------------
    paso('ruta').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.32);

    ruta.addAll(await _trazarRuta());
    if (_cancelado) return;
    final saltosVivos = ruta.where((s) => s.ip != null).toList();
    final masAlladelGateway =
        saltosVivos.where((s) => s.ip != gateway).toList();
    final salioAlOperador = saltosVivos
        .any((s) => s.esDestino || _esPublica(s.ip!) || _enCgnat(s.ip!));

    if (saltosVivos.isEmpty) {
      paso('ruta')
        ..estado = EstadoPaso.omitido
        ..detalle = 'Ningún salto contestó (el sistema bloquea el trazado).';
    } else if (salioAlOperador) {
      paso('ruta')
        ..estado = EstadoPaso.ok
        ..detalle = 'El tráfico sale de la red local: ${_resumenRuta(ruta)}';
    } else if (masAlladelGateway.isNotEmpty) {
      paso('ruta')
        ..estado = EstadoPaso.aviso
        ..detalle =
            'Solo se ve equipo propio antes de internet: ${_resumenRuta(ruta)}';
    } else {
      paso('ruta')
        ..estado = EstadoPaso.aviso
        ..detalle =
            'El tráfico no pasa de la puerta de enlace: ${_resumenRuta(ruta)}';
    }
    yield ev(pct: 0.50);

    // --- 4. Módem / enlace con el operador --------------------------------
    paso('modem').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.52);

    final wan = await _cgnat.wanRouter();
    if (_cancelado) return;
    var modemCaido = false;
    if (wan == null) {
      if (salioAlOperador) {
        paso('modem')
          ..estado = EstadoPaso.ok
          ..detalle = 'El módem no informa por UPnP, pero el tráfico sí sale '
              'hacia el operador.';
      } else {
        paso('modem')
          ..estado = EstadoPaso.aviso
          ..detalle = 'No se pudo consultar el módem (UPnP desactivado o no '
              'es el router).';
      }
    } else if (wan == '0.0.0.0') {
      modemCaido = true;
      paso('modem')
        ..estado = EstadoPaso.fallo
        ..detalle = 'El módem no tiene dirección de internet: el enlace con '
            'el operador está caído.';
    } else if (_enCgnat(wan)) {
      paso('modem')
        ..estado = EstadoPaso.ok
        ..detalle = 'Enlace activo con IP compartida del operador (CGNAT): $wan';
    } else if (_esPrivada(wan)) {
      paso('modem')
        ..estado = EstadoPaso.aviso
        ..detalle = 'La WAN del router es privada ($wan): hay otro equipo '
            'del operador por delante (doble NAT).';
    } else {
      paso('modem')
        ..estado = EstadoPaso.ok
        ..detalle = 'Enlace activo con IP pública: $wan';
    }
    yield ev(pct: 0.66);

    // --- 5. Internet por IP -----------------------------------------------
    paso('internet').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.68);

    final alcanzados = await _probarInternet();
    if (_cancelado) return;
    if (alcanzados.isEmpty) {
      paso('internet')
        ..estado = EstadoPaso.fallo
        ..detalle = 'Ningún servidor público responde '
            '(${_ipsInternet.join(', ')}).';
    } else if (alcanzados.length < _ipsInternet.length) {
      paso('internet')
        ..estado = EstadoPaso.aviso
        ..detalle = 'Responden ${alcanzados.length} de ${_ipsInternet.length}: '
            '${alcanzados.join(', ')}.';
    } else {
      paso('internet')
        ..estado = EstadoPaso.ok
        ..detalle = 'Responden los ${alcanzados.length} servidores probados.';
    }
    yield ev(pct: 0.80);

    // --- 6. DNS ------------------------------------------------------------
    paso('dns').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.82);

    final dns = await _probarDns();
    if (_cancelado) return;
    paso('dns')
      ..estado = dns.estado
      ..detalle = dns.detalle;
    yield ev(pct: 0.90);

    // --- 7. Navegación / portal cautivo ------------------------------------
    paso('web').estado = EstadoPaso.corriendo;
    yield ev(pct: 0.92);

    final web = await _probarWeb();
    if (_cancelado) return;
    paso('web')
      ..estado = web.estado
      ..detalle = web.detalle;
    yield ev(pct: 0.98);

    // --- Veredicto ---------------------------------------------------------
    final res = _veredicto(
      ap: paso('ap').estado,
      internetOk: alcanzados.isNotEmpty,
      internetParcial:
          alcanzados.isNotEmpty && alcanzados.length < _ipsInternet.length,
      dnsOk: dns.estado == EstadoPaso.ok || dns.estado == EstadoPaso.aviso,
      portal: web.portal,
      webOk: web.estado == EstadoPaso.ok,
      modemCaido: modemCaido,
      wan: wan,
      salioAlOperador: salioAlOperador,
      hayEquipoIntermedio: masAlladelGateway.isNotEmpty && !salioAlOperador,
    );
    yield ev(pct: 1, fin: true, res: res);
  }

  // ---------------------------------------------------------------- pruebas

  /// Ping (y TCP como respaldo) a la puerta de enlace: mide si el AP responde,
  /// con cuánta latencia y con cuánta pérdida.
  Future<_Resultado> _probarGateway(String gateway) async {
    final tiempos = <double>[];
    const intentos = 4;
    try {
      final ping = Ping(gateway, count: intentos, timeout: 1);
      await for (final e in ping.stream) {
        if (_cancelado) break;
        final t = e.response?.time;
        if (t != null) tiempos.add(t.inMicroseconds / 1000.0);
        if (e.summary != null) break;
      }
    } catch (_) {}

    if (tiempos.isNotEmpty) {
      final media = tiempos.reduce((a, b) => a + b) / tiempos.length;
      final perdida = ((intentos - tiempos.length) / intentos * 100).round();
      final detalle = '$gateway responde en '
          '${media.toStringAsFixed(media < 10 ? 1 : 0)} ms (pérdida $perdida%)';
      if (perdida >= 50 || media > 150) {
        return _Resultado(EstadoPaso.aviso,
            '$detalle — la señal está débil o el punto de acceso va saturado.');
      }
      if (perdida > 0 || media > 60) {
        return _Resultado(EstadoPaso.aviso, '$detalle — enlace irregular.');
      }
      return _Resultado(EstadoPaso.ok, detalle);
    }

    // Muchos routers ignoran el ping desde la LAN: se intenta por TCP.
    final puertos = await _puertosAbiertos(gateway, const [80, 443, 53, 8080]);
    if (puertos.isNotEmpty) {
      return _Resultado(
        EstadoPaso.ok,
        '$gateway no contesta al ping pero sí abre TCP '
        '(${puertos.join(', ')}): el punto de acceso está vivo.',
      );
    }
    return _Resultado(
      EstadoPaso.fallo,
      '$gateway no responde ni a ping ni a TCP.',
    );
  }

  /// Traceroute corto por TTL creciente hacia una IP pública conocida.
  /// Best-effort: si el sistema no deja ejecutar `ping`, devuelve vacío.
  Future<List<SaltoRuta>> _trazarRuta() async {
    final futuros = <Future<SaltoRuta>>[];
    for (var ttl = 1; ttl <= _maxSaltos; ttl++) {
      futuros.add(_salto(ttl));
    }
    final saltos = await Future.wait(futuros);
    final lista = <SaltoRuta>[];
    for (final s in saltos) {
      lista.add(s);
      if (s.esDestino) break;
    }
    return lista;
  }

  Future<SaltoRuta> _salto(int ttl) async {
    try {
      final r = await Process.run(
        'ping',
        Platform.isWindows
            ? ['-n', '1', '-w', '2000', '-i', '$ttl', _destinoRuta]
            : ['-c', '1', '-W', '2', '-t', '$ttl', _destinoRuta],
      ).timeout(const Duration(seconds: 6));
      final salida = '${r.stdout}\n${r.stderr}';

      // No se distingue "es la respuesta del destino" de "es un salto
      // intermedio" por el texto (cambia entre inglés/español y entre
      // Windows/Linux/macOS): se compara la IP encontrada contra el destino
      // conocido, que es un dato fijo y no depende del idioma del sistema.
      final ip = RegExp(r'(\d+\.\d+\.\d+\.\d+)').firstMatch(salida)?.group(1);
      if (ip == null) return SaltoRuta(ttl, null);
      return SaltoRuta(ttl, ip, esDestino: ip == _destinoRuta);
    } catch (_) {
      return SaltoRuta(ttl, null);
    }
  }

  /// Conexión TCP directa a IP conocidas: descarta el DNS de la ecuación.
  Future<List<String>> _probarInternet() async {
    final vivos = <String>[];
    await Future.wait(_ipsInternet.map((ip) async {
      try {
        final s =
            await Socket.connect(ip, _puertoInternet, timeout: const Duration(seconds: 4));
        vivos.add(ip);
        s.destroy();
      } catch (_) {
        // 8.8.8.8 también escucha en 53: segunda oportunidad.
        try {
          final s = await Socket.connect(ip, 53, timeout: const Duration(seconds: 3));
          vivos.add(ip);
          s.destroy();
        } catch (_) {}
      }
    }));
    vivos.sort();
    return vivos;
  }

  Future<_Resultado> _probarDns() async {
    const dominios = ['cloudflare.com', 'google.com'];
    final ok = <String>[];
    await Future.wait(dominios.map((d) async {
      try {
        final r =
            await InternetAddress.lookup(d).timeout(const Duration(seconds: 5));
        if (r.isNotEmpty) ok.add(d);
      } catch (_) {}
    }));
    if (ok.length == dominios.length) {
      return _Resultado(EstadoPaso.ok, 'Los nombres se resuelven bien.');
    }
    if (ok.isNotEmpty) {
      return _Resultado(EstadoPaso.aviso,
          'Solo resolvió ${ok.join(', ')}: el DNS va intermitente.');
    }
    return _Resultado(
        EstadoPaso.fallo, 'Ningún nombre se pudo traducir a dirección IP.');
  }

  /// Pide un endpoint que debe contestar 204 vacío. Cualquier otra cosa
  /// (redirección o página) significa que alguien intercepta la navegación.
  Future<_ResultadoWeb> _probarWeb() async {
    final r = await _pedir(_urlPortal);
    if (r != null) {
      if (r.codigo == 204) {
        return _ResultadoWeb(EstadoPaso.ok, 'La navegación web funciona.', false);
      }
      if (r.codigo >= 300 && r.codigo < 400) {
        return _ResultadoWeb(
          EstadoPaso.fallo,
          'La red redirige la navegación (HTTP ${r.codigo}) a '
          '${r.destino ?? 'otra página'}: hay portal cautivo.',
          true,
        );
      }
      return _ResultadoWeb(
        EstadoPaso.fallo,
        'La prueba de navegación devolvió HTTP ${r.codigo} en vez de 204: '
        'algo intercepta el tráfico.',
        true,
      );
    }

    // Respaldo por si gstatic está bloqueado en esa red.
    final alt = await _pedir(_urlPortalAlt);
    if (alt != null && alt.codigo == 200 && (alt.cuerpo ?? '').contains('Success')) {
      return _ResultadoWeb(EstadoPaso.ok, 'La navegación web funciona.', false);
    }
    if (alt != null) {
      return _ResultadoWeb(EstadoPaso.fallo,
          'La navegación devuelve contenido ajeno: hay portal cautivo.', true);
    }
    return _ResultadoWeb(
        EstadoPaso.fallo, 'No hubo respuesta a la petición web.', false);
  }

  Future<_Http?> _pedir(String url) async {
    HttpClient? c;
    try {
      c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.getUrl(Uri.parse(url));
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 6));
      String? cuerpo;
      try {
        final texto = await res
            .transform(const Utf8Decoder(allowMalformed: true))
            .join()
            .timeout(const Duration(seconds: 3));
        cuerpo = texto.length > 2000 ? texto.substring(0, 2000) : texto;
      } catch (_) {}
      return _Http(res.statusCode, res.headers.value('location'), cuerpo);
    } catch (_) {
      return null;
    } finally {
      c?.close(force: true);
    }
  }

  Future<List<int>> _puertosAbiertos(String ip, List<int> puertos) async {
    final abiertos = <int>[];
    await Future.wait(puertos.map((p) async {
      try {
        final s = await Socket.connect(ip, p, timeout: const Duration(milliseconds: 900));
        abiertos.add(p);
        s.destroy();
      } catch (_) {}
    }));
    abiertos.sort();
    return abiertos;
  }

  // -------------------------------------------------------------- veredicto

  ResultadoDiagnostico _veredicto({
    required EstadoPaso ap,
    required bool internetOk,
    required bool internetParcial,
    required bool dnsOk,
    required bool portal,
    required bool webOk,
    required bool modemCaido,
    required String? wan,
    required bool salioAlOperador,
    required bool hayEquipoIntermedio,
  }) {
    // El AP no contesta: nada de lo de más adelante es concluyente.
    if (ap == EstadoPaso.fallo) {
      return const ResultadoDiagnostico(
        culpable: Culpable.ap,
        titulo: 'El problema está en el punto de acceso',
        explicacion:
            'El equipo tiene dirección IP en la red, pero el aparato al que '
            'está conectado (router, switch o repetidor) no contesta. El '
            'corte está entre el equipo y ese aparato.',
        acciones: [
          'Revisa el cable de red o vuelve a conectar el WiFi.',
          'Reinicia el router, switch o repetidor.',
          'Comprueba si otros equipos de la misma red sí navegan.',
        ],
      );
    }

    if (internetOk) {
      if (portal) {
        return const ResultadoDiagnostico(
          culpable: Culpable.portal,
          titulo: 'Hay internet, pero la red pide iniciar sesión',
          explicacion:
              'La conexión llega hasta internet, pero un portal cautivo '
              'intercepta la navegación hasta que aceptes sus condiciones.',
          acciones: [
            'Abre el navegador: debe aparecer la página de acceso de la red.',
            'Acepta las condiciones o captura la clave que te dieron.',
          ],
        );
      }
      if (!dnsOk) {
        return const ResultadoDiagnostico(
          culpable: Culpable.dns,
          titulo: 'Hay internet, pero falla el DNS',
          explicacion:
              'Se alcanza internet por dirección IP, pero los nombres de los '
              'sitios no se traducen. Por eso parece que "no hay internet" '
              'aunque la conexión sí exista.',
          acciones: [
            'Cambia el DNS del equipo o del router a 1.1.1.1 o 8.8.8.8.',
            'Reinicia el router: suele ser su servidor DNS el que se traba.',
          ],
        );
      }
      final calidad = ap == EstadoPaso.aviso || internetParcial || !webOk;
      return ResultadoDiagnostico(
        culpable: Culpable.ninguno,
        titulo: calidad
            ? 'Hay internet, pero la conexión va irregular'
            : 'Hay internet',
        explicacion: calidad
            ? 'Se llega a internet y los nombres se resuelven, pero alguna '
                'prueba salió con pérdidas o lenta. Revisa el detalle de los '
                'pasos marcados en amarillo.'
            : 'La conexión funciona de punta a punta: el punto de acceso '
                'responde, el tráfico sale a internet y los nombres se '
                'resuelven.',
        acciones: calidad
            ? const ['Revisa el cable o acércate al punto de acceso WiFi.']
            : const [],
      );
    }

    // Sin internet: se decide entre módem y red del ISP.
    if (modemCaido) {
      return const ResultadoDiagnostico(
        culpable: Culpable.modem,
        titulo: 'El problema está en el módem',
        explicacion:
            'El punto de acceso responde bien, pero el módem no tiene '
            'dirección de internet: no logró enlazar con el proveedor.',
        acciones: [
          'Revisa las luces del módem (enlace / internet).',
          'Revisa el cable de la calle o la fibra.',
          'Reinicia el módem y espera dos minutos.',
          'Si no toma dirección, repórtalo al proveedor.',
        ],
      );
    }

    if (salioAlOperador || (wan != null && !_esPrivada(wan))) {
      return const ResultadoDiagnostico(
        culpable: Culpable.isp,
        titulo: 'El problema está en la red del proveedor',
        explicacion:
            'El punto de acceso y el módem funcionan: el tráfico sale de la '
            'casa y llega a equipos del operador, pero de ahí para afuera no '
            'hay respuesta. La falla es del proveedor de internet.',
        acciones: [
          'Reporta la falla al proveedor con la hora exacta.',
          'Confirma con un vecino del mismo operador si también está caído.',
          'No reinicies el módem varias veces: no cambia nada y pierdes el '
              'registro del corte.',
        ],
      );
    }

    if (hayEquipoIntermedio) {
      return const ResultadoDiagnostico(
        culpable: Culpable.modem,
        titulo: 'El problema está entre el punto de acceso y el módem',
        explicacion:
            'El aparato al que está conectado el equipo responde y hay otro '
            'equipo propio por delante, pero el tráfico no llega a salir a '
            'internet. El corte está en ese equipo intermedio o en el módem.',
        acciones: [
          'Revisa el cable entre el switch/repetidor y el módem.',
          'Reinicia primero el módem y después el punto de acceso.',
          'Conecta el equipo directo al módem para descartar el intermedio.',
        ],
      );
    }

    return const ResultadoDiagnostico(
      culpable: Culpable.modem,
      titulo: 'El tráfico no sale de la red',
      explicacion:
          'El punto de acceso responde, pero nada pasa de él hacia internet '
          'y no se pudo ver ningún equipo del operador. Lo más probable es '
          'que el módem esté sin enlace.',
      acciones: [
        'Revisa las luces del módem (enlace / internet).',
        'Reinicia el módem y espera dos minutos.',
        'Si el módem indica enlace correcto, repórtalo al proveedor.',
      ],
    );
  }

  ResultadoDiagnostico _veredictoSinRed() => const ResultadoDiagnostico(
        culpable: Culpable.sinRed,
        titulo: 'El equipo no está conectado a ninguna red',
        explicacion:
            'El equipo no tiene dirección IP, así que no hay nada que probar '
            'más adelante. Revisa el cable o la conexión WiFi.',
        acciones: [
          'Conecta el cable de red o el WiFi.',
          'Si ya está conectado, revisa el adaptador de red del equipo.',
        ],
      );

  // ------------------------------------------------------------- utilidades

  String _resumenRuta(List<SaltoRuta> ruta) => ruta
      .map((s) => '${s.numero}) ${s.ip ?? '—'}${s.esDestino ? ' ✓' : ''}')
      .join('  ');

  bool _enCgnat(String ip) {
    final o = _octetos(ip);
    if (o == null) return false;
    return o[0] == 100 && o[1] >= 64 && o[1] <= 127;
  }

  bool _esPrivada(String ip) {
    final o = _octetos(ip);
    if (o == null) return false;
    if (o[0] == 10) return true;
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
    if (o[0] == 192 && o[1] == 168) return true;
    if (o[0] == 169 && o[1] == 254) return true; // autoasignada
    if (o[0] == 127) return true;
    return false;
  }

  bool _esPublica(String ip) => !_esPrivada(ip) && !_enCgnat(ip);

  List<int>? _octetos(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return null;
    final o = <int>[];
    for (final parte in p) {
      final n = int.tryParse(parte);
      if (n == null || n < 0 || n > 255) return null;
      o.add(n);
    }
    return o;
  }
}

class _Resultado {
  final EstadoPaso estado;
  final String detalle;
  const _Resultado(this.estado, this.detalle);
}

class _ResultadoWeb extends _Resultado {
  final bool portal;
  const _ResultadoWeb(super.estado, super.detalle, this.portal);
}

class _Http {
  final int codigo;
  final String? destino;
  final String? cuerpo;
  const _Http(this.codigo, this.destino, this.cuerpo);
}
