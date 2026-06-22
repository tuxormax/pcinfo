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

[Registry]
; El backend arranca en cada inicio de sesión (la GUI le consulta el hardware).
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "PCInfoBackend"; \
  ValueData: """{app}\pcinfo-backend.exe"" --addr 127.0.0.1:51247"; \
  Flags: uninsdeletevalue

[Run]
#ifdef VcRedist
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Instalando Visual C++ Runtime..."; Flags: waituntilterminated
#endif
Filename: "{app}\pcinfo-backend.exe"; Parameters: "--addr 127.0.0.1:51247"; Flags: nowait runhidden
Filename: "{app}\pcinfo.exe"; Description: "Iniciar PCInfo"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Cerrar el backend al desinstalar.
Filename: "{cmd}"; Parameters: "/C taskkill /IM pcinfo-backend.exe /F"; Flags: runhidden; RunOnceId: "KillBackend"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
