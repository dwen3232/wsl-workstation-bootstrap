# =============================================================================
# WSL Workstation: Bootstrap Setup Script
# =============================================================================
# Project: WSL Workstation / Gaming PC Setup
#
# Download this repository from GitHub, then run this script from an elevated
# (Administrator) PowerShell session.
#
# See README.md in this repository for the current one-line bootstrap command.
#
# What this script does:
#   1.  Validates it is running as Administrator
#   2.  Prompts for your Tailscale auth key
#   3.  Installs WSL2 and Ubuntu 24.04 LTS
#   4.  Configures WSL2 resource limits (.wslconfig)
#   5.  Configures WSL2 systemd (wsl.conf inside the distro)
#   6.  Installs and configures Windows OpenSSH Server
#   7.  Configures sshd_config to route port 2222 into Ubuntu via ForceCommand
#   8.  Installs Tailscale via winget and authenticates with your auth key
#   9.  Creates a WSL2 keepalive scheduled task so the VM stays warm
#   10. Writes a portproxy config file and registers a refresh scheduled task
#   11. Opens required Windows Firewall ports
#
# Adding a new proxied port later:
#   Edit C:\ProgramData\ml-workstation\ports.conf - one mapping per line.
#   Supported formats: 5000 or 443:8443
#   Then run C:\ProgramData\ml-workstation\wsl-portproxy.ps1.
#   The refresh script reconciles both portproxy and firewall rules.
#
# Note on SSH architecture:
#   Tailscale secures and encrypts the network path (device-level auth).
#   Windows OpenSSH handles user auth and provides the shell session.
#   ForceCommand in sshd_config redirects port 2222 connections into WSL2.
#   A separate sshd inside WSL2 is NOT needed - Windows OpenSSH handles it all.
#
# Note on portproxy:
#   WSL2 sits behind Windows on an internal 172.x.x.x network invisible to
#   Tailscale. Services running in WSL2 must be bridged to Windows via portproxy
#   so Tailscale traffic can reach them. WSL2's internal IP changes on every
#   restart, so portproxy rules are refreshed by a scheduled task on every login.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Configuration -------------------------------------------------------------
$WSL_DISTRO   = "Ubuntu-24.04"
$SSH_PORT_WIN = 22
$SSH_PORT_WSL = 2222
$WSL_MEMORY   = "48GB"
$WSL_PROCS    = 24
$WSL_SWAP     = "16GB"
$ML_DIR       = "$env:ProgramData\ml-workstation"
$SETUP_ROOT   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# -- Helpers -------------------------------------------------------------------
function Write-Step($msg)    { Write-Host "`n>  $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "   [ok] $msg" -ForegroundColor Green }
function Write-Warn($msg)    { Write-Host "   [!] $msg" -ForegroundColor Yellow }
function Write-Info($msg)    { Write-Host "   [.] $msg" -ForegroundColor Gray }

function Install-Template {
    param(
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$Destination,
        [hashtable]$Replacements = @{}
    )

    $templatePath = Join-Path $SETUP_ROOT $TemplateName

    if (-not (Test-Path $templatePath)) {
        throw "Template not found: $templatePath"
    }

    $content = Get-Content -Path $templatePath -Raw
    foreach ($entry in $Replacements.GetEnumerator()) {
        $content = $content.Replace($entry.Key, $entry.Value)
    }

    Set-Content -Path $Destination -Value $content -Encoding UTF8
}

# -- 1. Verify Administrator ---------------------------------------------------
Write-Step "Checking privileges"

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)

if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Must be run as Administrator. Right-click PowerShell -> Run as Administrator."
    exit 1
}

Write-Success "Running as Administrator"

# -- 2. Prompt for Tailscale auth key ------------------------------------------
Write-Step "Tailscale auth key"
Write-Info "Generate a key at: https://login.tailscale.com/admin/settings/keys"
Write-Info "Settings: Reusable=No  Ephemeral=No  Pre-authorized=Yes  Tag=tag:workstation"
Write-Host ""

$TailscaleKeySecure = Read-Host "   Paste your Tailscale auth key" -AsSecureString
$TailscaleKeyBstr = [IntPtr]::Zero

try {
    $TailscaleKeyBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($TailscaleKeySecure)
    $TailscaleKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($TailscaleKeyBstr)
}
finally {
    if ($TailscaleKeyBstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($TailscaleKeyBstr)
    }
}

if ([string]::IsNullOrWhiteSpace($TailscaleKey)) {
    if ($null -ne $TailscaleKeySecure) {
        $TailscaleKeySecure.Dispose()
    }
    Write-Error "Auth key cannot be empty."
    exit 1
}

Write-Success "Auth key captured (held in memory only - never written to disk)"

# -- 3. Install WSL2 + Ubuntu 24.04 LTS ----------------------------------------
Write-Step "Installing WSL2 and $WSL_DISTRO"

$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
if ($wslFeature.State -ne "Enabled") {
    Write-Info "Enabling WSL2 feature..."
    wsl --install --no-distribution
    Write-Warn "WSL2 core installed. Reboot if prompted, then re-run this script."
} else {
    Write-Success "WSL2 feature already enabled"
}

Write-Info "Updating WSL kernel to latest..."
wsl --update | Out-Null
wsl --set-default-version 2 | Out-Null

$installedDistros = wsl --list --quiet 2>$null
if ($installedDistros -match [regex]::Escape($WSL_DISTRO)) {
    Write-Success "$WSL_DISTRO already installed"
} else {
    Write-Info "Downloading and installing $WSL_DISTRO (this may take several minutes)..."
    wsl --install -d $WSL_DISTRO
    Write-Success "$WSL_DISTRO installed"
}

wsl --set-default $WSL_DISTRO | Out-Null
Write-Success "$WSL_DISTRO set as default distro"

# -- 4. Write .wslconfig -------------------------------------------------------
Write-Step "Writing WSL2 resource config (.wslconfig)"

$wslConfigContent = @"
[wsl2]
# RAM allocated to the WSL2 VM - leave headroom for Windows and games
memory=$WSL_MEMORY

# Virtual CPU count - leave some cores for Windows
processors=$WSL_PROCS

# Swap for models that spill beyond VRAM/RAM
swap=$WSL_SWAP

# GPU passthrough for CUDA - do NOT install a separate NVIDIA driver in WSL2
gpuSupport=true
"@

Set-Content -Path "$env:USERPROFILE\.wslconfig" -Value $wslConfigContent -Encoding UTF8
Write-Success ".wslconfig written -> $env:USERPROFILE\.wslconfig"

# -- 5. Configure WSL2 internals (wsl.conf only) -------------------------------
Write-Step "Configuring WSL2 internals (wsl.conf)"

$wslConf = "[boot]`nsystemd=true`n`n[network]`ngenerateResolvConf=true`n`n[user]`ndefault=$env:USERNAME"
wsl -d $WSL_DISTRO -- bash -c "printf '%s\n' '$wslConf' | sudo tee /etc/wsl.conf > /dev/null"
Write-Success "/etc/wsl.conf written (systemd enabled)"

Write-Info "Restarting WSL2 to apply wsl.conf..."
wsl --shutdown
Start-Sleep -Seconds 4
Write-Success "WSL2 restarted"

# -- 6. Install Windows OpenSSH Server -----------------------------------------
Write-Step "Installing Windows OpenSSH Server"

$sshCap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
if ($sshCap.State -ne "Installed") {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-Success "OpenSSH Server installed"
} else {
    Write-Success "OpenSSH Server already installed"
}

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Success "sshd set to automatic and started"

# -- 7. Configure Windows sshd_config ------------------------------------------
Write-Step "Writing Windows sshd_config"

$sshdConfigWin = @"
# Windows OpenSSH Server - managed by wsl-setup.ps1
Port $SSH_PORT_WIN
Port $SSH_PORT_WSL

AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp sftp-server.exe

# Required for Windows administrator accounts
Match Group administrators
    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys

# Any connection arriving on port 2222 is forced into WSL2 Ubuntu.
# No sshd runs inside WSL2 - Windows OpenSSH handles auth entirely.
Match LocalPort $SSH_PORT_WSL
    ForceCommand C:\Windows\System32\wsl.exe -d $WSL_DISTRO --cd ~
"@

Set-Content -Path "$env:ProgramData\ssh\sshd_config" -Value $sshdConfigWin -Encoding UTF8
Restart-Service sshd
Write-Success "Windows sshd_config written and sshd restarted"

# -- 8. Install Tailscale and authenticate -------------------------------------
Write-Step "Installing Tailscale"

$tsInstalled = winget list --id Tailscale.Tailscale 2>$null | Select-String "Tailscale"
if ($tsInstalled) {
    Write-Success "Tailscale already installed"
} else {
    Write-Info "Installing via winget..."
    winget install `
        --id Tailscale.Tailscale `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements
    Write-Success "Tailscale installed"
}

Start-Sleep -Seconds 6

Write-Info "Authenticating with Tailscale..."
& "$env:ProgramFiles\Tailscale\tailscale.exe" up `
    --authkey="$TailscaleKey" `
    --hostname="$env:COMPUTERNAME"

if ($null -ne $TailscaleKeySecure) {
    $TailscaleKeySecure.Dispose()
}
$TailscaleKey = $null
$TailscaleKeySecure = $null
[System.GC]::Collect()

Write-Success "Tailscale authenticated - check https://login.tailscale.com/admin/machines"

# -- 9. WSL2 keepalive scheduled task ------------------------------------------
Write-Step "Registering WSL2 keepalive scheduled task"

New-Item -ItemType Directory -Force -Path $ML_DIR | Out-Null

$keepalivePath = Join-Path $ML_DIR "wsl-keepalive.ps1"
Install-Template -TemplateName "wsl-keepalive.ps1" -Destination $keepalivePath -Replacements @{
    "__WSL_DISTRO__" = $WSL_DISTRO
}

$taskAction   = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$keepalivePath`""
$taskTrigger  = New-ScheduledTaskTrigger -AtLogOn
$taskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "WSL2 Keepalive" `
    -TaskPath "\ML Workstation\" `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Settings $taskSettings `
    -RunLevel Highest `
    -Force | Out-Null

Start-ScheduledTask -TaskPath "\ML Workstation\" -TaskName "WSL2 Keepalive"
Write-Success "Keepalive task registered and started"

# -- 10. Portproxy config file + refresh scheduled task ------------------------
#
# Ports to proxy are stored in a plain text config file - one mapping per line.
# Comments (lines starting with #) and blank lines are ignored.
# Edit ports.conf to add or remove service mappings, then re-run the refresh task.
#
# Port 2222 (SSH) is intentionally absent - ForceCommand handles that via
# process invocation, not network forwarding, so no portproxy rule is needed.

Write-Step "Writing portproxy config and registering refresh task"

$portsConfPath = Join-Path $ML_DIR "ports.conf"

if (-not (Test-Path $portsConfPath)) {
    Install-Template -TemplateName "ports.conf" -Destination $portsConfPath
    Write-Success "ports.conf created -> $portsConfPath"
} else {
    Write-Info "ports.conf already exists - leaving it untouched"
}

$templateReplacements = @{
    "__ML_DIR__" = $ML_DIR
    "__WSL_DISTRO__" = $WSL_DISTRO
}

$portproxyPath = Join-Path $ML_DIR "wsl-portproxy.ps1"
Install-Template -TemplateName "wsl-portproxy.ps1" -Destination $portproxyPath -Replacements $templateReplacements
Write-Success "wsl-portproxy.ps1 written -> $portproxyPath"

$proxyAction  = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$portproxyPath`""

$proxyTrigger = New-ScheduledTaskTrigger -AtLogOn
$proxyTrigger.Delay = "PT10S"

$proxySettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "WSL2 Portproxy Refresh" `
    -TaskPath "\ML Workstation\" `
    -Action $proxyAction `
    -Trigger $proxyTrigger `
    -Settings $proxySettings `
    -RunLevel Highest `
    -Force | Out-Null

Write-Success "Portproxy refresh task registered (runs 10s after login)"
Write-Info "No ports proxied yet - edit ports.conf, then run .\wsl-portproxy.ps1"

$addPortPath = Join-Path $ML_DIR "wsl-add-port.ps1"
Install-Template -TemplateName "wsl-add-port.ps1" -Destination $addPortPath -Replacements $templateReplacements
Write-Success "wsl-add-port.ps1 written -> $addPortPath"

# -- 11. Firewall rules --------------------------------------------------------
#
# Only SSH ports are opened at install time. Service ports are opened and
# removed by wsl-portproxy.ps1 based on ports.conf.

Write-Step "Configuring Windows Firewall"

$rules = @(
    @{ Name = "ML Workstation: SSH (Windows)"; Port = $SSH_PORT_WIN; Desc = "Windows OpenSSH" }
    @{ Name = "ML Workstation: SSH -> WSL2";    Port = $SSH_PORT_WSL; Desc = "SSH forwarded into WSL2 Ubuntu via ForceCommand" }
)

foreach ($rule in $rules) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $rule.Name `
        -Description $rule.Desc `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $rule.Port `
        -Action Allow | Out-Null
    Write-Success "Firewall: $($rule.Name) -> port $($rule.Port)"
}

# -- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "  1. Find your MagicDNS hostname:" -ForegroundColor Gray
Write-Host "     https://login.tailscale.com/admin/machines" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. SSH into Ubuntu from your tailnet:" -ForegroundColor Gray
Write-Host "     ssh -p 2222 $env:USERNAME@<magicdns-hostname>" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Add your SSH public key to Windows authorized_keys:" -ForegroundColor Gray
Write-Host "     C:\ProgramData\ssh\administrators_authorized_keys" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Run terraform apply for Tailscale ACL + DNS" -ForegroundColor Gray
Write-Host ""
Write-Host "  5. Expose or remove WSL2 service ports (run as Admin):" -ForegroundColor Gray
Write-Host "     Edit: $ML_DIR\ports.conf" -ForegroundColor Gray
Write-Host "     Apply: $ML_DIR\wsl-portproxy.ps1" -ForegroundColor Gray
Write-Host "     Optional add helper: $ML_DIR\wsl-add-port.ps1 -Port 5000 -Name MLflow" -ForegroundColor Gray
Write-Host "     Optional remap helper: $ML_DIR\wsl-add-port.ps1 -Port 443 -ConnectPort 8443 -Name HTTPS" -ForegroundColor Gray
Write-Host ""
Write-Host "  Files written to $ML_DIR :" -ForegroundColor Gray
Write-Host "     ports.conf            - list of proxied port mappings" -ForegroundColor Gray
Write-Host "     wsl-portproxy.ps1     - reconciles portproxy + firewall rules" -ForegroundColor Gray
Write-Host "     wsl-keepalive.ps1     - keeps WSL2 VM warm at login" -ForegroundColor Gray
Write-Host "     wsl-add-port.ps1      - optional helper to append a port" -ForegroundColor Gray
Write-Host ""
Write-Host "  Scheduled tasks (\ML Workstation\ in Task Scheduler):" -ForegroundColor Gray
Write-Host "     WSL2 Keepalive         - runs at login" -ForegroundColor Gray
Write-Host "     WSL2 Portproxy Refresh - runs 10s after login" -ForegroundColor Gray
Write-Host ""
