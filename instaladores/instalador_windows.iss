; Inno Setup — instalador de PCInfo para Windows (GUI Flutter + backend Go).
; Se compila en un runner/máquina Windows. Las rutas de origen se pasan por
; línea de comandos:
;   iscc /DSourceFlutter="...\Release" /DSourceBackend="...\pcinfo-backend.exe" instalador_windows.iss
; (las usa el workflow .github/workflows/windows-installer.yml)

#define AppName "PCInfo"
#define AppVer "1.1.0"
#define Publisher "tuxor"

#ifndef SourceFlutter
  #define SourceFlutter "..\pcinfo\build\windows\x64\runner\Release"
#endif
#ifndef SourceBackend
  #define SourceBackend "..\backend\pcinfo-backend.exe"
#endif

[Setup]
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher={#Publisher}
DefaultDirName={autopf}\PCInfo
DefaultGroupName=PCInfo
UninstallDisplayIcon={app}\pcinfo.exe
OutputDir=.
OutputBaseFilename=pcinfo-setup-{#AppVer}
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
Source: "{#SourceFlutter}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs
; Backend Go.
Source: "{#SourceBackend}"; DestDir: "{app}"; DestName: "pcinfo-backend.exe"

[Icons]
Name: "{group}\PCInfo"; Filename: "{app}\pcinfo.exe"
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
; Iniciar backend ya mismo y abrir la app al terminar.
Filename: "{app}\pcinfo-backend.exe"; Parameters: "--addr 127.0.0.1:51247"; Flags: nowait runhidden
Filename: "{app}\pcinfo.exe"; Description: "Iniciar PCInfo"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Cerrar el backend al desinstalar.
Filename: "{cmd}"; Parameters: "/C taskkill /IM pcinfo-backend.exe /F"; Flags: runhidden; RunOnceId: "KillBackend"
