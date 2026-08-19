# PCInfo

[![Licencia: GPL v3](https://img.shields.io/badge/Licencia-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Autor](https://img.shields.io/badge/autor-tuxor-orange.svg)](mailto:tuxor.max@gmail.com)

App de **inventario de hardware** multiplataforma (**Linux** y **Windows**): CPU, tarjeta madre, RAM, GPU, almacenamiento y sistema operativo. Sin temperaturas — solo información del equipo.

Incluye además la pestaña **Historial de Errores**: lee lo que registró el sistema operativo (pantallazos azules y registro de eventos en Windows; journald y mensajes del kernel en Linux) y lo explica en español — qué pasó, qué lo provocó (incluido el **driver culpable** deducido del volcado de memoria en los BSOD) y cómo resolverlo.

Y dos pestañas más:

- **Software** — todos los programas instalados con su versión, separando **lo que instaló el usuario** de **lo que vino con el sistema**. Se exporta a **Markdown** (`.md`) ya agrupado, listo para pegar en un informe o un ticket.
- **Controladores** *(solo Windows)* — **respaldar y restaurar** los controladores de terceros del equipo y las **redes WiFi guardadas** (con sus contraseñas). Pensado para formatear un equipo sin perder ni los drivers ni las claves del WiFi.

> **En desarrollo.** Reescritura completa del antiguo *LinuxHWMonitor* (Python + PyQt5) a una arquitectura **Go + Flutter**.

## Capturas

![PCInfo — vista general](capturas/pcinfo-general.png)

*Sistema operativo, procesador, tarjeta madre, RAM (ranuras ocupadas y libres) y tarjeta gráfica.*

![PCInfo — almacenamiento](capturas/pcinfo-almacenamiento.png)

*Almacenamiento con estado de salud S.M.A.R.T., uso del disco, vida restante en SSD, horas encendido y sectores reasignados.*

## Descargar e instalar

Los instaladores **no se guardan en el repositorio** (son binarios pesados). Se publican en la sección **[Releases](https://github.com/tuxormax/pcinfo/releases)**, un release por revisión y sin borrar los anteriores — entra ahí, abre la versión más reciente y descarga el archivo de tu sistema:

| Sistema | Archivo | Instalación |
|---|---|---|
| Linux (Debian/Ubuntu) | `pcinfo_v<version>_rev-<rev>.deb` | `sudo apt install ./pcinfo_v1.1_rev-25.deb` |
| Windows 10 u 11 (64 bits) | `pcinfo_v<version>_rev-<rev>.exe` | Doble clic y seguir el asistente |
| Windows — versión portable | `pcinfo_v<version>_rev-<rev>_portable.zip` | Descomprimir y abrir `pcinfo.exe` (no instala nada) |

Notas:

- En Windows el requisito mínimo es **Windows 10**; Windows 7 y 8 no son compatibles.
- La lectura de salud S.M.A.R.T. de los discos pide permisos de administrador/root; el resto del inventario funciona sin ellos.
- La pestaña **Controladores** necesita administrador entera (respaldar y restaurar escriben en el sistema). Si PCInfo no lo tiene, la propia pestaña ofrece el botón *Reintentar como administrador*.
- ¿Prefieres compilarlo tú mismo? Ver **[construir/LEEME.md](construir/LEEME.md)**.

## Diagnosticar un equipo que ya no arranca

La versión **portable** cabe en una memoria USB y sirve para revisar un equipo que no entra a Windows:

1. Arranca el equipo con un medio de rescate en modo live (**Hiren's BootCD PE** o cualquier WinPE).
2. Abre `pcinfo.exe` desde la USB.
3. En la pestaña **Historial de Errores**, el selector *«Analizando el Windows de:»* lista las instalaciones encontradas en los discos. Elige la del Windows averiado — normalmente `C:` o `D:`, no la unidad del medio de rescate.

PCInfo lee entonces **sus** registros de eventos y **sus** volcados de pantallazo azul aunque ese Windows no pueda arrancar, deduce el driver culpable a partir del volcado y explica qué pasó y cómo resolverlo. Al analizar una instalación apagada se revisan los últimos **180 días** en lugar de 30, porque un equipo averiado suele llevar semanas sin usarse. Con **Guardar** queda un `.txt` con todo el diagnóstico.

La pestaña *Hardware* sigue funcionando en ese escenario y muestra el hardware real del equipo (el sistema operativo que reporta es el del medio de rescate).

## Respaldar y restaurar controladores y redes WiFi (Windows)

Antes de formatear un equipo, la pestaña **Controladores** guarda lo que Windows no vuelve a poner solo:

1. **Respaldar controladores** — copia los controladores de terceros instalados (`Export-WindowsDriver`) a la carpeta que elijas, en una subcarpeta `Controladores`. Puede tardar varios minutos; el avance se ve línea a línea.
2. **Respaldar redes WiFi** — exporta los perfiles inalámbricos con **sus contraseñas** a la subcarpeta `RedesWiFi`.
3. Tras reinstalar Windows, **Restaurar controladores** los instala uno a uno (`pnputil`) y **Restaurar redes WiFi** vuelve a dejar el equipo conectándose solo a las redes conocidas.

> ⚠️ Los archivos `.xml` del respaldo de WiFi contienen las contraseñas **en texto legible**: es lo único que permite restaurarlas en otro equipo sin teclearlas. Guarda esa carpeta donde corresponda.

La carpeta se elige **siempre a mano** (lo normal es que el respaldo vaya a una USB) y restaurar pide confirmación explícita diciendo qué va a pasar. En Linux la pestaña avisa de que no aplica: ahí los controladores vienen en el kernel y los gestiona la distribución.

## Arquitectura

- **`pcinfo/`** — interfaz gráfica en **Flutter** (desktop Linux/Windows), con cuatro pestañas: *Hardware*, *Historial de Errores*, *Software* y *Controladores*.
- **`backend/`** — recolector en **Go** que expone por HTTP local (JSON) el inventario (`GET /hardware`), el historial de errores (`GET /errores`, con `?raiz=D:\Windows` para analizar otra instalación), el software instalado (`GET /software`) y los controladores y redes WiFi (`GET /controladores`, más `POST /controladores/{respaldar,restaurar}` y `GET /controladores/tarea` para seguir el avance). Usa `ghw` (inventario), `smartctl` (salud S.M.A.R.T. de discos), `nvidia-smi` (GPU), el registro de Windows y `Get-AppxPackage` (software), `Export-WindowsDriver`/`pnputil`/`netsh wlan` (controladores y redes), el registro de eventos de Windows y journald/dpkg/rpm en Linux.

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
