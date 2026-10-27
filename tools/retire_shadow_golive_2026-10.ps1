# One-time: retire ALL open aggressive dry-run shadows at the go-live flip so
# the live book starts clean. Touches ONLY alpaca_state.json (aggr_shadow_open
# -> aggr_shadow_closed) and appends audit lines to data/journal_swing_skips.jsonl.
# No Alpaca calls, no orders, legacy positions/journal untouched.
# Paper P&L at the flip is logged for the record (from -Marks); excluded_from_results
# stays true and aggr_shadow_realized is NOT changed, so the dry-run book is not
# counted as a live result.
# Usage:
#   pwsh tools/retire_shadow_golive_2026-10.ps1
#   pwsh tools/retire_shadow_golive_2026-10.ps1 -Marks @{ V=420; UNH=400; ... } -Apply
param(
    [switch]$Apply,
    [string[]]$Symbols = @(),   # empty = every open shadow
    [hashtable]$Marks = @{},    # sym -> mark price for paper PnL; missing => pnl 0
    [string]$StatePath = (Join-Path $PSScriptRoot '..' 'alpaca_state.json'),
    [string]$SkipJournal = (Join-Path $PSScriptRoot '..' 'data' 'journal_swing_skips.jsonl')
)

function Get-RetireGolivePaperPnl($sh, $marks) {
    if ($null -eq $sh -or $null -eq $marks) { return 0.0 }
    $sym = [string]$sh.sym
    if (-not $marks.ContainsKey($sym)) { return 0.0 }
    $exitPx = [double]$marks[$sym]
    $dir = if ($sh.side -eq 'sell') { -1.0 } else { 1.0 }
    return [Math]::Round($dir * ($exitPx - [double]$sh.entry) * [double]$sh.qty, 2)
}

function Invoke-RetireGoliveShadows($state, [string[]]$syms, [string]$nowIso, [hashtable]$marks) {
    $filter = @($syms | Where-Object { $_ })
    $all = ($filter.Count -eq 0)
    $keep = @(); $retired = @()
    foreach ($s in @($state.aggr_shadow_open)) {
        if ($null -eq $s) { continue }
        if ($all -or ($filter -contains $s.sym)) {
            $pnl = Get-RetireGolivePaperPnl $s $marks
            $c = $s | Select-Object *
            $c | Add-Member -NotePropertyName exit -NotePropertyValue $(if ($marks.ContainsKey([string]$s.sym)) { [double]$marks[[string]$s.sym] } else { $null }) -Force
            $c | Add-Member -NotePropertyName exit_reason -NotePropertyValue 'RETIRED_AT_GOLIVE' -Force
            $c | Add-Member -NotePropertyName pnl -NotePropertyValue $pnl -Force
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
$r = Invoke-RetireGoliveShadows $state $Symbols $now $Marks
$names = @($r | ForEach-Object sym) -join ','
$left  = @($state.aggr_shadow_open | ForEach-Object sym) -join ','
Write-Host ("Retire go-live: {0}  | remaining open: {1}  | realized unchanged: {2}" -f $names, $left, $state.aggr_shadow_realized)
foreach ($x in $r) { Write-Host ("  {0}: paper_pnl={1} exit={2}" -f $x.sym, $x.pnl, $x.exit) }
if (-not $Apply) { Write-Host 'Preview only. Re-run with -Apply to write.'; return }
if ($r.Count -eq 0) { Write-Host 'Nothing to retire.'; return }
$state | ConvertTo-Json -Depth 20 | Set-Content $StatePath -Encoding utf8
foreach ($x in $r) {
    (@{ ts = $now; sym = $x.sym; event = 'SHADOW_RETIRED'; skip_reason = 'DRYRUN_EXIT'; exit_reason = 'RETIRED_AT_GOLIVE'; dry_run = $true
        kind = $x.kind; qty = $x.qty; entry = $x.entry; stop = $x.stop; tp = $x.tp; opened_at = $x.opened_at
        exit = $x.exit; pnl = $x.pnl; excluded_from_results = $true
        note = 'dry-run shadow retired at go-live flip by owner decision; paper PnL logged for record, excluded from live results' } | ConvertTo-Json -Compress) | Add-Content $SkipJournal
}
Write-Host 'Applied.'
