# alpaca_earnings.ps1
# Earnings calendar -- pulls the next ~14 days of US equity earnings from
# Nasdaq's public calendar endpoint and caches to earnings_calendar.json.
#
# Why this matters: earnings is a binary event with unpredictable direction.
# A pro never holds through it (blackout). But the 3-10 day pre-earnings
# window often shows institutional positioning ("run-up"), which is genuine
# edge worth biasing toward.
#
# Strategy plug-in points:
#   HARD REJECT:     symbol has earnings within $cfg.earnings_blackout_days
#   SCORE BONUS:     symbol has earnings in 3..$cfg.earnings_runup_days
#
# Exports:
#   Refresh-EarningsCalendar  $cfg [forceRefresh]   -> int (events cached)
#   Get-DaysToEarnings        $symbol               -> int or $null
#   Test-EarningsBlackout     $symbol $blackoutDays -> bool
#
# Cache file schema (earnings_calendar.json):
#   { last_refreshed: ISO8601, events: [ { symbol, date, time } ] }

$EarningsPath = Join-Path $PSScriptRoot "earnings_calendar.json"

# ── Cache I/O ─────────────────────────────────────────────────────────────────

function Load-EarningsCalendar {
    if (Test-Path $EarningsPath) {
        try { return Get-Content $EarningsPath -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{
        last_refreshed = ""
        events         = @()
    }
}

function Save-EarningsCalendar($cal) {
    $cal | ConvertTo-Json -Depth 5 | Set-Content $EarningsPath
}

# ── Nasdaq fetch ──────────────────────────────────────────────────────────────
# Nasdaq's calendar endpoint serves a single day; we walk forward two weeks.

function _Fetch-NasdaqEarningsForDate([datetime]$date) {
    $dateStr = $date.ToString("yyyy-MM-dd")
    $uri = "https://api.nasdaq.com/api/calendar/earnings?date=$dateStr"
    $headers = @{
        "User-Agent"      = "Mozilla/5.0 (compatible; alpaca-bot/1.0)"
        "Accept"          = "application/json"
        "Accept-Language" = "en-US,en;q=0.9"
    }
    try {
        $r = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing -TimeoutSec 15
        if ($null -eq $r -or $null -eq $r.data -or $null -eq $r.data.rows) { return @() }
        $out = @()
        foreach ($row in $r.data.rows) {
            if ($null -eq $row.symbol -or [string]::IsNullOrWhiteSpace([string]$row.symbol)) { continue }
            $sym = ([string]$row.symbol).Trim().ToUpper()
            if ($sym.Length -gt 5 -or $sym -match '[^A-Z]') { continue }
            $out += [pscustomobject]@{
                symbol = $sym
                date   = $dateStr
                time   = if ($row.time) { [string]$row.time } else { "" }
            }
        }
        return $out
    } catch {
        return @()
    }
}

# ── Refresh ───────────────────────────────────────────────────────────────────

function Refresh-EarningsCalendar {
    param($cfg, [switch]$Force, [int]$lookaheadDays = 14)

    $cal = Load-EarningsCalendar

    # Skip if cache is fresh (<24h old) unless forced
    if (-not $Force -and $cal.last_refreshed -ne "") {
        try {
            $age = (Get-Date) - [datetime]::Parse($cal.last_refreshed)
            if ($age.TotalHours -lt 24) {
                Write-Host ("  [EARNINGS] cache fresh ({0:F1}h old, {1} events)" -f `
                    $age.TotalHours, @($cal.events).Count) -ForegroundColor DarkGray
                return @($cal.events).Count
            }
        } catch {}
    }

    Write-Host ("  [EARNINGS] refreshing from Nasdaq ({0} days forward)..." -f $lookaheadDays) -ForegroundColor Cyan
    $all = @()
    $today = (Get-Date).Date
    for ($d = 0; $d -lt $lookaheadDays; $d++) {
        $dayEvents = _Fetch-NasdaqEarningsForDate $today.AddDays($d)
        if ($dayEvents.Count -gt 0) { $all += $dayEvents }
        Start-Sleep -Milliseconds 250   # be polite to a public endpoint
    }

    if ($all.Count -eq 0) {
        Write-Host "  [EARNINGS] Nasdaq returned no rows -- keeping previous cache" -ForegroundColor DarkYellow
        return @($cal.events).Count
    }

    $cal.events         = $all
    $cal.last_refreshed = (Get-Date).ToString("o")
    Save-EarningsCalendar $cal
    Write-Host ("  [EARNINGS] cached {0} events covering {1} days" -f $all.Count, $lookaheadDays) -ForegroundColor Green
    return $all.Count
}

# ── Lookups ───────────────────────────────────────────────────────────────────

function Get-DaysToEarnings {
    param([string]$symbol)
    $cal = Load-EarningsCalendar
    if ($null -eq $cal.events -or @($cal.events).Count -eq 0) { return $null }

    $today = (Get-Date).Date
    $sym   = $symbol.ToUpper()
    $upcoming = @($cal.events) | Where-Object { $_.symbol -eq $sym -and ([datetime]$_.date) -ge $today }
    if (@($upcoming).Count -eq 0) { return $null }
    $next = $upcoming | Sort-Object { [datetime]$_.date } | Select-Object -First 1
    return [int](([datetime]$next.date - $today).TotalDays)
}

function Test-EarningsBlackout {
    param([string]$symbol, [int]$blackoutDays = 2)
    $d = Get-DaysToEarnings $symbol
    if ($null -eq $d) { return $false }
    return ($d -le $blackoutDays)
}
