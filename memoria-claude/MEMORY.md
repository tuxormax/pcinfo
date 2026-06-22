# Memoria - LinuxHWMonitor

Monitor/inventario de hardware de tuxor. Repo `tuxormax/LinuxHWMonitor`. **En migración: de Python+PyQt5 → Go+Flutter (cross-platform Linux/Windows), solo inventario sin temperaturas.**

## Indice
- [proyecto-rewrite-go-flutter](proyecto-rewrite-go-flutter.md) — ⭐ ACTUAL (2026-06-22): rewrite a Go+Flutter, reemplaza el plan PyQt5. Por qué, estado, pendientes.
- [modulo-gui-pcinfo](modulo-gui-pcinfo.md) — GUI Flutter "PCInfo": fichas, modelo de datos, decisiones de diseño, datos difíciles en Windows.
- [proyecto-contexto](proyecto-contexto.md) — qué es, stack original (versión PyQt5).
- [modulo-disco-smart](modulo-disco-smart.md) — panel S.M.A.R.T. (PyQt5): parseo smartctl, atributos en español, escrituras/lecturas totales. Referencia para el backend Go.
- [mejora-port-windows](mejora-port-windows.md) — ⚠️ OBSOLETO: plan viejo de port manteniendo PyQt5. Sustituido por [[proyecto-rewrite-go-flutter]].
