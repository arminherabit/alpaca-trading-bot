# alpaca_trump_sentinel.ps1
# TrumpMarketSentinel -- watches Alpaca's news feed for Trump/White House/
# policy headlines that touch a small watchlist of politically-sensitive
# tickers (defense, semiconductors, DJT itself), and cross-checks those
# names for unusual volume or price action.
#
# Scope and honesty about limits: this bot only has Alpaca's licensed news
# feed (financial media/wires), NOT a live X or Truth Social API. Anything
# claiming social-sentiment coverage would be fabricated, so this module
# sticks to real news headlines + real price/volume data. If a Truth
# Social / X firehose is wired in later, plug it into Get-TrumpNewsHits
# alongside the Alpaca fetch.
#
# This module is advisory only -- it prints/logs alerts, it does not place
# orders. "Recommended Action" is a heuristic label for a human (or the
# screener's existing risk-gated pipeline) to act on, same as the plain
# news-catalyst score in alpaca_news.ps1.
#
# Exports:
#   Get-TrumpSentinelAlerts  $cfg  -> alert[] (new alerts since last run)
#   Invoke-TrumpMarketSentinel $cfg -> prints + logs, returns alert[]

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_news.ps1")
. (Join-Path $PSScriptRoot "alpaca_indicators.ps1")

$TrumpSentinelLogPath = Join-Path $PSScriptRoot "trump_sentinel_log.json"

$script:TrumpSentinelSeenHeadlines = $null   # hashset, loaded lazily from log
$script:TrumpSentinelBarsCache     = @{}     # symbol -> {Bars, Time}, TTL below

$DEFAULT_TRUMP_WATCHLIST = @("DJT", "PLTR", "LMT", "INTC", "RTX", "NOC", "GD", "TSM", "MSTR", "BA")

# Trump/administration/policy vocabulary -- headline or summary must hit one
# of these before a ticker is treated as "Trump-linked" news rather than
# ordinary company news.
$TRUMP_KEYWORDS = @(
    'trump', 'white house', 'trump administration', 'executive order',
    'truth social', 'tariff', 'tariffs', 'trade war', 'trade deal',
    'pentagon', 'department of defense', 'doj', 'department of justice',
    'sanctions', 'export ban', 'export controls', 'chips act',
    'national security', 'pardon', 'deportation', 'immigration order',
    'strategic reserve', 'defense contract', 'government contract',
    'federal contract'
)

# Extra bump for headlines that describe a concrete funding/contract event
# (the "funding announcements, contracts" part of the brief) so those score
# higher than a generic mention.
$CONTRACT_KEYWORDS = @(
    'contract', 'awarded', 'award', 'funding', 'grant', 'subsidy',
    'investment pledge', 'deal worth', 'procurement'
)

function Test-TrumpHeadline([string]$headline, [string]$summary) {
    $text = (($headline + " " + $summary)).ToLower()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($kw in $TRUMP_KEYWORDS) {
        if ($text -match [regex]::Escape($kw)) { return $true }
    }
    return $false
}

function Test-ContractHeadline([string]$headline, [string]$summary) {
    $text = (($headline + " " + $summary)).ToLower()
    foreach ($kw in $CONTRACT_KEYWORDS) {
        if ($text -match [regex]::Escape($kw)) { return $true }
    }
    return $false
}

# ── News side: Trump-linked catalysts on watchlist names ──────────────────────

function Get-TrumpNewsHits {
    param($cfg, [string[]]$watchlist, [int]$hoursBack = 6)

    $news = Get-RecentNews $cfg $hoursBack 50
    if ($news.Count -eq 0) { return @{} }

    $hits = @{}
    foreach ($n in $news) {
        $headline = if ($n.headline) { [string]$n.headline } else { "" }
        $summary  = if ($n.summary)  { [string]$n.summary }  else { "" }
        if ($headline -eq "") { continue }
        if (-not (Test-TrumpHeadline $headline $summary)) { continue }

        $symbols = @()
        if ($n.symbols) { $symbols = @($n.symbols | Where-Object { $watchlist -contains $_ }) }

        # No tagged watchlist ticker on this headline -- nothing actionable
        # for this watchlist, skip (avoids alerting on unrelated politics).
        if ($symbols.Count -eq 0) { continue }

        $score      = (Get-HeadlineSentiment $headline) + (Get-HeadlineSentiment $summary)
        $isContract = Test-ContractHeadline $headline $summary
        $headlineId = "{0}|{1}" -f $n.id, $headline

        foreach ($sym in $symbols) {
            if (-not $hits.ContainsKey($sym)) {
                $hits[$sym] = [pscustomobject]@{
                    Symbol      = $sym
                    Sentiment   = 0
                    IsContract  = $false
                    Headlines   = New-Object System.Collections.Generic.List[string]
                    HeadlineIds = New-Object System.Collections.Generic.List[string]
                }
            }
            $hits[$sym].Sentiment += $score
            if ($isContract) { $hits[$sym].IsContract = $true }
            if ($hits[$sym].Headlines.Count -lt 3) { $hits[$sym].Headlines.Add($headline) }
            $hits[$sym].HeadlineIds.Add($headlineId)
        }
    }
    return $hits
}

# ── Price side: unusual volume / price move on watchlist names ────────────────

function Get-TrumpVolatilityHits {
    param($cfg, [string[]]$watchlist, [double]$minRelVolume = 2.0, [double]$minMovePct = 3.0)

    $hits = @{}
    foreach ($sym in $watchlist) {
        # Daily bars don't change intra-cycle -- cache per symbol for 9 min
        # (matches Get-NewsRaw48h's cache window) so a 10-min cron loop
        # doesn't refetch the same bars every run.
        $cached = $script:TrumpSentinelBarsCache[$sym]
        if ($cached -and ((Get-Date) - $cached.Time).TotalMinutes -lt 9) {
            $bars = $cached.Bars
        } else {
            # daysBack is calendar days, not trading days -- need ~45 calendar
            # days to reliably get the 22 trading bars Get-RelativeVolume(20) needs.
            $bars = Get-DailyBars $cfg $sym 45
            $script:TrumpSentinelBarsCache[$sym] = [pscustomobject]@{ Bars = $bars; Time = Get-Date }
        }
        if ($null -eq $bars -or $bars.Count -lt 22) { continue }

        $relVol = Get-RelativeVolume $bars 20
        $last   = $bars[$bars.Count - 1]
        $prev   = $bars[$bars.Count - 2]
        $movePct = if ($prev.Close -ne 0) { (($last.Close - $prev.Close) / $prev.Close) * 100.0 } else { 0.0 }

        $unusual = (($null -ne $relVol) -and ($relVol -ge $minRelVolume)) -or ([Math]::Abs($movePct) -ge $minMovePct)
        if (-not $unusual) { continue }

        $hits[$sym] = [pscustomobject]@{
            Symbol   = $sym
            RelVol   = $relVol
            MovePct  = [Math]::Round($movePct, 2)
        }
    }
    return $hits
}

# ── Dedup / persistence ────────────────────────────────────────────────────────

function Get-TrumpSentinelSeenSet {
    if ($null -ne $script:TrumpSentinelSeenHeadlines) { return $script:TrumpSentinelSeenHeadlines }
    $set = New-Object System.Collections.Generic.HashSet[string]
    if (Test-Path $TrumpSentinelLogPath) {
        try {
            $log = Get-Content $TrumpSentinelLogPath -Raw | ConvertFrom-Json
            foreach ($entry in @($log)) {
                foreach ($id in @($entry.HeadlineIds)) { [void]$set.Add([string]$id) }
            }
        } catch {}
    }
    $script:TrumpSentinelSeenHeadlines = $set
    return $set
}

function Save-TrumpSentinelAlert($alert) {
    $log = @()
    if (Test-Path $TrumpSentinelLogPath) {
        try { $log = @(Get-Content $TrumpSentinelLogPath -Raw | ConvertFrom-Json) } catch { $log = @() }
    }
    $log += $alert
    # keep the log bounded -- most recent 200 alerts
    if ($log.Count -gt 200) { $log = $log[($log.Count - 200)..($log.Count - 1)] }
    $log | ConvertTo-Json -Depth 6 | Set-Content -Path $TrumpSentinelLogPath
}

# ── Alert assembly ──────────────────────────────────────────────────────────────

function Get-TrumpSentinelRecommendation($sentiment, $isContract, $movePct) {
    # Advisory heuristic only -- balanced view, biased toward "Monitor"
    # whenever the signal is ambiguous or the move has already run.
    if ($sentiment -ge 2 -or $isContract) {
        if ($null -ne $movePct -and $movePct -le -1.0) { return "Buy Dip" }
        if ($null -ne $movePct -and $movePct -ge 5.0)  { return "Monitor" }   # already extended, chase risk
        return "Monitor"
    }
    if ($sentiment -le -2) {
        if ($null -ne $movePct -and $movePct -le -5.0) { return "Avoid" }     # already fell sharply, knife-catch risk
        return "Sell"
    }
    return "Monitor"
}

function Get-TrumpSentinelAlerts {
    param($cfg)

    $watchlist = if ($cfg.trump_sentinel_watchlist -and @($cfg.trump_sentinel_watchlist).Count -gt 0) {
        @($cfg.trump_sentinel_watchlist)
    } else { $DEFAULT_TRUMP_WATCHLIST }

    $lookback    = if ($cfg.trump_sentinel_lookback_hours) { [int]$cfg.trump_sentinel_lookback_hours } else { 6 }
    $minRelVol   = if ($cfg.trump_sentinel_min_rel_volume) { [double]$cfg.trump_sentinel_min_rel_volume } else { 2.0 }
    $minMovePct  = if ($cfg.trump_sentinel_min_move_pct)   { [double]$cfg.trump_sentinel_min_move_pct }   else { 3.0 }

    $newsHits = Get-TrumpNewsHits $cfg $watchlist $lookback
    $volHits  = Get-TrumpVolatilityHits $cfg $watchlist $minRelVol $minMovePct
    $seen     = Get-TrumpSentinelSeenSet

    $alerts = @()
    $allSymbols = @($newsHits.Keys) + @($volHits.Keys | Where-Object { -not $newsHits.ContainsKey($_) })

    foreach ($sym in ($allSymbols | Select-Object -Unique)) {
        $newsHit = if ($newsHits.ContainsKey($sym)) { $newsHits[$sym] } else { $null }
        $volHit  = if ($volHits.ContainsKey($sym))  { $volHits[$sym] }  else { $null }

        # Skip if this is purely a news hit whose headlines were all already alerted
        if ($null -ne $newsHit) {
            $newIds = @($newsHit.HeadlineIds | Where-Object { -not $seen.Contains($_) })
            if ($newIds.Count -eq 0 -and $null -eq $volHit) { continue }
        }

        $sentiment  = if ($newsHit) { $newsHit.Sentiment } else { 0 }
        $isContract = if ($newsHit) { $newsHit.IsContract } else { $false }
        $movePct    = if ($volHit)  { $volHit.MovePct }     else { $null }

        # Threshold gate: only significant moves or high-probability catalysts.
        $significant = ($null -ne $volHit) -or ($null -ne $newsHit -and ([Math]::Abs($sentiment) -ge 2 -or $isContract))
        if (-not $significant) { continue }

        $eventBits = @()
        if ($newsHit -and $newsHit.Headlines.Count -gt 0) { $eventBits += $newsHit.Headlines[0] }
        if ($volHit) {
            $relVolStr = if ($null -ne $volHit.RelVol) { "{0}x avg volume" -f $volHit.RelVol } else { $null }
            $moveStr   = "{0:+0.0;-0.0}% today" -f $volHit.MovePct
            $pieces    = @($moveStr)
            if ($relVolStr) { $pieces = @($relVolStr) + $pieces }
            $eventBits += ("Unusual move: " + ($pieces -join ", "))
        }
        if ($eventBits.Count -eq 0) { continue }
        $event = $eventBits -join " -- "

        $leanStr = if ($sentiment -ge 2) { "bullish" } elseif ($sentiment -le -2) { "bearish" } else { "neutral" }
        $impactParts = @()
        if ($newsHit) {
            $impactParts += ("News lean {0} (score {1}{2})." -f $leanStr, $sentiment, $(if ($isContract) { ", contract/funding language detected" } else { "" }))
        }
        if ($volHit) {
            $relVolTxt = if ($null -ne $volHit.RelVol) { "{0}x" -f $volHit.RelVol } else { "n/a" }
            $impactParts += ("Price {0:+0.0;-0.0}% on {1} relative volume vs 20-day avg." -f $volHit.MovePct, $relVolTxt)
        }
        $impact = $impactParts -join " "

        $action = Get-TrumpSentinelRecommendation $sentiment $isContract $movePct

        $alert = [pscustomobject]@{
            Time            = (Get-Date).ToUniversalTime().ToString("o")
            Event           = $event
            AffectedTickers = @($sym)
            Impact          = $impact
            RecommendedAction = $action
            HeadlineIds     = if ($newsHit) { @($newsHit.HeadlineIds) } else { @() }
        }
        $alerts += $alert

        if ($newsHit) { foreach ($id in $newsHit.HeadlineIds) { [void]$seen.Add($id) } }
    }

    return $alerts
}

function Format-TrumpSentinelAlert($alert) {
    return @(
        ("Event: {0}" -f $alert.Event)
        ("Affected Tickers: {0}" -f ($alert.AffectedTickers -join ", "))
        ("Immediate Impact Analysis: {0}" -f $alert.Impact)
        ("Recommended Action: {0}" -f $alert.RecommendedAction)
    ) -join "`n"
}

function Invoke-TrumpMarketSentinel($cfg) {
    if ($cfg.trump_sentinel_enabled -eq $false) { return @() }

    $alerts = @()
    try {
        $alerts = Get-TrumpSentinelAlerts $cfg
    } catch {
        Write-Host ("  [TRUMP-SENTINEL] scan failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return @()
    }

    if ($alerts.Count -eq 0) { return @() }

    Write-Host ""
    Write-Host "  [TRUMP-SENTINEL] New alert(s):" -ForegroundColor Magenta
    foreach ($alert in $alerts) {
        $color = switch ($alert.RecommendedAction) {
            "Buy Dip" { "Green" }
            "Sell"    { "Red" }
            "Avoid"   { "Red" }
            default   { "Yellow" }
        }
        Write-Host ("  ── {0} ──" -f ($alert.AffectedTickers -join ", ")) -ForegroundColor $color
        (Format-TrumpSentinelAlert $alert) -split "`n" | ForEach-Object { Write-Host ("    {0}" -f $_) -ForegroundColor $color }
        Save-TrumpSentinelAlert $alert
    }
    Write-Host ""

    return $alerts
}
