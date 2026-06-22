---
name: proyecto-contexto
description: App original PyQt5 (ELIMINADA) — se conserva como referencia de qué datos/herramientas recolectaba, para el backend Go.
metadata:
  type: reference
---

> ⚠️ **HISTÓRICO / REFERENCIA.** Esta es la app **original Python+PyQt5, ya ELIMINADA** del repo (ver [[proyecto-rewrite-go-flutter]]). Se conserva porque la lista de **qué muestra** y **qué colectores/herramientas** usa es la mejor spec para construir el backend Go.

`/home/tuxor/www/pcinfo` — monitor de hardware para Linux de tuxor, inspirado en CrystalDiskInfo + HWiNFO64. Repo `tuxormax/pcinfo`.

**Stack (eliminado):** era Python 3.8+ con **PyQt5**, GPL v3, en `src/linux_hwmonitor.py` (~2040 líneas).

**2 pestañas:** "🖥 Sistema & Hardware" y "💾 Disco (S.M.A.R.T.)".

**Qué muestra:** SMART (salud, vida útil %, atributos SATA/NVMe, temp, horas, escrituras, espacio libre/usado), CPU (modelo, núcleos/hilos, caché L1/L2/L3, microcode, freq, virtualización), GPU (nombre, driver, VRAM, OpenGL/Vulkan; NVIDIA/AMD/Intel), Tarjeta Madre (fabricante, chipset, BIOS UEFI/Legacy, SATA, PCIe), RAM (por módulo: velocidad, fabricante, part number, voltaje, canal), Sistema (kernel, distro, hostname, arch, uptime).

**Colectores** (todos `subprocess` a herramientas Linux + `/sys` `/proc`): `get_disks`, `get_smart_data`, `get_disk_usage`, `get_cpu_info`, `get_gpu_info`, `get_motherboard_info`, `get_ram_info`. Usan `lsblk`, `smartctl`, `dmidecode`, `lspci`, `nvidia-smi`, `glxinfo`, `vulkaninfo`, `free`, `uptime`.

**Aviso licencia (GPL v3):** los créditos del autor (tuxor) deben mantenerse visibles en código e interfaz en cualquier fork/derivado.

**Ver también:** [[proyecto-rewrite-go-flutter]] [[modulo-gui-pcinfo]] [[modulo-disco-smart]]
