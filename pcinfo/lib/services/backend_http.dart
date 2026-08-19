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
}) =>
    _llama(uri, espera: espera, que: que);

/// POST al backend con [cuerpo] en JSON, devolviendo el JSON de respuesta ya
/// decodificado. Solo lo usan las operaciones que ESCRIBEN en el sistema
/// (respaldar y restaurar controladores y redes WiFi): el backend las exige por
/// POST justamente para que no se disparen por accidente con un GET.
Future<Map<String, dynamic>> enviaJson(
  Uri uri,
  Map<String, dynamic> cuerpo, {
  required Duration espera,
  required String que,
}) =>
    _llama(uri, espera: espera, que: que, cuerpo: cuerpo);

Future<Map<String, dynamic>> _llama(
  Uri uri, {
  required Duration espera,
  required String que,
  Map<String, dynamic>? cuerpo,
}) async {
  final metodo = cuerpo == null ? 'GET' : 'POST';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = cuerpo == null
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    if (cuerpo != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(cuerpo));
    }
    final resp = await req.close().timeout(espera);
    final cuerpoResp = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw BackendError(
        _mensajeServidor(cuerpoResp) ??
            'El servicio de PCInfo falló $que (HTTP ${resp.statusCode}).',
        detalle: _detalle(metodo, uri, 'HTTP ${resp.statusCode}', cuerpoResp),
      );
    }
    return jsonDecode(cuerpoResp) as Map<String, dynamic>;
  } on BackendError {
    rethrow;
  } on TimeoutException {
    throw BackendError(
      'El servicio de PCInfo tardó demasiado $que '
      '(más de ${espera.inSeconds} s) y se canceló la espera.',
      detalle: _detalle(metodo, uri, 'Tiempo de espera agotado (${espera.inSeconds} s)', ''),
    );
  } on SocketException catch (e) {
    throw BackendError(
      'No se pudo conectar con el servicio de PCInfo.',
      detalle: _detalle(
        metodo,
        uri,
        e.osError == null ? e.message : '${e.message} (${e.osError})',
        '',
      ),
    );
  } catch (e) {
    throw BackendError(
      'Fallo inesperado $que.',
      detalle: _detalle(metodo, uri, '$e', ''),
    );
  } finally {
    client.close(force: true);
  }
}

/// Mensaje de negocio del backend, si lo hay. Un 409 de "ya hay una tarea en
/// curso" o un 400 de "falta la carpeta" traen el motivo REDACTADO para el
/// usuario: mostrarlo tal cual es mucho más útil que el código HTTP.
String? _mensajeServidor(String cuerpo) {
  if (cuerpo.trim().isEmpty) return null;
  try {
    final j = jsonDecode(cuerpo) as Map<String, dynamic>;
    if (j['ok'] == false) {
      final msg = '${j['error'] ?? ''}'.trim();
      // Si trae traza es un fallo interno, no un mensaje pensado para leerse.
      if (msg.isNotEmpty && '${j['stack'] ?? ''}'.isEmpty) return msg;
    }
  } catch (_) {
    // no era JSON
  }
  return null;
}

/// Arma el bloque copiable. Si el cuerpo es el JSON de error del backend
/// (`{ok:false, error, stack}`), se despliega error y traza; si no, se copia el
/// cuerpo crudo recortado.
String _detalle(String metodo, Uri uri, String causa, String cuerpo) {
  final b = StringBuffer()
    ..writeln('$metodo $uri')
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
