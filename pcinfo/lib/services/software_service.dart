import '../models/software.dart';
import 'backend_http.dart';

/// Fuente del "Software instalado". Va aparte de HardwareService porque el
/// backend lo expone en otro endpoint (/software) y tarda: recorre el registro
/// de Windows y consulta las apps de la Tienda. La GUI solo lo pide cuando el
/// usuario abre esa pestaña.
abstract class SoftwareService {
  Future<SoftwareInfo> load();
}

class HttpSoftwareService implements SoftwareService {
  final Uri endpoint;

  HttpSoftwareService({String url = 'http://127.0.0.1:51247/software'})
      : endpoint = Uri.parse(url);

  @override
  Future<SoftwareInfo> load() async {
    final json = await pideJson(
      endpoint,
      espera: const Duration(minutes: 2),
      que: 'al leer el software instalado',
    );
    return SoftwareInfo.fromJson(json);
  }
}
