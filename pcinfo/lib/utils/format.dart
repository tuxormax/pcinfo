/// Formatea bytes a una cadena legible (base binaria: GiB/MiB).
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var size = bytes.toDouble();
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  final n = i == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(decimals);
  return '$n ${units[i]}';
}

/// Formatea bytes a GB decimales (base 1000, como se etiqueta la capacidad de
/// discos). Ej.: 240057409536 → "240.1 GB".
String formatGB(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 GB';
  return '${(bytes / 1e9).toStringAsFixed(decimals)} GB';
}

/// Formatea la capacidad de un disco en unidad DECIMAL (la real del fabricante):
/// GB hasta 1000, TB de ahí en adelante. Se usa tanto en el encabezado del disco
/// como en "Capacidad" para que coincidan (antes el encabezado iba en GiB y
/// confundía: 447.1 GiB vs 480.1 GB son el MISMO disco). Ej.: 480 GB / 1.0 TB.
String formatDiskCap(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '—';
  final gb = bytes / 1e9;
  if (gb >= 1000) return '${(gb / 1000).toStringAsFixed(decimals)} TB';
  return '${gb.toStringAsFixed(decimals)} GB';
}

/// Normaliza el nombre del fabricante de CPU a su forma corta.
String cleanVendor(String vendor) {
  final v = vendor.trim();
  if (v.toLowerCase().contains('amd')) return 'AMD';
  if (v.toLowerCase().contains('intel')) return 'Intel';
  return v;
}

/// Convierte MHz a GHz cuando aplica.
String formatMhz(double mhz) {
  if (mhz <= 0) return '—';
  if (mhz >= 1000) return '${(mhz / 1000).toStringAsFixed(2)} GHz';
  return '${mhz.toStringAsFixed(0)} MHz';
}
