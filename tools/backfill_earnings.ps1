# tools/backfill_earnings.ps1
# One-time earnings backfill (spec v1.2, section 2.3): requests every calendar
# date in [today - EARNINGS_BACKFILL_DAYS, today - 1] from the Nasdaq calendar
# and seeds last_earnings_date for every universe + override symbol.
#
# The scan runs this automatically on its first daily refresh when the earnings
# file has no backfill_completed_at. Run it by hand (or via workflow_dispatch)
# to redo it, e.g. after adding symbols to data/universe.json:
#   pwsh ./tools/backfill_earnings.ps1 -Force
#
# Same function as the automatic path (Invoke-OpusEarningsBackfill), so both
# produce the same file. A backfill that misses any day writes nothing.

param([switch]$Force, [int]$DelayMs = 250)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'opus_options_core.ps1')
. (Join-Path $root 'opus_options_data.ps1')
Set-OpusRoot $root

$cfg = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config/opus_options_config.psd1')
$v = Test-OpusConfig $cfg
if (-not $v.Valid) { Write-Host ("CONFIG_INVALID: " + ($v.Errors -join '; ')) -ForegroundColor Red; exit 1 }

$tz = $null; foreach ($id in 'America/New_York', 'Eastern Standard Time') { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
$today = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).ToString('yyyy-MM-dd')

$uni = Read-OpusJson $cfg.UNIVERSE_FILE
$ovr = Read-OpusJson $cfg.EARNINGS_OVERRIDE_FILE
$syms = @()
if ($null -ne $uni) { $syms += @(@($uni.symbols) | Where-Object { $_ } | ForEach-Object { ([string]$_.symbol).ToUpper() }) }
if ($null -ne $ovr -and $ovr.symbols -is [hashtable]) { $syms += @($ovr.symbols.Keys) }
$syms = @($syms | Sort-Object -Unique)

Write-Host ("Backfilling {0} days for {1} symbols (today {2})..." -f $cfg.EARNINGS_BACKFILL_DAYS, $syms.Count, $today)
$r = Invoke-OpusEarningsBackfill $cfg $today $syms $null ([datetime]::UtcNow.ToString('o')) $DelayMs -Force:$Force
if ($r.Written) {
    Write-Host "Backfill written: $($cfg.EARNINGS_FILE)" -ForegroundColor Green
    if (@($r.Missing).Count) { Write-Host ("No report in the window (use data/earnings_override.json if needed): " + ($r.Missing -join ', ')) -ForegroundColor Yellow }
    exit 0
}
if ($r.Reason -eq 'ALREADY_DONE') { Write-Host 'Backfill already completed (backfill_completed_at present). Use -Force to redo.' -ForegroundColor Yellow; exit 0 }
Write-Host ("{0}: {1} day(s) failed; nothing written." -f $r.Reason, @($r.Failed).Count) -ForegroundColor Red
exit 1
