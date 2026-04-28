# Install the tailscale osquery extension on Windows.
#
# Run as Administrator. Expects tailscale.ext.exe next to this script unless
# a path is supplied via -BinaryPath.

[CmdletBinding()]
param(
    [string]$BinaryPath = (Join-Path $PSScriptRoot "tailscale.ext.exe")
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "install.ps1 must be run as Administrator"
}

if (-not (Test-Path $BinaryPath)) {
    throw "Binary not found at $BinaryPath"
}

$OsqueryDir     = "C:\Program Files\osquery"
$ExtensionsDir  = Join-Path $OsqueryDir "extensions"
$ExtensionsLoad = Join-Path $OsqueryDir "extensions.load"
$DestBinary     = Join-Path $ExtensionsDir "tailscale.ext.exe"

New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null

Copy-Item -Path $BinaryPath -Destination $DestBinary -Force

# Ensure extensions.load exists and includes the extension.
if (-not (Test-Path $ExtensionsLoad)) {
    New-Item -ItemType File -Path $ExtensionsLoad | Out-Null
}
$existing = Get-Content $ExtensionsLoad -ErrorAction SilentlyContinue
if ($existing -notcontains $DestBinary) {
    Add-Content -Path $ExtensionsLoad -Value $DestBinary
}

Write-Host "Installed tailscale.ext.exe to $DestBinary"
Write-Host "Registered in $ExtensionsLoad"
Write-Host "Restarting Fleet osquery service..."

Restart-Service -Name "Fleet osquery" -Force
Write-Host "Done. Query with: SELECT * FROM tailscale_status;"
