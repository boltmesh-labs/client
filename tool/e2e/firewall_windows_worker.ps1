$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'BoltMesh\e2e'
$root = Join-Path $root 'firewall-control'
$requestPath = Join-Path $root 'request.json'
$resultPath = Join-Path $root 'result.json'
try {
    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
    $group = 'BoltMesh E2E temporary endpoint blocks'
    switch ($request.action) {
        'clear' {
            Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        }
        'block-ip' {
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse([string]$request.address, [ref]$ip)) { throw 'invalid endpoint IP' }
            $name = 'BoltMeshE2E-' + $ip.ToString().Replace(':', '-') + '-ALL'
            Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            New-NetFirewallRule -Name $name -DisplayName $name -Group $group `
                -Direction Outbound -Action Block -Protocol Any -RemoteAddress $ip.ToString() `
                -Profile Any | Out-Null
        }
        { $_ -in 'block', 'unblock' } {
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse([string]$request.address, [ref]$ip)) { throw 'invalid endpoint IP' }
            $port = 0
            if (-not [int]::TryParse([string]$request.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'invalid port' }
            $protocol = if ($request.protocol -in @('UDP', 'TCP')) { $request.protocol } else { 'UDP' }
            $name = 'BoltMeshE2E-' + $ip.ToString().Replace(':', '-') + '-' + $protocol + '-' + $port
            if ($request.action -eq 'block') {
                Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
                New-NetFirewallRule -Name $name -DisplayName $name -Group $group `
                    -Direction Outbound -Action Block -Protocol $protocol -RemoteAddress $ip.ToString() `
                    -RemotePort $port -Profile Any | Out-Null
            } else {
                Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            }
        }
        default { throw 'unsupported firewall operation' }
    }
    @{ ok = $true } | ConvertTo-Json -Compress | Set-Content -LiteralPath $resultPath -Encoding UTF8
} catch {
    @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress | Set-Content -LiteralPath $resultPath -Encoding UTF8
    exit 1
}
