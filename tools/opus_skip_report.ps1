# tools/opus_skip_report.ps1
# Summarises data/journal_options_skips.jsonl: every skipped candidate and its
# reason (spec 9.7 step 6 -- the owner reviews this before DRY_RUN=false).
#   pwsh ./tools/opus_skip_report.ps1 [-From 2026-10-12] [-To 2026-10-16] [-Out reports/opus_skip_report.md]

param([string]$From, [string]$To, [string]$Out)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'opus_options_core.ps1')
. (Join-Path $root 'opus_options_data.ps1')
Set-OpusRoot $root

$rows = @(Read-OpusJsonl 'data/journal_options_skips.jsonl' | Where-Object {
    $d = ConvertTo-OpusDate $_.date
    (-not $From -or $d -ge $From) -and (-not $To -or $d -le $To)
})
$lines = @("# Opus options skip report", "")
if ($rows.Count -eq 0) { $lines += "No skips recorded in range." }
else {
    $dates = @($rows | ForEach-Object { ConvertTo-OpusDate $_.date } | Sort-Object -Unique)
    $lines += ("{0} skips over {1} evaluation day(s): {2} .. {3}" -f $rows.Count, $dates.Count, $dates[0], $dates[-1]), ""
    $lines += "## By reason", "", "| Reason | Sleeve A | Sleeve B | All/other |", "| --- | ---: | ---: | ---: |"
    foreach ($g in ($rows | Group-Object reason | Sort-Object Count -Descending)) {
        $a = @($g.Group | Where-Object { $_.sleeve -eq 'A' }).Count; $b = @($g.Group | Where-Object { $_.sleeve -eq 'B' }).Count
        $lines += "| $($g.Name) | $a | $b | $($g.Count - $a - $b) |"
    }
    $lines += "", "## Every skip", "", "| Date | Symbol | Sleeve | Reason | Detail |", "| --- | --- | --- | --- | --- |"
    foreach ($r in ($rows | Sort-Object @{ Expression = { ConvertTo-OpusDate $_.date } }, symbol, sleeve)) {
        $lines += "| $(ConvertTo-OpusDate $r.date) | $($r.symbol) | $($r.sleeve) | $($r.reason) | $(([string]$r.detail) -replace '\|', '/') |"
    }
}
$text = ($lines -join "`n") + "`n"
if ($Out) { [System.IO.File]::WriteAllText((Join-Path $root $Out), $text); Write-Host "Written: $Out" } else { Write-Output $text }
