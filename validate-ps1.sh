#!/bin/zsh
set -euo pipefail

pwsh -NoLogo -NoProfile -Command '
  $files = Get-ChildItem -Path . -Filter *.ps1 -File
  $failed = $false
  foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
      $failed = $true
      Write-Host "FILE: $($file.Name)"
      $errors | ForEach-Object {
        Write-Host ("  {0}:{1} {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message)
      }
    } else {
      Write-Host "OK: $($file.Name)"
    }
  }
  if ($failed) { exit 1 }
'
