# tests/fix_journal_unfilled.Tests.ps1 -- Pester 5. One-time tool
# tools/fix_journal_unfilled_2026-10.ps1 (MRNA + UNH orphaned -> unfilled). No network.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Tool = Join-Path $script:Root 'tools/fix_journal_unfilled_2026-10.ps1'
    . (Join-Path $script:Root 'alpaca_journal.ps1')
    $JournalPath = Join-Path $TestDrive 'unused.json'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Test-UnfilledFrom*' }, $true)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Orph($sym, $opened, $qty, $entry) {
        [pscustomobject]@{ opened_at = $opened; symbol = $sym; strategy = 'BRKOUT'; side = 'buy'; entry = $entry; stop = 1; qty = $qty; risk_usd = 100
                           confidence = 80; regime = 'BULL'; reason = 't'; orphaned_at = '2026-10-19T13:30:24Z'; orphan_reason = 'position not held; exit never journaled' }
    }
    function NewJournal([string]$path, $extraClosed = @()) {
        [pscustomobject]@{ open = @([pscustomobject]@{ symbol = 'PFE'; strategy = 'BRKOUT'; opened_at = '2026-10-14T14:01:17Z'; qty = 605 })
            closed = @($extraClosed)
            orphaned = @((Orph 'MRNA' '2026-08-19T14:01:48.6390152Z' 89 133.13), (Orph 'UNH' '2026-10-15T13:50:26.0879597Z' 21 405.12)) } |
            ConvertTo-Json -Depth 6 | Set-Content $path
    }
}

Describe 'fix_journal_unfilled_2026-10 tool' {
    BeforeEach { $script:P = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.json') }
    It 'preview moves nothing on disk' {
        NewJournal $P; $before = Get-Content $P -Raw
        $out = & $Tool -JournalFile $P -NoAlpaca 6>&1 | Out-String
        $out | Should -Match 'PREVIEW ONLY'; $out | Should -Match 'MOVE  MRNA'; $out | Should -Match 'MOVE  UNH'
        Get-Content $P -Raw | Should -Be $before
    }
    It '-Apply moves exactly MRNA and UNH to unfilled as UNFILLED, leaves open/closed alone' {
        NewJournal $P
        & $Tool -JournalFile $P -NoAlpaca -Apply | Out-Null
        $j = Get-Content $P -Raw | ConvertFrom-Json
        @($j.orphaned).Count | Should -Be 0
        (@($j.unfilled) | ForEach-Object symbol) -join ',' | Should -Be 'MRNA,UNH'
        @($j.unfilled | Where-Object outcome -ne 'UNFILLED').Count | Should -Be 0
        @($j.unfilled | Where-Object { -not $_.correction_note }).Count | Should -Be 0
        @($j.open).Count | Should -Be 1; @($j.closed).Count | Should -Be 0
    }
    It 'is idempotent' {
        NewJournal $P
        & $Tool -JournalFile $P -NoAlpaca -Apply | Out-Null
        $after1 = Get-Content $P -Raw
        $out = & $Tool -JournalFile $P -NoAlpaca -Apply | Out-String
        $out | Should -Match 'SKIP  MRNA'; $out | Should -Match 'SKIP  UNH'
        Get-Content $P -Raw | Should -Be $after1
    }
    It 'journal evidence of a fill (closed row near opened_at) aborts without writing' {
        NewJournal $P @([pscustomobject]@{ symbol = 'UNH'; strategy = 'BRKOUT'; opened_at = '2026-10-15T13:50:30Z'; qty = 21; pnl = 10 })
        $before = Get-Content $P -Raw
        { & $Tool -JournalFile $P -NoAlpaca -Apply } | Should -Throw '*verification failed*'
        Get-Content $P -Raw | Should -Be $before
    }
    It 'missing target row aborts without writing' {
        NewJournal $P; $j = Get-Content $P -Raw | ConvertFrom-Json; $j.orphaned = @($j.orphaned[0]); $j | ConvertTo-Json -Depth 6 | Set-Content $P
        $before = Get-Content $P -Raw
        { & $Tool -JournalFile $P -NoAlpaca -Apply } | Should -Throw '*expected exactly 1*'
        Get-Content $P -Raw | Should -Be $before
    }
}

Describe 'Alpaca order-history verification (pure)' {
    BeforeAll { $script:T = [datetime]::SpecifyKind([datetime]'2026-10-15T13:50:26', 'Utc') }
    It 'canceled bracket with 0 fill -> ok' {
        (Test-UnfilledFromOrders @([pscustomobject]@{ id = 'a'; symbol = 'UNH'; order_class = 'bracket'; status = 'canceled'; filled_qty = '0'; created_at = '2026-10-15T13:50:25Z' }) 'UNH' $T).Ok | Should -BeTrue
    }
    It 'filled bracket -> refused' {
        $v = Test-UnfilledFromOrders @([pscustomobject]@{ id = 'a'; symbol = 'UNH'; order_class = 'bracket'; status = 'filled'; filled_qty = '21'; created_at = '2026-10-15T13:50:25Z' }) 'UNH' $T
        $v.Ok | Should -BeFalse; $v.Detail | Should -Match 'FILLED'
    }
    It 'still working -> refused' {
        (Test-UnfilledFromOrders @([pscustomobject]@{ id = 'a'; symbol = 'UNH'; order_class = 'bracket'; status = 'new'; filled_qty = '0'; created_at = '2026-10-15T13:50:25Z' }) 'UNH' $T).Ok | Should -BeFalse
    }
    It 'no matching entry -> refused' {
        (Test-UnfilledFromOrders @() 'UNH' $T).Ok | Should -BeFalse
    }
}
