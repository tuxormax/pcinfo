# LinuxHWMonitor

<div align="center">

**Monitor de hardware para Linux inspirado en CrystalDiskInfo + HWiNFO64**

[![Licencia: GPL v3](https://img.shields.io/badge/Licencia-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Python 3.8+](https://img.shields.io/badge/python-3.8+-yellow.svg)](https://www.python.org/)
[![PyQt5](https://img.shields.io/badge/GUI-PyQt5-green.svg)](https://riverbankcomputing.com/software/pyqt/)
[![Plataforma](https://img.shields.io/badge/plataforma-Linux-lightgrey?logo=linux)](https://kernel.org/)
[![Autor](https://img.shields.io/badge/autor-tuxor-orange.svg)](mailto:tuxor.max@gmail.com)

</div>
VISTA DE SISTEMA

![sistema1](https://github.com/tuxormax/LinuxHWMonitor/raw/main/docs/sistema-cpu-gpu.png)

![sistema2](https://github.com/tuxormax/LinuxHWMonitor/raw/main/docs/sistema-tarjetamadre.png)

![sistema3](https://github.com/tuxormax/LinuxHWMonitor/raw/main/docs/sistema-ram-so.png)

VISTA DE DISCOS
![hdd](https://github.com/tuxormax/LinuxHWMonitor/raw/main/docs/discos-hdd.png)

![ssd](https://github.com/tuxormax/LinuxHWMonitor/raw/main/docs/discos-ssd.png)

---

## Autor

**Creado por:** tuxor  
**Contacto:** tuxor.max@gmail.com  
**Versión:** 1.1  
**Fecha de creación:** 27 de febrero de 2026  

> ⚠️ **Aviso importante para modificaciones y distribuciones:**  
> Si usas, modificas o distribuyes este software, los créditos del autor original deben mantenerse visibles tanto en el código fuente como en la interfaz del programa (barra de estado, sección "Acerca de", o cualquier lugar equivalente). Esto aplica a cualquier versión derivada o fork. La licencia GPL v3 lo exige.

---

## Qué hace

| Módulo | Información mostrada |
|--------|----------------------|
| 💾 **S.M.A.R.T.** | Salud del disco, vida útil %, tabla completa de atributos SATA y NVMe, temperatura, horas de encendido, total de escrituras, **espacio libre y usado** |
| 🖥 **CPU** | Modelo, núcleos, hilos, caché L1/L2/L3, microcode, frecuencia, instrucciones, virtualización |
| 🎮 **GPU** | Nombre, driver, VRAM, versión OpenGL/Vulkan — NVIDIA, AMD e Intel |
| 🔧 **Tarjeta Madre** | Fabricante, modelo, chipset, tipo de BIOS (UEFI/Legacy), puertos SATA, slots PCIe |
| 💾 **RAM** | Detalles por módulo: velocidad, fabricante, part number, voltaje, modo de canal |
| 🐧 **Sistema** | Kernel, distribución, hostname, arquitectura, uptime |

---

## Instalación

### Opción 1 — Instalador automático (recomendada)

```bash
git clone https://github.com/TU_USUARIO/linuxhwmonitor.git
cd linuxhwmonitor
chmod +x install.sh
./install.sh
```

El instalador instala las dependencias, copia los archivos y crea el acceso directo en el **menú de aplicaciones** del escritorio (GNOME, KDE, XFCE…).

### Opción 2 — Ejecutar directamente

```bash
git clone https://github.com/TU_USUARIO/linuxhwmonitor.git
cd linuxhwmonitor

# Instalar dependencias (Ubuntu/Debian)
sudo apt install python3-pyqt5 smartmontools
pip3 install --user psutil

# Ejecutar
python3 src/linux_hwmonitor.py

# Con datos S.M.A.R.T. completos (recomendado):
sudo python3 src/linux_hwmonitor.py
```

### Opción 3 — Flatpak

```bash
# Instalar herramientas necesarias
sudo apt install flatpak flatpak-builder

# Agregar Flathub
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Instalar el SDK de compilación
flatpak install flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08

# Compilar e instalar (tarda varios minutos la primera vez)
chmod +x build-flatpak.sh
./build-flatpak.sh

# Ejecutar
flatpak run org.linuxhwmonitor.App
```

---

## Dependencias

| Paquete | Función | Obligatorio |
|---------|---------|-------------|
| Python 3.8+ | Motor de la app | ✅ |
| PyQt5 | Interfaz gráfica | ✅ |
| psutil | CPU y memoria | ✅ |
| smartmontools | Datos S.M.A.R.T. | ✅ |
| lm-sensors | Temperaturas | Opcional |
| pciutils | Detección GPU/PCIe | Recomendado |
| dmidecode | Tarjeta madre y RAM | Recomendado (sudo) |

### Por distribución

**Ubuntu / Debian / Linux Mint:**
```bash
sudo apt update
sudo apt install python3-pyqt5 smartmontools lm-sensors pciutils dmidecode
pip3 install --user psutil
sudo sensors-detect --auto
```

**Fedora / RHEL:**
```bash
sudo dnf install python3-qt5 smartmontools lm_sensors pciutils dmidecode
pip3 install --user psutil
```

**Arch Linux / Manjaro:**
```bash
sudo pacman -S python-pyqt5 smartmontools lm_sensors pciutils dmidecode
pip3 install --user psutil
```

**openSUSE:**
```bash
sudo zypper install python3-qt5 smartmontools sensors pciutils dmidecode
pip3 install --user psutil
```

---

## Permisos y sudo

| Función | Sin sudo | Con sudo |
|---------|:--------:|:--------:|
| Lista de discos | ✅ | ✅ |
| Temperatura del disco | ✅ | ✅ |
| Espacio libre / usado | ✅ | ✅ |
| Vida útil del disco (%) | ✅ | ✅ |
| Atributos S.M.A.R.T. básicos | ✅ | ✅ |
| Atributos S.M.A.R.T. completos | ⚠ Parcial | ✅ Completo |
| Detalles de tarjeta madre | ⚠ Básico | ✅ Completo |
| Información por módulo de RAM | ❌ | ✅ |

```bash
# Modo básico
linuxhwmonitor

# Modo completo (recomendado)
sudo linuxhwmonitor
```

---

## Desinstalar

```bash
chmod +x uninstall.sh
./uninstall.sh
```

---

## Estructura del repositorio

```
linuxhwmonitor/
├── src/
│   └── linux_hwmonitor.py              ← Aplicación principal
├── flatpak/
│   └── org.linuxhwmonitor.App.json     ← Manifest Flatpak
├── data/
│   ├── org.linuxhwmonitor.App.desktop
│   ├── icons/org.linuxhwmonitor.App.svg
│   └── metainfo/...metainfo.xml
├── docs/
│   └── preview.html                    ← Vista previa interactiva
├── .github/workflows/ci.yml            ← CI automático
├── install.sh      ← Instalador ⭐
├── uninstall.sh    ← Desinstalador
├── build-flatpak.sh
├── README.md
├── LICENSE
└── .gitignore
```

---

## Subir a GitHub

```bash
cd linuxhwmonitor
git init
git add .
git commit -m "feat: versión inicial v1.0.0"
git remote add origin https://github.com/TU_USUARIO/linuxhwmonitor.git
git branch -M main
git push -u origin main

# Crear release
git tag v1.0.0
git push origin v1.0.0
```

---

## Solución de problemas

**La app no aparece en el menú de aplicaciones:**
```bash
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache ~/.local/share/icons/hicolor
```

**No se detectan temperaturas:**
```bash
sudo sensors-detect --auto
sensors   # verificar que funciona
```

**S.M.A.R.T. no muestra atributos:**
```bash
sudo smartctl -a /dev/sda   # probar directamente
sudo apt install smartmontools   # si no está instalado
```

**Error "No module named PyQt5":**
```bash
sudo apt install python3-pyqt5   # Ubuntu/Debian
# o:
pip3 install --user PyQt5
```

**Los discos USB no aparecen:**

Los discos USB solo aparecen si soportan S.M.A.R.T. via USB:
```bash
sudo smartctl -a /dev/sdb --device=sat
```

---

## Contribuir

1. Haz un fork del repositorio
2. Crea una rama: `git checkout -b feature/nueva-funcion`
3. Commit de cambios: `git commit -m 'Agrega nueva función'`
4. Sube la rama: `git push origin feature/nueva-funcion`
5. Abre un Pull Request

> **Al contribuir, los créditos del autor original (tuxor / tuxor.max@gmail.com) deben mantenerse en el código y en la interfaz del programa.**

---

## Licencia

GNU General Public License v3.0 — ver archivo [LICENSE](LICENSE).

---

## Créditos

**Desarrollado por:** tuxor  
**Contacto:** tuxor.max@gmail.com  
**Año:** 2026  

Inspirado en [CrystalDiskInfo](https://crystalmark.info/en/software/crystaldiskinfo/) de Noriyuki Miyazaki y [HWiNFO](https://www.hwinfo.com/) de REALiX.

> Los créditos deben mantenerse visibles en cualquier versión modificada o redistribuida de este software, como lo requiere la licencia GPL v3.
