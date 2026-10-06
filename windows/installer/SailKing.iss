#ifndef Stage
 #error Stage must point to the verified build staging directory
#endif
#ifndef Output
 #define Output "..\..\build\windows"
#endif
#define AppVersion "0.4.0-preview.1"
[Setup]
AppId={{536B7ED5-A481-4931-A19E-4706E2BE6862}
AppName=出海王输入法
AppVersion={#AppVersion}
AppPublisher=SailKing contributors
AppPublisherURL=https://github.com/sapplex-sz/SailKing
AppSupportURL=https://github.com/sapplex-sz/SailKing/issues
DefaultDirName={autopf}\SailKing
DefaultGroupName=出海王输入法
OutputDir={#Output}
OutputBaseFilename=SailKing-{#AppVersion}-Windows-x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
PrivilegesRequired=admin
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\Native\SailKing.ico
UninstallDisplayIcon={app}\SailKing.exe
UninstallDisplayName=出海王输入法
CloseApplications=no
RestartApplications=no
DisableProgramGroupPage=yes
[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs restartreplace uninsrestartdelete
[Icons]
Name: "{commonprograms}\出海王输入法"; Filename: "{app}\SailKing.exe"
Name: "{commonstartup}\SailKing Input Service"; Filename: "{app}\SailKingBroker.exe"; WorkingDir: "{app}"
[Run]
Filename: "{app}\SailKing.exe"; Description: "打开出海王，完成键盘设置"; Flags: nowait postinstall skipifsilent runasoriginaluser
[Code]
function RegisterTip(Unregister: Boolean): Boolean;
var Code: Integer; Args: String;
begin
 if Unregister then Args := '/s /u ' else Args := '/s ';
 Result := Exec(ExpandConstant('{sys}\regsvr32.exe'), Args + '"' + ExpandConstant('{app}\native\{#AppVersion}\x64\SailKingTip.dll') + '"', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
 if Result then Result := Exec(ExpandConstant('{syswow64}\regsvr32.exe'), Args + '"' + ExpandConstant('{app}\native\{#AppVersion}\x86\SailKingTip.dll') + '"', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;
procedure StopBroker;
var Code: Integer;
begin
 if FileExists(ExpandConstant('{app}\SailKingProbe.exe')) then
  Exec(ExpandConstant('{app}\SailKingProbe.exe'), '--stop-broker', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;
procedure CurStepChanged(CurStep: TSetupStep);
begin
 if CurStep = ssInstall then StopBroker;
 if CurStep = ssPostInstall then begin
  if not RegisterTip(False) then begin
   RegisterTip(True);
   RaiseException('系统输入法注册失败。请重新运行安装包。');
  end;
 end;
end;
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
 if CurUninstallStep = usUninstall then begin StopBroker; RegisterTip(True); end;
end;
