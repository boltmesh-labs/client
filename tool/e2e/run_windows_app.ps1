<#
.SYNOPSIS
    Runs the Windows desktop app end to end, in the user's interactive session.

.DESCRIPTION
    The Windows twin of `tool/e2e/run_linux_app.sh`: the real GUI signs in
    against the real API, connects through the real privileged `boltmeshd`,
    and the run passes only once a real WireGuard tunnel has carried bytes on
    every rung the node serves. See tool/e2e/README.md for what that proves.

    Runs entirely as the normal, unprivileged user. The privileged helper is
    installed by `tool/e2e/install_boltmeshd.ps1` (elevated), which must run
    first; this script never elevates the app.

    Two things differ from Linux, and both are facts of the platform rather
    than app behaviour:

      * The helper is a service listening on a named pipe, not a systemd socket
        unit, so a stopped boltmeshd is a helper the app cannot reach at all.
        This script only checks the service is running.

      * The pipe's DACL grants access to Interactive Users, and the token a
        command gets over SSH, a scheduled task, or a service does not carry
        that group. A test process started from such a session cannot open the
        pipe, whatever the daemon is doing. So when this script is not already
        running in the interactive session, it re-executes itself there: it
        registers a limited-privilege scheduled task configured to run only
        when the user is logged on, starts it, streams its log, and reports its
        exit code. The app under test therefore always runs unprivileged in the
        session the pipe's own ACL expects - the shipped posture, not an
        elevated approximation of it.

    Credentials come from the environment or the gitignored `.env.e2e`, never a
    flag: the process list is world-readable, and a password there outlives the
    run. The relaunched run receives them through a file in this user's own
    work directory, which is the same trade `.env.e2e` already makes.

.PARAMETER EnvFile
    The `--dart-define-from-file` file, as `make run` uses. Defaults to `.env`
    at the repo root.

.PARAMETER WorkDir
    Where artifacts and the relaunch file go. Defaults to a private directory
    under this user's temp.

.PARAMETER LogFile
    Transcribe the run to this file, and stream it back when relaunching.

.PARAMETER SessionEnvFile
    Internal: the KEY=VALUE file a relaunching run hands to the one it starts.

.PARAMETER TimeoutMinutes
    How long a relaunched run may take. The ladder walk alone is three real
    handshakes plus an in-tunnel ping each, so this is deliberately generous.

.PARAMETER SkipClearDevices
    Keep the account's device rows. A failed run leaves its row behind and the
    device cap then fails the *next* run, so the default is to clear them.

.PARAMETER DryRunDevices
    List what clearing the devices would delete, and delete nothing.

.PARAMETER KeepSession
    Keep the app's stored session. The default is a fresh one, so a scripted
    run drives the sign-in form rather than the restore path.

.PARAMETER KeepTask
    Leave the relaunch task registered, for diagnosing a relaunched run.

.PARAMETER NoRelaunch
    Internal: run here even if this session is not the interactive one. Set by
    the task this script registers.

.PARAMETER Transcript
    Internal: transcribe this run to -LogFile, which is what a relaunching run
    streams back. The relaunching run prints live instead, so only the run that
    lands in the interactive session writes the log.

.EXAMPLE
    pwsh -File tool/e2e/install_boltmeshd.ps1     # once, elevated
    pwsh -File tool/e2e/run_windows_app.ps1
#>
[CmdletBinding()]
param(
    [string] $EnvFile = '',
    [string] $WorkDir = '',
    [string] $LogFile = '',
    [string] $SessionEnvFile = '',
    [int] $TimeoutMinutes = 40,
    [switch] $SkipClearDevices,
    [switch] $DryRunDevices,
    [switch] $KeepSession,
    [switch] $KeepTask,
    [switch] $NoRelaunch,
    [switch] $Transcript
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $repoRoot
$script:failed = $false

if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP 'boltmesh-windows-app-e2e' }
if (-not $LogFile) { $LogFile = Join-Path $WorkDir 'run.log' }
$taskName = 'BoltMeshE2EAppRun'
$credentialFile = Join-Path $repoRoot '.env.e2e'
$shotDir = Join-Path $WorkDir 'shots'

function ok([string] $message) { Write-Host "ok    $message" -ForegroundColor Green }
function warn([string] $message) { Write-Host "warn  $message" -ForegroundColor Yellow }
function bad([string] $message) {
    Write-Host "FAIL  $message" -ForegroundColor Red
    $script:failed = $true
}

function die([string] $message) {
    Write-Host "e2e: $message" -ForegroundColor Red
    exit 1
}

# Runs a native command and returns its exit code.
#
# Needed because this script runs with $ErrorActionPreference = 'Stop', and
# Windows PowerShell 5.1 turns a native command's *stderr* into a terminating
# error when it is captured. A tool's own warning - `go build`'s, the daemon's,
# a Python SyntaxWarning - would then abort a run that is otherwise fine, with
# the tool's message replacing the real failure. The exit code is the signal
# that matters here.
function Invoke-Native([scriptblock] $command) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $command
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InteractiveToken {
    # S-1-5-4 is the Interactive Users group, which the helper's pipe DACL
    # grants read/write to. A token without it - an SSH session, a service, an
    # ordinary scheduled task - cannot open the pipe at all.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sids = $identity.Groups | ForEach-Object { $_.Value }
    return $sids -contains 'S-1-5-4'
}

function Find-InteractiveSession {
    # A logged-on session with a desktop: the task this script registers can
    # only land in one of those. A disconnected RDP session still counts - it
    # is logged on, and its desktop is alive.
    $sessions = & query.exe session 2>$null
    foreach ($line in $sessions) {
        if ($line -match '^\s*\S+\s+\S+\s+\d+\s+Active') { return $true }
    }
    return $false
}

function Read-KeyValues([string] $path) {
    """Reads a KEY=VALUE file, tolerating comments and quotes. Never sources it."""
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $path -ErrorAction SilentlyContinue) {
        $trimmed = "$line".Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $equals = $trimmed.IndexOf('=')
        if ($equals -lt 1) { continue }
        $key = $trimmed.Substring(0, $equals).Trim()
        $value = $trimmed.Substring($equals + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -or $first -eq "'") -and $first -eq $last) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }
    return $values
}

function Resolve-Credentials {
    """The staging credentials: the environment wins, then a relaunch file, then .env.e2e."""
    if ($env:BOLTMESH_E2E_API_USER -and $env:BOLTMESH_E2E_API_PASSWORD) {
        return @{
            User = $env:BOLTMESH_E2E_API_USER
            Password = $env:BOLTMESH_E2E_API_PASSWORD
            From = 'the environment'
        }
    }
    $sources = @()
    if ($SessionEnvFile -and (Test-Path -LiteralPath $SessionEnvFile)) { $sources += $SessionEnvFile }
    if (Test-Path -LiteralPath $credentialFile) { $sources += $credentialFile }
    foreach ($source in $sources) {
        $values = Read-KeyValues $source
        if ($values['BOLTMESH_E2E_API_USER'] -and $values['BOLTMESH_E2E_API_PASSWORD']) {
            return @{
                User = $values['BOLTMESH_E2E_API_USER']
                Password = $values['BOLTMESH_E2E_API_PASSWORD']
                From = $source
            }
        }
    }
    die "BOLTMESH_E2E_API_USER/BOLTMESH_E2E_API_PASSWORD are not set and no $credentialFile carries both (override with -SessionEnvFile)"
}

function Test-HelperRunning {
    $state = (& sc.exe query boltmeshd | Select-String -SimpleMatch 'STATE').Line
    return "$state" -match 'RUNNING'
}

function Get-SecureStorePaths {
    """Where flutter_secure_storage keeps the app's session and device identity.

    A DPAPI-encrypted JSON file in the app's support directory, which
    path_provider derives from this executable's CompanyName/ProductName
    (windows/runner/Runner.rc: com.boltmesh/boltmesh). A debug build launched
    by `flutter test` may carry no version resource at all, in which case the
    product name falls back to the executable name - hence the second path.
    """
    $appData = [Environment]::GetFolderPath('ApplicationData')
    return @(
        (Join-Path $appData 'com.boltmesh\boltmesh\flutter_secure_storage.dat'),
        (Join-Path $appData 'boltmesh\flutter_secure_storage.dat')
    )
}

function Reset-SecureStore {
    # The Linux twin starts every run from an isolated, freshly-unlocked
    # keyring, so a scripted run drives the sign-in form. This is the same
    # guarantee: the file holds this app's secrets and nothing else, so
    # removing it leaves the rest of the profile untouched.
    $removed = @()
    foreach ($path in (Get-SecureStorePaths)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            $removed += $path
        }
    }
    if ($removed.Count -gt 0) {
        ok "cleared the app's stored session ($($removed -join ', '))"
    }
    else {
        ok 'no stored session to clear; this run signs in fresh'
    }
}

function Clear-Devices([string] $apiBase, [hashtable] $credentials, [string] $python) {
    $client = Join-Path $repoRoot 'tool\e2e\client.py'
    $arguments = @(
        $client, '--clear-devices',
        '--api-base', $apiBase,
        '--api-user', $credentials.User,
        '--api-password', $credentials.Password
    )
    if ($DryRunDevices) { $arguments += '--dry-run' }
    $code = Invoke-Native { & $python $arguments }
    if ($code -ne 0) { die "clearing the account's devices failed (exit $code)" }
}

function Invoke-E2ERun {
    """Runs the app end to end, here. Returns flutter's exit code."""
    $defines = Read-KeyValues $EnvFile
    $apiBase = $defines['API_BASE_URL']
    if (-not $apiBase) { die "$EnvFile sets no API_BASE_URL" }

    if (Test-Elevated) {
        # The app is meant to be unprivileged: every privileged read goes
        # through the helper. Elevated, the run would still pass while proving
        # nothing about the posture the shipped client runs in.
        warn 'this run is elevated, so the app under test is too. The Linux twin refuses root for the same reason; the honest Windows equivalent is the relaunch into the interactive session.'
    }

    if (-not $KeepSession) { Reset-SecureStore }

    $python = $env:BOLTMESH_E2E_PYTHON
    if (-not $python) { $python = (Get-Command python -ErrorAction SilentlyContinue).Source }
    if (-not $python) { die 'python is required (set BOLTMESH_E2E_PYTHON to override the interpreter)' }

    if (-not $SkipClearDevices) {
        Write-Host "`n==> clearing the account's devices" -ForegroundColor Cyan
        Clear-Devices $apiBase (Resolve-Credentials) $python
    }

    Write-Host "`n==> running the Windows app end to end" -ForegroundColor Cyan
    Write-Host "  defines:     $EnvFile"
    Write-Host "  screenshots: $shotDir"
    New-Item -ItemType Directory -Path $shotDir -Force | Out-Null

    $env:BOLTMESH_E2E_SHOT_DIR = $shotDir
    $code = Invoke-Native { & flutter test integration_test/app_e2e.dart -d windows --dart-define-from-file $EnvFile }

    # This box is the client host, so a tunnel left up outlives the run. The
    # helper tears its own tunnel down; this is only the warning for when it
    # did not.
    $left = Get-NetAdapter -Name 'boltmesh0' -ErrorAction SilentlyContinue
    if ($left) {
        warn 'the boltmesh0 adapter is still up. Tear it down with:'
        Write-Host "  & (Join-Path `$env:ProgramData 'BoltMesh\e2e\boltmeshd.exe') -cleanup   # elevated" -ForegroundColor Yellow
    }
    return $code
}

function Invoke-InSession {
    """Re-runs this script inside the user's interactive session, via a limited task."""
    if (-not (Find-InteractiveSession)) {
        die "no logged-on interactive session to run in. Log on at the console (or over RDP) and rerun, or use -NoRelaunch to run here anyway."
    }
    if (-not (Test-Elevated)) {
        die "registering an interactive task needs elevation. Run this from an elevated shell, log on at the console and run it there, or use -NoRelaunch to run here anyway."
    }

    $credentials = Resolve-Credentials
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    # The task runs with the environment of the account, not of this process,
    # so the values this run resolved are handed over in a file in this user's
    # own temp directory. Same trust model as `.env.e2e`: private to the
    # operator, never on a command line.
    $sessionFile = Join-Path $WorkDir 'session.env'
    $handover = [ordered]@{
        BOLTMESH_E2E_API_USER = $credentials.User
        BOLTMESH_E2E_API_PASSWORD = $credentials.Password
    }
    if ($env:BOLTMESH_E2E_PYTHON) { $handover['BOLTMESH_E2E_PYTHON'] = $env:BOLTMESH_E2E_PYTHON }
    if ($SkipClearDevices) { $handover['BOLTMESH_E2E_KEEP_DEVICES'] = '1' }
    if ($DryRunDevices) { $handover['BOLTMESH_E2E_DRY_RUN'] = '1' }
    if ($KeepSession) { $handover['BOLTMESH_E2E_KEEP_SESSION'] = '1' }
    $handover.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -LiteralPath $sessionFile -Encoding UTF8

    $extra = ''
    if ($SkipClearDevices) { $extra += ' -SkipClearDevices' }
    if ($DryRunDevices) { $extra += ' -DryRunDevices' }
    if ($KeepSession) { $extra += ' -KeepSession' }
    $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
                "-NoRelaunch -Transcript -EnvFile `"$EnvFile`" -SessionEnvFile `"$sessionFile`" " +
                "-LogFile `"$LogFile`" -WorkDir `"$WorkDir`"$extra"
    Write-Host "`n==> relaunching in the interactive session" -ForegroundColor Cyan
    Write-Host "  $argument"

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    # LogonType Interactive is the whole point: the task runs only in a
    # logged-on session, which is the only kind whose token carries the
    # Interactive Users group the pipe's DACL grants.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Trigger $trigger -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName

        # Wait for it to actually start before watching for it to finish: a
        # task that has not begun yet is not "not running".
        $started = $false
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline) {
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Running') { $started = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $started) { die "the relaunched run never started (task state: $state)" }
        Write-Host "  relaunched run is up; streaming $LogFile" -ForegroundColor DarkGray

        $shown = 0
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $LogFile) {
                $lines = @(Get-Content -LiteralPath $LogFile)
                if ($lines.Count -gt $shown) {
                    $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host $_ }
                    $shown = $lines.Count
                }
            }
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            if ($state -ne 'Running') { break }
            Start-Sleep -Seconds 2
        }

        $result = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
        if ($state -eq 'Running') {
            Stop-ScheduledTask -TaskName $taskName
            die "the relaunched run did not finish within $TimeoutMinutes minutes"
        }
        Write-Host "`nrelaunched run finished with exit code $result" -ForegroundColor Cyan
        return [int] $result
    }
    finally {
        if (-not $KeepTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    }
}

try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    if ($LogFile -and $Transcript) { Start-Transcript -Path $LogFile -Force | Out-Null }

    Write-Host 'BoltMesh Windows app e2e' -ForegroundColor Cyan
    Write-Host "repo:    $repoRoot"
    Write-Host "commit:  $(& git rev-parse --short HEAD 2>$null)"
    Write-Host "defines: $EnvFile"

    foreach ($tool in 'flutter') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { die "$tool is required but not on PATH" }
    }
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        die "no ${EnvFile}: copy .env.example to .env, or point -EnvFile at one"
    }

    # The app talks to the *running* helper over the named pipe, and the pipe
    # exists only while the service does. A stale helper would test stale
    # protocol code, so this is a hard stop rather than a warning.
    if (-not (Test-HelperRunning)) {
        die 'the boltmeshd service is not running. Install the current helper first, from an elevated shell: pwsh -File tool/e2e/install_boltmeshd.ps1'
    }
    ok 'the boltmeshd service is running'

    if ($NoRelaunch -or (Test-InteractiveToken)) {
        $exit = Invoke-E2ERun
    }
    else {
        $exit = Invoke-InSession
    }

    if ($exit -ne 0) {
        Write-Host "`ne2e FAILED (exit $exit); artifacts in $WorkDir" -ForegroundColor Red
        exit $exit
    }
    Write-Host "`ne2e PASSED - screenshots in $shotDir" -ForegroundColor Green
}
catch {
    Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
    $script:failed = $true
}
finally {
    if ($LogFile -and $Transcript) { Stop-Transcript | Out-Null }
    Pop-Location
}

if ($failed) { exit 1 }
