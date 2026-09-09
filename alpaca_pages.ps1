# alpaca_pages.ps1
# Builds docs/index.html -- the public status dashboard served by GitHub Pages.
#
# Runs entirely on the GitHub Actions runner as a workflow step: it reads the
# live account from Alpaca, the journal and the equity history from the repo,
# injects one JSON blob into docs/_template.html and writes docs/index.html,
# which the workflow commits. NOTHING here depends on a developer machine.
#
# The template is a separate file on purpose. Building HTML inside a PowerShell
# here-string means every JS `${...}` placeholder is eaten by string
# interpolation (that bug shipped once already, in the old dashboard); a
# placeholder swap has no such failure mode and the template can be opened in
# a browser on its own.
#
# Usage:
#   pwsh ./alpaca_pages.ps1

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_journal.ps1")
. (Join-Path $PSScriptRoot "alpaca_screener.ps1")   # $MY_ENTRY_PREFIXES
. (Join-Path $PSScriptRoot "alpaca_regime.ps1")     # Get-SwingRegime

$cfg          = Load-AlpacaConfig
$TemplatePath = Join-Path $PSScriptRoot "pages_template.html"   # kept OUT of docs/ so Pages never serves it
$OutFile      = Join-Path $PSScriptRoot "docs/index.html"
$HistPath     = Join-Path $PSScriptRoot "alpaca_equity_history.json"
$START_EQUITY = 100000.0

Write-Host "Building Pages dashboard..." -ForegroundColor Cyan

$acct  = Get-Account $cfg
if ($null -eq $acct) { Write-Host "  No account data -- aborting, keeping last published page." -ForegroundColor Red; exit 0 }
$equity = [double]$acct.equity
$lastEq = if ($acct.last_equity) { [double]$acct.last_equity } else { $equity }

# ── Equity history ────────────────────────────────────────────────────────────
# A committed, append-only daily series. Upserting today's value on every scan
# means the last write of the session wins, so each entry is that day's close.
# Self-contained by design: no dependence on Alpaca's portfolio-history
# retention, and the curve survives even if the API is unavailable.
#
# ConvertFrom-Json does NOT enumerate an array onto the pipeline -- it writes the
# whole array as ONE object. So `@(Get-Content ... | ConvertFrom-Json)` yields a
# 1-element array holding all 98 days, and the history silently collapses to a
# single point. Assign first, wrap second.
$parsed = $null
if (Test-Path $HistPath) {
    try { $parsed = ConvertFrom-Json (Get-Content $HistPath -Raw) } catch { $parsed = $null }
}
$hist = if ($null -eq $parsed) { @() } else { @($parsed) }

$today = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$hist  = @($hist | Where-Object { $null -ne $_ -and $_.d -and $_.d -ne $today })
$hist += [pscustomobject]@{ d = $today; e = [Math]::Round($equity, 2) }
$hist  = @($hist | Sort-Object { [string]$_.d })

# Refuse to shrink the record. If anything above went wrong, keep the file we
# have rather than overwriting a long history with a stub.
$priorCount = if ($null -eq $parsed) { 0 } else { @($parsed).Count }
if ($hist.Count -ge $priorCount) {
    # -InputObject (not the pipeline) so a single-day history still serialises
    # as a JSON array rather than a bare object.
    ConvertTo-Json -InputObject @($hist) -Depth 3 -Compress | Set-Content $HistPath -Encoding UTF8
} else {
    Write-Host ("  Equity history would shrink {0} -> {1}; keeping existing file." -f $priorCount, $hist.Count) -ForegroundColor Red
    $hist = @($parsed)
}
# Named fields, not nested arrays: Windows PowerShell serialises an array
# nested inside another object as {"value":[...],"Count":n}, which silently
# turns every data point into an object the chart cannot read.
$eqSeries = @($hist | ForEach-Object { [pscustomobject]@{ d = [string]$_.d; e = [double]$_.e } })

# ── Positions (ours only) ─────────────────────────────────────────────────────
# The Alpaca account is shared with another bot. Ownership is established by the
# strategy prefix on our entry orders' client_order_id; a position we cannot
# prove is ours is not shown.
$allPositions = @(Get-Positions $cfg)
$owned = @{}
$ordLookback = (Get-Date).ToUniversalTime().AddDays(-40).ToString("yyyy-MM-ddTHH:mm:ssZ")
$recent = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=all&after=$ordLookback&direction=desc&limit=500"
if ($null -ne $recent) {
    foreach ($o in @($recent)) {
        if ($null -eq $o -or $o.status -ne "filled" -or -not $o.client_order_id) { continue }
        $tag = ($o.client_order_id -split "_")[0]
        if ($MY_ENTRY_PREFIXES -contains $tag) { $owned[$o.symbol] = $true }
    }
}
$positions = @($allPositions | Where-Object { $owned.ContainsKey($_.symbol) })

# Hold-day counts come from the journal, which records the entry timestamp.
$journal  = Load-Journal
$openRows = @($journal.open)

$posData = @()
foreach ($p in $positions) {
    $entry   = [double]$p.avg_entry_price
    $current = [double]$p.current_price
    $qty     = [Math]::Abs([double]$p.qty)
    $legs    = Get-LiveExitLegs $cfg $p
    $stop    = [double]$legs.stop
    $target  = [double]$legs.target

    # Strategy + planned risk come from the journal (newest row for the symbol).
    $row = @($openRows | Where-Object { $_.symbol -eq $p.symbol } |
             Sort-Object { _Journal-AsUtc $_.opened_at } -Descending | Select-Object -First 1)[0]
    $risk  = 0.0
    $strat = "-"
    if ($null -ne $row) {
        $strat = $row.strategy
        $risk  = [double]$row.risk_usd
    }

    # Hold days must be derived the SAME way Close-StalePositions derives them --
    # from the most recent entry FILL -- or the page shows a different day count
    # than the time stop is acting on. A journal row survives its tranche (PFE's
    # original row dates from 18 Aug while the position's last entry fill was the
    # 25 Aug pyramid add: 16 days vs the 11 the bot reports).
    $day = 0
    $entrySide = if ($p.side -eq "long") { "buy" } else { "sell" }
    $hist2 = Invoke-AlpacaApi $cfg "GET" ("/v2/orders?status=closed&symbols=" + $p.symbol + "&limit=100")
    if ($null -ne $hist2) {
        $fill = @($hist2) | Where-Object {
                    $_.side -eq $entrySide -and $_.status -eq "filled" -and $_.filled_at
                } | Sort-Object { [datetime]::Parse($_.filled_at) } -Descending | Select-Object -First 1
        if ($null -ne $fill) {
            try { $day = _Journal-WeekdayCount ([datetime]::Parse($fill.filled_at).ToUniversalTime()) ([datetime]::UtcNow) } catch {}
        }
    }
    # "Open risk" means what is at stake AT THE CURRENT STOP, so the live stop
    # distance wins. The journal's risk_usd is the risk planned at entry, which
    # goes stale the moment the ladder moves the stop (PFE: $620 planned vs $319
    # actual once the stop reached break-even). Journal risk is the fallback for
    # a position with no live stop.
    if ($stop -gt 0) { $risk = [Math]::Abs($entry - $stop) * $qty }

    $progress = $null
    if ($stop -gt 0 -and $target -gt 0 -and $target -ne $stop) {
        $progress = [Math]::Max(0, [Math]::Min(100, [Math]::Round(($current - $stop) / ($target - $stop) * 100, 0)))
    }

    $posData += [pscustomobject]@{
        symbol   = $p.symbol
        strategy = $strat
        qty      = $qty
        entry    = [Math]::Round($entry, 2)
        current  = [Math]::Round($current, 2)
        stop     = [Math]::Round($stop, 2)
        target   = [Math]::Round($target, 2)
        unrlPnl  = [Math]::Round([double]$p.unrealized_pl, 2)
        unrlPct  = [Math]::Round([double]$p.unrealized_plpc * 100, 2)
        value    = [Math]::Round($qty * $current, 2)
        risk     = [Math]::Round($risk, 2)
        day      = $day
        progress = $progress
    }
}

# ── Closed trades (journaled swing era) ───────────────────────────────────────
$closedData = @()
foreach ($c in @($journal.closed)) {
    if (-not $c.closed_at) { continue }
    $d = ""
    try { $d = (_Journal-AsUtc $c.closed_at).ToString("yyyy-MM-dd") } catch { continue }
    $closedData += [pscustomobject]@{
        d    = $d
        sym  = [string]$c.symbol
        st   = [string]$c.strategy
        r    = [double]$c.r_multiple
        pnl  = [double]$c.pnl
        out  = [string]$c.outcome
        hold = [int]$c.hold_days
    }
}
$closedData = @($closedData | Sort-Object { $_.d })

# ── Regime + market state ─────────────────────────────────────────────────────
$regime = "UNKNOWN"; $vix = $null; $sizeMult = 1.0
try {
    $spyDaily = Get-DailyBars $cfg "SPY"
    $sr = Get-SwingRegime $cfg $spyDaily
    if ($null -ne $sr) {
        $regime   = $sr.Regime
        $sizeMult = [double]$sr.SizeMult
        if ($null -ne $sr.VIX) { $vix = [double]$sr.VIX }
    }
} catch { Write-Host "  Regime lookup failed -- rendering without it." -ForegroundColor DarkYellow }

$clock = Get-MarketClock $cfg
$marketOpen = ($null -ne $clock -and $clock.is_open)

# ── Assemble + inject ─────────────────────────────────────────────────────────
$payload = [pscustomobject]@{
    generated    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
    equity       = [Math]::Round($equity, 2)
    dayPnl       = [Math]::Round($equity - $lastEq, 2)
    startEquity  = $START_EQUITY
    marketOpen   = $marketOpen
    paper        = [bool]$cfg.paper_trading
    regime       = $regime
    vix          = $vix
    sizeMult     = $sizeMult
    maxPositions = if ($cfg.max_positions) { [int]$cfg.max_positions } else { 3 }
    eq           = $eqSeries
    positions    = $posData
    closed       = $closedData
}
# -Compress keeps it on one line; the template holds it in a JSON script block,
# so the only character that could break out of that block is "</script".
$json = ($payload | ConvertTo-Json -Depth 6 -Compress) -replace '</script', '<\/script'

if (-not (Test-Path $TemplatePath)) { throw "Template missing: $TemplatePath" }
# -Encoding UTF8 on BOTH ends. Windows PowerShell reads a BOM-less UTF-8 file
# as the system ANSI codepage, which turns every em dash and minus sign in the
# template into mojibake before it is ever written out.
$html = Get-Content $TemplatePath -Raw -Encoding UTF8
if (-not $html.Contains('__DATA__')) { throw "Template has no __DATA__ placeholder" }
# String.Replace, NOT -replace: the regex operator would treat "$" sequences in
# the JSON payload as capture-group references and silently mangle the data.
$html = $html.Replace('__DATA__', $json)

$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
# WriteAllText with a BOM-less encoder: identical bytes on PowerShell 5.1 and 7.
[System.IO.File]::WriteAllText($OutFile, $html, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("  docs/index.html written -- {0} positions, {1} closed, {2} equity points" -f `
    $posData.Count, $closedData.Count, $eqSeries.Count) -ForegroundColor Green
