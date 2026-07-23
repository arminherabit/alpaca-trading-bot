# Trade journal -- the bot's self-analysis layer.
#
# Every entry writes an OPEN record (setup, regime, confidence, dollar risk);
# every exit completes it (R-multiple, hold days, outcome) and moves it to
# CLOSED. The closed journal is the ground truth for the weekly self-review
# and for regime-aware expectancy stats: the regime recorded at ENTRY is
# recovered here at exit time, which the order flow alone cannot provide.
#
# File: alpaca_journal.json  { open: [...], closed: [...] }
# Persisted to the repo by the workflow like state/memory.

$JournalPath = Join-Path $PSScriptRoot "alpaca_journal.json"

function Load-Journal {
    $j = $null
    if (Test-Path $JournalPath) {
        try { $j = Get-Content $JournalPath -Raw | ConvertFrom-Json } catch {}
    }
    if ($null -eq $j) {
        $j = [pscustomobject]@{ open = @(); closed = @() }
    }
    foreach ($prop in @("open","closed")) {
        if (-not (Get-Member -InputObject $j -Name $prop -ErrorAction SilentlyContinue)) {
            $j | Add-Member -NotePropertyName $prop -NotePropertyValue @() -Force
        }
        if ($null -eq $j.$prop) { $j.$prop = @() }
    }
    return $j
}

function Save-Journal($j) {
    $j | ConvertTo-Json -Depth 10 | Set-Content $JournalPath
}

function _Journal-WeekdayCount([datetime]$from, [datetime]$to) {
    $count = 0; $d = $from.Date.AddDays(1)
    while ($d -le $to.Date) {
        if ($d.DayOfWeek -ne "Saturday" -and $d.DayOfWeek -ne "Sunday") { $count++ }
        $d = $d.AddDays(1)
    }
    return $count
}

# Called at ENTRY (order submission). Replaces any stale open record for the
# same symbol AND strategy (an orphaned record means the prior entry never
# filled or its exit escaped the sync window). Symbol-only dedupe would
# clobber the original record when a PYRA add opens on the same symbol.
function Add-JournalEntry {
    param(
        [string]$symbol, [string]$strategy, [string]$side,
        [double]$entry, [double]$stop, [int]$qty,
        [double]$riskUsd, [int]$confidence = 0,
        [string]$regime = "", [string]$reason = ""
    )
    $j = Load-Journal
    $j.open = @($j.open | Where-Object { -not ($_.symbol -eq $symbol -and $_.strategy -eq $strategy) })
    $j.open += [pscustomobject]@{
        opened_at  = (Get-Date).ToUniversalTime().ToString("o")
        symbol     = $symbol
        strategy   = $strategy
        side       = $side
        entry      = [Math]::Round($entry, 2)
        stop       = [Math]::Round($stop, 2)
        qty        = $qty
        risk_usd   = [Math]::Round($riskUsd, 2)
        confidence = $confidence
        regime     = $regime
        reason     = $reason
    }
    Save-Journal $j
    Write-Host ("  [JOURNAL] {0,-6} opened: {1} {2} conf={3} regime={4} risk=`${5}" -f `
        $symbol, $strategy, $side, $confidence, $regime, [Math]::Round($riskUsd,0)) -ForegroundColor DarkCyan
}

# Called at EXIT (Sync-ClosedTrades). Completes the open record, computes the
# R-multiple and outcome, moves it to closed. Returns the completed record
# (so the caller can recover the entry regime) or $null if no open record.
# When a symbol has two open records (original + PYRA add), the exit qty
# disambiguates which tranche closed.
function Complete-JournalEntry {
    param([string]$symbol, [double]$exitPrice, [double]$pnl, [int]$qty = 0)
    $j = Load-Journal
    $cands = @($j.open | Where-Object { $_.symbol -eq $symbol })
    if ($qty -gt 0) {
        $qtyMatch = @($cands | Where-Object { [int]$_.qty -eq $qty })
        if ($qtyMatch.Count -gt 0) { $cands = $qtyMatch }
    }
    $rec = $cands | Sort-Object { [datetime]::Parse($_.opened_at) } -Descending | Select-Object -First 1
    if ($null -eq $rec) { return $null }
    $j.open = @($j.open | Where-Object { $_ -ne $rec })

    $rMult = if ($rec.risk_usd -gt 0) { [Math]::Round($pnl / $rec.risk_usd, 2) } else { 0.0 }
    $outcome = if ([Math]::Abs($rMult) -lt 0.15) { "SCRATCH" } elseif ($pnl -gt 0) { "WIN" } else { "LOSS" }
    $holdDays = 0
    try { $holdDays = _Journal-WeekdayCount ([datetime]::Parse($rec.opened_at).ToUniversalTime()) ([datetime]::UtcNow) } catch {}

    $rec | Add-Member -NotePropertyName closed_at  -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    $rec | Add-Member -NotePropertyName exit       -NotePropertyValue ([Math]::Round($exitPrice, 2)) -Force
    $rec | Add-Member -NotePropertyName pnl        -NotePropertyValue ([Math]::Round($pnl, 2)) -Force
    $rec | Add-Member -NotePropertyName r_multiple -NotePropertyValue $rMult -Force
    $rec | Add-Member -NotePropertyName hold_days  -NotePropertyValue $holdDays -Force
    $rec | Add-Member -NotePropertyName outcome    -NotePropertyValue $outcome -Force

    $j.closed += $rec
    Save-Journal $j
    Write-Host ("  [JOURNAL] {0,-6} closed: {1} {2}  {3:+0.00;-0.00}R  `${4:F2}  held {5}d" -f `
        $symbol, $rec.strategy, $outcome, $rMult, $pnl, $holdDays) -ForegroundColor DarkCyan
    return $rec
}

# Weekly self-review: aggregates the last N days of closed journal entries.
# Returns a stats object; Write-WeeklyReview renders it to alpaca_review.md.
function Get-JournalStats([int]$daysBack = 7) {
    $j = Load-Journal
    $cutoff = [datetime]::UtcNow.AddDays(-$daysBack)
    $rows = @($j.closed | Where-Object {
        $_.closed_at -and ([datetime]::Parse($_.closed_at).ToUniversalTime() -ge $cutoff)
    })
    if ($rows.Count -eq 0) { return $null }

    $wins   = @($rows | Where-Object { $_.pnl -gt 0 })
    $losses = @($rows | Where-Object { $_.pnl -le 0 })
    $grossW = ($wins   | Measure-Object -Property pnl -Sum).Sum;  if ($null -eq $grossW) { $grossW = 0 }
    $grossL = [Math]::Abs((($losses | Measure-Object -Property pnl -Sum).Sum)); if ($null -eq $grossL) { $grossL = 0 }

    $byStrategy = $rows | Group-Object strategy | ForEach-Object {
        $p = ($_.Group | Measure-Object -Property pnl -Sum).Sum
        [pscustomobject]@{ Key = $_.Name; Trades = $_.Count
            Wins = @($_.Group | Where-Object { $_.pnl -gt 0 }).Count
            PnL = [Math]::Round($p, 2) }
    }
    $byRegime = $rows | Where-Object { $_.regime } | Group-Object regime | ForEach-Object {
        $p = ($_.Group | Measure-Object -Property pnl -Sum).Sum
        [pscustomobject]@{ Key = $_.Name; Trades = $_.Count
            Wins = @($_.Group | Where-Object { $_.pnl -gt 0 }).Count
            PnL = [Math]::Round($p, 2) }
    }

    return [pscustomobject]@{
        Trades       = $rows.Count
        Wins         = $wins.Count
        Losses       = $losses.Count
        WinRate      = [Math]::Round($wins.Count / $rows.Count, 3)
        TotalPnL     = [Math]::Round((($rows | Measure-Object -Property pnl -Sum).Sum), 2)
        AvgR         = [Math]::Round((($rows | Measure-Object -Property r_multiple -Average).Average), 2)
        ProfitFactor = if ($grossL -gt 0) { [Math]::Round($grossW / $grossL, 2) } elseif ($grossW -gt 0) { 99.0 } else { 0.0 }
        Expectancy   = [Math]::Round((($rows | Measure-Object -Property pnl -Average).Average), 2)
        AvgHoldDays  = [Math]::Round((($rows | Measure-Object -Property hold_days -Average).Average), 1)
        Best         = ($rows | Sort-Object pnl -Descending | Select-Object -First 1)
        Worst        = ($rows | Sort-Object pnl | Select-Object -First 1)
        ByStrategy   = $byStrategy
        ByRegime     = $byRegime
    }
}

# Renders the weekly review to console + appends a section to alpaca_review.md.
function Write-WeeklyReview {
    param([string]$weekLabel)
    $stats = Get-JournalStats 7
    $reviewPath = Join-Path $PSScriptRoot "alpaca_review.md"
    if (-not (Test-Path $reviewPath)) {
        "# Swing Bot -- Weekly Self-Review Log`n" | Set-Content $reviewPath
    }
    if ($null -eq $stats) {
        Write-Host "  [REVIEW] $weekLabel -- no closed trades in the last 7 days." -ForegroundColor DarkCyan
        Add-Content $reviewPath "`n## $weekLabel`nNo closed trades this week.`n"
        return
    }
    Write-Host ("  [REVIEW] {0}: {1} trades  W/L {2}/{3} ({4:P0})  PnL `${5}  PF {6}  avgR {7}  expectancy `${8}/trade" -f `
        $weekLabel, $stats.Trades, $stats.Wins, $stats.Losses, $stats.WinRate, $stats.TotalPnL, `
        $stats.ProfitFactor, $stats.AvgR, $stats.Expectancy) -ForegroundColor Cyan

    $md = @()
    $md += ""
    $md += "## $weekLabel"
    $md += ""
    $md += "| Metric | Value |"
    $md += "|---|---|"
    $md += "| Trades | $($stats.Trades) ($($stats.Wins)W / $($stats.Losses)L, $([Math]::Round($stats.WinRate*100))%) |"
    $md += "| Net P&L | `$$($stats.TotalPnL) |"
    $md += "| Profit factor | $($stats.ProfitFactor) |"
    $md += "| Expectancy / trade | `$$($stats.Expectancy) |"
    $md += "| Avg R | $($stats.AvgR) |"
    $md += "| Avg hold | $($stats.AvgHoldDays) days |"
    $md += "| Best | $($stats.Best.symbol) $($stats.Best.strategy) `$$($stats.Best.pnl) ($($stats.Best.r_multiple)R) |"
    $md += "| Worst | $($stats.Worst.symbol) $($stats.Worst.strategy) `$$($stats.Worst.pnl) ($($stats.Worst.r_multiple)R) |"
    $md += ""
    $md += "**By strategy:** " + (($stats.ByStrategy | ForEach-Object { "$($_.Key) $($_.Wins)/$($_.Trades) `$$($_.PnL)" }) -join " | ")
    if ($stats.ByRegime) {
        $md += ""
        $md += "**By regime:** " + (($stats.ByRegime | ForEach-Object { "$($_.Key) $($_.Wins)/$($_.Trades) `$$($_.PnL)" }) -join " | ")
    }
    $md += ""
    Add-Content $reviewPath ($md -join "`n")
}
