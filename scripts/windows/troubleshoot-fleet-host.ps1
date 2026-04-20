# ============================================================
# Fleet Windows Host Troubleshooting Script
# ============================================================

$FleetHost = "fleet.example.com"  # <-- UPDATE THIS
$OrbitInstallPath = "C:\Program Files\Orbit"
$OrbitDataLogPath = "$env:SystemRoot\System32\config\systemprofile\AppData\Local\FleetDM\Orbit\Logs"
$LogTailLines = 50

function Write-Section($title) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host " $title" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Write-Result($label, $value, $ok = $null) {
    $color = if ($ok -eq $true) { "Green" } elseif ($ok -eq $false) { "Red" } else { "White" }
    Write-Host ("{0,-40} {1}" -f $label, $value) -ForegroundColor $color
}

# ------------------------------------------------------------
Write-Section "1. SERVICE STATUS"
# ------------------------------------------------------------
# Candidate service names — current and historical. Probe by both Name
# and DisplayName because installers have used different conventions.
$candidates = @("Fleet osquery", "orbit", "osqueryd", "fleetd")

$found = $candidates | ForEach-Object {
    Get-Service -Name $_ -ErrorAction SilentlyContinue
    Get-Service -DisplayName $_ -ErrorAction SilentlyContinue
} | Where-Object { $_ } | Sort-Object -Property Name -Unique

if (-not $found) {
    Write-Result "No Fleet service found:" ("Checked: " + ($candidates -join ", ")) $false
    Write-Host "  --> fleetd may not be installed on this host." -ForegroundColor Yellow
} else {
    foreach ($svc in $found) {
        $isRunning = $svc.Status -eq "Running"
        Write-Result "Service '$($svc.Name)' ($($svc.DisplayName)):" $svc.Status $isRunning
        Write-Result "  StartType:" $svc.StartType

        if (-not $isRunning) {
            Write-Host "  --> Attempting to start service '$($svc.Name)'..." -ForegroundColor Yellow
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                Write-Host "  --> Service started successfully." -ForegroundColor Green
            } catch {
                Write-Host "  --> Failed to start service: $_" -ForegroundColor Red
            }
        }
    }
}

# ------------------------------------------------------------
Write-Section "2. LOG FILES (last $LogTailLines lines)"
# ------------------------------------------------------------
$logTargets = @(
    @{ Label = "Orbit (stdout/stderr)"; Glob = "$OrbitDataLogPath\orbit-osquery*.log*" }
    @{ Label = "osqueryd results";      Glob = "$OrbitInstallPath\osquery_log\osqueryd.results*" }
    @{ Label = "osqueryd INFO";         Glob = "$OrbitInstallPath\osquery_log\osqueryd.INFO*" }
    @{ Label = "osqueryd WARNING";      Glob = "$OrbitInstallPath\osquery_log\osqueryd.WARNING*" }
    @{ Label = "osqueryd ERROR";        Glob = "$OrbitInstallPath\osquery_log\osqueryd.ERROR*" }
)

foreach ($t in $logTargets) {
    $latest = Get-ChildItem -Path $t.Glob -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Write-Host "`n--- [$($t.Label)] $($latest.FullName) ---" -ForegroundColor Yellow
        Get-Content $latest.FullName -Tail $LogTailLines
    } else {
        Write-Result "Log not found ($($t.Label)):" $t.Glob $false
    }
}

# Fleet Desktop is per-user — enumerate all user profiles.
$desktopLogs = Get-ChildItem -Path "C:\Users\*\AppData\Local\Fleet\fleet-desktop.log" `
               -ErrorAction SilentlyContinue
if ($desktopLogs) {
    foreach ($d in $desktopLogs) {
        Write-Host "`n--- [Fleet Desktop] $($d.FullName) ---" -ForegroundColor Yellow
        Get-Content $d.FullName -Tail $LogTailLines
    }
} else {
    Write-Result "Log not found (Fleet Desktop):" "C:\Users\*\AppData\Local\Fleet\fleet-desktop.log" $false
}

# ------------------------------------------------------------
Write-Section "3. FLEET SERVER CONNECTIVITY"
# ------------------------------------------------------------

# DNS resolution
Write-Host "`nDNS Resolution for '$FleetHost':" -ForegroundColor Yellow
try {
    $dns = Resolve-DnsName $FleetHost -ErrorAction Stop
    $dns | ForEach-Object { Write-Result "  Resolved:" "$($_.Name) -> $($_.IPAddress)" $true }
} catch {
    Write-Result "  DNS resolution FAILED:" $_ $false
}

# TCP connectivity on port 443
Write-Host "`nTCP Connectivity to ${FleetHost}:443:" -ForegroundColor Yellow
try {
    $tcp = Test-NetConnection -ComputerName $FleetHost -Port 443 -WarningAction SilentlyContinue
    $ok = $tcp.TcpTestSucceeded
    Write-Result "  TcpTestSucceeded:" $ok $ok
    Write-Result "  PingSucceeded:" $tcp.PingSucceeded
    Write-Result "  RemoteAddress:" $tcp.RemoteAddress
} catch {
    Write-Result "  TCP test FAILED:" $_ $false
}

# HTTPS request
Write-Host "`nHTTPS Request to Fleet server:" -ForegroundColor Yellow
try {
    $resp = Invoke-WebRequest -Uri "https://$FleetHost/api/v1/osquery/enroll" `
        -Method GET -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Result "  HTTP Status:" $resp.StatusCode $true
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode) {
        # A response was received — server is reachable (enroll endpoint returning non-200 is expected)
        Write-Result "  HTTP Status:" $statusCode $true
        Write-Host "  --> Server is reachable (non-200 on enroll endpoint is expected for GET)." -ForegroundColor Green
    } else {
        Write-Result "  HTTPS request FAILED:" $_.Exception.Message $false
        Write-Host "  --> Possible TLS/certificate issue or server unreachable." -ForegroundColor Red
    }
}


# ------------------------------------------------------------
Write-Section "4. TLS CERTIFICATE CHECK"
# ------------------------------------------------------------
Write-Host "`nChecking TLS certificate for '$FleetHost':" -ForegroundColor Yellow
try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient($FleetHost, 443)
    $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false,
        { param($s, $c, $ch, $e) $true })  # Accept all certs to inspect
    $sslStream.AuthenticateAsClient($FleetHost)
    $cert = $sslStream.RemoteCertificate
    $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cert)
    Write-Result "  Subject:"       $cert2.Subject
    Write-Result "  Issuer:"        $cert2.Issuer
    Write-Result "  Valid From:"    $cert2.NotBefore
    Write-Result "  Valid To:"      $cert2.NotAfter
    $expired = $cert2.NotAfter -lt (Get-Date)
    Write-Result "  Expired:"       $expired (-not $expired)
    $sslStream.Close()
    $tcpClient.Close()
} catch {
    Write-Result "  TLS check FAILED:" $_.Exception.Message $false
}

# ------------------------------------------------------------
Write-Section "5. FIREWALL — OUTBOUND BLOCK RULES"
# ------------------------------------------------------------
Write-Host "`nChecking for outbound BLOCK rules on port 443:" -ForegroundColor Yellow
$blockRules = Get-NetFirewallRule | Where-Object {
    $_.Direction -eq "Outbound" -and $_.Action -eq "Block" -and $_.Enabled -eq "True"
} | ForEach-Object {
    $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    [PSCustomObject]@{ Name = $_.DisplayName; RemotePort = $portFilter.RemotePort }
} | Where-Object { $_.RemotePort -eq "443" -or $_.RemotePort -eq "Any" }

if ($blockRules) {
    Write-Host "  WARNING: Found outbound block rules that may affect Fleet:" -ForegroundColor Red
    $blockRules | Format-Table -AutoSize
} else {
    Write-Result "  No outbound block rules found for port 443:" "OK" $true
}

# ------------------------------------------------------------
Write-Section "DONE"
# ------------------------------------------------------------
Write-Host "Troubleshooting complete. Review any RED items above." -ForegroundColor Cyan
