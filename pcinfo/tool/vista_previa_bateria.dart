// Vista previa de la pestaña "Batería" con datos de un equipo real, para poder
// verla en el escritorio sin tener ese portátil delante. NO forma parte de la
// app: es una herramienta de desarrollo.
//
//   PCINFO_VISTA_PREVIA=/ruta/bateria.json flutter run -t tool/vista_previa_bateria.dart -d linux
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pcinfo/models/bateria.dart';
import 'package:pcinfo/theme.dart';
import 'package:pcinfo/ui/bateria_page.dart';

void main() {
  final ruta = Platform.environment['PCINFO_VISTA_PREVIA'] ?? 'bateria.json';
  final json = jsonDecode(File(ruta).readAsStringSync()) as Map<String, dynamic>;
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(child: BateriaPage(data: BateriaInfo.fromJson(json))),
    ),
  ));
}
