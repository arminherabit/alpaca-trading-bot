# tests/partial_fill_ownership.Tests.ps1 -- Pester 5. An entry that partially filled and
# was then canceled/expired (NVDA 67 of 71, 2026-11-06) is OWNED at the filled qty, gets the
# missing-stop fallback, and keeps its journal row. No network, no real journal.
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
    # Functions living in alpaca_bot.ps1 (a script with a main body): load just those from the AST.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'alpaca_bot.ps1'), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -in @('Get-MyOpenSymbols','Protect-NakedAggrPositions','New-ProtectiveStop','Get-StopLegForPosition') }, $true)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Ord($sym, $coid, $status, $filled, $side = 'sell') {
        [pscustomobject]@{ id = "id-$coid"; symbol = $sym; client_order_id = $coid; status = $status; filled_qty = "$filled"; side = $side
                           submitted_at = '2026-11-05T15:01:28Z'; created_at = '2026-11-05T15:01:28Z' }
    }
    # Broker double: /v2/positions -> $script:Held, per-symbol history (no `after`) -> $script:Hist[sym], windowed list -> OrderBook.
    function Broker($held = @(), $hist = @{}, [bool]$histFails = $false) {
        $script:Held = $held; $script:Hist = $hist; $script:HistFails = $histFails; $script:HistCalls = @()
    }
    function RouteApi($path) {
        if ($path -eq '/v2/positions') { return $script:Held }
        if ($path -like '/v2/orders?status=all&symbols=*') {
            $sym = ($path -replace '.*symbols=([^&]+).*', '$1'); $script:HistCalls += $sym
            if ($script:HistFails) { return $null }
            return @($script:Hist[$sym])
        }
        return OrderBook
    }
    function HeldPos($sym, $side = 'long') { [pscustomobject]@{ symbol = $sym; asset_class = 'us_equity'; side = $side; qty = '10'; avg_entry_price = '100' } }
    # The Nov 2026 book: NVDA canceled with 67 filled; UNH canceled with 0 (Oct 15); a filled legacy HD; a foreign fill.
    function OrderBook {
        @( (Ord 'NVDA' 'AGSW_NVDA_150128' 'canceled' 67)
           (Ord 'UNH'  'BRKOUT_UNH_135025' 'canceled' 0 'buy')
           (Ord 'GLD'  'AGSW_GLD_141500'   'filled'   64)
           (Ord 'XYZ'  'foreign-uuid-1'    'canceled' 10)
           (Ord 'ABC'  'BRKOUT_ABC_140000' 'partially_filled' 12 'buy') )
    }
}

Describe 'Test-OrderHasFill / Get-OrderFilledQty' {
    It 'filled counts' { Test-OrderHasFill (Ord 'A' 'AGSW_A_1' 'filled' 10) | Should -BeTrue }
    It 'canceled with filled_qty > 0 counts' { Test-OrderHasFill (Ord 'A' 'AGSW_A_1' 'canceled' 67) | Should -BeTrue }
    It 'expired and partially_filled with fills count' {
        Test-OrderHasFill (Ord 'A' 'AGSW_A_1' 'expired' 3) | Should -BeTrue
        Test-OrderHasFill (Ord 'A' 'AGSW_A_1' 'partially_filled' 3) | Should -BeTrue
    }
    It 'canceled/expired/new with zero or missing fill do not count' {
        Test-OrderHasFill (Ord 'A' 'AGSW_A_1' 'canceled' 0) | Should -BeFalse
        Test-OrderHasFill (Ord 'A' 'AGSW_A_1' 'expired' '') | Should -BeFalse
        Test-OrderHasFill ([pscustomobject]@{ status = 'canceled' }) | Should -BeFalse
        Test-OrderHasFill ([pscustomobject]@{ status = 'new'; filled_qty = '0' }) | Should -BeFalse
        Test-OrderHasFill $null | Should -BeFalse
    }
    It 'parses the qty as a number' { Get-OrderFilledQty (Ord 'A' 'x' 'canceled' '67') | Should -Be 67; Get-OrderFilledQty (Ord 'A' 'x' 'canceled' 'junk') | Should -Be 0 }
}

Describe 'Get-PartialFillEntries' {
    It 'returns only OUR tagged entries that ENDED with a partial fill' {
        $p = @(Get-PartialFillEntries (OrderBook))
        $p.Count | Should -Be 1
        $p[0].Symbol | Should -Be 'NVDA'; $p[0].FilledQty | Should -Be 67; $p[0].Status | Should -Be 'canceled'
    }
}

Describe 'Get-AggrOwnedSymbols' {
    BeforeEach { Broker; Mock Invoke-AggrApi { param($cfg, $method, $path, $body = $null) RouteApi $path } }
    It 'AGSW canceled with 67 filled is aggr-owned (NVDA); filled AGSW still owned' {
        $o = Get-AggrOwnedSymbols $Cfg
        $o.ContainsKey('NVDA') | Should -BeTrue
        $o.ContainsKey('GLD')  | Should -BeTrue
    }
    It 'zero-fill cancel, foreign fill and legacy-tagged partial are NOT aggr-owned' {
        $o = Get-AggrOwnedSymbols $Cfg
        $o.ContainsKey('UNH') | Should -BeFalse
        $o.ContainsKey('XYZ') | Should -BeFalse
        $o.ContainsKey('ABC') | Should -BeFalse
    }
    It 'API failure still returns $null' { Mock Invoke-AggrApi { $null }; Get-AggrOwnedSymbols $Cfg | Should -BeNullOrEmpty }
    It 'a partially_filled AGSW entry (still working) is owned' {
        Mock Invoke-AggrApi { @((Ord 'AMD' 'AGSW_AMD_150000' 'partially_filled' 5)) }
        (Get-AggrOwnedSymbols $Cfg).ContainsKey('AMD') | Should -BeTrue
    }
}

Describe 'Get-MyOpenSymbols (both bots)' {
    BeforeEach { Broker; Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null) RouteApi $path } }
    It 'NVDA (AGSW partial) and ABC (legacy BRKOUT partial) are mine; UNH zero-fill and foreign are not' {
        $m = Get-MyOpenSymbols $Cfg
        $m.ContainsKey('NVDA') | Should -BeTrue
        $m.ContainsKey('ABC')  | Should -BeTrue
        $m.ContainsKey('GLD')  | Should -BeTrue
        $m.ContainsKey('UNH')  | Should -BeFalse
        $m.ContainsKey('XYZ')  | Should -BeFalse
    }
    It 'exposes the ended-partial entries for the journal fix' {
        $null = Get-MyOpenSymbols $Cfg
        @($script:MyPartialFillEntries | ForEach-Object Symbol) | Should -Be @('NVDA')
    }
    It 'API failure returns $null (unchanged: act on nothing)' { Mock Invoke-AlpacaApi { $null }; Get-MyOpenSymbols $Cfg | Should -BeNullOrEmpty }
}

Describe 'Ownership split after the fix' {
    It 'NVDA is aggr-owned, so the legacy loop still skips it (one owner)' {
        $held = @([pscustomobject]@{ symbol = 'NVDA'; asset_class = 'us_equity' }, [pscustomobject]@{ symbol = 'ABC'; asset_class = 'us_equity' })
        Broker
        Mock Invoke-AggrApi { param($cfg, $method, $path, $body = $null) RouteApi $path }
        $aggr = Get-AggrOwnedSymbols $Cfg
        @(Select-LegacyManagedPositions $held $aggr | ForEach-Object symbol) | Should -Be @('ABC')   # legacy-tag partial -> legacy-managed
    }
}

Describe 'Set-JournalPartialFill' {
    BeforeEach {
        $script:JournalPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.json')
        $JournalPath = $script:JournalPath
        [pscustomobject]@{ open = @([pscustomobject]@{ opened_at = '2026-11-05T15:01:30Z'; symbol = 'NVDA'; strategy = 'BRKDN'; side = 'sell'; entry = 190.09; stop = 202.95; qty = 71; risk_usd = 913.06 })
                           closed = @() } | ConvertTo-Json -Depth 6 | Set-Content $script:JournalPath
    }
    It 'sets qty to the filled qty, scales risk, keeps the planned values, row stays open' {
        $r = Set-JournalPartialFill -symbol 'NVDA' -filledQty 67 -orderCreatedAt '2026-11-05T15:01:28Z'
        $r | Should -Not -BeNullOrEmpty
        $j = Load-Journal
        @($j.open).Count | Should -Be 1
        $j.open[0].qty | Should -Be 67; $j.open[0].planned_qty | Should -Be 71; $j.open[0].partial_fill | Should -BeTrue
        $j.open[0].risk_usd | Should -Be 861.62; $j.open[0].planned_risk_usd | Should -Be 913.06
    }
    It 'is idempotent' {
        $null = Set-JournalPartialFill -symbol 'NVDA' -filledQty 67 -orderCreatedAt '2026-11-05T15:01:28Z'
        Set-JournalPartialFill -symbol 'NVDA' -filledQty 67 -orderCreatedAt '2026-11-05T15:01:28Z' | Should -BeNullOrEmpty
        (Load-Journal).open[0].planned_qty | Should -Be 71
    }
    It 'ignores a row opened for a different order (outside the window) and a full fill' {
        Set-JournalPartialFill -symbol 'NVDA' -filledQty 67 -orderCreatedAt '2026-11-03T15:01:28Z' | Should -BeNullOrEmpty
        Set-JournalPartialFill -symbol 'NVDA' -filledQty 71 -orderCreatedAt '2026-11-05T15:01:28Z' | Should -BeNullOrEmpty
        (Load-Journal).open[0].qty | Should -Be 71
    }
    It 'a held partial-fill symbol is NOT orphaned by Reconcile-Journal' {
        Reconcile-Journal @('NVDA') | Should -Be 0
        @((Load-Journal).open).Count | Should -Be 1
    }
}

Describe 'Protect-NakedAggrPositions (the missing-stop fallback for aggr-owned stocks)' {
    BeforeAll {
        function NvdaShort { [pscustomobject]@{ symbol = 'NVDA'; asset_class = 'us_equity'; side = 'short'; qty = '-67'; avg_entry_price = '191.77'; current_price = '150.66'; unrealized_pl = '2754.37' } }
        $script:Owned = @{ NVDA = $true }
    }
    It 'plants ONE GTC buy-stop on 67 NVDA at entry -0.1% (191.58) when no stop is live' {
        $script:Posts = @()
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null)
            if ($method -eq 'POST') { $script:Posts += , $body; return [pscustomobject]@{ id = 'new' } }
            return @((Ord 'NVDA' 'AGSW_NVDA_150128' 'canceled' 67)) }          # no live stop leg anywhere
        Protect-NakedAggrPositions $Cfg @(NvdaShort) $Owned 6>$null
        $Posts.Count | Should -Be 1
        $Posts[0].symbol | Should -Be 'NVDA'; $Posts[0].side | Should -Be 'buy'; $Posts[0].qty | Should -Be '67'
        $Posts[0].type | Should -Be 'stop'; $Posts[0].time_in_force | Should -Be 'gtc'; $Posts[0].stop_price | Should -Be '191.58'
        $Posts[0].client_order_id | Should -BeLike 'PROTECT_BREAKEVEN_NVDA_*'
    }
    It 'places NOTHING when a live stop already exists (e.g. one placed by hand first)' {
        $script:Posts = @()
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null)
            if ($method -eq 'POST') { $script:Posts += , $body; return [pscustomobject]@{ id = 'new' } }
            return @([pscustomobject]@{ id = 's1'; symbol = 'NVDA'; side = 'buy'; type = 'stop'; order_type = 'stop'; status = 'new'; stop_price = '165.00'; legs = @() }) }
        Protect-NakedAggrPositions $Cfg @(NvdaShort) $Owned 6>$null
        $Posts.Count | Should -Be 0
    }
    It 'places NOTHING for a bracket stop leg that is live under its parent' {
        $script:Posts = @()
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null)
            if ($method -eq 'POST') { $script:Posts += , $body; return $null }
            $leg = [pscustomobject]@{ id = 'l'; symbol = 'NVDA'; side = 'buy'; type = 'stop'; order_type = 'stop'; status = 'held'; stop_price = '202.95' }
            return @([pscustomobject]@{ id = 'p'; symbol = 'NVDA'; side = 'sell'; type = 'limit'; status = 'filled'; legs = @($leg) }) }
        Protect-NakedAggrPositions $Cfg @(NvdaShort) $Owned 6>$null
        $Posts.Count | Should -Be 0
    }
    It 'skips positions that are not aggr-owned, options, and does nothing when ownership is unknown' {
        $script:Posts = @()
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null) if ($method -eq 'POST') { $script:Posts += , $body }; return @() }
        Protect-NakedAggrPositions $Cfg @(NvdaShort) @{ OTHER = $true } 6>$null
        Protect-NakedAggrPositions $Cfg @([pscustomobject]@{ symbol = 'NVDA'; asset_class = 'us_option' }) $Owned 6>$null
        Protect-NakedAggrPositions $Cfg @(NvdaShort) $null 6>$null
        $Posts.Count | Should -Be 0
    }
    It 'a losing naked position gets the MAX-LOSS stop (entry +2% for a short)' {
        $script:Posts = @()
        Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null) if ($method -eq 'POST') { $script:Posts += , $body; return [pscustomobject]@{ id = 'n' } }; return @() }
        $p = NvdaShort; $p.unrealized_pl = '-300'; $p.current_price = '195.00'
        Protect-NakedAggrPositions $Cfg @($p) $Owned 6>$null
        $Posts.Count | Should -Be 1; $Posts[0].stop_price | Should -Be '195.61'
    }
}

Describe 'Ownership of HELD positions does not expire with the 20-day order window (ISRG case)' {
    BeforeAll {
        # ISRG: legacy PULLBK long, entry filled Nov 2 -> outside the window on Nov 22. AGSW SOXX-style short: AGSW entry 30 days old.
        $script:IsrgOld = Ord 'ISRG' 'PULLBK_ISRG_150100' 'filled' 15 'buy'; $script:IsrgOld.submitted_at = '2026-11-02T15:01:00Z'
        $script:AgswOld = Ord 'SOXX' 'AGSW_SOXX_150100'   'filled' 58 'sell'; $script:AgswOld.submitted_at = '2026-10-20T15:01:00Z'
    }
    Context 'legacy (Get-MyOpenSymbols)' {
        BeforeEach { Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null) RouteApi $path } }
        It 'ISRG: not in the 20-day list, but held + old filled PULLBK buy -> mine' {
            Broker @((HeldPos 'ISRG' 'long')) @{ ISRG = @($IsrgOld) }
            (Get-MyOpenSymbols $Cfg).ContainsKey('ISRG') | Should -BeTrue
            $script:HistCalls | Should -Contain 'ISRG'
        }
        It 'old tagged AGSW short entry keeps a held short mine' {
            Broker @((HeldPos 'SOXX' 'short')) @{ SOXX = @($AgswOld) }
            (Get-MyOpenSymbols $Cfg).ContainsKey('SOXX') | Should -BeTrue
        }
        It 'a held position with NO tagged entry anywhere stays foreign' {
            Broker @((HeldPos 'FRGN' 'long')) @{ FRGN = @((Ord 'FRGN' 'some-uuid' 'filled' 10 'buy')) }
            (Get-MyOpenSymbols $Cfg).ContainsKey('FRGN') | Should -BeFalse
        }
        It 'an old tagged entry on the OPPOSITE side of the position does not claim it' {
            Broker @((HeldPos 'ISRG' 'short')) @{ ISRG = @($IsrgOld) }
            (Get-MyOpenSymbols $Cfg).ContainsKey('ISRG') | Should -BeFalse
        }
        It 'an old tagged order with zero fill does not claim it' {
            $z = Ord 'ISRG' 'PULLBK_ISRG_150100' 'canceled' 0 'buy'
            Broker @((HeldPos 'ISRG' 'long')) @{ ISRG = @($z) }
            (Get-MyOpenSymbols $Cfg).ContainsKey('ISRG') | Should -BeFalse
        }
        It 'only HELD symbols not already owned are looked up (no history call for owned or flat symbols)' {
            Broker @((HeldPos 'NVDA' 'short'), (HeldPos 'GLD' 'short')) @{}
            $null = Get-MyOpenSymbols $Cfg
            $script:HistCalls.Count | Should -Be 0     # NVDA and GLD already owned from the 20-day list; nothing else held
        }
        It 'history lookup failure leaves ownership unchanged (no throw, not owned)' {
            Broker @((HeldPos 'ISRG' 'long')) @{} $true
            (Get-MyOpenSymbols $Cfg).ContainsKey('ISRG') | Should -BeFalse
        }
        It 'positions API failure leaves the 20-day result untouched' {
            Broker; Mock Invoke-AlpacaApi { param($cfg, $method, $path, $body = $null) if ($path -eq '/v2/positions') { return $null }; RouteApi $path }
            $m = Get-MyOpenSymbols $Cfg
            $m.ContainsKey('NVDA') | Should -BeTrue
        }
    }
    Context 'aggr (Get-AggrOwnedSymbols) and the one-owner rule' {
        BeforeEach { Mock Invoke-AggrApi { param($cfg, $method, $path, $body = $null) RouteApi $path } }
        It 'old AGSW short stays aggr-owned' {
            Broker @((HeldPos 'SOXX' 'short')) @{ SOXX = @($AgswOld) }
            (Get-AggrOwnedSymbols $Cfg).ContainsKey('SOXX') | Should -BeTrue
        }
        It 'old LEGACY-tagged ISRG is NOT aggr-owned, so the legacy loop keeps managing it (one owner)' {
            Broker @((HeldPos 'ISRG' 'long')) @{ ISRG = @($IsrgOld) }
            $aggr = Get-AggrOwnedSymbols $Cfg
            $aggr.ContainsKey('ISRG') | Should -BeFalse
            $held = @([pscustomobject]@{ symbol = 'ISRG'; asset_class = 'us_equity' }, [pscustomobject]@{ symbol = 'SOXX'; asset_class = 'us_equity' })
            Broker @((HeldPos 'ISRG' 'long'), (HeldPos 'SOXX' 'short')) @{ ISRG = @($IsrgOld); SOXX = @($AgswOld) }
            @(Select-LegacyManagedPositions $held (Get-AggrOwnedSymbols $Cfg) | ForEach-Object symbol) | Should -Be @('ISRG')
        }
    }
}
