<#
.SYNOPSIS
    Builds the privileged boltmeshd helper from source and installs it (elevated).

.DESCRIPTION
    The Windows twin of `tool/e2e/install_boltmeshd.sh`. The app e2e must
    exercise the helper the current tree builds, not a stale one left behind by
    an installer, and this is the only part of the Windows e2e that needs
    elevation.

    What it does, in order:

      1. builds boltmeshd.exe from boltmeshd/ with the local Go toolchain;
      2. stages it in a stable directory, together with the three binaries the
         helper loads from beside itself — wintun.dll (the obfuscated rung's
         data plane), wireguard_svc.exe and wireguard.dll (the WireGuard-for-
         Windows data plane);
      3. runs `boltmeshd.exe -install`, which registers the boltmeshd service
         and starts it;
      4. proves the pipe answers, so a run cannot start against a helper that
         installed but cannot serve.

    The service registration is what the app's own transport authenticates
    against: the named pipe's server process must be the one the SCM reports
    for the boltmeshd service (see windows/runner/helper_pipe_io.cpp), so a
    helper started any other way — `-console`, say — is refused by the app
    even though its pipe exists. This script never starts the helper by hand.

    Unlike Linux's systemd socket unit, a Windows named pipe exists only while
    its server runs, so a stopped boltmeshd is a helper the app cannot reach at
    all rather than one that comes back on demand. Re-running this script is
    the supported way to refresh it: `-install` repoints the registration at
    the new executable and restarts the service.

.PARAMETER InstallDir
    Where the helper is staged. Deliberately not the program-files install
    directory, so a lab run cannot overwrite a real install's binary.

.EXAMPLE
    pwsh -File tool/e2e/install_boltmeshd.ps1
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:ProgramData 'BoltMesh\e2e')
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $repoRoot
$failed = $false

function ok([string] $message) { Write-Host "ok    $message" -ForegroundColor Green }
function skip([string] $message) { Write-Host "skip  $message" -ForegroundColor DarkGray }
function bad([string] $message) {
    Write-Host "FAIL  $message" -ForegroundColor Red
    $script:failed = $true
}

# Runs one step, reporting its own failure but never throwing: a later check
# that depends on it reports its own failure, so one broken step does not hide
# the state of the rest.
function Invoke-Step([string] $name, [scriptblock] $action) {
    Write-Host "`n==> $name" -ForegroundColor Cyan
    & $action
    $code = $LASTEXITCODE
    if ($null -ne $code -and $code -ne 0) {
        bad "$name (exit $code)"
        return $false
    }
    return $true
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs a native command and returns its exit code.
#
# Needed because this script runs with $ErrorActionPreference = 'Stop', and
# Windows PowerShell 5.1 turns a native command's *stderr* into a terminating
# error when it is captured. `go build` writes failures there, and the probe
# below captures a Python command's output, so without this a tool's own
# message would abort the install in place of the real failure.
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

try {
    Write-Host 'BoltMesh e2e helper install (Windows)' -ForegroundColor Cyan
    Write-Host "repo:    $repoRoot"
    Write-Host "commit:  $(& git rev-parse --short HEAD 2>$null)"
    Write-Host "target:  $InstallDir"

    # Everything below - creating the service, taking ownership of the config
    # directory, pinning the Wintun driver into System32 on the first
    # obfuscated connect - needs a token with the privileges enabled, so a
    # filtered (non-elevated) administrator token is refused here rather than
    # half-installing.
    if (-not (Test-Elevated)) {
        throw 'install_boltmeshd.ps1 must run elevated: it registers the boltmeshd service and owns the privileged config directory.'
    }

    $go = Get-Command go -ErrorAction SilentlyContinue
    if (-not $go) { throw 'go is required but not on PATH' }

    # --- the helper directory -------------------------------------------------
    # The daemon resolves wintun.dll and wireguard_svc.exe from its own
    # directory, so all four files must land here together. The parent
    # (%ProgramData%\BoltMesh) is the daemon's own config directory, whose ACL
    # it protects to SYSTEM + Administrators on every install - which also
    # means this directory is not world-readable, and need not be: only the
    # LocalSystem helper and the installer ever open these files.
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $helper = Join-Path $InstallDir 'boltmeshd.exe'

    $built = Invoke-Step 'build boltmeshd.exe from source' {
        # The Go module is boltmeshd/, exactly where the Linux installer runs
        # `go build` from; an absolute -o keeps the output out of the module.
        Push-Location (Join-Path $repoRoot 'boltmeshd')
        try {
            $env:CGO_ENABLED = '0'
            Invoke-Native { & go build -trimpath -o $helper ./cmd/boltmeshd } | Out-Null
        }
        finally {
            Pop-Location
        }
    }
    if (-not $built) { throw 'the helper build failed' }

    # --- the files the helper loads from beside itself -----------------------
    $wintunSource = Join-Path $repoRoot 'boltmeshd\internal\tunnel\third_party\wintun\wintun.dll'
    if (-not (Test-Path -LiteralPath $wintunSource -PathType Leaf)) {
        throw "vendored wintun.dll missing at $wintunSource; the obfuscated rung needs it beside the helper"
    }
    Copy-Item -LiteralPath $wintunSource -Destination $InstallDir -Force

    # The WireGuard-for-Windows data plane comes from the plugin the app
    # itself is built against, so it is the same bits the shipped bundle
    # carries. `flutter pub get` links the plugin into windows/flutter
    # (ephemeral); the built bundle is the fallback when that tree is gone.
    $plugin = Join-Path $repoRoot 'windows\flutter\ephemeral\.plugin_symlinks\wireguard_flutter_plus\windows\lib'
    $runtimeSources = [ordered]@{
        'wireguard_svc.exe' = Join-Path $plugin 'wireguard_svc\amd64\wireguard_svc.exe'
        'wireguard.dll'     = Join-Path $plugin 'wireguard\amd64\wireguard.dll'
    }
    $bundle = Join-Path $repoRoot 'build\windows\x64\runner\Debug'
    foreach ($file in $runtimeSources.Keys) {
        $source = $runtimeSources[$file]
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $source = Join-Path $bundle $file
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "$file not found beside the plugin or in $bundle. Run 'flutter pub get' (or 'flutter build windows --debug') first."
            }
        }
        Copy-Item -LiteralPath $source -Destination $InstallDir -Force
    }
    ok "staged boltmeshd.exe, wintun.dll, wireguard_svc.exe, wireguard.dll in $InstallDir"

    # --- install and start the service --------------------------------------
    $installed = Invoke-Step 'boltmeshd.exe -install' {
        Invoke-Native { & $helper -install } | Out-Null
    }
    if (-not $installed) { throw 'the helper could not install its service' }

    # A registration that exists but is stopped installs fine and serves
    # nothing, so the state is checked rather than -install's exit code.
    Start-Sleep -Seconds 1
    $state = (& sc.exe query boltmeshd | Select-String -SimpleMatch 'STATE').Line
    if ("$state" -notmatch 'RUNNING') {
        throw "the boltmeshd service is not running (sc.exe reports: $state). See $env:ProgramData\BoltMesh\logs\boltmeshd.log"
    }
    ok 'the boltmeshd service is running'

    # --- the pipe answers ----------------------------------------------------
    # The real proof that the app can talk to it: a pipe that exists but
    # refuses this user, or a registration pointing at some other binary,
    # both fail here rather than in the middle of a ladder walk.
    $client = Join-Path $repoRoot 'tool\e2e\client.py'
    $pipe = '\\.\pipe\boltmesh\boltmeshd'
    $python = $env:BOLTMESH_E2E_PYTHON
    if (-not $python) { $python = (Get-Command python -ErrorAction SilentlyContinue).Source }
    if (-not $python) {
        skip "no python on PATH, so the pipe was not exercised end to end (set BOLTMESH_E2E_PYTHON, or use a pipe client). The service is running."
    }
    else {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $answer = (& $python $client --pipe $pipe --status 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $saved
        }
        if ($code -ne 0) {
            throw "the helper did not answer on $pipe (exit $code): $answer. The service is running, so this is an access or registration problem."
        }
        ok "the helper answered on the pipe: $answer"
    }

    Write-Host "`nHelper installed; run the e2e with:`n  pwsh -File tool/e2e/run_windows_app.ps1" -ForegroundColor Green
}
catch {
    Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}
finally {
    Pop-Location
}

if ($failed) {
    Write-Host "`nHelper install FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nHelper install passed" -ForegroundColor Green
