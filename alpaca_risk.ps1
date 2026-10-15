# Alpaca Risk Management
# Enforces the 1% max risk per trade rule and minimum R:R ratio.
# All sizing is based on live account equity fetched from Alpaca.

. (Join-Path $PSScriptRoot "alpaca_client.ps1")

# ── Position Sizing ───────────────────────────────────────────────────────────

function Get-PositionSize {
    param(
        [double]$equity,
        [double]$entry,
        [double]$stop,
        [double]$maxRiskPct,         # baseline e.g. 1.0 for 1%
        [double]$buyingPower    = 0, # cap position value to BP / max_positions
        [int]$maxPositions      = 3,
        [double]$edgeMultiplier = 1.0,  # from Get-StrategyEdge -- proven setups get bigger size
        [double]$regimeMultiplier = 1.0, # from Get-MarketRegime -- volatile tape gets smaller size
        [double]$maxRiskCap = 1.5        # cfg.max_risk_pct_cap (was hard-coded 1.5)
    )

    if ($entry -le 0 -or $stop -le 0) { return $null }
    $riskPerShare = [Math]::Abs($entry - $stop)
    if ($riskPerShare -le 0) { return $null }

    # Effective risk = baseline × strategy edge × regime, capped at 1.5%.
    # The cap matters: a "proven" strategy on a quiet day could compound multipliers
    # to >2%, which violates the discipline rule. Never risk more than 1.5% on one trade.
    $effectiveRiskPct = $maxRiskPct * $edgeMultiplier * $regimeMultiplier
    if ($effectiveRiskPct -gt $maxRiskCap) { $effectiveRiskPct = $maxRiskCap }
    if ($effectiveRiskPct -lt 0.1) { $effectiveRiskPct = 0.0 }  # full-stop signal from regime

    if ($effectiveRiskPct -le 0) {
        return [pscustomobject]@{
            Shares = 0; RiskPerShare = $riskPerShare; MaxDollarRisk = 0
            ActualRisk = 0; ActualRiskPct = 0; PositionValue = 0
            EffectiveRiskPct = 0; EdgeMult = $edgeMultiplier; RegimeMult = $regimeMultiplier
        }
    }

    $maxDollarRisk = $equity * ($effectiveRiskPct / 100.0)
    $rawShares     = $maxDollarRisk / $riskPerShare
    $shares        = [Math]::Floor($rawShares)   # always round down
    if ($shares -lt 1) { $shares = 1 }

    # Cap shares so position value never exceeds per-slot buying power
    # Use 80% of the per-slot allocation to leave cushion for other positions
    if ($buyingPower -gt 0) {
        $maxPositionValue = ($buyingPower / $maxPositions) * 0.80
        $maxSharesByBP    = [Math]::Floor($maxPositionValue / $entry)
        if ($maxSharesByBP -ge 1 -and $maxSharesByBP -lt $shares) {
            $shares = $maxSharesByBP
        }
    }

    $actualRisk    = $shares * $riskPerShare
    $positionValue = $shares * $entry
    $actualRiskPct = ($actualRisk / $equity) * 100.0

    return [pscustomobject]@{
        Shares            = [int]$shares
        RiskPerShare      = [Math]::Round($riskPerShare,  4)
        MaxDollarRisk     = [Math]::Round($maxDollarRisk, 2)
        ActualRisk        = [Math]::Round($actualRisk,    2)
        ActualRiskPct     = [Math]::Round($actualRiskPct, 3)
        PositionValue     = [Math]::Round($positionValue, 2)
        EffectiveRiskPct  = [Math]::Round($effectiveRiskPct, 3)
        EdgeMult          = [Math]::Round($edgeMultiplier,   3)
        RegimeMult        = [Math]::Round($regimeMultiplier, 3)
    }
}

# ── R:R Validation ────────────────────────────────────────────────────────────

function Test-RiskReward {
    param(
        [double]$entry,
        [double]$stop,
        [double]$target,
        [string]$side,       # "buy" or "sell"
        [double]$minRR       # e.g. 2.5
    )

    $risk   = [Math]::Abs($entry - $stop)
    $reward = if ($side -eq "buy") { $target - $entry } else { $entry - $target }
    if ($risk -le 0) { return [pscustomobject]@{ Valid = $false; RR = 0.0; Reason = "Zero risk" } }

    $rr = [Math]::Round($reward / $risk, 2)
    $ok = ($rr -ge $minRR)
    return [pscustomobject]@{
        Valid  = $ok
        RR     = $rr
        Risk   = [Math]::Round($risk,   4)
        Reward = [Math]::Round($reward, 4)
        Reason = if ($ok) { "R:R ${rr} >= min ${minRR}" } else { "R:R ${rr} below min ${minRR}" }
    }
}

# ── Buying Power Check ────────────────────────────────────────────────────────

function Test-BuyingPower($cfg, [int]$shares, [double]$entry) {
    $bp       = Get-BuyingPower $cfg
    $required = $shares * $entry
    return [pscustomobject]@{
        Sufficient   = ($bp -ge $required)
        BuyingPower  = [Math]::Round($bp,       2)
        Required     = [Math]::Round($required, 2)
        Remaining    = [Math]::Round($bp - $required, 2)
    }
}

# ── Full Trade Validation ─────────────────────────────────────────────────────

function Validate-Trade {
    param($cfg, $signal, $regime = $null)

    $equity  = Get-Equity $cfg
    $bp      = Get-BuyingPower $cfg

    # Edge lookup -- bigger size on proven strategies, smaller on losing ones.
    # Regime-aware: the strategy's record in the CURRENT regime modulates size.
    $edgeMult   = 1.0; $edgeInfo = $null
    if ($cfg.adaptive_sizing) {
        $regimeName = if ($null -ne $regime -and $regime.Regime) { [string]$regime.Regime } else { "" }
        $edgeInfo = Get-StrategyEdge $signal.Strategy $regimeName
        $edgeMult = $edgeInfo.Mult
    }
    $regimeMult = if ($null -ne $regime) { [double]$regime.SizeMult } else { 1.0 }

    $sizing  = Get-PositionSize -equity $equity -entry $signal.Entry `
                                -stop $signal.Stop -maxRiskPct $cfg.max_risk_pct `
                                -buyingPower $bp -maxPositions ([int]$cfg.max_positions) `
                                -edgeMultiplier $edgeMult -regimeMultiplier $regimeMult `
                                -maxRiskCap $(if ($null -ne $cfg.max_risk_pct_cap) { [double]$cfg.max_risk_pct_cap } else { 1.5 })
    $rrCheck = Test-RiskReward  -entry $signal.Entry -stop $signal.Stop `
                                -target $signal.T1   -side $signal.Side `
                                -minRR $cfg.min_rr_ratio
    $bpCheck = Test-BuyingPower $cfg $sizing.Shares $signal.Entry

    $posCount = Get-PositionCount $cfg
    $posOk    = ($posCount -lt [int]$cfg.max_positions)

    $errors   = @()
    if (-not $rrCheck.Valid)      { $errors += ("R:R {0} < min {1}" -f $rrCheck.RR, $cfg.min_rr_ratio) }
    if (-not $bpCheck.Sufficient) { $errors += ("Need `${0}, have `${1}" -f $bpCheck.Required, $bpCheck.BuyingPower) }
    if (-not $posOk)              { $errors += ("Max positions ({0}) reached" -f $cfg.max_positions) }
    if ($signal.Confidence -lt 65) { $errors += ("Confidence {0}% below 65%" -f $signal.Confidence) }
    if ($sizing.Shares -lt 1)     { $errors += "Sizing returned 0 shares (regime/edge cut to zero)" }

    return [pscustomobject]@{
        Valid         = ($errors.Count -eq 0)
        Errors        = $errors
        Equity        = [Math]::Round($equity, 2)
        Sizing        = $sizing
        RRCheck       = $rrCheck
        BPCheck       = $bpCheck
        PositionCount = $posCount
        EdgeInfo      = $edgeInfo
    }
}

# ── Live-price entry check (stale signal guard) ───────────────────────────────
# Swing signals are priced off the daily bar's last IEX print, which can be
# minutes old on a thin or halted name. AEHL 2026-10-14: the last IEX trade was
# $29.00 at 14:05:26Z, nothing printed until 14:10:44, and the bracket limit at
# $29 filled at $26.84 -- with its stop at $26.83, $0.01 under the fill.
# Before any entry we re-read the live quote; if it has drifted more than
# entry_max_slippage_pct from the signal, the signal is rebuilt from the live
# price by the same signal code (same ATR multiple, same stop cap, same
# confidence scoring) and the caller re-runs its normal gates on it.

function Get-EntryCheckCfg($cfg) {
    $d = { param($v, $def) if ($null -ne $v -and "$v" -ne "") { [double]$v } else { $def } }
    return [pscustomobject]@{
        MaxSlippagePct  = & $d $cfg.entry_max_slippage_pct 1.0
        MaxQuoteAgeSec  = & $d $cfg.entry_quote_max_age_sec 60
        MaxSpreadPct    = & $d $cfg.entry_quote_max_spread_pct 2.0
        MinStopAtr      = & $d $cfg.entry_min_stop_atr 0.5
    }
}

# Pure. A quote is only a usable "live price" when it is two-sided, not
# crossed, recent and reasonably tight. Returns @{ Ok; Reason; Mid; SpreadPct; AgeSec }.
function Test-EntryQuote($quote, $ec, [datetime]$nowUtc) {
    $r = [ordered]@{ Ok = $false; Reason = ""; Mid = $null; SpreadPct = $null; AgeSec = $null }
    if ($null -eq $quote) { $r.Reason = "no quote"; return [pscustomobject]$r }
    $bid = [double]$quote.BidPrice; $ask = [double]$quote.AskPrice
    if ($bid -le 0 -or $ask -le 0) { $r.Reason = "one-sided quote (bid $bid / ask $ask)"; return [pscustomobject]$r }
    if ($ask -lt $bid) { $r.Reason = "crossed quote (bid $bid > ask $ask)"; return [pscustomobject]$r }
    $mid = ($bid + $ask) / 2.0
    $r.Mid = [Math]::Round($mid, 4); $r.SpreadPct = [Math]::Round(($ask - $bid) / $mid * 100.0, 2)
    if ($null -ne $quote.Time) { $r.AgeSec = [Math]::Round(($nowUtc - [datetime]$quote.Time).TotalSeconds, 1) }
    if ($null -eq $r.AgeSec)                  { $r.Reason = "quote has no timestamp"; return [pscustomobject]$r }
    if ($r.AgeSec -gt $ec.MaxQuoteAgeSec)     { $r.Reason = "quote {0}s old (max {1}s)" -f $r.AgeSec, $ec.MaxQuoteAgeSec; return [pscustomobject]$r }
    if ($r.SpreadPct -gt $ec.MaxSpreadPct)    { $r.Reason = "spread {0}% (max {1}%)" -f $r.SpreadPct, $ec.MaxSpreadPct; return [pscustomobject]$r }
    $r.Ok = $true
    return [pscustomobject]$r
}

# ATR(14) of COMPLETED days -- the basis every swing stop is built on.
function Get-DailyAtr($dailyBars) {
    if ($null -eq $dailyBars -or @($dailyBars).Count -lt 16) { return $null }
    try { $hist = @((Split-DailyBars $dailyBars).History); return Get-ATR $hist 14 } catch { return $null }
}

# Copy of the daily bars with today's bar re-priced to $price (High/Low widened
# to include it), so the signal can be rebuilt from the live price.
function Set-LiveLastBar($dailyBars, [double]$price) {
    $bars = @($dailyBars)
    $split = Split-DailyBars $bars
    $last = $bars[$bars.Count - 1]
    $live = [pscustomobject]@{ Time = $last.Time; Open = $last.Open; High = [Math]::Max([double]$last.High, $price)
                               Low = [Math]::Min([double]$last.Low, $price); Close = $price; Volume = $last.Volume
                               VWAP = $(if ($null -ne $last.VWAP) { $last.VWAP } else { $price }) }
    if ($split.LastIsToday) { return @($bars[0..($bars.Count - 2)]) + $live }
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $today = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).Date
    return $bars + [pscustomobject]@{ Time = $today; Open = $price; High = $price; Low = $price; Close = $price; Volume = 0; VWAP = $price }
}

# Returns @{ Action = OK | REPRICED | STALE_SIGNAL; Signal; Reason; Mid; DriftPct; SpreadPct; AgeSec; Atr }.
# OK: live price within entry_max_slippage_pct of the signal -> signal unchanged.
# REPRICED: signal rebuilt from the live price (caller must re-run its gates).
# STALE_SIGNAL: no usable live quote, no valid setup at the live price, a
# different setup/side, or a stop closer than entry_min_stop_atr x ATR.
function Update-SignalForLivePrice($cfg, [string]$symbol, $dailyBars, [string]$regimeName, $spyBars, $signal, $quote = $null, $nowUtc = $null) {
    $ec = Get-EntryCheckCfg $cfg
    if ($null -eq $nowUtc) { $nowUtc = [datetime]::UtcNow }
    if ($null -eq $quote) { $quote = Get-Quote $cfg $symbol }
    $res = [ordered]@{ Action = "STALE_SIGNAL"; Signal = $signal; Reason = ""; Mid = $null; DriftPct = $null; SpreadPct = $null; AgeSec = $null; Atr = $null }
    $q = Test-EntryQuote $quote $ec ([datetime]$nowUtc)
    $res.Mid = $q.Mid; $res.SpreadPct = $q.SpreadPct; $res.AgeSec = $q.AgeSec
    if (-not $q.Ok) { $res.Reason = "live quote unusable: " + $q.Reason; return [pscustomobject]$res }
    $atr = Get-DailyAtr $dailyBars
    $res.Atr = $atr
    if ($null -eq $atr -or $atr -le 0) { $res.Reason = "no ATR"; return [pscustomobject]$res }
    $entry = [double]$signal.Entry
    $res.DriftPct = [Math]::Round([Math]::Abs($q.Mid - $entry) / $entry * 100.0, 2)
    $sig = $signal; $action = "OK"
    if ($res.DriftPct -gt $ec.MaxSlippagePct) {
        $sig = Get-SwingBestSignal $cfg $symbol (Set-LiveLastBar $dailyBars ([double]$q.Mid)) $regimeName $spyBars
        if ($null -eq $sig) {
            $res.Reason = "signal {0:F2} vs live {1:F2} ({2}% drift): no valid setup at the live price" -f $entry, $q.Mid, $res.DriftPct
            return [pscustomobject]$res
        }
        if ($sig.Strategy -ne $signal.Strategy -or $sig.Side -ne $signal.Side) {
            $res.Reason = "repriced setup changed ({0} {1} -> {2} {3})" -f $signal.Strategy, $signal.Side, $sig.Strategy, $sig.Side
            return [pscustomobject]$res
        }
        $sig.Reason = "[repriced {0:F2}->{1:F2}] {2}" -f $entry, [double]$sig.Entry, $sig.Reason
        $action = "REPRICED"
    }
    $dist = [Math]::Abs([double]$sig.Entry - [double]$sig.Stop)
    if ($dist -lt $ec.MinStopAtr * $atr) {
        $res.Reason = "stop {0:F2} is {1:F2} ATR from entry {2:F2} (min {3})" -f $sig.Stop, ($dist / $atr), $sig.Entry, $ec.MinStopAtr
        return [pscustomobject]$res
    }
    $res.Action = $action; $res.Signal = $sig
    return [pscustomobject]$res
}

# Pure. After an entry FILLS: if the fill is more than entry_max_slippage_pct
# off the planned entry, or the live stop sits closer than entry_min_stop_atr x
# ATR to the fill, move the stop to (fill -/+ the planned stop distance), never
# closer than entry_min_stop_atr x ATR. Breached = the market is already
# through that new stop. Returns @{ Needed; NewStop; DriftPct; Dist; Breached; Reason }.
function Get-FillStopFix([double]$fill, [double]$plannedEntry, [double]$currentStop, [double]$atr, [string]$side, $ec, [double]$price) {
    $long = ($side -eq "buy" -or $side -eq "long")
    $drift = if ($plannedEntry -gt 0) { [Math]::Abs($fill - $plannedEntry) / $plannedEntry * 100.0 } else { 0 }
    $minDist = $ec.MinStopAtr * $atr
    $curDist = [Math]::Abs($fill - $currentStop)
    $needed = ($drift -gt $ec.MaxSlippagePct) -or ($curDist -lt $minDist)
    $dist = [Math]::Max([Math]::Abs($plannedEntry - $currentStop), $minDist)
    $newStop = if ($long) { [Math]::Round($fill - $dist, 2) } else { [Math]::Round($fill + $dist, 2) }
    $breached = if ($long) { $price -gt 0 -and $price -le $newStop } else { $price -gt 0 -and $price -ge $newStop }
    $why = if (-not $needed) { "fill within tolerance" } elseif ($drift -gt $ec.MaxSlippagePct) { "fill {0:F2} is {1:F2}% off planned {2:F2}" -f $fill, $drift, $plannedEntry } else { "stop {0:F2} only {1:F2} ATR from fill" -f $currentStop, ($curDist / $atr) }
    return [pscustomobject]@{ Needed = $needed; NewStop = $newStop; DriftPct = [Math]::Round($drift, 2); Dist = [Math]::Round($dist, 4); Breached = $breached; Reason = $why }
}

# After an entry FILLS: a limit that was marketable fills at the market, not
# at the limit (AEHL: limit 29.00 filled 26.84), so a stop planned off the
# limit can land on top of the fill. Each newly filled bracket is checked once:
# if the fill is > entry_max_slippage_pct off plan, or the stop leg is closer
# than entry_min_stop_atr x ATR to the fill, the stop leg is moved (PATCH
# stop_price -- allowed on a bracket leg) to fill -/+ the planned distance.
# PYRA adds are skipped: their stop is the campaign's shared stop by design.
# Called from Run-Scan (alpaca_bot.ps1) in swing mode, after Repair-DuplicateStops.
function Repair-EntryFillStops($cfg, $state, $positions) {
    if (-not (Get-Member -InputObject $state -Name "fill_checked" -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        $state | Add-Member -NotePropertyName "fill_checked" -NotePropertyValue @() -Force
    }
    $ec = Get-EntryCheckCfg $cfg
    $dead = @("filled","canceled","cancelled","expired","rejected","done_for_day","replaced")
    foreach ($pos in @($positions)) {
        if ($null -eq $pos -or $pos.asset_class -eq "us_option") { continue }
        $sym = $pos.symbol
        $entrySide = if ($pos.side -eq "long") { "buy" } else { "sell" }
        $exitSide  = if ($pos.side -eq "long") { "sell" } else { "buy" }
        $raw = Invoke-AlpacaApi $cfg "GET" "/v2/orders?status=all&nested=true&symbols=$sym&limit=50"
        $parent = @($raw | Where-Object {
            $_ -and $_.symbol -eq $sym -and $_.status -eq "filled" -and $_.side -eq $entrySide -and $_.order_class -eq "bracket" -and $_.legs -and
            ($MY_ENTRY_PREFIXES -contains ([string]$_.client_order_id -split "_")[0]) -and (([string]$_.client_order_id -split "_")[0] -ne "PYRA") }) |
            Sort-Object { [datetime]::Parse([string]$_.filled_at).ToUniversalTime() } -Descending | Select-Object -First 1
        if ($null -eq $parent -or @($state.fill_checked) -contains $parent.id) { continue }
        $leg = @($parent.legs | Where-Object { $_ -and $_.side -eq $exitSide -and @("stop","stop_limit") -contains $(if ($_.order_type) { $_.order_type } else { $_.type }) -and $dead -notcontains $_.status }) | Select-Object -First 1
        if ($null -eq $leg) { $state.fill_checked = @($state.fill_checked) + $parent.id; continue }   # stop already trailed/replaced: not ours to touch
        $atr = Get-DailyAtr (Get-DailyBars $cfg $sym)
        if ($null -eq $atr -or $atr -le 0) { Write-Host ("    [FILLCHK] {0,-6} no ATR -- retry next scan" -f $sym) -ForegroundColor DarkYellow; continue }
        $fx = Get-FillStopFix ([double]$parent.filled_avg_price) ([double]$parent.limit_price) ([double]$leg.stop_price) $atr $entrySide $ec ([double]$pos.current_price)
        if (-not $fx.Needed) { $state.fill_checked = @($state.fill_checked) + $parent.id; continue }
        if ($fx.Breached) {
            Write-Host ("    [FILLCHK][ALERT] {0,-6} {1}; corrected stop `${2:F2} already breached (mkt `${3:F2}) -- closing" -f $sym, $fx.Reason, $fx.NewStop, [double]$pos.current_price) -ForegroundColor Red
            Close-PositionNow $cfg $pos | Out-Null
            $state.fill_checked = @($state.fill_checked) + $parent.id
            continue
        }
        $res = Update-OrderStop $cfg $leg.id $fx.NewStop
        if ($res) {
            Write-Host ("    [FILLCHK] {0,-6} {1} -- stop `${2:F2} -> `${3:F2} (planned distance `${4:F2})" -f $sym, $fx.Reason, [double]$leg.stop_price, $fx.NewStop, $fx.Dist) -ForegroundColor Yellow
            $state.fill_checked = @($state.fill_checked) + $parent.id
            try { Set-JournalFillFix -symbol $sym -fill ([double]$parent.filled_avg_price) -newStop $fx.NewStop } catch {}
        } else {
            Write-Host ("    [FILLCHK][ALERT] {0,-6} stop re-place FAILED ({1}) -- retrying next scan" -f $sym, $fx.Reason) -ForegroundColor Red
        }
    }
    $state.fill_checked = @(@($state.fill_checked) | Select-Object -Last 200)
}

# ── Display helpers ───────────────────────────────────────────────────────────

function Write-TradeCard($signal, $validation) {
    $s    = $signal
    $v    = $validation
    $sz   = $v.Sizing
    $bias = if ($s.Side -eq "buy") { "LONG  [^]" } else { "SHORT [v]" }
    $slPct = [Math]::Round([Math]::Abs(($s.Entry - $s.Stop) / $s.Entry * 100), 2)
    Write-Host ""
    Write-Host ("  +--- TRADE SETUP: {0} --- {1} ----------------------------" -f $s.Symbol, $s.Strategy.ToUpper())
    Write-Host ("  |  Bias:       {0}" -f $bias)
    Write-Host ("  |  Entry:      `${0:F2}" -f $s.Entry)
    Write-Host ("  |  Stop Loss:  `${0:F2}  ({1:F2}% risk)" -f $s.Stop, $slPct)
    Write-Host ("  |  Target T1:  `${0:F2}  |  T2: `${1:F2}" -f $s.T1, $s.T2)
    Write-Host ("  |  R:R Ratio:  1:{0}" -f $v.RRCheck.RR)
    Write-Host ("  |  Position:   {0} shares  (`${1:F2})  Risk: `${2} ({3}% of equity)" -f `
        $sz.Shares, $sz.PositionValue, $sz.ActualRisk, $sz.ActualRiskPct)
    Write-Host ("  |  Confidence: {0}%" -f $s.Confidence)
    Write-Host ("  |  Account:    `${0:F2} equity  |  `${1:F2} buying power" -f `
        $v.Equity, $v.BPCheck.BuyingPower)
    Write-Host ("  |")
    foreach ($r in $s.Reason) { Write-Host ("  |  * {0}" -f $r) }
    Write-Host ("  |")
    if ($v.Valid) {
        Write-Host ("  |  [APPROVED]  All risk checks passed") -ForegroundColor Green
    } else {
        Write-Host ("  |  [REJECTED]  Risk checks failed:") -ForegroundColor Red
        foreach ($e in $v.Errors) { Write-Host ("  |    x {0}" -f $e) -ForegroundColor Red }
    }
    Write-Host ("  +--------------------------------------------------------")
    Write-Host ""
}
