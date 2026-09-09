# publish_to_share.ps1
# Copies the latest cloud-built status page to a local/UNC destination.
#
# WHY THIS EXISTS, AND WHAT IT CANNOT DO
# --------------------------------------
# The dashboard itself is built autonomously by GitHub Actions (alpaca_pages.ps1
# runs on the runner every scan and commits docs/index.html). That part needs no
# machine here.
#
# A UNC path such as \\Mike-hp\Users\Public\Desktop lives on a private LAN.
# A GitHub-hosted runner cannot reach it -- there is no route from GitHub's cloud
# to that share, and no amount of workflow configuration creates one. So the last
# hop, cloud -> share, must be performed by some machine ON that network.
#
# This script is that last hop, and it is deliberately thin: it fetches the page
# that the cloud already built and writes it to $Destination. It holds no API
# keys, needs no repo checkout, and does not run the bot. If the machine running
# it is off, only the copy on the share goes stale -- the bot keeps trading and
# the cloud page keeps updating.
#
# POWERSHELL 2.0 COMPATIBLE. Mike-hp runs PowerShell 2.0 (Windows 7 era), so
# this file deliberately avoids anything from 3.0+:
#   - System.Net.WebClient, not Invoke-WebRequest (3.0+)
#   - manual epoch arithmetic, not ToUnixTimeSeconds() (.NET 4.6+)
#   - no ScheduledTasks module, no -LiteralPath on Move-Item
# Do not "modernise" these without checking what Mike-hp actually has.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File publish_to_share.ps1
#   powershell -ExecutionPolicy Bypass -File publish_to_share.ps1 -Destination 'C:\Users\Public\Desktop'

param(
    # NOTE the share name: \\Mike-hp\Users, NOT \\Mike-hp\c. Both resolve to the
    # same folder on disk, but the "C" share is read-only at the SHARE level, so
    # every write through it is denied regardless of the NTFS permissions on the
    # folder. Reached via "Users" the same Desktop is writable.
    # On Mike-hp itself, pass the local path instead: C:\Users\Public\Desktop
    [string]$Destination = '\\Mike-hp\Users\Public\Desktop',
    [string]$FileName    = "AK's Stocks Swing Trader.html",
    [string]$SourceUrl   = 'https://raw.githubusercontent.com/arminherabit/alpaca-trading-bot/master/docs/index.html'
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg, [string]$colour = 'Gray') {
    Write-Host ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg) -ForegroundColor $colour
}

# ── TLS ───────────────────────────────────────────────────────────────────────
# GitHub requires TLS 1.2. On .NET 4.5+ that is SecurityProtocolType.Tls12; on
# older frameworks the enum member does not exist, so the numeric value (3072)
# is used directly. If the framework genuinely cannot do TLS 1.2 this still
# fails, but at the connection, with a clearer message than an enum error.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch {
    Write-Log "Could not enable TLS 1.2 ($($_.Exception.Message)); trying anyway." 'Yellow'
}

# ── Fetch ─────────────────────────────────────────────────────────────────────
# Cache-buster: raw.githubusercontent.com serves a CDN copy that can lag.
$epoch = [int][double]((Get-Date).ToUniversalTime() - (New-Object DateTime(1970,1,1))).TotalSeconds
$url   = $SourceUrl + '?t=' + $epoch

Write-Log "Fetching $SourceUrl"
$html = $null
try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    # A default-less proxy call is what fails first on locked-down machines.
    $wc.Headers.Add('User-Agent', 'alpaca-dashboard-publisher')
    $html = $wc.DownloadString($url)
} catch {
    Write-Log "FETCH FAILED: $($_.Exception.Message)" 'Red'
    if ($_.Exception.InnerException) {
        Write-Log "  inner: $($_.Exception.InnerException.Message)" 'Red'
    }
    Write-Log "  (a TLS error here means this machine cannot negotiate TLS 1.2 with GitHub)" 'Yellow'
    exit 1
} finally {
    if ($wc) { $wc.Dispose() }
}

# Sanity-check before overwriting a good copy with a login page or an error blob.
if ([string]::IsNullOrEmpty($html) -or $html.Length -lt 4000 -or $html -notmatch 'id="payload"') {
    Write-Log ("REFUSING TO PUBLISH: fetched {0} bytes and it does not look like the dashboard." -f $html.Length) 'Red'
    exit 1
}
Write-Log ("Fetched {0} bytes" -f $html.Length) 'Green'

# ── Publish ───────────────────────────────────────────────────────────────────
if (-not (Test-Path $Destination)) {
    Write-Log "DESTINATION NOT REACHABLE: $Destination" 'Red'
    exit 1
}

$target = Join-Path $Destination $FileName
$temp   = Join-Path $Destination ("." + [guid]::NewGuid().ToString('N') + ".tmp")

try {
    # Write to a temp name, then move over the target, so a reader never sees a
    # half-written page and a failed write never destroys the previous copy.
    [System.IO.File]::WriteAllText($temp, $html, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $target) { Remove-Item $target -Force }
    Move-Item $temp $target -Force
    Write-Log "Published -> $target" 'Green'
} catch {
    Write-Log "WRITE FAILED: $($_.Exception.Message)" 'Red'
    if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    Write-Log "The account running this script needs write permission on $Destination." 'Yellow'
    exit 1
}
