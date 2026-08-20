import '../models/bateria.dart';
import 'backend_http.dart';

/// Fuente de la pestaña "Batería". Va aparte de HardwareService porque el
/// backend lo expone en otro endpoint (/bateria) y tarda: en Windows le pide a
/// powercfg que genere su informe de batería, que recorre meses de registro de
/// energía. La GUI solo lo pide cuando el usuario abre esa pestaña.
abstract class BateriaService {
  Future<BateriaInfo> load();
}

class HttpBateriaService implements BateriaService {
  final Uri endpoint;

  HttpBateriaService({String url = 'http://127.0.0.1:51247/bateria'})
      : endpoint = Uri.parse(url);

  @override
  Future<BateriaInfo> load() async {
    final json = await pideJson(
      endpoint,
      espera: const Duration(minutes: 2),
      que: 'al leer el estado de la batería',
    );
    return BateriaInfo.fromJson(json);
  }
}
