// Vista previa de la pestaña "Encendidos y apagados" con la respuesta de un
// equipo real, para verla sin tener ese equipo delante. NO forma parte de la
// app: es una herramienta de desarrollo.
//
//   curl -s http://127.0.0.1:51247/arranques > arranques.json
//   PCINFO_VISTA_PREVIA=arranques.json flutter run -t tool/vista_previa_arranques.dart -d linux
//
// PCINFO_VISTA_SECCION=0|1|2 abre directo en encendidos, tareas o autoarranque.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pcinfo/models/arranques.dart';
import 'package:pcinfo/theme.dart';
import 'package:pcinfo/ui/arranques_page.dart';

void main() {
  final ruta = Platform.environment['PCINFO_VISTA_PREVIA'] ?? 'arranques.json';
  final json = jsonDecode(File(ruta).readAsStringSync()) as Map<String, dynamic>;
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: ArranquesPage(
        data: ArranquesInfo.fromJson(json),
        seccionInicial: int.tryParse(
                Platform.environment['PCINFO_VISTA_SECCION'] ?? '0') ??
            0,
      ),
    ),
  ));
}
