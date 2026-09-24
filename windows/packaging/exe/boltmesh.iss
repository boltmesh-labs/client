; Custom Inno Setup template for the BoltMesh Windows installer.
;
; Mirrors flutter_app_packager's default template but adds the privileged
; boltmeshd helper service: it is installed and started during setup, and
; stopped and removed on uninstall. The Flutter bundle already contains
; boltmeshd.exe (staged by windows/packaging/stage_boltmeshd.ps1) next to the
; plugin's wireguard_svc.exe / wireguard.dll, so the [Files] wildcard ships
; them all and the helper finds its backend beside itself. The helper's
; uninstall path also tears down the on-demand tunnel service and its config.
;
; Wired in through windows/packaging/exe/make_config.yaml (`script_template`).

[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
; The privileged helper and tunnel services load their binaries from {app} as
; LocalSystem, so the destination must stay in a protected system directory.
; Hide the directory page; [Code] additionally rejects a /DIR override that
; escapes the protected Program Files tree.
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCHITECTURES_ALLOWED}}
ArchitecturesInstallIn64BitMode={{ARCHITECTURES_INSTALL_IN_64BIT_MODE}}

[Languages]
{% for locale in LOCALES %}
{% if locale == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\Armenian.isl"{% endif %}
{% if locale == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\Bulgarian.isl"{% endif %}
{% if locale == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\Catalan.isl"{% endif %}
{% if locale == 'zh' %}Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"{% endif %}
{% if locale == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\Corsican.isl"{% endif %}
{% if locale == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\Czech.isl"{% endif %}
{% if locale == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\Danish.isl"{% endif %}
{% if locale == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\Dutch.isl"{% endif %}
{% if locale == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\Finnish.isl"{% endif %}
{% if locale == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\French.isl"{% endif %}
{% if locale == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\German.isl"{% endif %}
{% if locale == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"{% endif %}
{% if locale == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\Icelandic.isl"{% endif %}
{% if locale == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"{% endif %}
{% if locale == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"{% endif %}
{% if locale == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\Norwegian.isl"{% endif %}
{% if locale == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"{% endif %}
{% if locale == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"{% endif %}
{% if locale == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"{% endif %}
{% if locale == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\Slovak.isl"{% endif %}
{% if locale == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\Slovenian.isl"{% endif %}
{% if locale == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"{% endif %}
{% if locale == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"{% endif %}
{% if locale == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{{DISPLAY_NAME}}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if LAUNCH_AT_STARTUP != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
Name: "{userstartup}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"; WorkingDir: "{app}"; Tasks: launchAtStartup
[Run]
; Launch the app only after CurStepChanged(ssPostInstall) has installed the
; privileged helper. The helper owns the WireGuard tunnel service, so a bundle
; whose helper failed to install cannot connect; HelperInstalled keeps the app
; from starting in that state.
Filename: "{app}\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent; Check: HelperInstalled
[Code]
; The privileged helper is installed here rather than as a [Run] entry: Inno
; only logs a [Run] program's exit code, so a failed boltmeshd -install would
; otherwise be followed by the app launch and a "successful" install with no
; working tunnel. Installing it during ssPostInstall also runs it before the
; postinstall app launch. A failure suppresses that launch and is reported
; through the setup exit code.
var
  HelperInstallFailed: Boolean;

; Gates the postinstall app launch; a bundle whose helper failed must not start.
function HelperInstalled(): Boolean;
begin
  Result := not HelperInstallFailed;
end;

procedure InstallHelperService();
var
  HelperPath: String;
  ResultCode: Integer;
begin
  HelperPath := ExpandConstant('{app}\boltmeshd.exe');
  if not Exec(HelperPath, '-install', ExpandConstant('{app}'), SW_HIDE,
              ewWaitUntilTerminated, ResultCode) then
  begin
    HelperInstallFailed := True;
    Log('The BoltMesh helper could not be started for install.');
  end
  else if ResultCode <> 0 then
  begin
    HelperInstallFailed := True;
    Log(Format('The BoltMesh helper could not be installed (exit code %d).',
      [ResultCode]));
  end;

  if HelperInstallFailed and not WizardSilent then
    MsgBox('The BoltMesh helper service could not be installed, so the app ' +
      'cannot create a VPN tunnel. Re-run the installer, or see the setup log ' +
      'for details.', mbCriticalError, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    InstallHelperService();
end;

; A failed helper install means the install did not achieve its purpose. Report
; a nonzero exit code so silent and automated installs see the failure instead
; of success.
function GetCustomSetupExitCode(): Integer;
begin
  if HelperInstallFailed then
    Result := 1
  else
    Result := 0;
end;

; The privileged helper and tunnel services run as LocalSystem and load their
; binaries from {app}. DisableDirPage hides the directory page, but the /DIR
; command line can still override DefaultDirName, so verify the destination is
; inside the protected Program Files tree before any service is registered.
; Reject '..' as well so a non-canonical path cannot escape after expansion.
function InstallDirIsProtected(): Boolean;
var
  AppDir: String;
  ProtectedRoot: String;
  Prefix: String;
begin
  AppDir := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));
  ProtectedRoot := RemoveBackslashUnlessRoot(ExpandConstant('{autopf64}'));
  Prefix := ProtectedRoot + '\';
  Result := (Pos('..', AppDir) = 0) and
    ((CompareText(AppDir, ProtectedRoot) = 0) or
      (CompareText(Copy(AppDir, 1, Length(Prefix)), Prefix) = 0));
end;

; Run cleanup from an uninstall event rather than [UninstallRun] so a
; non-zero helper exit aborts before installed files are removed.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  HelperPath: String;
begin
  Result := '';
  if not InstallDirIsProtected() then
  begin
    Result := 'BoltMesh must be installed under Program Files. The selected ' +
      'directory is not protected, and the privileged helper would run from it.';
    Exit;
  end;
  // An upgrade replaces boltmeshd.exe while the old service may still hold
  // it open; remove the service first so the copy cannot fail. The helper
  // waits for both service registrations to disappear, and a failed cleanup
  // must abort rather than let the installer replace a live helper.
  HelperPath := ExpandConstant('{app}\boltmeshd.exe');
  if FileExists(HelperPath) then
  begin
    if not Exec(HelperPath, '-uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    begin
      Result := 'The BoltMesh helper could not be started for uninstall.';
    end
    else if ResultCode <> 0 then
    begin
      Result := Format('The BoltMesh helper could not be removed (exit code %d).', [ResultCode]);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CleanupError: String;
  HelperPath: String;
  ResultCode: Integer;
begin
  if (CurUninstallStep <> usUninstall) or not FileExists(ExpandConstant('{app}\boltmeshd.exe')) then
  begin
    Exit;
  end;

  HelperPath := ExpandConstant('{app}\boltmeshd.exe');
  CleanupError := '';
  if not Exec(HelperPath, '-uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    CleanupError := 'The BoltMesh helper could not be started for uninstall.'
  else if ResultCode <> 0 then
    CleanupError := Format('The BoltMesh helper could not be removed (exit code %d).', [ResultCode]);

  if CleanupError <> '' then
  begin
    Log(CleanupError);
    if not UninstallSilent then
      MsgBox(CleanupError, mbError, MB_OK);
    Abort;
  end;
end;
