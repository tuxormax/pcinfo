# PCInfo

[![Licencia: GPL v3](https://img.shields.io/badge/Licencia-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Autor](https://img.shields.io/badge/autor-tuxor-orange.svg)](mailto:tuxor.max@gmail.com)

App de **inventario de hardware** multiplataforma (**Linux** y **Windows**): CPU, tarjeta madre, RAM, GPU, almacenamiento y sistema operativo. Sin temperaturas — solo información del equipo.

Incluye además la pestaña **Historial de Errores**: lee lo que registró el sistema operativo (pantallazos azules y registro de eventos en Windows; journald y mensajes del kernel en Linux) y lo explica en español — qué pasó, qué lo provocó (incluido el **driver culpable** deducido del volcado de memoria en los BSOD) y cómo resolverlo.

> **En desarrollo.** Reescritura completa del antiguo *LinuxHWMonitor* (Python + PyQt5) a una arquitectura **Go + Flutter**.

## Capturas

![PCInfo — vista general](capturas/pcinfo-general.png)

*Sistema operativo, procesador, tarjeta madre, RAM (ranuras ocupadas y libres) y tarjeta gráfica.*

![PCInfo — almacenamiento](capturas/pcinfo-almacenamiento.png)

*Almacenamiento con estado de salud S.M.A.R.T., uso del disco, vida restante en SSD, horas encendido y sectores reasignados.*

## Descargar e instalar

Los instaladores **no se guardan en el repositorio** (son binarios pesados). Se publican en la sección **[Releases](https://github.com/tuxormax/pcinfo/releases)** — entra ahí, abre la versión más reciente y descarga el archivo de tu sistema:

| Sistema | Archivo | Instalación |
|---|---|---|
| Linux (Debian/Ubuntu) | `pcinfo_v<version>_rev-<rev>.deb` | `sudo apt install ./pcinfo_v1.1_rev-25.deb` |
| Windows 10 u 11 (64 bits) | `pcinfo_v<version>_rev-<rev>.exe` | Doble clic y seguir el asistente |

Notas:

- En Windows el requisito mínimo es **Windows 10**; Windows 7 y 8 no son compatibles.
- La lectura de salud S.M.A.R.T. de los discos pide permisos de administrador/root; el resto del inventario funciona sin ellos.
- ¿Prefieres compilarlo tú mismo? Ver **[construir/LEEME.md](construir/LEEME.md)**.

## Arquitectura

- **`pcinfo/`** — interfaz gráfica en **Flutter** (desktop Linux/Windows), con dos pestañas: *Hardware* e *Historial de Errores*.
- **`backend/`** — recolector en **Go** que expone por HTTP local (JSON) el inventario (`GET /hardware`) y el historial de errores (`GET /errores`), usando `ghw` (inventario), `smartctl` (salud S.M.A.R.T. de discos), `nvidia-smi` (GPU), el registro de eventos de Windows y journald en Linux.

La GUI consume el JSON del backend; la misma base de código sirve para Linux y Windows.

## Requisitos de desarrollo

- Flutter 3.35+ con desktop habilitado (`flutter config --enable-linux-desktop`).
- Go 1.26+ (para el backend).

## Ejecutar la GUI

```bash
cd pcinfo
flutter run -d linux
```

## Autor

**Creado por:** tuxor · tuxor.max@gmail.com

> Si usas, modificas o distribuyes este software, los créditos del autor original deben mantenerse visibles tanto en el código fuente como en la interfaz del programa. Lo exige la licencia GPL v3.

## Licencia

GNU General Public License v3.0 — ver [LICENSE](LICENSE).
