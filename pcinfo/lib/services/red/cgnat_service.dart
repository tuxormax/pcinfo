import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:upnp2/router.dart';

// Portado tal cual de RedScan (proyecto primo, lib/services/cgnat_service.dart):
// no depende de nada específico de móvil, funciona igual en escritorio.

/// Veredicto de la comprobación de CGNAT.
enum CgnatVeredicto {
  /// El router tiene IP pública propia: accesible desde internet.
  sin,

  /// La WAN del router cae en 100.64.0.0/10 (RFC 6598): CGNAT seguro.
  confirmado,

  /// La WAN del router es privada o difiere de la IP pública: hay otra
  /// capa NAT antes del router (CGNAT muy probable o doble NAT).
  operador,

  /// No se pudo obtener la WAN del router (UPnP desactivado o sin respuesta).
  desconocido,
}

/// Resultado de la comprobación: veredicto + las dos IP que lo sustentan.
class CgnatResultado {
  final CgnatVeredicto veredicto;
  final String? ipPublica; // vista desde internet (eco externo)
  final String? wanRouter; // WAN real del router (UPnP)

  const CgnatResultado({
    required this.veredicto,
    this.ipPublica,
    this.wanRouter,
  });
}

/// Detecta si la conexión está detrás de CGNAT comparando la IP WAN del
/// router (vía UPnP) contra los rangos reservados y la IP pública real.
class CgnatService {
  /// Eco externo que devuelve la IP pública en texto plano.
  static const String _urlEco = 'https://api.ipify.org';

  Future<CgnatResultado> comprobar() async {
    // Ambas consultas en paralelo: eco público + WAN del router.
    final resultados = await Future.wait([
      _ipPublica(),
      wanRouter(),
    ]);
    final ipPublica = resultados[0];
    final wan = resultados[1];

    return CgnatResultado(
      veredicto: _clasificar(wan, ipPublica),
      ipPublica: ipPublica,
      wanRouter: wan,
    );
  }

  CgnatVeredicto _clasificar(String? wan, String? ipPublica) {
    // Sin WAN no hay forma de saberlo desde la LAN.
    if (wan == null || wan.isEmpty) return CgnatVeredicto.desconocido;

    // 100.64.0.0/10 está reservado exclusivamente para CGNAT.
    if (_enCgnat(wan)) return CgnatVeredicto.confirmado;

    // WAN privada => hay NAT del operador por encima del router.
    if (_esPrivada(wan)) return CgnatVeredicto.operador;

    // WAN pública pero distinta a la vista desde internet => doble NAT.
    if (ipPublica != null && ipPublica.isNotEmpty && wan != ipPublica) {
      return CgnatVeredicto.operador;
    }

    // WAN pública (y coincide con la externa si la tenemos): sin CGNAT.
    return CgnatVeredicto.sin;
  }

  /// Obtiene la IP pública desde un eco externo. Best-effort.
  Future<String?> _ipPublica() async {
    HttpClient? cliente;
    try {
      cliente = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await cliente.getUrl(Uri.parse(_urlEco));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final cuerpo = await res.transform(utf8.decoder).join();
      final ip = cuerpo.trim();
      return _esIpv4(ip) ? ip : null;
    } catch (_) {
      return null;
    } finally {
      cliente?.close(force: true);
    }
  }

  /// Obtiene la IP WAN del router vía UPnP (GetExternalIPAddress). Best-effort.
  Future<String?> wanRouter() async {
    try {
      final router = await Router.find().timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
      if (router == null) return null;
      final wan = await router.getExternalIpAddress();
      final ip = wan?.trim();
      return (ip != null && _esIpv4(ip)) ? ip : null;
    } catch (_) {
      return null;
    }
  }

  // --- Clasificación de rangos IPv4 ---

  bool _esIpv4(String ip) => _octetos(ip) != null;

  /// 100.64.0.0/10 (RFC 6598, Shared Address Space para CGNAT).
  bool _enCgnat(String ip) {
    final o = _octetos(ip);
    if (o == null) return false;
    return o[0] == 100 && o[1] >= 64 && o[1] <= 127;
  }

  /// Rangos privados RFC1918.
  bool _esPrivada(String ip) {
    final o = _octetos(ip);
    if (o == null) return false;
    if (o[0] == 10) return true; // 10.0.0.0/8
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true; // 172.16.0.0/12
    if (o[0] == 192 && o[1] == 168) return true; // 192.168.0.0/16
    return false;
  }

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
