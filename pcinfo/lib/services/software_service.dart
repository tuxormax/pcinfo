import '../models/software.dart';
import 'backend_http.dart';

/// Fuente del "Software instalado". Va aparte de HardwareService porque el
/// backend lo expone en otro endpoint (/software) y tarda: recorre el registro
/// de Windows y consulta las apps de la Tienda. La GUI solo lo pide cuando el
/// usuario abre esa pestaña.
abstract class SoftwareService {
  Future<SoftwareInfo> load();

  /// Quita una app de la Tienda (PackageFullName) del usuario actual.
  Future<void> quitaTienda(String paquete);
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

  @override
  Future<void> quitaTienda(String paquete) async {
    await enviaJson(
      endpoint.replace(path: '/software/desinstalar'),
      {'package': paquete},
      espera: const Duration(minutes: 4),
      que: 'al quitar la app',
    );
  }
}
