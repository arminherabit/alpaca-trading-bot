# Swing-mode signal engine -- daily-bar strategies for 2-10 day holds.
#
# WHY SWING: 25 closed day trades produced a 12% win rate. Root cause was
# structural: stops sized from 5-min ATR (noise-level) with targets needing
# multi-hour moves -- the stop is statistically tagged before the thesis is
# tested. Daily-bar swing trades put stops at 2x DAILY ATR (genuinely outside
# noise) and give targets days to develop. The account's single profitable
# trade (MRVL short, +$3-6k) was a de facto swing trade.
#
# Strategies:
#   BRKOUT  -- Daily Breakout: close pushes above the 20-day high on
#              above-average volume. Momentum continuation.
#   PULLBK  -- Daily EMA Pullback: established uptrend (close>EMA20>EMA50),
#              price pulls back to the EMA20 zone and reclaims it.
#   Short mirrors (BRKDN / RALLYF) fire only when the swing regime is BEAR.
#
# All stops = 2.0x daily ATR(14). All targets = 3.5R. Min R:R enforced by
# config (3.0). Strategy tags must contain no underscore -- client_order_id
# parsing splits on the first "_".
#
# Dot-source dependencies: alpaca_indicators.ps1 (Get-EMAArray, Get-ATR, ...)

$SWING_STOP_ATR_MULT = 2.0
$SWING_TARGET_R      = 3.5
$SWING_MIN_BARS      = 60     # need EMA50 + 20-day lookback with margin
# Reject setups whose stop sits more than this fraction of price away. A
# 2x-ATR stop normally lands ~3-6% out; when a recent earnings gap inflates
# daily ATR it can balloon past 10%, producing untradeable geometry and
# oversized dollar risk (QCOM: 14.7% stop). Cap it.
$SWING_MAX_STOP_PCT  = 0.10

function New-SwingSignal([string]$strategy) {
    return [pscustomobject]@{
        Symbol     = ""
        Strategy   = $strategy
        Side       = ""
        Valid      = $false
        Entry      = 0.0
        Stop       = 0.0
        T1         = 0.0
        T2         = 0.0
        RR         = 0.0
        Confidence = 0
        Reason     = ""
    }
}

# Split daily bars into completed history vs today's (possibly partial) bar.
# During market hours the last bar IS today and still forming; after close
# it is complete but still "today". Lookback ranges (20-day high, EMAs, ATR)
# must use only completed PRIOR days so today's action is the trigger, not
# part of its own baseline.
function Split-DailyBars($bars) {
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $etToday = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).ToString("yyyy-MM-dd")

    $lastBar  = $bars[$bars.Count - 1]
    $lastIsToday = ($lastBar.Time.ToString("yyyy-MM-dd") -eq $etToday)
    $history = if ($lastIsToday) { $bars[0..($bars.Count - 2)] } else { $bars }
    $current = $lastBar   # today's bar when present, else most recent close
    return [pscustomobject]@{ History = $history; Current = $current; LastIsToday = $lastIsToday }
}

# Relative strength vs SPY over ~20 trading days. Positive = outperforming.
# $spyBars passed in so we fetch SPY dailies once per scan, not per symbol.
function Get-RelativeStrength($bars, $spyBars, [int]$lookback = 20) {
    if ($null -eq $spyBars -or $spyBars.Count -lt ($lookback + 1) -or $bars.Count -lt ($lookback + 1)) { return 0.0 }
    $symNow  = $bars[$bars.Count - 1].Close
    $symThen = $bars[$bars.Count - 1 - $lookback].Close
    $spyNow  = $spyBars[$spyBars.Count - 1].Close
    $spyThen = $spyBars[$spyBars.Count - 1 - $lookback].Close
    if ($symThen -le 0 -or $spyThen -le 0) { return 0.0 }
    return [Math]::Round((($symNow / $symThen) - ($spyNow / $spyThen)) * 100, 2)
}

# -- BRKOUT: Daily Breakout (long) / BRKDN: Daily Breakdown (short) ----------

function Get-SwingBreakoutSignal($cfg, $dailyBars, [string]$swingRegime, $spyBars) {
    $sig = New-SwingSignal "BRKOUT"
    if ($null -eq $dailyBars -or $dailyBars.Count -lt $SWING_MIN_BARS) { return $sig }

    $split   = Split-DailyBars $dailyBars
    $hist    = $split.History
    $today   = $split.Current
    if ($hist.Count -lt $SWING_MIN_BARS - 1) { return $sig }

    $closes  = @($hist | ForEach-Object { $_.Close })
    $atr     = Get-ATR $hist 14
    if ($null -eq $atr -or $atr -le 0) { return $sig }

    # 20-day high/low from COMPLETED days only
    $look20   = $hist | Select-Object -Last 20
    $high20   = ($look20 | Measure-Object -Property High -Maximum).Maximum
    $low20    = ($look20 | Measure-Object -Property Low  -Minimum).Minimum
    $avgVol20 = ($look20 | Measure-Object -Property Volume -Average).Average

    # Volume confirmation: today's cumulative volume, pace-adjusted for time
    # of day (same trick as the screener's RVOL fix). After close, progress=1.
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $etNow    = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
    $elapsed  = ($etNow - $etNow.Date.AddHours(9).AddMinutes(30)).TotalMinutes
    $progress = [Math]::Max(0.1, [Math]::Min(1.0, $elapsed / 390.0))
    $volPace  = if ($avgVol20 -gt 0) { $today.Volume / ($avgVol20 * $progress) } else { 0 }

    $price = $today.Close

    # LONG breakout: price clears the 20-day high. Blocked in BEAR regime.
    if ($price -gt $high20 -and $swingRegime -ne "BEAR") {
        # HARD GATES (entry-quality package):
        #  - RS >= +1.5% vs SPY: only market LEADERS break out and keep going;
        #    a laggard poking a 20-day high in chop is a fade. Also inherently
        #    blocks index-hugging names (their RS ~ 0 by construction).
        #  - volPace >= 1.1: a breakout without above-average participation
        #    has no fuel. Volume was previously only a confidence nudge.
        $rs = Get-RelativeStrength $dailyBars $spyBars 20
        if ($rs -lt 1.5)      { return $sig }
        if ($volPace -lt 1.1) { return $sig }

        $sig.Side  = "buy"
        $sig.Entry = [Math]::Round($price, 2)
        $sig.Stop  = [Math]::Round($price - $SWING_STOP_ATR_MULT * $atr, 2)
        $risk      = $sig.Entry - $sig.Stop
        if ($risk -le 0) { return $sig }
        if (($risk / $sig.Entry) -gt $SWING_MAX_STOP_PCT) { return $sig }  # ATR too inflated -- untradeable
        $sig.T1    = [Math]::Round($sig.Entry + $SWING_TARGET_R * $risk, 2)
        $sig.T2    = $sig.T1
        $sig.RR    = $SWING_TARGET_R

        $conf = 50
        $extension = ($price - $high20) / $atr
        if ($volPace -ge 1.5)                       { $conf += 20 }   # real participation
        elseif ($volPace -ge 1.0)                   { $conf += 10 }
        if ($extension -le 0.5)                     { $conf += 10 }   # fresh break, not chasing
        elseif ($extension -gt 1.5)                 { $conf -= 15 }   # extended -- late entry
        if ($rs -ge 3.0)                            { $conf += 15 }   # market leader (RS gated >= 1.5 above)
        elseif ($rs -ge 2.0)                        { $conf += 5  }
        $ema20 = Get-EMA $closes 20
        $ema50 = Get-EMA $closes 50
        if ($null -ne $ema20 -and $null -ne $ema50 -and $ema20 -gt $ema50) { $conf += 10 }  # trend aligned

        $sig.Confidence = [Math]::Max(0, [Math]::Min(100, $conf))
        $sig.Reason     = "20d-high break (ext {0:F2} ATR, volPace {1:F1}x, RS {2:+0.0;-0.0}%)" -f $extension, $volPace, $rs
        $sig.Valid      = $true
        return $sig
    }

    # SHORT breakdown: price loses the 20-day low. Only in BEAR regime --
    # shorting breakdowns in bull tape is fighting the primary trend.
    if ($price -lt $low20 -and $swingRegime -eq "BEAR") {
        # HARD GATES (mirror): weakest names on real volume only.
        $rs = Get-RelativeStrength $dailyBars $spyBars 20
        if ($rs -gt -1.5)     { return $sig }
        if ($volPace -lt 1.1) { return $sig }

        $sig.Strategy = "BRKDN"
        $sig.Side  = "sell"
        $sig.Entry = [Math]::Round($price, 2)
        $sig.Stop  = [Math]::Round($price + $SWING_STOP_ATR_MULT * $atr, 2)
        $risk      = $sig.Stop - $sig.Entry
        if ($risk -le 0) { return $sig }
        if (($risk / $sig.Entry) -gt $SWING_MAX_STOP_PCT) { return $sig }  # ATR too inflated -- untradeable
        $sig.T1    = [Math]::Round([Math]::Max(0.01, $sig.Entry - $SWING_TARGET_R * $risk), 2)
        $sig.T2    = $sig.T1
        $sig.RR    = $SWING_TARGET_R

        $conf = 50
        $extension = ($low20 - $price) / $atr
        if ($volPace -ge 1.5)       { $conf += 20 }
        elseif ($volPace -ge 1.0)   { $conf += 10 }
        if ($extension -le 0.5)     { $conf += 10 }
        elseif ($extension -gt 1.5) { $conf -= 15 }
        if ($rs -le -3.0)           { $conf += 15 }   # weakest names fall hardest (RS gated <= -1.5 above)
        elseif ($rs -le -2.0)       { $conf += 5  }
        $ema20 = Get-EMA $closes 20
        $ema50 = Get-EMA $closes 50
        if ($null -ne $ema20 -and $null -ne $ema50 -and $ema20 -lt $ema50) { $conf += 10 }

        $sig.Confidence = [Math]::Max(0, [Math]::Min(100, $conf))
        $sig.Reason     = "20d-low breakdown (ext {0:F2} ATR, volPace {1:F1}x, RS {2:+0.0;-0.0}%)" -f $extension, $volPace, $rs
        $sig.Valid      = $true
        return $sig
    }

    return $sig
}

# -- PULLBK: Daily EMA Pullback (long) / RALLYF: failed-rally short ----------

function Get-SwingPullbackSignal($cfg, $dailyBars, [string]$swingRegime, $spyBars) {
    $sig = New-SwingSignal "PULLBK"
    if ($null -eq $dailyBars -or $dailyBars.Count -lt $SWING_MIN_BARS) { return $sig }

    $split = Split-DailyBars $dailyBars
    $hist  = $split.History
    $today = $split.Current
    if ($hist.Count -lt $SWING_MIN_BARS - 1) { return $sig }

    $closes = @($hist | ForEach-Object { $_.Close })
    $atr    = Get-ATR $hist 14
    $ema20  = Get-EMA $closes 20
    $ema50  = Get-EMA $closes 50
    if ($null -eq $atr -or $atr -le 0 -or $null -eq $ema20 -or $null -eq $ema50) { return $sig }

    $price     = $today.Close
    $prevClose = $hist[$hist.Count - 1].Close

    # LONG pullback: established uptrend, price dipped into the EMA20 zone
    # within the last 3 days, and today reclaims above EMA20.
    if ($swingRegime -ne "BEAR" -and $ema20 -gt $ema50 -and $prevClose -gt $ema50) {
        $recent      = $hist | Select-Object -Last 3
        $touchedZone = ($recent | Where-Object { $_.Low -le $ema20 * 1.005 }).Count -gt 0
        $reclaimed   = $price -gt $ema20

        if ($touchedZone -and $reclaimed) {
            # HARD GATE: pullbacks are only worth buying in LEADERS (RS >= +1.5%
            # vs SPY). An index-hugging or lagging name reclaiming its EMA20 in
            # chop was the QQQ churn pattern (2W/10L).
            $rs = Get-RelativeStrength $dailyBars $spyBars 20
            if ($rs -lt 1.5) { return $sig }

            $sig.Side  = "buy"
            $sig.Entry = [Math]::Round($price, 2)
            # Stop below BOTH the EMA50 and 2x ATR -- whichever is closer caps
            # risk; if EMA50 is further than 3 ATR the setup is too sloppy.
            $stopAtr   = $price - $SWING_STOP_ATR_MULT * $atr
            $stopEma   = $ema50 - 0.25 * $atr
            $stop      = [Math]::Max($stopAtr, $stopEma)   # tighter of the two
            if (($price - $stop) -gt 3.0 * $atr) { return $sig }
            $sig.Stop  = [Math]::Round($stop, 2)
            $risk      = $sig.Entry - $sig.Stop
            if ($risk -le 0) { return $sig }
            if (($risk / $sig.Entry) -gt $SWING_MAX_STOP_PCT) { return $sig }  # ATR too inflated -- untradeable
            $sig.T1    = [Math]::Round($sig.Entry + $SWING_TARGET_R * $risk, 2)
            $sig.T2    = $sig.T1
            $sig.RR    = $SWING_TARGET_R

            $conf = 50
            $trendQuality = ($ema20 - $ema50) / $atr        # EMA separation in ATR units
            if ($trendQuality -ge 1.0)     { $conf += 15 }  # strong, orderly trend
            elseif ($trendQuality -ge 0.4) { $conf += 8  }
            $rsi = Get-RSI $closes 14
            if ($null -ne $rsi -and $rsi -ge 40 -and $rsi -le 60) { $conf += 10 }  # healthy reset, not broken
            if ($rs -ge 3.0)     { $conf += 15 }   # (RS gated >= 1.5 above)
            elseif ($rs -ge 2.0) { $conf += 5  }
            if ($today.Close -gt $today.Open) { $conf += 5 }   # buyers showed up today

            $sig.Confidence = [Math]::Max(0, [Math]::Min(100, $conf))
            $sig.Reason     = "EMA20 pullback reclaim (trendQ {0:F2} ATR, RS {1:+0.0;-0.0}%)" -f $trendQuality, $rs
            $sig.Valid      = $true
            return $sig
        }
    }

    # SHORT failed rally: established downtrend, price rallied into the EMA20
    # zone and got rejected back below. BEAR regime only.
    if ($swingRegime -eq "BEAR" -and $ema20 -lt $ema50 -and $prevClose -lt $ema50) {
        $recent      = $hist | Select-Object -Last 3
        $touchedZone = ($recent | Where-Object { $_.High -ge $ema20 * 0.995 }).Count -gt 0
        $rejected    = $price -lt $ema20

        if ($touchedZone -and $rejected) {
            # HARD GATE (mirror): only short LAGGARDS (RS <= -1.5% vs SPY).
            $rs = Get-RelativeStrength $dailyBars $spyBars 20
            if ($rs -gt -1.5) { return $sig }

            $sig.Strategy = "RALLYF"
            $sig.Side  = "sell"
            $sig.Entry = [Math]::Round($price, 2)
            $stopAtr   = $price + $SWING_STOP_ATR_MULT * $atr
            $stopEma   = $ema50 + 0.25 * $atr
            $stop      = [Math]::Min($stopAtr, $stopEma)
            if (($stop - $price) -gt 3.0 * $atr) { return $sig }
            $sig.Stop  = [Math]::Round($stop, 2)
            $risk      = $sig.Stop - $sig.Entry
            if ($risk -le 0) { return $sig }
            if (($risk / $sig.Entry) -gt $SWING_MAX_STOP_PCT) { return $sig }  # ATR too inflated -- untradeable
            $sig.T1    = [Math]::Round([Math]::Max(0.01, $sig.Entry - $SWING_TARGET_R * $risk), 2)
            $sig.T2    = $sig.T1
            $sig.RR    = $SWING_TARGET_R

            $conf = 50
            $trendQuality = ($ema50 - $ema20) / $atr
            if ($trendQuality -ge 1.0)     { $conf += 15 }
            elseif ($trendQuality -ge 0.4) { $conf += 8  }
            $rsi = Get-RSI $closes 14
            if ($null -ne $rsi -and $rsi -ge 40 -and $rsi -le 60) { $conf += 10 }
            if ($rs -le -3.0)     { $conf += 15 }   # (RS gated <= -1.5 above)
            elseif ($rs -le -2.0) { $conf += 5  }
            if ($today.Close -lt $today.Open) { $conf += 5 }

            $sig.Confidence = [Math]::Max(0, [Math]::Min(100, $conf))
            $sig.Reason     = "EMA20 rally rejection (trendQ {0:F2} ATR, RS {1:+0.0;-0.0}%)" -f $trendQuality, $rs
            $sig.Valid      = $true
            return $sig
        }
    }

    return $sig
}

# -- Selector -----------------------------------------------------------------

function Get-SwingBestSignal($cfg, [string]$symbol, $dailyBars, [string]$swingRegime, $spyBars) {
    $signals = @()
    foreach ($s in @(
        (Get-SwingBreakoutSignal $cfg $dailyBars $swingRegime $spyBars),
        (Get-SwingPullbackSignal $cfg $dailyBars $swingRegime $spyBars)
    )) {
        $s.Symbol = $symbol
        if ($s.Valid) { $signals += $s }
    }
    if ($signals.Count -eq 0) { return $null }
    return $signals | Sort-Object -Property Confidence -Descending | Select-Object -First 1
}
