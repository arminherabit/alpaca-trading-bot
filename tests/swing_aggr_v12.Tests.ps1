# tests/swing_aggr_v12.Tests.ps1 -- Pester 5. Swing Aggressive v1.2 "Variant I":
# config, dry-run slot/heat double-count fix, partial off + real 3.5R TP,
# BRKOUT extension gate, planned-R logging, unfilled-entry journaling. No network.
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
    $JournalPath = Join-Path $TestDrive 'journal.json'          # never the real journal
    $script:Cfg = Get-Content (Join-Path $script:Root 'alpaca_config.json') -Raw | ConvertFrom-Json
    $script:A = $script:Cfg.aggr

    # Cancel-StaleEntries lives in alpaca_bot.ps1 (a script with a main body), so
    # load just that function from the AST.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'alpaca_bot.ps1'), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Cancel-StaleEntries','Test-EntryCancelConfirmed') }, $true)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    # Broker double for Cancel-StaleEntries: open-order list, DELETE, order re-check, position, account.
    function StaleBroker([string]$recheckStatus = 'canceled', [string]$recheckFilled = '0', [bool]$deleteThrows = $false, $position = $null) {
        $script:SB = @{ Status = $recheckStatus; Filled = $recheckFilled; DelThrows = $deleteThrows; Pos = $position }
        Mock Get-EasternTime { [datetime]'2026-10-16T10:00:00' }
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body)
            if ($method -eq 'DELETE') { if ($script:SB.DelThrows) { throw '422 order not cancelable' }; return $null }
            if ($path -like '/v2/orders?status=open*') { return @([pscustomobject]@{ id = 'o1'; symbol = 'UNH'; order_class = 'bracket'; filled_qty = '0'; created_at = '2026-10-15T13:50:25Z' }) }
            if ($path -eq '/v2/orders/o1') { return [pscustomobject]@{ id = 'o1'; symbol = 'UNH'; status = $script:SB.Status; filled_qty = $script:SB.Filled } }
            if ($path -eq '/v2/positions/UNH') { return $script:SB.Pos }
            if ($path -eq '/v2/account') { return [pscustomobject]@{ equity = '94339.09' } }
            return $null }
    }

    function Bars([double]$todayClose) {
        try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
        catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
        $today = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).Date   # ET session date, as Split-DailyBars
        $b = @(60..1 | ForEach-Object { [pscustomobject]@{ Time = $today.AddDays(-$_); Open = 11.5; High = 12.0; Low = 10.915; Close = 11.5; Volume = 1e5 } })
        $b + [pscustomobject]@{ Time = $today; Open = 11.9; High = [Math]::Max(12.1, $todayClose); Low = 11.8; Close = $todayClose; Volume = 2e6 }
    }
    function Sig([double]$entry, [double]$stop) {
        [pscustomobject]@{ Strategy = 'BRKOUT'; Side = 'buy'; Entry = $entry; Stop = $stop; T1 = $entry + 3.5 * ($entry - $stop); T2 = $entry + 3.5 * ($entry - $stop)
                           RR = 3.5; Confidence = 95; Reason = '20d-high break'; Valid = $true }
    }
    function Shadow($sym, $entry, $stop, $qty) { $s = New-AggrShadow $sym 'stock' 'buy' $entry $stop ($entry + 10) $qty ($qty * ($entry - $stop)) '2026-10-14T14:01:16Z'; $s.filled = $true; $s }
    function LivePos($sym, $entry, $qty) { [pscustomobject]@{ symbol = $sym; asset_class = 'us_equity'; qty = "$qty"; side = 'long'; avg_entry_price = "$entry"; current_price = "$entry"; market_value = "$($entry*$qty)" } }

    function RunEntries($cfg, $shadows, $myPos, [double]$close, [double]$entry, [double]$stop) {
        $script:AggrSkipJournal = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.jsonl')
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body) if ($method -ne 'GET') { throw "LIVE CALL $method" }; return @() }
        Mock Get-TickerMemoryInfo { $null }
        Mock Test-EarningsBlackout { $false }
        Mock Get-RelativeStrength { 8.5 }
        Mock Get-AggrOpusUnderlyings { @{} }
        Mock Get-LiveExitLegs { @{ stop = 1.0; target = $null } }
        Mock Test-AggrCallEligible { 'REGIME' }
        $script:TBars = Bars $close; $script:TSig = Sig $entry $stop
        Mock Get-DailyBars { $script:TBars }
        Mock Get-SwingBestSignal { $script:TSig }
        Mock Update-SignalForLivePrice { [pscustomobject]@{ Action = 'OK'; Mid = $script:TSig.Entry; DriftPct = 0; SpreadPct = 0.1; AgeSec = 1; Signal = $script:TSig } }
        $st = [pscustomobject]@{ losses = 0; equity_at_open = 95000; active_watchlist = @() }
        Initialize-AggrState $st; $st.aggr_watchlist = @('ABBV'); $st.aggr_shadow_open = @($shadows)
        Invoke-AggrEntries $cfg $st ([pscustomobject]@{ Regime = 'BULL'; SizeMult = 1.0 }) @() 95000 190000 @($myPos) @($myPos) @{}
        $l = @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json })
        return [pscustomobject]@{ Line = ($l | Where-Object sym -eq 'ABBV' | Select-Object -Last 1); State = $st }
    }
}

Describe 'v1.2 config (Variant I, calls kept)' {
    It 'sizes, slots and limits' {
        $A.enabled | Should -BeTrue; $A.dry_run | Should -BeTrue
        $A.max_risk_pct | Should -Be 1.75; $A.max_risk_pct_cap | Should -Be 2.0
        $A.max_stock_positions | Should -Be 10; $A.max_call_positions | Should -Be 1; $A.max_positions | Should -Be 11
        $A.call_enabled | Should -BeTrue; $A.max_trades_per_day | Should -Be 2
        $A.partial_exit_r | Should -Be 0; $A.dummy_tp_r | Should -Be 3.5; $A.max_extension_atr | Should -Be 3.0
    }
    It 'unchanged guard rails' {
        $A.max_portfolio_heat_pct | Should -Be 15.0; $A.max_notional_pct | Should -Be 25.0; $A.bp_cap_divisor | Should -Be 5; $A.dd_floor_equity | Should -Be 76443.33
        $A.dd_throttle1_pct | Should -Be 10.0; $A.dd_throttle2_pct | Should -Be 15.0; $A.call_min_conf | Should -Be 90
        $Cfg.pyramiding_enabled | Should -BeFalse
    }
}

Describe 'Fix 1: dry-run slots/heat from the shadow book only' {
    It 'legacy-held PFE/NKE + their shadow copies = 2 stock slots, not 4' {
        $sh = @((Shadow 'PFE' 29.20 28.18 814), (Shadow 'NKE' 37.83 35.58 206))
        $b = Get-AggrSlotBook $Cfg ([pscustomobject]@{ aggr_shadow_open = $sh }) @((LivePos 'PFE' 29.2 605), (LivePos 'NKE' 37.83 137)) $true
        $b.StockCount | Should -Be 2; $b.CallCount | Should -Be 0
    }
    It 'shadow stocks are booked as stock risk qty x (entry - stop)' {
        $sh = @((Shadow 'PFE' 29.20 28.18 814), (Shadow 'NKE' 37.83 35.58 206))
        $b = Get-AggrSlotBook $Cfg ([pscustomobject]@{ aggr_shadow_open = $sh }) @() $true
        @($b.HeatItems | Where-Object { $_.Kind -eq 'stock' }).Count | Should -Be 2
        [Math]::Round((Get-AggrHeat $b.HeatItems), 2) | Should -Be ([Math]::Round(814 * 1.02 + 206 * 2.25, 2))
    }
    It 'shadow calls count as call slots at their premium' {
        $c = New-AggrShadow 'META' 'call' 'buy' 700 680 $null 1 950 '2026-10-14T14:01:16Z'
        $b = Get-AggrSlotBook $Cfg ([pscustomobject]@{ aggr_shadow_open = @($c) }) @() $true
        $b.CallCount | Should -Be 1; $b.StockCount | Should -Be 0; Get-AggrHeat $b.HeatItems | Should -Be 950
    }
    It 'live mode counts the live book' {
        Mock Get-LiveExitLegs { @{ stop = 28.18; target = $null } }
        $b = Get-AggrSlotBook $Cfg ([pscustomobject]@{ aggr_shadow_open = @() }) @((LivePos 'PFE' 29.2 605)) $false
        $b.StockCount | Should -Be 1
    }
    It 'ABBV is entered with PFE+NKE held live and shadowed (was STOCK_SLOTS_FULL)' {
        $r = RunEntries $Cfg @((Shadow 'PFE' 29.20 28.18 814), (Shadow 'NKE' 37.83 35.58 206)) @((LivePos 'PFE' 29.2 605), (LivePos 'NKE' 37.83 137)) 12.3 12.3 10.13
        $r.Line.skip_reason | Should -Be 'DRYRUN_ENTERED'
        @($r.State.aggr_shadow_open).Count | Should -Be 3
    }
    It 'ten shadow stocks fill the 10 stock slots' {
        $sh = @('S1','S2','S3','S4','S5','S6','S7','S8','S9','S10' | ForEach-Object { Shadow $_ 100 99 10 })
        $r = RunEntries $Cfg $sh @() 12.3 12.3 10.13
        $r.Line.skip_reason | Should -Be 'STOCK_SLOTS_FULL'
    }
    It 'nine shadow stocks still leave a 10th stock slot' {
        $sh = @('S1','S2','S3','S4','S5','S6','S7','S8','S9' | ForEach-Object { Shadow $_ 100 99 10 })
        $r = RunEntries $Cfg $sh @() 12.3 12.3 10.13
        $r.Line.skip_reason | Should -Be 'DRYRUN_ENTERED'
    }
}

Describe 'Fix 2: partial off, 3.5R take-profit is real' {
    It 'partial_exit_r 0 never sells a partial' {
        foreach ($r in 0.5, 2.0, 3.4, 10) { Get-AggrStockPartialQty $r 682 $false $A | Should -Be 0 }
    }
    It 'missing partial_exit_r also means off' {
        Get-AggrStockPartialQty 3.0 682 $false ([pscustomobject]@{ partial_exit_fraction = 0.3333 }) | Should -Be 0
    }
    It 'bracket TP leg sits at entry + 3.5R' {
        $p = New-AggrStockOrderPayload 'ABBV' 'buy' 82 288.81 275.95 ([double]$A.dummy_tp_r) 'BRKOUT' '100000'
        $p.take_profit.limit_price | Should -Be '333.82'   # 288.81 + 3.5 x 12.86
    }
    It 'dry-run shadow takes the 3.5R target as an exit' {
        $p = New-AggrStockOrderPayload 'X' 'buy' 10 100 90 ([double]$A.dummy_tp_r) 'BRKOUT' '1'
        $sh = New-AggrShadow 'X' 'stock' 'buy' 100 90 ([double]$p.take_profit.limit_price) 10 100 '2026-10-14T14:00:00Z'
        $x = Get-AggrShadowBarExit $sh @([pscustomobject]@{ Time = [datetime]'2026-10-15T15:00:00Z'; Open = 120; High = 136; Low = 119; Close = 134 })
        $x.Reason | Should -Be 'TARGET'; $x.Price | Should -Be 135
    }
}

Describe 'Fix 3: BRKOUT extension gate' {
    It 'pure gate' {
        Test-AggrExtensionGate 3.0 $A | Should -BeTrue
        Test-AggrExtensionGate 3.01 $A | Should -BeFalse
        Test-AggrExtensionGate $null $A | Should -BeTrue
        Test-AggrExtensionGate 50 ([pscustomobject]@{ max_extension_atr = 0 }) | Should -BeTrue
    }
    It 'an 11.9-ATR breakout (AEHL-like) is skipped as EXTENSION before any order or shadow' {
        $r = RunEntries $Cfg @() @() 29.0 29.0 26.83
        $r.Line.skip_reason | Should -Be 'EXTENSION'; [double]$r.Line.extension_atr | Should -BeGreaterThan 3.0
        @($r.State.aggr_shadow_open).Count | Should -Be 0
    }
}

Describe 'Fix 4: R from the planned stop distance' {
    It 'AEHL: limit 29.00 / stop 26.83, filled 26.84, out 25.64 = -0.55R (was -119.9R)' {
        $sh = New-AggrShadow 'AEHL' 'stock' 'buy' 29.0 26.83 50.7 426 924.42 '2026-10-14T14:10:30Z'
        $sh.entry = 26.84
        $pp = Get-AggrShadowPnl $sh 25.64
        $pp.R | Should -Be -0.55; $pp.Pnl | Should -Be -511.2
    }
    It 'no limit on record -> risk_usd / qty' {
        $sh = [pscustomobject]@{ sym = 'Z'; kind = 'stock'; side = 'buy'; entry = 10.0; stop = 9.99; qty = 100; risk_usd = 100.0 }
        [double](Get-AggrShadowPnl $sh 9.0).R | Should -Be -1
    }
}

Describe 'Fix 5: unfilled entries are journaled as UNFILLED' {
    BeforeEach {
        $j = [pscustomobject]@{ open = @(
                [pscustomobject]@{ opened_at = '2026-10-15T13:50:26Z'; symbol = 'UNH'; strategy = 'BRKOUT'; side = 'buy'; entry = 405.12; stop = 383.37; qty = 21; risk_usd = 456.75 },
                [pscustomobject]@{ opened_at = '2026-10-14T14:01:17Z'; symbol = 'PFE'; strategy = 'BRKOUT'; side = 'buy'; entry = 29.2; stop = 28.18; qty = 605; risk_usd = 617.1 })
              closed = @() }
        $j | ConvertTo-Json -Depth 6 | Set-Content $JournalPath
    }
    It 'moves only the matching row to journal.unfilled' {
        $r = Set-JournalUnfilled -symbol 'UNH' -orderCreatedAt '2026-10-15T13:50:25Z'
        $r.outcome | Should -Be 'UNFILLED'
        $j = Load-Journal
        @($j.open).Count | Should -Be 1; $j.open[0].symbol | Should -Be 'PFE'
        @($j.unfilled).Count | Should -Be 1; $j.unfilled[0].symbol | Should -Be 'UNH'
        @($j.closed).Count | Should -Be 0
    }
    It 'a row outside the time window is left alone' {
        Set-JournalUnfilled -symbol 'UNH' -orderCreatedAt '2026-10-17T13:50:25Z' | Should -BeNullOrEmpty
        @((Load-Journal).open).Count | Should -Be 2
    }
    It 'Cancel-StaleEntries: normal path (canceled, 0 fill, no position) journals UNFILLED' {
        StaleBroker
        Cancel-StaleEntries ([pscustomobject]@{}) @{}
        Should -Invoke Invoke-AlpacaApi -Times 1 -Exactly -ParameterFilter { $method -eq 'DELETE' }
        $j = Load-Journal
        @($j.unfilled).Count | Should -Be 1; @($j.open | Where-Object symbol -eq 'UNH').Count | Should -Be 0
    }
    It 'Cancel-StaleEntries: DELETE fails -> journal untouched, no re-check' {
        StaleBroker -deleteThrows $true
        Cancel-StaleEntries ([pscustomobject]@{}) @{}
        @((Load-Journal).open).Count | Should -Be 2; @((Load-Journal).unfilled | Where-Object { $_ }).Count | Should -Be 0
        Should -Invoke Invoke-AlpacaApi -Times 0 -Exactly -ParameterFilter { $path -eq '/v2/orders/o1' -and $method -eq 'GET' }
    }
    It 'Cancel-StaleEntries: fill race (re-check shows filled_qty > 0) -> journal untouched' {
        StaleBroker -recheckStatus 'filled' -recheckFilled '21'
        Cancel-StaleEntries ([pscustomobject]@{}) @{}
        @((Load-Journal).open | Where-Object symbol -eq 'UNH').Count | Should -Be 1; @((Load-Journal).unfilled | Where-Object { $_ }).Count | Should -Be 0
    }
    It 'Cancel-StaleEntries: position appeared after cancel -> journal untouched' {
        StaleBroker -position ([pscustomobject]@{ symbol = 'UNH'; qty = '21' })
        Cancel-StaleEntries ([pscustomobject]@{}) @{}
        @((Load-Journal).unfilled | Where-Object { $_ }).Count | Should -Be 0
    }
    It 'Cancel-StaleEntries: still pending_cancel -> journal untouched' {
        StaleBroker -recheckStatus 'pending_cancel'
        Cancel-StaleEntries ([pscustomobject]@{}) @{}
        @((Load-Journal).unfilled | Where-Object { $_ }).Count | Should -Be 0
    }
    It 'a held symbol (live protection) is never canceled or journaled' {
        Mock Get-EasternTime { [datetime]'2026-10-16T10:00:00' }
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body)
            if ($method -eq 'GET') { return @([pscustomobject]@{ id = 'o1'; symbol = 'UNH'; order_class = 'bracket'; filled_qty = '0'; created_at = '2026-10-15T13:50:25Z' }) }
            return $null }
        Cancel-StaleEntries ([pscustomobject]@{}) @{ UNH = $true }
        Should -Invoke Invoke-AlpacaApi -Times 0 -Exactly -ParameterFilter { $method -eq 'DELETE' }
        @((Load-Journal).open).Count | Should -Be 2
    }
}
