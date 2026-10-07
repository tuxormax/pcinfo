import '../models/controladores.dart';
import 'backend_http.dart';

/// Fuente de la pestaña "Controladores": el inventario (GET) y las operaciones
/// de respaldo y restauración (POST + sondeo del avance).
///
/// Las operaciones NO se esperan en una sola llamada: el backend las arranca en
/// segundo plano y devuelve el estado inicial, y la GUI va preguntando por
/// [tarea] cada segundo. Exportar los controladores de un equipo puede tardar
/// minutos y así se ve el avance en vez de un reloj de arena.
abstract class ControladoresService {
  Future<ControladoresInfo> load();

  /// Arranca el respaldo o la restauración. Lanza [BackendError] con el motivo
  /// si el backend se niega (sin administrador, sin carpeta, tarea en curso…).
  Future<TareaInfo> inicia({
    required String kind,
    required String carpeta,
    required bool drivers,
    required bool wifi,
  });

  /// Baja e instala del catálogo del fabricante las filas con esos ids. El
  /// enlace y el hash los resuelve el backend: aquí solo viajan los ids.
  Future<TareaInfo> descarga(List<String> ids);

  /// Estado de la tarea en curso (o de la última que terminó).
  Future<TareaInfo> tarea();

  /// Aborta la tarea en curso.
  Future<void> cancela();
}

class HttpControladoresService implements ControladoresService {
  final Uri base;

  HttpControladoresService({
    String url = 'http://127.0.0.1:51247/controladores',
  }) : base = Uri.parse(url);

  Uri _sub(String cola) => base.replace(path: '${base.path}$cola');

  @override
  Future<ControladoresInfo> load() async {
    final json = await pideJson(
      base,
      espera: const Duration(minutes: 2),
      que: 'al leer los controladores y las redes WiFi',
    );
    return ControladoresInfo.fromJson(json);
  }

  @override
  Future<TareaInfo> inicia({
    required String kind,
    required String carpeta,
    required bool drivers,
    required bool wifi,
  }) async {
    final json = await enviaJson(
      _sub('/$kind'),
      {'carpeta': carpeta, 'drivers': drivers, 'wifi': wifi},
      espera: const Duration(seconds: 30),
      que: 'al iniciar la operación',
    );
    return TareaInfo.fromJson(json);
  }

  @override
  Future<TareaInfo> descarga(List<String> ids) async {
    final json = await enviaJson(
      _sub('/descargar'),
      {'ids': ids},
      espera: const Duration(seconds: 30),
      que: 'al iniciar la descarga de controladores',
    );
    return TareaInfo.fromJson(json);
  }

  @override
  Future<TareaInfo> tarea() async {
    final json = await pideJson(
      _sub('/tarea'),
      espera: const Duration(seconds: 20),
      que: 'al consultar el avance',
    );
    return TareaInfo.fromJson(json);
  }

  @override
  Future<void> cancela() async {
    await enviaJson(
      _sub('/cancelar'),
      const {},
      espera: const Duration(seconds: 20),
      que: 'al cancelar la operación',
    );
  }
}
