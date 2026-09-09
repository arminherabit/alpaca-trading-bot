# publish_to_share.ps1
# Copies the latest cloud-built status page to a local/UNC destination.
#
# WHY THIS EXISTS, AND WHAT IT CANNOT DO
# --------------------------------------
# The dashboard itself is built autonomously by GitHub Actions (alpaca_pages.ps1
# runs on the runner every scan and commits docs/index.html). That part needs no
# machine here.
#
# A UNC path such as \\Mike-hp\c\Users\Public\Desktop lives on a private LAN.
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
# Run it on whichever machine should own the share copy (running it on Mike-hp
# itself avoids both the cross-machine write permission and any dependence on
# the development PC).
#
# Usage:
#   pwsh ./publish_to_share.ps1
#   pwsh ./publish_to_share.ps1 -Destination 'C:\Users\Public\Desktop'
#   powershell -ExecutionPolicy Bypass -File publish_to_share.ps1   # 5.1 is fine

[CmdletBinding()]
param(
    [string]$Destination = '\\Mike-hp\c\Users\Public\Desktop',
    [string]$FileName    = "AK's Stocks Swing Trader.html",
    [string]$SourceUrl   = 'https://raw.githubusercontent.com/arminherabit/alpaca-trading-bot/master/docs/index.html'
)

$ErrorActionPreference = 'Stop'
# GitHub requires TLS 1.2; Windows PowerShell 5.1 may still default lower.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Log([string]$msg, [string]$colour = 'Gray') {
    Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor $colour
}

# ── Fetch ─────────────────────────────────────────────────────────────────────
# Cache-buster: raw.githubusercontent.com serves a CDN copy that can lag.
$url = $SourceUrl + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Write-Log "Fetching $SourceUrl"
try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
} catch {
    Write-Log "FETCH FAILED: $($_.Exception.Message)" 'Red'
    exit 1
}

$html = $resp.Content
# Sanity-check before overwriting a good copy with a login page or an error blob.
if ([string]::IsNullOrWhiteSpace($html) -or $html.Length -lt 4000 -or
    $html -notmatch 'id="payload"') {
    Write-Log ("REFUSING TO PUBLISH: fetched {0} bytes and it does not look like the dashboard." -f $html.Length) 'Red'
    exit 1
}
Write-Log ("Fetched {0:N0} bytes" -f $html.Length) 'Green'

# ── Publish ───────────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $Destination)) {
    Write-Log "DESTINATION NOT REACHABLE: $Destination" 'Red'
    exit 1
}

$target = Join-Path $Destination $FileName
$temp   = Join-Path $Destination (".{0}.tmp" -f [guid]::NewGuid().ToString('N'))

try {
    # Write to a temp name, then move over the target, so a reader never sees a
    # half-written page and a failed write never destroys the previous copy.
    [System.IO.File]::WriteAllText($temp, $html, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $target -Force
    Write-Log "Published -> $target" 'Green'
} catch {
    Write-Log "WRITE FAILED: $($_.Exception.Message)" 'Red'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    Write-Log "The account running this script needs write permission on $Destination." 'Yellow'
    exit 1
}
