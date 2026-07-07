; Inno Setup — instalador de PCInfo para Windows (GUI Flutter + backend Go).
; Se compila en un runner/máquina Windows (ISCC ya viene en windows-latest).
; Las rutas y la versión se pasan por línea de comandos con /D (ver el workflow
; .github/workflows/windows-installer.yml). Para compilar a mano basta con los
; valores por defecto de abajo.

#define AppName "PCInfo"

#ifndef AppVer
  #define AppVer "1.1"
#endif
#ifndef SourceFlutter
  #define SourceFlutter "..\pcinfo\build\windows\x64\runner\Release"
#endif
#ifndef SourceBackend
  #define SourceBackend "..\backend\pcinfo-backend.exe"
#endif
#ifndef SourceSmartctl
  #define SourceSmartctl "..\backend\smartctl.exe"
#endif
#ifndef SourceDrivedb
  #define SourceDrivedb "..\backend\drivedb.h"
#endif
#ifndef OutDir
  #define OutDir "."
#endif
#ifndef BaseName
  #define BaseName "pcinfo-setup"
#endif

[Setup]
; AppId fijo → las actualizaciones reemplazan la versión previa.
AppId={{7E3B1A92-5D44-4C18-9F2A-1B6C7D8E9F01}}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher=tuxor
DefaultDirName={autopf}\pcinfo
DefaultGroupName=PCInfo
UninstallDisplayName=PCInfo
UninstallDisplayIcon={app}\pcinfo.exe
OutputDir={#OutDir}
OutputBaseFilename={#BaseName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
; Bundle completo de la GUI Flutter (pcinfo.exe + DLLs + data\).
Source: "{#SourceFlutter}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Backend Go.
Source: "{#SourceBackend}"; DestDir: "{app}"; DestName: "pcinfo-backend.exe"; Flags: ignoreversion
; smartctl (smartmontools) + su base de datos de discos: sin esto la ficha de
; almacenamiento sale "SIN SMART" en Windows (no viene en el PATH del sistema).
Source: "{#SourceSmartctl}"; DestDir: "{app}"; DestName: "smartctl.exe"; Flags: ignoreversion
Source: "{#SourceDrivedb}"; DestDir: "{app}"; DestName: "drivedb.h"; Flags: ignoreversion
#ifdef VcRedist
; Runtime de Visual C++ empaquetado (la app no arranca sin VCRUNTIME140).
Source: "{#VcRedist}"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif

[Icons]
Name: "{group}\PCInfo"; Filename: "{app}\pcinfo.exe"
Name: "{group}\Desinstalar PCInfo"; Filename: "{uninstallexe}"
Name: "{commondesktop}\PCInfo"; Filename: "{app}\pcinfo.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear acceso directo en el escritorio"; GroupDescription: "Accesos directos:"

[Run]
#ifdef VcRedist
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Instalando Visual C++ Runtime..."; Flags: waituntilterminated
#endif
; NO hay servicio en 2º plano: la GUI (asInvoker, abre siempre) lanza el backend
; como proceso hijo mientras está abierta y lo cierra al salir (estilo HWiNFO).
; El backend se lanza elevado (UAC) solo si se necesita SMART. Aquí solo se ofrece
; iniciar la app al terminar. runasoriginaluser: abrir la app como el usuario
; normal (no heredar la elevación del instalador), igual que un doble clic.
Filename: "{app}\pcinfo.exe"; Description: "Iniciar PCInfo"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; Cerrar cualquier backend que la app haya dejado corriendo.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM pcinfo-backend.exe /F"; Flags: runhidden; RunOnceId: "KillBackend"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// Antes de copiar archivos: (1) eliminar el SERVICIO de versiones anteriores
// (rev-9 lo instalaba; ya no se usa), y (2) matar la app/backend si están
// abiertos, porque tendrían bloqueados los .exe y la copia fallaría.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Rc: Integer;
begin
  Exec(ExpandConstant('{sys}\sc.exe'), 'stop PCInfoBackend', '', SW_HIDE, ewWaitUntilTerminated, Rc);
  Exec(ExpandConstant('{sys}\sc.exe'), 'delete PCInfoBackend', '', SW_HIDE, ewWaitUntilTerminated, Rc);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM pcinfo-backend.exe /F', '', SW_HIDE, ewWaitUntilTerminated, Rc);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM pcinfo.exe /F', '', SW_HIDE, ewWaitUntilTerminated, Rc);
  Sleep(1200);
  Result := '';
end;
