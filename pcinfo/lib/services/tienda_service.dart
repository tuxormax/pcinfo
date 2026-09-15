import '../models/tienda.dart';
import 'backend_http.dart';

/// Fuente de la pestaña "Tienda Windows": el catálogo (GET), el buscador de
/// la Store, y la instalación (POST + sondeo del avance, igual que
/// Controladores: instalar puede tardar minutos por app).
abstract class TiendaService {
  Future<TiendaInfo> load();

  /// Busca apps en la Store por nombre.
  Future<List<AppTienda>> buscar(String consulta);

  /// Arranca la instalación de [apps]. Si [carpeta] no es null, instala los
  /// paquetes YA DESCARGADOS de esa carpeta y [apps] se ignora (respaldo
  /// cuando rg-adguard está bloqueado por Cloudflare).
  Future<TareaTiendaInfo> instala({
    List<AppTienda> apps = const [],
    String? carpeta,
    required String arch,
    required String ring,
    required bool todos,
  });

  /// Estado de la instalación en curso (o de la última que terminó).
  Future<TareaTiendaInfo> tarea();

  /// Aborta la instalación en curso.
  Future<void> cancela();
}

class HttpTiendaService implements TiendaService {
  final Uri base;

  HttpTiendaService({String url = 'http://127.0.0.1:51247/tienda'})
      : base = Uri.parse(url);

  Uri _sub(String cola) => base.replace(path: '${base.path}$cola');

  @override
  Future<TiendaInfo> load() async {
    final json = await pideJson(
      base,
      espera: const Duration(seconds: 20),
      que: 'al leer la Tienda Windows',
    );
    return TiendaInfo.fromJson(json);
  }

  @override
  Future<List<AppTienda>> buscar(String consulta) async {
    final json = await pideJson(
      _sub('/buscar').replace(queryParameters: {'q': consulta}),
      espera: const Duration(seconds: 25),
      que: 'al buscar en la Store',
    );
    return (json['apps'] as List? ?? const [])
        .map((e) => AppTienda.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<TareaTiendaInfo> instala({
    List<AppTienda> apps = const [],
    String? carpeta,
    required String arch,
    required String ring,
    required bool todos,
  }) async {
    final json = await enviaJson(
      _sub('/instalar'),
      {
        'apps': apps.map((a) => a.toJson()).toList(),
        'carpeta': carpeta ?? '',
        'arch': arch,
        'ring': ring,
        'todos': todos,
      },
      espera: const Duration(seconds: 30),
      que: 'al iniciar la instalación',
    );
    return TareaTiendaInfo.fromJson(json);
  }

  @override
  Future<TareaTiendaInfo> tarea() async {
    final json = await pideJson(
      _sub('/tarea'),
      espera: const Duration(seconds: 20),
      que: 'al consultar el avance',
    );
    return TareaTiendaInfo.fromJson(json);
  }

  @override
  Future<void> cancela() async {
    await enviaJson(
      _sub('/cancelar'),
      const {},
      espera: const Duration(seconds: 20),
      que: 'al cancelar la instalación',
    );
  }
}
