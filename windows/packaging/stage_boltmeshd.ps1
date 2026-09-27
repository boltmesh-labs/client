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

# Stamp the build metadata the Makefile injects for local builds, so an
# installed helper reports its version and commit through `boltmeshd -version`
# instead of the placeholder `dev (unknown, built unknown)`. Git metadata is
# best-effort: a source tarball or a checkout without git still builds.
$version = 'dev'
$commit = 'unknown'
if (Get-Command git -ErrorAction SilentlyContinue) {
    $described = (& git -C $repoRoot describe --tags --always --dirty 2>$null)
    if ($LASTEXITCODE -eq 0 -and $described) { $version = $described.Trim() }
    $rev = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $rev) { $commit = $rev.Trim() }
}
$buildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
# One argument: go splits the value on spaces itself.
$ldflags = "-s -w -X main.Version=$version -X main.GitCommit=$commit -X main.BuildTime=$buildTime"

# The output path must be the resolved absolute one. go build runs after
# Push-Location $helperDir, so a relative -BuildDir (as in the .EXAMPLE above)
# would write the helper into boltmeshd/<BuildDir> instead of the bundle while
# still reporting success, and the installer would then ship without it.
$output = Join-Path $buildPath 'boltmeshd.exe'
Push-Location $helperDir
try {
    & go build -trimpath -ldflags $ldflags -o $output ./cmd/boltmeshd
    if ($LASTEXITCODE -ne 0) {
        throw "go build for boltmeshd failed (exit $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

# Fail loudly rather than leave a half-staged bundle: fastforge copies the
# runner output directory verbatim, so a missing helper here means an installer
# whose privileged tunnel service cannot be installed.
if (-not (Test-Path -LiteralPath $output)) {
    throw "boltmeshd.exe was not staged into $buildPath"
}

Write-Host "Staged boltmeshd.exe into $buildPath ($version, $commit)"
