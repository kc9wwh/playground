<#
.SYNOPSIS
    Installs the SentinelOne osquery extension for Fleet.

.DESCRIPTION
    Copies the extension binary to the osquery directory, adds it to
    extensions.load, and restarts the orbit (Fleet osquery) service.

.PARAMETER BinaryPath
    Path to the extension binary (.ext.exe file).

.EXAMPLE
    .\install.ps1 -BinaryPath .\dist\sentinelone.ext_windows_amd64.exe
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath
)

$ErrorActionPreference = "Stop"

$ExtensionName  = "sentinelone.ext.exe"
$InstallDir     = "C:\Program Files\osquery"
$ExtensionsLoad = Join-Path $InstallDir "extensions.load"
$ExtensionDest  = Join-Path $InstallDir $ExtensionName

# Verify running as Administrator
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

if (-not (Test-Path $BinaryPath)) {
    Write-Error "Binary not found at: $BinaryPath"
    exit 1
}

Write-Host "==> Installing $ExtensionName..."

Copy-Item -Path $BinaryPath -Destination $ExtensionDest -Force
Write-Host "    Binary installed to $ExtensionDest"

$loadContent = ""
if (Test-Path $ExtensionsLoad) {
    $loadContent = Get-Content $ExtensionsLoad -Raw
}
if ($loadContent -notlike "*$ExtensionDest*") {
    Add-Content -Path $ExtensionsLoad -Value $ExtensionDest
    Write-Host "    Added to $ExtensionsLoad"
} else {
    Write-Host "    Already in $ExtensionsLoad"
}

Write-Host "==> Restarting orbit..."
try {
    Restart-Service -Name "Fleet osquery" -Force
} catch {
    try {
        Stop-Service -Name "orbit" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service -Name "orbit"
    } catch {
        Write-Warning "Could not restart orbit. Please restart manually."
    }
}

Write-Host ""
Write-Host "==> Done. Verify with:"
Write-Host '    orbit.exe shell'
Write-Host '    osquery> SELECT * FROM sentinelone_info;'
