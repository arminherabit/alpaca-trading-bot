# tests/entry_live_price.Tests.ps1 -- Pester 5. Stale-signal entry guard and the
# post-fill stop re-place, built around the AEHL 2026-10-14 entry. No network.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'alpaca_client.ps1')
    . (Join-Path $script:Root 'alpaca_indicators.ps1')
    . (Join-Path $script:Root 'alpaca_swing_signals.ps1')
    . (Join-Path $script:Root 'alpaca_risk.ps1')
    . (Join-Path $script:Root 'alpaca_screener.ps1')
    . (Join-Path $script:Root 'alpaca_earnings.ps1')
    . (Join-Path $script:Root 'alpaca_swing_aggr.ps1')
    $JournalPath = Join-Path $TestDrive 'journal.json'          # never the real journal
    function Close-PositionNow($cfg, $pos) { }                  # lives in alpaca_bot.ps1; stub so it can be mocked
    $script:Cfg = Get-Content (Join-Path $script:Root 'alpaca_config.json') -Raw | ConvertFrom-Json
    $script:Ec  = Get-EntryCheckCfg $script:Cfg
    $script:T0  = [datetime]::SpecifyKind([datetime]'2026-10-14T14:10:32', 'Utc')   # AEHL bracket submitted

    # 60 completed days with true range 1.085 (ATR 1.085, as AEHL's 2 x ATR = 2.17 stop),
    # then today's bar at the stale IEX print 29.00.
    function AehlBars([double]$todayClose = 29.0) {
        try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
        catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
        $today = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).Date
        $b = @(60..1 | ForEach-Object { [pscustomobject]@{ Time = $today.AddDays(-$_); Open = 11.5; High = 12.0; Low = 10.915; Close = 11.5; Volume = 1e5 } })
        $b + [pscustomobject]@{ Time = $today; Open = 24.17; High = 29.7; Low = 10.99; Close = $todayClose; Volume = 2e6 }
    }
    function AehlSignal([double]$entry = 29.0, [double]$stop = 26.83) {
        [pscustomobject]@{ Strategy = 'BRKOUT'; Side = 'buy'; Entry = $entry; Stop = $stop; T1 = 36.6; T2 = 36.6; RR = 3.5; Confidence = 80; Reason = '20d-high break'; Valid = $true }
    }
    # The IEX quote that was actually latest at 14:10:32: 14:05:42, bid 29.70 / ask 33.81.
    $script:AehlStaleQuote = [pscustomobject]@{ BidPrice = 29.70; AskPrice = 33.81; MidPrice = 31.755; Time = [datetime]::SpecifyKind([datetime]'2026-10-14T14:05:42.944', 'Utc') }
    function Fresh([double]$mid, [double]$halfSpread = 0.01, [int]$ageSec = 2) {
        [pscustomobject]@{ BidPrice = $mid - $halfSpread; AskPrice = $mid + $halfSpread; MidPrice = $mid; Time = $script:T0.AddSeconds(-$ageSec) }
    }
}

Describe 'Live quote quality' {
    It 'the real AEHL quote at submit time is unusable (290 s old, 12.9% wide)' {
        $q = Test-EntryQuote $AehlStaleQuote $Ec $T0
        $q.Ok | Should -BeFalse; $q.AgeSec | Should -BeGreaterThan 280; $q.Reason | Should -Match 'old'
    }
    It 'fresh tight quote is usable; wide, crossed, one-sided and untimed are not' {
        (Test-EntryQuote (Fresh 26.84) $Ec $T0).Ok | Should -BeTrue
        (Test-EntryQuote (Fresh 26.84 0.5) $Ec $T0).Reason | Should -Match 'spread'
        (Test-EntryQuote ([pscustomobject]@{ BidPrice = 27; AskPrice = 26.9; Time = $T0 }) $Ec $T0).Reason | Should -Match 'crossed'
        (Test-EntryQuote ([pscustomobject]@{ BidPrice = 0; AskPrice = 26.9; Time = $T0 }) $Ec $T0).Reason | Should -Match 'one-sided'
        (Test-EntryQuote ([pscustomobject]@{ BidPrice = 26.8; AskPrice = 26.9; Time = $null }) $Ec $T0).Reason | Should -Match 'timestamp'
    }
    It 'config carries the thresholds' {
        $Cfg.entry_max_slippage_pct | Should -Be 1.0; $Ec.MaxQuoteAgeSec | Should -Be 60; $Ec.MaxSpreadPct | Should -Be 2.0; $Ec.MinStopAtr | Should -Be 0.5
    }
}

Describe 'Update-SignalForLivePrice (pre-submit)' {
    BeforeEach { Mock Get-SwingBestSignal { param($cfg, $symbol, $dailyBars) $c = [double]$dailyBars[-1].Close; AehlSignal $c ([Math]::Round($c - 2.17, 2)) } }

    It 'AEHL as it happened (signal 29.00, stale IEX quote): STALE_SIGNAL, no order' {
        $r = Update-SignalForLivePrice $Cfg 'AEHL' (AehlBars) 'BULL' @() (AehlSignal) $AehlStaleQuote $T0
        $r.Action | Should -Be 'STALE_SIGNAL'; $r.Reason | Should -Match 'quote unusable'
        Should -Invoke Get-SwingBestSignal -Times 0 -Exactly
    }
    It 'AEHL with a fresh quote at the real market 26.84: repriced, stop 2.17 under the live entry -- never $0.01' {
        $r = Update-SignalForLivePrice $Cfg 'AEHL' (AehlBars) 'BULL' @() (AehlSignal) (Fresh 26.84) $T0
        $r.Action | Should -Be 'REPRICED'; $r.DriftPct | Should -Be 7.45
        $r.Signal.Entry | Should -Be 26.84; $r.Signal.Stop | Should -Be 24.67
        ($r.Signal.Entry - $r.Signal.Stop) | Should -BeGreaterOrEqual (0.5 * $r.Atr)
        $r.Signal.Reason | Should -Match 'repriced 29.00->26.84'
        Should -Invoke Get-SwingBestSignal -Times 1 -Exactly -ParameterFilter { [double]$dailyBars[-1].Close -eq 26.84 }
    }
    It 'no valid setup at the live price -> STALE_SIGNAL' {
        Mock Get-SwingBestSignal { $null }
        (Update-SignalForLivePrice $Cfg 'AEHL' (AehlBars) 'BULL' @() (AehlSignal) (Fresh 26.84) $T0).Action | Should -Be 'STALE_SIGNAL'
    }
    It 'setup changes at the live price -> STALE_SIGNAL' {
        Mock Get-SwingBestSignal { [pscustomobject]@{ Strategy = 'PULLBK'; Side = 'buy'; Entry = 26.84; Stop = 24.67; Confidence = 90; Reason = 'x' } }
        (Update-SignalForLivePrice $Cfg 'AEHL' (AehlBars) 'BULL' @() (AehlSignal) (Fresh 26.84) $T0).Reason | Should -Match 'setup changed'
    }
    It 'within 1% -> OK, signal untouched, no rebuild' {
        $r = Update-SignalForLivePrice $Cfg 'AEHL' (AehlBars) 'BULL' @() (AehlSignal) (Fresh 29.20) $T0
        $r.Action | Should -Be 'OK'; $r.Signal.Entry | Should -Be 29.0; $r.Signal.Stop | Should -Be 26.83
        Should -Invoke Get-SwingBestSignal -Times 0 -Exactly
    }
    It 'stop closer than 0.5 ATR to the entry -> STALE_SIGNAL (would-be $0.01 stop)' {
        $r = Update-SignalForLivePrice $Cfg 'AEHL' (AehlBars) 'BULL' @() (AehlSignal 26.84 26.83) (Fresh 26.84) $T0
        $r.Action | Should -Be 'STALE_SIGNAL'; $r.Reason | Should -Match 'ATR from entry'
    }
    It 'aggr: a gate failing after a reprice is reported as STALE_SIGNAL' {
        $rec = @{}
        Get-AggrGateSkip ([pscustomobject]@{ Action = 'REPRICED' }) 'HEAT' $rec | Should -Be 'STALE_SIGNAL'; $rec.gate | Should -Be 'HEAT'
        Get-AggrGateSkip ([pscustomobject]@{ Action = 'OK' }) 'HEAT' @{} | Should -Be 'HEAT'
    }
}

Describe 'Post-fill stop re-place' {
    It 'Get-FillStopFix: AEHL fill 26.84 vs planned 29.00 moves the 26.83 stop to 24.67' {
        $f = Get-FillStopFix 26.84 29.00 26.83 1.085 'buy' $Ec 26.07
        $f.Needed | Should -BeTrue; $f.NewStop | Should -Be 24.67; $f.Breached | Should -BeFalse; $f.Reason | Should -Match '7.45% off planned'
    }
    It 'Get-FillStopFix: fill on plan and stop far enough -> nothing to do; market already through -> breached' {
        (Get-FillStopFix 29.05 29.00 26.83 1.085 'buy' $Ec 29.10).Needed | Should -BeFalse
        (Get-FillStopFix 26.84 29.00 26.83 1.085 'buy' $Ec 24.50).Breached | Should -BeTrue
        (Get-FillStopFix 50.00 50.00 49.90 2.0 'buy' $Ec 50.0).NewStop | Should -Be 49.0    # stop 0.05 ATR away -> widened to 0.5 ATR
        (Get-FillStopFix 49.00 50.00 52.00 1.0 'sell' $Ec 48.9).NewStop | Should -Be 51.0   # short: above the fill
    }
    Context 'Repair-EntryFillStops (mocked broker)' {
        BeforeEach {
            $script:Orders = @([pscustomobject]@{ id = 'p1'; symbol = 'AEHL'; side = 'buy'; status = 'filled'; order_class = 'bracket'; client_order_id = 'BRKOUT_AEHL_141032'
                limit_price = '29'; filled_avg_price = '26.84'; filled_at = '2026-10-14T14:10:44Z'
                legs = @([pscustomobject]@{ id = 'tp1'; symbol = 'AEHL'; side = 'sell'; status = 'new'; type = 'limit'; limit_price = '36.6' },
                         [pscustomobject]@{ id = 'sl1'; symbol = 'AEHL'; side = 'sell'; status = 'held'; type = 'stop'; stop_price = '26.83' }) })
            Mock Invoke-AlpacaApi { param($cfg, $method, $path) if ($method -ne 'GET') { throw "unexpected $method" }; $script:Orders }
            Mock Get-DailyBars { AehlBars }
            Mock Update-OrderStop { [pscustomobject]@{ id = 'sl1-r' } }
            Mock Set-JournalFillFix {}
            Mock Close-PositionNow {}
            Mock Write-Host {}
            $script:Pos = [pscustomobject]@{ symbol = 'AEHL'; asset_class = 'us_equity'; side = 'long'; qty = '284'; current_price = '26.07' }
        }
        It 'moves the stop leg to 24.67 once, then never again for the same fill' {
            $st = [pscustomobject]@{}
            Repair-EntryFillStops $Cfg $st @($Pos)
            Should -Invoke Update-OrderStop -Times 1 -Exactly -ParameterFilter { $orderId -eq 'sl1' -and $newStopPrice -eq 24.67 }
            @($st.fill_checked) | Should -Contain 'p1'
            Repair-EntryFillStops $Cfg $st @($Pos)
            Should -Invoke Update-OrderStop -Times 1 -Exactly
        }
        It 'market already through the corrected stop -> closes instead of placing it' {
            $Pos.current_price = '24.50'
            Repair-EntryFillStops $Cfg ([pscustomobject]@{}) @($Pos)
            Should -Invoke Close-PositionNow -Times 1 -Exactly
            Should -Invoke Update-OrderStop -Times 0 -Exactly
        }
        It 're-place failure is retried on the next scan (not marked checked)' {
            Mock Update-OrderStop { $null }
            $st = [pscustomobject]@{}
            Repair-EntryFillStops $Cfg $st @($Pos)
            @($st.fill_checked) | Should -Not -Contain 'p1'
        }
        It 'PYRA brackets are left alone' {
            $script:Orders[0].client_order_id = 'PYRA_AEHL_141032'
            Repair-EntryFillStops $Cfg ([pscustomobject]@{}) @($Pos)
            Should -Invoke Update-OrderStop -Times 0 -Exactly
        }
    }
}

Describe 'Aggressive dry run uses the same guard' {
    It 'AEHL with the stale quote: STALE_SIGNAL line, no shadow position, no orders' {
        $script:AggrSkipJournal = Join-Path $TestDrive 'stale.jsonl'
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body) if ($method -ne 'GET') { throw "LIVE CALL $method" }; return @() }
        Mock Get-EasternTime { [datetime]'2026-10-14T10:10:00' }
        Mock Get-TickerMemoryInfo { $null }
        Mock Test-EarningsBlackout { $false }
        Mock Get-RelativeStrength { 213.7 }
        Mock Get-AggrOpusUnderlyings { @{} }
        Mock Get-DailyBars { AehlBars }
        Mock Get-SwingBestSignal { AehlSignal }
        Mock Get-Quote { $script:AehlStaleQuote }
        $st = [pscustomobject]@{ losses = 0; equity_at_open = 95554.16; active_watchlist = @() }
        Initialize-AggrState $st; $st.aggr_watchlist = @('AEHL')
        # Extension gate off here: this test isolates the stale-quote guard (AEHL at
        # 11.87 ATR would otherwise be stopped earlier as EXTENSION, see swing_aggr_v12).
        $cfgNoExt = $Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $cfgNoExt.aggr.max_extension_atr = 0
        Invoke-AggrEntries $cfgNoExt $st ([pscustomobject]@{ Regime = 'BULL'; SizeMult = 1.0 }) @() 95554.16 190000 @() @() @{}
        $l = @(Get-Content $script:AggrSkipJournal | ForEach-Object { $_ | ConvertFrom-Json })
        $a = $l | Where-Object sym -eq 'AEHL'
        $a.skip_reason | Should -Be 'STALE_SIGNAL'; $a.stale_reason | Should -Match 'old'; $a.quote_spread_pct | Should -Be 12.94
        @($st.aggr_shadow_open).Count | Should -Be 0
        Should -Invoke Invoke-AlpacaApi -ParameterFilter { $method -ne 'GET' } -Times 0 -Exactly
    }
}
