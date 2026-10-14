# tests/swing_aggr_shadow.Tests.ps1 -- shadow book reconciliation (AEHL bug, 2026-10-14). No network.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    foreach ($f in 'alpaca_client','alpaca_indicators','alpaca_swing_signals','alpaca_risk','alpaca_screener','alpaca_earnings','alpaca_journal','alpaca_swing_aggr') {
        . (Join-Path $script:Root "$f.ps1")
    }
    if (-not (Get-Command Get-WeekdayCount -ErrorAction SilentlyContinue)) { function Get-WeekdayCount([datetime]$from, [datetime]$to) { 0 } }
    $script:Cfg = Get-Content (Join-Path $script:Root 'alpaca_config.json') -Raw | ConvertFrom-Json
    $script:A = $script:Cfg.aggr
    function Bar($t, $o, $h, $l, $c) { [pscustomobject]@{ Time = [datetime]::Parse($t).ToUniversalTime(); Open = $o; High = $h; Low = $l; Close = $c } }
    function AEHL { New-AggrShadow 'AEHL' 'stock' 'buy' 29.00 26.83 50.70 426 924.42 '2026-10-14T14:10:30.2748987Z' }
}

Describe 'Bar-model exits' {
    It 'stop hit -> STOP at stop' {
        $x = Get-AggrShadowBarExit (AEHL) @((Bar '2026-10-14T14:15:00Z' 28.5 28.9 27.5 27.8), (Bar '2026-10-14T14:20:00Z' 27.8 27.9 26.5 26.6))
        $x.Reason | Should -Be 'STOP'; $x.Price | Should -Be 26.83
    }
    It 'gap through stop fills at the open' { (Get-AggrShadowBarExit (AEHL) @((Bar '2026-10-14T14:20:00Z' 25.64 26.0 25.5 25.9))).Price | Should -Be 25.64 }
    It 'bars at/before opened_at are ignored' { Get-AggrShadowBarExit (AEHL) @((Bar '2026-10-14T14:10:00Z' 28 29 20 21)) | Should -BeNullOrEmpty }
    It 'target hit' { $x = Get-AggrShadowBarExit (AEHL) @((Bar '2026-10-15T14:00:00Z' 49 51 48 50)); $x.Reason | Should -Be 'TARGET'; $x.Price | Should -Be 50.70 }
    It 'stop and target in same bar -> STOP' { (Get-AggrShadowBarExit (AEHL) @((Bar '2026-10-15T14:00:00Z' 30 55 26 50))).Reason | Should -Be 'STOP' }
    It 'short mirror' {
        $s = New-AggrShadow 'X' 'stock' 'sell' 100 105 50 10 50 '2026-10-14T14:00:00Z'
        $x = Get-AggrShadowBarExit $s @((Bar '2026-10-14T14:05:00Z' 106 107 104 106)); $x.Reason | Should -Be 'STOP'; $x.Price | Should -Be 106
        (Get-AggrShadowPnl $s 106).Pnl | Should -Be -60
    }
    It 'no hit -> null' { Get-AggrShadowBarExit (AEHL) @((Bar '2026-10-14T14:15:00Z' 29 30 28 29.5)) | Should -BeNullOrEmpty }
}

Describe 'Live reconciliation' {
    It 'filled closing stop leg through the stop is used (real slippage)' {
        $co = @([pscustomobject]@{ id='o1'; symbol='AEHL'; status='filled'; side='sell'; filled_at='2026-10-14T14:18:00Z'; filled_avg_price='25.64' })
        $x = Resolve-AggrShadowExit (AEHL) @((Bar '2026-10-14T14:15:00Z' 28 28.5 26.0 26.2)) $co 0 $A
        $x.Source | Should -Be 'LIVE_FILL'; $x.Price | Should -Be 25.64; $x.BarPrice | Should -Be 26.83
        (Get-AggrShadowPnl (AEHL) 25.64).Pnl | Should -Be -1431.36
    }
    It 'live fill without bars (bar feed gap) still closes the shadow' {
        $co = @([pscustomobject]@{ id='o1'; symbol='AEHL'; status='filled'; side='sell'; filled_at='2026-10-14T14:18:00Z'; filled_avg_price='25.64' })
        (Resolve-AggrShadowExit (AEHL) @() $co 0 $A).Source | Should -Be 'LIVE_FILL'
    }
    It 'live fill above the stop (e.g. legacy time stop) is ignored' {
        $co = @([pscustomobject]@{ id='o1'; symbol='AEHL'; status='filled'; side='sell'; filled_at='2026-10-14T14:18:00Z'; filled_avg_price='28.10' })
        Resolve-AggrShadowExit (AEHL) @() $co 0 $A | Should -BeNullOrEmpty
    }
    It 'fills before the shadow opened and buy-side fills are ignored' {
        $co = @([pscustomobject]@{ symbol='AEHL'; status='filled'; side='sell'; filled_at='2026-10-14T14:00:00Z'; filled_avg_price='20' },
                [pscustomobject]@{ symbol='AEHL'; status='filled'; side='buy';  filled_at='2026-10-14T14:20:00Z'; filled_avg_price='20' })
        Get-AggrShadowLiveExit (AEHL) $co | Should -BeNullOrEmpty
    }
    It 'time stop after hold_days_max uses last close' {
        $x = Resolve-AggrShadowExit (AEHL) @((Bar '2026-10-30T19:55:00Z' 30 30.2 29.8 30.1)) @() 12 $A
        $x.Reason | Should -Be 'TIME'; $x.Price | Should -Be 30.1
    }
}

Describe 'Update-AggrShadowBook (dry run, read-only)' {
    BeforeEach {
        $script:AggrSkipJournal = Join-Path $TestDrive ("j{0}.jsonl" -f [guid]::NewGuid().ToString('N'))
        Mock Invoke-AlpacaApi { param($cfg,$method,$path,$body) if ($method -ne 'GET') { throw "LIVE CALL $method" }
            if ($path -like '*symbols=AEHL*') { return @([pscustomobject]@{ id='p'; symbol='AEHL'; status='filled'; side='buy'; filled_at='2026-10-14T14:10:40Z'; filled_avg_price='29.00'
                legs = @([pscustomobject]@{ id='sl'; symbol='AEHL'; status='filled'; side='sell'; filled_at='2026-10-14T14:20:22Z'; filled_avg_price='25.64' }) }) }
            return @() }
        Mock Get-Bars { param($cfg,$symbol) if ($symbol -eq 'PFE') { @((Bar '2026-10-14T15:00:00Z' 29.3 29.6 29.1 29.5)) } else { @() } }
        Mock Get-WeekdayCount { 0 }
    }
    It 'AEHL day-1 replay: closes AEHL via the live stop leg, keeps PFE open, no orders' {
        $st = [pscustomobject]@{}; Initialize-AggrState $st
        $st.aggr_shadow_open = @((AEHL), (New-AggrShadow 'PFE' 'stock' 'buy' 29.20 28.18 39.40 814 830.28 '2026-10-14T14:01:16Z'))
        Update-AggrShadowBook $Cfg $st @()
        @($st.aggr_shadow_open).Count | Should -Be 1; $st.aggr_shadow_open[0].sym | Should -Be 'PFE'
        $st.aggr_shadow_realized | Should -Be -1431.36
        $j = Get-Content $script:AggrSkipJournal | ConvertFrom-Json
        $j.skip_reason | Should -Be 'DRYRUN_EXIT'; $j.source | Should -Be 'LIVE_FILL'; $j.r_multiple | Should -Be -1.55
        Should -Invoke Invoke-AlpacaApi -ParameterFilter { $method -ne 'GET' } -Times 0 -Exactly
    }
    It 'migrates old {sym,kind,risk_usd} entries from the journal payload' {
        @{ sym='AEHL'; skip_reason='DRYRUN_ENTERED'; ts='2026-10-14T14:10:30.2748987Z'
           payload=@{ symbol='AEHL'; qty='426'; side='buy'; limit_price='29.00'; take_profit=@{limit_price='50.70'}; stop_loss=@{stop_price='26.83'} } } |
            ConvertTo-Json -Depth 5 -Compress | Set-Content $script:AggrSkipJournal
        $st = [pscustomobject]@{}; Initialize-AggrState $st
        $st.aggr_dry_entered = @([pscustomobject]@{ sym='AEHL'; kind='stock'; risk_usd=924.42 })
        Convert-AggrLegacyDryEntered $st
        @($st.aggr_dry_entered).Count | Should -Be 0
        $st.aggr_shadow_open[0].stop | Should -Be 26.83; $st.aggr_shadow_open[0].qty | Should -Be 426
    }
    It 'shadow holdings survive the ET day roll (no daily wipe)' {
        Mock Get-EasternTime { [datetime]'2026-10-15T09:00:00' }
        $st = [pscustomobject]@{ losses = 0; equity_at_open = 95000; active_watchlist = @() }; Initialize-AggrState $st
        $st.aggr_day = '2026-10-14'; $st.aggr_shadow_open = @((AEHL)); $st.aggr_watchlist = @('SPY')
        Mock Get-AggrOpusUnderlyings { @{} }
        Invoke-AggrEntries $Cfg $st ([pscustomobject]@{ Regime='BULL'; SizeMult=1.0 }) @() 95000 190000 @() @() @{}
        @($st.aggr_shadow_open).Count | Should -Be 1; $st.aggr_trades_today | Should -Be 0
    }
}
