---
name: mejora-smart-drivedb
description: Pendiente — base de datos por modelo (estilo CrystalDiskInfo) para unidades/vida SMART; hoy solo override puntual del ADATA SU.
metadata: 
  node_type: memory
  type: project
  originSessionId: 92db810f-2450-4a8d-9ca6-4f38011bb58b
---

# Pendiente: DB por modelo para SMART (implementar después)

Decisión 2026-06-22: dejar el parseo SMART como está (Rev 4) y construir más adelante una base de datos por modelo más completa. Acordado con tuxor: "lo implementamos después".

## Estado actual (Rev 4) — lo que YA funciona
- `backend/collector/smart.go`:
  - `attrToBytes()` decide unidad por NOMBRE del atributo, incluyendo múltiplos embebidos (`_32MiB`, `_1GiB`, etc.) → cualquier disco cuyo preset de smartmontools SÍ matchee sale correcto solo.
  - `ataLifeUsed()` calcula % de vida por nombre del atributo (igual método que CDI: valor normalizado del atributo de desgaste).
  - `modelHostUnit` (tabla de override por modelo): solo 1 entrada → `ADATA[ _]SU[689]\d\d` = 32 MiB para 241/242 (la familia SU Silicon Motion; smartmontools tiene el dato pero su regex no cubre `SU800NS38`).
- Verificado real con discos de tuxor: Kingston SA400 (6.4/4.5 TiB, 97%), ADATA SU800NS38 (4.18/5.37 TiB, 100%).

## Qué falta (futuro)
Generalizar el "conocimiento por modelo" sin reinventar CDI. Opciones (de menor a mayor esfuerzo):
1. **Ampliar `modelHostUnit`** a mano conforme aparezcan discos que reporten mal (rápido, puntual).
2. **Bundlear un `drivedb-add.h`** propio y llamar `smartctl -B <archivo>` → smartctl aplica presets a modelos que su regex base no cubre (ej. agregar `SU800NS38`). Self-contained, reutiliza el formato oficial.
3. **`update-smart-drivedb`** en el instalador/servicio para traer el drivedb más reciente (puede que ya cubra variantes nuevas). En Windows habría que distribuir el drivedb junto al backend.

## Por qué NO se usa la DB de CrystalDiskInfo
- CDI es open source (BSD modificada) pero su lógica por modelo está **hardcodeada en C++** (`AtaSmart.cpp`): detecta fabricante por el string del modelo y elige atributo/unidad. **No hay archivo de DB** que copiar.
- La DB curada equivalente y reutilizable es **`drivedb.h` de smartmontools** (ya en el sistema). Es la fuente correcta a aprovechar (opciones 2 y 3).

**Ver también:** [[modulo-disco-smart]] [[proyecto-rewrite-go-flutter]]
