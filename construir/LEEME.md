# Instaladores de PCInfo

Aquí viven los scripts que empaquetan PCInfo (GUI Flutter + backend Go). Los
binarios generados (`*.deb`, `*.exe`, `*.zip`) **nunca se versionan**: el repo no
tiene carpeta de instaladores. El único lugar de descarga es
**[Releases](https://github.com/tuxormax/pcinfo/releases)**, un release por
revisión (`v<ver>-rev<rev>`) con los tres archivos, y **los releases no se
borran** — quedan como histórico.

Al construir, cada script deja su binario en `instaladores/` (carpeta local,
ignorada por git) y lo sube al release de esa revisión.

## Linux (`.deb`)
Se construye localmente:

```bash
bash construir/construir_linux.sh                 # construye y publica en el release
bash construir/construir_linux.sh --sin-publicar  # solo construye
# → instaladores/pcinfo_v1.2_rev-31.deb  +  release v1.2-rev31
```

Publicar requiere `gh` autenticado; si falta, el script avisa e imprime el
`gh release upload` para hacerlo a mano.

### ⛔ Se compila dentro de un Ubuntu 22.04, no en el equipo

`construir_linux.sh` **no compila en el equipo de desarrollo**: lo hace dentro de
un Ubuntu 22.04 que arma `construir/entorno_jammy.sh` (rootfs oficial + `bwrap`,
**sin sudo ni Docker**; la primera vez baja ~30 MB + ~400 MB de paquetes y queda
cacheado en `~/.cache/pcinfo/jammy`).

El motivo: un binario compilado contra una librería **nueva** no arranca donde
está la **vieja**. Compilando en Mint 22.1 (GLib 2.80) el ejecutable pedía
`g_once_init_enter_pointer`, ausente en Mint 21.3 (GLib 2.72), y la app **moría
sin abrir ventana ni mostrar mensaje**. Compilando contra la base más vieja que
se soporta, el mismo `.deb` sirve para Mint 21.x **y** 22.x.

Antes de empaquetar, el script resuelve con `ldd -r` todos los símbolos contra
las librerías de esa base y **aborta sin generar el `.deb`** si falta alguno.

Requiere `flutter` (desktop Linux), `go`, `dpkg-deb` y `bwrap` (`bubblewrap`).
El paquete:
- instala la GUI en `/opt/pcinfo/app` + lanzador `/usr/bin/pcinfo` + entrada de menú;
- instala el backend en `/opt/pcinfo/backend` y lo registra como servicio
  systemd **`pcinfo-backend.service`** (corre como root → acceso a `dmidecode`
  y `smartctl` para RAM por ranura y S.M.A.R.T.);
- depende de `smartmontools`, `dmidecode` y de las versiones mínimas de GTK/GLib
  contra las que se compiló (`libgtk-3-0 (>= 3.24.33)`, `libglib2.0-0 (>= 2.72.4)`),
  para que un equipo demasiado viejo lo rechace con un mensaje claro en vez de
  instalar un programa que no abre.

Instalar / desinstalar:
```bash
sudo apt install ./instaladores/pcinfo_v1.2_rev-31.deb
sudo apt remove pcinfo
```

## Windows (`.exe`) — vía GitHub Actions
El bundle Flutter para Windows **no se puede compilar desde Linux** (requiere
Visual Studio). Se genera en CI (patrón replicado de SIGARN):

- Workflow: `.github/workflows/windows-installer.yml` (runner `windows-latest`).
- Pasos: compila backend Go (`.exe`) → `flutter build windows --release` →
  descarga el **VC++ Redistributable** (se empaqueta dentro del instalador, la
  app no arranca sin él) → Inno Setup (`instalador_windows.iss`, ISCC ya viene
  en el runner) → publica el instalador como **GitHub Release**.
- ⚠️ `subosito/flutter-action` se usa con `channel: stable` **sin fijar
  versión**: al fijarla, Flutter no detecta Visual Studio y CMake cae a su
  generador viejo ("Visual Studio 16 2019") → falla.
- Se publica como **Release** (no artifact): los release assets no consumen la
  cuota de almacenamiento de Actions. El release **no se borra** tras descargar;
  es la única fuente de descarga.
- Se dispara con push a `main` (cambios en `pcinfo/`, `backend/` o el `.iss`) o
  manual en **Actions → Run workflow** (inputs versión/revisión → nombre del
  `.exe`). Tag del release: `v<ver>-rev<rev>` — el mismo al que el script de
  Linux sube su `.deb`, para que una revisión tenga los tres archivos juntos.

### Compilar el instalador Windows a mano (en una máquina Windows)
Requiere Flutter + Visual Studio (Desktop C++) + Inno Setup 6:
```powershell
cd backend; go build -ldflags "-s -w" -o pcinfo-backend.exe .
cd ..\pcinfo; flutter build windows --release
cd ..
iscc /DSourceFlutter="pcinfo\build\windows\x64\runner\Release" `
     /DSourceBackend="backend\pcinfo-backend.exe" `
     construir\instalador_windows.iss
```
