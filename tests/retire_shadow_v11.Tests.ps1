BeforeAll { . (Join-Path $PSScriptRoot '..' 'tools' 'retire_shadow_v11_carryover_2026-10.ps1') }
Describe 'Invoke-RetireShadows' {
    BeforeEach {
        $st = [pscustomobject]@{ aggr_shadow_realized = -510.94
            aggr_shadow_closed = @([pscustomobject]@{ sym='AEHL'; pnl=-510.94 })
            aggr_shadow_open = @('PFE','NKE','V','UNH' | ForEach-Object { [pscustomobject]@{ sym=$_; kind='stock'; qty=10; entry=1; stop=0.9 } }) }
    }
    It 'moves only PFE/NKE to closed, keeps V/UNH, leaves realized unchanged' {
        $r = Invoke-RetireShadows $st @('PFE','NKE') '2026-10-21T21:00:00Z'
        @($r).Count | Should -Be 2
        (@($st.aggr_shadow_open).sym -join ',') | Should -Be 'V,UNH'
        @($st.aggr_shadow_closed).Count | Should -Be 3
        @($st.aggr_shadow_closed | Where-Object exit_reason -eq 'RETIRED_V11_CARRYOVER').Count | Should -Be 2
        @($st.aggr_shadow_closed | Where-Object excluded_from_results).pnl | ForEach-Object { $_ | Should -Be 0 }
        $st.aggr_shadow_realized | Should -Be -510.94
    }
    It 'is idempotent' {
        Invoke-RetireShadows $st @('PFE','NKE') 'x' | Out-Null
        $r2 = Invoke-RetireShadows $st @('PFE','NKE') 'y'
        @($r2).Count | Should -Be 0; @($st.aggr_shadow_closed).Count | Should -Be 3
    }
}
