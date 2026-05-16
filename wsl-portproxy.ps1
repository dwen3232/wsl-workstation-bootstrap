# WSL2 Portproxy Refresh - managed by wsl-setup.ps1
# Reads port mappings from ports.conf and reconciles portproxy + firewall rules,
# accounting for WSL2's dynamic internal IP changing on every restart.

$ML_DIR        = "__ML_DIR__"
$WSL_DISTRO    = "__WSL_DISTRO__"
$portsConfPath = Join-Path $ML_DIR "ports.conf"
$managedPortsPath = Join-Path $ML_DIR "managed-ports.state"

function Get-PortMappings {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @()
    }

    $mappings = @()
    $lineNumber = 0

    foreach ($line in Get-Content $Path) {
        $lineNumber++

        if ($line -match '^\s*(?:#.*)?$') {
            continue
        }

        if ($line -notmatch '^\s*(\d+)(?::(\d+))?\s*(?:#.*)?$') {
            throw "Invalid port mapping on line $lineNumber in ${Path}: $line"
        }

        $listenPort = [int]$matches[1]
        $connectPort = if ($matches[2]) { [int]$matches[2] } else { $listenPort }

        $mappings += [pscustomobject]@{
            ListenPort  = $listenPort
            ConnectPort = $connectPort
        }
    }

    $duplicates = $mappings | Group-Object ListenPort | Where-Object { $_.Count -gt 1 }
    if ($duplicates) {
        $duplicatePorts = ($duplicates | ForEach-Object { $_.Name }) -join ", "
        throw "Duplicate listen ports in ${Path}: $duplicatePorts"
    }

    return @($mappings | Sort-Object ListenPort)
}

if (-not (Test-Path $portsConfPath)) {
    Write-Warning "ports.conf not found at $portsConfPath - nothing to proxy"
    exit 0
}

# Read port mappings - strip comments and blank lines.
$mappings = Get-PortMappings -Path $portsConfPath
$ports = @($mappings | ForEach-Object { $_.ListenPort })
$previousPorts = @(Get-PortMappings -Path $managedPortsPath | ForEach-Object { $_.ListenPort })

foreach ($port in $previousPorts) {
    netsh interface portproxy delete v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$port 2>$null | Out-Null

    Remove-NetFirewallRule `
        -DisplayName "ML Workstation: Service Port $port" `
        -ErrorAction SilentlyContinue
}

if ($ports.Count -eq 0) {
    Remove-Item -Path $managedPortsPath -ErrorAction SilentlyContinue
    Write-Host "No ports defined in ports.conf - nothing to proxy"
    exit 0
}

# Resolve current WSL2 internal IP
$wslIp = (wsl -d $WSL_DISTRO hostname -I 2>$null).Trim().Split(" ")[0]

if ([string]::IsNullOrWhiteSpace($wslIp)) {
    Write-Error "Could not resolve WSL2 IP - is $WSL_DISTRO running?"
    exit 1
}

Write-Host "WSL2 IP resolved: $wslIp"

foreach ($mapping in $mappings) {
    $listenPort = $mapping.ListenPort
    $connectPort = $mapping.ConnectPort

    Remove-NetFirewallRule `
        -DisplayName "ML Workstation: Service Port $listenPort" `
        -ErrorAction SilentlyContinue

    netsh interface portproxy delete v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$listenPort 2>$null | Out-Null

    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$listenPort `
        connectaddress=$wslIp `
        connectport=$connectPort

    New-NetFirewallRule `
        -DisplayName "ML Workstation: Service Port $listenPort" `
        -Description "WSL2 service on port $listenPort -> $connectPort" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $listenPort `
        -Action Allow | Out-Null

    Write-Host "Proxied: 0.0.0.0:${listenPort} -> ${wslIp}:$connectPort"
}

Set-Content -Path $managedPortsPath -Value ($ports | ForEach-Object { "$_" }) -Encoding UTF8
