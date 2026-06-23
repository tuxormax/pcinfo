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

## BACKEND GO — ✅ HECHO (2026-06-22)
- Módulo `backend/` (`pcinfo-backend`, Go 1.26, dep `jaypipes/ghw`). Servidor HTTP en **`127.0.0.1:51247`** (override `--addr` o env `PCINFO_ADDR`), endpoint **`GET /hardware`** + `/healthz`. JSON con la forma EXACTA de `hardware.dart` (tags json camelCase = contrato).
- Estructura: `main.go` (server) + `collector/` (types.go contrato, collect.go orquesta, system/cpu/board/memory/gpu/disk/smart .go). Cada colector degrada con elegancia (`warn()`), nunca aborta.
- Fuentes: **ghw** (CPU, board/BIOS, GPU, discos, totales RAM) · **dmidecode -t 16/17** (ranuras/módulos/maxCap/soldada) · **smartctl --json -a** (SMART por disco) · **nvidia-smi** (driver+VRAM NVIDIA, enriquece tarjetas ghw por índice).
- ⚠️ **Permisos**: sin root, `dmidecode` (módulos/ranuras RAM) y `smartctl` (SMART) fallan → la app muestra solo totales y `smartAvailable=false`. Para datos completos correr backend con sudo / `setcap`. Probado OK sin root: system/cpu/board/memory-totales/gpu/discos básicos salen bien.
- smartctl sale con código ≠0 aunque el JSON sea válido (flags) → parseamos stdout ignorando el exit code.
- **DB por modelo (Rev 5, 2026-06-23)**: `collector/drivedb-add.h` embebido (`go:embed`) → `smartctl -B +<temp>` aplica presets a modelos que su regex base no cubre (ej. ADATA `SU800NS38`). Detalle en [[mejora-smart-drivedb]]. `attrToBytes` resuelve la unidad sola por el nombre del atributo.
- **Integración GUI HECHA**: `HttpHardwareService` (en `services/hardware_service.dart`, usa `dart:io`, sin deps nuevas) con `fallback: MockHardwareService()`. `main.dart` ya lo usa → datos reales si el backend corre, mock si no. UI no se tocó (salvo numerar GPUs).
- **Gaps cerrados (Rev 5)**: `formFactor` ahora trae el tipo de CHASIS real (`ghw.Chassis().TypeDescription`, ej. "Desktop") en vez de "" — DMI no expone ATX de la placa, el chasis es lo más cercano. `baseMhz` tiene fallback VM/Windows: parsea "@ x.xGHz" del nombre del CPU (`mhzFromModel`, típico Intel) cuando no hay cpufreq. En Linux sigue saliendo de cpufreq sin tocar.
- **Subproceso backend HECHO (Rev 5)**: `pcinfo/lib/services/backend_launcher.dart` — `ensureRunning()` sondea `/healthz` y SOLO si nadie responde lanza el binario empaquetado (detached). Así no choca con el servicio root (que da mejores datos) ni duplica proceso en el puerto. `main()` lo await-ea antes de `runApp`; `stop()` mata solo el que lanzamos nosotros (lifecycle detached/dispose). Busca el binario junto al ejecutable y en `../backend/`.

## Multi-GPU (integrada + dedicada)
- Backend y GUI YA soportan N tarjetas (ghw devuelve todas; GUI itera `g.cards`, las numera "GPU 1/2" con etiqueta Integrada/Dedicada por heurística de vendor/modelo).
- En la PC de tuxor (Ryzen 5 5600G **con Radeon** + RTX 3060) el SO solo ve **una** GPU: la Radeon integrada está **deshabilitada en BIOS** al haber GPU dedicada (confirmado: `lspci` y `/sys/class/drm` solo listan la NVIDIA). No es bug; si se habilita el iGPU en BIOS o en laptops Optimus, aparecerán ambas.

## Cómo correr
- GUI (Linux): `cd /home/tuxor/www/pcinfo/pcinfo && flutter run -d linux`.
- Backend: `cd /home/tuxor/www/pcinfo/backend && go build -o pcinfo-backend . && ./pcinfo-backend` (o con `sudo` para RAM modules + SMART).

## Instaladores (v1.1 Rev 2, 2026-06-22) — carpeta `instaladores/`
- Binarios generados (`*.deb`, `*.exe`) NO se versionan (`.gitignore`); sí los scripts.
- **Linux `.deb`**: `bash instaladores/construir_linux.sh` → `pcinfo_v<ver>_rev-<rev>.deb` (~17MB), **mismo nombre base que el .exe de Windows** (regla de tuxor 2026-06-23: ambos instaladores se llaman igual). El script lee versión/revisión de `version.dart` (igual que el workflow Windows); la versión Debian interna del paquete es `<ver>.<rev>` (p.ej. 1.1.6). Instala GUI en `/opt/pcinfo/app` + lanzador `/usr/bin/pcinfo` + `.desktop`, y el backend como **servicio systemd `pcinfo-backend.service`** corriendo como **root** (así dmidecode+smartctl dan datos completos). Depends: smartmontools, dmidecode, libgtk-3-0.
- **Windows**: NO se puede compilar el bundle Flutter Windows desde Linux (necesita Visual Studio). Se construye en **GitHub Actions** → `.github/workflows/windows-installer.yml` (runner `windows-latest`). Patrón **replicado de SIGARN** (`/home/tuxor/www/sigarn/.github/workflows/build-pos.yml`), 3 reglas aprendidas:
  1. ⚠️ **`runs-on: windows-2022`** (NO `windows-latest`): el runner latest trae **Visual Studio 2026 (v18)** que Flutter stable aún no mapea a un generador CMake → cae al viejo `Visual Studio 16 2019` y falla (`CMake Error: Generator Visual Studio 16 2019 could not find any instance`). windows-2022 = VS 2022 v17, soportado. Diagnosticado con `flutter doctor -v` en CI (mostró "Visual Studio Enterprise 2026 18.7"). Además `subosito/flutter-action@v2` con `channel: stable` SIN `flutter-version` (no fijar).
  2. **ISCC ya viene** en windows-latest (`C:\Program Files (x86)\Inno Setup 6\ISCC.exe`), NO usar `choco install innosetup`.
  3. **Empaquetar VC++ Redistributable** (`aka.ms/vs/17/release/vc_redist.x64.exe`) dentro del `.iss` con install silencioso (regla global [[feedback-instalador-windows de SIGARN]]: la app no arranca sin VCRUNTIME140).
  4. ⚠️ **SOLO disparo manual `workflow_dispatch`** (como SIGARN) — NUNCA trigger `push`. El instalador no debe quedarse/publicarse solo en cada commit; se genera bajo demanda desde Actions → "Run workflow". Regla de tuxor (2026-06-23): "nunca se deja el instalador en github" → se quitó el trigger push y se borraron los releases auto-creados (rev2–5). La versión/revisión las lee el workflow de `version.dart` (paso "Resolver versión"), no de inputs hardcodeados.
  - Publicar como **GitHub Release** (no artifact; la cuota de artifacts se llena). Tag `win-v<ver>-rev<rev>`, asset `pcinfo_v<ver>_rev-<rev>.exe`. Requiere `permissions: contents: write`. (El usuario descarga el .exe y luego puede borrar el release; no se acumulan como en SIGARN.)
  - El backend Go SÍ cross-compila a `.exe` desde Linux (`GOOS=windows`), pero la GUI no. Inno script: `instaladores/instalador_windows.iss` (AppId fijo, instala en Program Files, backend autostart vía HKLM\...\Run, rutas/version por `/D`).
- Versión en `pcinfo/lib/version.dart` (appVersion/appRevision) + `pubspec.yaml` (actual **1.1.0+6**, v1.1 Rev 6). Único lugar de la versión.

**Ver también:** [[modulo-gui-pcinfo]] [[proyecto-contexto]] [[modulo-disco-smart]]
