<#
.SYNOPSIS
    Runs the Windows half of the CI validation locally, in the same order.

.DESCRIPTION
    Mirrors the `validate-windows` job in .github/workflows/ci.yml, so a
    Windows-only break is caught on a Windows box instead of waiting for CI:

      1. flutter pub get --enforce-lockfile
      2. flutter build windows            (compiles the native runner,
                                          including the Windows-only
                                          windows/runner/helper_pipe.cpp)
      3. build + run helper_pipe_io_tests (the Flutter-free named-pipe
                                          transport test)
      4. go test ./... in boltmeshd/      (runs the Windows-tagged
                                          SCM/DLL-layout suites, which the
                                          Linux validate job cannot execute)
      5. assert the bundle carries the WireGuard files the helper loads from
         beside itself, and that the packaging staging hook lands the helper
         in the bundle

    The Flutter-free Dart checks (analyze, format, the test suite,
    check_generated.sh) and tool/verify_native.sh are platform-independent and
    belong to the other jobs; this script does not repeat them.

.PARAMETER Configuration
    The CMake configuration to build: Debug (default, what CI uses) or Release.

.PARAMETER SkipBuild
    Reuse the existing build/ tree. Skips step 2 only; the pipe test is still
    built and run, since it is EXCLUDE_FROM_ALL and never built by `flutter
    build` on its own.

.PARAMETER SkipPipeTest
    Skip steps 3 and 4 (the named-pipe test and the Go helper suite). Useful
    when iterating on the Dart side only.

.EXAMPLE
    pwsh -File tool/verify_windows.ps1

.EXAMPLE
    pwsh -File tool/verify_windows.ps1 -Configuration Release
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',
    [switch] $SkipBuild,
    [switch] $SkipPipeTest
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
$failed = $false

function ok([string] $message) { Write-Host "ok    $message" -ForegroundColor Green }
function skip([string] $message) { Write-Host "skip  $message" -ForegroundColor DarkGray }
function bad([string] $message) {
    Write-Host "FAIL  $message" -ForegroundColor Red
    $script:failed = $true
}

# Runs one step, reporting its own failure but never throwing: a later check
# that depends on this one reports its own skip or failure, so one broken step
# does not hide the state of the rest.
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

# cmake is on PATH in CI, but a plain developer shell often has only the copy
# Visual Studio ships (which is also the one the Flutter build itself uses).
function Resolve-Cmake {
    $onPath = Get-Command cmake -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $roots = @()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $install = & $vswhere -latest -products * -property installationPath
        if ($install) { $roots += $install }
    }
    $roots += Get-ChildItem (Join-Path $env:ProgramFiles 'Microsoft Visual Studio') `
        -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }

    # The bundled CMake sits at a fixed path under each Visual Studio edition
    # (roughly eight levels down, deeper than a bounded recursive search should
    # have to go), so try that path per root before falling back to a scan.
    $bundled = 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    foreach ($root in $roots) {
        $candidate = Join-Path $root $bundled
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($root in $roots) {
        $found = Get-ChildItem $root -Filter 'cmake.exe' -Recurse -Depth 10 `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\CMake\\bin\\cmake\.exe$' } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# Asserts that the staging hook put the helper in the bundle, given a relative
# -BuildDir. That relative form is the regression: the hook resolves the bundle
# for its architecture check but used to build the output path from the
# unresolved argument, and go build runs from boltmeshd/, so the helper landed in
# boltmeshd/<BuildDir> while the hook still reported success. fastforge would
# then pack an installer with no privileged helper at all.
function Test-StagingHook([string] $bundle) {
    $staged = Join-Path $bundle 'boltmeshd.exe'
    Remove-Item $staged -ErrorAction SilentlyContinue
    $script:stagingClean = $true
    $ran = Invoke-Step 'stage_boltmeshd.ps1 (relative -BuildDir)' {
        & (Join-Path $repoRoot 'windows\packaging\stage_boltmeshd.ps1') `
            -BuildDir 'build/windows/x64/runner/Release'
    }
    if (-not $ran) {
        bad 'the staging hook failed'
        return
    }
    if (Test-Path $staged) {
        ok "staging hook placed boltmeshd.exe in the bundle"
    }
    else {
        # Leave whatever the misplaced build produced in place: its absence in
        # boltmeshd/build/ is itself the evidence.
        $script:stagingClean = $false
        bad 'the staging hook reported success but the bundle has no boltmeshd.exe'
    }
}

try {
    Write-Host "BoltMesh Windows verification ($Configuration)" -ForegroundColor Cyan
    Write-Host "repo: $repoRoot"
    Write-Host "commit: $(& git rev-parse --short HEAD 2>$null)"

    $configLower = $Configuration.ToLowerInvariant()
    $bundleDir = Join-Path $repoRoot "build\windows\x64\runner\$configLower"
    $stagingClean = $true

    $resolved = Invoke-Step 'flutter pub get --enforce-lockfile' {
        & flutter pub get --enforce-lockfile
    }
    if (-not $resolved) { throw 'dependency resolution failed' }

    if ($SkipBuild) {
        skip "flutter build windows --$configLower (-SkipBuild)"
        if (-not (Test-Path $bundleDir)) {
            throw "-SkipBuild was given but $bundleDir does not exist"
        }
    }
    else {
        $built = Invoke-Step "flutter build windows --$configLower" {
            & flutter build windows --$configLower
        }
        if (-not $built) { throw 'the Windows build failed' }
        ok 'native runner compiled'
    }

    if ($SkipPipeTest) {
        skip 'named-pipe transport test (-SkipPipeTest)'
        skip 'boltmeshd Windows-tagged tests (-SkipPipeTest)'
    }
    else {
        # The named-pipe test is EXCLUDE_FROM_ALL (see windows/runner/
        # CMakeLists.txt), so `flutter build` never produces it: it must be
        # built by name. It links no Flutter libraries, so this works even
        # though the app itself needs a GUI toolchain.
        $cmake = Resolve-Cmake
        if (-not $cmake) {
            throw 'cmake not found on PATH and not found under Visual Studio'
        }
        Write-Host "using cmake: $cmake"

        $builtTest = Invoke-Step 'build helper_pipe_io_tests' {
            & $cmake --build (Join-Path $repoRoot 'build\windows\x64') `
                --config $Configuration --target helper_pipe_io_tests
        }
        if ($builtTest) {
            $testExe = Get-ChildItem (Join-Path $repoRoot 'build\windows') -Recurse `
                -Filter 'helper_pipe_io_tests.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $testExe) {
                bad 'helper_pipe_io_tests.exe was not built'
            }
            else {
                $ranTest = Invoke-Step 'run helper_pipe_io_tests' { & $testExe.FullName }
                if ($ranTest) { ok 'named-pipe transport test passed' }
            }
        }

        Push-Location (Join-Path $repoRoot 'boltmeshd')
        try {
            $ranGo = Invoke-Step 'boltmeshd go test ./...' { & go test ./... -count=1 }
            if ($ranGo) { ok 'Windows-tagged helper tests passed' }
        }
        finally {
            Pop-Location
        }
    }

    # The helper resolves wireguard_svc.exe and wireguard.dll from its own
    # directory, so a bundle missing them yields a helper that cannot create a
    # tunnel at all.
    foreach ($dll in 'wireguard_svc.exe', 'wireguard.dll') {
        if (Test-Path (Join-Path $bundleDir $dll)) {
            ok "bundle carries $dll"
        }
        else {
            bad "bundle is missing $dll ($bundleDir)"
        }
    }

    $releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path $releaseDir)) {
        skip 'staging hook (no Release bundle; run: flutter build windows --release)'
    }
    else {
        Test-StagingHook $releaseDir
    }
}
catch {
    Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}
finally {
    Pop-Location
}

if (-not $stagingClean) {
    Write-Host 'note: a stray boltmeshd/build/ tree is the staging regression; remove it' -ForegroundColor Yellow
}

if ($failed) {
    Write-Host "`nWindows verification FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nWindows verification passed" -ForegroundColor Green
