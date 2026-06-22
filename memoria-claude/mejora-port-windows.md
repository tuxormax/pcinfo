---
name: mejora-port-windows
description: Plan para portar LinuxHWMonitor a Windows (mantener Python+PyQt5, reescribir solo la capa de colectores)
metadata:
  type: project
---

# Plan: port de LinuxHWMonitor a Windows

Análisis hecho 2026-06-06 sobre `src/linux_hwmonitor.py` (Python 3.8+, PyQt5, GPL v3, ~2040 líneas, 2 pestañas: "Sistema & Hardware" y "Disco S.M.A.R.T.").

## Decisión clave: NO cambiar de lenguaje
Quedarse en **Python + PyQt5**. PyQt5 corre nativo en Windows, así que TODA la UI se porta gratis (`PartitionBarWidget`, `HealthBadge`, `TempWidget`, `DiskButton`, `DiskInfoPanel`, `SystemInfoPanel`, `MainWindow`, los `QTimer`). Reescribir en C# sería tirar código que ya funciona.

**Lo único a reescribir = la capa de colectores** (`get_*`), porque todas hacen `subprocess` a herramientas Linux o leen `/sys` y `/proc`.

## El truco que ahorra mucho
- **`smartctl` existe en Windows** (smartmontools build Win) → la pestaña SMART (`get_smart_data`, la más compleja) se reusa casi tal cual: bundlear `smartctl.exe` y el parser sigue.
- **`nvidia-smi` viene con el driver NVIDIA en Windows** → reusar parte GPU NVIDIA y su temperatura.

## Mapeo colector Linux -> Windows
| Colector (línea aprox) | Linux actual | Reemplazo Windows |
|---|---|---|
| `get_disks` / `get_disk_usage` (329/519) | `lsblk`, `free` | `psutil` + WMI `Win32_DiskDrive` |
| `get_smart_data` (352) | `smartctl` | **`smartctl.exe`** (mismo parser) |
| `get_cpu_info` (628) | `/proc/cpuinfo`, cache en `/sys` | `py-cpuinfo` + WMI `Win32_Processor`/`Win32_CacheMemory` |
| `get_gpu_info` (723) | `lspci`,`nvidia-smi`,`glxinfo`,`vulkaninfo` | WMI `Win32_VideoController` + `nvidia-smi` + `vulkaninfo.exe` |
| `get_motherboard_info` (831) | `dmidecode`, `/sys/class/dmi/id`, `/sys/firmware/efi` | WMI `Win32_BaseBoard`,`Win32_BIOS`; UEFI/Legacy por firmware |
| `get_ram_info` (898) | `dmidecode` | WMI `Win32_PhysicalMemory` (velocidad, fabricante, part number, voltaje, canal) |
| uptime/SO (1537+) | `uptime`, `/proc/uptime`, `free` | `psutil.boot_time()` + `platform` + WMI `Win32_OperatingSystem` |

Librerías Windows: **`pywin32`/`wmi`**, **`psutil`**, **`py-cpuinfo`**.

## Punto débil: temperaturas/voltajes/ventiladores
WMI no da temps reales de CPU fiables. Para CPU temp + voltajes + RPM ventiladores hay que integrar **LibreHardwareMonitor** (namespace WMI `root\LibreHardwareMonitor`, o cargar su DLL con `pythonnet`). Trae driver kernel firmado. GPU NVIDIA temp sale de `nvidia-smi`. (LibreHardwareMonitor = MPL 2.0.)

## Estructura propuesta
1. Abstracción `backends/`: `linux.py` (lo actual) + `windows.py`, seleccionado por `sys.platform`. La UI no se entera (mismo contrato de retorno por colector).
2. Empaquetar con **PyInstaller** -> `.exe` (en vez del `.deb`/flatpak actual). Bundlear `smartctl.exe`.
3. La app **necesita admin** (SMART de algunos discos + driver de LibreHardwareMonitor) -> manifiesto UAC `requireAdministrator`.

## Esfuerzo realista
UI 0% · SMART ~10% (bundlear binario) · reescribir CPU/GPU/mobo/RAM con WMI · lo más laborioso = temperaturas (LibreHardwareMonitor).

## Siguiente paso al retomar
Elegir: (a) scaffolding del backend Windows (`backends/` + `windows.py` con WMI/psutil devolviendo CPU/RAM/mobo/discos), o (b) plan archivo-por-archivo para separar `linux_hwmonitor.py` sin romper la versión Linux.

**Ver también:** [[proyecto-contexto]]
