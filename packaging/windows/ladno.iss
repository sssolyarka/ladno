#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
[Setup]
AppId={{C138EC64-8595-42A6-9435-81AB4DA3BC42}
AppName=Ладно
AppVersion={#AppVersion}
AppPublisher=sssolyarka
AppPublisherURL=https://github.com/sssolyarka/ladno
DefaultDirName={localappdata}\Programs\Ladno
DefaultGroupName=Ладно
UninstallDisplayIcon={app}\ladno.exe
OutputDir={#OutputDir}
OutputBaseFilename=ladno-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
SetupIconFile=..\..\windows\runner\resources\app_icon.ico

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Ладно"; Filename: "{app}\ladno.exe"
Name: "{autodesktop}\Ладно"; Filename: "{app}\ladno.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ladno.exe"; Description: "Открыть Ладно"; Flags: nowait postinstall skipifsilent
