# alpaca_news.ps1
# Pulls the rolling 24-hour news feed from Alpaca's /v1beta1/news endpoint,
# extracts ticker mentions, and assigns a light keyword-based sentiment score.
#
# Why this matters: stocks in active news cycles consistently move more than
# random names. Adding a "news catalyst" score to the screener is the single
# biggest free upgrade you can give a momentum bot, because the catalyst is
# the reason for the move that makes the technicals work in the first place.
#
# Exports:
#   Get-RecentNews        $cfg [hoursBack]                 -> news[] (raw)
#   Get-NewsCatalysts     $cfg [hoursBack] [minMentions]    -> hashtable
#       { SYMBOL -> { Mentions, Sentiment, Lean, Headlines } }
#
# Sentiment is a simple bull/bear keyword count -- not ML, but works because
# financial headlines use a small vocabulary. "beats / raises / upgrade" =
# bull; "misses / cuts / downgrade / lawsuit" = bear. Anything else = neutral.

. (Join-Path $PSScriptRoot "alpaca_client.ps1")

# ── Keyword lexicons -- compact on purpose; expand if false positives mount ──

$BULL_KEYWORDS = @(
    'beats','beat','raises','raised','raise','upgrade','upgraded','outperform',
    'surge','surged','jump','jumps','soar','soared','rally','rallies','rallied',
    'breakthrough','partnership','partners','acquire','acquires','acquisition',
    'buyback','dividend','approve','approved','approval','wins','win','contract',
    'record','strong','exceed','exceeded','tops','topped','bullish','positive',
    'launch','launches','launched','expand','expands','expanded','growth'
)
$BEAR_KEYWORDS = @(
    'miss','misses','missed','cut','cuts','downgrade','downgraded','underperform',
    'plunge','plunges','plunged','drop','drops','dropped','tumble','tumbles',
    'recall','recalled','lawsuit','sued','fraud','probe','investigation',
    'subpoena','sec','restatement','warning','warns','weak','sluggish','decline',
    'declines','declined','bearish','negative','layoffs','layoff','restructur',
    'bankruptcy','default','downgrade','sell','reduce','reduced'
)

# ── Raw fetch ─────────────────────────────────────────────────────────────────

function Get-RecentNews {
    param($cfg, [int]$hoursBack = 24, [int]$limit = 100)

    $startUtc = (Get-Date).ToUniversalTime().AddHours(-$hoursBack).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri = "https://data.alpaca.markets/v1beta1/news?start=$startUtc&limit=$limit&sort=desc"
    $headers = @{
        "APCA-API-KEY-ID"     = $cfg.api_key
        "APCA-API-SECRET-KEY" = $cfg.api_secret
        "Accept"              = "application/json"
    }
    try {
        $r = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing
        if ($null -eq $r -or $null -eq $r.news) { return @() }
        return @($r.news)
    } catch {
        Write-Host ("  [NEWS] fetch failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return @()
    }
}

# ── Sentiment helper ──────────────────────────────────────────────────────────

function Get-HeadlineSentiment {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return 0 }
    $tl = $text.ToLower()
    $bull = 0; $bear = 0
    foreach ($w in $BULL_KEYWORDS) { if ($tl -match "\b$w\b") { $bull++ } }
    foreach ($w in $BEAR_KEYWORDS) { if ($tl -match "\b$w\b") { $bear++ } }
    return ($bull - $bear)   # >0 bull, <0 bear, =0 neutral
}

# ── Catalyst tally ────────────────────────────────────────────────────────────

function Get-NewsCatalysts {
    param($cfg, [int]$hoursBack = 24, [int]$minMentions = 2)

    $news = Get-RecentNews $cfg $hoursBack 100
    if ($news.Count -eq 0) { return @{} }

    $tally = @{}
    foreach ($n in $news) {
        if ($null -eq $n.symbols -or $n.symbols.Count -eq 0) { continue }
        $headline = if ($n.headline) { [string]$n.headline } else { "" }
        $summary  = if ($n.summary)  { [string]$n.summary }  else { "" }
        $score    = (Get-HeadlineSentiment $headline) + (Get-HeadlineSentiment $summary)

        foreach ($sym in $n.symbols) {
            $s = [string]$sym
            # Filter out cryptos and ETF noise tickers if they slip in
            if ($s -match '/' -or $s.Length -gt 5) { continue }
            if (-not $tally.ContainsKey($s)) {
                $tally[$s] = [pscustomobject]@{
                    Mentions   = 0
                    Sentiment  = 0
                    Lean       = "neutral"
                    Headlines  = @()
                }
            }
            $tally[$s].Mentions++
            $tally[$s].Sentiment += $score
            if ($tally[$s].Headlines.Count -lt 3 -and $headline -ne "") {
                $tally[$s].Headlines += $headline
            }
        }
    }

    # Resolve lean per ticker
    $result = @{}
    foreach ($k in $tally.Keys) {
        $t = $tally[$k]
        if ($t.Mentions -lt $minMentions) { continue }
        if    ($t.Sentiment -ge 2) { $t.Lean = "bull"    }
        elseif($t.Sentiment -le -2){ $t.Lean = "bear"    }
        else                       { $t.Lean = "neutral" }
        $result[$k] = $t
    }

    Write-Host ("  [NEWS] {0} catalysts found ({1} headlines scanned, {2}h lookback)" -f `
        $result.Count, $news.Count, $hoursBack) -ForegroundColor DarkGray
    return $result
}
