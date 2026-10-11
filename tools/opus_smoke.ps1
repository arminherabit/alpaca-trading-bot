# tools/opus_smoke.ps1
# Read-only smoke test of the options module against the LIVE paper API and the
# Nasdaq calendar, run from GitHub Actions (workflow: opus_options_smoke.yml).
#
# Exercises the real-API paths the Pester suite mocks: Nasdaq backfill + daily
# refresh from a GitHub runner (a spec [VERIFY] item), calendar/clock/account,
# multi-symbol bars, latest trades, option contracts, indicative snapshots, and
# Sleeve A/B contract selection on real chains.
#
# Writes only to a temp directory. Never submits or cancels an order.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'opus_options.ps1') -NoRun

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('opus-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'config'), (Join-Path $tmp 'data') -Force | Out-Null
Copy-Item (Join-Path $root 'config/opus_options_config.psd1') (Join-Path $tmp 'config/')
Set-OpusRoot $tmp
$cfg = Import-PowerShellDataFile (Join-Path $tmp 'config/opus_options_config.psd1')
Set-OpusConfig $cfg
Set-OpusAlpacaConfig (Load-AlpacaConfig)

$uniSrc = Get-Content (Join-Path $root 'data/universe.json') -Raw | ConvertFrom-Json
$syms = @($uniSrc.symbols | ForEach-Object { $_.symbol })
$et = ConvertTo-OpusEt ([datetime]::UtcNow); $today = $et.ToString('yyyy-MM-dd')
Write-Host "== smoke $today ($($et.ToString('HH:mm')) ET), $($syms.Count) symbols"

# 1. Nasdaq from GitHub Actions: backfill (100 days) + daily refresh (74 days).
$sw = [Diagnostics.Stopwatch]::StartNew()
$bf = Invoke-OpusEarningsBackfill $cfg $today $syms $null ([datetime]::UtcNow.ToString('o'))
Write-Host ("== backfill: written={0} failed_days={1} no_report={2} ({3:N0}s)" -f $bf.Written, @($bf.Failed).Count, (@($bf.Missing) -join ','), $sw.Elapsed.TotalSeconds)
$sw.Restart()
$up = Update-OpusEarnings $cfg $today $syms $null ([datetime]::UtcNow.ToString('o'))
Write-Host ("== refresh: written={0} failed_days={1} ({2:N0}s)" -f $up.Written, @($up.Failed).Count, $sw.Elapsed.TotalSeconds)
$earn = Import-OpusEarnings $cfg $today
$listed = @($syms | Where-Object { (Get-OpusEarningsFor $earn $_).Next }).Count
$gate = @($syms | Where-Object { $e = Get-OpusEarningsFor $earn $_; (Test-OpusEarningsGate $today $e.Next $e.Last $cfg).Pass }).Count
Write-Host "== earnings: next date listed for $listed/$($syms.Count); earnings gate passes for $gate/$($syms.Count)"

# 2. Calendar, clock, account.
$cal = @(Get-OpusCalendar (Add-OpusDays $today -40) (Add-OpusDays $today 130))
$sessions = @($cal | ForEach-Object { ConvertTo-OpusDate $_.date } | Sort-Object)
$set = @{}; foreach ($s in $sessions) { $set[$s] = $true }
Write-Host ("== calendar: {0} sessions {1}..{2}; first date value type {3}" -f $sessions.Count, $sessions[0], $sessions[-1], $cal[0].date.GetType().Name)
$clock = Get-OpusClock; Write-Host "== clock: is_open=$($clock.is_open)"
$acct = Get-OpusAccount; Write-Host "== account: options_trading_level=$($acct.options_trading_level) options_buying_power=$($acct.options_buying_power)"

# 3. Bars + prices + RS ranking.
$raw = Get-OpusBars (@($syms) + 'SPY') (Add-OpusDays $today (-[int]$cfg.BAR_LOOKBACK_CALENDAR_DAYS))
$bars = @{}; foreach ($k in $raw.Keys) { $bars[$k] = Get-OpusCompletedBars $raw[$k] $et $null }
Write-Host ("== bars: SPY {0} completed, last {1}; min per symbol {2}" -f @($bars['SPY']).Count, $bars['SPY'][-1].Date, (($syms | ForEach-Object { @($bars[$_]).Count }) | Measure-Object -Minimum).Minimum)
$prices = Get-OpusLatestPrices (@($syms) + 'SPY')
Write-Host "== latest prices: $($prices.Count) symbols (NVDA $($prices['NVDA']), SPY $($prices['SPY']))"
$scores = @{}; foreach ($s in $syms) { $r = Get-OpusRsScore $bars[$s] $bars['SPY'] $cfg; if ($r) { $scores[$s] = $r.Score } }
$pct = Get-OpusRsPercentile $scores ([double]$cfg.RS_TOP_PCT)
Write-Host ("== RS top {0}: {1}" -f $pct[$syms[0]].K, (($pct.Keys | Where-Object { $pct[$_].Pass } | Sort-Object { $pct[$_].Rank }) -join ','))

# 4. Real chains through the selection code.
foreach ($s in 'NFLX', 'NVDA', 'MSFT', 'ORCL') {
    $ind = Get-OpusIndicators $bars[$s] $cfg; $spot = $prices[$s]
    foreach ($sl in 'A', 'B') {
        $type = if ($sl -eq 'A') { 'call' } else { 'put' }
        $dMin, $dMax, $dTg, $xD = if ($sl -eq 'A') { 38, 70, 52, 14 } else { 30, 45, 38, 10 }
        $cons = Get-OpusContracts $s $type (Add-OpusDays $today ($xD + 1)) (Add-OpusDays $today ($dMax + 35))
        $exps = @($cons | ForEach-Object { ConvertTo-OpusDate $_.expiration_date } | Sort-Object -Unique)
        $sel = Select-OpusExpiries $exps $today $dMin $dMax $dTg $xD $set $sessions[0] $sessions[-1]
        if ($sel.Expiries.Count -eq 0) { Write-Host "   $s $sl : no monthly"; continue }
        $e = $sel.Expiries[0]
        $snaps = Get-OpusChainSnapshots $s $type $e.Date
        $legs = @($cons | Where-Object { (ConvertTo-OpusDate $_.expiration_date) -eq $e.Date } | ForEach-Object { ConvertTo-OpusLeg $_ $snaps[[string]$_.symbol] $type })
        $withDelta = @($legs | Where-Object { $null -ne $_.Delta }).Count
        $r = if ($sl -eq 'A') { Select-OpusSleeveAPair $legs ([double]$spot) $cfg } else { Select-OpusSleeveBPair $legs ([double]$ind.Ema50) $cfg }
        $what = if ($r.Pair) {
            if ($sl -eq 'A') { $z = Get-OpusSizingA $r.Pair.DebitMid 5000 1.0 $cfg; "PAIR {0}/{1} debit {2:F2} -> {3}" -f $r.Pair.Long.Strike, $r.Pair.Short.Strike, $r.Pair.DebitMid, $(if ($z.Ok) { "$($z.Contracts) contract(s)" } else { $z.Reason }) }
            else { $z = Get-OpusSizingB $r.Pair.CreditMid 5 5000 1.0 $cfg; "PAIR {0}/{1} credit {2:F2} -> {3}" -f $r.Pair.Short.Strike, $r.Pair.Long.Strike, $r.Pair.CreditMid, $(if ($z.Ok) { "$($z.Contracts) contract(s)" } else { $z.Reason }) }
        } else { $r.Reason }
        Write-Host ("   {0,-5} {1} spot {2,8:F2} exp {3} ({4} DTE{5}) legs {6} (delta {7}) -> {8}" -f $s, $sl, $spot, $e.Date, $e.Dte, $(if ($sel.Fallback) { ', fallback' } else { '' }), $legs.Count, $withDelta, $what)
    }
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host "== smoke complete (no orders, nothing committed)"
