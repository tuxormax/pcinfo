---
name: proyecto-contexto
description: Que es LinuxHWMonitor y su stack
metadata:
  type: project
---

`/home/tuxor/www/LinuxHWMonitor` — monitor de hardware para Linux de tuxor, inspirado en CrystalDiskInfo + HWiNFO64. Repo `tuxormax/LinuxHWMonitor`.

**Stack:** Python 3.8+ con **PyQt5**. GPL v3. Fuente principal: `src/linux_hwmonitor.py` (~2040 líneas). Empaquetado: `.deb` (deb-build/) y flatpak (flatpak/, build-flatpak.sh).

**2 pestañas:** "🖥 Sistema & Hardware" y "💾 Disco (S.M.A.R.T.)".

**Qué muestra:** SMART (salud, vida útil %, atributos SATA/NVMe, temp, horas, escrituras, espacio libre/usado), CPU (modelo, núcleos/hilos, caché L1/L2/L3, microcode, freq, virtualización), GPU (nombre, driver, VRAM, OpenGL/Vulkan; NVIDIA/AMD/Intel), Tarjeta Madre (fabricante, chipset, BIOS UEFI/Legacy, SATA, PCIe), RAM (por módulo: velocidad, fabricante, part number, voltaje, canal), Sistema (kernel, distro, hostname, arch, uptime).

**Colectores** (todos `subprocess` a herramientas Linux + `/sys` `/proc`): `get_disks`, `get_smart_data`, `get_disk_usage`, `get_cpu_info`, `get_gpu_info`, `get_motherboard_info`, `get_ram_info`. Usan `lsblk`, `smartctl`, `dmidecode`, `lspci`, `nvidia-smi`, `glxinfo`, `vulkaninfo`, `free`, `uptime`.

**Aviso licencia (GPL v3):** los créditos del autor (tuxor) deben mantenerse visibles en código e interfaz en cualquier fork/derivado.

Pendiente principal: portar a Windows -> [[mejora-port-windows]].

**Ver también:** [[mejora-port-windows]]
