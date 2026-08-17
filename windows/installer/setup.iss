; Private Whisper — per-user Inno Setup installer (NO admin rights required).
; Mirrors the VS Code "User Installer" pattern: installs to
; %LOCALAPPDATA%\Programs\PrivateWhisper, Start-menu shortcut, HKCU uninstall
; registration (automatic when PrivilegesRequired=lowest).
;
; Build (after scripts\package.ps1 has assembled windows\dist\app):
;   ISCC.exe installer\setup.iss

#define MyAppName "Private Whisper"
#ifndef MyAppVersion
#define MyAppVersion "0.0.0"
#endif
#define MyAppExeName "PrivateWhisper.exe"
#define MyAppPublisher "Private Whisper"

[Setup]
AppId={{B7E64D1A-52C9-4F0E-A3D8-6C2F91B7A4E0}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\PrivateWhisper
DisableProgramGroupPage=yes
DisableDirPage=yes
; Per-user install, no UAC prompt, HKCU uninstall entry.
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=PrivateWhisper-windows-{#MyAppVersion}-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
WizardStyle=modern

[Files]
; Everything package.ps1 assembled: PrivateWhisper.exe + runtime\whisper\* +
; runtime\llama\* (sidecar binaries). Models are downloaded on first run into
; %APPDATA%\PrivateWhisper (this is the installed, non-portable layout — no
; portable.marker here).
Source: "..\dist\app\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{userprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; The app folder only. Downloaded models/config in %APPDATA%\PrivateWhisper are
; the user's data; deleting them is offered in the app, not forced here.
Type: filesandordirs; Name: "{app}"
