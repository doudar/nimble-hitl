#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#ifndef StageDir
  #error StageDir preprocessor define is required.
#endif

#define AppName "NimBLE HITL"
#define AppExeName "nimble_hitl_host.exe"

[Setup]
AppId={{E3A4D1B1-6AE8-4E25-95F6-2275438FC21E}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Anthony
DefaultDirName={localappdata}\Programs\NimBLE HITL
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputDir={#StageDir}\installer
OutputBaseFilename=nimble-hitl-windows-{#AppVersion}
UninstallDisplayIcon={app}\{#AppExeName}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "{#StageDir}\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
