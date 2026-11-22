# tests/swing_regime.Tests.ps1 -- Pester 5. Swing regime size multipliers. No network.
# Approved Opus rule: half size (x0.50) in NEUTRAL. BEAR x0.75, RANGING x0.60 and
# the VIX overlay are kept as-is (Armin, Nov 21 2026).
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'alpaca_client.ps1')
    . (Join-Path $script:Root 'alpaca_indicators.ps1')
    . (Join-Path $script:Root 'alpaca_signals.ps1')
    . (Join-Path $script:Root 'alpaca_regime.ps1')
    function script:Bars([double[]]$closes) { $closes | ForEach-Object { [pscustomobject]@{ Close = $_ } } }
    # 80 rising closes then a dip below EMA20 but still above EMA50 -> NEUTRAL
    $script:NeutralBars = Bars (@(1..80 | ForEach-Object { 100.0 + $_ }) + @(170.0, 165.0, 160.0))
    $script:BullBars    = Bars (@(1..80 | ForEach-Object { 100.0 + $_ }))
    $script:BearBars    = Bars (@(1..80 | ForEach-Object { 200.0 - $_ }))
}

Describe 'Get-SwingRegime size multipliers' {
    Context 'VIX unavailable (no overlay)' {
        BeforeAll { Mock Get-VIXLevel { $null } }
        It 'NEUTRAL = half size (0.50)' {
            $r = Get-SwingRegime $null $NeutralBars
            $r.Regime | Should -Be 'NEUTRAL'; [double]$r.SizeMult | Should -Be 0.5
        }
        It 'insufficient data defaults to NEUTRAL at half size' {
            $r = Get-SwingRegime $null (Bars @(1..10 | ForEach-Object { 100.0 }))
            $r.Regime | Should -Be 'NEUTRAL'; [double]$r.SizeMult | Should -Be 0.5
        }
        It 'BULL unchanged (1.0)' { $r = Get-SwingRegime $null $BullBars; $r.Regime | Should -Be 'BULL'; [double]$r.SizeMult | Should -Be 1.0 }
        It 'BEAR unchanged (0.75)' { $r = Get-SwingRegime $null $BearBars; $r.Regime | Should -Be 'BEAR'; [double]$r.SizeMult | Should -Be 0.75 }
    }
    Context 'VIX overlay still stacks on NEUTRAL' {
        It 'VIX 20 normal -> 0.50' { Mock Get-VIXLevel { 20.0 }; [double](Get-SwingRegime $null $NeutralBars).SizeMult | Should -Be 0.5 }
        It 'VIX 27 elevated -> 0.50 x 0.60 = 0.30' { Mock Get-VIXLevel { 27.0 }; [double](Get-SwingRegime $null $NeutralBars).SizeMult | Should -Be 0.3 }
        It 'VIX 35 high -> 0.50 x 0.40 = 0.20' { Mock Get-VIXLevel { 35.0 }; [double](Get-SwingRegime $null $NeutralBars).SizeMult | Should -Be 0.2 }
        It 'BEAR + VIX 35 unchanged -> 0.30' { Mock Get-VIXLevel { 35.0 }; [double](Get-SwingRegime $null $BearBars).SizeMult | Should -Be 0.3 }
    }
}
