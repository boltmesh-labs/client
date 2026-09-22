<#
.SYNOPSIS
    Builds the Windows boltmeshd helper into the Flutter build bundle.

.DESCRIPTION
    Runs as the `windows-exe` fastforge pre-packing hook (see
    `client/distribute_options.yaml`). It must run before the sign hook so
    `boltmeshd.exe` is signed too, and before Inno packs the bundle so the
    installer ships the helper next to `boltmesh.exe` (and next to the
    plugin-bundled `wireguard_svc.exe` / `wireguard.dll` it drives).

    The helper is the Windows analogue of the Linux boltmeshd: it owns the
    privileged WireGuard tunnel service, so the GUI itself installs and runs
    unprivileged.

.PARAMETER BuildDir
    The Flutter release bundle (fastforge's BUILD_OUTPUT_DIRECTORY).

.EXAMPLE
    pwsh -File windows/packaging/stage_boltmeshd.ps1 -BuildDir build/windows/x64/runner/Release
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BuildDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$helperDir = Join-Path $repoRoot 'boltmeshd'

if (-not (Test-Path -LiteralPath $BuildDir)) {
    throw "Build output directory not found: $BuildDir"
}

# The Windows client ships x64-only: the bundled wireguard_flutter_plus plugin
# provides only amd64 tunnel/wireguard DLLs, so an arm64 bundle could not load
# them. Derive the target from the bundle fastforge built (e.g.
# build/windows/x64/runner/Release) and refuse anything else instead of
# silently dropping an amd64 helper into a mismatched bundle.
$buildPath = (Resolve-Path -LiteralPath $BuildDir).Path
if ($buildPath -match '(?i)[\\/]arm64([\\/]|$)') {
    throw "Windows arm64 is not supported: the bundled wireguard_flutter_plus plugin ships only amd64 tunnel/wireguard DLLs (build output: $buildPath). x64 builds run on Windows on ARM under emulation."
} elseif ($buildPath -notmatch '(?i)[\\/]x64([\\/]|$)') {
    throw "Could not determine the Windows architecture from '$buildPath'; expected a build/windows/x64/runner/... path."
}

$env:CGO_ENABLED = '0'
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'

$output = Join-Path $BuildDir 'boltmeshd.exe'
Push-Location $helperDir
try {
    & go build -trimpath -ldflags '-s -w' -o $output ./cmd/boltmeshd
    if ($LASTEXITCODE -ne 0) {
        throw "go build for boltmeshd failed (exit $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

Write-Host "Staged boltmeshd.exe into $BuildDir"
