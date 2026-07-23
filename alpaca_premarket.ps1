# alpaca_premarket.ps1
# Pre-Market Movers Preview -- surfaces the earliest PUBLIC signals of who
# will move today, before the 9:30 ET open:
#
#   1. Scheduled catalysts : earnings dates within the next 5 days (known in
#      advance -- the most reliable "advance knowledge" that legally exists)
#   2. Pre-market gaps     : price vs yesterday's close from 4:00 AM ET on
#   3. Overnight news      : headlines that broke while the market was closed,
#      before the session has fully priced them
#
# Honesty about limits: this is NOT prediction. Nothing here knows a mover
# before the information is public. What it does is put the earliest public
# signals in one place a few hours before most participants look at them.
# Pre-market prints on the free IEX feed are sparse -- gap numbers are
# indicative, not exact, and thin names may show no pre-market trade at all.
#
# Advisory only -- prints/logs a preview, never places orders.
#
# Exports:
#   Get-PreMarketPreview     $cfg           -> preview object
#   Invoke-PreMarketPreview  $cfg [-Force]  -> prints + logs; self-gates to
#                                              one auto-run per day, 06:00-09:30 ET
#                                              (use -Force for on-demand runs)

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_news.ps1")
. (Join-Path $PSScriptRoot "alpaca_earnings.ps1")

$PreMarketLogPath = Join-Path $PSScriptRoot "premarket_log.json"

# ── Universe ──────────────────────────────────────────────────────────────────
# Sentinel watchlist + core config watchlist, deduped. Capped to keep the
# snapshot call to a single batch request.

function Get-PreMarketUniverse($cfg) {
    $u = @()
    if ($cfg.trump_sentinel_watchlist) { $u += @($cfg.trump_sentinel_watchlist) }
    if ($cfg.watchlist)                { $u += @($cfg.watchlist) }
    if ($cfg.premarket_extra_tickers)  { $u += @($cfg.premarket_extra_tickers) }
    return @($u | Select-Object -Unique | Select-Object -First 25)
}

# ── 1. Pre-market gaps ────────────────────────────────────────────────────────

function Get-PreMarketGaps {
    param($cfg, [string[]]$universe, [double]$minGapPct = 1.5)

    $snap = Get-Snapshot $cfg $universe
    if ($null -eq $snap) { return @() }

    $gaps = @()
    foreach ($sym in $universe) {
        $s = $snap.$sym
        if ($null -eq $s -or $null -eq $s.prevDailyBar) { continue }
        $prevClose = [double]$s.prevDailyBar.c
        if ($prevClose -le 0) { continue }

        # Latest trade is the best pre-market print; fall back to quote mid.
        $last = $null
        if ($s.latestTrade -and $s.latestTrade.p)  { $last = [double]$s.latestTrade.p }
        elseif ($s.latestQuote -and $s.latestQuote.bp -and $s.latestQuote.ap) {
            $bp = [double]$s.latestQuote.bp; $ap = [double]$s.latestQuote.ap
            if ($bp -gt 0 -and $ap -gt 0) { $last = ($bp + $ap) / 2.0 }
        }
        if ($null -eq $last -or $last -le 0) { continue }

        $gapPct = (($last - $prevClose) / $prevClose) * 100.0
        if ([Math]::Abs($gapPct) -lt $minGapPct) { continue }

        $gaps += [pscustomobject]@{
            Symbol    = $sym
            GapPct    = [Math]::Round($gapPct, 2)
            Last      = $last
            PrevClose = $prevClose
        }
    }
    return @($gaps | Sort-Object { [Math]::Abs($_.GapPct) } -Descending)
}

# ── 2. Upcoming earnings (scheduled catalysts) ────────────────────────────────

function Get-UpcomingEarnings {
    param($cfg, [string[]]$universe, [int]$lookaheadDays = 5)

    # Respects the module's 24h cache TTL / 4h failure back-off internally.
    Refresh-EarningsCalendar $cfg | Out-Null

    $upcoming = @()
    foreach ($sym in $universe) {
        $d = Get-DaysToEarnings $sym
        if ($null -eq $d -or $d -gt $lookaheadDays) { continue }
        $upcoming += [pscustomobject]@{
            Symbol       = $sym
            DaysToReport = $d
        }
    }
    return @($upcoming | Sort-Object DaysToReport)
}

# ── 3. Overnight news ─────────────────────────────────────────────────────────
# 16h lookback covers post-close through pre-market. minMentions=1 on purpose:
# pre-open, even a single overnight headline is worth a look.

function Get-OvernightNews {
    param($cfg, [string[]]$universe, [int]$hoursBack = 16)

    $catalysts = Get-NewsCatalysts $cfg $hoursBack 1
    $onList  = @()
    $offList = @()
    foreach ($sym in ($catalysts.Keys | Sort-Object { $catalysts[$_].Mentions } -Descending)) {
        $c = $catalysts[$sym]
        $row = [pscustomobject]@{
            Symbol    = $sym
            Mentions  = $c.Mentions
            Lean      = $c.Lean
            Headline  = if ($c.Headlines.Count -gt 0) { $c.Headlines[0] } else { "" }
        }
        if ($universe -contains $sym) { $onList += $row }
        elseif ($offList.Count -lt 5) { $offList += $row }   # top 5 off-watchlist
    }
    return [pscustomobject]@{ Watchlist = @($onList); OffWatchlist = @($offList) }
}

# ── Preview assembly ──────────────────────────────────────────────────────────

function Get-PreMarketPreview {
    param($cfg)

    $universe  = Get-PreMarketUniverse $cfg
    $minGap    = if ($cfg.premarket_min_gap_pct) { [double]$cfg.premarket_min_gap_pct } else { 1.5 }
    $lookahead = if ($cfg.premarket_earnings_lookahead_days) { [int]$cfg.premarket_earnings_lookahead_days } else { 5 }

    return [pscustomobject]@{
        Time     = (Get-Date).ToUniversalTime().ToString("o")
        Universe = $universe
        Gaps     = Get-PreMarketGaps      $cfg $universe $minGap
        Earnings = Get-UpcomingEarnings   $cfg $universe $lookahead
        News     = Get-OvernightNews      $cfg $universe
    }
}

function Save-PreMarketPreview($preview) {
    $log = @()
    if (Test-Path $PreMarketLogPath) {
        try { $log = @(Get-Content $PreMarketLogPath -Raw | ConvertFrom-Json) } catch { $log = @() }
    }
    $log += $preview
    if ($log.Count -gt 30) { $log = $log[($log.Count - 30)..($log.Count - 1)] }
    $log | ConvertTo-Json -Depth 7 | Set-Content -Path $PreMarketLogPath
}

function Test-PreMarketAlreadyRanToday {
    if (-not (Test-Path $PreMarketLogPath)) { return $false }
    try {
        $log = @(Get-Content $PreMarketLogPath -Raw | ConvertFrom-Json)
        if ($log.Count -eq 0) { return $false }
        $lastUtc = [datetime]::Parse($log[-1].Time).ToUniversalTime()
        try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
        catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
        $lastET = [System.TimeZoneInfo]::ConvertTimeFromUtc($lastUtc, $tz).ToString("yyyy-MM-dd")
        return ($lastET -eq (Get-EasternTime).ToString("yyyy-MM-dd"))
    } catch { return $false }
}

function Invoke-PreMarketPreview {
    param($cfg, [switch]$Force)

    if ($cfg.premarket_enabled -eq $false) { return $null }

    if (-not $Force) {
        # Auto-run gate: pre-open window only, once per ET day.
        $etNow = Get-EasternTime
        $inWindow = ($etNow.TimeOfDay -ge [timespan]"06:00" -and $etNow.TimeOfDay -lt [timespan]"09:30" -and
                     $etNow.DayOfWeek -ne "Saturday" -and $etNow.DayOfWeek -ne "Sunday")
        if (-not $inWindow) { return $null }
        if (Test-PreMarketAlreadyRanToday) { return $null }
    }

    $preview = $null
    try {
        $preview = Get-PreMarketPreview $cfg
    } catch {
        Write-Host ("  [PRE-MARKET] preview failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return $null
    }

    Write-Host ""
    Write-Host "  [PRE-MARKET] Movers Preview:" -ForegroundColor Cyan

    if ($preview.Gaps.Count -gt 0) {
        Write-Host "    Gaps vs yesterday's close (IEX, indicative):" -ForegroundColor Cyan
        foreach ($g in $preview.Gaps) {
            $c = if ($g.GapPct -ge 0) { "Green" } else { "Red" }
            Write-Host ("      {0,-6} {1,6:+0.0;-0.0}%   ({2} vs {3} prev close)" -f `
                $g.Symbol, $g.GapPct, $g.Last, $g.PrevClose) -ForegroundColor $c
        }
    } else {
        Write-Host "    No watchlist gaps above threshold." -ForegroundColor DarkGray
    }

    if ($preview.Earnings.Count -gt 0) {
        Write-Host "    Earnings ahead (scheduled catalysts):" -ForegroundColor Cyan
        foreach ($e in $preview.Earnings) {
            $when = if ($e.DaysToReport -eq 0) { "TODAY" } elseif ($e.DaysToReport -eq 1) { "tomorrow" } else { "in {0} days" -f $e.DaysToReport }
            Write-Host ("      {0,-6} reports {1}" -f $e.Symbol, $when) -ForegroundColor Yellow
        }
    } else {
        Write-Host "    No watchlist earnings in the lookahead window." -ForegroundColor DarkGray
    }

    if ($preview.News.Watchlist.Count -gt 0) {
        Write-Host "    Overnight news (watchlist):" -ForegroundColor Cyan
        foreach ($n in $preview.News.Watchlist) {
            Write-Host ("      {0,-6} {1} mention(s), lean {2}: {3}" -f `
                $n.Symbol, $n.Mentions, $n.Lean, $n.Headline) -ForegroundColor Gray
        }
    }
    if ($preview.News.OffWatchlist.Count -gt 0) {
        Write-Host "    Overnight news leaders (off-watchlist, FYI):" -ForegroundColor DarkCyan
        foreach ($n in $preview.News.OffWatchlist) {
            Write-Host ("      {0,-6} {1} mention(s), lean {2}: {3}" -f `
                $n.Symbol, $n.Mentions, $n.Lean, $n.Headline) -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    Save-PreMarketPreview $preview
    return $preview
}
