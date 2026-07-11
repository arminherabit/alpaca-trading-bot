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
. (Join-Path $PSScriptRoot "alpaca_swing_signals.ps1")
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
    # Long position closes via sell+stop. Short position closes via buy+stop.
    $expectedSide = if ($position.side -eq "long") { "sell" } else { "buy" }
    $stopTypes    = @("stop","stop_limit","trailing_stop","stop_loss")
    # An order/leg counts as live protection only if it hasn't terminated.
    $deadStatus   = @("filled","canceled","cancelled","expired","rejected","done_for_day","replaced")

    # Query status=ALL with nesting. A bracket's stop child is exposed ONLY as
    # a leg of its parent; once the entry FILLS the parent has status=filled,
    # so status=open never returns it (this was the duplicate-stop bug). We
    # therefore pull all orders, then accept either:
    #   (a) a standalone stop order (e.g. a manually-planted PROTECT_* stop), or
    #   (b) a live stop LEG under any parent (the bracket SL).
    $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=all&nested=true&symbols=$sym&limit=200"
    if ($null -eq $orders) { return $null }
    $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }

    foreach ($order in $arr) {
        if ($null -eq $order) { continue }
        if ($order.symbol -ne $sym) { continue }

        # (a) the order ITSELF is a live standalone stop
        $orderType = if ($order.order_type) { $order.order_type } else { $order.type }
        if (($stopTypes -contains $orderType) -and $order.side -eq $expectedSide -and
            ($deadStatus -notcontains $order.status)) {
            return $order
        }

        # (b) a live stop LEG under this parent (the bracket SL after fill)
        if ($order.legs -and $order.legs.Count -gt 0) {
            foreach ($leg in $order.legs) {
                if ($null -eq $leg) { continue }
                $legType = if ($leg.order_type) { $leg.order_type } else { $leg.type }
                if (($stopTypes -contains $legType) -and $leg.side -eq $expectedSide -and
                    ($deadStatus -notcontains $leg.status)) {
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

    # Idempotency guard: never stack stops. Uses the same nested-aware lookup
    # as management, so it sees bracket stop legs (not just standalone stops)
    # and won't plant a duplicate the broker would only reject anyway.
    $existingStop = Get-StopLegForPosition $cfg $position
    if ($null -ne $existingStop) {
        Write-Host ("    [PROTECT] {0,-6} stop already exists -- not planting duplicate" -f $sym) -ForegroundColor DarkGray
        return $null
    }

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

    # If the protective level is ALREADY breached, a stop on that side is
    # invalid (sell-stop must sit below market, buy-stop above) and Alpaca
    # rejects it -- leaving the position naked and the bot retrying the same
    # rejected order every scan (QCOM: down 4.3%, max-loss stop at entry-2%
    # was above market, looping forever). When that happens, the protective
    # action is to CLOSE NOW at market, not to place an unplaceable stop.
    $mktPx = [double]$position.current_price
    $breached = $false
    if ($mktPx -gt 0) {
        $breached = if ($side -eq "sell") { $stopPx -ge $mktPx } else { $stopPx -le $mktPx }
    }
    if ($breached) {
        Write-Host ("    [PROTECT-{0}] {1,-6} stop `${2:F2} already breached (mkt `${3:F2}) -- market-closing now" -f `
            $Mode, $sym, $stopPx, $mktPx) -ForegroundColor Red
        return Submit-MarketOrder $cfg $sym $side $qty
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

# One-shot repair for the duplicate-stop bug: a detection miss on freshly
# filled GTC brackets caused a new protective stop to be planted every scan.
# Collapse each position's exit-side stop orders down to the single MOST
# protective one (highest sell-stop for longs, lowest buy-stop for shorts);
# cancel the rest. Take-profit limit legs are left untouched.
function Repair-DuplicateStops($cfg, $positions) {
    if ($null -eq $positions -or $positions.Count -eq 0) { return }
    $stopTypes = @("stop","stop_limit","trailing_stop","stop_loss")

    foreach ($pos in $positions) {
        $sym      = $pos.symbol
        $exitSide = if ($pos.side -eq "long") { "sell" } else { "buy" }
        $orders   = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&symbols=$sym&limit=100"
        if ($null -eq $orders) { continue }
        $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }

        $stops = @($arr | Where-Object {
            $null -ne $_ -and $_.side -eq $exitSide -and
            ($stopTypes -contains $(if ($_.order_type) { $_.order_type } else { $_.type }))
        })
        if ($stops.Count -le 1) { continue }

        $keep = if ($pos.side -eq "long") {
            $stops | Sort-Object { [double]$_.stop_price } -Descending | Select-Object -First 1
        } else {
            $stops | Sort-Object { [double]$_.stop_price } | Select-Object -First 1
        }
        $canceled = 0
        foreach ($s in $stops) {
            if ($s.id -ne $keep.id) {
                try { Invoke-AlpacaApi $cfg "DELETE" "/v2/orders/$($s.id)" | Out-Null; $canceled++ } catch {}
            }
        }
        Write-Host ("    [REPAIR] {0,-6} had {1} stops -- kept `${2}, canceled {3}" -f `
            $sym, $stops.Count, $keep.stop_price, $canceled) -ForegroundColor Magenta
    }
}

# Convert a position's bracket protection into a native trailing stop so a
# winner can run past the fixed 3.5R target. Cancels the symbol's open bracket
# legs (the stop AND the take-profit cap), then submits a GTC trailing_stop;
# Alpaca ratchets the stop behind the high-water mark server-side. trailPct
# self-calibrates to the trade's volatility (its original stop distance).
# On a placement failure the position is briefly unprotected -- the next
# scan's Get-StopLegForPosition->New-ProtectiveStop fallback re-covers it.
function Convert-ToTrailingStop($cfg, $position, [double]$trailPct) {
    $sym  = $position.symbol
    $qty  = [int][Math]::Abs([double]$position.qty)
    $side = if ($position.side -eq "long") { "sell" } else { "buy" }
    if ($qty -le 0) { return $null }

    $open = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&symbols=$sym&limit=50"
    if ($null -ne $open) {
        $arr = if ($open -is [System.Array]) { $open } else { @($open) }
        foreach ($o in $arr) { if ($null -ne $o) { try { Invoke-AlpacaApi $cfg "DELETE" "/v2/orders/$($o.id)" | Out-Null } catch {} } }
        Start-Sleep -Milliseconds 500
    }
    $body = @{
        symbol          = $sym
        qty             = $qty.ToString()
        side            = $side
        type            = "trailing_stop"
        time_in_force   = "gtc"
        trail_percent   = $trailPct.ToString("F2")
        client_order_id = "TRAIL_" + $sym + "_" + (Get-Date -Format "HHmmss")
    }
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

        # Already trailing? Alpaca ratchets the stop server-side as the
        # high-water mark rises -- nothing for us to do, just let it run.
        $stopType = if ($stopLeg.order_type) { $stopLeg.order_type } else { $stopLeg.type }
        if ($stopType -eq "trailing_stop") {
            $tStop = if ($stopLeg.stop_price) { [double]$stopLeg.stop_price } else { 0 }
            Write-Host ("    [MANAGE] {0,-6} trailing stop active (stop ~`${1:F2}) -- letting it run" -f $sym, $tStop) -ForegroundColor Cyan
            continue
        }

        $currentStopRaw = if ($stopLeg.stop_price) { $stopLeg.stop_price } else { 0 }
        $currentStop    = [double]$currentStopRaw
        if ($currentStop -le 0) { continue }

        $riskPerShare = [Math]::Abs($entry - $currentStop)
        $absQty       = [Math]::Abs($qty)
        $totalRisk    = $riskPerShare * $absQty
        if ($totalRisk -le 0) { continue }

        # ── Two-stage exit, measured in R off the ORIGINAL stop ──────────────
        # The original 1R is recomputed from daily ATR (the same basis the
        # entry used) so the R-multiple stays correct even after we've moved
        # the stop to break-even -- once moved, |entry-currentStop| no longer
        # reflects the real risk taken. Analysis of the first 6 swing trades:
        # avg loss (~$465) dwarfed avg win (~$45) because losers ran to a full
        # -1R while nothing locked winners until +2R (a 6-10% move rarely
        # reached). Stages fix both:
        #   +1R  -> move stop to break-even  (a would-be loser becomes a scratch)
        #   +2R  -> trailing stop, drop the 3.5R cap  (let the winner run)
        $atBE = if ($side -eq "long") { $currentStop -ge $entry } else { $currentStop -le $entry }

        $dBars = Get-DailyBars $cfg $sym
        $dATR  = if ($dBars -and $dBars.Count -ge 15) { Get-ATR $dBars 14 } else { 0 }
        $origRiskPS = if ($dATR -gt 0) { 2.0 * $dATR } elseif (-not $atBE) { $riskPerShare } else { 0 }
        if ($origRiskPS -le 0) {
            # Can't establish a reliable R reference (no ATR and stop already
            # moved) -- leave the existing protection in place.
            Write-Host ("    [MANAGE] {0,-6} holding (stop `${1:F2}, R-ref unavailable)" -f $sym, $currentStop) -ForegroundColor DarkGray
            continue
        }
        $rMult = ($unrealized / $absQty) / $origRiskPS

        if ($rMult -ge 2.0) {
            # +2R -- convert to a trailing stop and remove the fixed TP cap.
            $trailPct = [Math]::Round(($origRiskPS / $entry) * 100, 2)
            $trailPct = [Math]::Max(2.0, [Math]::Min(5.0, $trailPct))
            Write-Host ("    [MANAGE] {0,-6} +{1:F1}R (pnl=`${2:F2}) -- converting to trailing stop ({3:F2}% trail), removing cap" -f `
                $sym, $rMult, $unrealized, $trailPct) -ForegroundColor Cyan
            $tr = Convert-ToTrailingStop $cfg $pos $trailPct
            if ($null -ne $tr) {
                Write-Host ("    [MANAGE] {0,-6} trailing stop placed -- winner can now run" -f $sym) -ForegroundColor Green
            } else {
                Write-Host ("    [MANAGE] {0,-6} trailing conversion FAILED -- protective fallback covers next scan" -f $sym) -ForegroundColor Red
            }
        }
        elseif ($rMult -ge 1.5) {
            # +1.5R -- RATCHET: lock the stop at entry +0.75R. Observed pattern
            # (ABBV, VOYA): winners stall in the +1R..+1.5R zone and fade back
            # to the BE stop for a scratch. This stage banks ~half the open
            # gain while still leaving room to reach the +2R trailing stage.
            $lockStop = if ($side -eq "long") {
                [Math]::Round($entry + 0.75 * $origRiskPS, 2)
            } else {
                [Math]::Round($entry - 0.75 * $origRiskPS, 2)
            }
            $alreadyLocked = if ($side -eq "long") { $currentStop -ge $lockStop } else { $currentStop -le $lockStop }
            if ($alreadyLocked) {
                Write-Host ("    [MANAGE] {0,-6} +{1:F1}R -- +0.75R lock already in place (`${2:F2})" -f $sym, $rMult, $currentStop) -ForegroundColor DarkGray
            } else {
                Write-Host ("    [MANAGE] {0,-6} +{1:F1}R (pnl=`${2:F2}) -- ratcheting stop to +0.75R (`${3:F2})" -f `
                    $sym, $rMult, $unrealized, $lockStop) -ForegroundColor Cyan
                $patch = Update-OrderStop $cfg $stopLeg.id $lockStop
                if ($null -eq $patch) {
                    Write-Host ("    [MANAGE] {0,-6} ratchet FAILED -- will retry next scan" -f $sym) -ForegroundColor Red
                }
            }
        }
        elseif ($rMult -ge 1.0 -and -not $atBE) {
            # +1R -- move stop to break-even + 0.1% buffer. A pullback from here
            # now scratches instead of taking a full -1R loss.
            $buffer  = $entry * 0.001
            $newStop = if ($side -eq "long") { [Math]::Round($entry + $buffer, 2) } else { [Math]::Round($entry - $buffer, 2) }
            Write-Host ("    [MANAGE] {0,-6} +{1:F1}R (pnl=`${2:F2}) -- moving stop to BE `${3:F2}" -f `
                $sym, $rMult, $unrealized, $newStop) -ForegroundColor Cyan
            $patch = Update-OrderStop $cfg $stopLeg.id $newStop
            if ($null -eq $patch) {
                Write-Host ("    [MANAGE] {0,-6} BE move FAILED -- will retry next scan" -f $sym) -ForegroundColor Red
            }
        }
        else {
            $tag = if ($atBE) { "at BE, <+1.5R" } else { ("+{0:F1}R, <+1R" -f $rMult) }
            Write-Host ("    [MANAGE] {0,-6} holding ({1}, pnl=`${2:F2})" -f $sym, $tag, $unrealized) -ForegroundColor DarkGray
        }
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

# ── Swing-mode helpers ───────────────────────────────────────────────────────

# Swing entries allowed 9:50 AM - 3:30 PM ET. No midday pause -- daily-bar
# signals don't care about lunch chop. The 9:50 floor lets the opening
# auction settle; the 3:30 ceiling avoids entering minutes before close
# (fills near the bell get the next day's gap with no chance to manage).
function Test-SwingEntryWindow {
    $etNow = Get-EasternTime
    $start = $etNow.Date.AddHours(9).AddMinutes(50)
    $end   = $etNow.Date.AddHours(15).AddMinutes(30)
    return ($etNow -ge $start -and $etNow -le $end)
}

# Count weekdays between two dates (rough trading-day age; ignores holidays,
# which only makes the time stop fire a day early on holiday weeks -- fine).
function Get-WeekdayCount([datetime]$from, [datetime]$to) {
    $count = 0
    $d = $from.Date.AddDays(1)
    while ($d -le $to.Date) {
        if ($d.DayOfWeek -ne "Saturday" -and $d.DayOfWeek -ne "Sunday") { $count++ }
        $d = $d.AddDays(1)
    }
    return $count
}

# Time stop: a swing trade that hasn't resolved in hold_days_max trading days
# is dead capital -- the catalyst didn't play out. Close it, free the slot.
function Close-StalePositions($cfg, $positions) {
    $maxHold = if ($cfg.hold_days_max) { [int]$cfg.hold_days_max } else { 12 }
    $etNow   = Get-EasternTime

    foreach ($pos in $positions) {
        $sym = $pos.symbol
        $entrySide = if ($pos.side -eq "long") { "buy" } else { "sell" }

        # Find the entry fill date from closed orders (positions API has no date)
        $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=closed&symbols=$sym&limit=100"
        if ($null -eq $orders) { continue }
        $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }
        $entryFill = $arr | Where-Object { $_.side -eq $entrySide -and $_.status -eq "filled" -and $_.filled_at } |
                     Sort-Object { [datetime]::Parse($_.filled_at) } -Descending | Select-Object -First 1
        if ($null -eq $entryFill) { continue }

        # UTC-date weekday count -- a few hours of tz skew can't matter at
        # a 12-day threshold
        $ageDays = Get-WeekdayCount ([datetime]::Parse($entryFill.filled_at).ToUniversalTime()) ([datetime]::UtcNow)

        if ($ageDays -lt $maxHold) {
            Write-Host ("    [HOLD] {0,-6} day {1}/{2} of max hold" -f $sym, $ageDays, $maxHold) -ForegroundColor DarkGray
            continue
        }

        $pnl = [double]$pos.unrealized_pl
        Write-Host ("    [TIME-STOP] {0,-6} held {1} trading days (max {2}) -- closing (unrealized `${3:F2})" -f `
            $sym, $ageDays, $maxHold, $pnl) -ForegroundColor Yellow

        # Cancel bracket legs first, then market-close
        $openOrders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&symbols=$sym&limit=20"
        if ($null -ne $openOrders) {
            $oArr = if ($openOrders -is [System.Array]) { $openOrders } else { @($openOrders) }
            foreach ($o in $oArr) {
                if ($null -ne $o) { try { Invoke-AlpacaApi $cfg "DELETE" "/v2/orders/$($o.id)" | Out-Null } catch {} }
            }
            Start-Sleep -Milliseconds 500
        }
        $qty = [int][Math]::Abs([double]$pos.qty)
        $closeSide = if ($pos.side -eq "long") { "sell" } else { "buy" }
        Submit-MarketOrder $cfg $sym $closeSide $qty | Out-Null
    }
}

# A GTC bracket whose ENTRY never filled is a stale bet: the signal was
# priced off a level that the market rejected. Cancel any unfilled parent
# bracket older than today so it can't fill days later in a different tape.
function Cancel-StaleEntries($cfg) {
    $etToday = (Get-EasternTime).ToString("yyyy-MM-dd")
    $orders  = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&nested=true&limit=100"
    if ($null -eq $orders) { return }
    $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }
    foreach ($o in $arr) {
        if ($null -eq $o) { continue }
        if ($o.order_class -ne "bracket") { continue }
        $filledQty = if ($o.filled_qty) { [double]$o.filled_qty } else { 0 }
        if ($filledQty -gt 0) { continue }   # entry filled -- legs are live protection
        try {
            $createdET = [System.TimeZoneInfo]::ConvertTimeFromUtc(
                [datetime]::Parse($o.created_at).ToUniversalTime(),
                $(try { [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
                  catch { [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") })
            ).ToString("yyyy-MM-dd")
            if ($createdET -lt $etToday) {
                Write-Host ("    [STALE] {0,-6} unfilled entry from {1} -- canceling" -f $o.symbol, $createdET) -ForegroundColor Yellow
                Invoke-AlpacaApi $cfg "DELETE" "/v2/orders/$($o.id)" | Out-Null
            }
        } catch {}
    }
}

# ── Trade ownership (SHARED Alpaca account) ───────────────────────────────────
# Another bot trades this account. We identify OUR positions by the strategy
# prefix on our entry orders' client_order_id ($MY_ENTRY_PREFIXES, defined in
# alpaca_screener.ps1). Returns a hashtable {symbol=$true} of symbols we entered
# via a filled, strategy-tagged order in the lookback window -- or $null if the
# orders API call fails (caller treats $null as "unknown, act on nothing").
function Get-MyOpenSymbols($cfg) {
    $lookback = (Get-Date).ToUniversalTime().AddDays(-20).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=all&after=$lookback&direction=desc&limit=500"
    if ($null -eq $orders) { return $null }
    $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }
    $owned = @{}
    foreach ($o in $arr) {
        if ($null -eq $o -or $o.status -ne "filled" -or -not $o.client_order_id) { continue }
        $tag = ($o.client_order_id -split "_")[0]
        if ($MY_ENTRY_PREFIXES -contains $tag) { $owned[$o.symbol] = $true }
    }
    return $owned
}

# Cancel any management orders (PROTECT_/TRAIL_/EOD_) THIS bot placed on a
# symbol it does not own -- e.g. a protective stop wrongly planted on the other
# bot's position before ownership filtering existed. Removes only OUR stray
# order; the foreign position itself is left untouched.
function Cancel-ForeignManagementOrders($cfg, $mySymbols) {
    $orders = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&limit=200"
    if ($null -eq $orders) { return }
    $arr = if ($orders -is [System.Array]) { $orders } else { @($orders) }
    foreach ($o in $arr) {
        if ($null -eq $o -or -not $o.client_order_id) { continue }
        $tag = ($o.client_order_id -split "_")[0]
        if ((@("PROTECT","TRAIL","EOD") -contains $tag) -and -not $mySymbols.ContainsKey($o.symbol)) {
            Write-Host ("    [OWNERSHIP] canceling stray {0} order on non-owned {1}" -f $tag, $o.symbol) -ForegroundColor Magenta
            try { Invoke-AlpacaApi $cfg "DELETE" "/v2/orders/$($o.id)" | Out-Null } catch {}
        }
    }
}

# ── Scan Cycle ────────────────────────────────────────────────────────────────

function Run-Scan($cfg, $state) {
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")

    $swingMode = ($cfg.scan_mode -eq "swing")

    Write-Host ""
    Write-Host ("=" * 70)
    $titleStr = if ($swingMode) { "ALPACA SWING TRADER" } else { "ALPACA DAY TRADER" }
    Write-Host ("  {0}  --  {1} UTC" -f $titleStr, $now)
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

    if ($swingMode) {
        if (-not (Test-SwingEntryWindow)) {
            Write-Host "  Outside swing entry window (09:50-15:30 ET) -- monitoring only." -ForegroundColor Yellow
        }
    } elseif (-not (Test-TradingWindow $cfg)) {
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
    # Swing mode reads the PRIMARY trend off SPY daily EMA20/50 -- the same
    # frame the swing strategies trade. Day mode keeps the 5-min classifier.
    $spyDaily = $null
    if ($swingMode) {
        $spyDaily   = Get-DailyBars $cfg "SPY"
        $regime     = Get-SwingRegime $cfg $spyDaily
        $marketBias = switch ($regime.Regime) {
            "BULL" { "BULL" } "BEAR" { "BEAR" } default { "NEUTRAL" }
        }
        $biasColor = switch ($regime.Regime) {
            "BULL" { "Green" } "BEAR" { "Red" } "RANGING" { "Yellow" } default { "DarkYellow" }
        }
        $vixDisplay = if ($null -eq $regime.VIX) { "n/a" } else { "{0:F1}" -f $regime.VIX }
        $hvFlag     = if ($regime.HighVol) { " [HIGH-VOL]" } else { "" }
        Write-Host ("  Swing Regime: {0,-8} | VIX: {1}{2} | SizeMult: {3}x" -f `
            $regime.Regime, $vixDisplay, $hvFlag, $regime.SizeMult) -ForegroundColor $biasColor
        Write-Host ("    -> {0}" -f $regime.Reason) -ForegroundColor DarkGray
    } else {
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
    }

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

    # ── SHARED ACCOUNT: scope to OUR positions only ───────────────────────────
    # Another bot trades here too. Determine which symbols are ours (by our
    # entry-order tags); never manage, count, or close anything else. If the
    # ownership lookup fails, act on NOTHING this scan (our positions stay
    # protected by their existing GTC stops).
    $mySymbols = Get-MyOpenSymbols $cfg
    if ($null -eq $mySymbols) {
        Write-Host "  [OWNERSHIP] could not resolve owned positions (orders API) -- skipping scan." -ForegroundColor Yellow
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state; return
    }
    Cancel-ForeignManagementOrders $cfg $mySymbols

    $allPositions = @(Get-Positions $cfg)
    $allPosSyms   = @{}; foreach ($p in $allPositions) { if ($p) { $allPosSyms[$p.symbol] = $true } }
    $positions    = @($allPositions | Where-Object { $mySymbols.ContainsKey($_.symbol) })
    $foreignCount = $allPositions.Count - $positions.Count
    $posCount     = $positions.Count

    $foreignNote = if ($foreignCount -gt 0) { "  (+{0} other-bot, ignored)" -f $foreignCount } else { "" }
    Write-Host ("  Equity: `${0:N2}  |  Buying Power: `${1:N2}  |  My Positions: {2}/{3}{4}" -f `
        $equity, $bp, $posCount, $cfg.max_positions, $foreignNote)
    Write-Host ("  P&L Today: `${0:F2}  |  Trades: {1}  |  W/L: {2}/{3}" -f `
        $state.pnl_today, $state.trades_today, $state.wins, $state.losses)
    Write-Host ""

    # Show + manage OUR open positions only
    if ($positions.Count -gt 0) {
        Write-Host "  Open Positions (mine):"
        foreach ($p in $positions) {
            $pnl    = [double]$p.unrealized_pl
            $pnlPct = [double]$p.unrealized_plpc * 100
            $color  = if ($pnl -ge 0) { "Green" } else { "Red" }
            Write-Host ("    {0,-6} {1,5} shares @ `${2}  PnL: `${3:F2} ({4:F2}%)" -f `
                $p.symbol, $p.qty, $p.avg_entry_price, $pnl, $pnlPct) -ForegroundColor $color
        }
        Write-Host ""

        # Clean up any stacked duplicate stops before managing
        Repair-DuplicateStops $cfg $positions

        # Active position management: trailing stop at +2R
        Manage-OpenPositions $cfg $positions

        if ($swingMode) {
            # Swing positions are MEANT to be held overnight -- no EOD close.
            # Instead: time-stop after hold_days_max trading days.
            Close-StalePositions $cfg $positions
        } else {
            # EOD time-stop: close same-day positions at 3:45 PM ET
            Close-EODPositions $cfg $positions $state
        }
        Write-Host ""
    }

    # Swing mode: kill unfilled GTC entry brackets from prior days
    if ($swingMode) { Cancel-StaleEntries $cfg }

    # Skip new entries if at max positions or outside window
    if ($posCount -ge [int]$cfg.max_positions) {
        Write-Host "  Max positions reached -- monitoring exits only." -ForegroundColor Yellow
        $state.last_scan = (Get-Date).ToString("o"); Save-State $state
        return
    }

    $entryWindowOk = if ($swingMode) { Test-SwingEntryWindow } else { Test-TradingWindow $cfg }
    if (-not $entryWindowOk) {
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

    # Symbols that already have a WORKING (unfilled) order. A GTC bracket entry
    # submitted on a prior scan isn't a filled position yet, so checking only
    # $positions let the bot re-enter the same name before the first order
    # filled (QCOM double-entry -> 2x risk). One fetch, reused for every symbol.
    $workingOrderSyms = @{}
    $openOrdersAll = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=open&limit=200"
    if ($null -ne $openOrdersAll) {
        $ooArr = if ($openOrdersAll -is [System.Array]) { $openOrdersAll } else { @($openOrdersAll) }
        foreach ($oo in $ooArr) { if ($null -ne $oo -and $oo.symbol) { $workingOrderSyms[$oo.symbol] = $true } }
    }

    foreach ($symbol in $watchlist) {
        # ── Max 1 entry per scan ──────────────────────────────────────────
        # A seasoned trader enters one position, watches it breathe, then
        # evaluates the next. Prevents 3-trade bursts that blow position limit.
        if ($enteredThisScan) {
            break
        }

        # Skip if a position (EITHER bot -- never commingle on a symbol the
        # other bot already holds), a working order, or a pending trade exists.
        $hasPos     = $allPosSyms.ContainsKey($symbol)
        $hasPending = ($pending | Where-Object { $_.symbol -eq $symbol }).Count -gt 0
        $hasWorking = $workingOrderSyms.ContainsKey($symbol)
        if ($hasPos -or $hasPending -or $hasWorking) {
            Write-Host ("  {0,-6} SKIP  (position/working order/pending exists)" -f $symbol) -ForegroundColor DarkGray
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

        # ── Index anchors are WATCH-ONLY ──────────────────────────────────
        # SPY/QQQ stay on the list for market context but are never entered:
        # 20 of the first 23 swing trades were anchor churn (QQQ 2W/10L).
        if ($INDEX_ANCHORS -contains $symbol) {
            Write-Host ("  {0,-6} SKIP  (index anchor -- watch-only)" -f $symbol) -ForegroundColor DarkGray
            continue
        }

        # ── Memory gate + loss cooldown ───────────────────────────────────
        # The self-learning layer finally gets veto power at the entry:
        #   - proven loser (5+ trades, score <= 0.3) -> benched
        #   - lost on this symbol within the last 5 trading days -> cooldown
        #     (stops the re-enter-the-same-failing-setup churn pattern)
        $memInfo = Get-TickerMemoryInfo $symbol
        if ($null -ne $memInfo) {
            $memScore  = if ($null -ne $memInfo.score) { [double]$memInfo.score } else { 1.0 }
            $memTrades = if ($null -ne $memInfo.trades) { [int]$memInfo.trades } else { 0 }
            if ($memTrades -ge 5 -and $memScore -le 0.3) {
                Write-Host ("  {0,-6} SKIP  (memory gate: {1} trades, score {2})" -f $symbol, $memTrades, $memScore) -ForegroundColor Yellow
                continue
            }
            $consecL = if ($null -ne $memInfo.consecutive_losses) { [int]$memInfo.consecutive_losses } else { 0 }
            if ($consecL -ge 1 -and $memInfo.last_trade) {
                try {
                    $lastTradeUtc = [datetime]::Parse($memInfo.last_trade).ToUniversalTime()
                    $daysSince    = Get-WeekdayCount $lastTradeUtc ([datetime]::UtcNow)
                    if ($daysSince -lt 5) {
                        Write-Host ("  {0,-6} SKIP  (loss cooldown: lost {1} trading day(s) ago, wait 5)" -f $symbol, $daysSince) -ForegroundColor Yellow
                        continue
                    }
                } catch {}
            }
        }

        if ($swingMode) {
            # Swing: signals come from DAILY bars -- stops live outside
            # intraday noise, targets get days to develop.
            $dailyBars = Get-DailyBars $cfg $symbol
            if ($dailyBars.Count -lt 60) {
                Write-Host ("  {0,-6} SKIP  (insufficient daily bars: {1})" -f $symbol, $dailyBars.Count) -ForegroundColor DarkGray
                continue
            }
            $signal = Get-SwingBestSignal $cfg $symbol $dailyBars $regime.Regime $spyDaily
            if ($null -eq $signal) {
                $last = ($dailyBars | Select-Object -Last 1).Close
                Write-Host ("  {0,-6} WATCH  `${1:F2}  -- no valid setup" -f $symbol, $last) -ForegroundColor DarkGray
                continue
            }
        } else {
            # Fetch bar data
            $bars1m = Get-IntradayBars $cfg $symbol "1Min"
            $bars5m = Get-IntradayBars $cfg $symbol "5Min"

            # Only gate on 1m bars (ORB's requirement -- ~20 min after open).
            # The 5m strategies self-guard at 30 bars inside alpaca_signals.ps1,
            # so a thin 5m series just means they return invalid -- no need to
            # block the whole symbol here.
            if ($bars1m.Count -lt 20) {
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
            # Swing brackets are GTC -- the trade needs days, not hours.
            # Stale unfilled entries are reaped by Cancel-StaleEntries.
            $tif = if ($swingMode) { "gtc" } else { "day" }
            Submit-BracketOrder $cfg $symbol $signal.Side $validation.Sizing.Shares `
                $signal.Entry $signal.T1 $signal.Stop $signal.Strategy $tif | Out-Null
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
