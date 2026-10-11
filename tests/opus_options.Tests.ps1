# tests/opus_options.Tests.ps1 -- Pester 5, spec v1.2 section 9. No network.
# Run: Invoke-Pester ./tests/opus_options.Tests.ps1 -Output Detailed

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'opus_options.ps1') -NoRun
    . (Join-Path $script:Root 'alpaca_swing_signals.ps1')
    $script:Cfg = Import-PowerShellDataFile (Join-Path $script:Root 'config/opus_options_config.psd1')
    Set-OpusConfig $script:Cfg

    # Version-proof float assertion (Pester's -BeApproximately does not bind in the CI's Pester).
    function Assert-Near($actual, $expected, [double]$tol = 1e-6) {
        [Math]::Abs([double]$actual - [double]$expected) | Should -BeLessOrEqual $tol
    }
    function New-Leg($strike, $delta, $bid, $ask, $oi = 5000, $type = 'call', $exp = '2026-11-20') {
        return @{ Occ = ('XYZ{0}{1}{2:00000000}' -f ($exp -replace '-', '').Substring(2), $type.Substring(0, 1).ToUpper(), [int]($strike * 1000))
                  Type = $type; Strike = [double]$strike; Expiration = $exp; Oi = [double]$oi; Bid = $bid; Ask = $ask; Delta = $delta; Iv = 0.3 }
    }
    function New-Bar($date, $o, $h, $l, $c) { [pscustomobject]@{ Date = $date; Time = [datetime]::ParseExact($date, 'yyyy-MM-dd', $null); Open = [double]$o; High = [double]$h; Low = [double]$l; Close = [double]$c; Volume = 1e6 } }
    function New-Sessions($from, $to, [string[]]$exclude = @()) {
        $out = @(); $d = [datetime]::ParseExact($from, 'yyyy-MM-dd', $null); $end = [datetime]::ParseExact($to, 'yyyy-MM-dd', $null)
        while ($d -le $end) { $s = $d.ToString('yyyy-MM-dd'); if ($d.DayOfWeek -notin 'Saturday', 'Sunday' -and $s -notin $exclude) { $out += $s }; $d = $d.AddDays(1) }
        return $out
    }
    function New-Pos($sleeve, $entry, $qty = 1, $extra = @{}) {
        $p = @{ sleeve = $sleeve; entry_fill_price = $entry; qty_open = $qty; partial_taken = $false; partial_fill_date = $null; short_strike = 185.0; entry_fill_date = '2026-10-01' }
        foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
        return $p
    }
    function New-ExitCtx($extra = @{}) {
        $x = @{ Today = '2026-10-12'; NextEarnings = $null; Dte = 30; Quote = $null; PNow = $null; ShortMid = $null; StopHits = 0; LastBar = $null; TradingDaysHeld = 3; ExDivTomorrow = $false; DividendPerShare = $null }
        foreach ($k in $extra.Keys) { $x[$k] = $extra[$k] }
        return $x
    }
}

Describe '9.1 Indicators' {
    It 'T1 EMA (existing alpaca_indicators function)' {
        $e = Get-EMAArray ([double[]]@(10, 11, 12, 13, 14)) 3
        Assert-Near ($e[2]) 11 1e-6; Assert-Near ($e[3]) 12 1e-6; Assert-Near ($e[4]) 13 1e-6
    }
    It 'T2 ATR Wilder n=3 (|H - C_prev| is the max component on bar 2)' {
        $b = @((New-Bar '2026-01-01' 9.5 10 9 9.5), (New-Bar '2026-01-02' 10 11 9 10), (New-Bar '2026-01-03' 13 14 12 13),
               (New-Bar '2026-01-04' 12 14 11 12), (New-Bar '2026-01-05' 12 15 10 12))
        # Existing Get-ATR rounds its output to 4 dp, hence 1e-4.
        Assert-Near (Get-ATR $b[0..3] 3) 3.0 1e-4
        Assert-Near (Get-ATR $b 3) 3.666667 1e-4
    }
    It 'T3 RS ratio form' {
        $s = @((New-Bar '2026-01-01' 100 100 100 100), (New-Bar '2026-01-02' 120 120 120 120))
        $p = @((New-Bar '2026-01-01' 400 400 400 400), (New-Bar '2026-01-02' 440 440 440 440))
        Assert-Near ((Get-OpusRsRatio $s $p 1).Value) 0.090909 1e-6
    }
    It 'T3b PULLBK RS difference form' {
        $bars = @(1..20 | ForEach-Object { New-Bar ('2026-01-{0:00}' -f $_) 100 100 100 100 })
        $spy  = @(1..20 | ForEach-Object { New-Bar ('2026-01-{0:00}' -f $_) 400 400 400 400 })
        $a = Get-OpusPullbackTrigger $bars 100 90 4 105 $spy 414 $script:Cfg
        Assert-Near ($a.Rs20Diff) 1.5 1e-6; $a.RsOk | Should -BeTrue
        $b = Get-OpusPullbackTrigger $bars 100 90 4 105 $spy 414.40 $script:Cfg
        Assert-Near ($b.Rs20Diff) 1.4 1e-6; $b.RsOk | Should -BeFalse
    }
    It 'T4 percentile' {
        $sc = @{}; for ($i = 0; $i -lt 25; $i++) { $sc[('S{0:00}' -f $i)] = 0.25 - 0.01 * $i }
        $r = Get-OpusRsPercentile $sc 0.20
        @($r.Keys | Where-Object { $r[$_].Pass }).Count | Should -Be 5
        $r['S04'].Pass | Should -BeTrue; $r['S05'].Pass | Should -BeFalse
        $sc11 = @{}; for ($i = 0; $i -lt 11; $i++) { $sc11[('T{0:00}' -f $i)] = 1 - 0.01 * $i }
        (Get-OpusRsPercentile $sc11 0.20)['T00'].K | Should -Be 3
        $tie = @{ BBB = 0.5; AAA = 0.5; CCC = 0.1; DDD = 0.1; EEE = 0.1 }   # k = 1
        $t = Get-OpusRsPercentile $tie 0.20
        $t['AAA'].Pass | Should -BeTrue; $t['BBB'].Pass | Should -BeFalse
    }
    It 'T5 completed bar rule' {
        $tz = $null; foreach ($id in 'America/New_York', 'Eastern Standard Time') { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
        $bars = @((New-Bar '2026-10-08' 1 1 1 1), (New-Bar '2026-10-09' 1 1 1 1), (New-Bar '2026-10-12' 1 1 1 1))
        $now = [datetime]'2026-10-12 15:35'; $close = [datetime]'2026-10-12 16:00'
        $c = Get-OpusCompletedBars $bars $now $close
        $c[-1].Date | Should -Be '2026-10-09'
        $c2 = Get-OpusCompletedBars $bars ([datetime]'2026-10-13 09:50') ([datetime]'2026-10-13 16:00')
        $c2[-1].Date | Should -Be '2026-10-12'
    }
}

Describe '9.2 Gates' {
    It 'T6 trend' {
        Test-OpusTrendGate 150 147 143 | Should -BeTrue
        Test-OpusTrendGate 150 142 143 | Should -BeFalse
    }
    It 'T7 PULLBK touch/reclaim/trend' {
        $mk = { param($lows) $i = 0; @($lows | ForEach-Object { $i++; New-Bar ('2026-01-{0:00}' -f $i) 148 149 $_ 148 }) }
        $spy = @(1..30 | ForEach-Object { New-Bar ('2026-01-{0:00}' -f $_) 400 400 400 400 })
        (Get-OpusPullbackTrigger (& $mk @(149, 149, 147.73)) 147 143 4 147.01 $spy 400 $script:Cfg).Touched | Should -BeTrue
        (Get-OpusPullbackTrigger (& $mk @(149, 149, 147.74)) 147 143 4 147.01 $spy 400 $script:Cfg).Touched | Should -BeFalse
        # Latest-EMA rule: L_{t-2} = 147.90 is inside its own per-bar zone (148.2375) but not EMA20_t's (147.735).
        (Get-OpusPullbackTrigger (& $mk @(147.90, 149, 149)) 147 143 4 147.01 $spy 400 $script:Cfg).Touched | Should -BeFalse
        (Get-OpusPullbackTrigger (& $mk @(149, 149, 147.73)) 147 143 4 147.01 $spy 400 $script:Cfg).Reclaimed | Should -BeTrue
        (Get-OpusPullbackTrigger (& $mk @(149, 149, 147.73)) 147 143 4 147.00 $spy 400 $script:Cfg).Reclaimed | Should -BeFalse
        (Get-OpusPullbackTrigger (& $mk @(149, 149, 147.73)) 147 145.5 4 147.01 $spy 400 $script:Cfg).TrendOk | Should -BeFalse
        (Get-OpusPullbackTrigger (& $mk @(149, 149, 147.73)) 147 145.4 4 147.01 $spy 400 $script:Cfg).TrendOk | Should -BeTrue
    }
    It 'T8 earnings gate incl. v1.2 fallback and override' {
        $t = '2026-10-12'
        (Test-OpusEarningsGate $t '2026-10-22' $null $script:Cfg).Pass | Should -BeTrue
        (Test-OpusEarningsGate $t '2026-10-21' $null $script:Cfg).Pass | Should -BeFalse
        (Test-OpusEarningsGate $t '2026-10-22' '2026-10-10' $script:Cfg).Pass | Should -BeFalse
        (Test-OpusEarningsGate $t '2026-10-22' '2026-10-09' $script:Cfg).Pass | Should -BeTrue
        (Test-OpusEarningsGate $t $null '2026-09-12' $script:Cfg).Pass | Should -BeTrue
        (Test-OpusEarningsGate $t $null '2026-08-28' $script:Cfg).Pass | Should -BeTrue
        $r = Test-OpusEarningsGate $t $null '2026-08-27' $script:Cfg; $r.Pass | Should -BeFalse; $r.Reason | Should -Be 'EARNINGS_DATA_MISSING'
        (Test-OpusEarningsGate $t $null $null $script:Cfg).Pass | Should -BeFalse
        (Test-OpusEarningsGate $t $null '2026-10-10' $script:Cfg).Reason | Should -Be 'EARNINGS_BLACKOUT'
        (Test-OpusEarningsGate $t '2026-10-05' $null $script:Cfg).Pass | Should -BeFalse
        $m = Merge-OpusEarnings @{ next_earnings_date = $null; last_earnings_date = '2026-08-27' } @{ next_earnings_date = '2026-12-30' }
        (Test-OpusEarningsGate $t $m.Next $m.Last $script:Cfg).Pass | Should -BeTrue
        $m = Merge-OpusEarnings @{ next_earnings_date = $null; last_earnings_date = '2026-09-12' } @{ next_earnings_date = '2026-10-20' }
        (Test-OpusEarningsGate $t $m.Next $m.Last $script:Cfg).Pass | Should -BeFalse
        $m = Merge-OpusEarnings @{ next_earnings_date = $null; last_earnings_date = $null } @{ last_earnings_date = '2026-09-12' }
        (Test-OpusEarningsGate $t $m.Next $m.Last $script:Cfg).Pass | Should -BeTrue
        (Merge-OpusEarnings @{ next_earnings_date = '2026-11-01' } @{ next_earnings_date = '2026-11-05' }).Next | Should -Be '2026-11-05'
    }
    It 'T9 liquidity' {
        Test-OpusLegLiquid (New-Leg 100 0.5 0.95 1.05 1001) $script:Cfg | Should -BeTrue
        Test-OpusLegLiquid (New-Leg 100 0.5 0.94 1.06 1001) $script:Cfg | Should -BeFalse
        Test-OpusLegLiquid (New-Leg 100 0.5 0.95 1.05 1000) $script:Cfg | Should -BeFalse
        Test-OpusLegLiquid (New-Leg 100 0.5 0.04 0.045 5000) $script:Cfg | Should -BeFalse
    }
    It 'T10 Sleeve B trigger' {
        Test-OpusSleeveBTrigger 200 197.5 196 5 $script:Cfg | Should -BeTrue
        Test-OpusSleeveBTrigger 201.5 197.5 196 5 $script:Cfg | Should -BeFalse
        Test-OpusSleeveBTrigger 200 201 196 5 $script:Cfg | Should -BeFalse
    }
}

Describe '9.3 Selection and sizing' {
    It 'T11 long delta ordering' {
        $calls = @((New-Leg 150 0.58 1 1.05), (New-Leg 148 0.61 1 1.05), (New-Leg 144 0.66 1 1.05), (New-Leg 141 0.69 1 1.05), (New-Leg 139 0.72 1 1.05))
        $o = Get-OpusSleeveALongCandidates $calls $script:Cfg
        @($o | ForEach-Object { $_.Delta }) | Should -Be @(0.66, 0.69, 0.61)
    }
    It 'T12 short strike band' {
        $grid5 = @(150, 155, 160, 165, 170, 175 | ForEach-Object { New-Leg $_ 0.2 1 1.05 })
        @((Get-OpusSleeveAShortCandidates $grid5 150.40 $script:Cfg) | ForEach-Object { $_.Strike }) | Should -Be @(165)
        $grid1 = @(60..70 | ForEach-Object { New-Leg $_ 0.2 1 1.05 })
        @((Get-OpusSleeveAShortCandidates $grid1 60.20 $script:Cfg) | ForEach-Object { $_.Strike }) | Should -Be @(66)
    }
    It 'T13 debit cap' {
        $ok = Select-OpusSleeveAPair @((New-Leg 145 0.65 12.25 12.35), (New-Leg 165 0.2 3.25 3.35)) 150.40 $script:Cfg
        Assert-Near ($ok.Pair.DebitMid) 9.00 1e-6
        $bad = Select-OpusSleeveAPair @((New-Leg 145 0.65 12.26 12.36), (New-Leg 165 0.2 3.25 3.35)) 150.40 $script:Cfg
        $bad.Pair | Should -BeNullOrEmpty; $bad.Reason | Should -Be 'DEBIT_TOO_HIGH'
    }
    It 'T14 sizing A' {
        $a = Get-OpusSizingA 3.80 5000 1.0 $script:Cfg; $a.Contracts | Should -Be 1; Assert-Near (($a.Contracts * $a.Cost1)) 380 1e-6
        (Get-OpusSizingA 4.01 5000 1.0 $script:Cfg).Reason | Should -Be 'SINGLE_CONTRACT_TOO_LARGE'
        (Get-OpusSizingA 3.80 20000 1.0 $script:Cfg).Contracts | Should -Be 3
        $dd = Get-OpusSizingA 3.80 5000 1.0 $script:Cfg   # drawdown mode does not scale size (P10)
        Assert-Near ($dd.SingleCap) 400 1e-6; $dd.Contracts | Should -Be 1
    }
    It 'T15 sizing B and credit floor' {
        $b = Get-OpusSizingB 1.68 5 5000 0.75 $script:Cfg; Assert-Near ($b.MaxLoss1) 332 1e-6; $b.Contracts | Should -Be 1
        (Get-OpusSizingB 1.68 5 4800 0.75 $script:Cfg).Ok | Should -BeTrue
        (Get-OpusSizingB 1.68 5 4700 0.75 $script:Cfg).Reason | Should -Be 'MAXLOSS_TOO_LARGE'
        $puts = @((New-Leg 185 -0.23 2.61 2.71 5000 'put'), (New-Leg 180 -0.15 0.95 1.05 5000 'put'))
        (Select-OpusSleeveBPair $puts 190 $script:Cfg).Pair | Should -BeNullOrEmpty
        (Select-OpusSleeveBPair $puts 190 $script:Cfg).Reason | Should -Be 'CREDIT_TOO_LOW'
    }
    It 'T16 long put exactly K_short - 5' {
        $puts = @((New-Leg 185 -0.225 2.60 2.75 5000 'put'), (New-Leg 180 -0.15 0.95 1.05 5000 'put'))
        $r = Select-OpusSleeveBPair $puts 190 $script:Cfg; $r.Pair.Long.Strike | Should -Be 180; Assert-Near ($r.Pair.CreditMid) 1.68 1e-9
        $puts2 = @((New-Leg 185 -0.225 2.60 2.75 5000 'put'), (New-Leg 184 -0.21 2.40 2.55 5000 'put'), (New-Leg 179 -0.12 0.70 0.75 5000 'put'))
        $r2 = Select-OpusSleeveBPair $puts2 190 $script:Cfg; $r2.Pair.Short.Strike | Should -Be 184; $r2.Pair.Long.Strike | Should -Be 179
    }
    It 'T17 partial qty' {
        foreach ($c in @(@(1, 1), @(2, 1), @(3, 2), @(5, 3))) {
            $d = Get-OpusExitDecision (New-Pos 'A_CALL_DEBIT' 3.80 $c[0]) (New-ExitCtx @{ Quote = @{ Mid = 6.50 } }) $script:Cfg
            $d.Reason | Should -Be 'TP_PARTIAL'; $d.Qty | Should -Be $c[1]
        }
    }
    It 'T38 expiry selection (monthly-anchored)' {
        $ses = New-Sessions '2026-09-01' '2027-03-31'; $set = @{}; foreach ($s in $ses) { $set[$s] = $true }
        $exps = @('2026-11-20', '2026-11-27', '2026-12-18', '2027-01-15', '2027-02-19')
        $a = Select-OpusExpiries $exps '2026-10-12' 38 70 52 14 $set '2026-09-01' '2027-03-31'
        @($a.Expiries | ForEach-Object { $_.Date }) | Should -Be @('2026-11-20', '2026-12-18'); $a.Fallback | Should -BeFalse
        @((Select-OpusExpiries $exps '2026-10-12' 30 45 38 10 $set '2026-09-01' '2027-03-31').Expiries | ForEach-Object { $_.Date }) | Should -Be @('2026-11-20')
        (Select-OpusExpiries $exps '2026-10-26' 38 70 52 14 $set '2026-09-01' '2027-03-31').Expiries[0].Date | Should -Be '2026-12-18'
        $b = Select-OpusExpiries $exps '2026-10-26' 30 45 38 10 $set '2026-09-01' '2027-03-31'
        $b.Fallback | Should -BeTrue; $b.Expiries[0].Date | Should -Be '2026-11-20'; $b.Expiries[0].Dte | Should -Be 25
        $c = Select-OpusExpiries $exps '2026-12-09' 38 70 52 14 $set '2026-09-01' '2027-03-31'
        $c.Fallback | Should -BeTrue; $c.Expiries[0].Date | Should -Be '2027-01-15'
        $hol = @{}; foreach ($s in (New-Sessions '2026-09-01' '2027-03-31' @('2026-11-20'))) { $hol[$s] = $true }
        Get-OpusMonthlyExpiration 2026 11 $hol '2026-09-01' '2027-03-31' | Should -Be '2026-11-19'
    }
}

Describe '9.4 Exits' {
    It 'T18 priority' {
        $d = Get-OpusExitDecision (New-Pos 'A_CALL_DEBIT' 3.80) (New-ExitCtx @{ NextEarnings = '2026-10-14'; Quote = @{ Mid = 1.5 }; StopHits = 2 }) $script:Cfg
        $d.Reason | Should -Be 'EARNINGS'
        (Get-OpusExitDecision (New-Pos 'A_CALL_DEBIT' 3.80) (New-ExitCtx @{ Dte = 14; Quote = @{ Mid = 7.0 } }) $script:Cfg).Reason | Should -Be 'DTE'
    }
    It 'T19 A thresholds' {
        $p = New-Pos 'A_CALL_DEBIT' 3.80
        (Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 6.46 } }) $script:Cfg).Reason | Should -Be 'TP_PARTIAL'
        Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 6.45 } }) $script:Cfg | Should -BeNullOrEmpty
        (Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 1.90 }; StopHits = 2 }) $script:Cfg).Reason | Should -Be 'STOP'
        (Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 4.55 }; TradingDaysHeld = 10 }) $script:Cfg).Reason | Should -Be 'TIME_STOP'
        Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 4.56 }; TradingDaysHeld = 10 }) $script:Cfg | Should -BeNullOrEmpty
        Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 4.00 }; TradingDaysHeld = 9 }) $script:Cfg | Should -BeNullOrEmpty
    }
    It 'T20 B thresholds' {
        $p = New-Pos 'B_PUT_CREDIT' 1.68
        (Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 0.84 } }) $script:Cfg).Reason | Should -Be 'TP'
        (Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 3.36 }; StopHits = 2 }) $script:Cfg).Reason | Should -Be 'STOP'
        Get-OpusExitDecision $p (New-ExitCtx @{ Quote = @{ Mid = 3.36 }; StopHits = 1 }) $script:Cfg | Should -BeNullOrEmpty
    }
    It 'T21 B4 short strike break' {
        $p = New-Pos 'B_PUT_CREDIT' 1.68
        (Get-OpusExitDecision $p (New-ExitCtx @{ LastBar = @{ Date = '2026-10-09'; Close = 184.99 } }) $script:Cfg).Reason | Should -Be 'SHORT_STRIKE_BREAK'
        Get-OpusExitDecision $p (New-ExitCtx @{ LastBar = @{ Date = '2026-10-09'; Close = 185.00 } }) $script:Cfg | Should -BeNullOrEmpty
    }
    It 'T22 A7 EMA20 trail only after the partial' {
        $bar = @{ Date = '2026-10-09'; Close = 99; Ema20 = 100; Ema50 = 90 }
        Get-OpusExitDecision (New-Pos 'A_CALL_DEBIT' 3.80) (New-ExitCtx @{ LastBar = $bar; Quote = @{ Mid = 4.0 } }) $script:Cfg | Should -BeNullOrEmpty
        $after = New-Pos 'A_CALL_DEBIT' 3.80 1 @{ partial_taken = $true; partial_fill_date = '2026-10-08' }
        (Get-OpusExitDecision $after (New-ExitCtx @{ LastBar = $bar; Quote = @{ Mid = 4.0 } }) $script:Cfg).Reason | Should -Be 'EMA20_TRAIL'
    }
    It 'T23 DTE' {
        Get-OpusExitDecision (New-Pos 'A_CALL_DEBIT' 3.80) (New-ExitCtx @{ Dte = 15 }) $script:Cfg | Should -BeNullOrEmpty
        (Get-OpusExitDecision (New-Pos 'A_CALL_DEBIT' 3.80) (New-ExitCtx @{ Dte = 14 }) $script:Cfg).Reason | Should -Be 'DTE'
        Get-OpusExitDecision (New-Pos 'B_PUT_CREDIT' 1.68) (New-ExitCtx @{ Dte = 11 }) $script:Cfg | Should -BeNullOrEmpty
        (Get-OpusExitDecision (New-Pos 'B_PUT_CREDIT' 1.68) (New-ExitCtx @{ Dte = 10 }) $script:Cfg).Reason | Should -Be 'DTE'
    }
}

Describe '9.5 Guards' {
    It 'T24 P5 total open risk + decrement' {
        (Resolve-OpusRiskCaps 1 300 300 712 0 5000 $script:Cfg).Reason | Should -Be 'RISK_CAP'
        (Resolve-OpusRiskCaps 3 380 380 2000 0 20000 $script:Cfg).Contracts | Should -Be 2
    }
    It 'T25 P6 underlying exposure' {
        (Resolve-OpusRiskCaps 1 332 500 0 0 5000 $script:Cfg).Contracts | Should -Be 1
    }
    It 'T26 P10 drawdown mode' {
        $d = Update-OpusDrawdownMode 5000 5600 $false $null $script:Cfg
        $d.DdMode | Should -BeTrue; Assert-Near ($d.Drawdown) 0.107143 1e-6
        $ctx = @{ Cfg = $script:Cfg; OpusUnderlyings = @{}; StockHeld = @{}; EntriesToday = 0; Cooldown = @{}; DdMode = $true; OpenPlusWorking = 1 }
        Get-OpusSymbolBlock 'NVDA' '2026-10-12' $ctx | Should -Be 'DD_POSITION_LIMIT'
        $ctx.OpenPlusWorking = 0; Get-OpusSymbolBlock 'NVDA' '2026-10-12' $ctx | Should -BeNullOrEmpty
        (Update-OpusDrawdownMode 5600 5600 $true 5600 $script:Cfg).DdMode | Should -BeTrue
        (Update-OpusDrawdownMode 5600.01 5600.01 $true 5600 $script:Cfg).DdMode | Should -BeFalse
        (Update-OpusDrawdownMode 5050 5600 $false $null $script:Cfg).DdMode | Should -BeFalse
    }
    It 'T27 P2 daily loss halt' {
        Test-OpusDailyLossHalt 4850 5000 $script:Cfg | Should -BeTrue
        Test-OpusDailyLossHalt 4850.01 5000 $script:Cfg | Should -BeFalse
    }
    It 'T28 P3 / P4 / P9' {
        $ses = New-Sessions '2026-10-01' '2026-10-31'
        $st = @{ strategy_halted = $false; manual_review_required = $false; entries_halted_date = $null; pause_until = $null }
        Get-OpusPortfolioBlock $st '2026-10-12' @{ Cfg = $script:Cfg; LossesToday = 2 } | Should -Be 'DAILY_LOSS_COUNT'
        $st.pause_until = Add-OpusTradingDays '2026-10-12' 5 $ses
        $st.pause_until | Should -Be '2026-10-19'
        Get-OpusPortfolioBlock $st '2026-10-19' @{ Cfg = $script:Cfg; LossesToday = 0 } | Should -Be 'CONSEC_LOSS_PAUSE'
        Get-OpusPortfolioBlock $st '2026-10-20' @{ Cfg = $script:Cfg; LossesToday = 0 } | Should -BeNullOrEmpty
        $cd = @{ NVDA = (Add-OpusTradingDays '2026-10-12' 5 $ses) }
        $ctx = @{ Cfg = $script:Cfg; OpusUnderlyings = @{}; StockHeld = @{}; EntriesToday = 0; Cooldown = $cd; DdMode = $false; OpenPlusWorking = 0 }
        Get-OpusSymbolBlock 'NVDA' '2026-10-19' $ctx | Should -Be 'COOLDOWN'
        Get-OpusSymbolBlock 'NVDA' '2026-10-20' $ctx | Should -BeNullOrEmpty
    }
    It 'T29 P7 / P8' {
        $ctx = @{ Cfg = $script:Cfg; OpusUnderlyings = @{ NVDA = $true }; StockHeld = @{ MSFT = $true }; EntriesToday = 0; Cooldown = @{}; DdMode = $false; OpenPlusWorking = 1 }
        Get-OpusSymbolBlock 'NVDA' '2026-10-12' $ctx | Should -Be 'UNDERLYING_BUSY'
        Get-OpusSymbolBlock 'MSFT' '2026-10-12' $ctx | Should -Be 'UNDERLYING_BUSY'
        $ctx.EntriesToday = 2; Get-OpusSymbolBlock 'AAPL' '2026-10-12' $ctx | Should -Be 'DAILY_ENTRY_CAP'
    }
    It 'T30 sleeve priority' {
        $o = Get-OpusSleeveOrder 380 0 5000 $script:Cfg
        $o.First | Should -Be 'B'; Assert-Near ($o.UA) 0.844444 1e-5
    }
}

Describe '9.6 Orders' {
    It 'T31 repricing' {
        @(0, 1, 2 | ForEach-Object { Get-OpusRepricePrice 3.80 4.10 'debit' $_ $script:Cfg }) | ForEach-Object { [Math]::Round($_, 2) } | Should -Be @(3.80, 3.90, 4.00)
        @(0, 1, 2 | ForEach-Object { Get-OpusRepricePrice 1.68 1.55 'credit' $_ $script:Cfg }) | ForEach-Object { [Math]::Round($_, 2) } | Should -Be @(1.68, 1.64, 1.59)
    }
    It 'T32 client_order_id' {
        $id = New-OpusClientOrderId 'OPCALLDEB' 'NVDA' '20261012' 'E' 0
        $id | Should -Match '^(OPCALLDEB|OPPUTCRED)-[A-Z.]{1,6}-\d{8}-(E|X|P|ASG)-\d+-[0-9a-f]{4}$'
        $id.Length | Should -BeLessOrEqual 128
    }
    It 'T34 payloads and signs' {
        $a = New-OpusMlegPayload 'A' 'open' @{ Long = 'L'; Short = 'S' } 1 3.80 'id' $script:Cfg
        $a.limit_price | Should -Be '3.80'; $a.qty | Should -Be '1'; $a.order_class | Should -Be 'mleg'
        $a.legs[0].side | Should -Be 'buy'; $a.legs[0].position_intent | Should -Be 'buy_to_open'; $a.legs[1].position_intent | Should -Be 'sell_to_open'
        $ax = New-OpusMlegPayload 'A' 'close' @{ Long = 'L'; Short = 'S' } 1 6.46 'id' $script:Cfg
        $ax.limit_price | Should -Be '-6.46'; $ax.legs[0].position_intent | Should -Be 'sell_to_close'; $ax.legs[1].position_intent | Should -Be 'buy_to_close'
        $b = New-OpusMlegPayload 'B' 'open' @{ Long = 'L'; Short = 'S' } 1 1.68 'id' $script:Cfg
        $b.limit_price | Should -Be '-1.68'; $b.legs[0].symbol | Should -Be 'S'; $b.legs[0].position_intent | Should -Be 'sell_to_open'
        $bx = New-OpusMlegPayload 'B' 'close' @{ Long = 'L'; Short = 'S' } 1 0.84 'id' $script:Cfg
        $bx.limit_price | Should -Be '0.84'; $bx.legs[0].position_intent | Should -Be 'buy_to_close'; $bx.legs[1].position_intent | Should -Be 'sell_to_close'
        (New-OpusSingleLegPayload 'S' 'buy' 'buy_to_close' 1 2.10 'id' $script:Cfg).limit_price | Should -Be '2.10'
    }
    It 'T36 entry window decision' {
        $s = [datetime]'2026-10-12 15:30'; $e = [datetime]'2026-10-12 15:55'
        Get-OpusEntryEvalDecision ([datetime]'2026-10-12 15:20') $s $e $null '2026-10-12' | Should -Be 'NONE'
        Get-OpusEntryEvalDecision ([datetime]'2026-10-12 15:31') $s $e $null '2026-10-12' | Should -Be 'EVAL'
        Get-OpusEntryEvalDecision ([datetime]'2026-10-12 15:41') $s $e '2026-10-12' '2026-10-12' | Should -Be 'NONE'
        Get-OpusEntryEvalDecision ([datetime]'2026-11-27 12:31') ([datetime]'2026-11-27 12:30') ([datetime]'2026-11-27 12:55') $null '2026-11-27' | Should -Be 'EVAL'
        Get-OpusEntryEvalDecision ([datetime]'2026-10-12 15:56') $s $e $null '2026-10-12' | Should -Be 'MISSED'
    }
    It 'T37 credit sign config' {
        (Test-OpusConfig $script:Cfg).Valid | Should -BeTrue
        foreach ($bad in 'VERIFY', 'POSITIVE') {
            $c = $script:Cfg.Clone(); $c.MLEG_CREDIT_PRICE_SIGN = $bad
            (Test-OpusConfig $c).Valid | Should -BeFalse
        }
        @(0, 1, 2 | ForEach-Object { Format-OpusLimitPrice (Get-OpusRepricePrice 1.68 1.55 'credit' $_ $script:Cfg) 'credit' $script:Cfg }) | Should -Be @('-1.68', '-1.64', '-1.59')
    }
    It 'T39 PULLBK parity with the swing code (never .Valid)' {
        $tz = $null; foreach ($id in 'Eastern Standard Time', 'America/New_York') { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
        $todayEt = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).Date
        $mkSeries = {
            param([double]$start, [double]$slope, [double]$range, [int]$n)
            $out = @()
            for ($i = 0; $i -lt $n; $i++) {
                $d = $todayEt.AddDays(-($n - $i)); $c = $start + $slope * $i
                $out += [pscustomobject]@{ Date = $d.ToString('yyyy-MM-dd'); Time = $d; Open = $c - 0.2; High = $c + $range; Low = $c - $range; Close = $c; Volume = 1e6 }
            }
            return , $out
        }
        $bars = & $mkSeries 100 0.3 0.6 199
        $closes = [double[]]@($bars | ForEach-Object { $_.Close })
        $ema20 = Get-EMA $closes 20
        $bars[-2].Low = $ema20 - 0.05                             # touch inside the last 3 completed bars
        $ema50 = Get-EMA $closes 50; $atr = Get-ATR $bars 14
        $pNow = $ema20 + 2.0
        $spy = & $mkSeries 400 0.1 1 199
        $spyNow = $spy[-1].Close + 0.1
        $partial = [pscustomobject]@{ Date = $todayEt.ToString('yyyy-MM-dd'); Time = $todayEt; Open = $pNow - 0.5; High = $pNow + 0.5; Low = $pNow - 0.6; Close = $pNow; Volume = 1e5 }
        $spyPartial = [pscustomobject]@{ Date = $todayEt.ToString('yyyy-MM-dd'); Time = $todayEt; Open = $spyNow; High = $spyNow; Low = $spyNow; Close = $spyNow; Volume = 1e5 }
        $swingBars = @($bars) + $partial; $swingSpy = @($spy) + $spyPartial

        $opus = Get-OpusPullbackTrigger $bars $ema20 $ema50 $atr $pNow $spy $spyNow $script:Cfg
        Assert-Near ($opus.Rs20Diff) (Get-RelativeStrength $swingBars $swingSpy 20) 1e-9
        $opus.Touched | Should -BeTrue; $opus.Reclaimed | Should -BeTrue; $opus.Pullback | Should -BeTrue
        (Get-SwingPullbackSignal $null $swingBars 'BULL' $swingSpy).Valid | Should -BeTrue      # same setup, swing agrees

        # The swing signal also rejects on STOCK-stop geometry. The spec's "> 3 ATR" case
        # cannot occur (the swing stop is max(price - 2 ATR, EMA50 - 0.25 ATR), never more
        # than 2 ATR away), so the reachable rejection -- SWING_MAX_STOP_PCT -- is forced
        # instead. The swing signal turns invalid; the options trigger must not move.
        $SWING_MAX_STOP_PCT = 0.001
        (Get-SwingPullbackSignal $null $swingBars 'BULL' $swingSpy).Valid | Should -BeFalse
        (Get-OpusPullbackTrigger $bars $ema20 $ema50 $atr $pNow $spy $spyNow $script:Cfg).Pullback | Should -BeTrue
    }
}

Describe 'Earnings feed (T40, T41)' {
    BeforeEach {
        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("opus-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Tmp 'data') -Force | Out-Null
        Set-OpusRoot $script:Tmp
        $script:Asked = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach { Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue }

    It 'T40 refresh window, failure keeps the file, last date carried forward' {
        $asked = $script:Asked
        $fetch = { param($d) $asked.Add($d); if ($d -eq '2026-10-10') { return @{ Ok = $true; Symbols = @('NVDA') } }; return @{ Ok = $true; Symbols = @() } }.GetNewClosure()
        (Update-OpusEarnings $script:Cfg '2026-10-12' @('NVDA', 'MSFT') $fetch '2026-10-12T05:00:00Z' 0).Written | Should -BeTrue
        $asked.Count | Should -Be 74; $asked[0] | Should -Be '2026-10-09'; $asked[-1] | Should -Be '2026-12-21'
        $f = Read-OpusJson $script:Cfg.EARNINGS_FILE
        $f.symbols.NVDA.last_earnings_date | Should -Be '2026-10-10'

        # Stored last of 2026-09-02 for MSFT survives a refresh with no MSFT row.
        $f.symbols.MSFT.last_earnings_date = '2026-09-02'; Write-OpusJson $script:Cfg.EARNINGS_FILE $f
        $none = { param($d) @{ Ok = $true; Symbols = @() } }
        (Update-OpusEarnings $script:Cfg '2026-10-12' @('MSFT') $none 'x' 0).Written | Should -BeTrue
        $m = (Read-OpusJson $script:Cfg.EARNINGS_FILE).symbols.MSFT
        $m.last_earnings_date | Should -Be '2026-09-02'
        (Test-OpusEarningsGate '2026-10-12' $m.next_earnings_date $m.last_earnings_date $script:Cfg).Pass | Should -BeTrue

        # A later lookback date replaces the stored one.
        $later = { param($d) if ($d -eq '2026-10-11') { @{ Ok = $true; Symbols = @('MSFT') } } else { @{ Ok = $true; Symbols = @() } } }
        Update-OpusEarnings $script:Cfg '2026-10-12' @('MSFT') $later 'x' 0 | Out-Null
        (Read-OpusJson $script:Cfg.EARNINGS_FILE).symbols.MSFT.last_earnings_date | Should -Be '2026-10-11'

        # A refresh failing mid-window leaves the file untouched.
        $before = Get-Content (Resolve-OpusPath $script:Cfg.EARNINGS_FILE) -Raw
        $fail = { param($d) if ($d -eq '2026-11-01') { @{ Ok = $false; Symbols = @() } } else { @{ Ok = $true; Symbols = @() } } }
        $r = Update-OpusEarnings $script:Cfg '2026-10-12' @('MSFT') $fail 'later' 0
        $r.Written | Should -BeFalse; $r.Reason | Should -Be 'EARNINGS_REFRESH_FAILED'
        Get-Content (Resolve-OpusPath $script:Cfg.EARNINGS_FILE) -Raw | Should -Be $before
    }

    It 'T41 one-time backfill' {
        $asked = $script:Asked
        $fetch = { param($d) $asked.Add($d); if ($d -eq '2026-08-05') { @{ Ok = $true; Symbols = @('NVDA') } } else { @{ Ok = $true; Symbols = @() } } }.GetNewClosure()
        $r = Invoke-OpusEarningsBackfill $script:Cfg '2026-10-12' @('NVDA', 'TSM') $fetch 'now' 0
        $r.Written | Should -BeTrue; $r.Missing | Should -Be @('TSM')
        $asked.Count | Should -Be 100; $asked[0] | Should -Be '2026-07-04'; $asked[-1] | Should -Be '2026-10-11'
        $f = Read-OpusJson $script:Cfg.EARNINGS_FILE
        $f.symbols.NVDA.last_earnings_date | Should -Be '2026-08-05'; $f.symbols.NVDA.next_earnings_date | Should -BeNullOrEmpty
        $f.backfill_completed_at | Should -Not -BeNullOrEmpty

        $asked.Clear()
        (Invoke-OpusEarningsBackfill $script:Cfg '2026-10-12' @('NVDA') $fetch 'now' 0).Reason | Should -Be 'ALREADY_DONE'
        $asked.Count | Should -Be 0

        Remove-Item (Resolve-OpusPath $script:Cfg.EARNINGS_FILE)
        $fail = { param($d) if ($d -eq '2026-09-01') { @{ Ok = $false; Symbols = @() } } else { @{ Ok = $true; Symbols = @() } } }
        $bf = Invoke-OpusEarningsBackfill $script:Cfg '2026-10-12' @('NVDA') $fail 'now' 0
        $bf.Reason | Should -Be 'EARNINGS_BACKFILL_FAILED'
        Test-Path (Resolve-OpusPath $script:Cfg.EARNINGS_FILE) | Should -BeFalse
    }

    It 'T41 tools/backfill_earnings.ps1 uses the same function as the automatic path' {
        $src = Get-Content (Join-Path $script:Root 'tools/backfill_earnings.ps1') -Raw
        $src | Should -Match 'Invoke-OpusEarningsBackfill'
    }
}

Describe 'Orchestrator (T33, T35)' {
    BeforeAll {
        # Fixture repo: config + data in a temp root.
        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("opus-scan-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Tmp 'config'), (Join-Path $script:Tmp 'data') -Force | Out-Null
        Copy-Item (Join-Path $script:Root 'config/opus_options_config.psd1') (Join-Path $script:Tmp 'config/')
        $script:OPUS_ROOT = $script:Tmp; Set-OpusRoot $script:Tmp

        $syms = 0..9 | ForEach-Object { 'S{0:00}' -f $_ }
        Write-OpusJson 'data/universe.json' ([ordered]@{ refreshed_at = '2026-10-12T00:00:00Z'; source = 'test'
            symbols = @($syms | ForEach-Object { [ordered]@{ symbol = $_; roic = 0.3; rev_growth = 0.2; fcf_positive = $true; refreshed_at = '2026-10-12T00:00:00Z' } }) })
        Write-OpusJson 'data/earnings_override.json' ([ordered]@{ symbols = @{} })
        $earnSyms = @{}; foreach ($s in $syms) { $earnSyms[$s] = [ordered]@{ next_earnings_date = '2026-12-15'; last_earnings_date = '2026-09-15'; confirmed = $false } }
        Write-OpusJson 'data/earnings.json' ([ordered]@{ refreshed_at = '2026-10-12T05:00:00Z'; source = 'test'; backfill_completed_at = '2026-10-12T05:00:00Z'; symbols = $earnSyms })
        $st = New-OpusState $script:Cfg; $st.last_earnings_refresh = '2026-10-12'
        Write-OpusJson 'data/opus_options_state.json' $st

        # Bars: 200 completed sessions; S00 rises fastest (top RS) and sits just above EMA20 with a green close.
        $script:Ses = New-Sessions '2026-01-01' '2027-03-31'
        $hist = @($script:Ses | Where-Object { $_ -lt '2026-10-12' } | Select-Object -Last 200)
        $script:BarsFx = @{}
        for ($k = 0; $k -lt 10; $k++) {
            $slope = 0.30 - 0.02 * $k; $out = @()
            for ($i = 0; $i -lt $hist.Count; $i++) { $c = 100 + $slope * $i; $out += [pscustomobject]@{ Date = $hist[$i]; Open = $c - 0.5; High = $c + 2.5; Low = $c - 2.5; Close = $c; Volume = 1e6 } }
            $script:BarsFx[$syms[$k]] = $out
        }
        $script:BarsFx['SPY'] = @(for ($i = 0; $i -lt $hist.Count; $i++) { [pscustomobject]@{ Date = $hist[$i]; Open = 400; High = 401; Low = 399; Close = 400 + 0.05 * $i; Volume = 1e6 } })
        $s0 = $script:BarsFx['S00'][-1].Close   # ~159.7, EMA20 ~157, EMA50 ~152
        $script:Spot = $s0
    }
    AfterAll { Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-12 13:30', 'Utc')
        Mock Load-AlpacaConfig { [pscustomobject]@{ paper_trading = $true } }
        Mock Get-OpusUtcNow { $script:Now }
        Mock Get-OpusCalendar { @($script:Ses | Where-Object { $_ -ge '2026-09-01' -and $_ -le '2027-02-28' } | ForEach-Object { [pscustomobject]@{ date = $_; open = '09:30'; close = '16:00' } }) }
        Mock Get-OpusClock { $et = [System.TimeZoneInfo]::ConvertTimeFromUtc($script:Now, (Get-OpusTimeZone)); [pscustomobject]@{ is_open = ($et.Hour * 60 + $et.Minute -ge 570 -and $et.Hour -lt 16) } }
        Mock Get-OpusAccount { [pscustomobject]@{ options_trading_level = 3; options_buying_power = 80000; trading_blocked = $false; account_blocked = $false } }
        Mock Get-OpusPositions { @([pscustomobject]@{ symbol = 'MSFT'; asset_class = 'us_equity'; qty = '17' }) }
        Mock Get-OpusBars { $h = @{}; foreach ($s in $symbols) { $h[$s] = @($script:BarsFx[$s]) }; $h }
        Mock Get-OpusLatestPrices { $h = @{}; foreach ($s in $symbols) { if ($script:BarsFx.ContainsKey($s)) { $h[$s] = $script:BarsFx[$s][-1].Close + 0.2 } }; $h }
        Mock Get-SwingRegime { [pscustomobject]@{ Regime = 'BULL'; Reason = 'mock'; SizeMult = 1.0 } }
        Mock Get-OpusAtmIv { 0.30 }
        Mock Get-OpusDividends { $null }
        Mock Get-OpusContracts {
            $strikes = 130..175
            @($strikes | ForEach-Object { [pscustomobject]@{ symbol = ('{0}261120P{1:00000000}' -f $symbol, $_ * 1000); strike_price = "$_"; expiration_date = '2026-11-20'; open_interest = '5000'; tradable = $true; style = 'american' } })
        }
        Mock Get-OpusChainSnapshots {
            $h = @{}
            foreach ($k in 130..175) {
                $occ = '{0}261120P{1:00000000}' -f $symbol, $k * 1000
                $delta = -[Math]::Min(0.6, [Math]::Max(0.02, 0.225 + ($k - 145) * 0.02))
                $mid = [Math]::Max(0.20, 3.00 + ($k - 145) * 0.36)
                $h[$occ] = [pscustomobject]@{ latestQuote = [pscustomobject]@{ bp = [Math]::Round($mid - 0.04, 2); ap = [Math]::Round($mid + 0.04, 2) }; greeks = [pscustomobject]@{ delta = $delta }; impliedVolatility = 0.3 }
            }
            $h
        }
        Mock Get-OpusLegQuotes {
            $h = @{}
            foreach ($o in $occs) { $k = [int]($o.Substring($o.Length - 8)) / 1000; $mid = [Math]::Max(0.20, 3.00 + ($k - 145) * 0.36)
                $h[$o] = @{ Occ = $o; Bid = [Math]::Round($mid - 0.04, 2); Ask = [Math]::Round($mid + 0.04, 2); Delta = -0.2; Oi = 0 } }
            $h
        }
        Mock Submit-OpusOrder { throw 'must not be called' }
        Mock Remove-OpusOrder { throw 'must not be called' }
        Mock Get-OpusOrderById { throw 'must not be called' }
    }

    It 'T35 DRY_RUN: a simulated day of 39 scans places no real orders and journals dry_run rows' {
        for ($i = 0; $i -lt 39; $i++) {
            $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-12 13:30', 'Utc').AddMinutes(10 * $i)
            Invoke-OpusOptionsScan
        }
        Should -Invoke Submit-OpusOrder -Times 0 -Exactly
        Should -Invoke Remove-OpusOrder -Times 0 -Exactly
        $orders = @(Read-OpusJsonl 'data/journal_options_orders.jsonl')
        $orders.Count | Should -BeGreaterThan 0
        @($orders | Where-Object { -not $_.dry_run }).Count | Should -Be 0
        $skips = @(Read-OpusJsonl 'data/journal_options_skips.jsonl')
        @($skips | Where-Object { $_.symbol -eq 'MSFT' }).Count | Should -Be 0     # MSFT is not in this universe
        (Read-OpusJson 'data/opus_options_state.json').last_entry_eval_date | Should -Be '2026-10-12'
    }

    It 'T33 ownership: positions and orders Opus does not own are never touched' {
        # Foreign option position and a foreign open order exist on the account; state holds nothing.
        Mock Get-OpusPositions { @([pscustomobject]@{ symbol = 'NVDA261120C00200000'; asset_class = 'us_option'; qty = '1' }) }
        $st = New-OpusState $script:Cfg; $st.last_earnings_refresh = '2026-10-12'; $st.last_entry_eval_date = '2026-10-12'
        Write-OpusJson 'data/opus_options_state.json' $st
        $script:Now = [datetime]::SpecifyKind([datetime]'2026-10-12 15:00', 'Utc')
        Invoke-OpusOptionsScan
        Should -Invoke Submit-OpusOrder -Times 0 -Exactly
        Should -Invoke Remove-OpusOrder -Times 0 -Exactly
        @((Read-OpusJson 'data/opus_options_state.json').positions).Count | Should -Be 0
    }
}
