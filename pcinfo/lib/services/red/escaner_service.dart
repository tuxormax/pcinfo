import 'dart:async';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:multicast_dns/multicast_dns.dart';

/// Un equipo encontrado en la red local.
class Dispositivo {
  final String ip;
  String mac;
  String? nombre;
  String? fabricante;
  final Set<int> puertos;
  int? latenciaMs;
  bool esEsteEquipo;
  bool esGateway;

  Dispositivo({
    required this.ip,
    this.mac = '',
    this.nombre,
    this.fabricante,
    Set<int>? puertos,
    this.latenciaMs,
    this.esEsteEquipo = false,
    this.esGateway = false,
  }) : puertos = puertos ?? <int>{};

  String get etiqueta {
    if (nombre != null && nombre!.trim().isNotEmpty) return nombre!;
    if (esEsteEquipo) return 'Este equipo';
    if (esGateway) return 'Router (puerta de enlace)';
    if (fabricante != null && fabricante!.isNotEmpty) return fabricante!;
    return ip;
  }

  /// Adivina el tipo por puertos/nombre/fabricante (para el icono).
  String get tipo {
    final n = (nombre ?? '').toLowerCase();
    final f = (fabricante ?? '').toLowerCase();
    if (esGateway) return 'router';
    if (esEsteEquipo) return 'pc';
    if (puertos.contains(9100) || puertos.contains(631) || n.contains('print')) {
      return 'impresora';
    }
    if (puertos.contains(8009) || n.contains('cast') || n.contains('tv') ||
        n.contains('roku') || n.contains('bravia')) {
      return 'tv';
    }
    if (puertos.contains(80) || puertos.contains(443) || puertos.contains(8080)) {
      if (f.contains('espressif') || n.contains('esp')) return 'iot';
      return 'web';
    }
    if (puertos.contains(22)) return 'servidor';
    if (puertos.contains(445) || puertos.contains(139) ||
        puertos.contains(3389)) {
      return 'pc';
    }
    if (f.contains('apple') || f.contains('samsung') || f.contains('xiaomi') ||
        f.contains('huawei')) {
      return 'telefono';
    }
    return 'generico';
  }
}

class ProgresoEscaneo {
  final int hechos;
  final int total;
  final String fase;
  final Dispositivo? nuevo; // equipo que acaba de responder al ping
  final List<Dispositivo>? resultado; // solo en el evento final
  const ProgresoEscaneo(this.hechos, this.total, this.fase,
      {this.nuevo, this.resultado});
  double get porcentaje => total == 0 ? 0 : hechos / total;
}

/// Escáner de la subred /24 del equipo. Portado de RedScan (proyecto primo):
/// ping + TCP para hallar equipos vivos, tabla ARP (MAC → fabricante por OUI),
/// nombres por mDNS / DNS inverso y puertos extra para adivinar el tipo.
/// Solo lectura: no escribe nada en el equipo ni necesita administrador.
class EscanerService {
  static const _puertosIdent = [
    21, 23, 53, 139, 631, 548, 3389, 5000, 5555, 8443, 32400, 62078, 1883
  ];
  static const _servicios = <String>[
    '_googlecast._tcp.local',
    '_airplay._tcp.local',
    '_raop._tcp.local',
    '_printer._tcp.local',
    '_ipp._tcp.local',
    '_http._tcp.local',
    '_workstation._tcp.local',
    '_smb._tcp.local',
    '_ssh._tcp.local',
    '_device-info._tcp.local',
    '_homekit._tcp.local',
    '_companion-link._tcp.local',
    '_sonos._tcp.local',
  ];

  final Map<String, String> _oui = {};
  bool _cancelado = false;
  void cancelar() => _cancelado = true;

  Stream<ProgresoEscaneo> escanear(
      {required String baseRed,
      required String ipLocal,
      required String gateway}) async* {
    _cancelado = false;
    if (baseRed.isEmpty) {
      yield const ProgresoEscaneo(0, 0, 'Sin red', resultado: []);
      return;
    }
    await _cargarOui();

    final ips = [for (var i = 1; i <= 254; i++) '$baseRed.$i'];
    final total = ips.length;
    final vivos = <String, Dispositivo>{};
    var hechos = 0;

    // Fase 1: equipos vivos (ping + TCP) con concurrencia limitada.
    final cola = StreamController<ProgresoEscaneo>();
    _enLotes<String>(ips, 40, (ip) async {
      final d = await _detectar(ip);
      hechos++;
      if (d != null) vivos[ip] = d;
      cola.add(ProgresoEscaneo(hechos, total, 'Escaneando $baseRed.1 – $baseRed.254',
          nuevo: d));
    }).then((_) => cola.close());
    yield* cola.stream;
    if (_cancelado) {
      yield ProgresoEscaneo(hechos, total, 'Detenido',
          resultado: vivos.values.toList());
      return;
    }

    // Fase 2: MAC por ARP (el ping ya pobló la caché del sistema).
    yield ProgresoEscaneo(total, total, 'Leyendo MAC…');
    (await _tablaArp()).forEach((ip, mac) {
      if (!ip.startsWith('$baseRed.')) return;
      final d = vivos[ip];
      if (d == null) return; // solo equipos que respondieron al ping
      d.mac = mac;
      d.fabricante = _fabricante(mac);
    });

    // Fase 3: nombres por mDNS y DNS inverso.
    yield ProgresoEscaneo(total, total, 'Resolviendo nombres…');
    (await _mdns()).forEach((ip, nombre) {
      vivos[ip]?.nombre = nombre;
    });
    for (final d in vivos.values) {
      if (d.ip == ipLocal) d.esEsteEquipo = true;
      if (d.ip == gateway) d.esGateway = true;
    }
    await _enLotes<Dispositivo>(vivos.values.toList(), 20, (d) async {
      d.nombre ??= await _reverso(d.ip);
    });

    // Fase 4: puertos extra para identificar el tipo.
    yield ProgresoEscaneo(total, total, 'Identificando servicios…');
    await _enLotes<Dispositivo>(vivos.values.toList(), 20, (d) async {
      d.puertos.addAll(await _puertosAbiertos(d.ip, _puertosIdent));
    });

    final lista = vivos.values.toList()
      ..sort((a, b) => _ult(a.ip).compareTo(_ult(b.ip)));
    yield ProgresoEscaneo(total, total, 'Listo', resultado: lista);
  }

  int _ult(String ip) => int.tryParse(ip.split('.').last) ?? 0;

  Future<Dispositivo?> _detectar(String ip) async {
    if (_cancelado) return null;
    // Como Angry IP Scanner: solo cuenta quien responde al ping.
    final lat = await _ping(ip);
    return lat == null ? null : Dispositivo(ip: ip, latenciaMs: lat);
  }

  Future<int?> _ping(String ip) async {
    try {
      final ping = Ping(ip, count: 1, timeout: 1);
      await for (final ev in ping.stream) {
        if (ev.response?.time != null) return ev.response!.time!.inMilliseconds;
        if (ev.summary != null) break;
      }
    } catch (_) {}
    return null;
  }

  Future<Set<int>> _puertosAbiertos(String ip, List<int> puertos,
      {int timeoutMs = 400}) async {
    final abiertos = <int>{};
    await Future.wait(puertos.map((p) async {
      try {
        final s = await Socket.connect(ip, p,
            timeout: Duration(milliseconds: timeoutMs));
        abiertos.add(p);
        s.destroy();
      } catch (_) {}
    }));
    return abiertos;
  }

  Future<void> _enLotes<T>(
      List<T> items, int concurrencia, Future<void> Function(T) fn) async {
    var i = 0;
    await Future.wait(List.generate(concurrencia, (_) async {
      while (!_cancelado) {
        final idx = i++;
        if (idx >= items.length) return;
        await fn(items[idx]);
      }
    }));
  }

  // ---- ARP: Linux lee /proc, Windows y macOS usan `arp -a` ----

  Future<Map<String, String>> _tablaArp() async {
    final mapa = <String, String>{};
    try {
      if (Platform.isLinux) {
        final lineas = (await File('/proc/net/arp').readAsString()).split('\n');
        for (final l in lineas.skip(1)) {
          final c = l.trim().split(RegExp(r'\s+'));
          if (c.length >= 4) _anotarMac(mapa, c[0], c[3]);
        }
      } else {
        final r = await Process.run('arp', ['-a'])
            .timeout(const Duration(seconds: 5));
        final re = RegExp(
            r'(\d{1,3}(?:\.\d{1,3}){3})\)?\s+(?:at\s+)?([0-9a-fA-F]{1,2}(?:[-:][0-9a-fA-F]{1,2}){5})');
        for (final m in re.allMatches(r.stdout.toString())) {
          _anotarMac(mapa, m.group(1)!, m.group(2)!);
        }
      }
    } catch (_) {}
    return mapa;
  }

  void _anotarMac(Map<String, String> mapa, String ip, String crudo) {
    final o = crudo.split(RegExp(r'[-:]'));
    if (o.length != 6) return;
    final mac = o.map((x) => x.padLeft(2, '0').toUpperCase()).join(':');
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(mac)) return;
    // Descarta vacías y multicast/broadcast.
    if (mac == '00:00:00:00:00:00' || mac == 'FF:FF:FF:FF:FF:FF' ||
        mac.startsWith('01:00:5E')) {
      return;
    }
    mapa[ip] = mac;
  }

  // ---- Fabricante por OUI ----

  Future<void> _cargarOui() async {
    if (_oui.isNotEmpty) return;
    try {
      final txt = await rootBundle.loadString('assets/oui.txt');
      for (final l in txt.split('\n')) {
        if (l.length > 7 && l[6] == '\t') {
          _oui[l.substring(0, 6)] = l.substring(7).trim();
        }
      }
    } catch (_) {}
  }

  String? _fabricante(String mac) {
    final hex = mac.replaceAll(':', '');
    return hex.length < 6 ? null : _oui[hex.substring(0, 6)];
  }

  // ---- Nombres ----

  Future<String?> _reverso(String ip) async {
    try {
      final res =
          await InternetAddress(ip).reverse().timeout(const Duration(seconds: 2));
      final h = res.host;
      if (h.isNotEmpty && h != ip) return _limpiarHost(h);
    } catch (_) {}
    return null;
  }

  String _limpiarHost(String host) {
    var h = host;
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.endsWith('.local')) h = h.substring(0, h.length - 6);
    return h;
  }

  Future<Map<String, String>> _mdns() async {
    final out = <String, String>{};
    final client = MDnsClient();
    try {
      await client.start();
      await Future.any([
        Future.wait(_servicios.map((s) => _resolverServicio(client, s, out))),
        Future.delayed(const Duration(seconds: 4)),
      ]);
    } catch (_) {
    } finally {
      client.stop();
    }
    return out;
  }

  Future<void> _resolverServicio(
      MDnsClient client, String servicio, Map<String, String> out) async {
    try {
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(servicio))
          .timeout(const Duration(seconds: 3), onTimeout: (s) => s.close())) {
        final sufijo = '.$servicio';
        final bonito = ptr.domainName.endsWith(sufijo)
            ? ptr.domainName
                .substring(0, ptr.domainName.length - sufijo.length)
            : null;
        await for (final srv in client
            .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
            .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
          await for (final ip in client
              .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
            final dir = ip.address.address;
            final hay = bonito != null && bonito.isNotEmpty;
            if (!out.containsKey(dir) || hay) {
              out[dir] = hay ? bonito : _limpiarHost(srv.target);
            }
          }
        }
      }
    } catch (_) {}
  }
}
