import 'package:flutter/material.dart';

import '../theme.dart';
import '../version.dart';

/// Texto «Creado por …» + logo de SEIS. Widget único del pie (regla global
/// LOGO-SEIS-PIE): alto pequeño, sin recolorear el logo (fondo oscuro, letras cian).
class PieSeis extends StatelessWidget {
  const PieSeis({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Creado por $appAuthor',
          style: TextStyle(color: AppColors.textLow, fontSize: kFont),
        ),
        const SizedBox(width: 10),
        Image.asset('assets/logo_seis_pie.png', height: 22, semanticLabel: 'SEIS'),
      ],
    );
  }
}
