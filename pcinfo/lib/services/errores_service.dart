import 'dart:convert';
import 'dart:io';

import '../models/errores.dart';

/// Fuente del "Historial de Errores". Va aparte de HardwareService porque el
/// backend lo expone en otro endpoint (/errores) y es bastante más lento: la GUI
/// solo lo pide cuando el usuario abre esa pestaña.
abstract class ErroresService {
  Future<ErroresInfo> load();
}

class HttpErroresService implements ErroresService {
  final Uri endpoint;

  HttpErroresService({String url = 'http://127.0.0.1:51247/errores'})
      : endpoint = Uri.parse(url);

  @override
  Future<ErroresInfo> load() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(endpoint);
      // Margen amplio: en Windows se recorren 30 días de registro de eventos y
      // se analizan los volcados de memoria (.dmp) de cada pantallazo azul.
      final resp = await req.close().timeout(const Duration(minutes: 3));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: endpoint);
      }
      final body = await resp.transform(utf8.decoder).join();
      return ErroresInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }
}
