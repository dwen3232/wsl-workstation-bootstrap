# wsl-add-port.ps1 - expose a new WSL2 service to your Tailscale network
# Manual edits to ports.conf are the preferred workflow.
# This helper only appends a mapping entry and runs a refresh.
# Usage (run as Administrator):
#   .\wsl-add-port.ps1 -Port 5000
#   .\wsl-add-port.ps1 -Port 5000 -Name "MLflow"
#   .\wsl-add-port.ps1 -Port 443 -ConnectPort 8443 -Name "HTTPS"

param(
    [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
    [ValidateRange(0, 65535)][int]$ConnectPort = 0,
    [string]$Name = ""
)

$ML_DIR        = "__ML_DIR__"
$portsConfPath = Join-Path $ML_DIR "ports.conf"
$portproxyPath = Join-Path $ML_DIR "wsl-portproxy.ps1"

if (-not (Test-Path $portsConfPath)) {
    throw "ports.conf not found at $portsConfPath"
}

if ($ConnectPort -eq 0) {
    $ConnectPort = $Port
}

# Parse the listen port from each mapping so inline comments and remaps work.
$existingPorts = @(
    Get-Content $portsConfPath |
        ForEach-Object {
            if ($_ -match '^\s*(\d+)(?::(\d+))?\s*(?:#.*)?$') {
                $matches[1]
            }
        } |
        Where-Object { $_ }
)

if ($existingPorts -notcontains "$Port") {
    $mapping = if ($ConnectPort -eq $Port) { "$Port" } else { "${Port}:$ConnectPort" }
    $line = if ([string]::IsNullOrWhiteSpace($Name)) { $mapping } else { "$mapping  # $Name" }
    Add-Content -Path $portsConfPath -Value $line
    Write-Host "Added mapping $mapping to ports.conf"
} else {
    Write-Host "Port $Port already in ports.conf"
}

# Immediately refresh portproxy so the service is live without a reboot
& $portproxyPath

Write-Host "Done - port $Port now forwards to WSL port $ConnectPort"
