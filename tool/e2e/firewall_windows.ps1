[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('block', 'unblock', 'block-ip', 'clear')]
    [string] $Action,
    [Parameter(Position = 1)] [string] $Address,
    [Parameter(Position = 2)] [string] $Port,
    [Parameter(Position = 3)] [ValidateSet('UDP', 'TCP')] [string] $Protocol = 'UDP'
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'BoltMesh\e2e'
$root = Join-Path $root 'firewall-control'
$requestPath = Join-Path $root 'request.json'
$resultPath = Join-Path $root 'result.json'
if ($Action -ne 'clear') {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref] $parsed)) { throw 'invalid endpoint IP' }
    if ($Action -eq 'block') {
        $number = 0
        if (-not [int]::TryParse($Port, [ref] $number) -or $number -lt 1 -or $number -gt 65535) { throw "invalid $Protocol port" }
    }
}
$request = @{ action = $Action; address = $Address; port = $Port; protocol = $Protocol }
$request | ConvertTo-Json -Compress | Set-Content -LiteralPath $requestPath -Encoding UTF8
Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
$task = '\BoltMesh\E2EFirewall'
& schtasks.exe /Run /TN $task | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'could not start the installed E2E firewall task' }
$deadline = [DateTime]::UtcNow.AddSeconds(15)
while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path -LiteralPath $resultPath)) { throw 'firewall task did not finish within 15 seconds' }
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
if (-not $result.ok) { throw "firewall task failed: $($result.error)" }
