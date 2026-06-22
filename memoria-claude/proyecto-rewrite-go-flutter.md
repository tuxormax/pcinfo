---
name: proyecto-rewrite-go-flutter
description: Decisión y estado del rewrite de LinuxHWMonitor a Go + Flutter (cross-platform Linux/Windows).
metadata: 
  node_type: memory
  type: project
  originSessionId: c7e329be-3c86-4fa8-a8c9-4ff222658fdf
---

# Rewrite a Go + Flutter (decidido 2026-06-22)

El usuario decidió **reescribir** LinuxHWMonitor (antes Python+PyQt5) en **Go + Flutter**, cross-platform Linux **y** Windows. La versión PyQt5 actual "no le sirve mucho". Esto **reemplaza** el plan de [[mejora-port-windows]] (que era mantener PyQt5 y solo reescribir colectores).

## Por qué Go+Flutter (no Rust, no PyQt5)
- **Flutter** = UI (desktop estable). **Go** = colectores. Puente: **servidor HTTP local** (Go expone `/hardware` JSON, Flutter consume) — más simple que FFI para inventario estático.
- Go elegido sobre Rust porque **`jaypipes/ghw`** da inventario CPU/RAM/madre/GPU/discos con la MISMA API en Linux (lee /sys,/proc,dmidecode) y Windows (WMI). En Rust el puente (flutter_rust_bridge) es mejor pero no hay equivalente tan completo a ghw.
- Objetivo: **solo inventario de hardware, SIN temperaturas** → no se necesita LibreHardwareMonitor/.NET (eso era lo difícil en Windows).

## Estado actual
- **GUI primero** (fase actual), con datos **mock**. Backend Go **aún no existe** (siguiente fase).
- **App Python+PyQt5 legacy ELIMINADA** (2026-06-22): se borraron `src/`, `deb-build/`, `data/`, `flatpak/`, `docs/`, `install.sh`, `uninstall.sh`, `build-flatpak.sh`, `.deb`, CI Python. El repo solo contiene ahora `pcinfo/` (Flutter) + `memoria-claude/` + LICENSE + README.
- **Repo/carpeta renombrados a `pcinfo`**: GitHub `tuxormax/pcinfo` (remote SSH), carpeta local `/home/tuxor/www/pcinfo`. ⚠️ El nuevo key de sesión Claude es `-home-tuxor-www-pcinfo` (symlink memory→memoria-claude ya creado para ambos keys).
- Proyecto Flutter en `pcinfo/` (paquete `pcinfo`). Binario Go irá en `backend/` (pendiente).
- App **v1.0 Rev 1** (versionado nuevo del rewrite; el PyQt5 iba en v1.2 Rev 2). Footer con autor/copyright/versión visible (lo exige la licencia GPL).
- Go instalado en `~/go-sdk/go` (v1.26.4, sin sudo, PATH en .bashrc). Flutter 3.35.6, Linux desktop habilitado.

## Decisiones de la GUI (ver detalle en [[modulo-gui-pcinfo]])
- Nombre de la app: **PCInfo** (antes "HWMonitor"/hwmonitor).
- Fuente **Ubuntu** empaquetada (Regular+Bold en pcinfo/fonts/), **todo a un solo tamaño** (`kFont=14`), sin monoespaciada.
- Dashboard con fichas: Sistema operativo, CPU, Tarjeta madre, RAM, GPU, Almacenamiento.

## Pendiente — BACKEND GO (próxima fase, arranca aquí)
- Crear `backend/` (módulo Go). Servidor HTTP local (ej. `127.0.0.1:PORT`) con endpoint **`GET /hardware`** que devuelve el JSON **exactamente con la forma de `pcinfo/lib/models/hardware.dart`**: `{system, cpu, board, memory, gpu, disks}` (campos y nombres = el contrato; ver [[modulo-gui-pcinfo]]).
- Fuentes: **`jaypipes/ghw`** (CPU, RAM+slots, madre/BIOS, GPU, discos) · **`smartctl --json`** (salud SMART, escrituras/lecturas, vida, sectores) · **`nvidia-smi`** (driver/VRAM NVIDIA). En Windows el equivalente lo resuelve ghw (WMI).
- Datos que ghw NO da y hay que resolver (mostrar ""/"Desconocido"): frecuencia máx CPU, tamaño placa ATX, VRAM real >4GB en Win, RAM soldada (form factor).
- Integrar en GUI: crear `HttpHardwareService implements HardwareService` (GET /hardware) y cambiar la línea en `main.dart` (`MockHardwareService()` → `HttpHardwareService()`). La UI NO se toca.
- Decidir cómo empaqueta Flutter el binario Go (lanzarlo como subproceso al iniciar la app, o servicio aparte).

**Ver también:** [[modulo-gui-pcinfo]] [[proyecto-contexto]] [[modulo-disco-smart]]
