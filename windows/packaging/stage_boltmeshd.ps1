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
