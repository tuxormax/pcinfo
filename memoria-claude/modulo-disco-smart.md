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

## Atributos en español
`SMART_ATTRS_ES` (dict por **id** entero) y `SMART_NVME_ES` (dict por nombre). Tabla de 8 columnas: ID · Atributo · Qué significa · Estado · Valor · Peor · Umbral · Raw. El nombre técnico original va en tooltip. Si el id no está en el dict → usa el nombre de smartctl + "atributo del fabricante".

## Campos que ANTES estaban hardcodeados (falsos) y ahora son reales
- "Versión ATA / SATA" (antes fijo `ACS-4 | ACS-4 Revision 5`) ← `ata_version.string` + `sata_version.string`.
- "Velocidad Interfaz" (antes fijo `SATA/600`) ← `interface_speed.current/max`.
- "Características" (antes fijo `S.M.A.R.T., NCQ, TRIM, DevSleep`) ← TRIM real (`trim.supported`), SSD/RPM (`rotation_rate`), cifrado ATA.

## Build instalador
No hay script automatizado. `.deb` se arma con `dpkg-deb --build --root-owner-group deb-build/linuxhwmonitor_X.Y-Z_all <salida>.deb`. OJO: el dir `DEBIAN/` hereda setgid del padre (grupo www-data) → quitar con `find ... -type d | xargs chmod g-s` antes de `dpkg-deb` (si no: error "permisos erróneos 2755"). Versión en `deb-build/.../DEBIAN/control` + `setWindowTitle` del py + `install.sh`.

**Ver también:** [[proyecto-contexto]]
