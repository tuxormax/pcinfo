import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fallo al hablar con el backend, CON la causa concreta a la vista.
///
/// Antes cualquier problema (backend caído, tardanza, error interno del
/// colector) terminaba en el mismo texto "el servicio no está respondiendo", que
/// no permite diagnosticar nada en un equipo ajeno: no distingue entre "no
/// arrancó", "tardó demasiado" y "se rompió leyendo los discos". [mensaje] dice
/// qué pasó en español y [detalle] trae el texto crudo (incluidos el error y la
/// traza que devuelve el backend en un 500) para poder copiarlo y reportarlo.
class BackendError implements Exception {
  const BackendError(this.mensaje, {this.detalle = ''});

  final String mensaje;
  final String detalle;

  @override
  String toString() => detalle.isEmpty ? mensaje : '$mensaje\n\n$detalle';
}

/// GET al backend devolviendo el JSON ya decodificado. Cualquier fallo sale como
/// [BackendError] con la causa. [que] completa la frase ("al leer el hardware").
Future<Map<String, dynamic>> pideJson(
  Uri uri, {
  required Duration espera,
  required String que,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(uri);
    final resp = await req.close().timeout(espera);
    final cuerpo = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw BackendError(
        'El servicio de PCInfo falló $que (HTTP ${resp.statusCode}).',
        detalle: _detalle(uri, 'HTTP ${resp.statusCode}', cuerpo),
      );
    }
    return jsonDecode(cuerpo) as Map<String, dynamic>;
  } on BackendError {
    rethrow;
  } on TimeoutException {
    throw BackendError(
      'El servicio de PCInfo tardó demasiado $que '
      '(más de ${espera.inSeconds} s) y se canceló la espera.',
      detalle: _detalle(uri, 'Tiempo de espera agotado (${espera.inSeconds} s)', ''),
    );
  } on SocketException catch (e) {
    throw BackendError(
      'No se pudo conectar con el servicio de PCInfo.',
      detalle: _detalle(
        uri,
        e.osError == null ? e.message : '${e.message} (${e.osError})',
        '',
      ),
    );
  } catch (e) {
    throw BackendError(
      'Fallo inesperado $que.',
      detalle: _detalle(uri, '$e', ''),
    );
  } finally {
    client.close(force: true);
  }
}

/// Arma el bloque copiable. Si el cuerpo es el JSON de error del backend
/// (`{ok:false, error, stack}`), se despliega error y traza; si no, se copia el
/// cuerpo crudo recortado.
String _detalle(Uri uri, String causa, String cuerpo) {
  final b = StringBuffer()
    ..writeln('GET $uri')
    ..writeln('Causa: $causa');
  if (cuerpo.trim().isEmpty) return b.toString().trimRight();
  try {
    final j = jsonDecode(cuerpo) as Map<String, dynamic>;
    final err = '${j['error'] ?? ''}';
    final stack = '${j['stack'] ?? ''}';
    if (err.isNotEmpty) {
      b.writeln('Error del sistema: $err');
      if (stack.isNotEmpty) {
        b
          ..writeln('--- Traza ---')
          ..writeln(_recorta(stack, 2000));
      }
      return b.toString().trimRight();
    }
  } catch (_) {
    // no era JSON: se copia el cuerpo tal cual
  }
  b
    ..writeln('Respuesta:')
    ..writeln(_recorta(cuerpo, 1500));
  return b.toString().trimRight();
}

String _recorta(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
