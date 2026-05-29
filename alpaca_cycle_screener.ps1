# alpaca_cycle_screener.ps1
# Cycle Leader Detection -- catch the move before it explodes.
#
# Layers on top of alpaca_screener.ps1's base scoring. Adds five signals
# that together identify "tickers whose 48-hour window looks like institutional
# accumulation, not noise":
#
#   1. News Acceleration  -- coverage ramping today vs yesterday
#   2. Sector Heat        -- sector ETF outperforming SPY today
#   3. Theme Match        -- headlines contain trending macro themes
#   4. Pre-Market Strength-- gap + early volume (best-effort on IEX free tier)
#   5. Technical Coiling  -- near 52w high + volume dry-up (stub for free tier)
#
# The framework then tiers candidates so the bot scans T1 first, T2 second,
# T3 (memory-proven fallback) last. On a tight daily trade budget, this means
# the highest-conviction setups get the limited slots.

. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_news.ps1")
. (Join-Path $PSScriptRoot "alpaca_indicators.ps1")

# ── Sector mapping ────────────────────────────────────────────────────────────
# Maps individual tickers to their primary S&P sector SPDR ETF. Curated for
# the names that appear in our static universe + the typical most-actives
# pool. Unknown tickers fall through to "SPY" (no sector bonus).

$CYCLE_SECTOR_MAP = @{
    # Mega-cap tech (XLK)
    "AAPL"="XLK"; "MSFT"="XLK"; "GOOGL"="XLC"; "GOOG"="XLC"; "META"="XLC"
    "NVDA"="XLK"; "AVGO"="XLK"; "AMD"="XLK"; "QCOM"="XLK"; "MU"="XLK"
    "AMAT"="XLK"; "MRVL"="XLK"; "SMCI"="XLK"; "ARM"="XLK"; "LRCX"="XLK"; "KLAC"="XLK"
    "PLTR"="XLK"; "SNOW"="XLK"; "CRWD"="XLK"; "PANW"="XLK"; "NET"="XLK"
    "DDOG"="XLK"; "ZS"="XLK"; "ORCL"="XLK"; "ADBE"="XLK"; "CRM"="XLK"
    # Consumer discretionary (XLY)
    "AMZN"="XLY"; "TSLA"="XLY"; "HD"="XLY"; "NKE"="XLY"; "SBUX"="XLY"; "CMG"="XLY"
    "MCD"="XLY"; "BKNG"="XLY"; "LOW"="XLY"
    # Consumer staples (XLP)
    "COST"="XLP"; "TGT"="XLP"; "WMT"="XLP"; "PG"="XLP"; "KO"="XLP"; "PEP"="XLP"
    # Financials (XLF)
    "JPM"="XLF"; "BAC"="XLF"; "GS"="XLF"; "MS"="XLF"; "C"="XLF"; "WFC"="XLF"
    "V"="XLF"; "MA"="XLF"; "BX"="XLF"; "AXP"="XLF"; "SCHW"="XLF"
    # Energy (XLE)
    "XOM"="XLE"; "CVX"="XLE"; "OXY"="XLE"; "SLB"="XLE"; "MPC"="XLE"; "COP"="XLE"
    # Healthcare (XLV)
    "UNH"="XLV"; "LLY"="XLV"; "PFE"="XLV"; "MRNA"="XLV"; "ABBV"="XLV"; "ISRG"="XLV"
    "JNJ"="XLV"; "MRK"="XLV"; "TMO"="XLV"; "ABT"="XLV"
    # Industrials (XLI)
    "BA"="XLI"; "CAT"="XLI"; "DE"="XLI"; "GE"="XLI"; "HON"="XLI"; "UPS"="XLI"
    # Communications (XLC)
    "NFLX"="XLC"; "DIS"="XLC"; "T"="XLC"; "VZ"="XLC"
}

$CYCLE_SECTOR_ETFS = @("XLK","XLF","XLE","XLV","XLY","XLP","XLI","XLU","XLB","XLRE","XLC")

# ── Hot themes lexicon ────────────────────────────────────────────────────────
# Macro themes that drive multi-day momentum. Quarterly review recommended --
# what's hot in May 2026 won't be hot in November 2026.

$CYCLE_HOT_THEMES = @(
    # AI / data center
    "artificial intelligence","\bAI\b","generative","large language",
    "machine learning","\bLLM\b","data center","hyperscaler",
    # Semiconductors
    "semiconductor","\bchip\b","foundry","TSMC","wafer",
    # GLP-1 / obesity
    "GLP-1","weight loss","obesity drug","Ozempic","Wegovy","Mounjaro",
    # Trade / tariffs
    "tariff","trade war","import duty","China trade","export ban",
    # EV / battery
    "electric vehicle","\bEV\b","battery","lithium","gigafactory",
    # Quantum / robotics
    "quantum computing","humanoid robot","automation",
    # Cyber
    "cybersecurity","ransomware","zero-day","breach",
    # Biotech catalysts
    "FDA approval","Phase 3","clinical trial","breakthrough therapy",
    # Crypto-adjacent equities
    "bitcoin","cryptocurrency","stablecoin"
)

# ── 1. News Acceleration ──────────────────────────────────────────────────────
# Compares mentions in the last 24h vs the 24h before that. A 1.5x+ ramp
# with at least 3 fresh mentions = institutional eyes are turning toward
# this name -- the move usually hasn't fully priced in yet.
# Takes a pre-fetched 48h news array to avoid N+1 API calls.

function Get-NewsAcceleration {
    param([string]$symbol, $news48h)
    if ($null -eq $news48h -or @($news48h).Count -eq 0) {
        return [pscustomobject]@{ Mentions24h = 0; Mentions48h = 0; IsAccelerating = $false; Lean = "neutral" }
    }
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-24)
    $m24 = 0; $m48 = 0
    $bullScore = 0; $bearScore = 0
    foreach ($n in $news48h) {
        if ($null -eq $n.symbols) { continue }
        $hit = $false
        foreach ($s in $n.symbols) { if ($s -eq $symbol) { $hit = $true; break } }
        if (-not $hit) { continue }
        $when = $null
        try { $when = [datetime]::Parse($n.created_at).ToUniversalTime() } catch { continue }
        if ($when -ge $cutoff) {
            $m24++
            $headline = if ($n.headline) { [string]$n.headline } else { "" }
            $bullScore += (Get-HeadlineSentiment $headline)
        } else {
            $m48++
        }
    }
    $accel = ($m24 -ge 3 -and $m48 -gt 0 -and $m24 -gt ($m48 * 1.5)) -or `
             ($m24 -ge 4 -and $m48 -eq 0)   # new cycle starting today
    $lean  = if ($bullScore -ge 2) { "bull" } elseif ($bullScore -le -2) { "bear" } else { "neutral" }
    return [pscustomobject]@{
        Mentions24h    = $m24
        Mentions48h    = $m48
        IsAccelerating = $accel
        Lean           = $lean
    }
}

# ── 2. Sector Heat ────────────────────────────────────────────────────────────
# Pulls a snapshot of all sector SPDR ETFs + SPY. For each sector, computes
# (sector day_change - SPY day_change). Positive means the sector is leading.
# Returns hashtable { ETF -> outperformance_pct }.
# Cached for one scan -- recomputed each cycle.

function Get-SectorMomentum($cfg) {
    $syms = $CYCLE_SECTOR_ETFS + @("SPY")
    $snap = Get-Snapshots $cfg ($syms | Select-Object -Unique)
    if ($null -eq $snap) { return @{} }

    $spyChange = $null
    if ($snap.SPY -and $snap.SPY.dailyBar -and $snap.SPY.prevDailyBar) {
        $sc = [double]$snap.SPY.dailyBar.c
        $sp = [double]$snap.SPY.prevDailyBar.c
        if ($sp -gt 0) { $spyChange = (($sc - $sp) / $sp) * 100 }
    }
    if ($null -eq $spyChange) { return @{} }

    $result = @{}
    foreach ($etf in $CYCLE_SECTOR_ETFS) {
        if (-not $snap.$etf) { continue }
        $d = $snap.$etf.dailyBar
        $p = $snap.$etf.prevDailyBar
        if ($null -eq $d -or $null -eq $p) { continue }
        $pc = [double]$p.c
        if ($pc -le 0) { continue }
        $chg = (([double]$d.c - $pc) / $pc) * 100
        $result[$etf] = [Math]::Round($chg - $spyChange, 3)
    }
    return $result
}

function Get-TickerSector([string]$symbol) {
    if ($CYCLE_SECTOR_MAP.ContainsKey($symbol)) { return $CYCLE_SECTOR_MAP[$symbol] }
    return $null
}

# ── 3. Theme Match ────────────────────────────────────────────────────────────
# Scans the ticker's recent headlines for hot-theme keywords. A theme match
# layered on top of a news cycle is a stronger signal than either alone --
# institutional rotation typically follows macro themes.

function Get-ThemeMatch {
    param([string]$symbol, $news48h)
    if ($null -eq $news48h -or @($news48h).Count -eq 0) {
        return [pscustomobject]@{ Matches = $false; Themes = @() }
    }
    $matched = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in $news48h) {
        if ($null -eq $n.symbols) { continue }
        $hit = $false
        foreach ($s in $n.symbols) { if ($s -eq $symbol) { $hit = $true; break } }
        if (-not $hit) { continue }
        $blob = ((($n.headline) + " " + ($n.summary))).ToLower()
        foreach ($theme in $CYCLE_HOT_THEMES) {
            if ($blob -match $theme.ToLower()) { [void]$matched.Add($theme) }
        }
    }
    return [pscustomobject]@{
        Matches = ($matched.Count -gt 0)
        Themes  = @($matched)
    }
}

# ── 4. Pre-Market Strength (best-effort on free IEX tier) ─────────────────────
# Fetches 1-min bars from today's 4 AM ET onwards. Computes:
#   pre-market gap = (last_premkt_close - prev_close) / prev_close
#   pre-market volume = sum of all pre-market bar volumes
# IEX-only pre-market is sparse. We return $null if too few bars to be useful;
# callers treat null as "no premarket signal" and don't penalize.

function Get-PremarketStrength {
    param($cfg, [string]$symbol, [double]$prevClose)
    if ($prevClose -le 0) { return $null }

    # Compute today's 4 AM ET as start
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $etNow  = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
    $offset = $tz.GetUtcOffset($etNow)
    $sign   = if ($offset.Hours -ge 0) { "+" } else { "-" }
    $offStr = "{0}{1:D2}:00" -f $sign, [Math]::Abs($offset.Hours)
    $start  = $etNow.ToString("yyyy-MM-dd") + "T04:00:00" + $offStr
    $end    = $etNow.ToString("yyyy-MM-dd") + "T09:30:00" + $offStr
    $path   = "/v2/stocks/{0}/bars?timeframe=5Min&start={1}&end={2}&limit=200&adjustment=raw&feed=iex" `
              -f $symbol, $start, $end

    $r = $null
    try { $r = Invoke-AlpacaData $cfg $path } catch {}
    if ($null -eq $r -or $null -eq $r.bars -or @($r.bars).Count -lt 2) { return $null }

    $bars = @($r.bars)
    $totalVol = 0; $lastClose = 0
    foreach ($b in $bars) { $totalVol += [double]$b.v; $lastClose = [double]$b.c }
    if ($lastClose -le 0) { return $null }

    $gapPct  = (($lastClose - $prevClose) / $prevClose) * 100
    $strength = 0.0
    # Categorical strength score so downstream scoring stays additive
    if ([Math]::Abs($gapPct) -ge 5.0 -and $totalVol -ge 100000) { $strength = 3.0 }
    elseif ([Math]::Abs($gapPct) -ge 3.0 -and $totalVol -ge 50000)  { $strength = 2.0 }
    elseif ([Math]::Abs($gapPct) -ge 1.5)                            { $strength = 1.0 }

    return [pscustomobject]@{
        GapPct  = [Math]::Round($gapPct, 2)
        Volume  = $totalVol
        Strength= $strength
    }
}

# ── 5. Technical Setup (stub -- free-tier daily bars are heavy per ticker) ───
# Real implementation would fetch ~252 daily bars and compute:
#   NearAth: current within 5% of 52w high
#   VolumeDryUp: recent 5d avg vol < 20d avg vol * 0.8
#   TightRange: recent 5d ATR < 20d ATR * 0.7
# For now we return a $null context; framework wired so it's ready when we
# decide to add the API spend.

function Get-TechnicalSetup {
    param($cfg, [string]$symbol)
    return $null  # deliberately deferred; see comments
}

# ── 6. Cycle Context bundle ───────────────────────────────────────────────────
# Single object capturing every cycle signal for one ticker. Passed to
# Score-Candidate and to tier assignment.

function Get-CycleContext {
    param(
        $cfg, [string]$symbol, [double]$prevClose,
        $news48h, $sectorMomentum, [double]$memoryScore
    )
    $accel  = Get-NewsAcceleration $symbol $news48h
    $theme  = Get-ThemeMatch       $symbol $news48h
    $sector = Get-TickerSector     $symbol
    $sectorHeat = if ($sector -and $sectorMomentum.ContainsKey($sector)) { $sectorMomentum[$sector] } else { 0.0 }
    $premkt = Get-PremarketStrength $cfg $symbol $prevClose
    $tech   = Get-TechnicalSetup    $cfg $symbol

    return [pscustomobject]@{
        Symbol         = $symbol
        Acceleration   = $accel
        Theme          = $theme
        Sector         = $sector
        SectorHeat     = $sectorHeat
        Premarket      = $premkt
        Technical      = $tech
        MemoryScore    = $memoryScore
    }
}

# ── 7. Watchlist Tier assignment ──────────────────────────────────────────────
# Tier 1: HIGH CONVICTION -- accelerating news AND (premarket gap >= 3% OR
#         sector heat >= 1.0 OR memory >= 1.5)
# Tier 2: STANDARD -- has at least one strong catalyst (news accel, premarket,
#         theme, or strong sector)
# Tier 3: FALLBACK -- memory-proven name with no fresh catalyst (use sparingly
#         on quiet days)

function Get-WatchlistTier {
    param($candidate, $cycleCtx)
    if ($null -eq $cycleCtx) { return 3 }

    $accel    = $cycleCtx.Acceleration -and $cycleCtx.Acceleration.IsAccelerating
    $premkt   = $cycleCtx.Premarket -and $cycleCtx.Premarket.Strength -ge 2.0
    $hotSec   = $cycleCtx.SectorHeat -ge 1.0
    $mem      = $cycleCtx.MemoryScore -ge 1.5
    $themeOk  = $cycleCtx.Theme -and $cycleCtx.Theme.Matches

    if ($accel -and ($premkt -or $hotSec -or $mem)) { return 1 }
    if ($accel -or $premkt -or $hotSec -or $themeOk) { return 2 }
    if ($mem) { return 3 }
    return 3
}
