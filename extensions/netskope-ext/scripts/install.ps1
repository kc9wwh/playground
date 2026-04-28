# Installs netskope.ext.exe into Fleet's orbit-managed osquery on Windows.
# Run as Administrator. Safe to re-run.

param(
  [string]$BinarySrc = "netskope.ext.exe"
)

$ErrorActionPreference = "Stop"

$ExtDir   = "C:\Program Files\Orbit\osquery-extensions"
$LoadFile = "C:\Program Files\osquery\extensions.load"
$Target   = Join-Path $ExtDir "netskope.ext.exe"

if (-not (Test-Path $BinarySrc)) {
  Write-Error "source binary not found at $BinarySrc"
}

# Require admin.
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Error "install.ps1 must be run as Administrator"
}

New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null
Copy-Item -Force $BinarySrc $Target

$loadDir = Split-Path $LoadFile -Parent
New-Item -ItemType Directory -Force -Path $loadDir | Out-Null
if (-not (Test-Path $LoadFile)) { New-Item -ItemType File -Path $LoadFile | Out-Null }

$existing = Get-Content -Path $LoadFile -ErrorAction SilentlyContinue
if ($existing -notcontains $Target) {
  Add-Content -Path $LoadFile -Value $Target
}

# Restart Fleet's osquery service so it picks up the new extension.
$service = Get-Service -Name "Fleet osquery" -ErrorAction SilentlyContinue
if ($service) {
  Restart-Service -Name "Fleet osquery" -Force
} else {
  Write-Warning "Fleet osquery service not found — restart orbit manually"
}

Write-Output "Installed $Target and registered in $LoadFile"
