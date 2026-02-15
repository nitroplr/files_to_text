#define AppName "Files to Text"
#define AppVersion "1.0.0"
#define AppPublisher "RaidBuilder"
#define AppExeName "files_to_text.exe"

[Setup]
AppId={{B07C21B9-79B6-4E65-A5F1-3BB2B7E6D9B7}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=installer_out
OutputBaseFilename=Setup_{#AppName}_{#AppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

; Optional: add an icon to the installer itself
; SetupIconFile=windows\runner\resources\app_icon.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; IMPORTANT: points to Flutter's Release folder
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
