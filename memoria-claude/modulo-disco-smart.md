---
name: modulo-disco-smart
description: "Panel S.M.A.R.T. de discos — parseo smartctl, atributos en español, escrituras/lecturas totales estilo CrystalDiskInfo."
metadata: 
  node_type: memory
  type: project
  originSessionId: c280056a-2cbd-4661-9596-544ea181f747
---

# Módulo Disco (S.M.A.R.T.)

Todo vive en `src/linux_hwmonitor.py` (archivo único). Clase `DiskInfoPanel`. Datos de `get_smart_data()` que parsea `smartctl -a -j` (JSON).

## Qué muestra (panel derecho, estilo CrystalDiskInfo, todo en español)
- **Lecturas Totales (Host)** ← atributo SATA 242 / NVMe `data_units_read`.
- **Escrituras Totales (Host)** ← atributo SATA 241 / NVMe `data_units_written`.
- **Escrituras Totales (NAND)** ← atributo 249 o nombre con "nand/flash"+"writ"; muchos SSD (ej. Kingston SA400) NO lo exponen → muestra `--` (correcto, no es bug).
- Veces Encendido (12 / `power_cycles`), Horas Encendido (9 / `power_on_hours`).

## Conversión de unidades — clave
`_attr_to_bytes(name, raw, lba_size)` decide la unidad por el **nombre** del atributo: contiene "gib"→×1024³, "gb"→×1e9, "lba/sector"→×lba_size (512), default→×512. NVMe: 1 data unit = 512000 bytes. `_fmt_bytes()` formatea a TB/GB/MB. Si la cifra no cuadra con un disco real, revisar el nombre real del atributo con `sudo smartctl -A /dev/sdX`.

## ⭐ Replicado en backend Go (2026-06-22) — `backend/collector/smart.go`
La misma lógica name-based vive ahora en Go (`attrToBytes`, `ataLifeUsed`). **Bug real corregido**: antes multiplicaba SIEMPRE ×512 → Kingston SA400 (atributo 241 `Lifetime_Writes_GiB` raw=6531) mostraba **3.2 MiB** en vez de **6.4 TiB** (6531×1024³). Fix: decidir unidad por nombre (gib/gb/mib/mb/lba/sector). Vida SSD SATA (`ataLifeUsed`): por nombre — `ssd_life_left`/`life_left`/`media_wearout` → 100−valorNormalizado; `*life_used` → raw directo; respaldo `wear_leveling`. Ejemplos verificados con SMART real de tuxor: Kingston SA400 231 `SSD_Life_Left`=97 → 97% restante; ADATA SU800 177 `Wear_Leveling_Count`=100 → 100% restante.
- ✅ **ADATA SU800NS38 RESUELTO (Rev 4)**: su 241/242 están en **unidades de 32 MiB**, NO en sectores. Lo confirma el propio `drivedb.h` de smartmontools (`-v 241,raw48,Host_Writes_32MiB`), pero su regex de preset cubre `SU800` y NO la variante `SU800NS38` → smartctl cae al genérico `Total_LBAs_Written` (×512) → mostraba 67 MiB. Fix en `smart.go`: `hostBytes()` con tabla `modelHostUnit` (override por modelo, regex `ADATA[ _]SU[689]\d\d` → 32 MiB), copiando ese dato del drivedb. Ahora ADATA = 4.18 TiB / 5.37 TiB. Además `attrToBytes` ahora parsea múltiplos embebidos en el nombre (`_32MiB`, `_1GiB`) para que cualquier disco cuyo preset SÍ aplique salga bien automáticamente.

## Discos resueltos vía drivedb-add.h (DB por modelo, [[mejora-smart-drivedb]])
- **ADATA SU800NS38 (Silicon Motion)**: 241/242 en 32 MiB. Override + entrada drivedb.
- **WD Green/Blue 2.5"/M.2 (SanDisk) — Rev 8 (2026-06-23)**: su 241/242 están en **GiB**, NO en LBAs (preset oficial smartmontools familia "SanDisk based SSDs": `-v 241,raw48,Total_Writes_GiB`). El modelo `WD Green 2.5 1000GB` NO está en el drivedb por defecto → smartctl usaba el genérico `Total_LBAs_Written` → la app hacía ×512 = **6.9 MiB** en vez de ~13.8 TiB (14160 GiB). Fix: entrada en `drivedb-add.h` regex `WD (Green|Blue) (2\.5|M\.2|3D|SA510) .*` que SOLO renombra 241→Total_Writes_GiB y 242→Total_Reads_GiB (los demás atributos se dejan genéricos para no alterar "Vida restante", que sale del 233 Media_Wearout_Indicator). `attrToBytes` ve "GiB" → ×1024³. Diagnóstico: `sudo smartctl -a /dev/sdX` mostró 241 raw=14160 con nombre genérico.

## Unidad de capacidad de disco — Rev 8
`formatDiskCap()` (en format.dart): el encabezado del disco y la fila "Capacidad" usan unidad DECIMAL del fabricante (GB hasta 1000, luego TB). Antes el encabezado iba en GiB (binario) y "Capacidad" en GB → confundía (447.1 GiB vs 480.1 GB = MISMO disco de 480 GB). Ocupado/Disponible siguen en GB (`formatGB`).

## Sobre la "base de datos" tipo CrystalDiskInfo
- **CDI es open source (BSD modificada) pero NO tiene archivo de DB**: la lógica por modelo está hardcodeada en C++ (`AtaSmart.cpp`). No se puede "bajar" una DB; habría que portar código.
- **La DB curada equivalente es `drivedb.h` de smartmontools** (ya en el sistema: `/var/lib/smartmontools/drivedb/drivedb.h`, actualizable con `update-smart-drivedb`). De ahí salen los nombres con unidad. smartctl la aplica solo por regex de modelo.
- Cuando un modelo no matchea el preset (caso SU800NS38) → agregar override en el backend (copiar la línea del drivedb) o un `drivedb-add.h` y pasar `smartctl -B`. Elegimos el override en código por ser self-contained (sirve igual en Windows).

## Atributos en español
`SMART_ATTRS_ES` (dict por **id** entero) y `SMART_NVME_ES` (dict por nombre). Tabla de 8 columnas: ID · Atributo · Qué significa · Estado · Valor · Peor · Umbral · Raw. El nombre técnico original va en tooltip. Si el id no está en el dict → usa el nombre de smartctl + "atributo del fabricante".

## Campos que ANTES estaban hardcodeados (falsos) y ahora son reales
- "Versión ATA / SATA" (antes fijo `ACS-4 | ACS-4 Revision 5`) ← `ata_version.string` + `sata_version.string`.
- "Velocidad Interfaz" (antes fijo `SATA/600`) ← `interface_speed.current/max`.
- "Características" (antes fijo `S.M.A.R.T., NCQ, TRIM, DevSleep`) ← TRIM real (`trim.supported`), SSD/RPM (`rotation_rate`), cifrado ATA.

## Build instalador
No hay script automatizado. `.deb` se arma con `dpkg-deb --build --root-owner-group deb-build/linuxhwmonitor_X.Y-Z_all <salida>.deb`. OJO: el dir `DEBIAN/` hereda setgid del padre (grupo www-data) → quitar con `find ... -type d | xargs chmod g-s` antes de `dpkg-deb` (si no: error "permisos erróneos 2755"). Versión en `deb-build/.../DEBIAN/control` + `setWindowTitle` del py + `install.sh`.

**Ver también:** [[proyecto-contexto]]
