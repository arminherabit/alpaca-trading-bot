# alpaca_regime.ps1
# Market regime detector -- classifies the current SPY 5-min state and returns
# a recommended position-size multiplier.
#
# A seasoned trader never trades every setup the same way. The same ORB
# breakout that's gold in a calm uptrend is a trap in a VIX spike. This module
# is the gate that tells the bot:
#   - HOW to size today (multiplier)
#   - WHETHER to take longs at all (BEAR_TREND blocks them)
#   - WHICH strategies fit the tape (RANGING favours mean-reversion, TREND
#     favours breakouts; the bot uses this hint downstream).
#
# Output regime decisions:
#   BULL_TREND  close>9EMA>20EMA AND 60-min move >  +0.20 %    size 1.00x
#   BEAR_TREND  close<9EMA<20EMA AND 60-min move <  -0.20 %    size 0.00x (skip)
#   VOLATILE    ATR% of price > 0.25  (regardless of trend)    size 0.50x
#   RANGING     |60-min move| < 0.15 % AND mixed EMAs          size 0.75x
#   NEUTRAL     everything else (transitional)                 size 0.85x

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_indicators.ps1")

function Get-MarketRegime($cfg) {
    $default = [pscustomobject]@{
        Regime         = "NEUTRAL"
        Volatility     = 0.0
        TrendStrength  = 0.0
        SizeMult       = 0.75
        Reason         = "Insufficient SPY data"
        PreferTrend    = $false
        PreferReversion= $false
    }

    $spyBars = Get-IntradayBars $cfg "SPY" "5Min"
    # 21 bars = ~105 min after open (10:15 AM ET). Below this, 9/20 EMA isn't
    # meaningful so we return NEUTRAL with a cautious default size mult.
    if ($null -eq $spyBars -or $spyBars.Count -lt 21) { return $default }

    [double[]]$closes = $spyBars | ForEach-Object { $_.Close }
    $ema9  = Get-EMA $closes 9
    $ema20 = Get-EMA $closes 20
    $atr   = Get-ATR $spyBars 14
    if ($null -eq $ema9 -or $null -eq $ema20 -or $null -eq $atr) { return $default }

    $last = $closes[$closes.Count - 1]

    # Volatility regime -- ATR as % of price (intraday VIX proxy)
    $volPct = [Math]::Round(($atr / $last) * 100, 3)

    # Trend strength -- % move over the last hour (12 bars of 5-min)
    $startIdx   = [Math]::Max(0, $closes.Count - 12)
    $startPrice = $closes[$startIdx]
    $hourMove   = if ($startPrice -gt 0) {
        [Math]::Round((($last - $startPrice) / $startPrice) * 100, 3)
    } else { 0.0 }

    $bullAligned = ($last -gt $ema9 -and $ema9 -gt $ema20)
    $bearAligned = ($last -lt $ema9 -and $ema9 -lt $ema20)

    $regime = "NEUTRAL"; $sizeMult = 0.85; $reason = ""
    $preferTrend = $false; $preferReversion = $false

    if ($volPct -gt 0.25) {
        $regime = "VOLATILE"; $sizeMult = 0.5
        $reason = "ATR=$volPct% -- VIX-like spike, halve size"
    }
    elseif ($bearAligned -and $hourMove -lt -0.2) {
        $regime = "BEAR_TREND"; $sizeMult = 1.0
        $reason = "SPY < 9EMA < 20EMA AND -$([Math]::Abs($hourMove))%/hr -- shorts enabled, longs blocked by HTF gate"
    }
    elseif ($bullAligned -and $hourMove -gt 0.2) {
        $regime = "BULL_TREND"; $sizeMult = 1.0; $preferTrend = $true
        $reason = "SPY > 9EMA > 20EMA AND +$hourMove%/hr -- full size, prefer breakouts"
    }
    elseif ([Math]::Abs($hourMove) -lt 0.15 -and -not ($bullAligned -or $bearAligned)) {
        $regime = "RANGING"; $sizeMult = 0.75; $preferReversion = $true
        $reason = "Flat tape ($hourMove%/hr) -- favour mean-reversion, reduce size"
    }
    else {
        $regime = "NEUTRAL"; $sizeMult = 0.85
        $reason = "Mixed signals (move=$hourMove%, EMAs not aligned)"
    }

    return [pscustomobject]@{
        Regime          = $regime
        Volatility      = $volPct
        TrendStrength   = $hourMove
        SizeMult        = $sizeMult
        Reason          = $reason
        PreferTrend     = $preferTrend
        PreferReversion = $preferReversion
    }
}
