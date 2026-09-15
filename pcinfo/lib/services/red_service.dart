import '../models/red.dart';
import 'backend_http.dart';

/// Fuente de la pestaña "Red": solo la IP local y la puerta de enlace (lo
/// único que necesita el sistema operativo). El resto del diagnóstico y el
/// test de velocidad los hace la GUI directamente por socket, sin pasar por
/// el backend.
abstract class RedService {
  Future<RedInfo> load();
}

class HttpRedService implements RedService {
  final Uri endpoint;

  HttpRedService({String url = 'http://127.0.0.1:51247/red'})
      : endpoint = Uri.parse(url);

  @override
  Future<RedInfo> load() async {
    final json = await pideJson(
      endpoint,
      espera: const Duration(seconds: 20),
      que: 'al leer la información de red',
    );
    return RedInfo.fromJson(json);
  }
}
