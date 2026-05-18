# Alpaca Technical Indicators
# Works on arrays of bar objects: {Time, Open, High, Low, Close, Volume, VWAP}
# All functions return scalar values (last bar) unless named *Array.

# ── EMA ───────────────────────────────────────────────────────────────────────

function Get-EMAArray([double[]]$closes, [int]$period) {
    if ($closes.Count -lt $period) { return $null }
    $k    = 2.0 / ($period + 1)
    $emas = [double[]]::new($closes.Count)
    $seed = 0.0
    for ($i = 0; $i -lt $period; $i++) { $seed += $closes[$i] }
    $emas[$period - 1] = $seed / $period
    for ($i = $period; $i -lt $closes.Count; $i++) {
        $emas[$i] = $closes[$i] * $k + $emas[$i - 1] * (1 - $k)
    }
    return $emas
}

function Get-EMA([double[]]$closes, [int]$period) {
    $arr = Get-EMAArray $closes $period
    if ($null -eq $arr) { return $null }
    return $arr[$arr.Count - 1]
}

function Get-SMA([double[]]$closes, [int]$period) {
    if ($closes.Count -lt $period) { return $null }
    $slice = $closes[($closes.Count - $period)..($closes.Count - 1)]
    return ($slice | Measure-Object -Sum).Sum / $period
}

# ── RSI ───────────────────────────────────────────────────────────────────────

function Get-RSIArray([double[]]$closes, [int]$period = 14) {
    if ($closes.Count -lt ($period + 1)) { return $null }
    $gains  = [double[]]::new($closes.Count - 1)
    $losses = [double[]]::new($closes.Count - 1)
    for ($i = 1; $i -lt $closes.Count; $i++) {
        $d = $closes[$i] - $closes[$i - 1]
        if ($d -gt 0) { $gains[$i-1] = $d } else { $losses[$i-1] = [Math]::Abs($d) }
    }
    $ag = 0.0; $al = 0.0
    for ($i = 0; $i -lt $period; $i++) { $ag += $gains[$i]; $al += $losses[$i] }
    $ag /= $period; $al /= $period
    $rsiArr = [double[]]::new($closes.Count)
    $rsiArr[$period] = if ($al -eq 0) { 100.0 } else { 100 - (100 / (1 + $ag / $al)) }
    for ($i = $period; $i -lt $gains.Count; $i++) {
        $ag = ($ag * ($period - 1) + $gains[$i])  / $period
        $al = ($al * ($period - 1) + $losses[$i]) / $period
        $rsiArr[$i + 1] = if ($al -eq 0) { 100.0 } else { 100 - (100 / (1 + $ag / $al)) }
    }
    return $rsiArr
}

function Get-RSI([double[]]$closes, [int]$period = 14) {
    $arr = Get-RSIArray $closes $period
    if ($null -eq $arr) { return $null }
    return [Math]::Round($arr[$arr.Count - 1], 2)
}

# ── MACD ──────────────────────────────────────────────────────────────────────

function Get-MACD([double[]]$closes) {
    $e12 = Get-EMAArray $closes 12
    $e26 = Get-EMAArray $closes 26
    if ($null -eq $e12 -or $null -eq $e26) { return $null }

    $macdLine = [double[]]::new($closes.Count)
    for ($i = 25; $i -lt $closes.Count; $i++) { $macdLine[$i] = $e12[$i] - $e26[$i] }

    [double[]]$macdSlice = $macdLine[25..($closes.Count - 1)]
    $signalArr = Get-EMAArray $macdSlice 9
    if ($null -eq $signalArr) { return $null }

    $fullSignal = [double[]]::new($closes.Count)
    for ($i = 0; $i -lt $signalArr.Count; $i++) { $fullSignal[$i + 25] = $signalArr[$i] }

    $last = $closes.Count - 1
    return [pscustomobject]@{
        MACD      = [Math]::Round($macdLine[$last], 4)
        Signal    = [Math]::Round($fullSignal[$last], 4)
        Histogram = [Math]::Round($macdLine[$last] - $fullSignal[$last], 4)
        MACDPrev  = [Math]::Round($macdLine[$last - 1], 4)
        SigPrev   = [Math]::Round($fullSignal[$last - 1], 4)
        Bullish   = ($macdLine[$last] -gt $fullSignal[$last]) -and ($macdLine[$last - 1] -le $fullSignal[$last - 1])
        Bearish   = ($macdLine[$last] -lt $fullSignal[$last]) -and ($macdLine[$last - 1] -ge $fullSignal[$last - 1])
    }
}

# ── ATR ───────────────────────────────────────────────────────────────────────

function Get-ATR($bars, [int]$period = 14) {
    if ($bars.Count -lt ($period + 1)) { return $null }
    $trs = [double[]]::new($bars.Count - 1)
    for ($i = 1; $i -lt $bars.Count; $i++) {
        $hl   = $bars[$i].High  - $bars[$i].Low
        $hpc  = [Math]::Abs($bars[$i].High  - $bars[$i - 1].Close)
        $lpc  = [Math]::Abs($bars[$i].Low   - $bars[$i - 1].Close)
        $trs[$i - 1] = [Math]::Max($hl, [Math]::Max($hpc, $lpc))
    }
    $atr = ($trs[0..($period - 1)] | Measure-Object -Sum).Sum / $period
    for ($i = $period; $i -lt $trs.Count; $i++) {
        $atr = ($atr * ($period - 1) + $trs[$i]) / $period
    }
    return [Math]::Round($atr, 4)
}

# ── VWAP (intraday) ───────────────────────────────────────────────────────────

function Get-VWAP($bars) {
    # Cumulative VWAP from session start. Expects intraday bars.
    if ($null -eq $bars -or $bars.Count -eq 0) { return $null }
    $cumTPV = 0.0; $cumVol = 0.0
    foreach ($b in $bars) {
        $tp      = ($b.High + $b.Low + $b.Close) / 3.0
        $cumTPV += $tp * $b.Volume
        $cumVol += $b.Volume
    }
    if ($cumVol -eq 0) { return $null }
    return [Math]::Round($cumTPV / $cumVol, 4)
}

function Get-VWAPArray($bars) {
    if ($null -eq $bars -or $bars.Count -eq 0) { return $null }
    $result = [double[]]::new($bars.Count)
    $cumTPV = 0.0; $cumVol = 0.0
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $tp      = ($bars[$i].High + $bars[$i].Low + $bars[$i].Close) / 3.0
        $cumTPV += $tp * $bars[$i].Volume
        $cumVol += $bars[$i].Volume
        $result[$i] = if ($cumVol -gt 0) { $cumTPV / $cumVol } else { $bars[$i].Close }
    }
    return $result
}

# ── Opening Range ─────────────────────────────────────────────────────────────

function Get-OpeningRange($bars, [int]$minutes = 15) {
    # Returns {High, Low, Mid} of the first N minutes of the session.
    if ($null -eq $bars -or $bars.Count -eq 0) { return $null }
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $orbBars = $bars | Where-Object {
        $utc    = $_.Time.ToUniversalTime()
        $etTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
        $minsIn = ($etTime - $etTime.Date.AddHours(9).AddMinutes(30)).TotalMinutes
        $minsIn -ge 0 -and $minsIn -lt $minutes
    }
    if ($null -eq $orbBars -or @($orbBars).Count -eq 0) { return $null }
    $high = ($orbBars | Measure-Object -Property High -Maximum).Maximum
    $low  = ($orbBars | Measure-Object -Property Low  -Minimum).Minimum
    return [pscustomobject]@{
        High  = [Math]::Round($high, 4)
        Low   = [Math]::Round($low,  4)
        Mid   = [Math]::Round(($high + $low) / 2.0, 4)
        Range = [Math]::Round($high - $low, 4)
    }
}

# ── Swing High / Low ──────────────────────────────────────────────────────────

function Get-SwingHigh($bars, [int]$lookback = 20) {
    $slice = $bars | Select-Object -Last $lookback
    return ($slice | Measure-Object -Property High -Maximum).Maximum
}

function Get-SwingLow($bars, [int]$lookback = 20) {
    $slice = $bars | Select-Object -Last $lookback
    return ($slice | Measure-Object -Property Low -Minimum).Minimum
}

# ── Volume ────────────────────────────────────────────────────────────────────

function Get-RelativeVolume($bars, [int]$avgBars = 20) {
    if ($bars.Count -lt ($avgBars + 1)) { return $null }
    $hist    = $bars | Select-Object -Last ($avgBars + 1) | Select-Object -First $avgBars
    $avgVol  = ($hist | Measure-Object -Property Volume -Average).Average
    $curVol  = ($bars | Select-Object -Last 1).Volume
    if ($avgVol -eq 0) { return $null }
    return [Math]::Round($curVol / $avgVol, 2)
}
