# opus_options_core.ps1
# Opus options sleeves (spec v1.2) -- PURE functions only.
#
# Nothing in this file calls the network, reads or writes files, or looks at
# the clock. Every rule in the spec that can be expressed as "inputs -> answer"
# lives here, so the Pester suite (tests/opus_options.Tests.ps1) can pin it
# without mocks. The orchestrator (opus_options.ps1) gathers inputs from the
# API and the data files and feeds them in.
#
# Conventions
# - Prices and constraint checks are POSITIVE magnitudes. The mleg sign
#   (MLEG_CREDIT_PRICE_SIGN = 'NEGATIVE': credit sent as "-x.xx") is applied
#   only when serializing an order (Format-OpusLimitPrice).
# - Dates are 'yyyy-MM-dd' strings. ConvertFrom-Json on PowerShell 7 turns
#   ISO strings into [datetime] while 5.1 leaves them as strings; every date
#   input goes through ConvertTo-OpusDate so both shapes work.
# - Threshold comparisons use OPUS_EPS. Spec examples sit exactly on their
#   boundaries (3.8 * 1.2 = 4.5600000000000005 in binary floating point), and
#   without the tolerance "4.56 -> hold" would fire.

. (Join-Path $PSScriptRoot "alpaca_indicators.ps1")

$script:OPUS_EPS = 1e-9

# ── Dates ─────────────────────────────────────────────────────────────────────

function ConvertTo-OpusDate($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [datetime]) { return $value.ToString('yyyy-MM-dd') }
    $s = [string]$value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s.Length -ge 10) { return $s.Substring(0, 10) }
    return $s
}

function ConvertTo-OpusDateObj($value) {
    $d = ConvertTo-OpusDate $value
    if ($null -eq $d) { return $null }
    return [datetime]::ParseExact($d, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Calendar days from $from to $to (to - from).
function Get-OpusDayDiff($from, $to) {
    $a = ConvertTo-OpusDateObj $from; $b = ConvertTo-OpusDateObj $to
    if ($null -eq $a -or $null -eq $b) { return $null }
    return [int]($b - $a).TotalDays
}

function Add-OpusDays($date, [int]$days) {
    return (ConvertTo-OpusDateObj $date).AddDays($days).ToString('yyyy-MM-dd')
}

# ── Trading calendar (list of 'yyyy-MM-dd' session dates, ascending) ─────────

# The Nth trading day strictly after $date.
function Add-OpusTradingDays($date, [int]$n, [string[]]$sessions) {
    $d = ConvertTo-OpusDate $date
    $after = @($sessions | Where-Object { $_ -gt $d } | Sort-Object)
    if ($after.Count -lt $n) { return $null }
    return $after[$n - 1]
}

# Completed sessions strictly after $from up to and including $to (entry day = 0).
function Get-OpusTradingDaysBetween($from, $to, [string[]]$sessions) {
    $a = ConvertTo-OpusDate $from; $b = ConvertTo-OpusDate $to
    return @($sessions | Where-Object { $_ -gt $a -and $_ -le $b }).Count
}

# ── Completed-bar rule (3.0.1) ────────────────────────────────────────────────

# Drops today's bar when today's session has not closed yet.
# $nowEt: [datetime] in ET. $todayCloseEt: [datetime] ET close of today, or
# $null when today is not a session.
function Get-OpusCompletedBars($bars, [datetime]$nowEt, $todayCloseEt) {
    $today = $nowEt.ToString('yyyy-MM-dd')
    $out = @()
    foreach ($b in @($bars)) {
        if ($null -eq $b) { continue }
        $d = ConvertTo-OpusDate $b.Date
        if ($d -gt $today) { continue }
        if ($d -eq $today -and ($null -eq $todayCloseEt -or $nowEt -lt $todayCloseEt)) { continue }
        $out += $b
    }
    return ,$out
}

# ── Indicators (3.0.3 / 3.0.4 reuse alpaca_indicators.ps1) ────────────────────

function Get-OpusIndicators($bars, $cfg) {
    $bars = @($bars)
    if ($bars.Count -lt 2) { return $null }
    [double[]]$closes = @($bars | ForEach-Object { [double]$_.Close })
    $ema20 = Get-EMA $closes ([int]$cfg.EMA_FAST)
    $ema50 = Get-EMA $closes ([int]$cfg.EMA_SLOW)
    $atr   = Get-ATR $bars ([int]$cfg.ATR_PERIOD)
    $t     = $bars[$bars.Count - 1]
    return [pscustomobject]@{
        Date = (ConvertTo-OpusDate $t.Date); Close = [double]$t.Close; Open = [double]$t.Open
        Ema20 = $ema20; Ema50 = $ema50; Atr = $atr; Bars = $bars.Count
    }
}

# ── Relative strength (3.0.5, ratio form, date-aligned) ──────────────────────

# Close of the series' latest bar dated <= $date. Returns @{ Close; Exact }.
function Get-OpusCloseAsOf($bars, [string]$date) {
    $best = $null
    foreach ($b in @($bars)) {
        $d = ConvertTo-OpusDate $b.Date
        if ($d -le $date) { if ($null -eq $best -or $d -gt (ConvertTo-OpusDate $best.Date)) { $best = $b } }
    }
    if ($null -eq $best) { return $null }
    return @{ Close = [double]$best.Close; Exact = ((ConvertTo-OpusDate $best.Date) -eq $date) }
}

# RS_N = (C_t / C_{t-N}) / (SPY_t / SPY_{t-N}) - 1, SPY aligned by date.
# Returns @{ Value; BarGap } or $null when there is not enough history.
function Get-OpusRsRatio($bars, $spyBars, [int]$n) {
    $bars = @($bars)
    if ($bars.Count -lt ($n + 1)) { return $null }
    $t  = $bars[$bars.Count - 1]; $t0 = $bars[$bars.Count - 1 - $n]
    $dt = ConvertTo-OpusDate $t.Date; $d0 = ConvertTo-OpusDate $t0.Date
    $s1 = Get-OpusCloseAsOf $spyBars $dt; $s0 = Get-OpusCloseAsOf $spyBars $d0
    if ($null -eq $s1 -or $null -eq $s0 -or [double]$t0.Close -le 0 -or $s0.Close -le 0) { return $null }
    $v = ([double]$t.Close / [double]$t0.Close) / ($s1.Close / $s0.Close) - 1
    return @{ Value = $v; BarGap = (-not ($s1.Exact -and $s0.Exact)) }
}

function Get-OpusRsScore($bars, $spyBars, $cfg) {
    $short = Get-OpusRsRatio $bars $spyBars ([int]$cfg.RS_LOOKBACK_SHORT)
    $long  = Get-OpusRsRatio $bars $spyBars ([int]$cfg.RS_LOOKBACK_LONG)
    if ($null -eq $short -or $null -eq $long) { return $null }
    return @{
        Rs63 = $short.Value; Rs126 = $long.Value
        Score = [double]$cfg.RS_WEIGHT_SHORT * $short.Value + [double]$cfg.RS_WEIGHT_LONG * $long.Value
        BarGap = ($short.BarGap -or $long.BarGap)
    }
}

# 3.0.6: $scores = hashtable symbol -> RS_SCORE. Sort desc, ties symbol asc,
# k = ceil(top_pct * m). Returns hashtable symbol -> @{ Rank; Pass; K; M }.
function Get-OpusRsPercentile([hashtable]$scores, [double]$topPct) {
    $m = $scores.Count
    $k = [int][Math]::Ceiling($topPct * $m - $script:OPUS_EPS)
    $ordered = @($scores.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key }; Descending = $false })
    $out = @{}
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $out[$ordered[$i].Key] = @{ Rank = $i + 1; Pass = (($i + 1) -le $k); K = $k; M = $m }
    }
    return $out
}

# ── Gates (3.0.7, 3.B trigger) ────────────────────────────────────────────────

function Test-OpusTrendGate([double]$close, $ema20, $ema50) {
    if ($null -eq $ema20 -or $null -eq $ema50) { return $false }
    return ($close -gt $ema20 -and $close -gt $ema50 -and $ema20 -gt $ema50)
}

# 0 < C_t - EMA20_t <= 1.0 * ATR_t AND C_t > O_t
function Test-OpusSleeveBTrigger([double]$close, [double]$open, [double]$ema20, [double]$atr, $cfg) {
    $gap = $close - $ema20
    if (-not ($gap -gt 0)) { return $false }
    if ($gap -gt [double]$cfg.B_ENTRY_MAX_ATR_ABOVE_EMA_FAST * $atr + $script:OPUS_EPS) { return $false }
    if ($cfg.B_REQUIRE_GREEN_CLOSE -and -not ($close -gt $open)) { return $false }
    return $true
}

# ── PULLBK trigger (3.A step 4) -- reproduces alpaca_swing_signals.ps1 ~L213 ──
#
# $bars: COMPLETED daily bars (ascending). $ema20/$ema50/$atr: values at t.
# $pNow: live stock price. $spyBars: COMPLETED SPY bars. $spyNow: live SPY.
#
# RS20_diff parity: the swing code calls Get-RelativeStrength on bars that
# INCLUDE today's unfinished bar, so "now" is that bar's close (the live
# price) and "then" is 20 bars before it = the 20th-from-last completed bar.
# It rounds to 2 decimals and does not align dates. Reproduced exactly.
function Get-OpusPullbackTrigger($bars, $ema20, $ema50, $atr, $pNow, $spyBars, $spyNow, $cfg) {
    $bars = @($bars); $spyBars = @($spyBars)
    $zonePct = [double]$cfg.A_PULLBACK_ZONE_PCT
    $look    = [int]$cfg.A_PULLBACK_LOOKBACK_DAYS
    $rsN     = [int]$cfg.A_RS_PULLBK_LOOKBACK

    $zone = if ($null -ne $ema20) { [double]$ema20 * (1 + $zonePct) } else { $null }
    $touched = $false; $touchDate = $null
    if ($null -ne $zone -and $bars.Count -ge 1) {
        $recent = @($bars | Select-Object -Last $look)
        foreach ($b in $recent) {
            if ([double]$b.Low -le $zone + $script:OPUS_EPS) { $touched = $true; $touchDate = ConvertTo-OpusDate $b.Date }
        }
    }
    $reclaimed = ($null -ne $ema20 -and $null -ne $pNow -and [double]$pNow -gt [double]$ema20)

    $trendQ = $null; $trendOk = $false
    if ($null -ne $ema20 -and $null -ne $ema50 -and $null -ne $atr -and [double]$atr -gt 0) {
        $trendQ  = ([double]$ema20 - [double]$ema50) / [double]$atr
        $trendOk = ($trendQ -ge [double]$cfg.A_MIN_TREND_QUALITY_ATR - $script:OPUS_EPS)
    }

    # Get-RelativeStrength($bars + partial, $spy + partial, 20):
    #   needs (count with partial) >= lookback + 1  ->  completed >= lookback
    $rs = 0.0
    if ($null -ne $pNow -and $null -ne $spyNow -and $bars.Count -ge $rsN -and $spyBars.Count -ge $rsN) {
        $symThen = [double]$bars[$bars.Count - $rsN].Close
        $spyThen = [double]$spyBars[$spyBars.Count - $rsN].Close
        if ($symThen -gt 0 -and $spyThen -gt 0) {
            $rs = [Math]::Round(((([double]$pNow / $symThen) - ([double]$spyNow / $spyThen)) * 100), 2)
        }
    }
    $rsOk = ($rs -ge [double]$cfg.A_MIN_RS_PULLBK - $script:OPUS_EPS)

    return [pscustomobject]@{
        Touched = $touched; TouchDate = $touchDate; Zone = $zone
        Reclaimed = $reclaimed; TrendQ = $trendQ; TrendOk = $trendOk
        Rs20Diff = $rs; RsOk = $rsOk
        Pullback = ($touched -and $reclaimed -and $trendOk -and $rsOk)
    }
}

# ── Earnings (3.0.8) ──────────────────────────────────────────────────────────

# Merge feed + override per symbol; override non-null fields win (2.3).
function Merge-OpusEarnings($feedEntry, $overrideEntry) {
    $next = $null; $last = $null
    if ($null -ne $feedEntry)     { $next = ConvertTo-OpusDate $feedEntry.next_earnings_date; $last = ConvertTo-OpusDate $feedEntry.last_earnings_date }
    if ($null -ne $overrideEntry) {
        $on = ConvertTo-OpusDate $overrideEntry.next_earnings_date; if ($null -ne $on) { $next = $on }
        $ol = ConvertTo-OpusDate $overrideEntry.last_earnings_date; if ($null -ne $ol) { $last = $ol }
    }
    return @{ Next = $next; Last = $last }
}

# Returns @{ Pass; Reason; Detail; ViaFallback; Next; Last }.
function Test-OpusEarningsGate($today, $next, $last, $cfg) {
    $today = ConvertTo-OpusDate $today
    $next  = ConvertTo-OpusDate $next
    $last  = ConvertTo-OpusDate $last
    if ($null -ne $next -and $next -lt $today) { $next = $null }   # stale = missing

    if ($null -ne $last) {
        $since = Get-OpusDayDiff $last $today
        if ($since -ge 0 -and $since -le [int]$cfg.EARNINGS_POST_BLACKOUT_DAYS) {
            return @{ Pass = $false; Reason = 'EARNINGS_BLACKOUT'; Detail = "last $last ($since d ago)"; ViaFallback = $false; Next = $next; Last = $last }
        }
    }
    if ($null -ne $next) {
        $to = Get-OpusDayDiff $today $next
        if ($to -ge [int]$cfg.EARNINGS_MIN_DAYS_AHEAD) {
            return @{ Pass = $true; Reason = $null; Detail = "next $next ($to d)"; ViaFallback = $false; Next = $next; Last = $last }
        }
        return @{ Pass = $false; Reason = 'EARNINGS_TOO_CLOSE'; Detail = "next $next ($to d)"; ViaFallback = $false; Next = $next; Last = $last }
    }
    if ($null -ne $last) {
        $since = Get-OpusDayDiff $last $today
        if ($since -ge 0 -and $since -le [int]$cfg.EARNINGS_MAX_DAYS_SINCE_LAST) {
            return @{ Pass = $true; Reason = $null; Detail = "next not listed; last $last ($since d ago, fallback)"; ViaFallback = $true; Next = $null; Last = $last }
        }
    }
    return @{ Pass = $false; Reason = 'EARNINGS_DATA_MISSING'; Detail = "next unknown; last $last"; ViaFallback = $false; Next = $null; Last = $last }
}

# ── Expiry selection (3.0.10, monthly-anchored) ───────────────────────────────

# Standard monthly for a month: third Friday, or the preceding Thursday when
# that Friday is not a session. $sessionSet: hashtable of session dates.
# $calendarFrom/$calendarTo bound where the calendar is known; outside them the
# Friday is assumed to be a session.
function Get-OpusMonthlyExpiration([int]$year, [int]$month, [hashtable]$sessionSet, $calendarFrom, $calendarTo) {
    $first = [datetime]::new($year, $month, 1)
    $offset = ([int][DayOfWeek]::Friday - [int]$first.DayOfWeek + 7) % 7
    $friday = $first.AddDays($offset + 14).ToString('yyyy-MM-dd')
    $known = ($null -ne $calendarFrom -and $null -ne $calendarTo -and $friday -ge $calendarFrom -and $friday -le $calendarTo)
    if ($known -and -not $sessionSet.ContainsKey($friday)) {
        return (ConvertTo-OpusDateObj $friday).AddDays(-1).ToString('yyyy-MM-dd')
    }
    return $friday
}

function Test-OpusMonthly([string]$expiration, [hashtable]$sessionSet, $calendarFrom, $calendarTo) {
    $d = ConvertTo-OpusDateObj $expiration
    return ($expiration -eq (Get-OpusMonthlyExpiration $d.Year $d.Month $sessionSet $calendarFrom $calendarTo))
}

# Returns @{ Expiries (ordered, each @{ Date; Dte }); Fallback }.
function Select-OpusExpiries([string[]]$expirations, $today, [int]$dteMin, [int]$dteMax, [int]$dteTarget, [int]$exitDte,
                             [hashtable]$sessionSet, $calendarFrom, $calendarTo) {
    $today = ConvertTo-OpusDate $today
    $monthlies = @()
    foreach ($e in (@($expirations) | Sort-Object -Unique)) {
        $e = ConvertTo-OpusDate $e
        if (Test-OpusMonthly $e $sessionSet $calendarFrom $calendarTo) {
            $monthlies += @{ Date = $e; Dte = (Get-OpusDayDiff $today $e) }
        }
    }
    # Order: |DTE - target| ascending, tie -> later expiry (larger DTE).
    $inWin = @($monthlies | Where-Object { $_.Dte -ge $dteMin -and $_.Dte -le $dteMax })
    if ($inWin.Count -gt 0) {
        $sorted = @($inWin | Sort-Object @{ Expression = { [Math]::Abs($_.Dte - $dteTarget) } }, @{ Expression = { $_.Dte }; Descending = $true })
        return @{ Expiries = $sorted; Fallback = $false }
    }
    $eligible = @($monthlies | Where-Object { $_.Dte -gt $exitDte })
    if ($eligible.Count -eq 0) { return @{ Expiries = @(); Fallback = $true } }
    $best = @($eligible | Sort-Object @{ Expression = { [Math]::Abs($_.Dte - $dteTarget) } }, @{ Expression = { $_.Dte }; Descending = $true })[0]
    return @{ Expiries = @($best); Fallback = $true }
}

# ── Legs, liquidity, selection (3.0.9, 3.A 6-7, 3.B 6-7) ──────────────────────
# Leg: @{ Occ; Type; Strike; Expiration; Oi; Bid; Ask; Delta; Iv }

function Get-OpusMid($leg) { return ([double]$leg.Bid + [double]$leg.Ask) / 2.0 }

function Test-OpusQuotable($leg, $cfg) {
    if ($null -eq $leg.Bid -or $null -eq $leg.Ask) { return $false }
    return ([double]$leg.Bid -ge [double]$cfg.MIN_LEG_BID - $script:OPUS_EPS -and [double]$leg.Ask -gt [double]$leg.Bid)
}

# Returns $null when liquid, else the failing reason.
function Get-OpusLegLiquidityFailure($leg, $cfg) {
    if (-not (Test-OpusQuotable $leg $cfg)) { return 'NOT_QUOTABLE' }
    if (-not ([double]$leg.Oi -gt [double]$cfg.MIN_OPEN_INTEREST)) { return 'LOW_OPEN_INTEREST' }
    $mid = Get-OpusMid $leg
    if ($mid -le 0) { return 'NOT_QUOTABLE' }
    if ((([double]$leg.Ask - [double]$leg.Bid) / $mid) -gt [double]$cfg.MAX_LEG_SPREAD_PCT_OF_MID + $script:OPUS_EPS) { return 'WIDE_SPREAD' }
    return $null
}

function Test-OpusLegLiquid($leg, $cfg) { return ($null -eq (Get-OpusLegLiquidityFailure $leg $cfg)) }

# Sleeve A, one expiry. $calls: legs of that expiry. Returns
# @{ Pair; Reason } where Pair = @{ Long; Short; Width; DebitMid; DebitNatural }.
# 3.A step 6.1: calls with 0.60 <= delta <= 0.70, by |delta - 0.65| (rounded to
# 9 dp so 0.61 and 0.69 tie as the spec intends), tie -> lower strike.
function Get-OpusSleeveALongCandidates($calls, $cfg) {
    return @(@($calls) | Where-Object { $null -ne $_ -and $null -ne $_.Delta -and
                [double]$_.Delta -ge [double]$cfg.A_LONG_DELTA_MIN - $script:OPUS_EPS -and [double]$_.Delta -le [double]$cfg.A_LONG_DELTA_MAX + $script:OPUS_EPS } |
             Sort-Object @{ Expression = { [Math]::Round([Math]::Abs([double]$_.Delta - [double]$cfg.A_LONG_DELTA_TARGET), 9) } }, @{ Expression = { [double]$_.Strike } })
}

# 3.A step 6.2: strikes in [spot*1.08, spot*1.10] by |K - spot*1.09|, tie -> higher strike.
function Get-OpusSleeveAShortCandidates($calls, [double]$spot, $cfg) {
    $lo = $spot * (1 + [double]$cfg.A_SHORT_OTM_MIN); $hi = $spot * (1 + [double]$cfg.A_SHORT_OTM_MAX); $tg = $spot * (1 + [double]$cfg.A_SHORT_OTM_TARGET)
    return @(@($calls) | Where-Object { $null -ne $_ -and $null -ne $_.Delta -and [double]$_.Strike -ge $lo - $script:OPUS_EPS -and [double]$_.Strike -le $hi + $script:OPUS_EPS } |
             Sort-Object @{ Expression = { [Math]::Round([Math]::Abs([double]$_.Strike - $tg), 9) } }, @{ Expression = { [double]$_.Strike }; Descending = $true })
}

# Sleeve A, one expiry. $calls: legs of that expiry. Returns
# @{ Pair; Reason } where Pair = @{ Long; Short; Width; DebitMid; DebitNatural }.
function Select-OpusSleeveAPair($calls, [double]$spot, $cfg) {
    $longs  = Get-OpusSleeveALongCandidates $calls $cfg
    $shorts = Get-OpusSleeveAShortCandidates $calls $spot $cfg
    $reason = 'NO_VALID_CONTRACTS'
    foreach ($L in $longs) {
        foreach ($S in $shorts) {
            if (-not ([double]$S.Strike -gt [double]$L.Strike)) { continue }
            $liq = Get-OpusLegLiquidityFailure $L $cfg; if (-not $liq) { $liq = Get-OpusLegLiquidityFailure $S $cfg }
            if ($liq) { $reason = 'ILLIQUID_LEG'; continue }
            $width = [double]$S.Strike - [double]$L.Strike
            $debit = (Get-OpusMid $L) - (Get-OpusMid $S)
            if (-not ($debit -gt 0) -or $debit -gt [double]$cfg.A_MAX_DEBIT_PCT_WIDTH * $width + $script:OPUS_EPS) { $reason = 'DEBIT_TOO_HIGH'; continue }
            return @{ Pair = @{ Long = $L; Short = $S; Width = $width; DebitMid = $debit; DebitNatural = ([double]$L.Ask - [double]$S.Bid) }; Reason = $null }
        }
    }
    return @{ Pair = $null; Reason = $reason }
}

# Sleeve B, one expiry. $puts: legs of that expiry.
function Select-OpusSleeveBPair($puts, [double]$ema50, $cfg) {
    $puts = @($puts | Where-Object { $null -ne $_ })
    $byStrike = @{}; foreach ($p in $puts) { $byStrike[[string]([Math]::Round([double]$p.Strike, 4))] = $p }
    $shorts = @($puts | Where-Object { $null -ne $_.Delta -and [Math]::Abs([double]$_.Delta) -ge [double]$cfg.B_SHORT_DELTA_MIN - $script:OPUS_EPS -and
                                        [Math]::Abs([double]$_.Delta) -le [double]$cfg.B_SHORT_DELTA_MAX + $script:OPUS_EPS -and
                                        (-not $cfg.B_SHORT_STRIKE_BELOW_EMA_SLOW -or [double]$_.Strike -lt $ema50) } |
                Sort-Object @{ Expression = { [Math]::Round([Math]::Abs([Math]::Abs([double]$_.Delta) - [double]$cfg.B_SHORT_DELTA_TARGET), 9) } }, @{ Expression = { [double]$_.Strike } })
    $width = [double]$cfg.B_WIDTH
    $reason = 'NO_VALID_CONTRACTS'
    foreach ($S in $shorts) {
        $key = [string]([Math]::Round([double]$S.Strike - $width, 4))
        if (-not $byStrike.ContainsKey($key)) { $reason = 'NO_LONG_LEG'; continue }
        $L = $byStrike[$key]
        if ($null -eq $L.Delta) { $reason = 'NO_DELTA'; continue }
        $liq = Get-OpusLegLiquidityFailure $S $cfg; if (-not $liq) { $liq = Get-OpusLegLiquidityFailure $L $cfg }
        if ($liq) { $reason = 'ILLIQUID_LEG'; continue }
        # round(mid_short - mid_long, 2) as the spec computes it (2.675 - 1.00 = 1.68):
        # plain [Math]::Round gives 1.67 because 1.675 is 1.67499... in binary.
        $credit = Get-OpusRoundToTick ((Get-OpusMid $S) - (Get-OpusMid $L)) 0.01
        if ($credit -lt $width * [double]$cfg.B_MIN_CREDIT_PCT_WIDTH - $script:OPUS_EPS) { $reason = 'CREDIT_TOO_LOW'; continue }
        return @{ Pair = @{ Short = $S; Long = $L; Width = $width; CreditMid = $credit; CreditNatural = ([double]$S.Bid - [double]$L.Ask) }; Reason = $null }
    }
    return @{ Pair = $null; Reason = $reason }
}

# ── Sizing (3.A 8, 3.B 8) and P5/P6 ───────────────────────────────────────────

function Get-OpusSizingA([double]$debitMid, [double]$equity, [double]$regimeMult, $cfg) {
    $cost1 = $debitMid * [double]$cfg.MULTIPLIER
    $single = $equity * [double]$cfg.A_MAX_SINGLE_CONTRACT_PCT
    $target = $equity * [double]$cfg.A_RISK_PCT * $regimeMult
    if ($cost1 -gt $single + $script:OPUS_EPS) {
        return @{ Ok = $false; Reason = 'SINGLE_CONTRACT_TOO_LARGE'; Cost1 = $cost1; SingleCap = $single; RiskTarget = $target; Contracts = 0 }
    }
    $n = [Math]::Max(1, [int][Math]::Floor($target / $cost1 + $script:OPUS_EPS))
    return @{ Ok = $true; Reason = $null; Cost1 = $cost1; SingleCap = $single; RiskTarget = $target; Contracts = $n }
}

function Get-OpusSizingB([double]$creditMid, [double]$width, [double]$equity, [double]$regimeMult, $cfg) {
    $ml1 = ($width - $creditMid) * [double]$cfg.MULTIPLIER
    $hard = $equity * [double]$cfg.B_MAX_LOSS_PCT
    $target = $equity * [double]$cfg.B_RISK_PCT * $regimeMult
    if ($ml1 -gt $hard + $script:OPUS_EPS) {
        return @{ Ok = $false; Reason = 'MAXLOSS_TOO_LARGE'; MaxLoss1 = $ml1; HardCap = $hard; RiskTarget = $target; Contracts = 0 }
    }
    $n = [Math]::Max(1, [int][Math]::Floor($target / $ml1 + $script:OPUS_EPS))
    return @{ Ok = $true; Reason = $null; MaxLoss1 = $ml1; HardCap = $hard; RiskTarget = $target; Contracts = $n }
}

# Decrement contracts until P5 (total open risk) and P6 (underlying exposure) pass.
function Resolve-OpusRiskCaps([int]$contracts, [double]$unitRisk, [double]$unitExposure,
                              [double]$openRiskTotal, [double]$symbolExposure, [double]$equity, $cfg) {
    $riskCap = $equity * [double]$cfg.TOTAL_OPEN_RISK_CAP_PCT
    $expCap  = $equity * [double]$cfg.MAX_UNDERLYING_EXPOSURE_PCT
    $reason = $null
    while ($contracts -gt 0) {
        $okRisk = ($openRiskTotal + $contracts * $unitRisk -le $riskCap + $script:OPUS_EPS)
        $okExp  = ($symbolExposure + $contracts * $unitExposure -le $expCap + $script:OPUS_EPS)
        if ($okRisk -and $okExp) { return @{ Contracts = $contracts; Reason = $null } }
        $reason = if (-not $okRisk) { 'RISK_CAP' } else { 'UNDERLYING_CAP' }
        $contracts--
    }
    return @{ Contracts = 0; Reason = $reason }
}

# ── Sleeve priority (5.3) ─────────────────────────────────────────────────────

function Get-OpusSleeveOrder([double]$openRiskA, [double]$openRiskB, [double]$equity, $cfg) {
    $cap = $equity * [double]$cfg.TOTAL_OPEN_RISK_CAP_PCT
    $uA = $openRiskA / ([double]$cfg.A_RISK_SHARE * $cap)
    $uB = $openRiskB / ([double]$cfg.B_RISK_SHARE * $cap)
    if ($uB -lt $uA - $script:OPUS_EPS) { return @{ First = 'B'; UA = $uA; UB = $uB } }
    return @{ First = 'A'; UA = $uA; UB = $uB }
}

# ── Guards (5.2) ──────────────────────────────────────────────────────────────

# Portfolio-level: P1-P4, P11. Returns reason or $null.
function Get-OpusPortfolioBlock($state, [string]$today, $ctx) {
    if ($state.strategy_halted -or $state.manual_review_required) { return 'HALTED' }
    if ((ConvertTo-OpusDate $state.entries_halted_date) -eq $today) { return 'DAILY_LOSS_HALT' }
    if ([int]$ctx.LossesToday -ge [int]$ctx.Cfg.MAX_LOSSES_PER_DAY) { return 'DAILY_LOSS_COUNT' }
    $pause = ConvertTo-OpusDate $state.pause_until
    if ($null -ne $pause -and $today -le $pause) { return 'CONSEC_LOSS_PAUSE' }
    if ($ctx.LevelInsufficient) { return 'LEVEL_INSUFFICIENT' }
    if ($ctx.DataStale) { return 'DATA_STALE' }
    if ($ctx.RegimeUnavailable) { return 'REGIME_UNAVAILABLE' }
    return $null
}

# Symbol-level: P7 (one per underlying + other strategies' stock), P8, P9, P10.
function Get-OpusSymbolBlock([string]$symbol, [string]$today, $ctx) {
    if ($ctx.OpusUnderlyings.ContainsKey($symbol)) { return 'UNDERLYING_BUSY' }
    if ($ctx.Cfg.EXCLUDE_UNDERLYINGS_HELD_BY_OTHER_STRATEGIES -and $ctx.StockHeld.ContainsKey($symbol)) { return 'UNDERLYING_BUSY' }
    if ([int]$ctx.EntriesToday -ge [int]$ctx.Cfg.MAX_NEW_ENTRIES_PER_DAY) { return 'DAILY_ENTRY_CAP' }
    if ($ctx.Cooldown.ContainsKey($symbol) -and $today -le $ctx.Cooldown[$symbol]) { return 'COOLDOWN' }
    if ($ctx.DdMode -and [int]$ctx.OpenPlusWorking -ge [int]$ctx.Cfg.DD_MAX_OPEN_POSITIONS) { return 'DD_POSITION_LIMIT' }
    return $null
}

# P10 state transition. Returns @{ DdMode; HwmAtTrigger; Drawdown }.
function Update-OpusDrawdownMode([double]$equity, [double]$hwm, [bool]$ddMode, $hwmAtTrigger, $cfg) {
    $dd = if ($hwm -gt 0) { ($hwm - $equity) / $hwm } else { 0.0 }
    if ($ddMode) {
        if ($null -ne $hwmAtTrigger -and $equity -gt [double]$hwmAtTrigger + $script:OPUS_EPS) { return @{ DdMode = $false; HwmAtTrigger = $null; Drawdown = $dd } }
        return @{ DdMode = $true; HwmAtTrigger = $hwmAtTrigger; Drawdown = $dd }
    }
    if ($dd -ge [double]$cfg.DD_THRESHOLD_PCT - $script:OPUS_EPS) { return @{ DdMode = $true; HwmAtTrigger = $hwm; Drawdown = $dd } }
    return @{ DdMode = $false; HwmAtTrigger = $null; Drawdown = $dd }
}

# P2: halt when equity <= day_start * (1 - 3%).
function Test-OpusDailyLossHalt([double]$equity, [double]$dayStartEquity, $cfg) {
    return ($equity -le $dayStartEquity * (1 - [double]$cfg.DAILY_LOSS_HALT_PCT) + $script:OPUS_EPS)
}

# Entry evaluation timing (8 step 12): 'EVAL' once per day inside
# [close-30m, close-5m); 'MISSED' when the first scan of the day lands in the
# 10 minutes after the window; else 'NONE'.
function Get-OpusEntryEvalDecision([datetime]$et, [datetime]$winStart, [datetime]$winEnd, $lastEvalDate, [string]$today) {
    if ((ConvertTo-OpusDate $lastEvalDate) -eq $today) { return 'NONE' }
    if ($et -ge $winStart -and $et -lt $winEnd) { return 'EVAL' }
    if ($et -ge $winEnd -and $et -lt $winEnd.AddMinutes(10)) { return 'MISSED' }
    return 'NONE'
}

# ── Pricing and orders (6.2, 6.3) ─────────────────────────────────────────────

function Get-OpusRoundToTick([double]$x, [double]$tick) {
    return [Math]::Round([Math]::Round($x / $tick, 6), 0, [MidpointRounding]::AwayFromZero) * $tick
}

# Attempt k price as a positive magnitude. $kind: 'debit' | 'credit'.
function Get-OpusRepricePrice([double]$mid, [double]$natural, [string]$kind, [int]$k, $cfg) {
    $fr = @($cfg.REPRICE_FRACTIONS); $f = [double]$fr[[Math]::Min($k, $fr.Count - 1)]
    $p = if ($kind -eq 'debit') { $mid + $f * ($natural - $mid) } else { $mid - $f * ($mid - $natural) }
    return Get-OpusRoundToTick $p ([double]$cfg.PRICE_TICK)
}

# Serialize an mleg limit: debit positive, credit negative (MLEG_CREDIT_PRICE_SIGN).
function Format-OpusLimitPrice([double]$magnitude, [string]$kind, $cfg) {
    $s = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2}', [Math]::Abs($magnitude))
    if ($kind -eq 'credit') {
        if ($cfg.MLEG_CREDIT_PRICE_SIGN -ne 'NEGATIVE') { throw "MLEG_CREDIT_PRICE_SIGN must be NEGATIVE" }
        return '-' + $s
    }
    return $s
}

function New-OpusRand4 { return -join ((1..4) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }

function New-OpusClientOrderId([string]$prefix, [string]$symbol, [string]$dateYmd, [string]$action, [int]$attempt, [string]$rand4) {
    if (-not $rand4) { $rand4 = New-OpusRand4 }
    return ('{0}-{1}-{2}-{3}-{4}-{5}' -f $prefix, $symbol.ToUpper(), $dateYmd, $action, $attempt, $rand4)
}

function New-OpusTradeId([string]$prefix, [string]$symbol, [string]$dateYmd, [string]$rand4) {
    if (-not $rand4) { $rand4 = New-OpusRand4 }
    return ('{0}-{1}-{2}-{3}' -f $prefix, $symbol.ToUpper(), $dateYmd, $rand4)
}

# Order kind for each (sleeve, action): A open = debit, A close = credit,
# B open = credit, B close = debit.
function Get-OpusOrderKind([string]$sleeve, [string]$action) {
    if ($sleeve -eq 'A') { if ($action -eq 'open') { return 'debit' } else { return 'credit' } }
    if ($action -eq 'open') { return 'credit' } else { return 'debit' }
}

# mleg payload (6.2 / 4.C). $legs: @{ Long = occ; Short = occ }.
function New-OpusMlegPayload([string]$sleeve, [string]$action, [hashtable]$legs, [int]$qty, [double]$magnitude, [string]$clientOrderId, $cfg) {
    $kind = Get-OpusOrderKind $sleeve $action
    if ($sleeve -eq 'A') {
        $legArr = if ($action -eq 'open') {
            @(@{ symbol = $legs.Long;  ratio_qty = '1'; side = 'buy';  position_intent = 'buy_to_open' },
              @{ symbol = $legs.Short; ratio_qty = '1'; side = 'sell'; position_intent = 'sell_to_open' })
        } else {
            @(@{ symbol = $legs.Long;  ratio_qty = '1'; side = 'sell'; position_intent = 'sell_to_close' },
              @{ symbol = $legs.Short; ratio_qty = '1'; side = 'buy';  position_intent = 'buy_to_close' })
        }
    } else {
        $legArr = if ($action -eq 'open') {
            @(@{ symbol = $legs.Short; ratio_qty = '1'; side = 'sell'; position_intent = 'sell_to_open' },
              @{ symbol = $legs.Long;  ratio_qty = '1'; side = 'buy';  position_intent = 'buy_to_open' })
        } else {
            @(@{ symbol = $legs.Short; ratio_qty = '1'; side = 'buy';  position_intent = 'buy_to_close' },
              @{ symbol = $legs.Long;  ratio_qty = '1'; side = 'sell'; position_intent = 'sell_to_close' })
        }
    }
    return [ordered]@{
        order_class = 'mleg'; qty = [string]$qty; type = 'limit'
        limit_price = (Format-OpusLimitPrice $magnitude $kind $cfg)
        time_in_force = [string]$cfg.ORDER_TIF; client_order_id = $clientOrderId
        legs = $legArr
    }
}

# Single-leg limit (E0, SHORT_LEG_ONLY_CLOSE): ordinary positive price.
function New-OpusSingleLegPayload([string]$occ, [string]$side, [string]$intent, [int]$qty, [double]$price, [string]$clientOrderId, $cfg) {
    return [ordered]@{
        symbol = $occ; qty = [string]$qty; side = $side; type = 'limit'; position_intent = $intent
        limit_price = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2}', [Math]::Abs($price))
        time_in_force = [string]$cfg.ORDER_TIF; client_order_id = $clientOrderId
    }
}

# Spread mid/natural for a position's legs. $q: hashtable occ -> leg quote.
# A: value = mid_long - mid_short; B: cost_to_close = mid_short - mid_long.
# Close natural: A close is a credit (bid_long - ask_short); B close is a debit (ask_short - bid_long).
function Get-OpusSpreadQuote([string]$sleeve, $longLeg, $shortLeg, $cfg) {
    if ($null -eq $longLeg -or $null -eq $shortLeg) { return $null }
    if (-not (Test-OpusQuotable $longLeg $cfg) -or -not (Test-OpusQuotable $shortLeg $cfg)) { return $null }
    if ($sleeve -eq 'A') {
        return @{ Mid = (Get-OpusMid $longLeg) - (Get-OpusMid $shortLeg); CloseNatural = [double]$longLeg.Bid - [double]$shortLeg.Ask
                  OpenNatural = [double]$longLeg.Ask - [double]$shortLeg.Bid }
    }
    return @{ Mid = (Get-OpusMid $shortLeg) - (Get-OpusMid $longLeg); CloseNatural = [double]$shortLeg.Ask - [double]$longLeg.Bid
              OpenNatural = [double]$shortLeg.Bid - [double]$longLeg.Ask }
}

# DRY_RUN simulated fill (8 step 15): debit fills if limit >= natural; credit if limit <= natural.
function Test-OpusSimulatedFill([double]$limitMagnitude, [double]$naturalMagnitude, [string]$kind) {
    if ($kind -eq 'debit') { return ($limitMagnitude -ge $naturalMagnitude - $script:OPUS_EPS) }
    return ($limitMagnitude -le $naturalMagnitude + $script:OPUS_EPS)
}

# Entry price constraint on reprice (6.3).
function Test-OpusEntryPriceOk([string]$sleeve, [double]$price, [double]$width, [double]$equity, $cfg) {
    if ($sleeve -eq 'A') {
        return ($price -le [double]$cfg.A_MAX_DEBIT_PCT_WIDTH * $width + $script:OPUS_EPS -and
                $price * [double]$cfg.MULTIPLIER -le $equity * [double]$cfg.A_MAX_SINGLE_CONTRACT_PCT + $script:OPUS_EPS)
    }
    return ($price -ge $width * [double]$cfg.B_MIN_CREDIT_PCT_WIDTH - $script:OPUS_EPS)
}

# ── Exits (Section 4) ─────────────────────────────────────────────────────────
#
# $pos: open trade record (sleeve, entry price, legs, flags). $x context:
#   Today, NextEarnings, Dte, Quote (Get-OpusSpreadQuote or $null), PNow,
#   ShortMid, StopHits (consecutive scans incl. this one where the stop held),
#   LastBar @{ Date; Close; Ema20; Ema50 } (completed, after entry fill date) or $null,
#   TradingDaysHeld, ExDivTomorrow, DividendPerShare.
# Returns @{ Rule; Reason; Type; Qty } or $null. The first rule that fires wins.
function Get-OpusExitDecision($pos, $x, $cfg) {
    $eps = $script:OPUS_EPS
    $qtyOpen = [int]$pos.qty_open
    $earn = $null
    $nx = ConvertTo-OpusDate $x.NextEarnings
    if ($null -ne $nx) { $earn = Get-OpusDayDiff $x.Today $nx }

    if ($pos.sleeve -like 'A*') {
        $debit = [double]$pos.entry_fill_price
        $exitDays = [int]$cfg.EARNINGS_EXIT_DAYS
        if ($null -ne $earn -and $earn -ge 0 -and $earn -le $exitDays) { return @{ Rule = 'A1'; Reason = 'EARNINGS'; Type = 'FORCED'; Qty = $qtyOpen } }
        if ($null -ne $x.Dte -and [int]$x.Dte -le [int]$cfg.A_EXIT_DTE) { return @{ Rule = 'A2'; Reason = 'DTE'; Type = 'FORCED'; Qty = $qtyOpen } }
        $v = if ($null -ne $x.Quote) { [double]$x.Quote.Mid } else { $null }
        if ($null -ne $v -and $v -le $debit * (1 - [double]$cfg.A_STOP_PCT) + $eps -and [int]$x.StopHits -ge [int]$cfg.STOP_CONFIRM_SCANS) {
            return @{ Rule = 'A3'; Reason = 'STOP'; Type = 'FORCED'; Qty = $qtyOpen }
        }
        if ($null -ne $x.LastBar -and $null -ne $x.LastBar.Ema50 -and [double]$x.LastBar.Close -lt [double]$x.LastBar.Ema50) {
            return @{ Rule = 'A4'; Reason = 'EMA50_BREAK'; Type = 'FORCED'; Qty = $qtyOpen }
        }
        if ($x.ExDivTomorrow -and $null -ne $x.PNow -and $null -ne $x.ShortMid -and $null -ne $x.DividendPerShare) {
            $kS = [double]$pos.short_strike
            if ([double]$x.PNow -gt $kS) {
                $extr = [double]$x.ShortMid - ([double]$x.PNow - $kS)
                if ($extr -lt [double]$x.DividendPerShare) { return @{ Rule = 'A5'; Reason = 'EXDIV_RISK'; Type = 'FORCED'; Qty = $qtyOpen } }
            }
        }
        if (-not $pos.partial_taken -and $null -ne $v -and $v -ge $debit * (1 + [double]$cfg.A_TP_PCT) - $eps) {
            $q = if ($qtyOpen -eq 1) { 1 } else { [int][Math]::Ceiling($qtyOpen / 2.0) }
            return @{ Rule = 'A6'; Reason = 'TP_PARTIAL'; Type = 'DISCRETIONARY'; Qty = $q }
        }
        if ($pos.partial_taken -and $null -ne $x.LastBar -and $null -ne $x.LastBar.Ema20 -and
            (ConvertTo-OpusDate $x.LastBar.Date) -gt (ConvertTo-OpusDate $pos.partial_fill_date) -and [double]$x.LastBar.Close -lt [double]$x.LastBar.Ema20) {
            return @{ Rule = 'A7'; Reason = 'EMA20_TRAIL'; Type = 'FORCED'; Qty = $qtyOpen }
        }
        if ($null -ne $v -and [int]$x.TradingDaysHeld -ge [int]$cfg.A_TIME_STOP_DAYS -and $v -lt $debit * (1 + [double]$cfg.A_TIME_STOP_MIN_GAIN) - $eps) {
            return @{ Rule = 'A8'; Reason = 'TIME_STOP'; Type = 'DISCRETIONARY'; Qty = $qtyOpen }
        }
        return $null
    }

    # Sleeve B ($pos.sleeve 'B_PUT_CREDIT'; journal values per spec 7.1)
    $credit = [double]$pos.entry_fill_price
    if ($null -ne $earn -and $earn -ge 0 -and $earn -le [int]$cfg.EARNINGS_EXIT_DAYS) { return @{ Rule = 'B1'; Reason = 'EARNINGS'; Type = 'FORCED'; Qty = $qtyOpen } }
    if ($null -ne $x.Dte -and [int]$x.Dte -le [int]$cfg.B_EXIT_DTE) { return @{ Rule = 'B2'; Reason = 'DTE'; Type = 'FORCED'; Qty = $qtyOpen } }
    $c = if ($null -ne $x.Quote) { [double]$x.Quote.Mid } else { $null }
    if ($null -ne $c -and $c -ge $credit * [double]$cfg.B_STOP_MULT - $eps -and [int]$x.StopHits -ge [int]$cfg.STOP_CONFIRM_SCANS) {
        return @{ Rule = 'B3'; Reason = 'STOP'; Type = 'FORCED'; Qty = $qtyOpen }
    }
    $kS = [double]$pos.short_strike
    if ($null -ne $x.LastBar -and [double]$x.LastBar.Close -lt $kS) { return @{ Rule = 'B4'; Reason = 'SHORT_STRIKE_BREAK'; Type = 'FORCED'; Qty = $qtyOpen } }
    if ($null -ne $x.Quote -and $null -ne $x.PNow -and $null -ne $x.ShortMid -and [double]$x.PNow -lt $kS) {
        $extr = [double]$x.ShortMid - ($kS - [double]$x.PNow)
        if ($extr -lt 0.10) { return @{ Rule = 'B5'; Reason = 'DEEP_ITM'; Type = 'FORCED'; Qty = $qtyOpen } }
    }
    if ($null -ne $c -and $c -le $credit * (1 - [double]$cfg.B_TP_PCT) + $eps) { return @{ Rule = 'B6'; Reason = 'TP'; Type = 'DISCRETIONARY'; Qty = $qtyOpen } }
    return $null
}

# Whether this scan's quote satisfies the quote stop (feeds the 2-scan confirm counter).
function Test-OpusStopCondition($pos, $quote, $cfg) {
    if ($null -eq $quote) { return $false }
    if ($pos.sleeve -like 'A*') { return ([double]$quote.Mid -le [double]$pos.entry_fill_price * (1 - [double]$cfg.A_STOP_PCT) + $script:OPUS_EPS) }
    return ([double]$quote.Mid -ge [double]$pos.entry_fill_price * [double]$cfg.B_STOP_MULT - $script:OPUS_EPS)
}

# ── Metrics (8.1) ─────────────────────────────────────────────────────────────

function Get-OpusMetrics($closedTrades, $cfg) {
    $t = @($closedTrades | Where-Object { $null -ne $_ -and -not $_.dry_run })
    $gp = 0.0; $gl = 0.0
    foreach ($x in $t) { $p = [double]$x.net_pnl; if ($p -gt 0) { $gp += $p } elseif ($p -lt 0) { $gl += $p } }
    $pf  = if ($gl -lt 0) { $gp / [Math]::Abs($gl) } else { $null }
    $gph = $gp * (1 - [double]$cfg.PAPER_HAIRCUT_PCT)
    $pfh = if ($gl -lt 0) { $gph / [Math]::Abs($gl) } else { $null }
    $wr = @{}
    foreach ($s in 'A', 'B') {
        $ts = @($t | Where-Object { $_.sleeve -like "$s*" })
        $wr[$s] = if ($ts.Count -gt 0) { @($ts | Where-Object { [double]$_.net_pnl -gt 0 }).Count / $ts.Count } else { $null }
    }
    return @{ Trades = $t.Count; GP = $gp; GL = $gl; PF = $pf; PFH = $pfh; NetH = $gph + $gl; WinRateA = $wr['A']; WinRateB = $wr['B'] }
}

function Test-OpusKill($metrics, $cfg) {
    return ($metrics.Trades -ge [int]$cfg.KILL_MIN_TRADES -and $null -ne $metrics.PF -and $metrics.PF -lt [double]$cfg.KILL_PF_BELOW)
}

function Test-OpusGoLiveGates($metrics, [double]$maxDrawdown, $cfg) {
    $pf = if ($cfg.GATES_USE_HAIRCUT) { $metrics.PFH } else { $metrics.PF }
    return ($metrics.Trades -ge [int]$cfg.GOLIVE_MIN_TRADES -and $null -ne $pf -and $pf -ge [double]$cfg.GOLIVE_MIN_PF -and
            $null -ne $metrics.WinRateA -and $metrics.WinRateA -ge [double]$cfg.GOLIVE_MIN_WINRATE_A -and
            $null -ne $metrics.WinRateB -and $metrics.WinRateB -ge [double]$cfg.GOLIVE_MIN_WINRATE_B -and
            $maxDrawdown -lt [double]$cfg.GOLIVE_MAX_DRAWDOWN)
}

# ── Config validation (2.1, 2.2) ──────────────────────────────────────────────

$script:OPUS_KEY_TYPES = [ordered]@{
    OPTIONS_ENABLED = 'bool'; DRY_RUN = 'bool'; ENTRIES_ENABLED = 'bool'; STRATEGY_VERSION = 'string'
    STARTING_CAPITAL = 'number'; EQUITY_MODE = 'string'; MULTIPLIER = 'number'
    STOCK_DATA_FEED = 'string'; OPTIONS_DATA_FEED = 'string'; BAR_ADJUSTMENT = 'string'
    BAR_LOOKBACK_CALENDAR_DAYS = 'number'; MIN_BARS_REQUIRED = 'number'
    UNIVERSE_FILE = 'string'; EARNINGS_FILE = 'string'; EARNINGS_OVERRIDE_FILE = 'string'; STATE_FILE = 'string'; IV_HISTORY_FILE = 'string'
    UNIVERSE_STALE_WARN_DAYS = 'number'; UNIVERSE_STALE_BLOCK_DAYS = 'number'; EARNINGS_STALE_BLOCK_DAYS = 'number'
    EARNINGS_LOOKAHEAD_DAYS = 'number'; EARNINGS_LOOKBACK_DAYS = 'number'; EARNINGS_REFRESH = 'string'
    EARNINGS_BACKFILL_ENABLED = 'bool'; EARNINGS_BACKFILL_DAYS = 'number'
    MIN_ROIC = 'number'; MIN_REV_GROWTH = 'number'; REQUIRE_FCF_POSITIVE = 'bool'
    EMA_FAST = 'number'; EMA_SLOW = 'number'; ATR_PERIOD = 'number'
    RS_LOOKBACK_SHORT = 'number'; RS_LOOKBACK_LONG = 'number'; RS_WEIGHT_SHORT = 'number'; RS_WEIGHT_LONG = 'number'; RS_TOP_PCT = 'number'; BENCHMARK = 'string'
    REQUIRE_CLOSE_ABOVE_EMA_FAST = 'bool'; REQUIRE_CLOSE_ABOVE_EMA_SLOW = 'bool'; REQUIRE_EMA_FAST_ABOVE_SLOW = 'bool'
    EXPIRY_TYPE = 'string'
    MIN_OPEN_INTEREST = 'number'; MAX_LEG_SPREAD_PCT_OF_MID = 'number'; MIN_LEG_BID = 'number'
    EARNINGS_MIN_DAYS_AHEAD = 'number'; EARNINGS_POST_BLACKOUT_DAYS = 'number'; EARNINGS_EXIT_DAYS = 'number'; EARNINGS_MAX_DAYS_SINCE_LAST = 'number'
    A_ENABLED = 'bool'; A_PREFIX = 'string'; A_RISK_SHARE = 'number'; A_PULLBACK_LOOKBACK_DAYS = 'number'; A_PULLBACK_ZONE_PCT = 'number'
    A_MIN_TREND_QUALITY_ATR = 'number'; A_MIN_RS_PULLBK = 'number'; A_RS_PULLBK_LOOKBACK = 'number'
    A_DTE_MIN = 'number'; A_DTE_MAX = 'number'; A_DTE_TARGET = 'number'
    A_LONG_DELTA_MIN = 'number'; A_LONG_DELTA_MAX = 'number'; A_LONG_DELTA_TARGET = 'number'
    A_SHORT_OTM_MIN = 'number'; A_SHORT_OTM_MAX = 'number'; A_SHORT_OTM_TARGET = 'number'
    A_MAX_DEBIT_PCT_WIDTH = 'number'; A_RISK_PCT = 'number'; A_MAX_SINGLE_CONTRACT_PCT = 'number'; A_MAX_OPEN = 'number'
    A_TP_PCT = 'number'; A_STOP_PCT = 'number'; A_TIME_STOP_DAYS = 'number'; A_TIME_STOP_MIN_GAIN = 'number'; A_EXIT_DTE = 'number'
    A_REGIME_MULT = 'hashtable'
    B_ENABLED = 'bool'; B_PREFIX = 'string'; B_RISK_SHARE = 'number'; B_ENTRY_MAX_ATR_ABOVE_EMA_FAST = 'number'; B_REQUIRE_GREEN_CLOSE = 'bool'
    B_DTE_MIN = 'number'; B_DTE_MAX = 'number'; B_DTE_TARGET = 'number'
    B_SHORT_DELTA_MIN = 'number'; B_SHORT_DELTA_MAX = 'number'; B_SHORT_DELTA_TARGET = 'number'; B_SHORT_STRIKE_BELOW_EMA_SLOW = 'bool'
    B_WIDTH = 'number'; B_MIN_CREDIT_PCT_WIDTH = 'number'; B_RISK_PCT = 'number'; B_MAX_LOSS_PCT = 'number'; B_MAX_OPEN = 'number'
    B_TP_PCT = 'number'; B_STOP_MULT = 'number'; B_EXIT_DTE = 'number'; B_REGIME_MULT = 'hashtable'
    TOTAL_OPEN_RISK_CAP_PCT = 'number'; MAX_UNDERLYING_EXPOSURE_PCT = 'number'; ONE_POSITION_PER_UNDERLYING = 'bool'
    EXCLUDE_UNDERLYINGS_HELD_BY_OTHER_STRATEGIES = 'bool'; MAX_NEW_ENTRIES_PER_DAY = 'number'; SYMBOL_COOLDOWN_AFTER_LOSS_DAYS = 'number'
    DD_THRESHOLD_PCT = 'number'; DD_MAX_OPEN_POSITIONS = 'number'; CONSEC_LOSS_LIMIT = 'number'; CONSEC_LOSS_PAUSE_DAYS = 'number'
    DAILY_LOSS_HALT_PCT = 'number'; MAX_LOSSES_PER_DAY = 'number'
    ENTRY_WINDOW_START_MIN_BEFORE_CLOSE = 'number'; ENTRY_WINDOW_END_MIN_BEFORE_CLOSE = 'number'
    EXIT_EARLIEST_MIN_AFTER_OPEN = 'number'; EXIT_LATEST_MIN_BEFORE_CLOSE = 'number'
    ORDER_TIF = 'string'; ENTRY_MAX_REPRICES = 'number'; EXIT_MAX_REPRICES_DISCRETIONARY = 'number'; EXIT_FORCED_GO_NATURAL_AFTER = 'number'
    REPRICE_FRACTIONS = 'array'; PRICE_TICK = 'number'; STOP_CONFIRM_SCANS = 'number'; MLEG_CREDIT_PRICE_SIGN = 'string'
    REVIEW_AFTER_TRADES = 'number'; KILL_MIN_TRADES = 'number'; KILL_PF_BELOW = 'number'
    GOLIVE_MIN_TRADES = 'number'; GOLIVE_MIN_PF = 'number'; GOLIVE_MIN_WINRATE_A = 'number'; GOLIVE_MIN_WINRATE_B = 'number'
    GOLIVE_MAX_DRAWDOWN = 'number'; PAPER_HAIRCUT_PCT = 'number'; GATES_USE_HAIRCUT = 'bool'
}

function Test-OpusNumber($v) { return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single]) }

# Returns @{ Valid; Errors }.
function Test-OpusConfig($cfg) {
    $err = @()
    if ($null -eq $cfg) { return @{ Valid = $false; Errors = @('config is null') } }
    foreach ($k in $script:OPUS_KEY_TYPES.Keys) {
        if (-not $cfg.ContainsKey($k)) { $err += "missing key $k"; continue }
        $v = $cfg[$k]; $t = $script:OPUS_KEY_TYPES[$k]
        $ok = switch ($t) {
            'bool'      { $v -is [bool] }
            'string'    { $v -is [string] }
            'number'    { Test-OpusNumber $v }
            'hashtable' { $v -is [hashtable] }
            'array'     { $v -is [array] }
        }
        if (-not $ok) { $err += "key $k must be $t" }
    }
    if ($err.Count -gt 0) { return @{ Valid = $false; Errors = $err } }

    $checks = [ordered]@{
        'A DTE min<=target<=max' = ($cfg.A_DTE_MIN -le $cfg.A_DTE_TARGET -and $cfg.A_DTE_TARGET -le $cfg.A_DTE_MAX)
        'B DTE min<=target<=max' = ($cfg.B_DTE_MIN -le $cfg.B_DTE_TARGET -and $cfg.B_DTE_TARGET -le $cfg.B_DTE_MAX)
        'A delta min<=target<=max' = ($cfg.A_LONG_DELTA_MIN -le $cfg.A_LONG_DELTA_TARGET -and $cfg.A_LONG_DELTA_TARGET -le $cfg.A_LONG_DELTA_MAX)
        'B delta min<=target<=max' = ($cfg.B_SHORT_DELTA_MIN -le $cfg.B_SHORT_DELTA_TARGET -and $cfg.B_SHORT_DELTA_TARGET -le $cfg.B_SHORT_DELTA_MAX)
        'A_RISK_PCT <= A_MAX_SINGLE_CONTRACT_PCT' = ($cfg.A_RISK_PCT -le $cfg.A_MAX_SINGLE_CONTRACT_PCT)
        'B_RISK_PCT <= B_MAX_LOSS_PCT' = ($cfg.B_RISK_PCT -le $cfg.B_MAX_LOSS_PCT)
        'A_RISK_SHARE + B_RISK_SHARE == 1' = ([Math]::Abs($cfg.A_RISK_SHARE + $cfg.B_RISK_SHARE - 1.0) -le 1e-9)
        'MLEG_CREDIT_PRICE_SIGN must be NEGATIVE' = ($cfg.MLEG_CREDIT_PRICE_SIGN -ceq 'NEGATIVE')
        'EXPIRY_TYPE must be MONTHLY' = ($cfg.EXPIRY_TYPE -ceq 'MONTHLY')
        'EARNINGS_LOOKAHEAD_DAYS >= A_DTE_MAX' = ($cfg.EARNINGS_LOOKAHEAD_DAYS -ge $cfg.A_DTE_MAX)
        'POST_BLACKOUT < MAX_DAYS_SINCE_LAST < BACKFILL_DAYS' = ($cfg.EARNINGS_POST_BLACKOUT_DAYS -lt $cfg.EARNINGS_MAX_DAYS_SINCE_LAST -and $cfg.EARNINGS_MAX_DAYS_SINCE_LAST -lt $cfg.EARNINGS_BACKFILL_DAYS)
        'DD_MAX_OPEN_POSITIONS >= 1' = ($cfg.DD_MAX_OPEN_POSITIONS -ge 1)
    }
    foreach ($pair in @(@('A', $cfg.A_REGIME_MULT), @('B', $cfg.B_REGIME_MULT))) {
        foreach ($r in 'BULL', 'NEUTRAL', 'RANGING', 'BEAR') {
            $m = $pair[1]
            $checks["$($pair[0])_REGIME_MULT.$r in [0,1]"] = ($m.ContainsKey($r) -and (Test-OpusNumber $m[$r]) -and $m[$r] -ge 0 -and $m[$r] -le 1)
        }
    }
    foreach ($k in $checks.Keys) { if (-not $checks[$k]) { $err += $k } }
    return @{ Valid = ($err.Count -eq 0); Errors = $err }
}

# Env overrides: OPUS_DRY_RUN, OPUS_OPTIONS_ENABLED ('true'/'false'/'1'/'0').
function Set-OpusEnvOverrides([hashtable]$cfg) {
    foreach ($pair in @(@('OPUS_DRY_RUN', 'DRY_RUN'), @('OPUS_OPTIONS_ENABLED', 'OPTIONS_ENABLED'))) {
        $v = [Environment]::GetEnvironmentVariable($pair[0])
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        switch ($v.Trim().ToLower()) {
            { $_ -in 'true', '1', 'yes' }  { $cfg[$pair[1]] = $true }
            { $_ -in 'false', '0', 'no' } { $cfg[$pair[1]] = $false }
        }
    }
    return $cfg
}
