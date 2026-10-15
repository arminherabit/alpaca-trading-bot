# tools/fix_journal_pyramid_2026-08.ps1 -- ONE-TIME correction (owner-approved).
#
# In Aug 2026 one market sell flattened base + PYRA tranches together (SNOW 14+7
# on 2026-08-19, MSFT 14+7 on 2026-08-20). Sync-ClosedTrades credited the whole
# 21-share fill to the PYRA row, priced off the PYRA entry, and the base row was
# later moved to 'orphaned' with no P&L. Values below are from the Alpaca orders
# (filled_avg_price of each entry and of the 21-share exit), verified read-only.
#
#   pwsh ./tools/fix_journal_pyramid_2026-08.ps1          # preview only
#   pwsh ./tools/fix_journal_pyramid_2026-08.ps1 -Apply   # write alpaca_journal.json
#   -JournalFile <path> runs against a copy instead (for checking).
#
# Idempotent: rows already carrying correction_note are left alone.
param([switch]$Apply, [string]$JournalFile)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'alpaca_journal.ps1')
if ($JournalFile) { $JournalPath = $JournalFile }

$note = "corrected 2026-10-15: one 21-share exit split FIFO across base+PYRA (journal bug)"
$fixes = @(
    # PYRA rows: keep the row, replace P&L with the 7-share tranche priced off its own fill.
    @{ Symbol = 'SNOW'; Strategy = 'PYRA';   Bucket = 'closed';   Fill = 312.00; Exit = 321.04; Qty = 7;  ExitAt = '2026-08-19T13:33:26Z' },
    @{ Symbol = 'MSFT'; Strategy = 'PYRA';   Bucket = 'closed';   Fill = 494.11; Exit = 481.78; Qty = 7;  ExitAt = '2026-08-20T13:36:13Z' },
    # Base rows: move from orphaned to closed with their own P&L.
    @{ Symbol = 'SNOW'; Strategy = 'BRKOUT'; Bucket = 'orphaned'; Fill = 283.26; Exit = 321.04; Qty = 14; ExitAt = '2026-08-19T13:33:26Z' },
    @{ Symbol = 'MSFT'; Strategy = 'BRKOUT'; Bucket = 'orphaned'; Fill = 459.99; Exit = 481.78; Qty = 14; ExitAt = '2026-08-20T13:36:13Z' }
)

$j = Load-Journal
if ($null -eq $j.PSObject.Properties['orphaned']) { $j | Add-Member -NotePropertyName orphaned -NotePropertyValue @() -Force }
$changed = 0
foreach ($f in $fixes) {
    $rows = @($j.($f.Bucket) | Where-Object { $_.symbol -eq $f.Symbol -and $_.strategy -eq $f.Strategy -and [int]$_.qty -eq $f.Qty })
    if ($rows.Count -ne 1) {
        $done = @($j.closed | Where-Object { $_.symbol -eq $f.Symbol -and $_.strategy -eq $f.Strategy -and $_.correction_note })
        if ($done.Count -gt 0) { "SKIP  {0} {1}: already corrected" -f $f.Symbol, $f.Strategy; continue }
        throw ("{0} {1}: expected exactly 1 row in '{2}' with qty {3}, found {4} -- not touching anything" -f $f.Symbol, $f.Strategy, $f.Bucket, $f.Qty, $rows.Count)
    }
    $r = $rows[0]
    if ($r.correction_note) { "SKIP  {0} {1}: already corrected" -f $f.Symbol, $f.Strategy; continue }
    $pnl  = [Math]::Round(($f.Exit - $f.Fill) * $f.Qty, 2)
    $rM   = if ([double]$r.risk_usd -gt 0) { [Math]::Round($pnl / [double]$r.risk_usd, 2) } else { 0.0 }
    $out  = if ([Math]::Abs($rM) -lt 0.15) { "SCRATCH" } elseif ($pnl -gt 0) { "WIN" } else { "LOSS" }
    $hold = _Journal-WeekdayCount (_Journal-AsUtc $r.opened_at) (_Journal-AsUtc $f.ExitAt)
    $before = if ($f.Bucket -eq 'closed') { "pnl {0} / {1}R ({2})" -f $r.pnl, $r.r_multiple, $r.outcome } else { "orphaned, no P&L" }
    "{0,-5} {1,-6} {2,-30} -> pnl {3} / {4}R ({5}), exit {6} @ {7}, held {8}d" -f $f.Symbol, $f.Strategy, $before, $pnl, $rM, $out, $f.Exit, $f.ExitAt, $hold
    foreach ($kv in @{ closed_at = $f.ExitAt; exit = $f.Exit; pnl = $pnl; r_multiple = $rM; hold_days = $hold; outcome = $out; fill_price = $f.Fill; correction_note = $note }.GetEnumerator()) {
        $r | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force
    }
    if ($f.Bucket -eq 'orphaned') {
        foreach ($p in 'orphaned_at', 'orphan_reason') { $r.PSObject.Properties.Remove($p) }
        $j.orphaned = @($j.orphaned | Where-Object { $_ -ne $r })
        $j.closed   = @($j.closed) + $r
    }
    $changed++
}
if ($Apply -and $changed -gt 0) { Save-Journal $j; "WROTE $JournalPath ($changed rows)" }
elseif ($changed -gt 0) { "PREVIEW ONLY ($changed rows) -- re-run with -Apply to write" }
