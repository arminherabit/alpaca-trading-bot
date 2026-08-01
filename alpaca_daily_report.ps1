# End-of-day report generator.
#
# Run once after the close (the daily_report.yml workflow schedules it at
# ~20:10 UTC / 4:10 PM ET, weekdays). Fetches LIVE equity + positions from
# Alpaca (the API still returns current marks after hours), reads today's
# W/L and realized P&L from state, and today's closed trades from the journal.
# Writes plain-text to alpaca_daily_report.txt (emailed by the workflow) and
# echoes it to the run log.
#
# Ownership-scoped: on the shared account, only OUR positions (identified by
# our entry-order client_order_id prefixes) are counted.

. (Join-Path $PSScriptRoot "alpaca_client.ps1")

$MY_ENTRY_PREFIXES = @("BRKOUT","PULLBK","BRKDN","RALLYF","ORB","VWAP","EMA","PYRA")

function Get-OwnedSymbolSet($cfg) {
    $owned = @{}
    $lookback = (Get-Date).ToUniversalTime().AddDays(-20).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=all&after=$lookback&direction=desc&limit=500"
    if ($null -ne $orders) {
        $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }
        foreach ($o in $arr) {
            if ($null -eq $o -or $o.status -ne "filled" -or -not $o.client_order_id) { continue }
            $tag = ($o.client_order_id -split "_")[0]
            if ($MY_ENTRY_PREFIXES -contains $tag) { $owned[$o.symbol] = $true }
        }
    }
    return $owned
}

$cfg = Load-AlpacaConfig

# Eastern date for the header
try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
$etNow  = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
$dateStr = $etNow.ToString("dddd, MMMM d, yyyy")

# Live marks
$equity = Get-Equity $cfg
$owned  = Get-OwnedSymbolSet $cfg
$allPos = @(Get-Positions $cfg)
$myPos  = @($allPos | Where-Object { $owned.ContainsKey($_.symbol) })

# Today's realized W/L from state (reset each ET day by the bot)
$statePath = Join-Path $PSScriptRoot "alpaca_state.json"
$wins = 0; $losses = 0; $pnlToday = 0.0; $eqOpen = 0.0
if (Test-Path $statePath) {
    try {
        $st = Get-Content $statePath -Raw | ConvertFrom-Json
        $wins = [int]$st.wins; $losses = [int]$st.losses
        $pnlToday = [double]$st.pnl_today; $eqOpen = [double]$st.equity_at_open
    } catch {}
}

# Today's closed trades from the journal (detail lines)
$todayCloses = @()
$journalPath = Join-Path $PSScriptRoot "alpaca_journal.json"
if (Test-Path $journalPath) {
    try {
        $jr = Get-Content $journalPath -Raw | ConvertFrom-Json
        $etToday = $etNow.ToString("yyyy-MM-dd")
        foreach ($c in @($jr.closed)) {
            if (-not $c.closed_at) { continue }
            $cET = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::Parse($c.closed_at).ToUniversalTime(), $tz).ToString("yyyy-MM-dd")
            if ($cET -eq $etToday) { $todayCloses += $c }
        }
    } catch {}
}

$unrealized = 0.0
foreach ($p in $myPos) { $unrealized += [double]$p.unrealized_pl }
$dayEquityChg = if ($eqOpen -gt 0) { $equity - $eqOpen } else { 0.0 }

# ── Build report text ──────────────────────────────────────────────────────
$L = New-Object System.Collections.Generic.List[string]
$L.Add("ALPACA SWING BOT -- Daily Report")
$L.Add($dateStr)
$L.Add(("=" * 44))
$L.Add("")
$L.Add(("Account balance (equity): `${0:N2}" -f $equity))
if ($eqOpen -gt 0) {
    $sign = if ($dayEquityChg -ge 0) { "+" } else { "-" }
    $L.Add(("Change on day:            {0}`${1:N2}" -f $sign, [Math]::Abs($dayEquityChg)))
}
$L.Add("")
$L.Add(("Today's W/L:   {0}W / {1}L" -f $wins, $losses))
$L.Add(("Realized P&L:  `${0:N2}" -f $pnlToday))
$L.Add(("Open unreal.:  `${0:N2}  ({1} position(s))" -f $unrealized, $myPos.Count))
$L.Add("")

if ($todayCloses.Count -gt 0) {
    $L.Add("Closed today:")
    foreach ($c in $todayCloses) {
        $L.Add(("  {0,-6} {1,-7} {2,-7} {3,6:+0.00;-0.00}R  `${4:N2}" -f `
            $c.symbol, $c.strategy, $c.outcome, [double]$c.r_multiple, [double]$c.pnl))
    }
    $L.Add("")
}

if ($myPos.Count -gt 0) {
    $L.Add("Open positions:")
    foreach ($p in ($myPos | Sort-Object { [double]$_.unrealized_pl } -Descending)) {
        $pl  = [double]$p.unrealized_pl
        $plp = [double]$p.unrealized_plpc * 100
        $L.Add(("  {0,-6} {1,5} sh @ `${2,-9:N2}  {3,8:+$#,##0.00;-$#,##0.00}  ({4,5:+0.00;-0.00}%)" -f `
            $p.symbol, $p.qty, [double]$p.avg_entry_price, $pl, $plp))
    }
} else {
    $L.Add("Open positions: none (flat).")
}
$L.Add("")
$L.Add("-- automated report from the Alpaca swing bot (paper trading)")

$text = ($L -join "`n")
Set-Content -Path (Join-Path $PSScriptRoot "alpaca_daily_report.txt") -Value $text -Encoding utf8
Write-Output $text
