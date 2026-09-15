import 'dart:async';
import 'dart:io';

// Portado tal cual de RedScan (proyecto primo, lib/services/velocidad_service.dart):
// no depende de nada específico de móvil, funciona igual en escritorio.

/// Mide velocidad de internet: latencia (ping), descarga y subida.
/// Usa los endpoints públicos de medición de Cloudflare.
class VelocidadService {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  bool _cancelado = false;
  void cancelar() => _cancelado = true;
  void reiniciar() => _cancelado = false;

  /// Latencia media en ms midiendo conexiones TCP a un host confiable.
  Future<double?> ping({
    String host = '1.1.1.1',
    int port = 443,
    int intentos = 5,
  }) async {
    final tiempos = <double>[];
    for (var i = 0; i < intentos; i++) {
      if (_cancelado) break;
      try {
        final sw = Stopwatch()..start();
        final s = await Socket.connect(host, port,
            timeout: const Duration(seconds: 3));
        sw.stop();
        s.destroy();
        tiempos.add(sw.elapsedMicroseconds / 1000.0);
      } catch (_) {}
    }
    if (tiempos.isEmpty) return null;
    tiempos.sort();
    // mediana, más estable que el promedio ante un pico
    return tiempos[tiempos.length ~/ 2];
  }

  /// Descarga [bytes] bytes y reporta la velocidad en Mbps en vivo.
  Future<double?> descarga({
    int bytes = 25000000,
    void Function(double mbps)? onProgreso,
  }) async {
    try {
      final uri =
          Uri.parse('https://speed.cloudflare.com/__down?bytes=$bytes');
      final req = await _client.getUrl(uri);
      final resp = await req.close();
      var recibidos = 0;
      final sw = Stopwatch()..start();
      await for (final chunk in resp) {
        if (_cancelado) break;
        recibidos += chunk.length;
        final s = sw.elapsedMicroseconds / 1e6;
        if (s > 0 && onProgreso != null) {
          onProgreso(recibidos * 8 / s / 1e6);
        }
      }
      sw.stop();
      final s = sw.elapsedMicroseconds / 1e6;
      if (s <= 0 || recibidos == 0) return null;
      return recibidos * 8 / s / 1e6;
    } catch (_) {
      return null;
    }
  }

  /// Sube [bytes] bytes y reporta la velocidad en Mbps en vivo.
  Future<double?> subida({
    int bytes = 10000000,
    void Function(double mbps)? onProgreso,
  }) async {
    try {
      final uri = Uri.parse('https://speed.cloudflare.com/__up');
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.binary;
      req.contentLength = bytes;
      const tam = 65536;
      final bloque = List<int>.filled(tam, 0x41);
      var enviados = 0;
      final sw = Stopwatch()..start();
      while (enviados < bytes) {
        if (_cancelado) break;
        final n = (bytes - enviados) < tam ? bytes - enviados : tam;
        req.add(n == tam ? bloque : bloque.sublist(0, n));
        await req.flush();
        enviados += n;
        final s = sw.elapsedMicroseconds / 1e6;
        if (s > 0 && onProgreso != null) {
          onProgreso(enviados * 8 / s / 1e6);
        }
      }
      final resp = await req.close();
      await resp.drain<void>();
      sw.stop();
      final s = sw.elapsedMicroseconds / 1e6;
      if (s <= 0 || enviados == 0) return null;
      return enviados * 8 / s / 1e6;
    } catch (_) {
      return null;
    }
  }
}
