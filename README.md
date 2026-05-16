# WSL Workstation Bootstrap

Standalone Windows-side bootstrap for a WSL2 + Tailscale remote workstation setup.

## Layout

- `wsl-setup.ps1`: main bootstrap entrypoint
- `ports.conf`: source of truth for proxied WSL2 service port mappings
- `wsl-keepalive.ps1`: installed scheduled-task helper
- `wsl-portproxy.ps1`: installed refresh helper that reconciles portproxy and firewall rules
- `wsl-add-port.ps1`: optional helper that appends a mapping entry and runs a refresh

## Run From GitHub

Paste this into an elevated PowerShell session on the Windows host. It downloads the public repo zip, extracts it, and runs `wsl-setup.ps1`.

```powershell
$zip=Join-Path $env:TEMP 'wsl-workstation-bootstrap.zip';$dir=Join-Path $env:TEMP ('wsl-workstation-bootstrap-' + [guid]::NewGuid().ToString('n'));Invoke-WebRequest -Uri 'https://github.com/dwen3232/wsl-workstation-bootstrap/archive/refs/heads/main.zip' -OutFile $zip;Expand-Archive -Path $zip -DestinationPath $dir;$root=Get-ChildItem $dir -Directory | Select-Object -First 1;& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root.FullName 'wsl-setup.ps1')
```

This uses PowerShell's built-in `Invoke-WebRequest` plus GitHub's standard source archive URL. No API recursion or per-file download step is needed.

GitHub archive docs:
- https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives

## Validation

Local validation uses PowerShell's own parser.

Install PowerShell on macOS:

```bash
brew install powershell
```

Run validation:

```bash
./validate-ps1.sh
```

## Managing Ports

Preferred workflow:

1. Edit `C:\ProgramData\ml-workstation\ports.conf`
2. Add or remove one mapping per line
3. Run `C:\ProgramData\ml-workstation\wsl-portproxy.ps1`

Example:

```text
# SSH to WSL already exists on 2222 via Windows OpenSSH ForceCommand
5000  # MLflow
8080  # W&B
8888  # Jupyter
443:8443  # listen on 443, forward to 8443 in WSL
```

`wsl-portproxy.ps1` treats `ports.conf` as the source of truth and reconciles both portproxy and Windows Firewall rules to match it.

SSH is the exception: WSL shell access already exists on port `2222` via Windows OpenSSH `ForceCommand`, so `2222` should not be added to `ports.conf`.

Supported formats:

- `5000`: listen on `5000`, forward to `5000` in WSL
- `443:8443`: listen on `443`, forward to `8443` in WSL
