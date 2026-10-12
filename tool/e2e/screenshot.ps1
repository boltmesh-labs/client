<#
.SYNOPSIS
    Captures the primary screen to a PNG, for the app e2e's screenshots.

.DESCRIPTION
    The Linux harness takes its screenshots with ImageMagick's `import`, which
    reads an X display. A Windows box has no X display and no ImageMagick on a
    stock install, so the run captures the primary screen instead: during a
    scripted run the app's window is the only thing on it.

    Best effort by contract — the Dart test reports whatever went wrong and
    carries on, so its absence costs the pictures, never the run.

.PARAMETER Path
    The PNG to write.

.EXAMPLE
    pwsh -File tool/e2e/screenshot.ps1 -Path C:\shots\01-signed-in.png
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$parent = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bounds.Size)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
