BeforeAll { . (Join-Path $PSScriptRoot '..' 'tools' 'retire_shadow_golive_2026-10.ps1') }
Describe 'Invoke-RetireGoliveShadows' {
    BeforeEach {
        $st = [pscustomobject]@{
            aggr_shadow_realized = -510.94
            aggr_shadow_closed = @([pscustomobject]@{ sym='AEHL'; pnl=-510.94 })
            aggr_shadow_open = @(
                [pscustomobject]@{ sym='V';    kind='stock'; side='buy'; qty=58;  entry=407.5;  stop=394.88; tp=453.2 }
                [pscustomobject]@{ sym='UNH';  kind='stock'; side='buy'; qty=34;  entry=416.095; stop=394.0;  tp=497.9 }
                [pscustomobject]@{ sym='ISRG'; kind='stock'; side='buy'; qty=20;  entry=432.93; stop=408.66; tp=517.88 }
                [pscustomobject]@{ sym='BHVN'; kind='stock'; side='buy'; qty=444; entry=14.55;  stop=13.18;  tp=19.75 }
                [pscustomobject]@{ sym='XLE';  kind='stock'; side='buy'; qty=139; entry=69.56;  stop=66.71;  tp=79.54 }
                [pscustomobject]@{ sym='TSLA'; kind='stock'; side='buy'; qty=26;  entry=393.71; stop=368.94; tp=481.04 }
            )
        }
        $marks = @{ V = 408.0; UNH = 410.0; ISRG = 450.0; BHVN = 13.88; XLE = 70.0; TSLA = 400.0 }
    }
    It 'retires all six open shadows with paper PnL, leaves realized unchanged' {
        $r = Invoke-RetireGoliveShadows $st @() '2026-10-27T13:30:00Z' $marks
        @($r).Count | Should -Be 6
        @($st.aggr_shadow_open).Count | Should -Be 0
        @($st.aggr_shadow_closed | Where-Object exit_reason -eq 'RETIRED_AT_GOLIVE').Count | Should -Be 6
        @($st.aggr_shadow_closed | Where-Object excluded_from_results).Count | Should -Be 6
        $st.aggr_shadow_realized | Should -Be -510.94
        ($r | Where-Object sym -eq 'V').pnl    | Should -Be 29.0       # (408-407.5)*58
        ($r | Where-Object sym -eq 'ISRG').pnl | Should -Be 341.4      # (450-432.93)*20
        ($r | Where-Object sym -eq 'BHVN').pnl | Should -Be -297.48    # (13.88-14.55)*444
        ($r | Where-Object sym -eq 'V').exit   | Should -Be 408.0
    }
    It 'can retire a subset and keep the rest open' {
        $r = Invoke-RetireGoliveShadows $st @('V','UNH') 'x' $marks
        @($r).Count | Should -Be 2
        (@($st.aggr_shadow_open).sym -join ',') | Should -Be 'ISRG,BHVN,XLE,TSLA'
    }
    It 'is idempotent' {
        Invoke-RetireGoliveShadows $st @() 'x' $marks | Out-Null
        $r2 = Invoke-RetireGoliveShadows $st @() 'y' $marks
        @($r2).Count | Should -Be 0
        @($st.aggr_shadow_closed | Where-Object exit_reason -eq 'RETIRED_AT_GOLIVE').Count | Should -Be 6
    }
    It 'missing mark => pnl 0 and null exit, still excluded' {
        $r = Invoke-RetireGoliveShadows $st @('V') 'z' @{}
        $r[0].pnl | Should -Be 0; $r[0].exit | Should -BeNullOrEmpty
        $r[0].excluded_from_results | Should -BeTrue
        $st.aggr_shadow_realized | Should -Be -510.94
    }
}
Describe 'Get-RetireGolivePaperPnl' {
    It 'long and short' {
        Get-RetireGolivePaperPnl ([pscustomobject]@{ sym='A'; side='buy';  entry=10; qty=5 }) @{ A = 12 } | Should -Be 10
        Get-RetireGolivePaperPnl ([pscustomobject]@{ sym='A'; side='sell'; entry=10; qty=5 }) @{ A = 8 }  | Should -Be 10
    }
}
