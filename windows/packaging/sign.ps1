<#
.SYNOPSIS
    Authenticode-signs BoltMesh Windows artifacts (app exe, installer).

.DESCRIPTION
    Called by the `windows-exe` fastforge job (`hooks.pre` signs the freshly
    built app exe, `hooks.post` signs the installer) and usable by hand.

    Configuration comes from the environment (or the matching parameters):

      WINDOWS_CERTIFICATE_PATH      Path to a .pfx. In CI this file is decoded
                                    from the WINDOWS_CERTIFICATE repo secret.
      WINDOWS_CERTIFICATE_PASSWORD  Password for that .pfx.
      WINDOWS_TIMESTAMP_URL         RFC 3161 timestamp server (default:
                                    http://timestamp.digicert.com).

    When WINDOWS_CERTIFICATE_PATH is unset the script warns and skips, so
    unsigned local builds keep working. A set-but-missing file is an error
    (that means a broken CI secret, not "no certificate").

    Cloud/HSM certificates (EV tokens, Azure Trusted Signing, DigiCert
    KeyLocker, SSL.com eSigner) cannot be exported to a .pfx; swap the
    `signtool sign` invocation below for the provider's action/CLI. See
    `client/README.md`.

.PARAMETER Path
    Files to sign. Directories are searched recursively for *.exe.

.PARAMETER Require
    Fail instead of skipping when no certificate is configured.

.PARAMETER SkipVerify
    Skip the post-sign `signtool verify` check. Needed when testing with an
    untrusted self-signed certificate, whose chain `verify /pa` rejects.

.EXAMPLE
    pwsh -File windows/packaging/sign.ps1 -Path build/windows/x64/runner/Release/boltmesh.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Path,

    [string] $CertificatePath = $env:WINDOWS_CERTIFICATE_PATH,
    [string] $CertificatePassword = $env:WINDOWS_CERTIFICATE_PASSWORD,
    [string] $TimestampUrl = $env:WINDOWS_TIMESTAMP_URL,

    [switch] $Require,
    [switch] $SkipVerify
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
    $TimestampUrl = 'http://timestamp.digicert.com'
}

function Resolve-SignTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $kitsBase = ${env:ProgramFiles(x86)}
    if ($kitsBase) {
        $kitsRoot = Join-Path $kitsBase 'Windows Kits\10\bin'
        if (Test-Path -LiteralPath $kitsRoot) {
            $candidates = Get-ChildItem -LiteralPath $kitsRoot -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
                Where-Object { Test-Path -LiteralPath $_ }
            if ($candidates) { return $candidates[0] }
        }
    }

    throw 'signtool.exe not found. Install the Windows SDK (Visual Studio component "Windows SDK for Desktop C++").'
}

# Expand directories to their *.exe contents; keep files as-is.
$targets = foreach ($item in $Path) {
    if (Test-Path -LiteralPath $item -PathType Container) {
        Get-ChildItem -LiteralPath $item -Recurse -File -Filter '*.exe'
    } else {
        Get-Item -LiteralPath $item
    }
}
$targets = @($targets | Where-Object { $_.Extension -ieq '.exe' } | Sort-Object FullName -Unique)

if ($targets.Count -eq 0) {
    throw "No .exe found to sign in: $($Path -join ', ')"
}

if ([string]::IsNullOrWhiteSpace($CertificatePath)) {
    if ($Require) {
        throw 'No signing certificate configured (WINDOWS_CERTIFICATE_PATH); refusing to produce an unsigned release.'
    }
    Write-Warning "No signing certificate configured; leaving $($targets.Count) file(s) unsigned."
    return
}
if (-not (Test-Path -LiteralPath $CertificatePath)) {
    throw "Signing certificate not found: $CertificatePath"
}

$signTool = Resolve-SignTool
$signed = 0
foreach ($target in $targets) {
    Write-Host "Signing $($target.FullName)"

    $signArgs = @('sign', '/fd', 'SHA256', '/f', $CertificatePath)
    if (-not [string]::IsNullOrEmpty($CertificatePassword)) {
        $signArgs += @('/p', $CertificatePassword)
    }
    $signArgs += @('/tr', $TimestampUrl, '/td', 'SHA256', '/d', 'BoltMesh', $target.FullName)

    & $signTool @signArgs
    if ($LASTEXITCODE -ne 0) {
        throw "signtool sign failed for $($target.FullName) (exit $LASTEXITCODE)"
    }
    if (-not $SkipVerify) {
        & $signTool verify /pa /q $target.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "signtool verify failed for $($target.FullName) (exit $LASTEXITCODE)"
        }
    }
    $signed++
}

Write-Host "Signed $signed file(s) with $TimestampUrl."
