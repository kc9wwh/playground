# PowerShell script to download and install Cloudflare WARP on Windows 11
# For use with Fleet MDM

# Set strict mode for better error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Define variables
$downloadUrl = "https://downloads.cloudflareclient.com/v1/download/windows/ga"
$tempDir = $env:TEMP
$installerPath = Join-Path $tempDir "Cloudflare_WARP.msi"
$organization = "your-team-name"  # Replace with your Cloudflare Zero Trust organization name

# Function to write log messages
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] $Message"
}

try {
    Write-Log "Starting Cloudflare WARP installation process..."

    # Check if running with administrator privileges
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "ERROR: This script must be run as Administrator"
        exit 1
    }

    Write-Log "Downloading Cloudflare WARP from: $downloadUrl"
    Write-Log "Download location: $installerPath"

    # Download the installer
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing

    # Verify the file was downloaded
    if (-not (Test-Path $installerPath)) {
        Write-Log "ERROR: Failed to download installer"
        exit 1
    }

    $fileSize = (Get-Item $installerPath).Length / 1MB
    Write-Log "Download complete. File size: $([math]::Round($fileSize, 2)) MB"

    # Install silently
    Write-Log "Starting silent installation with organization: $organization"
    $arguments = @(
        "/i"
        "`"$installerPath`""
        "/qn"
        "ORGANIZATION=`"$organization`""
        "/norestart"
        "/L*V"
        "`"$tempDir\CloudflareWARP_install.log`""
    )

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    # Check installation result
    if ($process.ExitCode -eq 0) {
        Write-Log "Installation completed successfully"
    } elseif ($process.ExitCode -eq 3010) {
        Write-Log "Installation completed successfully (reboot required)"
    } else {
        Write-Log "ERROR: Installation failed with exit code: $($process.ExitCode)"
        Write-Log "Check installation log at: $tempDir\CloudflareWARP_install.log"
        exit $process.ExitCode
    }

    # Verify organization configuration
    Write-Log "Verifying organization configuration..."
    $mdmXmlPath = "C:\ProgramData\Cloudflare\mdm.xml"

    # Wait a moment for the file to be created
    Start-Sleep -Seconds 2

    if (Test-Path $mdmXmlPath) {
        try {
            [xml]$mdmContent = Get-Content $mdmXmlPath

            # Parse the plist-style XML structure
            $keys = $mdmContent.dict.key
            $values = $mdmContent.dict.string

            # Find the organization key and its corresponding value
            $orgIndex = -1
            for ($i = 0; $i -lt $keys.Count; $i++) {
                if ($keys[$i] -eq "organization") {
                    $orgIndex = $i
                    break
                }
            }

            if ($orgIndex -ge 0 -and $orgIndex -lt $values.Count) {
                $configuredOrg = $values[$orgIndex]
                if ($configuredOrg -eq $organization) {
                    Write-Log "SUCCESS: Organization verified as '$configuredOrg'"
                } else {
                    Write-Log "WARNING: Organization mismatch. Expected '$organization' but found '$configuredOrg'"
                }
            } else {
                Write-Log "WARNING: Organization key not found in mdm.xml"
            }
        } catch {
            Write-Log "WARNING: Could not parse mdm.xml: $($_.Exception.Message)"
        }
    } else {
        Write-Log "WARNING: mdm.xml not found at $mdmXmlPath"
    }

    # Clean up installer file
    Write-Log "Cleaning up installer file..."
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    Write-Log "Cloudflare WARP installation process completed"
    exit 0

} catch {
    Write-Log "ERROR: An exception occurred: $($_.Exception.Message)"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"

    # Clean up on error
    if (Test-Path $installerPath) {
        Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    }

    exit 1
}
