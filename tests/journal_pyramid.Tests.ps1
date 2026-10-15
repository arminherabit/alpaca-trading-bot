# tests/journal_pyramid.Tests.ps1 -- Pester 5. One closing fill split FIFO across
# base + PYRA journal tranches (SNOW / MSFT, Aug 2026). No network.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'alpaca_screener.ps1')   # Sync-ClosedTrades, MY_ENTRY_PREFIXES, journal
    # alpaca_journal.ps1 sets $JournalPath in THIS scope when dot-sourced, so it
    # must be redirected here (a $script: copy set later is shadowed by this one
    # and the tests would write the real alpaca_journal.json).
    $JournalPath = Join-Path $TestDrive 'journal.json'
    $script:Cfg = [pscustomobject]@{}

    # Alpaca order shapes as returned by /v2/orders?status=closed&nested=true.
    function Bracket($id, $sym, $coid, $sub, $fill, $qty, $px) {
        [pscustomobject]@{ id = $id; symbol = $sym; side = 'buy'; status = 'filled'; order_class = 'bracket'; client_order_id = $coid
            submitted_at = $sub; filled_at = $fill; filled_qty = "$qty"; filled_avg_price = "$px"; qty = "$qty"
            legs = @([pscustomobject]@{ id = "$id-tp"; symbol = $sym; side = 'sell'; status = 'canceled'; type = 'limit' },
                     [pscustomobject]@{ id = "$id-sl"; symbol = $sym; side = 'sell'; status = 'canceled'; type = 'stop' }) }
    }
    function Exit1($id, $sym, $fill, $qty, $px) {
        [pscustomobject]@{ id = $id; symbol = $sym; side = 'sell'; status = 'filled'; order_class = ''; type = 'market'
            client_order_id = [guid]::NewGuid().ToString(); submitted_at = $fill; filled_at = $fill; filled_qty = "$qty"; filled_avg_price = "$px"; legs = $null }
    }
    function Rec($sym, $strat, $opened, $entry, $stop, $qty, $risk) {
        [pscustomobject]@{ opened_at = $opened; symbol = $sym; strategy = $strat; side = 'buy'; entry = $entry; stop = $stop; qty = $qty
                           risk_usd = $risk; confidence = 90; regime = 'BULL'; reason = 't' }
    }
    function NewState { [pscustomobject]@{ recorded_exits = @(); wins = 0; losses = 0; pnl_today = 0.0 } }
}

Describe 'Get-ExitAllocation (pure)' {
    It 'SNOW 21-share exit: base 14 @ 283.26 then PYRA 7 @ 312.00, each off its own fill' {
        $open = @((Rec 'SNOW' 'BRKOUT' '2026-07-29T14:01:49Z' 283.62 257.82 14 361.2), (Rec 'SNOW' 'PYRA' '2026-08-03T13:40:45Z' 312.39 290 7 201.95))
        $ents = @((Bracket 'b1' 'SNOW' 'BRKOUT_SNOW_140149' '2026-07-29T14:01:49Z' '2026-07-29T14:07:09Z' 14 283.26),
                  (Bracket 'p1' 'SNOW' 'PYRA_SNOW_134045'   '2026-08-03T13:40:45Z' '2026-08-03T13:40:47Z' 7 312.00))
        $a = @(Get-ExitAllocation $open $ents 'SNOW' 'buy' 21 321.04)
        $a.Count | Should -Be 2
        $a[0].Strategy | Should -Be 'BRKOUT'; $a[0].Qty | Should -Be 14; $a[0].Entry | Should -Be 283.26; $a[0].Pnl | Should -Be 528.92
        $a[1].Strategy | Should -Be 'PYRA';   $a[1].Qty | Should -Be 7;  $a[1].Entry | Should -Be 312.00; $a[1].Pnl | Should -Be 63.28
    }
    It 'smaller exit than the base closes part of the oldest tranche only (FIFO)' {
        $open = @((Rec 'X' 'BRKOUT' '2026-07-01T14:00:00Z' 10 9 30 30), (Rec 'X' 'PYRA' '2026-07-02T14:00:00Z' 11 10 10 10))
        $a = @(Get-ExitAllocation $open @() 'X' 'buy' 10 12)
        $a.Count | Should -Be 1; $a[0].Strategy | Should -Be 'BRKOUT'; $a[0].Qty | Should -Be 10; $a[0].Partial | Should -BeTrue; $a[0].Pnl | Should -Be 20   # journal entry fallback
    }
    It 'no open tranche -> empty (caller keeps the old single-entry path)' {
        @(Get-ExitAllocation @() @() 'X' 'buy' 10 12).Count | Should -Be 0
    }
}

Describe 'Sync-ClosedTrades pass 2 with base + PYRA closed by one sell' {
    BeforeEach {
        # Hard guard: never touch the real journal.
        $JournalPath | Should -BeLike "$TestDrive*"
        $script:JournalPath = $JournalPath
        Mock Update-TickerMemory {}
        Mock Write-Host {}
    }
    It 'SNOW (14 + 7): base and PYRA each closed with their own P&L and R; nothing left open' {
        [pscustomobject]@{ open = @((Rec 'SNOW' 'BRKOUT' '2026-07-29T14:01:49Z' 283.62 257.82 14 361.2), (Rec 'SNOW' 'PYRA' '2026-08-03T13:40:45Z' 312.39 290 7 201.95)); closed = @() } |
            ConvertTo-Json -Depth 6 | Set-Content $script:JournalPath
        $script:Orders = @((Bracket 'b1' 'SNOW' 'BRKOUT_SNOW_140149' '2026-07-29T14:01:49Z' '2026-07-29T14:07:09Z' 14 283.26),
                           (Bracket 'p1' 'SNOW' 'PYRA_SNOW_134045'   '2026-08-03T13:40:45Z' '2026-08-03T13:40:47Z' 7 312.00),
                           (Exit1 'x1' 'SNOW' '2026-08-19T13:33:26Z' 21 321.04))
        Mock Invoke-AlpacaApi { return $script:Orders }
        $st = Sync-ClosedTrades $Cfg (NewState)
        $j = Get-Content $script:JournalPath -Raw | ConvertFrom-Json
        @($j.open).Count | Should -Be 0
        $b = @($j.closed | Where-Object strategy -eq 'BRKOUT')[0]; $p = @($j.closed | Where-Object strategy -eq 'PYRA')[0]
        $b.qty | Should -Be 14; $b.pnl | Should -Be 528.92; $b.r_multiple | Should -Be 1.46; $b.outcome | Should -Be 'WIN'
        $p.qty | Should -Be 7;  $p.pnl | Should -Be 63.28;  $p.r_multiple | Should -Be 0.31; $p.outcome | Should -Be 'WIN'
        @($st.recorded_exits) | Should -Contain 'x1'
        Should -Invoke Update-TickerMemory -Times 2 -Exactly
        Should -Invoke Update-TickerMemory -Times 1 -Exactly -ParameterFilter { $strategy -eq 'BRKOUT' -and $pnl -eq 528.92 }
        Should -Invoke Update-TickerMemory -Times 1 -Exactly -ParameterFilter { $strategy -eq 'PYRA' -and $pnl -eq 63.28 }
    }
    It 'MSFT (14 + 7): base +305.06 / +0.69R, PYRA -86.31 / -0.36R' {
        [pscustomobject]@{ open = @((Rec 'MSFT' 'BRKOUT' '2026-07-31T13:50:30Z' 460.04 428.67 14 439.18), (Rec 'MSFT' 'PYRA' '2026-08-04T14:10:41Z' 495.12 460.45 7 242.69)); closed = @() } |
            ConvertTo-Json -Depth 6 | Set-Content $script:JournalPath
        $script:Orders = @((Bracket 'b2' 'MSFT' 'BRKOUT_MSFT_135029' '2026-07-31T13:50:30Z' '2026-07-31T13:50:38Z' 14 459.99),
                           (Bracket 'p2' 'MSFT' 'PYRA_MSFT_141040'   '2026-08-04T14:10:41Z' '2026-08-04T14:10:42Z' 7 494.11),
                           (Exit1 'x2' 'MSFT' '2026-08-20T13:36:13Z' 21 481.78))
        Mock Invoke-AlpacaApi { return $script:Orders }
        $st = Sync-ClosedTrades $Cfg (NewState)
        $j = Get-Content $script:JournalPath -Raw | ConvertFrom-Json
        @($j.open).Count | Should -Be 0
        $b = @($j.closed | Where-Object strategy -eq 'BRKOUT')[0]; $p = @($j.closed | Where-Object strategy -eq 'PYRA')[0]
        $b.pnl | Should -Be 305.06; $b.r_multiple | Should -Be 0.69; $b.outcome | Should -Be 'WIN'
        $p.pnl | Should -Be -86.31; $p.r_multiple | Should -Be -0.36; $p.outcome | Should -Be 'LOSS'
    }
    It 'single tranche, full exit: unchanged behaviour (one closed row, full P&L)' {
        [pscustomobject]@{ open = @((Rec 'XOM' 'BRKOUT' '2026-08-19T14:00:00Z' 166.90 159.73 86 616.62)); closed = @() } | ConvertTo-Json -Depth 6 | Set-Content $script:JournalPath
        $script:Orders = @((Bracket 'b3' 'XOM' 'BRKOUT_XOM_140000' '2026-08-19T14:00:00Z' '2026-08-19T14:00:05Z' 86 166.89),
                           (Exit1 'x3' 'XOM' '2026-08-26T15:00:00Z' 86 158.84))
        Mock Invoke-AlpacaApi { return $script:Orders }
        $null = Sync-ClosedTrades $Cfg (NewState)
        $j = Get-Content $script:JournalPath -Raw | ConvertFrom-Json
        @($j.open).Count | Should -Be 0; @($j.closed).Count | Should -Be 1; $j.closed[0].pnl | Should -Be -692.3
    }
    It 'partial exit (aggr 1/3 sale) closes 227 of 682 and leaves 455 open with the rest of the risk' {
        [pscustomobject]@{ open = @((Rec 'AI' 'BRKOUT' '2026-10-12T14:00:00Z' 11.98 11.07 682 620.62)); closed = @() } | ConvertTo-Json -Depth 6 | Set-Content $script:JournalPath
        $script:Orders = @((Bracket 'b4' 'AI' 'BRKOUT_AI_140000' '2026-10-12T14:00:00Z' '2026-10-12T14:00:03Z' 682 11.98),
                           (Exit1 'x4' 'AI' '2026-10-14T15:00:00Z' 227 13.90))
        Mock Invoke-AlpacaApi { return $script:Orders }
        $null = Sync-ClosedTrades $Cfg (NewState)
        $j = Get-Content $script:JournalPath -Raw | ConvertFrom-Json
        @($j.open).Count | Should -Be 1; $j.open[0].qty | Should -Be 455; $j.open[0].risk_usd | Should -Be 414.05
        @($j.closed).Count | Should -Be 1; $j.closed[0].qty | Should -Be 227; $j.closed[0].risk_usd | Should -Be 206.57
        $j.closed[0].pnl | Should -Be 435.84; $j.closed[0].r_multiple | Should -Be 2.11
    }
}
