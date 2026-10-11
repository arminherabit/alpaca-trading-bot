# opus_options_data.ps1
# Opus options sleeves (spec v1.2) -- files: state, journals, universe, earnings.
#
# Network access in this file is limited to the Nasdaq earnings calendar, and
# even that goes through an injectable fetcher (-Fetcher) so tests run offline.
#
# Mapping decisions recorded here (spec 2.3 / 7 / 8.2):
# - EARNINGS_FILE is Opus's own file. The swing bot's earnings_calendar.json
#   keeps its 14-day format and behaviour (swing logic unchanged). Opus reuses
#   the same Nasdaq endpoint and browser headers, but needs a fetch that can
#   tell "no earnings that day" from "request failed": the swing helper returns
#   an empty list for both, and a refresh that misses a day MUST NOT be written.
# - Only universe + override symbols are stored (not every US issuer), so the
#   committed file stays small. Re-run tools/backfill_earnings.ps1 -Force after
#   adding symbols to the universe to seed their last_earnings_date.
# - Trade records: open trades live in state; one final record per position is
#   appended to journal_options.jsonl when it closes ("one record per position").

$script:OPUS_NASDAQ_HEADERS = @{
    "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Accept"          = "application/json, text/plain, */*"
    "Accept-Language" = "en-US,en;q=0.9"
    "Origin"          = "https://www.nasdaq.com"
    "Referer"         = "https://www.nasdaq.com/market-activity/earnings"
}

# ── JSON helpers ──────────────────────────────────────────────────────────────

function Set-OpusRoot([string]$path) { $script:OPUS_ROOT = $path }

function Resolve-OpusPath([string]$relative) {
    if ([System.IO.Path]::IsPathRooted($relative)) { return $relative }
    $root = if ($script:OPUS_ROOT) { $script:OPUS_ROOT } else { $PSScriptRoot }
    return (Join-Path $root $relative)
}

# Reads a JSON file into hashtables. Dates stay strings where the host allows it
# (ConvertFrom-Json -DateKind String, PowerShell 7.5+); every date consumer also
# goes through ConvertTo-OpusDate, so older hosts work too.
function Read-OpusJson([string]$path) {
    $full = Resolve-OpusPath $path
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    $raw = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $cmd = Get-Command ConvertFrom-Json
    if ($cmd.Parameters.ContainsKey('DateKind')) { return ($raw | ConvertFrom-Json -AsHashtable -DateKind String) }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

# Atomic write: temp file then move, so a killed runner never leaves half a file.
function Write-OpusJson([string]$path, $object, [int]$depth = 30) {
    $full = Resolve-OpusPath $path
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$full.tmp"
    $json = ConvertTo-Json -InputObject $object -Depth $depth
    [System.IO.File]::WriteAllText($tmp, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $full -Force
}

function Add-OpusJsonl([string]$path, $object) {
    $full = Resolve-OpusPath $path
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = ConvertTo-Json -InputObject $object -Depth 20 -Compress
    [System.IO.File]::AppendAllText($full, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Read-OpusJsonl([string]$path) {
    $full = Resolve-OpusPath $path
    if (-not (Test-Path -LiteralPath $full)) { return }
    $out = @()
    $cmd = Get-Command ConvertFrom-Json
    foreach ($line in [System.IO.File]::ReadAllLines($full)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = if ($cmd.Parameters.ContainsKey('DateKind')) { $line | ConvertFrom-Json -AsHashtable -DateKind String } else { $line | ConvertFrom-Json -AsHashtable }
            $out += , $o
        } catch { }
    }
    foreach ($o in $out) { $o }   # unrolled; callers collect with @(...)
}

# Returns elements unrolled; callers collect with @(...). (A ,@() return here
# plus @() at the call site double-wraps: the caller then sees ONE element,
# the whole array.)
function ConvertTo-OpusArray($value) {
    if ($null -eq $value) { return }
    foreach ($v in @($value)) { $v }
}

# ── Journal paths (spec 7; 8.2 git-add list) ──────────────────────────────────

function Get-OpusJournalPath([string]$kind) {
    switch ($kind) {
        'trades' { return 'data/journal_options.jsonl' }
        'orders' { return 'data/journal_options_orders.jsonl' }
        'skips'  { return 'data/journal_options_skips.jsonl' }
    }
}

# ── State ─────────────────────────────────────────────────────────────────────

function New-OpusState($cfg) {
    return [ordered]@{
        strategy_version       = $cfg.STRATEGY_VERSION
        hwm                    = [double]$cfg.STARTING_CAPITAL
        hwm_dry                = [double]$cfg.STARTING_CAPITAL
        dd_mode                = $false
        hwm_at_trigger         = $null
        max_drawdown           = 0.0
        day_start_date         = $null
        day_start_equity       = $null
        entries_halted_date    = $null
        consec_losses          = 0
        pause_until            = $null
        strategy_halted        = $false
        manual_review_required = $false
        last_entry_eval_date   = $null
        last_earnings_refresh  = $null
        reviewed_20            = $false
        golive_gates_met       = $false
        positions              = @()
        working_orders         = @()
        cooldown               = @{}
        bar_cache              = @{}
        info_logged            = @{}
        last_scan              = $null
    }
}

function Import-OpusState($cfg) {
    $s = $null
    try { $s = Read-OpusJson $cfg.STATE_FILE } catch { $s = $null }
    $fresh = New-OpusState $cfg
    if ($null -eq $s) { return @{ State = $fresh; Rebuilt = $true } }
    foreach ($k in @($fresh.Keys)) { if (-not $s.ContainsKey($k)) { $s[$k] = $fresh[$k] } }
    $s.positions      = @(ConvertTo-OpusArray $s.positions)
    $s.working_orders = @(ConvertTo-OpusArray $s.working_orders)
    foreach ($h in 'cooldown', 'bar_cache', 'info_logged') { if ($s[$h] -isnot [hashtable]) { $s[$h] = @{} } }
    return @{ State = $s; Rebuilt = $false }
}

function Save-OpusState($state, $cfg) { Write-OpusJson $cfg.STATE_FILE $state }

# ── Universe (2.3) ────────────────────────────────────────────────────────────

# Returns @{ Symbols; Dropped; RefreshedAt; AgeDays; Warn; Stale; TooSmall; Source }.
function Import-OpusUniverse($cfg, [string]$today) {
    $u = Read-OpusJson $cfg.UNIVERSE_FILE
    if ($null -eq $u) { return @{ Symbols = @(); Dropped = @(); RefreshedAt = $null; AgeDays = $null; Warn = $true; Stale = $true; TooSmall = $true; Source = $null } }
    $keep = @(); $dropped = @()
    foreach ($e in @(ConvertTo-OpusArray $u.symbols)) {
        $sym = ([string]$e.symbol).Trim().ToUpper()
        $why = @()
        if (-not ([double]$e.roic -gt [double]$cfg.MIN_ROIC)) { $why += ("roic {0} <= {1}" -f $e.roic, $cfg.MIN_ROIC) }
        if (-not ([double]$e.rev_growth -gt [double]$cfg.MIN_REV_GROWTH)) { $why += ("rev_growth {0} <= {1}" -f $e.rev_growth, $cfg.MIN_REV_GROWTH) }
        if ($cfg.REQUIRE_FCF_POSITIVE -and -not ($e.fcf_positive -eq $true)) { $why += "fcf_positive false" }
        if ($why.Count -eq 0) { $keep += $sym } else { $dropped += @{ symbol = $sym; reason = ($why -join '; ') } }
    }
    $refreshed = ConvertTo-OpusDate $u.refreshed_at
    $age = if ($null -ne $refreshed) { Get-OpusDayDiff $refreshed $today } else { $null }
    return @{
        Symbols = $keep; Dropped = $dropped; RefreshedAt = $refreshed; AgeDays = $age; Source = $u.source
        Warn  = ($null -eq $age -or $age -gt [int]$cfg.UNIVERSE_STALE_WARN_DAYS)
        Stale = ($null -eq $age -or $age -gt [int]$cfg.UNIVERSE_STALE_BLOCK_DAYS)
        TooSmall = ($keep.Count -lt 10)
    }
}

# ── Earnings feed (2.3) ───────────────────────────────────────────────────────

# One Nasdaq calendar day. Returns @{ Ok; Symbols } -- Ok = $false only when the
# request or the response is unusable; a day with no rows is Ok with no symbols.
function Invoke-OpusNasdaqDay([string]$date) {
    try {
        $r = Invoke-RestMethod -Uri "https://api.nasdaq.com/api/calendar/earnings?date=$date" -Method GET `
                -Headers $script:OPUS_NASDAQ_HEADERS -UseBasicParsing -TimeoutSec 15
    } catch { return @{ Ok = $false; Symbols = @(); Error = $_.Exception.Message } }
    if ($null -eq $r -or $null -eq $r.status -or [int]$r.status.rCode -ne 200 -or $null -eq $r.data) {
        return @{ Ok = $false; Symbols = @(); Error = 'unexpected response' }
    }
    $syms = @()
    foreach ($row in @($r.data.rows)) {
        if ($null -eq $row -or $null -eq $row.symbol) { continue }
        $s = ([string]$row.symbol).Trim().ToUpper()
        if ($s.Length -eq 0 -or $s.Length -gt 6 -or $s -match '[^A-Z.]') { continue }
        $syms += $s
    }
    return @{ Ok = $true; Symbols = $syms }
}

# Fetch every date in [from, to]. Retries each failing day once. Returns
# @{ Ok; ByDate (date -> symbols); Failed (dates) }.
function Get-OpusEarningsWindow([string]$from, [string]$to, [scriptblock]$Fetcher, [int]$delayMs = 250) {
    if (-not $Fetcher) { $Fetcher = { param($d) Invoke-OpusNasdaqDay $d } }
    $byDate = @{}; $failed = @()
    $d = $from
    while ($d -le $to) {
        $res = & $Fetcher $d
        if (-not $res.Ok) { Start-Sleep -Milliseconds 1500; $res = & $Fetcher $d }
        if (-not $res.Ok) { $failed += $d } else { $byDate[$d] = @($res.Symbols) }
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
        $d = Add-OpusDays $d 1
    }
    return @{ Ok = ($failed.Count -eq 0); ByDate = $byDate; Failed = $failed }
}

function New-OpusEarningsFile { return [ordered]@{ refreshed_at = $null; source = 'nasdaq'; window = $null; backfill_completed_at = $null; symbols = @{} } }

# Daily refresh: today-lookback .. today+lookahead. Carries every stored
# last_earnings_date forward; a stored value is replaced only by a later date.
# On any failed day nothing is written. Returns @{ Written; Reason; Failed }.
function Update-OpusEarnings($cfg, [string]$today, [string[]]$symbols, [scriptblock]$Fetcher, [string]$nowIso, [int]$delayMs = 250) {
    $from = Add-OpusDays $today (-[int]$cfg.EARNINGS_LOOKBACK_DAYS)
    $to   = Add-OpusDays $today ([int]$cfg.EARNINGS_LOOKAHEAD_DAYS)
    $win = Get-OpusEarningsWindow $from $to $Fetcher $delayMs
    if (-not $win.Ok) { return @{ Written = $false; Reason = 'EARNINGS_REFRESH_FAILED'; Failed = $win.Failed } }

    $prev = Read-OpusJson $cfg.EARNINGS_FILE
    $file = New-OpusEarningsFile
    if ($null -ne $prev) { $file.backfill_completed_at = $prev.backfill_completed_at }
    $prevSyms = if ($null -ne $prev -and $prev.symbols -is [hashtable]) { $prev.symbols } else { @{} }
    $want = @{}; foreach ($s in $symbols) { $want[$s.ToUpper()] = $true }
    foreach ($s in $prevSyms.Keys) { $want[$s] = $true }

    foreach ($s in $want.Keys) {
        $next = $null; $last = $null
        foreach ($d in ($win.ByDate.Keys | Sort-Object)) {
            if (@($win.ByDate[$d]) -notcontains $s) { continue }
            if ($d -ge $today -and $null -eq $next) { $next = $d }
            if ($d -lt $today) { $last = $d }
        }
        $stored = if ($prevSyms.ContainsKey($s)) { ConvertTo-OpusDate $prevSyms[$s].last_earnings_date } else { $null }
        if ($null -eq $last -or ($null -ne $stored -and $stored -gt $last)) { $last = $stored }
        $file.symbols[$s] = [ordered]@{ next_earnings_date = $next; last_earnings_date = $last; confirmed = $false }
    }
    $file.refreshed_at = $nowIso
    $file.window = [ordered]@{ from = $from; to = $to }
    Write-OpusJson $cfg.EARNINGS_FILE $file
    return @{ Written = $true; Reason = $null; Failed = @() }
}

# One-time backfill: today-backfill_days .. today-1 seeds last_earnings_date.
# next_earnings_date untouched. On any failed day nothing is written.
function Invoke-OpusEarningsBackfill($cfg, [string]$today, [string[]]$symbols, [scriptblock]$Fetcher, [string]$nowIso, [int]$delayMs = 250, [switch]$Force) {
    $prev = Read-OpusJson $cfg.EARNINGS_FILE
    if (-not $Force -and $null -ne $prev -and $null -ne $prev.backfill_completed_at) {
        return @{ Written = $false; Reason = 'ALREADY_DONE'; Failed = @(); Missing = @() }
    }
    $from = Add-OpusDays $today (-[int]$cfg.EARNINGS_BACKFILL_DAYS)
    $to   = Add-OpusDays $today (-1)
    $win = Get-OpusEarningsWindow $from $to $Fetcher $delayMs
    if (-not $win.Ok) { return @{ Written = $false; Reason = 'EARNINGS_BACKFILL_FAILED'; Failed = $win.Failed; Missing = @() } }

    $file = if ($null -ne $prev) { $prev } else { New-OpusEarningsFile }
    if ($file.symbols -isnot [hashtable]) { $file.symbols = @{} }
    $want = @{}; foreach ($s in $symbols) { $want[$s.ToUpper()] = $true }
    foreach ($s in $file.symbols.Keys) { $want[$s] = $true }
    $missing = @()
    foreach ($s in $want.Keys) {
        $latest = $null
        foreach ($d in $win.ByDate.Keys) { if (@($win.ByDate[$d]) -contains $s -and ($null -eq $latest -or $d -gt $latest)) { $latest = $d } }
        if (-not $file.symbols.ContainsKey($s)) { $file.symbols[$s] = [ordered]@{ next_earnings_date = $null; last_earnings_date = $null; confirmed = $false } }
        $stored = ConvertTo-OpusDate $file.symbols[$s].last_earnings_date
        if ($null -ne $latest -and ($null -eq $stored -or $latest -gt $stored)) { $file.symbols[$s].last_earnings_date = $latest }
        if ($null -eq (ConvertTo-OpusDate $file.symbols[$s].last_earnings_date)) { $missing += $s }
    }
    $file.backfill_completed_at = $nowIso
    Write-OpusJson $cfg.EARNINGS_FILE $file
    return @{ Written = $true; Reason = $null; Failed = @(); Missing = ($missing | Sort-Object) }
}

# Merged per-symbol earnings (feed + override). Returns @{ Feed; Override; Stale; Get }.
function Import-OpusEarnings($cfg, [string]$today) {
    $feed = Read-OpusJson $cfg.EARNINGS_FILE
    $ovr  = Read-OpusJson $cfg.EARNINGS_OVERRIDE_FILE
    $feedSyms = if ($null -ne $feed -and $feed.symbols -is [hashtable]) { $feed.symbols } else { @{} }
    $ovrSyms  = if ($null -ne $ovr -and $ovr.symbols -is [hashtable]) { $ovr.symbols } else { @{} }
    $refreshed = if ($null -ne $feed) { ConvertTo-OpusDate $feed.refreshed_at } else { $null }
    $age = if ($null -ne $refreshed) { Get-OpusDayDiff $refreshed $today } else { $null }
    return @{
        FeedSymbols = $feedSyms; OverrideSymbols = $ovrSyms; RefreshedAt = $refreshed
        Stale = ($null -eq $age -or $age -gt [int]$cfg.EARNINGS_STALE_BLOCK_DAYS)
    }
}

function Get-OpusEarningsFor($earnings, [string]$symbol) {
    $f = if ($earnings.FeedSymbols.ContainsKey($symbol)) { $earnings.FeedSymbols[$symbol] } else { $null }
    $o = if ($earnings.OverrideSymbols.ContainsKey($symbol)) { $earnings.OverrideSymbols[$symbol] } else { $null }
    return Merge-OpusEarnings $f $o
}

# ── Skip / order / trade journals ─────────────────────────────────────────────

function Add-OpusSkip([string]$date, [string]$symbol, [string]$sleeve, [string]$reason, [string]$detail) {
    Add-OpusJsonl (Get-OpusJournalPath 'skips') ([ordered]@{ date = $date; symbol = $symbol; sleeve = $sleeve; reason = $reason; detail = $detail })
}

function Add-OpusOrderEvent($evt) { Add-OpusJsonl (Get-OpusJournalPath 'orders') $evt }

function Add-OpusClosedTrade($trade) { Add-OpusJsonl (Get-OpusJournalPath 'trades') $trade }

function Get-OpusClosedTrades { return @(Read-OpusJsonl (Get-OpusJournalPath 'trades')) }

# ── IV history (7.3) ──────────────────────────────────────────────────────────

# Appends today's IV per symbol (once per date) and returns iv_rank per symbol
# (null until 252 observations).
function Update-OpusIvHistory($cfg, [string]$today, [hashtable]$ivBySymbol) {
    $h = Read-OpusJson $cfg.IV_HISTORY_FILE
    if ($null -eq $h -or $h.symbols -isnot [hashtable]) { $h = [ordered]@{ symbols = @{} } }
    $ranks = @{}
    foreach ($s in $ivBySymbol.Keys) {
        $series = @(ConvertTo-OpusArray $h.symbols[$s])
        $series = @($series | Where-Object { (ConvertTo-OpusDate $_.d) -ne $today })
        $series += , ([ordered]@{ d = $today; iv = [double]$ivBySymbol[$s] })
        if ($series.Count -gt 400) { $series = @($series | Select-Object -Last 400) }
        $h.symbols[$s] = $series
        $rank = $null
        if ($series.Count -ge 252) {
            $vals = @($series | Select-Object -Last 252 | ForEach-Object { [double]$_.iv })
            $mn = ($vals | Measure-Object -Minimum).Minimum; $mx = ($vals | Measure-Object -Maximum).Maximum
            if ($mx -gt $mn) { $rank = ([double]$ivBySymbol[$s] - $mn) / ($mx - $mn) }
        }
        $ranks[$s] = $rank
    }
    Write-OpusJson $cfg.IV_HISTORY_FILE $h
    return $ranks
}
