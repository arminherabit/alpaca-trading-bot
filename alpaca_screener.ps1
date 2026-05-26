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

$MemoryPath = Join-Path $PSScriptRoot "alpaca_ticker_memory.json"

# ── Core anchors -- always in the list (market structure reference) ─────────────
$CORE_TICKERS = @("SPY", "QQQ")

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
    foreach ($prop in @("strategy_stats","hour_stats","regime_stats")) {
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
        }) -Force
    }
    $b = $container.$key
    $b.trades++
    if ($won) { $b.wins++ } else { $b.losses++ }
    $b.total_pnl = [Math]::Round($b.total_pnl + $pnl, 2)
    $b.win_rate  = if ($b.trades -gt 0) { [Math]::Round($b.wins / $b.trades, 3) } else { 0.0 }
    $b.avg_pnl   = if ($b.trades -gt 0) { [Math]::Round($b.total_pnl / $b.trades, 2) } else { 0.0 }
}

function Get-StrategyEdge {
    # Returns a position-size multiplier (0.5-1.25x) based on the strategy's
    # historical win rate. Cold-start (sample <5): cautious 0.75x.
    param([string]$strategy)
    $mem = Load-TickerMemory
    if (-not (Get-Member -InputObject $mem.strategy_stats -Name $strategy -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Trades = 0; WinRate = 0.0; Mult = 0.75; Reason = "cold-start" }
    }
    $s = $mem.strategy_stats.$strategy
    if ($s.trades -lt 5) {
        return [pscustomobject]@{ Trades = $s.trades; WinRate = $s.win_rate; Mult = 0.75; Reason = "sample<5" }
    }
    $wrStr = "{0:P0}" -f $s.win_rate
    $mult = 1.0; $reason = "neutral edge"
    if    ($s.win_rate -ge 0.60) { $mult = 1.25; $reason = "proven edge ($wrStr)" }
    elseif($s.win_rate -ge 0.45) { $mult = 1.00; $reason = "marginal edge ($wrStr)" }
    elseif($s.win_rate -ge 0.35) { $mult = 0.65; $reason = "weak edge ($wrStr) -- cut size" }
    else                          { $mult = 0.40; $reason = "negative edge ($wrStr) -- minimal size" }
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
        [double]$rVol,          # relative volume (today / avg)
        [double]$dailyRangePct, # (H-L)/Close * 100  -- ATR proxy
        [double]$changeAbs      # abs % change on day
    )

    $score  = 0.0
    $reasons = @()

    # ── 1. Price filter (hard reject outside $10-$500) ──────────────────────
    if ($price -lt 10 -or $price -gt 500) { return $null }

    # Sweet-spot bonus
    if ($price -ge 20 -and $price -le 300) { $score += 0.5; $reasons += "price sweet-spot" }

    # ── 2. Relative Volume -- #1 signal for day traders ──────────────────────
    $rVolStr = "{0:F2}" -f $rVol
    if    ($rVol -ge 4.0) { $score += 3.0; $reasons += "RVOL ${rVolStr}x EXTREME" }
    elseif($rVol -ge 2.5) { $score += 2.0; $reasons += "RVOL ${rVolStr}x HIGH" }
    elseif($rVol -ge 1.5) { $score += 1.0; $reasons += "RVOL ${rVolStr}x elevated" }
    elseif($rVol -lt 0.8) { return $null }  # dead -- no interest today

    # ── 3. Gap -- catalyst/momentum signal ───────────────────────────────────
    $absGap    = [Math]::Abs($gapPct)
    $gapStr    = "{0:F1}" -f $gapPct
    if    ($absGap -ge 5.0) { $score += 2.0; $reasons += "gap ${gapStr}% LARGE" }
    elseif($absGap -ge 2.0) { $score += 1.2; $reasons += "gap ${gapStr}%" }
    elseif($absGap -ge 0.8) { $score += 0.5; $reasons += "gap ${gapStr}% small" }

    # ── 4. Intraday range -- need movement to profit ──────────────────────────
    $rngStr = "{0:F1}" -f $dailyRangePct
    if    ($dailyRangePct -ge 3.0) { $score += 1.5; $reasons += "range ${rngStr}% HIGH" }
    elseif($dailyRangePct -ge 1.5) { $score += 1.0; $reasons += "range ${rngStr}% good" }
    elseif($dailyRangePct -ge 0.5) { $score += 0.3; $reasons += "range ${rngStr}% ok" }
    else                           { return $null }  # too flat, no profit opportunity

    # ── 5. Directional momentum ─────────────────────────────────────────────
    $chgStr = "{0:F1}" -f $changeAbs
    if ($changeAbs -ge 3.0) { $score += 0.8; $reasons += "moving ${chgStr}%" }

    # ── 6. Historical performance memory ────────────────────────────────────
    $memScore = Get-TickerScore $symbol
    $memStr   = "{0:F2}" -f $memScore
    if    ($memScore -ge 1.5) { $score += 1.0; $reasons += "memory ${memStr} proven" }
    elseif($memScore -ge 1.0) { $score += 0.3 }
    elseif($memScore -le 0.5) { $score -= 0.8; $reasons += "memory ${memStr} poor" }

    return [pscustomobject]@{
        Symbol         = $symbol
        Score          = [Math]::Round($score, 2)
        Price          = [Math]::Round($price, 2)
        GapPct         = [Math]::Round($gapPct, 2)
        RVol           = [Math]::Round($rVol, 2)
        RangePct       = [Math]::Round($dailyRangePct, 2)
        ChangeAbs      = [Math]::Round($changeAbs, 2)
        MemScore       = $memScore
        Reasons        = $reasons
    }
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

    # ── Step 4: Score each candidate ────────────────────────────────────────
    foreach ($sym in ($snapshots | Get-Member -MemberType NoteProperty).Name) {
        $s = $snapshots.$sym
        try {
            $daily  = $s.dailyBar
            $prev   = $s.prevDailyBar

            if ($null -eq $daily -or $null -eq $prev) { continue }

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
            $rVol          = if ($prevVol -gt 0) { $dayVol / $prevVol } else { 1.0 }

            $c = Score-Candidate $sym $price $gapPct $rVol $dailyRangePct ([Math]::Abs($changePct))
            if ($null -ne $c) { $candidates += $c }
        } catch { continue }
    }

    # ── Step 5: Rank and select ──────────────────────────────────────────────
    $ranked = $candidates | Sort-Object Score -Descending

    # Core anchors always included
    $watchlist = [System.Collections.Generic.List[string]]::new()
    foreach ($anchor in $CORE_TICKERS) { $watchlist.Add($anchor) }

    # Add top screened names (skip cores to avoid duplicate)
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

    return $watchlist.ToArray()
}

# ── Report ────────────────────────────────────────────────────────────────────

function Write-ScreenerReport($candidates, $selected) {
    Write-Host ""
    Write-Host ("  {0}" -f ("=" * 68))
    Write-Host "  SCREENER RESULTS"
    Write-Host ("  {0}" -f ("=" * 68))
    Write-Host ("  {0,-6}  {1,6}  {2,6}  {3,6}  {4,6}  {5,6}  {6}" -f `
        "Symbol","Score","Price","Gap%","RVOL","Range%","Reasons")
    Write-Host ("  {0}" -f ("-" * 68))
    $top = $candidates | Sort-Object Score -Descending | Select-Object -First 15
    foreach ($c in $top) {
        $flag = if ($selected -contains $c.Symbol) { "*" } else { " " }
        $col  = if ($selected -contains $c.Symbol) { "Green" } else { "DarkGray" }
        Write-Host ("  {0}{1,-6}  {2,6:F2}  {3,6:F2}  {4,5:F1}%  {5,5:F1}x  {6,5:F1}%  {7}" -f `
            $flag, $c.Symbol, $c.Score, $c.Price, $c.GapPct, `
            $c.RVol, $c.RangePct, ($c.Reasons -join " | ")) -ForegroundColor $col
    }
    Write-Host ("  {0}" -f ("=" * 68))
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

    # Look back 7 days -- recorded_exits prevents double-counting on repeat runs
    $lookback = (Get-Date).ToUniversalTime().AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri      = "/v2/orders?status=closed&after=$lookback&direction=asc&limit=500&nested=true"

    $raw = $null
    try { $raw = Invoke-AlpacaApi $cfg "GET" $uri } catch {}
    if ($null -eq $raw) { return $state }

    # Normalise: Invoke-RestMethod returns PSCustomObject for single item, array otherwise
    $orders = if ($raw -is [System.Array]) { $raw } else { @($raw) }
    if ($orders.Count -eq 0) { return $state }

    foreach ($o in $orders) {
        if ($null -eq $o) { continue }

        # We only care about filled buy (entry) orders that have bracket legs
        if ($o.side -ne "buy" -or $o.status -ne "filled") { continue }
        if (-not $o.filled_avg_price -or -not $o.filled_qty) { continue }
        if (-not $o.legs -or $o.legs.Count -eq 0) { continue }

        $sym        = $o.symbol
        $entryPrice = [double]$o.filled_avg_price
        $qty        = [double]$o.filled_qty
        $strategy   = if ($o.client_order_id) { $o.client_order_id -replace "_.*","" } else { "UNKNOWN" }

        # Find whichever sell leg filled (take-profit or stop-loss; the other will be canceled)
        foreach ($leg in $o.legs) {
            if ($null -eq $leg) { continue }
            if ($leg.side -ne "sell" -or $leg.status -ne "filled") { continue }
            if (-not $leg.filled_avg_price) { continue }

            $exitId    = $leg.id
            if ($state.recorded_exits -contains $exitId) { continue }  # already processed

            $exitPrice = [double]$leg.filled_avg_price
            $pnl       = [Math]::Round(($exitPrice - $entryPrice) * $qty, 2)
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

            Update-TickerMemory -symbol $sym -won $won -pnl $pnl -strategy $strategy -hourET $hourET

            $state.recorded_exits += $exitId
            if ($won) { $state.wins++ } else { $state.losses++ }
            $state.pnl_today = [Math]::Round($state.pnl_today + $pnl, 2)
        }
    }

    return $state
}
