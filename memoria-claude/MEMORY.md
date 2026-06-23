# Memoria - PCInfo

Monitor/inventario de hardware de tuxor. Repo `tuxormax/pcinfo`. **En migración: de Python+PyQt5 → Go+Flutter (cross-platform Linux/Windows), solo inventario sin temperaturas.**

## Indice
- [proyecto-rewrite-go-flutter](proyecto-rewrite-go-flutter.md) — ⭐ ACTUAL (2026-06-22): rewrite a Go+Flutter, reemplaza el plan PyQt5. Por qué, estado, pendientes.
- [modulo-gui-pcinfo](modulo-gui-pcinfo.md) — GUI Flutter "PCInfo": fichas, modelo de datos, decisiones de diseño, datos difíciles en Windows.
- [proyecto-contexto](proyecto-contexto.md) — qué es, stack original (versión PyQt5).
- [modulo-disco-smart](modulo-disco-smart.md) — S.M.A.R.T.: parseo smartctl, unidades por nombre de atributo, vida SSD (método CDI), fix ADATA 32 MiB. Backend Go `smart.go` + referencia PyQt5.
- [mejora-smart-drivedb](mejora-smart-drivedb.md) — ✅ HECHO (Rev 5): DB por modelo estilo CDI = `drivedb-add.h` embebido + `smartctl -B`. modelHostUnit queda de respaldo.
- [mejora-port-windows](mejora-port-windows.md) — ⚠️ OBSOLETO: plan viejo de port manteniendo PyQt5. Sustituido por [[proyecto-rewrite-go-flutter]].
