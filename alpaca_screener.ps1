# alpaca_screener.ps1
# Self-learning dynamic ticker screener.
# Thinks like a seasoned analyst: gap + volume + ATR + sector + memory.
#
# Exports:
#   Get-DynamicWatchlist  $cfg          -> string[]  (up to $cfg.max_watchlist tickers)
#   Update-TickerMemory   $symbol $won $pnl $strategy
#   Write-ScreenerReport  $candidates
#
# Persists learning to: alpaca_ticker_memory.json

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_news.ps1")
. (Join-Path $PSScriptRoot "alpaca_earnings.ps1")
. (Join-Path $PSScriptRoot "alpaca_cycle_screener.ps1")
. (Join-Path $PSScriptRoot "alpaca_journal.ps1")

$MemoryPath = Join-Path $PSScriptRoot "alpaca_ticker_memory.json"

# Module-scope stash so the caller (bot.ps1) can pass real scored candidates
# to Write-ScreenerReport instead of an empty array. Refreshed each
# Get-DynamicWatchlist call.
$script:LastScreenerCandidates = @()
function Get-LastScreenerCandidates { return $script:LastScreenerCandidates }

# ── Core anchors -- always in the list (market structure reference) ─────────────
$CORE_TICKERS = @("SPY", "QQQ")

# ── Leveraged / inverse ETF blocklist ─────────────────────────────────────────
# These amplify losses, have decay, and break stop/target math.
# Trade the underlying (QQQ, SPY) instead.
$LEVERAGED_BLOCKLIST = @(
    "TQQQ","SQQQ",       # 3x / -3x Nasdaq
    "SPXL","SPXS",       # 3x / -3x S&P 500
    "UPRO","SDS","SH",   # 3x / -2x / -1x S&P
    "UVXY","SVXY",       # VIX leveraged
    "SOXL","SOXS",       # 3x / -3x Semis
    "LABU","LABD",       # 3x / -3x Biotech
    "TNA","TZA",         # 3x / -3x Russell 2000
    "FNGU","FNGD",       # 3x / -3x FANG+
    "NUGT","DUST",       # 2x / -2x Gold Miners
    "JNUG","JDST"        # 2x / -2x Junior Gold Miners
)

# ── Trade ownership (SHARED Alpaca account) ───────────────────────────────────
# Another bot trades this same account. The ONLY durable marker of our own
# trades is the strategy prefix we stamp into every entry's client_order_id.
# Positions/orders without one of these prefixes belong to the other bot and
# must never be managed, counted, or learned from.
$MY_ENTRY_PREFIXES = @("BRKOUT","PULLBK","BRKDN","RALLYF","ORB","VWAP","EMA","PYRA")

# ── Correlated ticker groups ──────────────────────────────────────────────────
# Tickers in the same group are the same underlying exposure.
# The bot must never hold conflicting positions on the same group,
# and must not enter two tickers from the same group in one session.
$CORRELATED_GROUPS = @(
    @("QQQ","TQQQ","SQQQ"),                    # Nasdaq 100
    @("SPY","SPXL","SPXS","UPRO","SDS","SH"),  # S&P 500
    @("IWM","TNA","TZA"),                       # Russell 2000
    @("SOXX","SOXL","SOXS"),                    # Semiconductors
    @("GLD","NUGT","DUST","JNUG","JDST")        # Gold
)

function Get-CorrelatedGroup([string]$symbol) {
    foreach ($group in $CORRELATED_GROUPS) {
        if ($group -contains $symbol) { return $group }
    }
    return @($symbol)
}

function Test-CorrelationConflict([string]$symbol, [array]$existingPositions, [array]$sameScanEntries) {
    $group = Get-CorrelatedGroup $symbol
    if ($group.Count -le 1) { return $null }  # not in any group

    # Check existing positions
    foreach ($pos in $existingPositions) {
        if ($group -contains $pos.symbol) {
            return "correlated with open position $($pos.symbol) (same group: $($group -join ','))"
        }
    }
    # Check same-scan entries (prevent SQQQ + QQQ in one scan)
    foreach ($entry in $sameScanEntries) {
        if ($group -contains $entry) {
            return "correlated with same-scan entry $entry (same group: $($group -join ','))"
        }
    }
    return $null
}

# ── Broad liquid universe (~60 names) -- fallback when screener API unavailable ─
# Curated: mega-cap + high-beta tech + sector leaders + ETFs.
# Each name passes minimum liquidity bar: avg daily volume > 2M shares.
$UNIVERSE = @(
    # Mega-cap tech (deep liquidity, reacts to macro + sector)
    "AAPL","MSFT","NVDA","AMZN","META","GOOGL","TSLA","AMD","AVGO","QCOM",
    # High-beta semis / AI names (high ATR = more profit per trade)
    "MU","AMAT","MRVL","SMCI","ARM","LRCX","KLAC",
    # Cloud / cybersecurity (momentum names)
    "PLTR","SNOW","CRWD","PANW","NET","DDOG","ZS",
    # Finance (react to rates / macro)
    "JPM","BAC","GS","MS","C","V","MA","BX",
    # Energy (crude oil correlation, volatile)
    "XOM","CVX","OXY","SLB","MPC",
    # Healthcare / biotech (gap plays on FDA / earnings)
    "UNH","LLY","PFE","MRNA","ABBV","ISRG",
    # Consumer discretionary
    "HD","NKE","SBUX","COST","TGT","CMG",
    # Sector ETFs (rotation signal + direct trades)
    "IWM","XLK","XLF","XLE","SOXX","GLD","TLT"
)

# ── Memory ────────────────────────────────────────────────────────────────────

function Load-TickerMemory {
    $mem = $null
    if (Test-Path $MemoryPath) {
        try { $mem = Get-Content $MemoryPath -Raw | ConvertFrom-Json } catch {}
    }
    if ($null -eq $mem) {
        $mem = [pscustomobject]@{
            tickers        = [pscustomobject]@{}
            last_updated   = ""
            last_screened  = ""
            total_trades   = 0
        }
    }
    # Backward compat -- ensure the new self-learning rollups exist
    foreach ($prop in @("strategy_stats","hour_stats","regime_stats","strategy_regime_stats")) {
        if (-not (Get-Member -InputObject $mem -Name $prop -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
            $mem | Add-Member -NotePropertyName $prop -NotePropertyValue ([pscustomobject]@{}) -Force
        }
    }
    return $mem
}

# ── Self-learning rollup helpers ──────────────────────────────────────────────
# These three blocks let the bot answer: "What's my edge right now?"
#   strategy_stats  -> per-strategy global win rate
#   hour_stats      -> per-hour-of-day (ET) global win rate
#   regime_stats    -> per-regime global win rate

function _Update-RollupBucket($container, [string]$key, [bool]$won, [double]$pnl) {
    if (-not (Get-Member -InputObject $container -Name $key -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $container | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{
            trades = 0; wins = 0; losses = 0; total_pnl = 0.0; win_rate = 0.0; avg_pnl = 0.0
            gross_profit = 0.0; gross_loss = 0.0; profit_factor = 0.0
        }) -Force
    }
    $b = $container.$key
    # Backward compat: pre-expectancy buckets lack gross fields. They start
    # accumulating from now (historical splits are unrecoverable from totals).
    foreach ($f in @("gross_profit","gross_loss","profit_factor")) {
        if (-not (Get-Member -InputObject $b -Name $f -ErrorAction SilentlyContinue)) {
            $b | Add-Member -NotePropertyName $f -NotePropertyValue 0.0 -Force
        }
    }
    $b.trades++
    if ($won) { $b.wins++; $b.gross_profit = [Math]::Round($b.gross_profit + [Math]::Max(0,$pnl), 2) }
    else      { $b.losses++; $b.gross_loss = [Math]::Round($b.gross_loss + [Math]::Abs([Math]::Min(0,$pnl)), 2) }
    $b.total_pnl = [Math]::Round($b.total_pnl + $pnl, 2)
    $b.win_rate  = if ($b.trades -gt 0) { [Math]::Round($b.wins / $b.trades, 3) } else { 0.0 }
    $b.avg_pnl   = if ($b.trades -gt 0) { [Math]::Round($b.total_pnl / $b.trades, 2) } else { 0.0 }
    # avg_pnl IS the expectancy per trade; profit_factor = gross win / gross loss
    $b.profit_factor = if ($b.gross_loss -gt 0) { [Math]::Round($b.gross_profit / $b.gross_loss, 2) }
                       elseif ($b.gross_profit -gt 0) { 99.0 } else { 0.0 }
}

function Get-StrategyEdge {
    # Returns a position-size multiplier based on the strategy's historical
    # record. Ladder is win-rate based, extended by PROFIT FACTOR at larger
    # samples (a 60% WR strategy whose wins are tiny should not size up), and
    # adjusted by the strategy's record in the CURRENT regime when known.
    # Cold-start (sample <5): cautious 0.75x. Hard cap 1.75x (and effective
    # risk stays capped at 1.5% in Get-PositionSize regardless).
    param([string]$strategy, [string]$regime = "")
    $mem = Load-TickerMemory
    if (-not (Get-Member -InputObject $mem.strategy_stats -Name $strategy -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Trades = 0; WinRate = 0.0; Mult = 0.75; Reason = "cold-start" }
    }
    $s = $mem.strategy_stats.$strategy
    if ($s.trades -lt 5) {
        return [pscustomobject]@{ Trades = $s.trades; WinRate = $s.win_rate; Mult = 0.75; Reason = "sample<5" }
    }
    $pf = if (Get-Member -InputObject $s -Name "profit_factor" -ErrorAction SilentlyContinue) { [double]$s.profit_factor } else { 0.0 }
    $wrStr = "{0:P0}" -f $s.win_rate
    $mult = 1.0; $reason = "neutral edge"
    if ($s.win_rate -ge 0.60) {
        # Extended ladder: size up further only when BOTH the sample and the
        # payoff quality justify it. Win rate alone can be luck at N=5.
        if     ($s.trades -ge 20 -and $pf -ge 1.8) { $mult = 1.75; $reason = "elite edge ($wrStr, PF $pf, n=$($s.trades))" }
        elseif ($s.trades -ge 10 -and $pf -ge 1.5) { $mult = 1.50; $reason = "strong proven edge ($wrStr, PF $pf)" }
        else                                       { $mult = 1.25; $reason = "proven edge ($wrStr)" }
    }
    elseif($s.win_rate -ge 0.45) { $mult = 1.00; $reason = "marginal edge ($wrStr)" }
    elseif($s.win_rate -ge 0.35) { $mult = 0.65; $reason = "weak edge ($wrStr) -- cut size" }
    else                          { $mult = 0.40; $reason = "negative edge ($wrStr) -- minimal size" }

    # Regime-context adjustment: if this strategy has a meaningful record in
    # the CURRENT regime, let that record modulate the size.
    if ($regime -ne "") {
        $rkey = "{0}|{1}" -f $strategy, $regime
        if (Get-Member -InputObject $mem.strategy_regime_stats -Name $rkey -ErrorAction SilentlyContinue) {
            $sr = $mem.strategy_regime_stats.$rkey
            if ($sr.trades -ge 5) {
                if ($sr.avg_pnl -lt 0) {
                    $mult = [Math]::Round($mult * 0.5, 3)
                    $reason += " | negative in $regime (n=$($sr.trades)) x0.5"
                } elseif ($sr.win_rate -ge 0.60) {
                    $mult = [Math]::Round($mult * 1.1, 3)
                    $reason += " | thrives in $regime x1.1"
                }
            }
        }
    }
    $mult = [Math]::Min(1.75, $mult)
    return [pscustomobject]@{ Trades = $s.trades; WinRate = $s.win_rate; Mult = $mult; Reason = $reason }
}

function Get-HourEdge {
    param([int]$hour)
    $mem = Load-TickerMemory
    $key = "$hour"
    if (-not (Get-Member -InputObject $mem.hour_stats -Name $key -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Trades = 0; WinRate = 0.0 }
    }
    return [pscustomobject]@{ Trades = $mem.hour_stats.$key.trades; WinRate = $mem.hour_stats.$key.win_rate }
}

# Returns the per-ticker memory score (0.1-3.0) computed in Update-TickerMemory.
# 1.0 = neutral (no history). Higher = proven performer, lower = poor performer.
# This is the single biggest hidden bug -- it was called from Score-Candidate
# and Get-CycleContext for weeks but never defined, so every candidate threw
# 'The term Get-TickerScore is not recognized' and the try/catch swallowed it
# silently. The exception-message-prefix logging added today finally surfaced it.
function Get-TickerScore {
    param([string]$symbol)
    $mem = Load-TickerMemory
    if ($null -eq $mem.tickers) { return 1.0 }
    if (-not (Get-Member -InputObject $mem.tickers -Name $symbol -ErrorAction SilentlyContinue)) {
        return 1.0
    }
    $t = $mem.tickers.$symbol
    if ($null -eq $t -or $null -eq $t.score) { return 1.0 }
    return [double]$t.score
}

# Full memory record for a ticker (or $null if never traded). Used by the
# entry loop's memory gate and loss-cooldown checks.
function Get-TickerMemoryInfo {
    param([string]$symbol)
    $mem = Load-TickerMemory
    if ($null -eq $mem.tickers) { return $null }
    if (-not (Get-Member -InputObject $mem.tickers -Name $symbol -ErrorAction SilentlyContinue)) { return $null }
    return $mem.tickers.$symbol
}

# Index ETF anchors: kept on the watchlist for market visibility, but NOT
# tradeable. Evidence (swing era, Jun 15 - Jul 10): QQQ 2W/10L -$1,663 from
# pullback churn in range-bound tape; SPY 4W/4L -$37. The anchors were
# force-included daily, bypassing the memory suppression that would have
# benched any screened stock with QQQ's record (score 0.1, 17% WR).
$INDEX_ANCHORS = @("SPY","QQQ")

function Save-TickerMemory($mem) {
    $mem.last_updated = (Get-Date).ToString("o")
    $mem | ConvertTo-Json -Depth 10 | Set-Content $MemoryPath
}

function Update-TickerMemory {
    param(
        [string]$symbol,
        [bool]$won,
        [double]$pnl,
        [string]$strategy = "UNKNOWN",
        [int]$hourET      = -1,        # ET hour the trade closed; -1 = skip hour rollup
        [string]$regime   = ""          # market regime at entry; "" = skip regime rollup
    )
    $mem = Load-TickerMemory

    # ── Self-learning rollups: strategy / hour / regime ─────────────────────
    # These feed sizing and filtering. Update them BEFORE the per-ticker block
    # so that even if the ticker block fails, the global edge stats are kept.
    _Update-RollupBucket $mem.strategy_stats $strategy $won $pnl
    if ($hourET -ge 0)        { _Update-RollupBucket $mem.hour_stats   "$hourET" $won $pnl }
    if ($regime -ne "")       { _Update-RollupBucket $mem.regime_stats $regime    $won $pnl }
    # Setup-in-context: strategy performance PER regime (e.g. "BRKOUT|BULL").
    # Feeds Get-StrategyEdge so a setup that only works in trending tape gets
    # sized down when the tape is chopping.
    if ($regime -ne "" -and $strategy -ne "UNKNOWN") {
        _Update-RollupBucket $mem.strategy_regime_stats ("{0}|{1}" -f $strategy, $regime) $won $pnl
    }

    # Init record if new ticker
    if ($null -eq $mem.tickers.$symbol) {
        $mem.tickers | Add-Member -NotePropertyName $symbol -NotePropertyValue (
            [pscustomobject]@{
                trades             = 0
                wins               = 0
                losses             = 0
                total_pnl          = 0.0
                avg_pnl            = 0.0
                win_rate           = 0.0
                score              = 1.0
                consecutive_losses = 0
                best_strategy      = ""
                strategy_wins      = [pscustomobject]@{}
                strategy_trades    = [pscustomobject]@{}
                last_trade         = ""
                added_count        = 0   # how many times screener selected it
            }
        ) -Force
    }

    $t = $mem.tickers.$symbol
    $t.trades++
    $mem.total_trades++
    $t.total_pnl  = [Math]::Round($t.total_pnl + $pnl, 2)
    $t.avg_pnl    = [Math]::Round($t.total_pnl / $t.trades, 2)
    $t.last_trade = (Get-Date).ToString("o")

    if ($won) {
        $t.wins++
        $t.consecutive_losses = 0
    } else {
        $t.losses++
        $t.consecutive_losses++
    }

    $t.win_rate = [Math]::Round($t.wins / $t.trades, 3)

    # Per-strategy tracking
    if (-not (Get-Member -InputObject $t.strategy_trades -Name $strategy -ErrorAction SilentlyContinue)) {
        $t.strategy_trades | Add-Member -NotePropertyName $strategy -NotePropertyValue 0 -Force
        $t.strategy_wins   | Add-Member -NotePropertyName $strategy -NotePropertyValue 0 -Force
    }
    $t.strategy_trades.$strategy++
    if ($won) { $t.strategy_wins.$strategy++ }

    # Find best strategy (min 3 trades to qualify)
    $bestStrat = ""; $bestWR = 0.0
    foreach ($s in ($t.strategy_trades | Get-Member -MemberType NoteProperty).Name) {
        $st = $t.strategy_trades.$s
        $sw = $t.strategy_wins.$s
        if ($st -ge 3) {
            $wr = $sw / $st
            if ($wr -gt $bestWR) { $bestWR = $wr; $bestStrat = $s }
        }
    }
    $t.best_strategy = $bestStrat

    # ── Dynamic score (0.1 - 3.0) ──────────────────────────────────────────
    # Based on win rate, avg P&L, and consistency.
    # A seasoned analyst would weight recent trades more, but with small N
    # we use overall record plus streak penalty.
    $score = 1.0

    if ($t.trades -ge 3) {
        $wr = $t.win_rate
        if    ($wr -ge 0.70) { $score += 0.6 }   # elite performer
        elseif($wr -ge 0.60) { $score += 0.4 }   # good
        elseif($wr -ge 0.50) { $score += 0.2 }   # slightly above breakeven
        elseif($wr -lt 0.35) { $score -= 0.4 }   # underperformer
        elseif($wr -lt 0.25) { $score -= 0.6 }   # avoid
    }

    # Avg P&L bonus / penalty
    if    ($t.avg_pnl -ge  100) { $score += 0.3 }
    elseif($t.avg_pnl -ge   40) { $score += 0.15 }
    elseif($t.avg_pnl -le  -80) { $score -= 0.3 }
    elseif($t.avg_pnl -le  -40) { $score -= 0.15 }

    # Losing streak -- cool-off penalty
    if ($t.consecutive_losses -ge 4) { $score -= 0.5 }
    elseif ($t.consecutive_losses -ge 2) { $score -= 0.2 }

    $t.score = [Math]::Round([Math]::Max(0.1, [Math]::Min(3.0, $score)), 3)

    Save-TickerMemory $mem
    Write-Host ("  [MEMORY] {0,-6}  W:{1} L:{2}  WR:{3:P0}  AvgPnL:`${4}  Score:{5}" -f `
        $symbol, $t.wins, $t.losses, $t.win_rate, $t.avg_pnl, $t.score)
}

# ── Alpaca Screener API (v1beta1) ─────────────────────────────────────────────

function Get-MostActives($cfg, [int]$top = 25) {
    $uri = "https://data.alpaca.markets/v1beta1/screener/stocks/most-actives?by=volume&top=$top"
    $headers = @{
        "APCA-API-KEY-ID"     = $cfg.api_key
        "APCA-API-SECRET-KEY" = $cfg.api_secret
    }
    try {
        $r = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing
        return $r.most_actives
    } catch { return $null }
}

function Get-TopMovers($cfg, [int]$top = 20) {
    $uri = "https://data.alpaca.markets/v1beta1/screener/stocks/movers?market_type=stocks&top=$top"
    $headers = @{
        "APCA-API-KEY-ID"     = $cfg.api_key
        "APCA-API-SECRET-KEY" = $cfg.api_secret
    }
    try {
        $r = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing
        return $r
    } catch { return $null }
}

# ── Snapshot batch fetch ───────────────────────────────────────────────────────

function Get-Snapshots($cfg, [string[]]$symbols) {
    $joined = $symbols -join ","
    # No feed param -- uses best available (SIP if subscribed, IEX fallback)
    $uri    = "https://data.alpaca.markets/v2/stocks/snapshots?symbols=$joined"
    $headers = @{
        "APCA-API-KEY-ID"     = $cfg.api_key
        "APCA-API-SECRET-KEY" = $cfg.api_secret
    }
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing
    } catch { return $null }
}

# ── Candidate scoring engine ───────────────────────────────────────────────────
#
# Analyst lens: a good day-trade candidate today needs:
#   1. CATALYST  -- volume spike signals institutional interest or news
#   2. MOVEMENT  -- enough ATR to profit after spread; not flat
#   3. PRICE     -- in the sweet spot ($15-$450) for position sizing
#   4. GAP       -- pre-market direction gives momentum context
#   5. TRACK     -- has the bot worked well with this ticker before?

function Score-Candidate {
    param(
        [string]$symbol,
        [double]$price,
        [double]$gapPct,        # % gap from prev close
        [double]$rVol,          # relative volume (today / pace)
        [double]$dailyRangePct, # (H-L)/Close * 100  -- ATR proxy
        [double]$changeAbs,     # abs % change on day
        [double]$sessionFrac  = 1.0,  # 0.0 at open, 1.0 at close
        $newsInfo             = $null, # { Mentions, Sentiment, Lean, Headlines }
        [int]$daysToEarnings  = -1,    # -1 = no upcoming earnings; >=0 days
        [int]$blackoutDays    = 2,
        [int]$runupDays       = 10,
        $cycleCtx             = $null  # Get-CycleContext output -- adds cycle bonuses
    )

    $score  = 0.0
    $reasons = @()

    # ── 0. Leveraged ETF filter (hard reject) ─────────────────────────────
    if ($LEVERAGED_BLOCKLIST -contains $symbol) {
        return [pscustomobject]@{ Symbol = $symbol; Rejected = $true; Reason = "leveraged_etf_blocked" }
    }

    # ── 1. Price filter (hard reject outside $10-$500) ──────────────────────
    if ($price -lt 10 -or $price -gt 500) {
        return [pscustomobject]@{ Symbol = $symbol; Rejected = $true; Reason = "price_out_of_range" }
    }

    # Sweet-spot bonus
    if ($price -ge 20 -and $price -le 300) { $score += 0.5; $reasons += "price sweet-spot" }

    # ── 1b. Earnings blackout (hard reject in +/- blackout window) ──────────
    # Never hold through earnings -- the move is binary and unpredictable.
    if ($daysToEarnings -ge 0 -and $daysToEarnings -le $blackoutDays) {
        return [pscustomobject]@{ Symbol = $symbol; Rejected = $true; Reason = "earnings_blackout" }
    }

    # ── 2. Relative Volume -- #1 signal for day traders ──────────────────────
    $rVolStr = "{0:F2}" -f $rVol
    if    ($rVol -ge 4.0) { $score += 3.0; $reasons += "RVOL ${rVolStr}x EXTREME" }
    elseif($rVol -ge 2.5) { $score += 2.0; $reasons += "RVOL ${rVolStr}x HIGH" }
    elseif($rVol -ge 1.5) { $score += 1.0; $reasons += "RVOL ${rVolStr}x elevated" }
    elseif($rVol -lt 0.8) {
        return [pscustomobject]@{ Symbol = $symbol; Rejected = $true; Reason = "low_rvol_${rVolStr}" }
    }

    # ── 3. Gap -- catalyst/momentum signal ───────────────────────────────────
    $absGap    = [Math]::Abs($gapPct)
    $gapStr    = "{0:F1}" -f $gapPct
    if    ($absGap -ge 5.0) { $score += 2.0; $reasons += "gap ${gapStr}% LARGE" }
    elseif($absGap -ge 2.0) { $score += 1.2; $reasons += "gap ${gapStr}%" }
    elseif($absGap -ge 0.8) { $score += 0.5; $reasons += "gap ${gapStr}% small" }

    # ── 4. Intraday range -- need movement to profit ──────────────────────────
    # Hard-reject floor scales with session progress: at 10 AM only ~8% of the
    # day has elapsed, so demanding 0.5% range is unrealistic; demand ~0.15%.
    $rngFloor = [Math]::Max(0.10, 0.5 * $sessionFrac)
    $rngStr = "{0:F1}" -f $dailyRangePct
    if    ($dailyRangePct -ge 3.0)        { $score += 1.5; $reasons += "range ${rngStr}% HIGH" }
    elseif($dailyRangePct -ge 1.5)        { $score += 1.0; $reasons += "range ${rngStr}% good" }
    elseif($dailyRangePct -ge 0.5)        { $score += 0.3; $reasons += "range ${rngStr}% ok" }
    elseif($dailyRangePct -ge $rngFloor)  { $score += 0.1; $reasons += "range ${rngStr}% early" }
    else {
        return [pscustomobject]@{ Symbol = $symbol; Rejected = $true; Reason = "flat_range_${rngStr}" }
    }

    # ── 5. Directional momentum ─────────────────────────────────────────────
    $chgStr = "{0:F1}" -f $changeAbs
    if ($changeAbs -ge 3.0) { $score += 0.8; $reasons += "moving ${chgStr}%" }

    # ── 6. News catalyst ────────────────────────────────────────────────────
    # Active news cycle = institutional eyes are on this name today.
    if ($null -ne $newsInfo) {
        $score += 1.5; $reasons += ("news cycle x{0}" -f $newsInfo.Mentions)
        if ($newsInfo.Lean -eq "bull") {
            $score += 0.5; $reasons += "headline lean BULL"
        } elseif ($newsInfo.Lean -eq "bear") {
            $score -= 0.5; $reasons += "headline lean BEAR"
        }
    }

    # ── 7. Earnings run-up (3..runupDays before earnings) ──────────────────
    # Institutions often position ahead of earnings; volume + range expand.
    if ($daysToEarnings -gt $blackoutDays -and $daysToEarnings -le $runupDays) {
        $score += 1.0; $reasons += ("earnings in ${daysToEarnings}d (run-up)")
    }

    # ── Cycle Leader bonuses (cycle screener overlay) ──────────────────────
    # Each of these can stack -- a name that's accelerating, in a hot sector,
    # gapping pre-market, AND riding a hot theme is the textbook early cycle
    # leader. Bonuses sum but each is bounded individually.
    if ($null -ne $cycleCtx) {
        if ($cycleCtx.Acceleration -and $cycleCtx.Acceleration.IsAccelerating) {
            $score += 2.5
            $reasons += ("news accel {0}->{1}" -f $cycleCtx.Acceleration.Mentions48h, $cycleCtx.Acceleration.Mentions24h)
            if ($cycleCtx.Acceleration.Lean -eq "bull") { $score += 1.0; $reasons += "accel BULL lean" }
            elseif ($cycleCtx.Acceleration.Lean -eq "bear") { $score -= 0.5 }
        }
        if ($cycleCtx.Premarket -and $cycleCtx.Premarket.Strength -gt 0) {
            $pmStr = "{0:F1}" -f $cycleCtx.Premarket.GapPct
            $score += $cycleCtx.Premarket.Strength
            $reasons += ("premkt gap ${pmStr}% strength " + $cycleCtx.Premarket.Strength)
        }
        if ($cycleCtx.SectorHeat -ge 1.0) {
            $shStr = "{0:F2}" -f $cycleCtx.SectorHeat
            $score += 2.0
            $reasons += ("sector " + $cycleCtx.Sector + " hot +${shStr}% vs SPY")
        } elseif ($cycleCtx.SectorHeat -le -1.0) {
            $score -= 1.0
            $reasons += ("sector " + $cycleCtx.Sector + " weak")
        }
        if ($cycleCtx.Theme -and $cycleCtx.Theme.Matches) {
            $score += 1.5
            $reasons += ("theme: " + (($cycleCtx.Theme.Themes | Select-Object -First 2) -join ","))
        }
        if ($cycleCtx.Technical -and $cycleCtx.Technical.NearAth -and $cycleCtx.Technical.VolumeDryUp) {
            $score += 2.2
            $reasons += "coiling near ATH"
        }
    }

    # ── 8. Historical performance memory ────────────────────────────────────
    $memScore = Get-TickerScore $symbol
    $memStr   = "{0:F2}" -f $memScore
    if    ($memScore -ge 1.5) { $score += 1.0; $reasons += "memory ${memStr} proven" }
    elseif($memScore -ge 1.0) { $score += 0.3 }
    elseif($memScore -le 0.5) { $score -= 0.8; $reasons += "memory ${memStr} poor" }

    $candidate = [pscustomobject]@{
        Symbol         = $symbol
        Rejected       = $false
        Score          = [Math]::Round($score, 2)
        Price          = [Math]::Round($price, 2)
        GapPct         = [Math]::Round($gapPct, 2)
        RVol           = [Math]::Round($rVol, 2)
        RangePct       = [Math]::Round($dailyRangePct, 2)
        ChangeAbs      = [Math]::Round($changeAbs, 2)
        MemScore       = $memScore
        Reasons        = $reasons
        Tier           = 3   # default; overwritten by tiering pass downstream
    }
    if ($null -ne $cycleCtx) {
        $candidate.Tier = Get-WatchlistTier $candidate $cycleCtx
    }
    return $candidate
}

# ── Main screener ──────────────────────────────────────────────────────────────

function Get-DynamicWatchlist {
    param($cfg, [int]$maxTickers = 12)

    Write-Host ""
    Write-Host "  [SCREENER] Building dynamic watchlist..." -ForegroundColor Cyan

    $candidates = @()

    # Build a local candidate pool (script-scope $UNIVERSE is immutable inside function)
    $pool = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $UNIVERSE) { $pool.Add($s) }

    # ── News catalysts -- pull active-cycle tickers into the pool ───────────
    $newsCatalysts = @{}
    if ($cfg.news_catalyst_enabled) {
        $lookback = if ($cfg.news_lookback_hours) { [int]$cfg.news_lookback_hours } else { 24 }
        $minMent  = if ($cfg.news_min_mentions)   { [int]$cfg.news_min_mentions   } else { 2 }
        $newsCatalysts = Get-NewsCatalysts $cfg $lookback $minMent
        foreach ($sym in $newsCatalysts.Keys) {
            if (-not $pool.Contains($sym)) { $pool.Add($sym) }
        }
    }

    # ── Cycle screener prep: 48h news (cached) + sector momentum (once) ────
    $cycleEnabled = ($cfg.cycle_screener_enabled -ne $false)
    $news48h      = if ($cycleEnabled) { Get-NewsRaw48h $cfg } else { $null }
    $sectorMomentum = if ($cycleEnabled) { Get-SectorMomentum $cfg } else { @{} }
    if ($cycleEnabled -and $sectorMomentum.Count -gt 0) {
        $topSec = $sectorMomentum.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3
        Write-Host ("  [CYCLE] Sector heat vs SPY: " + (($topSec | ForEach-Object { "$($_.Name) +$($_.Value)%" }) -join ", ")) -ForegroundColor DarkGray
    }

    # ── Earnings calendar pre-load ──────────────────────────────────────────
    $blackoutDays = if ($cfg.earnings_blackout_days) { [int]$cfg.earnings_blackout_days } else { 2 }
    $runupDays    = if ($cfg.earnings_runup_days)    { [int]$cfg.earnings_runup_days    } else { 10 }

    # ── Step 1: Try Alpaca most-actives API first ────────────────────────────
    $actives = Get-MostActives $cfg 30
    if ($null -ne $actives -and $actives.Count -gt 0) {
        Write-Host ("  [SCREENER] Alpaca most-actives API: {0} symbols" -f $actives.Count)
        foreach ($a in $actives) {
            if ($a.symbol -match "[^A-Z]") { continue }  # skip non-standard symbols
            if ($a.symbol.Length -gt 5)    { continue }  # skip ETNs/warrants
            if (-not $pool.Contains($a.symbol)) { $pool.Add($a.symbol) }
        }
    }

    # ── Step 2: Try top movers (gainers + losers) ───────────────────────────
    $movers = Get-TopMovers $cfg 20
    if ($null -ne $movers) {
        $allMovers = @()
        if ($movers.gainers) { $allMovers += $movers.gainers }
        if ($movers.losers)  { $allMovers += $movers.losers  }
        Write-Host ("  [SCREENER] Top movers: {0} symbols" -f $allMovers.Count)
        foreach ($m in $allMovers) {
            if ($m.symbol -match "[^A-Z]") { continue }
            if ($m.symbol.Length -gt 5)    { continue }
            if (-not $pool.Contains($m.symbol)) { $pool.Add($m.symbol) }
        }
    }

    # ── Step 3: Batch snapshot all candidates ───────────────────────────────
    # Split into batches of 40 (API limit per call)
    $allSymbols = ($pool.ToArray() | Select-Object -Unique)
    Write-Host ("  [SCREENER] Fetching snapshots for {0} symbols..." -f $allSymbols.Count)

    $snapshots = [pscustomobject]@{}
    $batchSize = 40
    for ($i = 0; $i -lt $allSymbols.Count; $i += $batchSize) {
        $batch = $allSymbols[$i..([Math]::Min($i + $batchSize - 1, $allSymbols.Count - 1))]
        $snap  = Get-Snapshots $cfg $batch
        if ($null -ne $snap) {
            foreach ($sym in ($snap | Get-Member -MemberType NoteProperty).Name) {
                $snapshots | Add-Member -NotePropertyName $sym -NotePropertyValue $snap.$sym -Force
            }
        }
    }

    # ── Session-progress factor for time-of-day adjusted RVOL ────────────────
    # Compares today's cumulative volume to (prev full-day vol * % of session elapsed).
    # Without this, RVOL is meaningless before ~3 PM ET because the numerator is
    # only a slice of the day while the denominator is a full prior day.
    $etScreen = Get-EasternTime
    $marketOpen  = $etScreen.Date.AddHours(9).AddMinutes(30)
    $marketClose = $etScreen.Date.AddHours(16)
    $sessionMin   = ($marketClose - $marketOpen).TotalMinutes   # 390
    $elapsedMin   = [Math]::Max(1.0, [Math]::Min($sessionMin, ($etScreen - $marketOpen).TotalMinutes))
    $sessionFrac  = $elapsedMin / $sessionMin                   # 0.0 -> 1.0
    Write-Host ("  [SCREENER] Session progress: {0:P0} ({1:F0} min)" -f $sessionFrac, $elapsedMin) -ForegroundColor DarkGray

    # ── Step 4: Score each candidate ────────────────────────────────────────
    # Track rejection reasons so we can see WHY everything's getting filtered.
    # Inline tally instead of inner function -- PowerShell's nested function
    # scoping made the previous version throw on every iteration ('exception=87'
    # in production). Inline is uglier but bulletproof.
    $rejectTally = @{}
    foreach ($sym in ($snapshots | Get-Member -MemberType NoteProperty).Name) {
        $s = $snapshots.$sym
        try {
            $daily  = $s.dailyBar
            $prev   = $s.prevDailyBar

            if ($null -eq $daily -or $null -eq $prev) {
                if (-not $rejectTally.ContainsKey("missing_bars")) { $rejectTally["missing_bars"] = 0 }
                $rejectTally["missing_bars"]++
                continue
            }

            # Price: prefer latestTrade, fall back to dailyBar close
            $price = 0.0
            if ($null -ne $s.latestTrade -and $s.latestTrade.p) {
                $price = [double]$s.latestTrade.p
            }
            if ($price -le 0 -and $daily.c) { $price = [double]$daily.c }
            if ($price -le 0) { continue }

            $prevClose = if ($prev.c) { [double]$prev.c } else { continue }
            $dayOpen   = if ($daily.o) { [double]$daily.o } else { $prevClose }
            $dayHigh   = if ($daily.h) { [double]$daily.h } else { $price }
            $dayLow    = if ($daily.l) { [double]$daily.l } else { $price }
            $dayVol    = if ($daily.v) { [double]$daily.v } else { 0 }
            $prevVol   = if ($prev.v)  { [double]$prev.v  } else { 0 }

            if ($prevClose -le 0 -or $price -le 0) { continue }

            # Calculate metrics
            $gapPct        = ($dayOpen - $prevClose) / $prevClose * 100
            $changePct     = ($price   - $prevClose) / $prevClose * 100
            $dailyRangePct = if ($price -gt 0) { ($dayHigh - $dayLow) / $price * 100 } else { 0 }

            # Time-of-day adjusted RVOL: today's vol vs (prev full day * fraction elapsed)
            # >1.0  -> above pace, <1.0 -> below pace. Fair comparison at any hour.
            $expectedVol = $prevVol * $sessionFrac
            $rVol        = if ($expectedVol -gt 0) { $dayVol / $expectedVol } else { 1.0 }

            # Look up news + earnings context for this symbol
            $newsInfo = if ($newsCatalysts.ContainsKey($sym)) { $newsCatalysts[$sym] } else { $null }
            $daysToER = if ($cfg.earnings_enabled) {
                $v = Get-DaysToEarnings $sym
                if ($null -eq $v) { -1 } else { [int]$v }
            } else { -1 }

            # Build cycle context: news accel, sector heat, theme, premkt
            $cycleCtx = $null
            if ($cycleEnabled) {
                $memScore = Get-TickerScore $sym
                $cycleCtx = Get-CycleContext $cfg $sym $prevClose $news48h $sectorMomentum $memScore
            }

            $c = Score-Candidate $sym $price $gapPct $rVol $dailyRangePct ([Math]::Abs($changePct)) `
                                 $sessionFrac $newsInfo $daysToER $blackoutDays $runupDays $cycleCtx
            if ($null -eq $c) {
                if (-not $rejectTally.ContainsKey("null_return")) { $rejectTally["null_return"] = 0 }
                $rejectTally["null_return"]++
                continue
            }
            if ($c.Rejected) {
                $r = if ($c.Reason) { $c.Reason } else { "unknown" }
                if (-not $rejectTally.ContainsKey($r)) { $rejectTally[$r] = 0 }
                $rejectTally[$r]++
                continue
            }
            $candidates += $c
        } catch {
            # Surface the exception message in the first occurrence so we don't
            # silently swallow future bugs the way the inner-function one was.
            $msg = $_.Exception.Message
            $key = "exception:" + ($msg.Substring(0, [Math]::Min(40, $msg.Length)))
            if (-not $rejectTally.ContainsKey($key)) { $rejectTally[$key] = 0 }
            $rejectTally[$key]++
            continue
        }
    }

    # ── Reject summary -- explicit visibility into screener filter funnel ───
    if ($rejectTally.Count -gt 0) {
        $summary = (($rejectTally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object {
            "$($_.Name)=$($_.Value)"
        }) -join " ")
        Write-Host ("  [SCREENER] Rejects ({0} candidates): {1}" -f $candidates.Count, $summary) -ForegroundColor DarkGray
    }

    # ── Step 5: Rank and select ──────────────────────────────────────────────
    # Tier first (1 highest conviction -> 3 fallback), then Score within tier.
    # Result: T1 leaders scanned before T2 standard before T3 memory-only,
    # so the limited daily trade slots go to the strongest setups first.
    $ranked = $candidates | Sort-Object @{Expression="Tier";Ascending=$true}, @{Expression="Score";Descending=$true}

    # Tier summary for visibility
    $tCounts = @{}
    foreach ($c in $candidates) {
        $t = if ($c.Tier) { $c.Tier } else { 3 }
        if (-not $tCounts.ContainsKey($t)) { $tCounts[$t] = 0 }
        $tCounts[$t]++
    }
    if ($tCounts.Count -gt 0) {
        $tStr = (($tCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "T$($_.Name)=$($_.Value)" }) -join " ")
        Write-Host ("  [CYCLE] Tier distribution: $tStr") -ForegroundColor DarkGray
    }

    # Core anchors always included (treated as Tier 3 -- last-resort anchors)
    $watchlist = [System.Collections.Generic.List[string]]::new()
    foreach ($anchor in $CORE_TICKERS) { $watchlist.Add($anchor) }

    # Add top screened names IN TIER ORDER -- T1 first so they get scanned
    # before the daily trade budget is consumed.
    $added = 0
    $maxAdd = $maxTickers - $CORE_TICKERS.Count
    foreach ($c in $ranked) {
        if ($watchlist.Contains($c.Symbol)) { continue }
        if ($added -ge $maxAdd) { break }
        $watchlist.Add($c.Symbol)
        $added++
    }

    # Bump memory-proven tickers if not already included
    $mem = Load-TickerMemory
    foreach ($sym in (($mem.tickers | Get-Member -MemberType NoteProperty).Name | Sort-Object { -($mem.tickers.$_.score) })) {
        if ($watchlist.Count -ge $maxTickers) { break }
        if ($watchlist.Contains($sym)) { continue }
        $t = $mem.tickers.$sym
        if ($t.score -ge 1.3 -and $t.trades -ge 3) {
            $watchlist.Add($sym)
            Write-Host ("  [SCREENER] Added {0} from memory (score={1}, WR={2:P0})" -f $sym, $t.score, $t.win_rate)
        }
    }

    # Update memory: record how often each ticker was selected
    $mem = Load-TickerMemory
    $mem.last_screened = (Get-Date).ToString("o")
    foreach ($sym in $watchlist) {
        if ($null -ne $mem.tickers.$sym) {
            $mem.tickers.$sym.added_count++
        }
    }
    Save-TickerMemory $mem

    # Stash for Write-ScreenerReport so it can display real candidates
    $script:LastScreenerCandidates = @($candidates)

    return $watchlist.ToArray()
}

# ── Report ────────────────────────────────────────────────────────────────────

function Write-ScreenerReport($candidates, $selected) {
    Write-Host ""
    Write-Host ("  {0}" -f ("=" * 78))
    Write-Host "  SCREENER RESULTS"
    Write-Host ("  {0}" -f ("=" * 78))
    Write-Host ("  {0,-3} {1,-6}  {2,6}  {3,6}  {4,6}  {5,6}  {6,6}  {7}" -f `
        "Tr","Symbol","Score","Price","Gap%","RVOL","Range%","Reasons")
    Write-Host ("  {0}" -f ("-" * 78))
    $top = $candidates | Sort-Object @{Expression="Tier";Ascending=$true}, @{Expression="Score";Descending=$true} | Select-Object -First 15
    foreach ($c in $top) {
        $flag = if ($selected -contains $c.Symbol) { "*" } else { " " }
        $col  = if ($selected -contains $c.Symbol) { "Green" } else { "DarkGray" }
        $tier = if ($c.Tier) { "T$($c.Tier)" } else { "T3" }
        Write-Host ("  {0,-3} {1}{2,-6}  {3,6:F2}  {4,6:F2}  {5,5:F1}%  {6,5:F1}x  {7,5:F1}%  {8}" -f `
            $tier, $flag, $c.Symbol, $c.Score, $c.Price, $c.GapPct, `
            $c.RVol, $c.RangePct, ($c.Reasons -join " | ")) -ForegroundColor $col
    }
    Write-Host ("  {0}" -f ("=" * 78))
    Write-Host ("  Selected ({0}): {1}" -f $selected.Count, ($selected -join "  ")) -ForegroundColor Cyan
    Write-Host ""
}

# ── Closed position tracker ────────────────────────────────────────────────────
# Called each scan cycle to detect fills and update memory automatically.
#
# Design notes:
#   - Looks back 7 days (not just today) so exits from prior sessions get caught.
#   - Uses nested=true so each filled buy order carries its exit legs inline.
#     Alpaca bracket structure: parent buy -> legs[take_profit sell, stop_loss sell]
#     With nested=true the legs are embedded and NOT returned as top-level orders,
#     which eliminates the symbol-based pairing ambiguity of flat queries.
#   - Dedup guard: recorded_exits stores the sell-leg order ID; safe to re-run.

function Sync-ClosedTrades {
    param($cfg, $state)

    # Ensure recorded_exits exists (backward compat with old state files)
    if (-not (Get-Member -InputObject $state -Name "recorded_exits" -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $state | Add-Member -NotePropertyName "recorded_exits" -NotePropertyValue @() -Force
    }
    if ($null -eq $state.recorded_exits) { $state.recorded_exits = @() }

    # Look back 30 days. Swing trades can hold up to 12 TRADING days (~17
    # calendar days), so by the time an exit fills its ENTRY order may be
    # well over a week old -- a 7-day window dropped the entry and left the
    # exit unmatchable (both passes need entry + exit in the same window).
    # recorded_exits dedup makes the wider window safe against double-counting.
    $lookback = (Get-Date).ToUniversalTime().AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri      = "/v2/orders?status=closed&after=$lookback&direction=asc&limit=500&nested=true"

    $raw = $null
    try { $raw = Invoke-AlpacaApi $cfg "GET" $uri } catch {}
    if ($null -eq $raw) { return $state }

    # Normalise: Invoke-RestMethod returns PSCustomObject for single item, array otherwise
    $orders = if ($raw -is [System.Array]) { $raw } else { @($raw) }
    if ($orders.Count -eq 0) { return $state }

    # Today's ET date. The daily counters (wins/losses/pnl_today) drive the
    # day's discipline gates and must reflect ONLY today's realized exits --
    # a wider lookback (or a late-caught miss) can surface old exits, and
    # those must update lifetime MEMORY but NOT today's gate counters.
    try   { $tzD = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tzD = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $todayET = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tzD).ToString("yyyy-MM-dd")
    function Test-ExitToday($filledAt) {
        if (-not $filledAt) { return $false }
        try {
            $u = [datetime]::Parse($filledAt).ToUniversalTime()
            return ([System.TimeZoneInfo]::ConvertTimeFromUtc($u, $tzD).ToString("yyyy-MM-dd") -eq $todayET)
        } catch { return $false }
    }

    foreach ($o in $orders) {
        if ($null -eq $o) { continue }

        # We care about filled entry orders (buy for longs, sell for shorts)
        # that have bracket legs. Both directions produce bracket children.
        if ($o.status -ne "filled") { continue }
        if ($o.side -ne "buy" -and $o.side -ne "sell") { continue }
        if (-not $o.filled_avg_price -or -not $o.filled_qty) { continue }
        if (-not $o.legs -or $o.legs.Count -eq 0) { continue }

        $sym        = $o.symbol
        $entryPrice = [double]$o.filled_avg_price
        $qty        = [double]$o.filled_qty
        $entrySide  = $o.side   # "buy" = long entry, "sell" = short entry
        $exitSide   = if ($entrySide -eq "buy") { "sell" } else { "buy" }
        $strategy   = if ($o.client_order_id) { $o.client_order_id -replace "_.*","" } else { "UNKNOWN" }
        # SHARED ACCOUNT: only reconcile OUR trades. Skip the other bot's
        # brackets (no recognized strategy prefix) so they never hit our stats.
        if ($MY_ENTRY_PREFIXES -notcontains $strategy) { continue }

        # Find whichever exit leg filled (take-profit or stop-loss; the other will be canceled)
        foreach ($leg in $o.legs) {
            if ($null -eq $leg) { continue }
            if ($leg.side -ne $exitSide -or $leg.status -ne "filled") { continue }
            if (-not $leg.filled_avg_price) { continue }

            $exitId    = $leg.id
            if ($state.recorded_exits -contains $exitId) { continue }  # already processed

            $exitPrice = [double]$leg.filled_avg_price
            # Longs profit when exit > entry; shorts profit when entry > exit
            $pnl = if ($entrySide -eq "buy") {
                [Math]::Round(($exitPrice - $entryPrice) * $qty, 2)
            } else {
                [Math]::Round(($entryPrice - $exitPrice) * $qty, 2)
            }
            $won       = ($pnl -gt 0)

            # Derive the ET hour the exit filled (drives hour_stats rollup)
            $hourET = -1
            if ($leg.filled_at) {
                try {
                    $filledUtc = [datetime]::Parse($leg.filled_at).ToUniversalTime()
                    try   { $tzH = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
                    catch { $tzH = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
                    $hourET = [System.TimeZoneInfo]::ConvertTimeFromUtc($filledUtc, $tzH).Hour
                } catch {}
            }

            Write-Host ("  [LEARN] {0,-6} {1}  entry=`${2:F2}  exit=`${3:F2}  qty={4}  PnL=`${5:F2}  hr={6}ET" -f `
                $sym, (if ($won) { "WIN " } else { "LOSS" }), $entryPrice, $exitPrice, $qty, $pnl, $hourET) `
                -ForegroundColor (if ($won) { "Green" } else { "Red" })

            # Journal completion recovers the regime recorded at ENTRY --
            # the only reliable source for regime-aware expectancy stats.
            $jrec    = Complete-JournalEntry -symbol $sym -exitPrice $exitPrice -pnl $pnl -qty ([int]$qty)
            $jRegime = if ($null -ne $jrec -and $jrec.regime) { $jrec.regime } else { "" }
            Update-TickerMemory -symbol $sym -won $won -pnl $pnl -strategy $strategy -hourET $hourET -regime $jRegime

            $state.recorded_exits += $exitId
            # Daily gate counters move only for exits that actually filled today
            if (Test-ExitToday $leg.filled_at) {
                if ($won) { $state.wins++ } else { $state.losses++ }
                $state.pnl_today = [Math]::Round($state.pnl_today + $pnl, 2)
            }
        }
    }

    # ── PASS 2: standalone exits not captured as bracket legs ──────────────
    # Protective stops (PROTECT_*), EOD closes, and time-stop market closes
    # are NOT bracket children, so pass 1 misses them -- this is how MRVL's
    # break-even close went unrecorded. The bot ONLY ever enters via brackets,
    # so any filled top-level order with no legs (and order_class != bracket)
    # is a CLOSING order. Match it to the nearest preceding opposite-side
    # bracket entry for the same symbol to recover entry price + strategy.

    # Index filled bracket entries by symbol.
    $entriesBySym = @{}
    foreach ($o in $orders) {
        if ($null -eq $o -or $o.status -ne "filled") { continue }
        $isEntry = ($o.order_class -eq "bracket") -or ($o.legs -and $o.legs.Count -gt 0)
        if (-not $isEntry) { continue }
        if (-not $o.filled_avg_price -or -not $o.filled_at) { continue }
        # SHARED ACCOUNT: only index OUR entries so a standalone close can't be
        # matched to (and recorded against) the other bot's bracket.
        $oTag = if ($o.client_order_id) { ($o.client_order_id -split "_")[0] } else { "" }
        if ($MY_ENTRY_PREFIXES -notcontains $oTag) { continue }
        if (-not $entriesBySym.ContainsKey($o.symbol)) { $entriesBySym[$o.symbol] = @() }
        $entriesBySym[$o.symbol] += $o
    }

    foreach ($o in $orders) {
        if ($null -eq $o -or $o.status -ne "filled") { continue }
        if ($o.side -ne "buy" -and $o.side -ne "sell") { continue }
        if (-not $o.filled_avg_price -or -not $o.filled_qty -or -not $o.filled_at) { continue }
        # Skip bracket entries (pass 1) and anything carrying legs.
        if (($o.order_class -eq "bracket") -or ($o.legs -and $o.legs.Count -gt 0)) { continue }

        $exitId = $o.id
        if ($state.recorded_exits -contains $exitId) { continue }

        $sym      = $o.symbol
        $exitSide = $o.side
        # A long is closed by a sell; a short is closed by a buy.
        $entrySideNeeded = if ($exitSide -eq "buy") { "sell" } else { "buy" }
        if (-not $entriesBySym.ContainsKey($sym)) { continue }

        $exitTime = [datetime]::Parse($o.filled_at).ToUniversalTime()
        # Nearest preceding opposite-side entry whose OWN bracket leg did NOT
        # already fill (i.e. it wasn't already closed + recorded by pass 1).
        $match = $entriesBySym[$sym] | Where-Object {
            $_.side -eq $entrySideNeeded -and
            ([datetime]::Parse($_.filled_at).ToUniversalTime() -le $exitTime) -and
            -not (@($_.legs | Where-Object { $null -ne $_ -and $_.side -eq $exitSide -and $_.status -eq "filled" }).Count)
        } | Sort-Object { [datetime]::Parse($_.filled_at).ToUniversalTime() } -Descending | Select-Object -First 1
        if ($null -eq $match) { continue }

        $entryPrice = [double]$match.filled_avg_price
        $exitPrice  = [double]$o.filled_avg_price
        $qty        = [double]$o.filled_qty
        $entrySide  = $match.side
        $strategy   = if ($match.client_order_id) { $match.client_order_id -replace "_.*","" } else { "UNKNOWN" }
        $pnl = if ($entrySide -eq "buy") {
            [Math]::Round(($exitPrice - $entryPrice) * $qty, 2)
        } else {
            [Math]::Round(($entryPrice - $exitPrice) * $qty, 2)
        }
        $won = ($pnl -gt 0)

        $hourET = -1
        if ($o.filled_at) {
            try {
                $filledUtc = [datetime]::Parse($o.filled_at).ToUniversalTime()
                try   { $tzH = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
                catch { $tzH = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
                $hourET = [System.TimeZoneInfo]::ConvertTimeFromUtc($filledUtc, $tzH).Hour
            } catch {}
        }

        Write-Host ("  [LEARN*] {0,-6} {1}  entry=`${2:F2}  exit=`${3:F2}  qty={4}  PnL=`${5:F2}  hr={6}ET  (standalone close)" -f `
            $sym, (if ($won) { "WIN " } else { "LOSS" }), $entryPrice, $exitPrice, $qty, $pnl, $hourET) `
            -ForegroundColor (if ($won) { "Green" } else { "Red" })

        $jrec    = Complete-JournalEntry -symbol $sym -exitPrice $exitPrice -pnl $pnl -qty ([int]$qty)
        $jRegime = if ($null -ne $jrec -and $jrec.regime) { $jrec.regime } else { "" }
        Update-TickerMemory -symbol $sym -won $won -pnl $pnl -strategy $strategy -hourET $hourET -regime $jRegime

        $state.recorded_exits += $exitId
        # Daily gate counters move only for exits that actually filled today
        if (Test-ExitToday $o.filled_at) {
            if ($won) { $state.wins++ } else { $state.losses++ }
            $state.pnl_today = [Math]::Round($state.pnl_today + $pnl, 2)
        }
    }

    return $state
}
