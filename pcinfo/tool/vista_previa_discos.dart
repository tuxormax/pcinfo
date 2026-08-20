// Vista previa de la pestaña "Discos" con datos de discos reales, para verla en
// el escritorio sin tener ese equipo delante. NO forma parte de la app.
//
//   PCINFO_VISTA_PREVIA_DISCOS=/ruta/discos.json flutter run -t tool/vista_previa_discos.dart -d linux
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pcinfo/models/hardware.dart';
import 'package:pcinfo/theme.dart';
import 'package:pcinfo/ui/discos_page.dart';

void main() {
  final ruta = Platform.environment['PCINFO_VISTA_PREVIA_DISCOS'] ?? 'discos.json';
  final json = jsonDecode(File(ruta).readAsStringSync()) as Map<String, dynamic>;
  final discos = (json['discos'] as List)
      .map((e) => DiskInfo.fromJson(e as Map<String, dynamic>))
      .toList();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(child: DiscosPage(discos: discos)),
    ),
  ));
}
