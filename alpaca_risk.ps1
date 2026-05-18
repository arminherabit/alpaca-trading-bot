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
        [double]$maxRiskPct   # e.g. 1.0 for 1%
    )

    if ($entry -le 0 -or $stop -le 0) { return $null }
    $riskPerShare = [Math]::Abs($entry - $stop)
    if ($riskPerShare -le 0) { return $null }

    $maxDollarRisk = $equity * ($maxRiskPct / 100.0)
    $rawShares     = $maxDollarRisk / $riskPerShare
    $shares        = [Math]::Floor($rawShares)   # always round down
    if ($shares -lt 1) { $shares = 1 }

    $actualRisk    = $shares * $riskPerShare
    $positionValue = $shares * $entry
    $actualRiskPct = ($actualRisk / $equity) * 100.0

    return [pscustomobject]@{
        Shares         = [int]$shares
        RiskPerShare   = [Math]::Round($riskPerShare,  4)
        MaxDollarRisk  = [Math]::Round($maxDollarRisk, 2)
        ActualRisk     = [Math]::Round($actualRisk,    2)
        ActualRiskPct  = [Math]::Round($actualRiskPct, 3)
        PositionValue  = [Math]::Round($positionValue, 2)
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
    param($cfg, $signal)

    $equity  = Get-Equity $cfg
    $sizing  = Get-PositionSize -equity $equity -entry $signal.Entry `
                                -stop $signal.Stop -maxRiskPct $cfg.max_risk_pct
    $rrCheck = Test-RiskReward  -entry $signal.Entry -stop $signal.Stop `
                                -target $signal.T1   -side $signal.Side `
                                -minRR $cfg.min_rr_ratio
    $bpCheck = Test-BuyingPower $cfg $sizing.Shares $signal.Entry

    $posCount = Get-PositionCount $cfg
    $posOk    = ($posCount -lt [int]$cfg.max_positions)

    $errors   = @()
    if (-not $rrCheck.Valid)  { $errors += ("R:R {0} < min {1}" -f $rrCheck.RR, $cfg.min_rr_ratio) }
    if (-not $bpCheck.Sufficient) { $errors += ("Need `${0}, have `${1}" -f $bpCheck.Required, $bpCheck.BuyingPower) }
    if (-not $posOk)          { $errors += ("Max positions ({0}) reached" -f $cfg.max_positions) }
    if ($signal.Confidence -lt 65) { $errors += ("Confidence {0}% below 65%" -f $signal.Confidence) }

    return [pscustomobject]@{
        Valid        = ($errors.Count -eq 0)
        Errors       = $errors
        Equity       = [Math]::Round($equity, 2)
        Sizing       = $sizing
        RRCheck      = $rrCheck
        BPCheck      = $bpCheck
        PositionCount = $posCount
    }
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
