---
name: modulo-gui-pcinfo
description: "Estructura y decisiones de diseño de la GUI Flutter (PCInfo) — fichas, modelo de datos, contrato con backend Go."
metadata: 
  node_type: memory
  type: project
  originSessionId: c7e329be-3c86-4fa8-a8c9-4ff222658fdf
---

# GUI Flutter — PCInfo

App de inventario de hardware. Carpeta `pcinfo/` (paquete Flutter `pcinfo`). Hoy con datos **mock** ([[proyecto-rewrite-go-flutter]]).

## Estructura
- `lib/models/hardware.dart` — modelos **espejo del JSON del backend Go** (HardwareInfo → SystemInfo, CpuInfo, BoardInfo, MemoryInfo+MemModule, GpuInfo+GpuCard, DiskInfo). Cambiar aquí = cambiar el contrato.
- `lib/services/hardware_service.dart` — `HardwareService` abstracto + `MockHardwareService`. Al tener backend: crear `HttpHardwareService` (GET localhost) **sin tocar la UI**.
- `lib/ui/dashboard_page.dart` — dashboard, fichas, masonry.
- `lib/ui/widgets/spec_card.dart` — `SpecCard` (header categoría + filas `SpecRow` etiqueta/valor).
- `lib/theme.dart` — colores (acento por categoría) + `kFont`. `lib/utils/format.dart` — formatBytes, formatMhz, cleanVendor.
- `lib/version.dart` — único lugar de versión: appName/appVersion/appRevision/autor/copyright/licencia. Footer fijo abajo (`_footer()` en dashboard) muestra "PCInfo vX.Y Rev N · © 2026 tuxor · email · GPL v3" (los créditos visibles los exige la licencia).

## Diseño acordado con el usuario
- Encabezado de cada ficha = **solo la categoría** ("Procesador (CPU)", etc.); fabricante/modelo van como filas dentro.
- Fuente **Ubuntu** empaquetada, **un solo tamaño** kFont=14 (jerarquía por peso/color, no tamaño).
- Fichas en **MasonryGridView** (2 col, paquete flutter_staggered_grid_view) — se rebalancea solo, sin huecos. 1 col si ancho ≤720.
- Ventana mínima **760×560** (linux/runner/my_application.cc, geometry hints).
- Etiqueta de SpecRow ancho **155** (para que "Frecuencia máxima" quepa en 1 línea).

## Qué muestra cada ficha
- **Sistema operativo**: Sistema, Nombre equipo, Kernel, Arquitectura, Escritorio. (SIN tiempo encendido — el usuario no lo quiere.)
- **CPU**: Fabricante, Modelo, Núcleos, Hilos, Frecuencia base, Frecuencia máxima. (SIN flags/instrucciones — el usuario los quitó.)
- **Tarjeta madre**: Fabricante, Modelo, Tamaño (ATX…), Versión, BIOS, Fecha BIOS. (SIN chasis.)
- **RAM**: Total, Montaje (soldada/ranuras), Ranuras ocupadas/libres, Capacidad máx + lista de ranuras (ocupadas y vacías).
- **GPU**: Fabricante, Modelo, VRAM, Driver.
- **Almacenamiento** (ancho completo): por disco — modelo, tipo (badge), salud SMART (badge SALUDABLE/ADVERTENCIA/FALLA/SIN SMART), tamaño, device/serie/bus, y métricas (escrituras/lecturas totales, vida restante, horas, ciclos, sectores reasignados).

## Datos difíciles en Windows (backend deberá manejar, mostrar "—"/"Desconocido")
- Frecuencia máxima/turbo del CPU (WMI solo da base).
- Tamaño de placa ATX (no existe en SMBIOS ni WMI — deducir del modelo).
- VRAM real de GPU (WMI AdapterRAM topado a 4GB — usar registro/DXGI).
- RAM soldada (deducir del form factor "Row Of Chips").

**Ver también:** [[proyecto-rewrite-go-flutter]] [[modulo-disco-smart]]
