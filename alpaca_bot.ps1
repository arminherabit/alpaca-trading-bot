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
. (Join-Path $PSScriptRoot "alpaca_regime.ps1")
. (Join-Path $PSScriptRoot "alpaca_news.ps1")
. (Join-Path $PSScriptRoot "alpaca_earnings.ps1")

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
        equity_at_open   = 0.0   # snapshot at first scan of the day -- drives DD limit
        equity_at_open_date = "" # ET date for the snapshot above
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
# BULL  = close > 9 EMA > 20 EMA        -> allow longs
# BEAR  = close < 9 EMA < 20 EMA        -> block all new entries
# NEUTRAL = mixed (e.g. recent reversal) -> allow longs but with tighter confidence

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

# ── Position Management (break-even stop at +1R) ──────────────────────────────
# A seasoned trader doesn't just set a stop and walk away. The moment the
# trade has earned 1R of profit, the stop moves to entry + small buffer so
# the worst-case outcome becomes scratch instead of a loss. This is "free
# risk reduction": same upside, zero downside on managed trades.
#
# How it works with Alpaca bracket orders:
#   1. Each open position has a parent buy order with two child sell legs:
#      take-profit (limit) and stop-loss (stop). We need the stop leg.
#   2. We look up open orders with nested=true so legs are embedded.
#   3. For each position:
#        - find the parent buy with matching symbol that has bracket legs
#        - find the child stop leg (sell+stop for longs, buy+stop for shorts)
#        - compute risk-per-share = |entry - current_stop|
#        - if unrealized_pl >= risk * qty (i.e. +1R), PATCH stop to breakeven
#        - idempotent: skip if stop already at/past breakeven
#
# Scale-out (sell 50% at +1R) is intentionally NOT implemented here. Partial
# closes on bracket orders require rebalancing the leg qty, which can race
# with TP/SL fills. Revisit once we have 30+ trade samples to confirm the
# break-even rule alone is correctly tightened.

function Get-StopLegForPosition($cfg, $position) {
    $sym = $position.symbol
    # Two cases must be handled:
    #  1. Parent bracket still open: stop leg lives in parent.legs[] (nested=true).
    #  2. Parent already filled: child legs become STANDALONE open orders and
    #     no longer have a parent reference. We must accept top-level orders
    #     that ARE stops matching the position's exit direction.
    $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&nested=true&limit=100"
    if ($null -eq $orders) { return $null }
    $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }

    # Long position closes via sell+stop. Short position closes via buy+stop.
    $expectedSide = if ($position.side -eq "long") { "sell" } else { "buy" }

    # Accept any stop variant -- Alpaca returns 'stop', 'stop_limit',
    # 'trailing_stop' depending on order shape. The previous exact-match on
    # 'stop' missed stop_limit children of brackets.
    $stopTypes = @("stop","stop_limit","trailing_stop","stop_loss")

    foreach ($order in $arr) {
        if ($null -eq $order) { continue }
        if ($order.symbol -ne $sym) { continue }

        # Case 2: the order ITSELF is the stop (orphaned bracket child)
        $orderType = if ($order.order_type) { $order.order_type } else { $order.type }
        if (($stopTypes -contains $orderType) -and $order.side -eq $expectedSide) {
            return $order
        }

        # Case 1: parent bracket still active with embedded legs
        if ($order.legs -and $order.legs.Count -gt 0) {
            foreach ($leg in $order.legs) {
                if ($null -eq $leg) { continue }
                $legType = if ($leg.order_type) { $leg.order_type } else { $leg.type }
                if (($stopTypes -contains $legType) -and $leg.side -eq $expectedSide) {
                    return $leg
                }
            }
        }
    }
    return $null
}

# Submits a fresh standalone stop for a position that has lost its bracket
# protection. Two modes:
#   BREAKEVEN: entry +/- 0.1% buffer  (use for profitable positions)
#   MAXLOSS:   entry +/- 2.0%         (use for losing positions to cap bleeding)
function New-ProtectiveStop {
    param(
        $cfg,
        $position,
        [string]$Mode = "BREAKEVEN"   # BREAKEVEN | MAXLOSS
    )
    $sym  = $position.symbol
    $qty  = [int][Math]::Abs([double]$position.qty)
    $side = if ($position.side -eq "long") { "sell" } else { "buy" }
    $entry = [double]$position.avg_entry_price
    if ($entry -le 0 -or $qty -le 0) { return $null }

    $bufPct = if ($Mode -eq "MAXLOSS") { 0.02 } else { 0.001 }
    $buf = $entry * $bufPct

    # Long: stop BELOW entry (sell trigger).
    # Short: stop ABOVE entry (buy-to-cover trigger).
    $stopPx = if ($side -eq "sell") {
        # closing a long -- BE mode = entry+0.1%, MAXLOSS mode = entry-2%
        if ($Mode -eq "BREAKEVEN") { [Math]::Round($entry + $buf, 2) }
        else                       { [Math]::Round($entry - $buf, 2) }
    } else {
        # closing a short -- BE mode = entry-0.1%, MAXLOSS mode = entry+2%
        if ($Mode -eq "BREAKEVEN") { [Math]::Round($entry - $buf, 2) }
        else                       { [Math]::Round($entry + $buf, 2) }
    }

    $body = @{
        symbol          = $sym
        qty             = $qty.ToString()
        side            = $side
        type            = "stop"
        time_in_force   = "gtc"
        stop_price      = $stopPx.ToString("F2")
        client_order_id = "PROTECT_${Mode}_" + $sym + "_" + (Get-Date -Format "HHmmss")
    }
    Write-Host ("    [PROTECT-{0}] {1,-6} placing GTC stop @ `${2:F2} (entry=`${3:F2})" -f `
        $Mode, $sym, $stopPx, $entry) -ForegroundColor Yellow
    return Invoke-AlpacaApi $cfg "POST" "/v2/orders" $body
}

function Manage-OpenPositions($cfg, $positions) {
    if ($null -eq $positions -or $positions.Count -eq 0) { return }

    foreach ($pos in $positions) {
        $sym        = $pos.symbol
        $entry      = [double]$pos.avg_entry_price
        $qty        = [double]$pos.qty
        $side       = [string]$pos.side                    # "long" or "short"
        $unrealized = [double]$pos.unrealized_pl

        $stopLeg = Get-StopLegForPosition $cfg $pos
        if ($null -eq $stopLeg) {
            # No stop protection at all. ALWAYS plant a stop -- a naked position
            # is the highest-risk configuration regardless of P&L:
            #   - Profitable -> plant BE+buffer stop to lock in gains
            #   - Losing     -> plant max-loss stop to CAP the bleeding
            if ($unrealized -gt 0) {
                Write-Host ("    [MANAGE] {0,-6} no stop leg AND pnl=`${1:F2} > 0 -- planting BE protective stop" -f $sym, $unrealized) -ForegroundColor Yellow
                New-ProtectiveStop $cfg $pos -Mode "BREAKEVEN" | Out-Null
            } else {
                Write-Host ("    [MANAGE] {0,-6} no stop leg AND pnl=`${1:F2} < 0 -- planting MAX-LOSS stop (cap bleeding)" -f $sym, $unrealized) -ForegroundColor Red
                New-ProtectiveStop $cfg $pos -Mode "MAXLOSS" | Out-Null
            }
            continue
        }

        $currentStopRaw = if ($stopLeg.stop_price) { $stopLeg.stop_price } else { 0 }
        $currentStop    = [double]$currentStopRaw
        if ($currentStop -le 0) { continue }

        $riskPerShare = [Math]::Abs($entry - $currentStop)
        $absQty       = [Math]::Abs($qty)
        $totalRisk    = $riskPerShare * $absQty
        if ($totalRisk -le 0) { continue }

        # Idempotency: skip if stop already past breakeven (moved on a prior scan)
        $alreadyManaged = if ($side -eq "long") {
            $currentStop -ge $entry
        } else {
            $currentStop -le $entry
        }
        if ($alreadyManaged) {
            Write-Host ("    [MANAGE] {0,-6} stop already at/past BE (`${1:F2}) -- holding" -f `
                $sym, $currentStop) -ForegroundColor DarkGray
            continue
        }

        # Trigger: unrealized profit has reached at least 2R
        # (Raised from 1R to 2R -- at +1R, normal intraday retracements
        #  were tripping the BE stop and turning winners into scratches.
        #  At +2R the trade has proven itself and BE locks in meaningful profit.)
        $beThreshold = $totalRisk * 2.0
        if ($unrealized -lt $beThreshold) {
            $threshStr = "{0:F2}" -f $beThreshold
            Write-Host ("    [MANAGE] {0,-6} pnl=`${1:F2} below 2R=`${2} -- holding" -f `
                $sym, $unrealized, $threshStr) -ForegroundColor DarkGray
            continue
        }

        # Move stop to breakeven + 0.1% buffer (gives the bracket some slippage room)
        $buffer = $entry * 0.001
        $newStop = if ($side -eq "long") {
            [Math]::Round($entry + $buffer, 2)
        } else {
            [Math]::Round($entry - $buffer, 2)
        }

        Write-Host ("    [MANAGE] {0,-6} +2R hit (pnl=`${1:F2} >= 2R=`${2:F2}) -- moving stop `${3:F2} -> `${4:F2}" -f `
            $sym, $unrealized, $beThreshold, $currentStop, $newStop) -ForegroundColor Cyan
        $patchResult = Update-OrderStop $cfg $stopLeg.id $newStop
        if ($null -ne $patchResult) {
            Write-Host ("    [MANAGE] {0,-6} stop moved to BE successfully" -f $sym) -ForegroundColor Green
        } else {
            Write-Host ("    [MANAGE] {0,-6} stop move FAILED -- will retry next scan" -f $sym) -ForegroundColor Red
        }

        # SCALE-OUT (deferred): sell 50% qty here, then rebalance bracket legs.
        # Risk: partial close races with TP/SL fills if not done atomically.
        # Skipping until we have larger trade sample to validate the BE-only rule.
    }
}

# ── EOD Time-Stop: close day-trade positions before the bell ──────────────────
# A day trade that hasn't hit TP by 3:45 PM ET is unlikely to reach target
# before close. Holding overnight with intraday-calibrated stops exposes
# the position to gap risk the sizing didn't account for.
#
# At 3:45 PM ET, close any position that was OPENED TODAY via market order.
# Positions opened on prior days (e.g. MRVL multi-day short) are left alone
# -- those have protective stops already and were intentionally held.

function Close-EODPositions($cfg, $positions, $state) {
    $etNow   = Get-EasternTime
    $etToday = $etNow.ToString("yyyy-MM-dd")

    # Only fire at 3:45 PM ET or later
    $eodCutoff = $etNow.Date.AddHours(15).AddMinutes(45)
    if ($etNow -lt $eodCutoff) { return }

    # Already past close (4 PM)? Don't try to submit market orders.
    $marketClose = $etNow.Date.AddHours(16)
    if ($etNow -ge $marketClose) { return }

    foreach ($pos in $positions) {
        $sym = $pos.symbol
        $qty = [int][Math]::Abs([double]$pos.qty)
        if ($qty -le 0) { continue }

        # Only close positions opened TODAY. Check if we have a same-day
        # entry by looking at the created_at timestamp on matching filled orders.
        # Quick heuristic: if equity_at_open_date == today AND position exists,
        # it's likely a same-day entry. For multi-day holds the position
        # predates today's equity capture.
        #
        # More robust: check the order's created_at via API. But to keep it
        # simple and safe, skip positions that were already open at session start
        # by checking if we had a recorded trade for this symbol today.
        # If trades_today == 0, no entries were made today, so all positions
        # are multi-day holds.
        if ($state.trades_today -le 0) { continue }

        # Check if this symbol has an open order (bracket TP/SL still active).
        # If the bracket was placed today, it's a day trade candidate for EOD exit.
        $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&symbols=$sym&limit=10"
        $hasTodayOrder = $false
        if ($null -ne $orders) {
            $orderArr = if ($orders -is [System.Array]) { $orders } else { @($orders) }
            foreach ($ord in $orderArr) {
                if ($null -eq $ord) { continue }
                try {
                    $ordDate = [datetime]::Parse($ord.created_at).ToUniversalTime()
                    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
                    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
                    $ordET = [System.TimeZoneInfo]::ConvertTimeFromUtc($ordDate, $tz).ToString("yyyy-MM-dd")
                    if ($ordET -eq $etToday) { $hasTodayOrder = $true; break }
                } catch {}
            }
        }

        if (-not $hasTodayOrder) {
            Write-Host ("    [EOD] {0,-6} multi-day hold -- keeping overnight" -f $sym) -ForegroundColor DarkGray
            continue
        }

        $pnl = [double]$pos.unrealized_pl
        $pnlStr = "{0:F2}" -f $pnl
        Write-Host ("    [EOD] {0,-6} closing day trade at 3:45 PM ET (unrealized `${1})" -f $sym, $pnlStr) -ForegroundColor Yellow

        # Cancel any open orders for this symbol first (bracket legs)
        foreach ($ord in $orderArr) {
            if ($null -ne $ord -and $ord.status -eq "new" -or $ord.status -eq "accepted" -or $ord.status -eq "partially_filled") {
                try { Invoke-AlpacaApi $cfg "DELETE" "/v2/orders/$($ord.id)" | Out-Null } catch {}
            }
        }
        Start-Sleep -Milliseconds 500

        # Submit market close
        $closeSide = if ($pos.side -eq "long") { "sell" } else { "buy" }
        $closeBody = @{
            symbol        = $sym
            qty           = $qty.ToString()
            side          = $closeSide
            type          = "market"
            time_in_force = "day"
            client_order_id = "EOD_CLOSE_${sym}_" + (Get-Date -Format "HHmmss")
        }
        $result = Invoke-AlpacaApi $cfg "POST" "/v2/orders" $closeBody
        if ($null -ne $result) {
            Write-Host ("    [EOD] {0,-6} market close submitted" -f $sym) -ForegroundColor Green
        } else {
            Write-Host ("    [EOD] {0,-6} close FAILED -- will retry next scan" -f $sym) -ForegroundColor Red
        }
    }
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

    # ── Self-learning: sync closed trades -> update ticker memory ───────────
    # Run this BEFORE the market-open gate so any exits that filled near or at
    # close get recorded into memory overnight rather than waiting until the
    # next session. The 7-day lookback in Sync-ClosedTrades is safe to call
    # repeatedly thanks to the recorded_exits dedup set.
    $state = Sync-ClosedTrades $cfg $state

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

    # ── Backward-compat: ensure new state fields exist on old state.json ───
    foreach ($f in @("equity_at_open","equity_at_open_date")) {
        if (-not (Get-Member -InputObject $state -Name $f -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
            $default = if ($f -eq "equity_at_open") { 0.0 } else { "" }
            $state | Add-Member -NotePropertyName $f -NotePropertyValue $default -Force
        }
    }

    # ── Capture start-of-day equity ────────────────────────────────────────
    # Done once per ET day so the drawdown limit has a stable reference point.
    $equityNow = Get-Equity $cfg
    if ($state.equity_at_open_date -ne $etToday -or $state.equity_at_open -le 0) {
        $state.equity_at_open      = $equityNow
        $state.equity_at_open_date = $etToday
        Save-State $state
        Write-Host ("  [DAY-OPEN] Equity baseline captured: `${0:N2}" -f $equityNow) -ForegroundColor Cyan
    }

    # ── Market regime ──────────────────────────────────────────────────────
    # Replaces the prior simple BULL/BEAR/NEUTRAL bias with a richer 5-class
    # regime + size multiplier + strategy preference hint.
    $regime     = Get-MarketRegime $cfg
    $marketBias = switch ($regime.Regime) {
        "BULL_TREND" { "BULL" } "BEAR_TREND" { "BEAR" } default { "NEUTRAL" }
    }
    $biasColor = switch ($regime.Regime) {
        "BULL_TREND" { "Green"  } "BEAR_TREND" { "Red"    }
        "VOLATILE"   { "Magenta"} "RANGING"    { "Yellow" } default { "DarkYellow" }
    }
    $vixDisplay = if ($null -eq $regime.VIX) { "n/a" } else { "{0:F1}" -f $regime.VIX }
    $hvFlag     = if ($regime.HighVol) { " [HIGH-VOL]" } else { "" }
    Write-Host ("  Regime: {0,-11} | Vol: {1}% | 60m: {2}% | VIX: {3}{4} | SizeMult: {5}x" -f `
        $regime.Regime, $regime.Volatility, $regime.TrendStrength, $vixDisplay, $hvFlag, $regime.SizeMult) -ForegroundColor $biasColor
    Write-Host ("    -> {0}" -f $regime.Reason) -ForegroundColor DarkGray

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

    # Screener runs once per day but NOT before 10:00 AM ET --
    # snapshot data at 9:31 AM is too thin to score RVOL and range properly.
    # Self-heal: if a same-day screener run already happened but produced an
    # anaemic list (<=2 tickers = only the core anchors), allow one re-run
    # because that means scoring failed and a code/data fix may have landed.
    $screenerReady   = ($etNow -ge $etNow.Date.AddHours(10))
    $listUnderbuilt  = ($state.active_watchlist -isnot [array] -or $state.active_watchlist.Count -le 2)
    $needScreen      = ($state.watchlist_date -ne $etToday) -or $listUnderbuilt
    if ($needScreen -and $screenerReady) {
        # Refresh earnings calendar first so the screener can hard-reject blackout
        # names and score the run-up window. Internal 24h TTL avoids spam.
        if ($cfg.earnings_enabled) { Refresh-EarningsCalendar $cfg | Out-Null }

        $maxW = if ($cfg.max_watchlist) { [int]$cfg.max_watchlist } else { 12 }
        $dynamicList = Get-DynamicWatchlist $cfg $maxW
        $state.active_watchlist = $dynamicList
        $state.watchlist_date   = $etToday
        Write-ScreenerReport (Get-LastScreenerCandidates) $dynamicList
        Save-State $state
    } elseif ($needScreen -and -not $screenerReady) {
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

        # Active position management: break-even stop at +2R
        Manage-OpenPositions $cfg $positions

        # EOD time-stop: close same-day positions at 3:45 PM ET
        Close-EODPositions $cfg $positions $state
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

    # Market bias note -- no longer a hard skip. Each strategy's HTF gate
    # filters direction per symbol:
    #   - BEAR_TREND SPY: long strategies hard-reject (BEARISH HTF),
    #     short strategies fire when individual symbol's 15m is also bearish
    #   - BULL_TREND SPY: opposite, longs eligible, shorts hard-rejected
    if ($marketBias -eq "BEAR") {
        Write-Host "  SPY in BEAR trend -- longs blocked by HTF gate, shorts eligible." -ForegroundColor Magenta
    }

    # ── Daily discipline gates ────────────────────────────────────────────
    # A seasoned trader walks away after a fixed loss or trade count.
    # These are non-negotiable -- the bot stops opening positions for the day.
    $maxTrades = if ($cfg.max_trades_per_day) { [int]$cfg.max_trades_per_day } else { 5 }
    $maxLosses = if ($cfg.max_losses_per_day) { [int]$cfg.max_losses_per_day } else { 2 }
    $maxDDPct  = if ($cfg.max_daily_drawdown_pct) { [double]$cfg.max_daily_drawdown_pct } else { -3.0 }

    if ($state.trades_today -ge $maxTrades) {
        Write-Host ("  [LIMIT] Trade cap hit ({0}/{1}) -- monitoring exits only." -f `
            $state.trades_today, $maxTrades) -ForegroundColor Yellow
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state; return
    }
    if ($state.losses -ge $maxLosses) {
        Write-Host ("  [LIMIT] Loss cap hit ({0}/{1}) -- shutting down for the day." -f `
            $state.losses, $maxLosses) -ForegroundColor Red
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state; return
    }
    if ($state.equity_at_open -gt 0) {
        $ddPct = (($equityNow - $state.equity_at_open) / $state.equity_at_open) * 100
        if ($ddPct -le $maxDDPct) {
            Write-Host ("  [LIMIT] Daily drawdown {0:F2}% <= {1}% -- shutting down." -f `
                $ddPct, $maxDDPct) -ForegroundColor Red
            $state.last_scan = (Get-Date).ToString("o"); Save-State $state; return
        }
    }

    # Scan watchlist (dynamic -- refreshed each morning by screener)
    Write-Host ("  Scanning {0} symbols: {1}" -f $watchlist.Count, ($watchlist -join ", "))
    Write-Host ""

    $pending  = @(Load-Pending)
    $newTrades = @()
    $sameScanEntries = @()   # track entries made THIS scan to prevent correlated duplicates
    $enteredThisScan = $false  # max 1 new entry per scan cycle

    foreach ($symbol in $watchlist) {
        # ── Max 1 entry per scan ──────────────────────────────────────────
        # A seasoned trader enters one position, watches it breathe, then
        # evaluates the next. Prevents 3-trade bursts that blow position limit.
        if ($enteredThisScan) {
            break
        }

        # Skip if already have position or pending trade
        $hasPos     = ($positions | Where-Object { $_.symbol -eq $symbol }).Count -gt 0
        $hasPending = ($pending   | Where-Object { $_.symbol -eq $symbol }).Count -gt 0
        if ($hasPos -or $hasPending) {
            Write-Host ("  {0,-6} SKIP  (position or pending order exists)" -f $symbol) -ForegroundColor DarkGray
            continue
        }

        # ── Correlated ticker conflict check ──────────────────────────────
        # Never hold QQQ + TQQQ, or SPY + SPXL, etc. Same underlying = same bet.
        $conflictReason = Test-CorrelationConflict $symbol $positions $sameScanEntries
        if ($null -ne $conflictReason) {
            Write-Host ("  {0,-6} SKIP  ({1})" -f $symbol, $conflictReason) -ForegroundColor Yellow
            continue
        }

        # ── Leveraged ETF block (belt-and-suspenders with screener) ───────
        if ($LEVERAGED_BLOCKLIST -contains $symbol) {
            Write-Host ("  {0,-6} SKIP  (leveraged ETF blocked)" -f $symbol) -ForegroundColor Yellow
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

        # Validate risk -- raise confidence bar in all regimes
        # 75% minimum across the board; 85% in NEUTRAL (choppy = harder to trade)
        $confFloor = if ($marketBias -eq "NEUTRAL") { 85 } else { 75 }
        if ($signal.Confidence -lt $confFloor) {
            Write-Host ("  {0,-6} SKIP  ({1} market -- need conf>={2}, got {3}%)" -f `
                $symbol, $marketBias, $confFloor, $signal.Confidence) -ForegroundColor DarkGray
            continue
        }

        $validation = Validate-Trade $cfg $signal $regime
        Write-TradeCard $signal $validation

        # Surface the adaptive-sizing reasoning so it's auditable in the logs
        if ($validation.EdgeInfo) {
            Write-Host ("  [EDGE] {0}  trades={1}  WR={2:P0}  sizeMult={3}x  ({4})" -f `
                $signal.Strategy, $validation.EdgeInfo.Trades, $validation.EdgeInfo.WinRate,
                $validation.EdgeInfo.Mult, $validation.EdgeInfo.Reason) -ForegroundColor DarkCyan
        }

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
            $sameScanEntries += $symbol
            $enteredThisScan = $true   # one entry per scan -- wait for next cycle
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
