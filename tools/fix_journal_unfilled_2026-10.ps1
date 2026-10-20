# tools/fix_journal_unfilled_2026-10.ps1 -- ONE-TIME correction (owner-approved 2026-10-19).
#
# Two entries that never filled sit in journal 'orphaned' ("position not held;
# exit never journaled"), which reads like a trade with a missing exit:
#   MRNA BRKOUT opened 2026-08-19T14:01:48Z  (89 @ 133.13, stop 126.17)
#   UNH  BRKOUT opened 2026-10-15T13:50:26Z  (21 @ 405.12, stop 383.37)
# This moves them to journal 'unfilled' with outcome UNFILLED (same shape
# Set-JournalUnfilled writes since v1.2). No P&L, no R.
#
# Verification per row, before anything is written:
#   - Alpaca credentials present (ALPACA_API_KEY/SECRET): GET-only order history
#     around opened_at. Requires the matching entry bracket to have filled_qty 0
#     and a terminal unfilled status (canceled/expired/rejected); a fill aborts.
#   - No credentials: journal evidence only -- no 'closed' row for the symbol
#     within +/-1 day of opened_at, and still in 'orphaned'. Marked as such.
#
#   pwsh ./tools/fix_journal_unfilled_2026-10.ps1            # preview only
#   pwsh ./tools/fix_journal_unfilled_2026-10.ps1 -Apply     # write alpaca_journal.json
#   -JournalFile <path> runs against a copy. Idempotent.
param([switch]$Apply, [string]$JournalFile, [switch]$NoAlpaca)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'alpaca_journal.ps1')
if ($JournalFile) { $JournalPath = $JournalFile }

$targets = @(
    @{ Symbol = 'MRNA'; Strategy = 'BRKOUT'; OpenedAt = '2026-08-19T14:01:48Z'; Qty = 89 },
    @{ Symbol = 'UNH';  Strategy = 'BRKOUT'; OpenedAt = '2026-10-15T13:50:26Z'; Qty = 21 }
)

function Get-FixAlpacaCfg {
    if ($NoAlpaca -or -not $env:ALPACA_API_KEY -or -not $env:ALPACA_API_SECRET) { return $null }
    . (Join-Path $root 'alpaca_client.ps1')
    return Load-AlpacaConfig
}

# Pure: decide from an Alpaca order list. Returns @{ Ok; Detail }.
function Test-UnfilledFromOrders($orders, [string]$symbol, [datetime]$openedUtc) {
    $ents = @($orders | Where-Object { $_ -and $_.symbol -eq $symbol -and $_.order_class -eq 'bracket' -and
        [Math]::Abs(((_Journal-AsUtc $_.created_at) - $openedUtc).TotalMinutes) -le 15 })
    if ($ents.Count -eq 0) { return @{ Ok = $false; Detail = "no entry bracket within 15 min of opened_at in Alpaca history" } }
    $filled = @($ents | Where-Object { $_.filled_qty -and [double]$_.filled_qty -gt 0 })
    if ($filled.Count -gt 0) { return @{ Ok = $false; Detail = "entry FILLED (filled_qty $($filled[0].filled_qty)) -- not an unfilled entry" } }
    $live = @($ents | Where-Object { @('canceled','expired','rejected') -notcontains [string]$_.status })
    if ($live.Count -gt 0) { return @{ Ok = $false; Detail = "entry status '$($live[0].status)' is not terminal" } }
    return @{ Ok = $true; Detail = ("alpaca: order {0} status {1}, filled_qty 0" -f $ents[0].id, $ents[0].status) }
}

# Pure: journal-only evidence.
function Test-UnfilledFromJournal($j, [string]$symbol, [datetime]$openedUtc) {
    $cl = @($j.closed | Where-Object { $_.symbol -eq $symbol -and [Math]::Abs(((_Journal-AsUtc $_.opened_at) - $openedUtc).TotalDays) -le 1 })
    if ($cl.Count -gt 0) { return @{ Ok = $false; Detail = "a closed row exists for $symbol near opened_at -- looks filled" } }
    return @{ Ok = $true; Detail = "journal evidence only: no closed row within 1 day, orphaned with no exit (not verified against Alpaca)" }
}

$j = Load-Journal
foreach ($b in 'orphaned','unfilled') { if ($null -eq $j.PSObject.Properties[$b]) { $j | Add-Member -NotePropertyName $b -NotePropertyValue @() -Force } }
$acfg = Get-FixAlpacaCfg
"Mode: {0} | verification: {1} | journal: {2}" -f $(if ($Apply) { 'APPLY' } else { 'PREVIEW' }), $(if ($acfg) { 'Alpaca order history (GET only)' } else { 'journal evidence (no Alpaca credentials)' }), $JournalPath

$changed = 0
foreach ($t in $targets) {
    $tU = _Journal-AsUtc $t.OpenedAt
    $match = { param($r) $r.symbol -eq $t.Symbol -and $r.strategy -eq $t.Strategy -and [int]$r.qty -eq $t.Qty -and [Math]::Abs(((_Journal-AsUtc $r.opened_at) - $tU).TotalSeconds) -le 60 }
    if (@($j.unfilled | Where-Object { & $match $_ }).Count -gt 0) { "SKIP  {0}: already in 'unfilled'" -f $t.Symbol; continue }
    $rows = @($j.orphaned | Where-Object { & $match $_ })
    if ($rows.Count -ne 1) { throw ("{0}: expected exactly 1 matching row in 'orphaned', found {1} -- not touching anything" -f $t.Symbol, $rows.Count) }
    if ($acfg) {
        $after = $tU.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'); $until = $tU.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $ords = Invoke-AlpacaApi $acfg 'GET' "/v2/orders?status=all&symbols=$($t.Symbol)&after=$after&until=$until&nested=true&limit=100"
        if ($null -eq $ords) { throw "$($t.Symbol): Alpaca order history unavailable -- rerun, or pass -NoAlpaca to use journal evidence" }
        $v = Test-UnfilledFromOrders $ords $t.Symbol $tU
    } else { $v = Test-UnfilledFromJournal $j $t.Symbol $tU }
    if (-not $v.Ok) { throw ("{0}: verification failed: {1} -- not touching anything" -f $t.Symbol, $v.Detail) }
    $r = $rows[0]
    "MOVE  {0,-5} {1} opened {2} qty {3} @ {4}: orphaned -> unfilled (UNFILLED)  [{5}]" -f $r.symbol, $r.strategy, $r.opened_at, $r.qty, $r.entry, $v.Detail
    $j.orphaned = @($j.orphaned | Where-Object { $_ -ne $r })
    $r | Add-Member -NotePropertyName unfilled_at     -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $r | Add-Member -NotePropertyName unfilled_reason -NotePropertyValue 'entry never filled (one-time correction 2026-10)' -Force
    $r | Add-Member -NotePropertyName outcome         -NotePropertyValue 'UNFILLED' -Force
    $r | Add-Member -NotePropertyName correction_note -NotePropertyValue ("corrected 2026-10-19: orphaned -> unfilled; " + $v.Detail) -Force
    $j.unfilled = @($j.unfilled) + $r
    $changed++
}
"Result: {0} row(s) to move. open={1} closed={2} orphaned={3} unfilled={4} (after)" -f $changed, @($j.open).Count, @($j.closed).Count, @($j.orphaned).Count, @($j.unfilled).Count
if ($Apply -and $changed -gt 0) { Save-Journal $j; "WRITTEN: $JournalPath" } elseif ($changed -gt 0) { "PREVIEW ONLY -- nothing written. Rerun with -Apply." }
