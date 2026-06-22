import 'package:flutter/material.dart';

/// Tamaño de fuente único para toda la app.
const double kFont = 14.0;

/// Paleta y tema de la app. Estilo "panel de diagnóstico": fondo slate
/// profundo, superficies sutiles, acento cian-verde para datos clave.
class AppColors {
  static const bg = Color(0xFF0E1116);
  static const surface = Color(0xFF161B22);
  static const surfaceAlt = Color(0xFF1C232D);
  static const border = Color(0xFF273039);
  static const accent = Color(0xFF2DD4A7); // cian-verde
  static const accentDim = Color(0xFF1B6B58);
  static const textHi = Color(0xFFE6EDF3);
  static const textMid = Color(0xFF9DA7B3);
  static const textLow = Color(0xFF6B7682);

  // Acentos por categoría (icono de cada tarjeta).
  static const cpu = Color(0xFF2DD4A7);
  static const board = Color(0xFFE3A84B);
  static const ram = Color(0xFF6AA9FF);
  static const gpu = Color(0xFFB07CFF);
  static const disk = Color(0xFFF2768D);
  static const system = Color(0xFF4FD1C5);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      surface: AppColors.surface,
      primary: AppColors.accent,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textHi,
      displayColor: AppColors.textHi,
      fontFamily: 'Ubuntu',
    ),
  );
}
