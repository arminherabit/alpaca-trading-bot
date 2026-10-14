# tests/swing_aggr.Tests.ps1 -- Pester 5. Swing Aggressive spec v1.1. No network.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'alpaca_client.ps1')
    . (Join-Path $script:Root 'alpaca_indicators.ps1')
    . (Join-Path $script:Root 'alpaca_swing_signals.ps1')
    . (Join-Path $script:Root 'alpaca_risk.ps1')
    . (Join-Path $script:Root 'alpaca_screener.ps1')
    . (Join-Path $script:Root 'alpaca_earnings.ps1')
    . (Join-Path $script:Root 'alpaca_journal.ps1')
    . (Join-Path $script:Root 'alpaca_swing_aggr.ps1')
    $script:Cfg = Get-Content (Join-Path $script:Root 'alpaca_config.json') -Raw | ConvertFrom-Json
    $script:A = $script:Cfg.aggr
    function Near($x, $y, $t = 1e-6) { [Math]::Abs([double]$x - [double]$y) | Should -BeLessOrEqual $t }
    function C($occ, $dte, $delta, $bid, $ask, $oi = 1000, $vol = 100) {
        [pscustomobject]@{ Occ = $occ; Expiration = '2026-11-27'; Dte = $dte; Delta = $delta; Bid = $bid; Ask = $ask; Oi = $oi; Volume = $vol }
    }
}

Describe 'Config' {
    It 'ships with aggr enabled AND dry_run on' { $A.enabled | Should -BeTrue; $A.dry_run | Should -BeTrue }
    It 'legacy risk cap moved to config at 1.5 (unchanged behaviour)' { $Cfg.max_risk_pct_cap | Should -Be 1.5; $Cfg.max_risk_pct | Should -Be 1.0; $Cfg.max_positions | Should -Be 3 }
    It 'floor = 0.80 x start' { Near $A.dd_floor_equity ([Math]::Round(0.8 * $A.dd_start_equity, 2)) 0.01 }
}

Describe 'Legacy Get-PositionSize cap from config' {
    It 'caps at maxRiskCap' {
        $s = Get-PositionSize -equity 100000 -entry 100 -stop 90 -maxRiskPct 1.0 -edgeMultiplier 3 -maxRiskCap 1.5
        $s.EffectiveRiskPct | Should -Be 1.5; $s.Shares | Should -Be 150
        $s2 = Get-PositionSize -equity 100000 -entry 100 -stop 90 -maxRiskPct 1.0 -edgeMultiplier 3 -maxRiskCap 2.0
        $s2.Shares | Should -Be 200
    }
}

Describe 'Stock sizing' {
    It '1.5% risk on $95,554' {
        $s = Get-AggrStockSize -equity 95554.16 -buyingPower 0 -entry 50 -stop 45 -a $A
        $s.RiskPct | Should -Be 1.5; $s.Shares | Should -Be 286   # 1433.31/5
    }
    It 'cap 2.0% with edge/regime multipliers' {
        (Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 90 -a $A -edgeMult 2.0).RiskPct | Should -Be 2.0
    }
    It 'dd multiplier halves' { (Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 90 -a $A -ddMult 0.5).Shares | Should -Be 75 }
    It '25% notional cap binds on tight stop' {
        $s = Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 99.5 -a $A
        $s.Shares | Should -Be 250; $s.CappedBy | Should -Be 'notional'
    }
    It 'BP/6*0.8 cap binds' { (Get-AggrStockSize -equity 100000 -buyingPower 30000 -entry 100 -stop 90 -a $A).Shares | Should -Be 40 }
    It 'short side sizes the same' { (Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 110 -a $A).Shares | Should -Be 150 }
}

Describe 'Heat' {
    It 'sums stock risk and call value' {
        $h = Get-AggrHeat @(@{Kind='stock';Side='long';Qty=100;Entry=50;Stop=45}, @{Kind='call';MarketValue=900}, @{Kind='stock';Side='long';Qty=10;Entry=50;Stop=55})
        $h | Should -Be 1400
    }
    It '8% cap' { Test-AggrHeatOk 7000 1000 100000 $A | Should -BeTrue; Test-AggrHeatOk 7000 1001 100000 $A | Should -BeFalse }
}

Describe 'Drawdown floor and throttles' {
    It 'normal' { $d = Get-AggrDdState 95000 $A; $d.Tier | Should -Be 'NORMAL'; $d.Mult | Should -Be 1.0; $d.MaxPositions | Should -Be 6 }
    It '-10% throttle1' { $d = Get-AggrDdState 85998 $A; $d.Tier | Should -Be 'THROTTLE1'; $d.Mult | Should -Be 0.5; $d.MaxPositions | Should -Be 4; $d.CallsAllowed | Should -BeFalse }
    It '-15% throttle2' { $d = Get-AggrDdState 81000 $A; $d.Tier | Should -Be 'THROTTLE2'; $d.Mult | Should -Be 0.25; $d.MaxPositions | Should -Be 2 }
    It 'halt at floor exactly' { (Get-AggrDdState 76443.33 $A).Halted | Should -BeTrue }
    It 'just above floor is not halted' { (Get-AggrDdState 76443.34 $A).Halted | Should -BeFalse }
    It 'stays halted after recovery (sticky)' { (Get-AggrDdState 99000 $A $true).Halted | Should -BeTrue }
}

Describe 'Call eligibility and selection' {
    BeforeAll { $script:dd = Get-AggrDdState 95000 $A }
    It 'eligible top-tier BULL' { Test-AggrCallEligible ([pscustomobject]@{Side='buy';Strategy='BRKOUT';Confidence=95}) 'BULL' 3.5 $A $dd 0 | Should -BeNullOrEmpty }
    It 'conf 89 -> CONF' { Test-AggrCallEligible ([pscustomobject]@{Side='buy';Strategy='BRKOUT';Confidence=89}) 'BULL' 3.5 $A $dd 0 | Should -Be 'CONF' }
    It 'NEUTRAL -> REGIME' { Test-AggrCallEligible ([pscustomobject]@{Side='buy';Strategy='PULLBK';Confidence=95}) 'NEUTRAL' 3.5 $A $dd 0 | Should -Be 'REGIME' }
    It 'rs 2.9 -> RS' { Test-AggrCallEligible ([pscustomobject]@{Side='buy';Strategy='PULLBK';Confidence=95}) 'BULL' 2.9 $A $dd 0 | Should -Be 'RS' }
    It '2 calls open -> MAX_CALLS' { Test-AggrCallEligible ([pscustomobject]@{Side='buy';Strategy='PULLBK';Confidence=95}) 'BULL' 4 $A $dd 2 | Should -Be 'MAX_CALLS' }
    It 'throttle -> DD_THROTTLE' { Test-AggrCallEligible ([pscustomobject]@{Side='buy';Strategy='PULLBK';Confidence=95}) 'BULL' 4 $A (Get-AggrDdState 85000 $A) 0 | Should -Be 'DD_THROTTLE' }
    It 'short -> SIDE' { Test-AggrCallEligible ([pscustomobject]@{Side='sell';Strategy='BRKDN';Confidence=95}) 'BULL' 4 $A $dd 0 | Should -Be 'SIDE' }
    It 'filters and ranks' {
        $chain = @(
            (C 'A' 30 0.65 5.0 5.2),          # DTE too short
            (C 'B' 45 0.55 5.0 5.2),          # delta too low
            (C 'C' 45 0.65 5.0 5.2 100),      # OI too low
            (C 'D' 45 0.65 5.0 5.2 1000 10),  # volume too low
            (C 'E' 45 0.65 5.0 5.6),          # spread 11.3% / $0.60
            (C 'F' 52 0.65 5.0 5.2),          # ok, dte dist 7
            (C 'G' 44 0.70 5.0 5.2),          # ok, dte dist 1, delta dist .05
            (C 'H' 46 0.66 5.0 5.2)           # ok, dte dist 1, delta dist .01  <- best
        )
        (Select-AggrCallContract $chain $A).Occ | Should -Be 'H'
    }
    It 'none -> null' { Select-AggrCallContract @((C 'A' 30 0.65 5 5.2)) $A | Should -BeNullOrEmpty }
    It 'bid 0 rejected' { Select-AggrCallContract @((C 'A' 45 0.65 0 5.2)) $A | Should -BeNullOrEmpty }
    It 'limit ladder never above ask' {
        Get-AggrCallLimit 5.0 5.4 0 | Should -Be 5.2; Get-AggrCallLimit 5.0 5.4 1 | Should -Be 5.3; Get-AggrCallLimit 5.0 5.4 2 | Should -Be 5.4; Get-AggrCallLimit 5.0 5.4 9 | Should -Be 5.4
    }
    It 'call size 1% budget' {
        $s = Get-AggrCallSize 95554.16 4.10 $A; $s.Budget | Should -Be 955.54; $s.Contracts | Should -Be 2
        (Get-AggrCallSize 95554.16 9.60 $A).Contracts | Should -Be 0
    }
    It 'payload shape' {
        $p = New-AggrCallOrderPayload 'NVDA261127C00180000' 2 4.1 'NVDA' 'SWCALL' 'buy' '202610141000'
        $p.type | Should -Be 'limit'; $p.time_in_force | Should -Be 'day'; $p.limit_price | Should -Be '4.10'
        $p.client_order_id | Should -Be 'SWCALL_NVDA_202610141000'
        (($p.client_order_id -split '_')[0]) | Should -Be 'SWCALL'
    }
    It 'OCC underlying parse' { Get-OccUnderlying 'NVDA261127C00180000' | Should -Be 'NVDA'; Get-OccUnderlying 'NVDA' | Should -BeNullOrEmpty }
}

Describe 'Exits' {
    BeforeAll {
        function X($o = @{}) {
            $x = @{ UnderPx = 105; StockStop = 95; UnderEntry = 100; R = 5; EntryPremium = 4.0; Bid = 4.5; Dte = 40; DaysHeld = 3
                    EarningsBeforeNextSession = $false; PartialDone = $false; LastClose = 105; HighestClose = 106; Atr = 2; Contracts = 2 }
            foreach ($k in $o.Keys) { $x[$k] = $o[$k] }; return $x
        }
    }
    It 'hold' { (Get-AggrCallExitDecision (X) $A).Action | Should -Be 'HOLD' }
    It 'underlying stop' { (Get-AggrCallExitDecision (X @{UnderPx=95}) $A).Reason | Should -Be 'UNDERLYING_STOP' }
    It 'premium -50%' { (Get-AggrCallExitDecision (X @{Bid=2.0}) $A).Reason | Should -Be 'PREMIUM_STOP' }
    It 'DTE 21' { (Get-AggrCallExitDecision (X @{Dte=21}) $A).Reason | Should -Be 'DTE' }
    It '12 days' { (Get-AggrCallExitDecision (X @{DaysHeld=12}) $A).Reason | Should -Be 'MAX_HOLD' }
    It 'earnings' { (Get-AggrCallExitDecision (X @{EarningsBeforeNextSession=$true}) $A).Reason | Should -Be 'EARNINGS' }
    It 'half at +2R' { $d = Get-AggrCallExitDecision (X @{UnderPx=110}) $A; $d.Action | Should -Be 'SELL_PARTIAL'; $d.Qty | Should -Be 1 }
    It '1 contract at +2R exits all' { (Get-AggrCallExitDecision (X @{UnderPx=110; Contracts=1}) $A).Action | Should -Be 'EXIT_ALL' }
    It 'trail after partial' {
        (Get-AggrCallExitDecision (X @{PartialDone=$true; UnderPx=112; LastClose=112; HighestClose=118}) $A).Reason | Should -Be 'TRAIL'   # trail = max(105,114)
        (Get-AggrCallExitDecision (X @{PartialDone=$true; UnderPx=115; LastClose=115; HighestClose=118}) $A).Action | Should -Be 'HOLD'
    }
    It 'stock 1/3 partial at +2R once' {
        Get-AggrStockPartialQty 2.0 682 $false $A | Should -Be 227
        Get-AggrStockPartialQty 1.9 682 $false $A | Should -Be 0
        Get-AggrStockPartialQty 3.0 682 $true  $A | Should -Be 0
        Get-AggrStockPartialQty 2.0 1 $false $A | Should -Be 0
    }
    It 'stock payload uses dummy 10R TP' {
        $p = New-AggrStockOrderPayload 'AI' 'buy' 100 11.98 11.07 10 'BRKOUT' '100000'
        $p.take_profit.limit_price | Should -Be '21.08'; $p.order_class | Should -Be 'bracket'; $p.time_in_force | Should -Be 'gtc'
    }
}

Describe 'Dry-run guard' {
    It 'refuses POST/PATCH/DELETE when dry_run' {
        { Invoke-AggrApi $Cfg 'POST' '/v2/orders' @{} } | Should -Throw '*DRY-RUN GUARD*'
        { Invoke-AggrApi $Cfg 'PATCH' '/v2/orders/x' @{} } | Should -Throw '*DRY-RUN GUARD*'
        { Invoke-AggrApi $Cfg 'DELETE' '/v2/orders/x' } | Should -Throw '*DRY-RUN GUARD*'
    }
    It 'missing dry_run flag defaults to dry' { Test-AggrDryRun ([pscustomobject]@{ aggr = [pscustomobject]@{ enabled = $true } }) | Should -BeTrue }
    It 'manage in dry run (AI migration + partial) writes journal and sends no order' {
        $script:AggrSkipJournal = Join-Path $TestDrive 'skips.jsonl'
        Mock Invoke-AlpacaApi { param($cfg,$method,$path,$body) if ($method -ne 'GET') { throw "LIVE CALL $method" }; return @() }
        Mock Get-LiveExitLegs { @{ stop = 11.07; target = 15.17 } }
        Mock Get-AggrJournalOpen { [pscustomobject]@{ symbol = 'AI'; stop = 11.07 } }
        Mock Get-EasternTime { [datetime]'2026-10-14T10:00:00' }
        $st = [pscustomobject]@{}; Initialize-AggrState $st
        $pos = [pscustomobject]@{ symbol='AI'; asset_class='us_equity'; qty='682'; side='long'; avg_entry_price='11.98'; current_price='13.90' }  # +2.1R
        Invoke-AggrManage $Cfg $st @($pos) @($pos)
        Invoke-AggrManage $Cfg $st @($pos) @($pos)   # second scan same day: migration not re-logged
        $lines = @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json })
        @($lines | Where-Object skip_reason -eq 'DRYRUN_MIGRATE').Count | Should -Be 1
        ($lines | Where-Object skip_reason -eq 'DRYRUN_MIGRATE').new_tp | Should -Be 21.08
        @($lines | Where-Object skip_reason -eq 'DRYRUN_PARTIAL').Count | Should -Be 2
        ($lines | Where-Object skip_reason -eq 'DRYRUN_PARTIAL' | Select-Object -First 1).payload.qty | Should -Be '227'
        @($st.aggr_migrated).Count | Should -Be 0
        @($st.aggr_partial_done).Count | Should -Be 0
        Should -Invoke Invoke-AlpacaApi -ParameterFilter { $method -ne 'GET' } -Times 0 -Exactly
    }
    It 'entries in dry run: call payload logged with quote caveat, no orders, sim state tracked' {
        $script:AggrSkipJournal = Join-Path $TestDrive 'skips2.jsonl'
        Mock Invoke-AlpacaApi { param($cfg,$method,$path,$body) if ($method -ne 'GET') { throw "LIVE CALL $method" }; return @() }
        Mock Get-EasternTime { [datetime]'2026-10-14T11:00:00' }
        Mock Get-TickerMemoryInfo { $null }
        Mock Test-EarningsBlackout { $false }
        Mock Test-AggrEarningsBefore { $false }
        Mock Get-DailyBars { @(1..80 | ForEach-Object { [pscustomobject]@{ Close = 100 } }) }
        Mock Get-RelativeStrength { 4.0 }
        Mock Get-SwingBestSignal { [pscustomobject]@{ Strategy='BRKOUT'; Side='buy'; Entry=100; Stop=95; Confidence=95; Reason='t' } }
        Mock Get-AggrCallChain { @((C 'NVDA261127C00100000' 45 0.65 4.0 4.2)) }
        Mock Get-AggrOpusUnderlyings { @{ 'MSFT' = $true } }
        $cfg2 = $Cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $cfg2.adaptive_sizing = $false
        $st = [pscustomobject]@{ losses = 0; equity_at_open = 95554.16; active_watchlist = @(); aggr_watchlist = @('SPY','MSFT','NVDA','AMD') }
        Initialize-AggrState $st; $st.aggr_watchlist = @('SPY','MSFT','NVDA','AMD')
        Invoke-AggrEntries $cfg2 $st ([pscustomobject]@{ Regime='BULL'; SizeMult=1.0 }) @() 95554.16 190000 @() @() @{}
        $l = @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json })
        ($l | Where-Object sym -eq 'SPY').skip_reason  | Should -Be 'INDEX_ANCHOR'
        ($l | Where-Object sym -eq 'MSFT').skip_reason | Should -Be 'OPUS_CONFLICT'
        $n = $l | Where-Object sym -eq 'NVDA'
        $n.skip_reason | Should -Be 'DRYRUN_ENTERED'; $n.instrument | Should -Be 'call'
        $n.payload.limit_price | Should -Be '4.10'; $n.payload.qty | Should -Be '2'; $n.quote_caveat | Should -Match 'FREE indicative'
        ($l | Where-Object sym -eq 'AMD').skip_reason | Should -Be 'ONE_PER_SCAN'
        @($st.aggr_dry_entered).Count | Should -Be 1
        Should -Invoke Invoke-AlpacaApi -ParameterFilter { $method -ne 'GET' } -Times 0 -Exactly
    }
}
