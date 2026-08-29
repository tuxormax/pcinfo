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
; Recopilador de pantallazos azules. Deja el equipo capturando SOLO cada BSOD en
; C:\bluescreen.md y, sobre todo, garantiza que Windows llegue a crear el .dmp:
; sin volcado, el análisis del culpable de la pestaña Historial de Errores no
; tiene nada que leer (caso real: 32 pantallazos y solo 5 volcados).
Source: "..\herramientas\bluescreen\bluescreen.ps1"; DestDir: "{app}\bluescreen"; Flags: ignoreversion
Source: "..\herramientas\bluescreen\bluescreen.bat"; DestDir: "{app}\bluescreen"; Flags: ignoreversion
#ifdef VcRedist
; Runtime de Visual C++ empaquetado (la app no arranca sin VCRUNTIME140).
Source: "{#VcRedist}"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif

[Icons]
Name: "{group}\PCInfo"; Filename: "{app}\pcinfo.exe"
Name: "{group}\Pantallazos azules (bluescreen)"; Filename: "{app}\bluescreen\bluescreen.bat"; Comment: "Ver y recopilar los pantallazos azules del equipo"
Name: "{group}\Desinstalar PCInfo"; Filename: "{uninstallexe}"
Name: "{commondesktop}\PCInfo"; Filename: "{app}\pcinfo.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear acceso directo en el escritorio"; GroupDescription: "Accesos directos:"

[Run]
#ifdef VcRedist
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Instalando Visual C++ Runtime..."; Flags: waituntilterminated
#endif
; Deja puesta la tarea 'RecopilarBluescreens' (la dispara el propio pantallazo,
; vía el evento 1001) y configura Windows para que SIEMPRE guarde el volcado. Se
; hace en cada instalación y sin preguntar: es lo que garantiza que la pestaña
; Historial de Errores tenga un .dmp que analizar. Se espera a que termine
; porque además recopila los pantallazos que ya hubieran ocurrido.
; skipifdoesntexist: si el equipo no tiene PowerShell, se salta en silencio en
; vez de abrirle un error al usuario en mitad de la instalación.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\bluescreen\bluescreen.ps1"" -InstalarTarea"; StatusMsg: "Configurando el recopilador de pantallazos azules..."; Flags: runhidden waituntilterminated skipifdoesntexist

; PCInfo en sí NO deja servicio en 2º plano: la GUI (asInvoker, abre siempre)
; lanza el backend como proceso hijo mientras está abierta y lo cierra al salir
; (estilo HWiNFO); el backend se eleva por UAC solo si necesita SMART. Aquí solo
; se ofrece abrir la app al terminar. runasoriginaluser: abrirla como el usuario
; normal (no heredar la elevación del instalador), igual que un doble clic.
Filename: "{app}\pcinfo.exe"; Description: "Iniciar PCInfo"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; Cerrar cualquier backend que la app haya dejado corriendo.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM pcinfo-backend.exe /F"; Flags: runhidden; RunOnceId: "KillBackend"
; Quitar la tarea del recopilador. C:\bluescreen.md NO se borra: es el informe
; del usuario, y borrarlo al desinstalar sería perder su historial de fallos.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\bluescreen\bluescreen.ps1"" -QuitarTarea"; Flags: runhidden skipifdoesntexist; RunOnceId: "QuitarTareaBluescreen"

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
