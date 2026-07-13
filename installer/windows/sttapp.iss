#ifndef AppVersion
  #error AppVersion must be provided to ISCC, for example /DAppVersion=1.2.3
#endif

#define AppName "sttapp"
#define AppPublisher "sttapp"
#define AppExeName "sttapp.exe"

[Setup]
AppId={{A89E3107-1926-45A2-BD9F-E0D2BC47F78C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=sttapp-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\build\installer\VC_redist.x64.exe"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  VCRedistRestartRequired: Boolean;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  ExtractTemporaryFile('VC_redist.x64.exe');

  if not Exec(
    ExpandConstant('{tmp}\VC_redist.x64.exe'),
    '/install /quiet /norestart',
    '',
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode
  ) then
  begin
    Result := 'The Microsoft Visual C++ Redistributable could not be started. ' +
      SysErrorMessage(ResultCode);
    exit;
  end;

  { 1638 means that another/newer compatible version is already installed. }
  if (ResultCode <> 0) and (ResultCode <> 1638) and (ResultCode <> 3010) then
  begin
    Result := 'The Microsoft Visual C++ Redistributable installation failed with exit code ' +
      IntToStr(ResultCode) + '. Run this installer again with /LOG=path-to-log.txt for details.';
    exit;
  end;

  if ResultCode = 3010 then
  begin
    VCRedistRestartRequired := True;
    NeedsRestart := True;
  end;
end;

function NeedRestart(): Boolean;
begin
  Result := VCRedistRestartRequired;
end;
