<#
.SYNOPSIS
    Builds the Windows boltmeshd helper into the Flutter build bundle.

.DESCRIPTION
    Runs as the `windows-exe` fastforge pre-packing hook (see
    `client/distribute_options.yaml`). It must run before the sign hook so
    `boltmeshd.exe` is signed too, and before Inno packs the bundle so the
    installer ships the helper next to `boltmesh.exe` (and next to the
    plugin-bundled `wireguard_svc.exe` / `wireguard.dll` it drives).

    It also stages the vendored `wintun.dll` beside the helper, which is what
    the obfuscated (AmneziaWG) data plane pins into System32 before loading.
    The Inno `[Files]` wildcard ships whatever is in the bundle, so anything
    this hook does not put there is not in the installer.

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
# Build to a scratch name and move it into place. `go build -o` cannot replace a
# file that is currently executing: when the helper service is running from this
# very bundle, go writes boltmeshd.exe~, fails to swap it in, and exits 0. The
# bundle would then keep the *old* helper while this hook reported success, and
# the installer would ship a stale privileged binary. Building aside and
# verifying the final content closes that hole.
$staged = Join-Path $buildPath 'boltmeshd.staging.exe'
Push-Location $helperDir
try {
    & go build -trimpath -ldflags $ldflags -o $staged ./cmd/boltmeshd
    if ($LASTEXITCODE -ne 0) {
        throw "go build for boltmeshd failed (exit $LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $staged)) {
    throw "go build did not produce $staged"
}

# Leftovers from an earlier locked build. They are not in [Files]'s intent and
# would ship into %ProgramFiles%\BoltMesh as a second privileged binary.
Get-ChildItem -Path $buildPath -Filter 'boltmeshd.exe~' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

try {
    Move-Item -LiteralPath $staged -Destination $output -Force -ErrorAction Stop
}
catch {
    # Never leave the scratch build behind: the bundle is copied verbatim into
    # the installer, so a leftover here would ship as a second helper binary.
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    throw "could not replace $output. If the boltmeshd service is running from this bundle, stop it first (sc stop boltmeshd); Windows will not let a running image be overwritten, and shipping the previous helper would be worse than failing. Underlying error: $($_.Exception.Message)"
}

# The AmneziaWG data plane needs the Wintun L3 TUN driver, because the
# WireGuard-for-Windows kernel service has no concept of the obfuscation
# directives an obfuscated region requires. Nothing embeds it:
# golang.zx2c4.com/wintun resolves the DLL by bare name at first use, so it has
# to be a file on disk. The helper does not trust what sits beside it -- it
# verifies a pinned hash and copies the driver into System32 before that load
# (see boltmeshd/internal/tunnel/wintun_windows.go) -- but it reads the reviewed
# binary from the helper's own directory, so this hook is the only place it can
# enter the bundle. Without it an installed client fails every obfuscated
# connect with "vendored wintun.dll is unreadable at <install dir>\wintun.dll",
# while a stock region's WireGuard-for-Windows path keeps working, which is what
# makes the gap easy to miss.
#
# Not signed, deliberately. sign.ps1 selects *.exe, and re-signing would rewrite
# the bytes and break wintunSHA256 -- the hash pin is this driver's trust
# mechanism, not its (counter-signed, long-expired) Authenticode signature.
$wintunName = 'wintun.dll'
$wintunSource = Join-Path $repoRoot "boltmeshd/internal/tunnel/third_party/wintun/$wintunName"
if (-not (Test-Path -LiteralPath $wintunSource -PathType Leaf)) {
    throw "The vendored Wintun driver is missing: $wintunSource. It is committed under boltmeshd/internal/tunnel/third_party/wintun (see its README.md) and must ship beside boltmeshd.exe, because the helper pins it into System32 by hash before loading it. Refusing to pack a bundle whose obfuscated data plane could not start."
}

# Replace it the same way as the helper: aside first, then move. The service
# running from this bundle keeps wintun.dll mapped for the life of the process,
# so overwriting it in place fails; the installer's PrepareToInstall stops the
# helper before the file copy, which is what makes an upgrade get this far.
$wintunOutput = Join-Path $buildPath $wintunName
$wintunStaged = Join-Path $buildPath 'wintun.staging.dll'
Get-ChildItem -Path $buildPath -Filter 'wintun.staging.dll' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

try {
    Copy-Item -LiteralPath $wintunSource -Destination $wintunStaged -Force -ErrorAction Stop
    Move-Item -LiteralPath $wintunStaged -Destination $wintunOutput -Force -ErrorAction Stop
}
catch {
    # A leftover here would ship into %ProgramFiles%\BoltMesh next to the
    # reviewed driver, so it is removed whatever went wrong.
    Remove-Item -LiteralPath $wintunStaged -Force -ErrorAction SilentlyContinue
    throw "could not stage $wintunOutput from $wintunSource. If the boltmeshd service is running from this bundle, stop it first (sc stop boltmeshd); Windows will not let a mapped image be overwritten. Underlying error: $($_.Exception.Message)"
}

# The installed helper is what `boltmeshd -version` reports, so report enough to
# spot a stale one by eye too.
$onDisk = Get-Item -LiteralPath $output
$onDiskWintun = Get-Item -LiteralPath $wintunOutput
Write-Host "Staged boltmeshd.exe into $buildPath ($version, $commit, $($onDisk.Length) bytes)"
Write-Host "Staged $wintunName beside it ($($onDiskWintun.Length) bytes, hash-pinned into System32 on first obfuscated connect)"
