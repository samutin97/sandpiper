[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
; Non-solid: slightly larger, but less "packed dropper" heuristic noise on AV/VT.
SolidCompression=no
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; Closes locked app binaries before file replace — prefer this over taskkill.exe heuristics.
CloseApplications=force
; VERSIONINFO for Setup.exe and the embedded uninstaller. PE files without a
; CompanyName/ProductName resource are an "unknown dropper" signal for AV engines.
VersionInfoCompany={{PUBLISHER_NAME}}
VersionInfoDescription={{DISPLAY_NAME}} Setup
VersionInfoProductName={{DISPLAY_NAME}}
VersionInfoTextVersion={{APP_VERSION}}
VersionInfoCopyright=Copyright (C) {{PUBLISHER_NAME}}
AppCopyright=Copyright (C) {{PUBLISHER_NAME}}
; Settings > Apps / Add or Remove Programs entry: plain name + the app icon
; (Store policy 10.2.7 rejects a blank or unrelated name or publisher).
UninstallDisplayName={{DISPLAY_NAME}}
UninstallDisplayIcon={app}\{{EXECUTABLE_NAME}}
; CI (windows/scripts/configure_windows_signing.ps1) registers the "hiddifysign"
; Sign Tool and sets HIDDIFY_INNO_SIGNTOOL, so the compiler signs Setup.exe *and*
; unins000.exe. An unsigned uninstaller dropped into Program Files is one of the
; VirusTotal sandbox hits ("Sysmon File Executable Creation" Sigma rule).
#if GetEnv("HIDDIFY_INNO_SIGNTOOL") == "hiddifysign"
SignTool=hiddifysign
SignedUninstaller=yes
#endif

; Translations Inno Setup 6.7 ships only as "unofficial" (not in compiler:Languages) are
; kept in windows/packaging/exe/languages. fastforge writes this script under dist\<version>\,
; so the folder is found from SETUP_ICON_FILE, the one path it passes as absolute
; (<repo>\windows\runner\resources\app_icon.ico).
#define HiddifyLanguagesDir AddBackslash(ExtractFileDir("{{SETUP_ICON_FILE}}")) + "..\..\packaging\exe\languages\"

[Languages]
{% for locale in LOCALES %}
{% if locale == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale == 'ar' %}Name: "arabic"; MessagesFile: "compiler:Languages\\Arabic.isl"{% endif %}
{% if locale == 'fa' %}Name: "farsi"; MessagesFile: "{#HiddifyLanguagesDir}Farsi.isl"{% endif %}
{% if locale == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale == 'zh' %}Name: "chinesesimplified"; MessagesFile: "{#HiddifyLanguagesDir}ChineseSimplified.isl"{% endif %}
{% if locale == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{{DISPLAY_NAME}}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if LAUNCH_AT_STARTUP != true %}unchecked{% else %}checkedonce{% endif %}
[InstallDelete]
; Before 5.9.1 the core ran from core\Hiddify.exe; it is SandpiperCoreEngine.exe beside the app now.
Type: filesandordirs; Name: "{app}\core"
; The console launcher was HiddifyCli.exe before SandpiperCore.exe (a core that still ships it puts it back).
Type: files; Name: "{app}\HiddifyCli.exe"

[Files]
Source: "{{SOURCE_DIR}}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
; --autostart: when the app's own autostart entry launched a copy first, this one exits without
; showing that copy's window, which would undo a silent start.
Name: "{userstartup}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"; Parameters: "--autostart"; WorkingDir: "{app}"; Tasks: launchAtStartup
[Registry]
; A "Run as administrator" compatibility layer left on the app's path by an older install (or set
; by hand) makes CreateProcess refuse the app with error 740, so the launch at the end of Setup
; failed with "The requested operation requires elevation". The app must not run elevated anyway:
; it installs its service through SandpiperAdmin.exe, and an elevated app sets the system proxy and
; the autostart for the wrong user. Drop the layer for both hives.
Root: HKCU; Subkey: "Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueName: "{app}\{{EXECUTABLE_NAME}}"; ValueType: none; Flags: deletevalue dontcreatekey noerror
Root: HKLM; Subkey: "Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueName: "{app}\{{EXECUTABLE_NAME}}"; ValueType: none; Flags: deletevalue dontcreatekey noerror

[Run]
; shellexec: the app starts through ShellExecuteEx, as from Explorer. Should the app still need
; elevation (a compatibility layer, a policy), Windows prompts for it instead of CreateProcess
; failing with error 740. Never runascurrentuser, even for an install as administrator: a postinstall
; entry runs as the user who started Setup by default, and the app must not run elevated (above).
Filename: "{app}\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: shellexec nowait postinstall skipifsilent

[UninstallDelete]
; The app's data: %APPDATA%\<CompanyName>\<ProductName> of windows\runner\Runner.rc (path_provider).
; Never {userappdata}\Hiddify, which is upstream Hiddify's, installed beside it on the same PC.
Type: filesandordirs; Name: "{userappdata}\Sandpiper"
; D7-03: the folder of this app's service (ProgramData\Sandpiper\AdminBgService: its control secret,
; build stamp and core), after the service is removed (CurUninstallStepChanged). Upstream's is
; ProgramData\Hiddify, never touched here.
Type: filesandordirs; Name: "{commonappdata}\Sandpiper"

[Code]
// Stop/remove services via the Service Control Manager API.
// Do not shell out to net.exe / taskkill.exe / sc.exe — those command lines match
// common Sigma rules and drive VirusTotal sandbox false positives.

type
  TServiceStatus = record
    dwServiceType: DWORD;
    dwCurrentState: DWORD;
    dwControlsAccepted: DWORD;
    dwWin32ExitCode: DWORD;
    dwServiceSpecificExitCode: DWORD;
    dwCheckPoint: DWORD;
    dwWaitHint: DWORD;
  end;

const
  SC_MANAGER_CONNECT = $0001;
  SERVICE_QUERY_STATUS = $0004;
  SERVICE_STOP = $0020;
  SERVICE_CONTROL_STOP = $0001;
  SERVICE_STOPPED = $0001;
  DELETE_ACCESS = $10000;
  // The elevated service this app's core installs: its own name (upstream Hiddify's is
  // HiddifyAdminBG, never touched here), running the SandpiperAdmin.exe it was installed from.
  ADMIN_SERVICE = 'SandpiperAdminBG';

function OpenSCManager(lpMachineName, lpDatabaseName: string; dwDesiredAccess: DWORD): THandle;
  external 'OpenSCManagerW@advapi32.dll stdcall';
function OpenService(hSCManager: THandle; lpServiceName: string; dwDesiredAccess: DWORD): THandle;
  external 'OpenServiceW@advapi32.dll stdcall';
function ControlService(hService: THandle; dwControl: DWORD; var lpServiceStatus: TServiceStatus): Boolean;
  external 'ControlService@advapi32.dll stdcall';
function DeleteService(hService: THandle): Boolean;
  external 'DeleteService@advapi32.dll stdcall';
function CloseServiceHandle(hSCObject: THandle): Boolean;
  external 'CloseServiceHandle@advapi32.dll stdcall';
function QueryServiceStatus(hService: THandle; var lpServiceStatus: TServiceStatus): Boolean;
  external 'QueryServiceStatus@advapi32.dll stdcall';

procedure StopServiceByName(const ServiceName: string; const Remove: Boolean);
var
  hSCM, hService: THandle;
  Access: DWORD;
  Status: TServiceStatus;
  I: Integer;
begin
  hSCM := OpenSCManager('', '', SC_MANAGER_CONNECT);
  if hSCM = 0 then
    Exit;

  Access := SERVICE_STOP or SERVICE_QUERY_STATUS;
  if Remove then
    Access := Access or DELETE_ACCESS;

  hService := OpenService(hSCM, ServiceName, Access);
  if hService <> 0 then
  begin
    // up to 10 s for the service to exit, so its files can be replaced or deleted
    if ControlService(hService, SERVICE_CONTROL_STOP, Status) then
      for I := 1 to 100 do
      begin
        if not QueryServiceStatus(hService, Status) then
          Break;
        if Status.dwCurrentState = SERVICE_STOPPED then
          Break;
        Sleep(100);
      end;
    if Remove then
      DeleteService(hService);
    CloseServiceHandle(hService);
  end;

  CloseServiceHandle(hSCM);
end;

// Whether the service runs a program from this app's folder: a service upstream Hiddify installed
// beside this app (the same name, its own folder) is never stopped or removed by this setup.
function ServiceRunsFromApp(const ServiceName: string): Boolean;
var
  ImagePath: string;
begin
  Result := False;
  if RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Services\' + ServiceName, 'ImagePath', ImagePath) then
    Result := Pos(Lowercase(AddBackslash(ExpandConstant('{app}'))), Lowercase(ImagePath)) > 0;
end;

// Before the files are checked and replaced: this app's service is stopped so its binaries can be
// replaced on upgrade (it was stopped whatever it ran, upstream Hiddify's VPN included, and
// Hiddify's legacy HiddifyTunnelService was removed; this app never installed that one).
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if ServiceRunsFromApp(ADMIN_SERVICE) then
    StopServiceByName(ADMIN_SERVICE, False);
  Result := '';
end;

// D7-03: the handler of sandpiper:// links the app registers for its user (HKCU), when it opens this
// app's executable: left behind, it pointed at a deleted file. A handler another program registered
// under that scheme is left as it is.
procedure RemoveLinkHandler();
var
  Command: string;
begin
  if RegQueryStringValue(HKCU, 'Software\Classes\sandpiper\shell\open\command', '', Command) and
     (Pos(Lowercase(AddBackslash(ExpandConstant('{app}'))), Lowercase(Command)) > 0) then
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\sandpiper');
end;

// B-02: the uninstaller removes this app's service (stopped, up to 10 s, then deleted) before the
// files go. Left behind, it was a SYSTEM service started at every boot from a folder that no longer
// exists (and could be made again).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    if ServiceRunsFromApp(ADMIN_SERVICE) then
      StopServiceByName(ADMIN_SERVICE, True);
    RemoveLinkHandler();
  end;
end;