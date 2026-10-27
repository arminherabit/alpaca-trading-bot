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
    # v1.1 exit settings (partial 1/3 at +2R, dummy 10R TP): the partial machinery
    # stays in the code for a future re-enable, so its tests run against this copy.
    $script:Cfg11 = $script:Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $script:Cfg11.aggr.dry_run = $true   # dry-run behavioural tests keep an explicit dry copy
    $script:Cfg11.aggr.partial_exit_r = 2.0; $script:Cfg11.aggr.dummy_tp_r = 10.0
    $script:A11 = $script:Cfg11.aggr
    function Near($x, $y, $t = 1e-6) { [Math]::Abs([double]$x - [double]$y) | Should -BeLessOrEqual $t }
    function C($occ, $dte, $delta, $bid, $ask, $oi = 1000, $vol = 100) {
        [pscustomobject]@{ Occ = $occ; Expiration = '2026-11-27'; Dte = $dte; Delta = $delta; Bid = $bid; Ask = $ask; Oi = $oi; Volume = $vol }
    }
}

Describe 'Config' {
    It 'ships with aggr enabled AND dry_run off (live paper)' { $A.enabled | Should -BeTrue; $A.dry_run | Should -BeFalse }
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
    It '1.75% risk on $95,554 (v1.2 Variant I)' {
        $s = Get-AggrStockSize -equity 95554.16 -buyingPower 0 -entry 50 -stop 45 -a $A
        $s.RiskPct | Should -Be 1.75; $s.Shares | Should -Be 334   # 1672.20/5
    }
    It 'cap 2.0% with edge/regime multipliers' {
        (Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 90 -a $A -edgeMult 2.0).RiskPct | Should -Be 2.0
    }
    It 'dd multiplier halves' { (Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 90 -a $A -ddMult 0.5).Shares | Should -Be 87 }   # 0.875% of 100k / 10
    It '25% notional cap binds on tight stop' {
        $s = Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 99.5 -a $A
        $s.Shares | Should -Be 250; $s.CappedBy | Should -Be 'notional'
    }
    It 'BP/bp_cap_divisor*0.8 cap binds (30000 / 5 * 0.8 -> 48 sh)' { (Get-AggrStockSize -equity 100000 -buyingPower 30000 -entry 100 -stop 90 -a $A).Shares | Should -Be 48 }
    It 'changing max_positions does not change size' {
        $a2 = $A | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $a2.max_positions = 3
        $a3 = $A | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $a3.max_positions = 20
        foreach ($x in $a2, $a3) { (Get-AggrStockSize -equity 100000 -buyingPower 30000 -entry 100 -stop 90 -a $x).Shares | Should -Be 48 }
    }
    It 'short side sizes the same' { (Get-AggrStockSize -equity 100000 -buyingPower 0 -entry 100 -stop 110 -a $A).Shares | Should -Be 175 }
}

Describe 'Heat' {
    It 'sums stock risk and call value' {
        $h = Get-AggrHeat @(@{Kind='stock';Side='long';Qty=100;Entry=50;Stop=45}, @{Kind='call';MarketValue=900}, @{Kind='stock';Side='long';Qty=10;Entry=50;Stop=55})
        $h | Should -Be 1400
    }
    It '15% cap' { Test-AggrHeatOk 14000 1000 100000 $A | Should -BeTrue; Test-AggrHeatOk 14000 1001 100000 $A | Should -BeFalse }
}

Describe 'Drawdown floor and throttles' {
    It 'normal' { $d = Get-AggrDdState 95000 $A; $d.Tier | Should -Be 'NORMAL'; $d.Mult | Should -Be 1.0; $d.MaxPositions | Should -Be 11 }
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
        Get-AggrStockPartialQty 2.0 682 $false $A11 | Should -Be 227
        Get-AggrStockPartialQty 1.9 682 $false $A11 | Should -Be 0
        Get-AggrStockPartialQty 3.0 682 $true  $A11 | Should -Be 0
        Get-AggrStockPartialQty 2.0 1 $false $A11 | Should -Be 0
    }
    It 'stock payload uses dummy 10R TP and AGSW client_order_id' {
        $p = New-AggrStockOrderPayload 'AI' 'buy' 100 11.98 11.07 10 'BRKOUT' '100000'
        $p.take_profit.limit_price | Should -Be '21.08'; $p.order_class | Should -Be 'bracket'; $p.time_in_force | Should -Be 'gtc'
        $p.client_order_id | Should -Be 'AGSW_AI_100000'
        (($p.client_order_id -split '_')[0]) | Should -Be 'AGSW'
    }
}

Describe 'Dry-run guard' {
    It 'refuses POST/PATCH/DELETE when dry_run' {
        $dry = $Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $dry.aggr.dry_run = $true
        { Invoke-AggrApi $dry 'POST' '/v2/orders' @{} } | Should -Throw '*DRY-RUN GUARD*'
        { Invoke-AggrApi $dry 'PATCH' '/v2/orders/x' @{} } | Should -Throw '*DRY-RUN GUARD*'
        { Invoke-AggrApi $dry 'DELETE' '/v2/orders/x' } | Should -Throw '*DRY-RUN GUARD*'
    }
    It 'ships live (dry_run false) so the guard does not fire on POST' {
        Mock Invoke-AlpacaApi { param($cfg,$method,$path,$body) return @{ id = 'x' } }
        { Invoke-AggrApi $Cfg 'POST' '/v2/orders' @{} } | Should -Not -Throw
    }
    It 'missing dry_run flag defaults to dry' { Test-AggrDryRun ([pscustomobject]@{ aggr = [pscustomobject]@{ enabled = $true } }) | Should -BeTrue }
    It 'manage in dry run (AI migration + partial, v1.1 exits) writes journal and sends no order' {
        $script:AggrSkipJournal = Join-Path $TestDrive 'skips.jsonl'
        Mock Invoke-AlpacaApi {
            param($cfg,$method,$path,$body)
            if ($method -ne 'GET') { throw "LIVE CALL $method" }
            if ($path -like '/v2/orders?status=all&nested=true*') {
                return @([pscustomobject]@{ id = 'p1'; symbol = 'AI'; side = 'buy'; status = 'filled'; type = 'limit'; legs = @(
                    [pscustomobject]@{ id = 'tp1'; symbol = 'AI'; side = 'sell'; status = 'new';  type = 'limit'; limit_price = '15.17'; qty = '682' },
                    [pscustomobject]@{ id = 'sl1'; symbol = 'AI'; side = 'sell'; status = 'held'; type = 'stop';  stop_price  = '11.07'; qty = '682' }) })
            }
            return @()
        }
        Mock Get-LiveExitLegs { @{ stop = 11.07; target = 15.17 } }
        Mock Get-AggrJournalOpen { [pscustomobject]@{ symbol = 'AI'; stop = 11.07 } }
        Mock Get-EasternTime { [datetime]'2026-10-14T10:00:00' }
        $st = [pscustomobject]@{}; Initialize-AggrState $st
        $pos = [pscustomobject]@{ symbol='AI'; asset_class='us_equity'; qty='682'; side='long'; avg_entry_price='11.98'; current_price='13.90' }  # +2.1R
        Invoke-AggrManage $Cfg11 $st @($pos) @($pos)
        Invoke-AggrManage $Cfg11 $st @($pos) @($pos)   # second scan same day: migration not re-logged
        $lines = @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json })
        @($lines | Where-Object skip_reason -eq 'DRYRUN_MIGRATE').Count | Should -Be 1
        ($lines | Where-Object skip_reason -eq 'DRYRUN_MIGRATE').new_tp | Should -Be 21.08
        $plan = @($lines | Where-Object skip_reason -eq 'DRYRUN_PARTIAL')
        $plan.Count | Should -Be 8   # CANCEL_EXITS, PROTECT, SELL, VERIFY on each of the two scans
        (@($plan | Select-Object -First 4) | ForEach-Object step) -join ',' | Should -Be 'CANCEL_EXITS,PROTECT,SELL,VERIFY'
        (@($plan | Where-Object step -eq 'CANCEL_EXITS')[0].orders | ForEach-Object id) -join ',' | Should -Be 'tp1,sl1'
        $pr = @($plan | Where-Object step -eq 'PROTECT')[0]
        $pr.payload.order_class | Should -Be 'oco'; $pr.payload.qty | Should -Be '455'
        $pr.payload.stop_loss.stop_price | Should -Be '11.07'; $pr.payload.take_profit.limit_price | Should -Be '15.17'
        $pr.fallback_payload.type | Should -Be 'stop'; $pr.fallback_payload.qty | Should -Be '455'
        $sell = @($plan | Where-Object step -eq 'SELL')[0]
        $sell.payload.qty | Should -Be '227'; $sell.payload.type | Should -Be 'market'; $sell.payload.client_order_id | Should -Be 'PARTIAL_AI_20261014'
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
        # Live-price guard is covered in its own Describe; pass the signal through here.
        Mock Update-SignalForLivePrice { param($cfg, $symbol, $dailyBars, $regimeName, $spyBars, $signal) [pscustomobject]@{ Action = 'OK'; Signal = $signal; Mid = $signal.Entry; DriftPct = 0; SpreadPct = 0.1; AgeSec = 1; Reason = '' } }
        Mock Get-RelativeStrength { 4.0 }
        Mock Get-SwingBestSignal { [pscustomobject]@{ Strategy='BRKOUT'; Side='buy'; Entry=100; Stop=95; Confidence=95; Reason='t' } }
        Mock Get-AggrCallChain { @((C 'NVDA261127C00100000' 45 0.65 4.0 4.2)) }
        Mock Get-AggrOpusUnderlyings { @{ 'MSFT' = $true } }
        $cfg2 = $Cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $cfg2.aggr.dry_run = $true; $cfg2.adaptive_sizing = $false
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
        @($st.aggr_shadow_open).Count | Should -Be 1; $st.aggr_shadow_open[0].stop | Should -Be 95; $st.aggr_shadow_open[0].qty | Should -Be 2
        Should -Invoke Invoke-AlpacaApi -ParameterFilter { $method -ne 'GET' } -Times 0 -Exactly
    }
}

Describe 'Stock partial with an open bracket (live path, mocked broker)' {
    BeforeAll {
        $script:AggrPollDelayMs = 0
        $script:CfgLive = $Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $script:CfgLive.aggr.dry_run = $false
        $script:CfgLive.aggr.partial_exit_r = 2.0   # partial mechanics under the v1.1 exit (v1.2 ships with it off)
        function O($id, $type, $grp, $extra = @{}) {
            $h = [ordered]@{ id = $id; symbol = 'AI'; side = 'sell'; status = 'new'; type = $type; qty = '682'; group = $grp }
            foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }; [pscustomobject]$h
        }
        function Live { @($script:B.Orders | Where-Object { @('canceled','filled','expired','rejected') -notcontains $_.status }) }
        function LiveStops { @(Live | Where-Object { @('stop','trailing_stop') -contains $_.type }) }
        function Posts { @($script:B.Calls | Where-Object { $_ -like 'POST*' }) }
        function Journal { @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json }) }
    }
    BeforeEach {
        $script:AggrSkipJournal = Join-Path $TestDrive ("p_{0}.jsonl" -f [guid]::NewGuid().ToString('N'))
        # A filled 682-share AI long with its live bracket: TP 15.17, stop 11.07 (one OCO group).
        $script:B = @{
            Orders = [System.Collections.ArrayList]@(
                (O 'tp1' 'limit' 'g0' @{ limit_price = '15.17' }),
                (O 'sl1' 'stop'  'g0' @{ stop_price = '11.07'; status = 'held' }))
            Calls = [System.Collections.ArrayList]@(); Bodies = [System.Collections.ArrayList]@()
            Fail = @{ Cancel = $false; CancelStuck = $false; Sell = $false; SellPartial = 0; Oco = 0; Stop = 0 }
            Sold = 0; Seq = 0; SellOrder = $null; PosQty = 682; Open = $true
        }
        Mock Get-EasternTime { [datetime]'2026-10-14T11:00:00' }
        Mock Invoke-AlpacaApi {
            param($cfg, $method, $path, $body)
            $B = $script:B; [void]$B.Calls.Add(("{0} {1}" -f $method, $path))
            if ($method -eq 'GET') {
                if ($path -eq '/v2/clock') { return [pscustomobject]@{ is_open = $B.Open } }
                if ($path -like '/v2/orders?status=all&nested=true*') { return @($B.Orders | ForEach-Object { $_ }) }
                if ($path -like '/v2/orders:by_client_order_id*') { return $null }
                if ($path -like '/v2/positions/*') { return [pscustomobject]@{ qty = [string]($B.PosQty - $B.Sold) } }
                if ($path -like '/v2/orders/*') { return $B.SellOrder }
                return @()
            }
            if ($method -eq 'DELETE') {
                $id = $path.Split('/')[-1]
                if ($B.SellOrder -and $id -eq $B.SellOrder.id) { $B.SellOrder.status = 'canceled'; return $null }
                if ($B.Fail.Cancel) { throw '422 order is not cancelable' }
                $o = @($B.Orders | Where-Object { $_.id -eq $id })[0]
                if ($null -eq $o) { throw '404 order not found' }
                foreach ($x in $B.Orders) {   # cancelling one leg cancels its whole group
                    if ($x.group -eq $o.group -and @('canceled','filled') -notcontains $x.status) {
                        $x.status = if ($B.Fail.CancelStuck) { 'pending_cancel' } else { 'canceled' }
                    }
                }
                return $null
            }
            if ($method -eq 'POST') {
                [void]$B.Bodies.Add($body); $B.Seq++
                if ($body.type -eq 'market') {
                    if ($B.Fail.Sell) { throw '403 insufficient qty available for order' }
                    $f = if ($B.Fail.SellPartial -gt 0) { $B.Fail.SellPartial } else { [int]$body.qty }
                    $B.Sold = $f
                    $B.SellOrder = [pscustomobject]@{ id = 'sell1'; status = $(if ($B.Fail.SellPartial -gt 0) { 'partially_filled' } else { 'filled' })
                                                       filled_qty = [string]$f; qty = $body.qty; client_order_id = $body.client_order_id }
                    return $B.SellOrder
                }
                $g = "g$($B.Seq)"
                if ($body.order_class -eq 'oco') {
                    if ($B.Fail.Oco -gt 0) { $B.Fail.Oco = $B.Fail.Oco - 1; throw '422 oco rejected' }
                    $tp = O "tpN$($B.Seq)" 'limit' $g @{ limit_price = $body.take_profit.limit_price; qty = $body.qty }
                    [void]$B.Orders.Add($tp)
                    [void]$B.Orders.Add((O "slN$($B.Seq)" 'stop' $g @{ stop_price = $body.stop_loss.stop_price; qty = $body.qty; status = 'held' }))
                    return $tp
                }
                if ($body.type -eq 'stop') {
                    if ($B.Fail.Stop -gt 0) { $B.Fail.Stop = $B.Fail.Stop - 1; throw '422 stop rejected' }
                    $s = O "stN$($B.Seq)" 'stop' $g @{ stop_price = $body.stop_price; qty = $body.qty }
                    [void]$B.Orders.Add($s); return $s
                }
                if ($body.type -eq 'trailing_stop') {
                    $s = O "trN$($B.Seq)" 'trailing_stop' $g @{ trail_percent = $body.trail_percent; qty = $body.qty }
                    [void]$B.Orders.Add($s); return $s
                }
            }
            return $null
        }
        $script:Pos = [pscustomobject]@{ symbol = 'AI'; asset_class = 'us_equity'; qty = '682'; side = 'long'; avg_entry_price = '11.98'; current_price = '13.90' }
        $script:St = [pscustomobject]@{}; Initialize-AggrState $script:St
    }

    It 'success: cancel bracket, OCO on 455 BEFORE selling 227, one protection left' {
        $r = Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11
        $r.Outcome | Should -Be 'DONE'; $r.Sold | Should -Be 227; $r.Protect.Kind | Should -Be 'oco'
        @(Posts).Count | Should -Be 2
        $B.Bodies[0].order_class | Should -Be 'oco'; $B.Bodies[0].qty | Should -Be '455'
        $B.Bodies[0].stop_loss.stop_price | Should -Be '11.07'; $B.Bodies[0].take_profit.limit_price | Should -Be '15.17'
        $B.Bodies[1].type | Should -Be 'market'; $B.Bodies[1].qty | Should -Be '227'; $B.Bodies[1].client_order_id | Should -Be 'PARTIAL_AI_20261014'
        # Unprotected window: only "are the legs gone?" polls between the last cancel and the protection POST.
        $calls = @($B.Calls)
        $iPost = @(0..($calls.Count - 1) | Where-Object { $calls[$_] -like 'POST*' })[0]
        $iDel  = @(0..($iPost - 1) | Where-Object { $calls[$_] -like 'DELETE*' })[-1]
        @(($iDel + 1)..($iPost - 1) | Where-Object { $calls[$_] -notlike 'GET /v2/orders?status=all*' }).Count | Should -Be 0
        @(LiveStops).Count | Should -Be 1; (LiveStops)[0].qty | Should -Be '455'
        @($St.aggr_partial_done) | Should -Contain 'AI'
        @($St.aggr_protect_restore).Count | Should -Be 0
        @(Journal | Where-Object skip_reason -eq 'PARTIAL_DONE').Count | Should -Be 1
    }

    It 'never sells twice: a second manage pass the same day sends no sell' {
        Mock Get-AggrJournalOpen { [pscustomobject]@{ symbol = 'AI'; stop = 11.07 } }
        Mock Get-LiveExitLegs { @{ stop = 11.07; target = 15.17 } }
        Invoke-AggrManage $CfgLive $St @($Pos) @($Pos)
        $pos2 = [pscustomobject]@{ symbol = 'AI'; asset_class = 'us_equity'; qty = '455'; side = 'long'; avg_entry_price = '11.98'; current_price = '14.10' }
        Invoke-AggrManage $CfgLive $St @($pos2) @($pos2)
        @($B.Bodies | Where-Object { $_.type -eq 'market' }).Count | Should -Be 1
    }

    It 'cancel failure: bracket stays, nothing is sold or placed, no retry today' {
        $B.Fail.Cancel = $true
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'ABORTED_CANCEL'
        @(Posts).Count | Should -Be 0
        (@(Live) | ForEach-Object id) -join ',' | Should -Be 'tp1,sl1'
        @($St.aggr_partial_failed) | Should -Contain '20261014:AI'
        @($St.aggr_protect_restore).Count | Should -Be 0     # still fully protected by the bracket
        $n = $B.Calls.Count
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'SKIPPED_FAILED_TODAY'
        $B.Calls.Count | Should -Be $n
    }

    It 'cancel stuck in pending_cancel: aborts, queues a restore, next pass re-covers the full position' {
        $B.Fail.CancelStuck = $true
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'ABORTED_CANCEL'
        @(Posts).Count | Should -Be 0
        @($St.aggr_protect_restore | ForEach-Object sym) | Should -Contain 'AI'
        foreach ($x in $B.Orders) { if ($x.status -eq 'pending_cancel') { $x.status = 'canceled' } }   # broker finishes the cancel
        $B.Fail.CancelStuck = $false
        Invoke-AggrProtectRestore $CfgLive $St @($Pos)
        @(LiveStops).Count | Should -Be 1; (LiveStops)[0].qty | Should -Be '682'; (LiveStops)[0].stop_price | Should -Be '11.07'
        @($St.aggr_protect_restore).Count | Should -Be 0
    }

    It 'sell rejected: no double sell, protection resized back to the full 682' {
        $B.Fail.Sell = $true
        $r = Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11
        $r.Outcome | Should -Be 'SELL_REJECTED'; $r.Error | Should -Match 'insufficient qty'
        @($B.Bodies | Where-Object { $_.type -eq 'market' }).Count | Should -Be 1
        @(LiveStops).Count | Should -Be 1; (LiveStops)[0].qty | Should -Be '682'
        @($St.aggr_partial_done).Count | Should -Be 0
        @($St.aggr_partial_failed) | Should -Contain '20261014:AI'
        @(Journal | Where-Object skip_reason -eq 'PARTIAL_SELL_REJECTED').Count | Should -Be 1
    }

    It 'partial fill: 100 of 227 sold, rest of the sell cancelled, protection resized to 582' {
        $B.Fail.SellPartial = 100
        $r = Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11
        $r.Outcome | Should -Be 'PARTIAL_FILL'; $r.Sold | Should -Be 100
        $B.Calls | Should -Contain 'DELETE /v2/orders/sell1'
        @(LiveStops).Count | Should -Be 1; (LiveStops)[0].qty | Should -Be '582'
        @($St.aggr_partial_done) | Should -Contain 'AI'     # never re-sold
        @($B.Bodies | Where-Object { $_.type -eq 'market' }).Count | Should -Be 1
    }

    It 're-place failure: OCO rejected twice -> plain stop fallback on 455, then sells' {
        $B.Fail.Oco = 2
        $r = Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11
        $r.Outcome | Should -Be 'DONE'; $r.Protect.Kind | Should -Be 'stop'; $r.Protect.Fallback | Should -BeTrue; $r.Protect.Attempts | Should -Be 3
        @(Live).Count | Should -Be 1; (Live)[0].type | Should -Be 'stop'; (Live)[0].qty | Should -Be '455'; (Live)[0].stop_price | Should -Be '11.07'
        @(Journal | Where-Object skip_reason -eq 'PARTIAL_PROTECT_FALLBACK').Count | Should -Be 1
    }

    It 're-place failure on 455: does not sell, re-covers all 682' {
        $B.Fail.Oco = 99; $B.Fail.Stop = 2
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'ABORTED_PROTECT'
        @($B.Bodies | Where-Object { $_.type -eq 'market' }).Count | Should -Be 0
        @(LiveStops).Count | Should -Be 1; (LiveStops)[0].qty | Should -Be '682'
    }

    It 'total re-place failure: no sell, loud alert, restore queued' {
        $B.Fail.Oco = 99; $B.Fail.Stop = 99
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'UNPROTECTED'
        @($B.Bodies | Where-Object { $_.type -eq 'market' }).Count | Should -Be 0
        @($St.aggr_protect_restore | ForEach-Object sym) | Should -Contain 'AI'
        @(Journal | Where-Object skip_reason -eq 'PARTIAL_UNPROTECTED').Count | Should -Be 1
    }

    It 'trailing stop (legacy +2R conversion) is re-placed as a trailing stop on the kept shares' {
        $B.Orders.Clear(); [void]$B.Orders.Add((O 'tr0' 'trailing_stop' 'gT' @{ trail_percent = '3.5'; stop_price = '13.41' }))
        $r = Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11
        $r.Outcome | Should -Be 'DONE'; $r.Protect.Kind | Should -Be 'trail'
        @(Live).Count | Should -Be 1; (Live)[0].type | Should -Be 'trailing_stop'; (Live)[0].qty | Should -Be '455'; (Live)[0].trail_percent | Should -Be '3.5'
    }

    It 'market closed: deferred, nothing cancelled' {
        $B.Open = $false
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'DEFERRED'
        @($B.Calls | Where-Object { $_ -ne 'GET /v2/clock' }).Count | Should -Be 0
    }

    It 'no live stop: aborts without touching orders' {
        $B.Orders.Clear(); [void]$B.Orders.Add((O 'tp9' 'limit' 'g9' @{ limit_price = '15.17' }))
        (Invoke-AggrStockPartial $CfgLive $St $Pos 227 2.11).Outcome | Should -Be 'ABORTED_NO_STOP'
        @($B.Calls | Where-Object { $_ -like 'DELETE*' -or $_ -like 'POST*' }).Count | Should -Be 0
    }
}

Describe 'Extension logging (no gate)' {
    BeforeAll {
        # 60 completed days: High 100, Low 98, Close 99 (true range 2 -> ATR 2), then
        # today's bar closing at 104: 2.0 ATR and 4% above the 20-day high of 100.
        function ExtBars([double]$todayClose = 104) {
            try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
            catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
            $today = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).Date
            $b = @(60..1 | ForEach-Object { [pscustomobject]@{ Time = $today.AddDays(-$_); Open = 99; High = 100; Low = 98; Close = 99; Volume = 1e6 } })
            $b + [pscustomobject]@{ Time = $today; Open = 101; High = $todayClose + 1; Low = 99; Close = $todayClose; Volume = 2e6 }
        }
    }
    It 'matches the BRKOUT signal basis: completed days only, ATR(14), current close' {
        $x = Get-AggrExtension (ExtBars 104)
        $x.extension_atr | Should -Be 2.0; $x.pct_above_20d_high | Should -Be 4.0
        $y = Get-AggrExtension (ExtBars 97)    # below the 20-day high: negative, still logged
        $y.extension_atr | Should -Be (-1.5); $y.pct_above_20d_high | Should -Be (-3.0)
    }
    It 'never throws: missing or short bars give nulls' {
        $n = Get-AggrExtension $null; $n.extension_atr | Should -BeNullOrEmpty; $n.pct_above_20d_high | Should -BeNullOrEmpty
        (Get-AggrExtension @((ExtBars)[0..9])).extension_atr | Should -BeNullOrEmpty
        (Get-AggrExtension @(1..80 | ForEach-Object { [pscustomobject]@{ Close = 100 } })).extension_atr | Should -BeNullOrEmpty   # no Time/High
    }
    It 'dry run: BRKOUT skip lines and every DRYRUN_ENTERED line carry the fields; decisions unchanged; no orders' {
        $script:AggrSkipJournal = Join-Path $TestDrive 'ext.jsonl'
        Mock Invoke-AlpacaApi { param($cfg,$method,$path,$body) if ($method -ne 'GET') { throw "LIVE CALL $method" }; return @() }
        Mock Get-EasternTime { [datetime]'2026-10-15T11:00:00' }
        Mock Get-TickerMemoryInfo { $null }
        Mock Test-EarningsBlackout { $false }
        Mock Get-RelativeStrength { 4.0 }
        Mock Get-AggrOpusUnderlyings { @{} }
        Mock Get-DailyBars { ExtBars 104 }
        Mock Get-Quote { [pscustomobject]@{ Symbol = 'X'; BidPrice = 103.98; AskPrice = 104.02; MidPrice = 104.0; Time = [datetime]::UtcNow.AddSeconds(-2) } }   # fresh, at the signal price
        Mock Get-SwingBestSignal {
            param($cfg, $symbol)
            switch ($symbol) {
                'BRK1' { [pscustomobject]@{ Strategy = 'BRKOUT'; Side = 'buy'; Entry = 104; Stop = 100; Confidence = 70; Reason = 't' } }   # < NEUTRAL floor 80
                'PUL1' { [pscustomobject]@{ Strategy = 'PULLBK'; Side = 'buy'; Entry = 104; Stop = 100; Confidence = 70; Reason = 't' } }   # < floor, not BRKOUT
                'PUL2' { [pscustomobject]@{ Strategy = 'PULLBK'; Side = 'buy'; Entry = 104; Stop = 100; Confidence = 90; Reason = 't' } }   # enters
            }
        }
        $cfg2 = $Cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $cfg2.aggr.dry_run = $true; $cfg2.adaptive_sizing = $false
        $st = [pscustomobject]@{ losses = 0; equity_at_open = 95554.16; active_watchlist = @() }
        Initialize-AggrState $st; $st.aggr_watchlist = @('BRK1', 'PUL1', 'PUL2')
        Invoke-AggrEntries $cfg2 $st ([pscustomobject]@{ Regime = 'NEUTRAL'; SizeMult = 1.0 }) @() 95554.16 190000 @() @() @{}
        $l = @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json })
        $b = $l | Where-Object sym -eq 'BRK1'
        $b.skip_reason | Should -Be 'CONF_FLOOR'; $b.extension_atr | Should -Be 2.0; $b.pct_above_20d_high | Should -Be 4.0
        $p1 = $l | Where-Object sym -eq 'PUL1'
        $p1.skip_reason | Should -Be 'CONF_FLOOR'; $p1.PSObject.Properties.Name | Should -Not -Contain 'extension_atr'
        $p2 = $l | Where-Object sym -eq 'PUL2'
        $p2.skip_reason | Should -Be 'DRYRUN_ENTERED'; $p2.extension_atr | Should -Be 2.0; $p2.pct_above_20d_high | Should -Be 4.0
        $p2.payload.qty | Should -Be '229'    # 25% notional cap (23,888.54 / $104) binds before 1.5% risk (358): sizing untouched
        Should -Invoke Invoke-AlpacaApi -ParameterFilter { $method -ne 'GET' } -Times 0 -Exactly
    }
}

Describe 'Aggr ownership tags' {
    It 'AGSW and SWCALL are owned; legacy BRKOUT is not' {
        Test-AggrOwnedCoid 'AGSW_V_100000' | Should -BeTrue
        Test-AggrOwnedCoid 'SWCALL_NVDA_202610141000' | Should -BeTrue
        Test-AggrOwnedCoid 'BRKOUT_PFE_140116' | Should -BeFalse
        Test-AggrOwnedCoid 'PULLBK_NKE_140118' | Should -BeFalse
        Test-AggrOwnedCoid '' | Should -BeFalse
    }
    It 'MY_ENTRY_PREFIXES keeps AGSW/SWCALL for journal/foreign scoping (not legacy exits)' {
        $MY_ENTRY_PREFIXES -contains 'AGSW' | Should -BeTrue
        $MY_ENTRY_PREFIXES -contains 'SWCALL' | Should -BeTrue
        $MY_ENTRY_PREFIXES -contains 'BRKOUT' | Should -BeTrue
        $MY_ENTRY_PREFIXES -contains 'PULLBK' | Should -BeTrue
    }
}

Describe 'Select-LegacyManagedPositions (one owner per position)' {
    BeforeAll {
        function Pos($sym, $cls = 'us_equity') {
            [pscustomobject]@{ symbol = $sym; asset_class = $cls; qty = '10'; side = 'long'; avg_entry_price = '100' }
        }
    }
    It 'keeps BRKOUT/PULLBK legacy stocks and drops AGSW stocks + SWCALL options' {
        $book = @(
            (Pos 'NKE'), (Pos 'PFE'), (Pos 'V'),
            (Pos 'TSLA'),                          # AGSW-owned
            (Pos 'NVDA261127C00180000' 'us_option') # SWCALL
        )
        $aggrOwned = @{ TSLA = $true; 'NVDA261127C00180000' = $true }
        $got = Select-LegacyManagedPositions $book $aggrOwned
        $syms = @($got | ForEach-Object { $_.symbol })
        $syms | Should -Be @('NKE','PFE','V')
    }
    It 'returns empty when aggr ownership is unknown (null) so legacy touches nothing' {
        $book = @((Pos 'NKE'), (Pos 'TSLA'))
        @(Select-LegacyManagedPositions $book $null).Count | Should -Be 0
    }
    It 'returns empty when every stock is AGSW-owned' {
        $book = @((Pos 'TSLA'), (Pos 'XLE'))
        $aggrOwned = @{ TSLA = $true; XLE = $true }
        @(Select-LegacyManagedPositions $book $aggrOwned).Count | Should -Be 0
    }
    It 'returns all stocks when aggr owns nothing (empty hashtable)' {
        $book = @((Pos 'NKE'), (Pos 'PFE'))
        $got = Select-LegacyManagedPositions $book @{}
        @($got | ForEach-Object { $_.symbol }) | Should -Be @('NKE','PFE')
    }
    It 'never returns us_option rows even if missing from aggrOwned' {
        $book = @((Pos 'NKE'), (Pos 'NVDA261127C00180000' 'us_option'))
        $got = Select-LegacyManagedPositions $book @{}
        @($got | ForEach-Object { $_.symbol }) | Should -Be @('NKE')
    }
}
