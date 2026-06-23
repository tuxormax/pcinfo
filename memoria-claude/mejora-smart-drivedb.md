---
name: mejora-smart-drivedb
description: HECHO (Rev 5) — DB por modelo estilo CDI vía drivedb-add.h embebido + smartctl -B; modelHostUnit queda solo de respaldo.
metadata: 
  node_type: memory
  type: project
  originSessionId: 92db810f-2450-4a8d-9ca6-4f38011bb58b
---

# DB por modelo para SMART — ✅ IMPLEMENTADO (Rev 5, 2026-06-23)

Se eligió la **opción 2** (bundlear `drivedb-add.h` propio + `smartctl -B +<archivo>`).

## Cómo quedó
- **`backend/collector/drivedb-add.h`**: base de datos por modelo en el FORMATO OFICIAL de smartmontools (5 columnas). Hoy 1 entrada: familia `ADATA SU(6xx|[789]00)NS38` (Silicon Motion) con los presets `-v 241,raw48,Host_Writes_32MiB`/`242 Host_Reads_32MiB` (+ erase counts y `169 Remaining_Lifetime_Perc`, `231 SSD_Life_Left`), copiados del drivedb.h del sistema, ampliando el regex para cubrir el sufijo `NS38` que el oficial no consume.
- **`smart.go`**: el archivo se **embebe** (`//go:embed drivedb-add.h`), se materializa a un temporal una sola vez (`drivedbArg()` con `sync.Once`) y se pasa a cada llamada `smartctl -B +<temp> --json -a <dev>`. smartctl PREPENDE la entrada a su drivedb interno (gana prioridad, cae al built-in si no matchea). Como devuelve el nombre `Host_Writes_32MiB`, `attrToBytes` lo resuelve solo por el múltiplo embebido.
- **`modelHostUnit`** (override por modelo en Go) sigue existiendo SOLO como respaldo si `-B` no carga (smartctl viejo / temporal no escribible).
- Verificado lo verificable sin root: smartctl parsea el archivo sin errores (`-P showall` lista la entrada), el regex matchea `ADATA SU800NS38/SU900NS38/SU650NS38`, el temporal se crea al pegarle a `/hardware`. La verificación final sobre disco real necesita el backend como servicio root.

## Cómo AGREGAR un modelo nuevo (cuando reporte TB/% raros)
1. `smartctl -A /dev/sdX` y compara con la capacidad real.
2. Busca la familia en `/var/lib/smartmontools/drivedb/drivedb.h`, copia su bloque `-v ...`.
3. Pega una entrada nueva en `drivedb-add.h` AMPLIANDO el regex del modelo (col. 2). Recompila el backend (el `.h` se reembebe).

## Estado previo (Rev 4) — lo que YA funcionaba
- `backend/collector/smart.go`:
  - `attrToBytes()` decide unidad por NOMBRE del atributo, incluyendo múltiplos embebidos (`_32MiB`, `_1GiB`, etc.) → cualquier disco cuyo preset de smartmontools SÍ matchee sale correcto solo.
  - `ataLifeUsed()` calcula % de vida por nombre del atributo (igual método que CDI: valor normalizado del atributo de desgaste).
  - `modelHostUnit` (tabla de override por modelo): solo 1 entrada → `ADATA[ _]SU[689]\d\d` = 32 MiB para 241/242 (la familia SU Silicon Motion; smartmontools tiene el dato pero su regex no cubre `SU800NS38`).
- Verificado real con discos de tuxor: Kingston SA400 (6.4/4.5 TiB, 97%), ADATA SU800NS38 (4.18/5.37 TiB, 100%).

## Futuro (opcional, ya no urgente)
La opción 2 (drivedb-add.h embebido) ya cubre el caso. Si algún día se quiere más cobertura automática:
- **`update-smart-drivedb`** en el instalador/servicio para traer el drivedb del sistema más reciente (puede cubrir variantes nuevas sin tocar nuestro `.h`). En Windows habría que distribuir el drivedb junto al backend.

## Por qué NO se usa la DB de CrystalDiskInfo
- CDI es open source (BSD modificada) pero su lógica por modelo está **hardcodeada en C++** (`AtaSmart.cpp`): detecta fabricante por el string del modelo y elige atributo/unidad. **No hay archivo de DB** que copiar.
- La DB curada equivalente y reutilizable es **`drivedb.h` de smartmontools** (ya en el sistema). Es la fuente correcta a aprovechar (opciones 2 y 3).

**Ver también:** [[modulo-disco-smart]] [[proyecto-rewrite-go-flutter]]
