import '../models/arranques.dart';
import 'backend_http.dart';

/// Fuente de "Encendidos y apagados" (GET /arranques). Va aparte del hardware
/// porque recorre el registro de accesos, el diario del sistema y consulta a
/// systemd: la GUI solo lo pide cuando se abre esa pestaña.
abstract class ArranquesService {
  Future<ArranquesInfo> load();

  /// Activa el diario permanente del sistema. Modifica el equipo, así que va
  /// por POST y el sistema pide la contraseña de administrador.
  Future<ResultadoAccion> activarDiario();
}

/// Lo que contesta una acción que modifica el equipo.
class ResultadoAccion {
  final bool ok;
  final String message;
  final String detail;

  const ResultadoAccion(
      {this.ok = false, this.message = '', this.detail = ''});

  factory ResultadoAccion.fromJson(Map<String, dynamic> j) => ResultadoAccion(
        ok: j['ok'] ?? false,
        message: j['message'] ?? '',
        detail: j['detail'] ?? '',
      );
}

class HttpArranquesService implements ArranquesService {
  final Uri endpoint;

  HttpArranquesService({String url = 'http://127.0.0.1:51247/arranques'})
      : endpoint = Uri.parse(url);

  @override
  Future<ArranquesInfo> load() async {
    final json = await pideJson(
      endpoint,
      espera: const Duration(minutes: 2),
      que: 'al leer el historial de encendidos y apagados',
    );
    return ArranquesInfo.fromJson(json);
  }

  @override
  Future<ResultadoAccion> activarDiario() async {
    // Espera larga a propósito: el diálogo de contraseña del escritorio lo
    // contesta una persona, y cortar a los treinta segundos dejaría el trabajo
    // hecho a medias sin que la app se entere.
    final json = await enviaJson(
      endpoint.replace(path: '${endpoint.path}/diario'),
      const {},
      espera: const Duration(minutes: 5),
      que: 'al activar el diario permanente del sistema',
    );
    return ResultadoAccion.fromJson(json);
  }
}
