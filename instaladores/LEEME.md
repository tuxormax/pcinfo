# Instaladores de PCInfo

Salida de empaquetado de PCInfo (GUI Flutter + backend Go). Los binarios
generados (`*.deb`, `*.exe`) **no se versionan** (ver `.gitignore`); aquí viven
los scripts que los producen.

## Linux (`.deb`)
Se construye localmente:

```bash
bash instaladores/construir_linux.sh
# → instaladores/pcinfo_1.1.0_amd64.deb
```

Requiere `flutter` (desktop Linux), `go` y `dpkg-deb`. El paquete:
- instala la GUI en `/opt/pcinfo/app` + lanzador `/usr/bin/pcinfo` + entrada de menú;
- instala el backend en `/opt/pcinfo/backend` y lo registra como servicio
  systemd **`pcinfo-backend.service`** (corre como root → acceso a `dmidecode`
  y `smartctl` para RAM por ranura y S.M.A.R.T.);
- depende de `smartmontools` y `dmidecode` (se instalan solos con apt).

Instalar / desinstalar:
```bash
sudo apt install ./instaladores/pcinfo_1.1.0_amd64.deb
sudo apt remove pcinfo
```

## Windows (`.exe`) — vía GitHub Actions
El bundle Flutter para Windows **no se puede compilar desde Linux** (requiere
Visual Studio). Se genera en CI:

- Workflow: `.github/workflows/windows-installer.yml` (runner `windows-latest`).
- Pasos: compila backend Go (`.exe`) → `flutter build windows --release` →
  Inno Setup (`instalador_windows.iss`) → sube el instalador como **artifact**
  `pcinfo-windows-installer`.
- Se dispara solo al hacer push a `main` (cambios en `pcinfo/`, `backend/` o el
  `.iss`) o manualmente desde la pestaña **Actions → Run workflow**.
- El instalador resultante (`pcinfo-setup-1.1.0.exe`) se descarga desde la
  ejecución del workflow en GitHub.

### Compilar el instalador Windows a mano (en una máquina Windows)
Requiere Flutter + Visual Studio (Desktop C++) + Inno Setup 6:
```powershell
cd backend; go build -ldflags "-s -w" -o pcinfo-backend.exe .
cd ..\pcinfo; flutter build windows --release
cd ..
iscc /DSourceFlutter="pcinfo\build\windows\x64\runner\Release" `
     /DSourceBackend="backend\pcinfo-backend.exe" `
     instaladores\instalador_windows.iss
```
