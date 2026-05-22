# Alpaca Day Trading Bot
# Strategy: Scans dynamic watchlist every 10 min during market hours.
#   Generates ORB / VWAP Bounce / EMA Pullback signals.
#   Validates risk (1% rule, R:R >= 2.5, position limits).
#   Self-learning: dynamic screener refreshes watchlist each morning,
#   memory tracks per-ticker win rate and adjusts selection scores.
#   If require_approval=false AND paper_trading=true, auto-executes.

param(
    [switch]$Once,     # Run one scan cycle then exit
    [switch]$Approve,  # Approve pending trades and submit orders
    [switch]$Cancel,   # Cancel all open orders and flatten positions
    [string]$ApproveId # Approve a specific pending trade by ID
)

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_signals.ps1")
. (Join-Path $PSScriptRoot "alpaca_risk.ps1")
. (Join-Path $PSScriptRoot "alpaca_screener.ps1")
. (Join-Path $PSScriptRoot "alpaca_indicators.ps1")

$StatePath   = Join-Path $PSScriptRoot "alpaca_state.json"
$PendingPath = Join-Path $PSScriptRoot "pending_approval.json"

# ── State ─────────────────────────────────────────────────────────────────────

function Load-State {
    if (Test-Path $StatePath) {
        try { return Get-Content $StatePath -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{
        trades_today     = 0
        wins             = 0
        losses           = 0
        pnl_today        = 0.0
        last_scan        = ""
        session_start    = (Get-Date).ToString("o")
        watchlist_date   = ""    # date the dynamic watchlist was last built
        active_watchlist = @()   # today's screened watchlist
        recorded_exits   = @()   # order IDs already processed for memory
    }
}

function Save-State($s) { $s | ConvertTo-Json -Depth 5 | Set-Content $StatePath }

function Load-Pending {
    if (Test-Path $PendingPath) {
        try { return @(Get-Content $PendingPath | ConvertFrom-Json) } catch {}
    }
    return @()
}

function Save-Pending($pending) {
    if ($pending.Count -eq 0) {
        if (Test-Path $PendingPath) { Remove-Item $PendingPath -Force }
    } else {
        $pending | ConvertTo-Json -Depth 10 | Set-Content $PendingPath
    }
}

# ── Approve Mode ──────────────────────────────────────────────────────────────

function Invoke-ApprovePending($cfg) {
    $pending = Load-Pending
    if ($pending.Count -eq 0) {
        Write-Host "  No pending trades." -ForegroundColor Yellow
        return
    }

    foreach ($t in $pending) {
        $skip = ($ApproveId -ne "" -and $t.id -ne $ApproveId)
        if ($skip) { continue }

        Write-Host ""
        Write-Host ("  Submitting: {0} {1} x {2} @ `${3}  SL=`${4}  TP=`${5}" -f `
            $t.side.ToUpper(), $t.shares, $t.symbol, $t.entry, $t.stop, $t.t1) -ForegroundColor Cyan

        $order = Submit-BracketOrder $cfg $t.symbol $t.side $t.shares $t.entry $t.t1 $t.stop
        if ($null -ne $order) {
            Write-Host ("  Order submitted: {0}" -f $order.id) -ForegroundColor Green
        }
    }

    # Remove approved trades from queue (all or specific)
    if ($ApproveId -ne "") {
        $remaining = $pending | Where-Object { $_.id -ne $ApproveId }
        Save-Pending @($remaining)
    } else {
        Save-Pending @()
    }
}

# ── Cancel Mode ───────────────────────────────────────────────────────────────

function Invoke-CancelAll($cfg) {
    Write-Host "  Cancelling all open orders..." -ForegroundColor Yellow
    Cancel-AllOrders $cfg
    Write-Host "  Closing all positions..." -ForegroundColor Yellow
    $positions = Get-Positions $cfg
    foreach ($p in $positions) {
        Close-Position $cfg $p.symbol
        Write-Host ("  Closed: {0}" -f $p.symbol)
    }
    Save-Pending @()
    Write-Host "  All positions flattened." -ForegroundColor Green
}

# ── Market Bias (SPY 5-min trend) ─────────────────────────────────────────────
# A seasoned trader never fights the tape.
# Rule: only take long entries when SPY is in a confirmed uptrend on the 5-min chart.
# BULL  = close > 9 EMA > 20 EMA        → allow longs
# BEAR  = close < 9 EMA < 20 EMA        → block all new entries
# NEUTRAL = mixed (e.g. recent reversal) → allow longs but with tighter confidence

function Get-MarketBias($cfg) {
    $spyBars = Get-IntradayBars $cfg "SPY" "5Min"
    if ($null -eq $spyBars -or $spyBars.Count -lt 25) { return "NEUTRAL" }
    [double[]]$closes = $spyBars | ForEach-Object { $_.Close }
    $ema9  = Get-EMA $closes 9
    $ema20 = Get-EMA $closes 20
    if ($null -eq $ema9 -or $null -eq $ema20) { return "NEUTRAL" }
    $last = $closes[$closes.Count - 1]
    if ($last -gt $ema9 -and $ema9 -gt $ema20) { return "BULL"    }
    if ($last -lt $ema9 -and $ema9 -lt $ema20) { return "BEAR"    }
    return "NEUTRAL"
}

# ── Scan Cycle ────────────────────────────────────────────────────────────────

function Run-Scan($cfg, $state) {
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")

    Write-Host ""
    Write-Host ("=" * 70)
    Write-Host ("  ALPACA DAY TRADER  --  {0} UTC" -f $now)
    $modeStr = if ($cfg.paper_trading) { "PAPER" } else { "LIVE" }
    Write-Host ("  Mode: {0}  |  Interval: {1}s" -f $modeStr, $cfg.scan_interval_sec)
    Write-Host ("=" * 70)

    # ── Daily counter reset ────────────────────────────────────────────────────
    # Compare last-scan date (ET) to today; wipe P&L/trade counters each morning.
    $etNow   = Get-EasternTime
    $etToday = $etNow.ToString("yyyy-MM-dd")
    $lastScanET = ""
    if ($state.last_scan -and $state.last_scan -ne "") {
        try {
            $lastUtc = [datetime]::Parse($state.last_scan).ToUniversalTime()
            try   { $tzReset = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
            catch { $tzReset = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
            $lastScanET = [System.TimeZoneInfo]::ConvertTimeFromUtc($lastUtc, $tzReset).ToString("yyyy-MM-dd")
        } catch { $lastScanET = "" }
    }
    if ($lastScanET -ne "" -and $lastScanET -ne $etToday) {
        Write-Host ("  [RESET] New trading day ({0}) -- resetting daily counters." -f $etToday) -ForegroundColor Cyan
        $state.trades_today = 0
        $state.wins         = 0
        $state.losses       = 0
        $state.pnl_today    = 0.0
        Save-State $state
    }

    # Market hours check
    if (-not (Test-MarketOpen $cfg)) {
        Write-Host "  Market closed -- waiting." -ForegroundColor DarkGray
        $state.last_scan = (Get-Date).ToString("o")
        Save-State $state
        return
    }

    if (-not (Test-TradingWindow $cfg)) {
        Write-Host ("  Outside trading window ({0}-{1} ET, paused {2}-{3}) -- monitoring only." -f `
            $cfg.no_trade_before, $cfg.no_trade_after, $cfg.midday_pause_start, $cfg.midday_pause_end) -ForegroundColor Yellow
    }

    # ── Self-learning: sync closed trades -> update ticker memory ───────────
    $state = Sync-ClosedTrades $cfg $state

    # ── Market bias filter (SPY 5-min trend) ───────────────────────────────
    # Never fight the tape — skip longs entirely when SPY is in a downtrend.
    $marketBias = Get-MarketBias $cfg
    $biasColor  = switch ($marketBias) { "BULL" { "Green" } "BEAR" { "Red" } default { "Yellow" } }
    Write-Host ("  Market Bias (SPY 5m EMA): {0}" -f $marketBias) -ForegroundColor $biasColor

    # ── Dynamic watchlist: refresh once per trading day ─────────────────────
    # Ensure new properties exist on state (backward compat with old state.json)
    if (-not (Get-Member -InputObject $state -Name "watchlist_date"    -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $state | Add-Member -NotePropertyName "watchlist_date"    -NotePropertyValue "" -Force
    }
    if (-not (Get-Member -InputObject $state -Name "active_watchlist"  -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $state | Add-Member -NotePropertyName "active_watchlist"  -NotePropertyValue @() -Force
    }
    if (-not (Get-Member -InputObject $state -Name "recorded_exits"    -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $state | Add-Member -NotePropertyName "recorded_exits"    -NotePropertyValue @() -Force
    }

    # Screener runs once per day but NOT before 10:00 AM ET —
    # snapshot data at 9:31 AM is too thin to score RVOL and range properly.
    $screenerReady = ($etNow -ge $etNow.Date.AddHours(10))
    if ($state.watchlist_date -ne $etToday -and $screenerReady) {
        $maxW = if ($cfg.max_watchlist) { [int]$cfg.max_watchlist } else { 12 }
        $dynamicList = Get-DynamicWatchlist $cfg $maxW
        $state.active_watchlist = $dynamicList
        $state.watchlist_date   = $etToday
        Write-ScreenerReport @() $dynamicList
        Save-State $state
    } elseif ($state.watchlist_date -ne $etToday -and -not $screenerReady) {
        Write-Host ("  [SCREENER] Waiting until 10:00 AM ET for richer data (now {0} ET)" -f `
            $etNow.ToString("HH:mm")) -ForegroundColor DarkGray
    }

    # Use today's dynamic watchlist (fall back to config if empty)
    $watchlist = if ($state.active_watchlist -and $state.active_watchlist.Count -gt 0) {
        $state.active_watchlist
    } else {
        $cfg.watchlist
    }

    # Account summary
    $equity = Get-Equity $cfg
    $bp     = Get-BuyingPower $cfg
    $posCount = Get-PositionCount $cfg
    Write-Host ("  Equity: `${0:N2}  |  Buying Power: `${1:N2}  |  Positions: {2}/{3}" -f `
        $equity, $bp, $posCount, $cfg.max_positions)
    Write-Host ("  P&L Today: `${0:F2}  |  Trades: {1}  |  W/L: {2}/{3}" -f `
        $state.pnl_today, $state.trades_today, $state.wins, $state.losses)
    Write-Host ""

    # Show open positions
    $positions = Get-Positions $cfg
    if ($positions.Count -gt 0) {
        Write-Host "  Open Positions:"
        foreach ($p in $positions) {
            $pnl    = [double]$p.unrealized_pl
            $pnlPct = [double]$p.unrealized_plpc * 100
            $color  = if ($pnl -ge 0) { "Green" } else { "Red" }
            Write-Host ("    {0,-6} {1,5} shares @ `${2}  PnL: `${3:F2} ({4:F2}%)" -f `
                $p.symbol, $p.qty, $p.avg_entry_price, $pnl, $pnlPct) -ForegroundColor $color
        }
        Write-Host ""
    }

    # Skip new entries if at max positions or outside window
    if ($posCount -ge [int]$cfg.max_positions) {
        Write-Host "  Max positions reached -- monitoring exits only." -ForegroundColor Yellow
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state
        return
    }

    if (-not (Test-TradingWindow $cfg)) {
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state
        return
    }

    # Market bias gate — no new longs when SPY is in a confirmed downtrend
    if ($marketBias -eq "BEAR") {
        Write-Host "  SPY in BEAR trend (close < 9EMA < 20EMA) -- no new entries." -ForegroundColor Red
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state
        return
    }

    # Scan watchlist (dynamic — refreshed each morning by screener)
    Write-Host ("  Scanning {0} symbols: {1}" -f $watchlist.Count, ($watchlist -join ", "))
    Write-Host ""

    $pending  = @(Load-Pending)
    $newTrades = @()

    foreach ($symbol in $watchlist) {
        # Skip if already have position or pending trade
        $hasPos     = ($positions | Where-Object { $_.symbol -eq $symbol }).Count -gt 0
        $hasPending = ($pending   | Where-Object { $_.symbol -eq $symbol }).Count -gt 0
        if ($hasPos -or $hasPending) {
            Write-Host ("  {0,-6} SKIP  (position or pending order exists)" -f $symbol) -ForegroundColor DarkGray
            continue
        }

        # Fetch bar data
        $bars1m = Get-IntradayBars $cfg $symbol "1Min"
        $bars5m = Get-IntradayBars $cfg $symbol "5Min"

        if ($bars1m.Count -lt 20 -or $bars5m.Count -lt 10) {
            Write-Host ("  {0,-6} SKIP  (insufficient bar data)" -f $symbol) -ForegroundColor DarkGray
            continue
        }

        # Generate best signal
        $signal = Get-BestSignal $cfg $symbol $bars1m $bars5m

        if ($null -eq $signal) {
            $last = ($bars1m | Select-Object -Last 1).Close
            Write-Host ("  {0,-6} WATCH  `${1:F2}  -- no valid setup" -f $symbol, $last) -ForegroundColor DarkGray
            continue
        }

        # Validate risk — raise confidence bar in choppy/neutral market
        if ($marketBias -eq "NEUTRAL" -and $signal.Confidence -lt 80) {
            Write-Host ("  {0,-6} SKIP  (NEUTRAL market — need conf>=80, got {1}%)" -f `
                $symbol, $signal.Confidence) -ForegroundColor DarkGray
            continue
        }

        $validation = Validate-Trade $cfg $signal
        Write-TradeCard $signal $validation

        if (-not $validation.Valid) { continue }

        # Build pending trade record
        $tradeId = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
        $trade   = [pscustomobject]@{
            id         = $tradeId
            symbol     = $symbol
            strategy   = $signal.Strategy
            side       = $signal.Side
            shares     = $validation.Sizing.Shares
            entry      = $signal.Entry
            stop       = $signal.Stop
            t1         = $signal.T1
            t2         = $signal.T2
            rr         = $signal.RR
            confidence = $signal.Confidence
            risk_usd   = $validation.Sizing.ActualRisk
            risk_pct   = $validation.Sizing.ActualRiskPct
            proposed_at = (Get-Date).ToString("o")
        }

        # Auto-execute if paper mode and approval not required
        if ($cfg.paper_trading -and -not $cfg.require_approval) {
            Write-Host ("  AUTO-EXECUTE (paper): {0}" -f $tradeId) -ForegroundColor Cyan
            Submit-BracketOrder $cfg $symbol $signal.Side $validation.Sizing.Shares `
                $signal.Entry $signal.T1 $signal.Stop $signal.Strategy | Out-Null
            $state.trades_today++
        } else {
            $newTrades += $trade
            Write-Host ("  QUEUED for approval: ID={0}" -f $tradeId) -ForegroundColor Yellow
            Write-Host ("  Run: .\alpaca_bot.ps1 -Approve  to execute") -ForegroundColor Yellow
        }
    }

    # Merge new trades into pending queue
    if ($newTrades.Count -gt 0) {
        $allPending = @($pending) + @($newTrades)
        Save-Pending $allPending
    }

    $state.last_scan = (Get-Date).ToString("o")
    Save-State $state

    Write-Host ""
    Write-Host ("  Scan complete. Next check in {0}s." -f $cfg.scan_interval_sec)
    Write-Host ("=" * 70)
}

# ── Entry Point ───────────────────────────────────────────────────────────────

$cfg   = Load-AlpacaConfig
$state = Load-State

if ($Cancel) {
    Invoke-CancelAll $cfg
    exit 0
}

if ($Approve -or $ApproveId -ne "") {
    Invoke-ApprovePending $cfg
    exit 0
}

if ($Once) {
    Run-Scan $cfg $state
} else {
    while ($true) {
        try {
            Run-Scan $cfg $state
            $state = Load-State   # reload in case approval modified it
        } catch {
            Write-Host ("  [CYCLE ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Start-Sleep -Seconds ([int]$cfg.scan_interval_sec)
    }
}
