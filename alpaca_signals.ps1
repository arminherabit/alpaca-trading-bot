# Alpaca Signal Engine -- 3 Day Trading Strategies
# Dot-source alpaca_indicators.ps1 before using these functions.
#
# Returns a signal object with:
#   Symbol, Strategy, Side, Entry, Stop, T1, T2, RR, Confidence, Reason[], Valid

. (Join-Path $PSScriptRoot "alpaca_indicators.ps1")

# ── Strategy 1: Opening Range Breakout (ORB) ──────────────────────────────────
# Setup:  First 15-min high/low defines the range.
# Long:   Price closes above ORB high on a 1-min bar with expanding volume.
# Short:  Price closes below ORB low on a 1-min bar with expanding volume.
# Stop:   Opposite side of ORB range.
# Target: 1.5x-2x range projected from breakout level.

function Get-ORBSignal($cfg, $bars1m, [string]$htfBias = "NEUTRAL") {
    $signal = [pscustomobject]@{
        Symbol     = ""; Strategy = "ORB"; Side = ""; Entry = 0.0
        Stop       = 0.0; T1 = 0.0; T2 = 0.0; RR = 0.0
        Confidence = 0; Reason = @(); Valid = $false
    }

    if ($null -eq $bars1m -or $bars1m.Count -lt 20) {
        $signal.Reason += "Not enough 1m bars"; return $signal
    }

    # ORB is only relevant early in the session — don't chase stale breakouts
    $etNowOrb  = Get-EasternTime
    $orbCutoff = if ($cfg.orb_cutoff) { $cfg.orb_cutoff } else { "10:45" }
    $cutoffT   = [datetime]::ParseExact($orbCutoff, "HH:mm", $null)
    if ($etNowOrb -gt $etNowOrb.Date.Add($cutoffT.TimeOfDay)) {
        $signal.Reason += ("ORB setups only valid before {0} ET -- skipping" -f $orbCutoff)
        return $signal
    }

    $orb = Get-OpeningRange $bars1m $cfg.orb_minutes
    if ($null -eq $orb -or $orb.Range -le 0) {
        $signal.Reason += "ORB not established yet"; return $signal
    }

    [double[]]$closes = $bars1m | ForEach-Object { $_.Close }
    [double[]]$vols   = $bars1m | ForEach-Object { $_.Volume }
    $rsi    = Get-RSI $closes 14
    $relVol = Get-RelativeVolume $bars1m 20
    $last   = $bars1m[$bars1m.Count - 1]
    $prev   = $bars1m[$bars1m.Count - 2]

    $signal.Reason += ("ORB H={0:F2} L={1:F2} Range={2:F2}" -f $orb.High, $orb.Low, $orb.Range)
    $signal.Reason += ("RSI={0}  RelVol={1}x  Last Close={2:F2}" -f $rsi, $relVol, $last.Close)

    # Long breakout
    if ($last.Close -gt $orb.High -and $prev.Close -le $orb.High) {
        # HTF hard gate -- never long against a confirmed 15m downtrend
        if ($htfBias -eq "BEARISH") {
            $signal.Reason += "LONG breakout detected but HTF 15m BEARISH -- HARD REJECT"
            return $signal   # Side stays empty, Valid stays false
        }
        $signal.Side   = "buy"
        $signal.Entry  = [Math]::Round($orb.High + 0.01, 2)
        $signal.Stop   = [Math]::Round($orb.Low  - 0.01, 2)
        $signal.T1     = [Math]::Round($signal.Entry + $orb.Range * 1.0, 2)
        $signal.T2     = [Math]::Round($signal.Entry + $orb.Range * 2.0, 2)
        $signal.Reason += "LONG breakout above ORB high"
        $conf = 50
        if ($relVol -ge 1.5) { $conf += 20; $signal.Reason += "Volume surge (${relVol}x)" }
        if ($rsi -ge 50 -and $rsi -le 70) { $conf += 15; $signal.Reason += "RSI bullish zone" }
        if ($last.Close -gt $last.Open)   { $conf += 15; $signal.Reason += "Green candle confirms" }
        if ($htfBias -eq "BULLISH")       { $conf += 10; $signal.Reason += "HTF 15m BULLISH -- aligned +10" }
        else                              { $signal.Reason += "HTF 15m NEUTRAL -- allowed" }
        $signal.Confidence = $conf
        $risk = $signal.Entry - $signal.Stop
        $signal.RR = if ($risk -gt 0) { [Math]::Round(($signal.T1 - $signal.Entry) / $risk, 2) } else { 0 }
        $signal.Valid = ($signal.Confidence -ge 65 -and $signal.RR -ge $cfg.min_rr_ratio)
        return $signal
    }

    # Short breakout
    if ($last.Close -lt $orb.Low -and $prev.Close -ge $orb.Low) {
        # HTF hard gate -- never short against a confirmed 15m uptrend
        if ($htfBias -eq "BULLISH") {
            $signal.Reason += "SHORT breakdown detected but HTF 15m BULLISH -- HARD REJECT"
            return $signal
        }
        $signal.Side   = "sell"
        $signal.Entry  = [Math]::Round($orb.Low  - 0.01, 2)
        $signal.Stop   = [Math]::Round($orb.High + 0.01, 2)
        $signal.T1     = [Math]::Round($signal.Entry - $orb.Range * 1.0, 2)
        $signal.T2     = [Math]::Round($signal.Entry - $orb.Range * 2.0, 2)
        $signal.Reason += "SHORT breakdown below ORB low"
        $conf = 50
        if ($relVol -ge 1.5) { $conf += 20; $signal.Reason += "Volume surge (${relVol}x)" }
        if ($rsi -le 50 -and $rsi -ge 30) { $conf += 15; $signal.Reason += "RSI bearish zone" }
        if ($last.Close -lt $last.Open)   { $conf += 15; $signal.Reason += "Red candle confirms" }
        if ($htfBias -eq "BEARISH")       { $conf += 10; $signal.Reason += "HTF 15m BEARISH -- aligned +10" }
        else                              { $signal.Reason += "HTF 15m NEUTRAL -- allowed" }
        $signal.Confidence = $conf
        $risk = $signal.Stop - $signal.Entry
        $signal.RR = if ($risk -gt 0) { [Math]::Round(($signal.Entry - $signal.T1) / $risk, 2) } else { 0 }
        $signal.Valid = ($signal.Confidence -ge 65 -and $signal.RR -ge $cfg.min_rr_ratio)
        return $signal
    }

    $signal.Reason += ("Watching ORB -- price {0:F2} inside range ({1:F2}-{2:F2})" -f $last.Close, $orb.Low, $orb.High)
    return $signal
}

# ── Strategy 2: VWAP Bounce ───────────────────────────────────────────────────
# Setup:  Price in uptrend (above 5-min 9 EMA), pulls back to VWAP, then reclaims it.
# Long:   Price dips below VWAP then closes back above it with RSI rising from oversold.
# Stop:   Below the low of the VWAP-touch candle.
# Target: Previous swing high.

function Get-VWAPSignal($cfg, $bars5m, [string]$htfBias = "NEUTRAL") {
    $signal = [pscustomobject]@{
        Symbol     = ""; Strategy = "VWAP_BOUNCE"; Side = ""; Entry = 0.0
        Stop       = 0.0; T1 = 0.0; T2 = 0.0; RR = 0.0
        Confidence = 0; Reason = @(); Valid = $false
    }

    if ($null -eq $bars5m -or $bars5m.Count -lt 30) {
        $signal.Reason += "Not enough 5m bars"; return $signal
    }

    [double[]]$closes = $bars5m | ForEach-Object { $_.Close }
    $vwapArr  = Get-VWAPArray $bars5m
    $ema9Arr  = Get-EMAArray $closes 9
    $rsiArr   = Get-RSIArray $closes 14
    $atr      = Get-ATR $bars5m 14

    if ($null -eq $vwapArr -or $null -eq $ema9Arr -or $null -eq $rsiArr -or $null -eq $atr) {
        $signal.Reason += "Insufficient data for VWAP calculation"; return $signal
    }

    $last     = $bars5m[$bars5m.Count - 1]
    $prev     = $bars5m[$bars5m.Count - 2]
    $n        = $closes.Count - 1
    $vwapNow  = $vwapArr[$n]
    $vwapPrev = $vwapArr[$n - 1]
    $ema9Now  = $ema9Arr[$n]
    $rsiNow   = $rsiArr[$n]
    $rsiPrev  = $rsiArr[$n - 1]

    $signal.Reason += ("VWAP={0:F2}  EMA9={1:F2}  RSI={2:F1}  ATR={3:F2}" -f `
        $vwapNow, $ema9Now, $rsiNow, $atr)

    $relVol = Get-RelativeVolume $bars5m 20

    # Long VWAP reclaim: prev bar touched/crossed below VWAP, current bar closed above
    $vwapDip   = ($prev.Low -le $vwapPrev)
    $vwapReclaim = ($last.Close -gt $vwapNow -and $prev.Close -le $vwapPrev)
    $uptrend   = ($last.Close -gt $ema9Now)
    $rsiRising = ($rsiNow -gt $rsiPrev -and $rsiPrev -le 45 -and $rsiNow -le 65)

    if ($vwapDip -and $vwapReclaim) {
        # HTF hard gate -- VWAP bounce is long-only and never against the trend
        if ($htfBias -eq "BEARISH") {
            $signal.Reason += "VWAP reclaim detected but HTF 15m BEARISH -- HARD REJECT"
            return $signal   # Side stays empty, Valid stays false
        }
        $signal.Side   = "buy"
        $signal.Entry  = [Math]::Round($last.Close + 0.01, 2)
        $signal.Stop   = [Math]::Round([Math]::Min($prev.Low, $last.Low) - $atr * 0.50, 2)
        $signal.T1     = [Math]::Round($signal.Entry + ($signal.Entry - $signal.Stop) * 2.5, 2)
        $signal.T2     = [Math]::Round($signal.Entry + ($signal.Entry - $signal.Stop) * 4.0, 2)
        $signal.Reason += "VWAP reclaim after dip"
        $conf = 55
        if ($uptrend)         { $conf += 15; $signal.Reason += "Price above EMA9 (uptrend)" }
        if ($rsiRising)       { $conf += 15; $signal.Reason += "RSI rising from oversold" }
        if ($relVol -ge 1.2)  { $conf += 15; $signal.Reason += "Volume above average (${relVol}x)" }
        if ($htfBias -eq "BULLISH") { $conf += 10; $signal.Reason += "HTF 15m BULLISH -- aligned +10" }
        else                        { $signal.Reason += "HTF 15m NEUTRAL -- allowed" }
        $signal.Confidence = $conf
        $risk = $signal.Entry - $signal.Stop
        $signal.RR = if ($risk -gt 0) { [Math]::Round(($signal.T1 - $signal.Entry) / $risk, 2) } else { 0 }
        $signal.Valid = ($signal.Confidence -ge 70 -and $signal.RR -ge $cfg.min_rr_ratio)
        return $signal
    }

    $signal.Reason += ("Watching VWAP -- price {0:F2}, VWAP {1:F2}" -f $last.Close, $vwapNow)
    return $signal
}

# ── Strategy 3: EMA Pullback ──────────────────────────────────────────────────
# Setup:  Price in strong uptrend: above 9 EMA AND 21 EMA on 5-min chart.
# Long:   Price pulls back to 9 EMA, RSI in 40-55 zone (not oversold), candle bounces.
# Stop:   Below 21 EMA.
# Target: 2.5x risk.

function Get-EMAPullbackSignal($cfg, $bars5m, [string]$htfBias = "NEUTRAL") {
    $signal = [pscustomobject]@{
        Symbol     = ""; Strategy = "EMA_PULLBACK"; Side = ""; Entry = 0.0
        Stop       = 0.0; T1 = 0.0; T2 = 0.0; RR = 0.0
        Confidence = 0; Reason = @(); Valid = $false
    }

    if ($null -eq $bars5m -or $bars5m.Count -lt 30) {
        $signal.Reason += "Not enough 5m bars"; return $signal
    }

    [double[]]$closes = $bars5m | ForEach-Object { $_.Close }
    $ema9Arr  = Get-EMAArray $closes 9
    $ema21Arr = Get-EMAArray $closes 21
    $rsiArr   = Get-RSIArray $closes 14
    $atr      = Get-ATR $bars5m 14

    if ($null -eq $ema9Arr -or $null -eq $ema21Arr -or $null -eq $rsiArr -or $null -eq $atr) {
        $signal.Reason += "Insufficient data for EMA calculation"; return $signal
    }

    $last    = $bars5m[$bars5m.Count - 1]
    $prev    = $bars5m[$bars5m.Count - 2]
    $n       = $closes.Count - 1
    $ema9    = $ema9Arr[$n]
    $ema21   = $ema21Arr[$n]
    $rsiNow  = $rsiArr[$n]
    $rsiPrev = $rsiArr[$n - 1]

    $signal.Reason += ("EMA9={0:F2}  EMA21={1:F2}  RSI={2:F1}  ATR={3:F2}  Close={4:F2}" -f `
        $ema9, $ema21, $rsiNow, $atr, $last.Close)

    $relVol = Get-RelativeVolume $bars5m 20

    # Trend filter: price above both EMAs, EMAs in bullish order
    $bullTrend  = ($last.Close -gt $ema9 -and $ema9 -gt $ema21)
    # Pullback: previous bar low touched or crossed 9 EMA, current bar bounced back above
    $touchedEMA = ($prev.Low -le $ema9Arr[$n - 1])
    $bounced    = ($last.Close -gt $ema9 -and $prev.Close -le $ema9Arr[$n - 1])
    $rsiOk      = ($rsiNow -ge 40 -and $rsiNow -le 60)
    $rsiRising  = ($rsiNow -gt $rsiPrev)

    if ($bullTrend -and $touchedEMA -and $bounced) {
        # HTF hard gate -- never long against a confirmed 15m downtrend even
        # when the 5m looks bullish; the higher frame wins
        if ($htfBias -eq "BEARISH") {
            $signal.Reason += "EMA bounce detected but HTF 15m BEARISH -- HARD REJECT"
            return $signal
        }
        $signal.Side   = "buy"
        $signal.Entry  = [Math]::Round($last.Close + 0.01, 2)
        $signal.Stop   = [Math]::Round($ema21 - $atr * 0.50, 2)
        $signal.T1     = [Math]::Round($signal.Entry + ($signal.Entry - $signal.Stop) * 2.5, 2)
        $signal.T2     = [Math]::Round($signal.Entry + ($signal.Entry - $signal.Stop) * 4.0, 2)
        $signal.Reason += "EMA9 bounce in uptrend"
        $conf = 50
        if ($rsiOk)          { $conf += 20; $signal.Reason += "RSI in healthy pullback zone (${rsiNow})" }
        if ($rsiRising)      { $conf += 10; $signal.Reason += "RSI turning back up" }
        if ($relVol -ge 1.2) { $conf += 10; $signal.Reason += "Volume confirming bounce (${relVol}x)" }
        if ($last.Close -gt $last.Open) { $conf += 10; $signal.Reason += "Green bounce candle" }
        if ($htfBias -eq "BULLISH") { $conf += 10; $signal.Reason += "HTF 15m BULLISH -- aligned +10" }
        else                        { $signal.Reason += "HTF 15m NEUTRAL -- allowed" }
        $signal.Confidence = $conf
        $risk = $signal.Entry - $signal.Stop
        $signal.RR = if ($risk -gt 0) { [Math]::Round(($signal.T1 - $signal.Entry) / $risk, 2) } else { 0 }
        $signal.Valid = ($signal.Confidence -ge 70 -and $signal.RR -ge $cfg.min_rr_ratio)
        return $signal
    }

    $signal.Reason += ("Watching EMA -- Close={0:F2} EMA9={1:F2} EMA21={2:F2}" -f $last.Close, $ema9, $ema21)
    return $signal
}

# ── Strategy 2-SHORT: VWAP Rejection ──────────────────────────────────────────
# Mirror of VWAP Bounce. Setup: price in downtrend (below 5-min 9 EMA),
# rallies UP to VWAP, then rejects (closes back below).
# Short: prev high reached/crossed VWAP from below AND current close < VWAP.
# Stop:  Above the high of the VWAP-touch candle + 0.25 ATR.
# Target: 2.5R / 4R.

function Get-ShortVWAPSignal($cfg, $bars5m, [string]$htfBias = "NEUTRAL") {
    $signal = [pscustomobject]@{
        Symbol     = ""; Strategy = "VWAP_REJECTION"; Side = ""; Entry = 0.0
        Stop       = 0.0; T1 = 0.0; T2 = 0.0; RR = 0.0
        Confidence = 0; Reason = @(); Valid = $false
    }

    if ($null -eq $bars5m -or $bars5m.Count -lt 30) {
        $signal.Reason += "Not enough 5m bars"; return $signal
    }

    [double[]]$closes = $bars5m | ForEach-Object { $_.Close }
    $vwapArr  = Get-VWAPArray $bars5m
    $ema9Arr  = Get-EMAArray $closes 9
    $rsiArr   = Get-RSIArray $closes 14
    $atr      = Get-ATR $bars5m 14

    if ($null -eq $vwapArr -or $null -eq $ema9Arr -or $null -eq $rsiArr -or $null -eq $atr) {
        $signal.Reason += "Insufficient data for VWAP calculation"; return $signal
    }

    $last     = $bars5m[$bars5m.Count - 1]
    $prev     = $bars5m[$bars5m.Count - 2]
    $n        = $closes.Count - 1
    $vwapNow  = $vwapArr[$n]
    $vwapPrev = $vwapArr[$n - 1]
    $ema9Now  = $ema9Arr[$n]
    $rsiNow   = $rsiArr[$n]
    $rsiPrev  = $rsiArr[$n - 1]

    $signal.Reason += ("VWAP={0:F2}  EMA9={1:F2}  RSI={2:F1}  ATR={3:F2}" -f `
        $vwapNow, $ema9Now, $rsiNow, $atr)

    $relVol = Get-RelativeVolume $bars5m 20

    # Short VWAP rejection: prev high reached/crossed VWAP, current closed below
    $vwapTouch   = ($prev.High -ge $vwapPrev)
    $vwapReject  = ($last.Close -lt $vwapNow -and $prev.Close -ge $vwapPrev)
    $downtrend   = ($last.Close -lt $ema9Now)
    $rsiFalling  = ($rsiNow -lt $rsiPrev -and $rsiPrev -ge 55 -and $rsiNow -ge 35)

    if ($vwapTouch -and $vwapReject) {
        # HTF hard gate -- never short against a confirmed 15m uptrend
        if ($htfBias -eq "BULLISH") {
            $signal.Reason += "VWAP rejection detected but HTF 15m BULLISH -- HARD REJECT"
            return $signal
        }
        $signal.Side   = "sell"
        $signal.Entry  = [Math]::Round($last.Close - 0.01, 2)
        $signal.Stop   = [Math]::Round([Math]::Max($prev.High, $last.High) + $atr * 0.50, 2)
        $signal.T1     = [Math]::Round($signal.Entry - ($signal.Stop - $signal.Entry) * 2.5, 2)
        $signal.T2     = [Math]::Round($signal.Entry - ($signal.Stop - $signal.Entry) * 4.0, 2)
        $signal.Reason += "VWAP rejection from above"
        $conf = 55
        if ($downtrend)       { $conf += 15; $signal.Reason += "Price below EMA9 (downtrend)" }
        if ($rsiFalling)      { $conf += 15; $signal.Reason += "RSI falling from overbought" }
        if ($relVol -ge 1.2)  { $conf += 15; $signal.Reason += "Volume above average (${relVol}x)" }
        if ($htfBias -eq "BEARISH") { $conf += 10; $signal.Reason += "HTF 15m BEARISH -- aligned +10" }
        else                        { $signal.Reason += "HTF 15m NEUTRAL -- allowed" }
        $signal.Confidence = $conf
        $risk = $signal.Stop - $signal.Entry
        $signal.RR = if ($risk -gt 0) { [Math]::Round(($signal.Entry - $signal.T1) / $risk, 2) } else { 0 }
        $signal.Valid = ($signal.Confidence -ge 70 -and $signal.RR -ge $cfg.min_rr_ratio)
        return $signal
    }

    $signal.Reason += ("Watching VWAP rejection -- price {0:F2}, VWAP {1:F2}" -f $last.Close, $vwapNow)
    return $signal
}

# ── Strategy 3-SHORT: EMA Pullback Short (rejection) ──────────────────────────
# Mirror of EMA Pullback. Setup: price in strong downtrend (below 9 EMA AND
# 21 EMA on 5-min). Short: price rallies up to 9 EMA, RSI in 40-60 zone,
# candle rejects with close back below 9 EMA.
# Stop: Above 21 EMA + 0.15 ATR.
# Target: 2.5R / 4R.

function Get-ShortEMAPullbackSignal($cfg, $bars5m, [string]$htfBias = "NEUTRAL") {
    $signal = [pscustomobject]@{
        Symbol     = ""; Strategy = "EMA_REJECTION"; Side = ""; Entry = 0.0
        Stop       = 0.0; T1 = 0.0; T2 = 0.0; RR = 0.0
        Confidence = 0; Reason = @(); Valid = $false
    }

    if ($null -eq $bars5m -or $bars5m.Count -lt 30) {
        $signal.Reason += "Not enough 5m bars"; return $signal
    }

    [double[]]$closes = $bars5m | ForEach-Object { $_.Close }
    $ema9Arr  = Get-EMAArray $closes 9
    $ema21Arr = Get-EMAArray $closes 21
    $rsiArr   = Get-RSIArray $closes 14
    $atr      = Get-ATR $bars5m 14

    if ($null -eq $ema9Arr -or $null -eq $ema21Arr -or $null -eq $rsiArr -or $null -eq $atr) {
        $signal.Reason += "Insufficient data for EMA calculation"; return $signal
    }

    $last    = $bars5m[$bars5m.Count - 1]
    $prev    = $bars5m[$bars5m.Count - 2]
    $n       = $closes.Count - 1
    $ema9    = $ema9Arr[$n]
    $ema21   = $ema21Arr[$n]
    $rsiNow  = $rsiArr[$n]
    $rsiPrev = $rsiArr[$n - 1]

    $signal.Reason += ("EMA9={0:F2}  EMA21={1:F2}  RSI={2:F1}  ATR={3:F2}  Close={4:F2}" -f `
        $ema9, $ema21, $rsiNow, $atr, $last.Close)

    $relVol = Get-RelativeVolume $bars5m 20

    # Bear trend filter: price below both EMAs, EMAs in bearish order
    $bearTrend  = ($last.Close -lt $ema9 -and $ema9 -lt $ema21)
    # Pullback: prev high touched or crossed 9 EMA from below
    $touchedEMA = ($prev.High -ge $ema9Arr[$n - 1])
    # Rejection: current bar closed back below 9 EMA
    $rejected   = ($last.Close -lt $ema9 -and $prev.Close -ge $ema9Arr[$n - 1])
    $rsiOk      = ($rsiNow -ge 40 -and $rsiNow -le 60)
    $rsiFalling = ($rsiNow -lt $rsiPrev)

    if ($bearTrend -and $touchedEMA -and $rejected) {
        if ($htfBias -eq "BULLISH") {
            $signal.Reason += "EMA rejection detected but HTF 15m BULLISH -- HARD REJECT"
            return $signal
        }
        $signal.Side   = "sell"
        $signal.Entry  = [Math]::Round($last.Close - 0.01, 2)
        $signal.Stop   = [Math]::Round($ema21 + $atr * 0.50, 2)
        $signal.T1     = [Math]::Round($signal.Entry - ($signal.Stop - $signal.Entry) * 2.5, 2)
        $signal.T2     = [Math]::Round($signal.Entry - ($signal.Stop - $signal.Entry) * 4.0, 2)
        $signal.Reason += "EMA9 rejection in downtrend"
        $conf = 50
        if ($rsiOk)          { $conf += 20; $signal.Reason += "RSI in healthy bounce zone (${rsiNow})" }
        if ($rsiFalling)     { $conf += 10; $signal.Reason += "RSI turning back down" }
        if ($relVol -ge 1.2) { $conf += 10; $signal.Reason += "Volume confirming rejection (${relVol}x)" }
        if ($last.Close -lt $last.Open) { $conf += 10; $signal.Reason += "Red rejection candle" }
        if ($htfBias -eq "BEARISH") { $conf += 10; $signal.Reason += "HTF 15m BEARISH -- aligned +10" }
        else                        { $signal.Reason += "HTF 15m NEUTRAL -- allowed" }
        $signal.Confidence = $conf
        $risk = $signal.Stop - $signal.Entry
        $signal.RR = if ($risk -gt 0) { [Math]::Round(($signal.Entry - $signal.T1) / $risk, 2) } else { 0 }
        $signal.Valid = ($signal.Confidence -ge 70 -and $signal.RR -ge $cfg.min_rr_ratio)
        return $signal
    }

    $signal.Reason += ("Watching EMA rejection -- Close={0:F2} EMA9={1:F2} EMA21={2:F2}" -f $last.Close, $ema9, $ema21)
    return $signal
}

# ── Higher Timeframe Bias filter ─────────────────────────────────────────────
# Multi-timeframe confluence: a long setup on the 5-min chart against a clear
# 15-min downtrend is fighting the tape on a higher frame. A seasoned trader
# either passes the trade or takes it with reduced size and a tighter stop.
# Here we model that as a confidence modifier so the existing Valid threshold
# still gates entry.
#
# Returns: "BULLISH", "BEARISH", or "NEUTRAL"
#   BULLISH = close > 9 EMA > 20 EMA on the higher timeframe (default 15m)
#   BEARISH = close < 9 EMA < 20 EMA
#   NEUTRAL = mixed (transitional) OR insufficient data (cautious default)

function Get-HigherTimeframeBias {
    param(
        $cfg,
        [string]$symbol,
        [string]$timeframe = "15Min",
        [int]$limit        = 50
    )

    $bars = Get-Bars $cfg $symbol $timeframe $limit
    if ($null -eq $bars -or $bars.Count -lt 20) { return "NEUTRAL" }

    [double[]]$closes = $bars | ForEach-Object { $_.Close }
    $ema9  = Get-EMA $closes 9
    $ema20 = Get-EMA $closes 20
    if ($null -eq $ema9 -or $null -eq $ema20) { return "NEUTRAL" }

    $lastClose = $closes[$closes.Count - 1]
    if ($lastClose -gt $ema9 -and $ema9 -gt $ema20) { return "BULLISH" }
    if ($lastClose -lt $ema9 -and $ema9 -lt $ema20) { return "BEARISH" }
    return "NEUTRAL"
}

# ── Run all strategies for a symbol ──────────────────────────────────────────

function Get-BestSignal($cfg, [string]$symbol, $bars1m, $bars5m) {
    # Fetch HTF bias ONCE per symbol and pass it down to each strategy.
    # Each strategy owns its own hard-reject logic when opposing the HTF.
    $htfBias = Get-HigherTimeframeBias $cfg $symbol "15Min"

    $signals = @()

    # Long side -- ORB long branch + VWAP Bounce + EMA Pullback
    # (ORB also returns its short branch internally; one function, two directions)
    $orb       = Get-ORBSignal               $cfg $bars1m $htfBias
    $vwapLong  = Get-VWAPSignal              $cfg $bars5m $htfBias
    $emaLong   = Get-EMAPullbackSignal       $cfg $bars5m $htfBias

    # Short side mirrors -- evaluate symmetrically
    $vwapShort = Get-ShortVWAPSignal         $cfg $bars5m $htfBias
    $emaShort  = Get-ShortEMAPullbackSignal  $cfg $bars5m $htfBias

    foreach ($s in @($orb, $vwapLong, $emaLong, $vwapShort, $emaShort)) {
        $s.Symbol = $symbol
        if ($s.Valid) { $signals += $s }
    }

    if ($signals.Count -eq 0) { return $null }

    # Pick highest confidence valid signal
    return $signals | Sort-Object -Property Confidence -Descending | Select-Object -First 1
}
