# One-time: retire the v1.1 carry-over shadows (PFE, NKE) from the aggressive
# dry-run slot book so v1.2 setups can use the 4 stock slots. Touches ONLY
# alpaca_state.json (aggr_shadow_open -> aggr_shadow_closed) and appends an
# audit line to data/journal_swing_skips.jsonl. No Alpaca calls, no orders,
# legacy positions/journal untouched. pnl = 0 and aggr_shadow_realized is NOT
# changed, so the retirement does not count as a v1.2 result.
# Usage: pwsh tools/retire_shadow_v11_carryover_2026-10.ps1 [-Apply]
param([switch]$Apply, [string[]]$Symbols = @('PFE','NKE'),
      [string]$StatePath = (Join-Path $PSScriptRoot '..' 'alpaca_state.json'),
      [string]$SkipJournal = (Join-Path $PSScriptRoot '..' 'data' 'journal_swing_skips.jsonl'))

function Invoke-RetireShadows($state, [string[]]$syms, [string]$nowIso) {
    $keep = @(); $retired = @()
    foreach ($s in @($state.aggr_shadow_open)) {
        if ($null -eq $s) { continue }
        if ($syms -contains $s.sym) {
            $c = $s | Select-Object *
            $c | Add-Member -NotePropertyName exit -NotePropertyValue $null -Force
            $c | Add-Member -NotePropertyName exit_reason -NotePropertyValue 'RETIRED_V11_CARRYOVER' -Force
            $c | Add-Member -NotePropertyName pnl -NotePropertyValue 0.0 -Force
            $c | Add-Member -NotePropertyName retired_at -NotePropertyValue $nowIso -Force
            $c | Add-Member -NotePropertyName excluded_from_results -NotePropertyValue $true -Force
            $retired += $c
        } else { $keep += $s }
    }
    $state.aggr_shadow_open = @($keep)
    if ($retired.Count) { $state.aggr_shadow_closed = @(@($state.aggr_shadow_closed) + $retired | Select-Object -Last 100) }
    return ,$retired
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by tests
$state = Get-Content $StatePath -Raw | ConvertFrom-Json
$now = (Get-Date).ToUniversalTime().ToString('o')
$r = Invoke-RetireShadows $state $Symbols $now
Write-Host ("Retire: {0}  | remaining open: {1}" -f (($r | ForEach-Object sym) -join ','), ((@($state.aggr_shadow_open) | ForEach-Object sym) -join ','))
if (-not $Apply) { Write-Host 'Preview only. Re-run with -Apply to write.'; return }
if ($r.Count -eq 0) { Write-Host 'Nothing to retire.'; return }
$state | ConvertTo-Json -Depth 20 | Set-Content $StatePath -Encoding utf8
foreach ($x in $r) {
    (@{ ts = $now; sym = $x.sym; event = 'SHADOW_RETIRED'; skip_reason = 'DRYRUN_EXIT'; exit_reason = 'RETIRED_V11_CARRYOVER'; dry_run = $true
        kind = $x.kind; qty = $x.qty; entry = $x.entry; stop = $x.stop; tp = $x.tp; opened_at = $x.opened_at; pnl = 0.0
        note = 'v1.1 carry-over removed from v1.2 dry-run slots by owner decision; not a v1.2 result' } | ConvertTo-Json -Compress) | Add-Content $SkipJournal
}
Write-Host 'Applied.'
