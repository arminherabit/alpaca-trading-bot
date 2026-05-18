# Alpaca REST API Client
# Covers: account, positions, orders, market data (bars + quotes)
# Set $cfg before dot-sourcing, or call Load-AlpacaConfig first.

function Load-AlpacaConfig {
    $path = Join-Path $PSScriptRoot "alpaca_config.json"
    $c    = Get-Content $path | ConvertFrom-Json
    if ($c.api_key           -eq "FROM_ENV") { $c.api_key           = "$env:ALPACA_API_KEY".Trim()    }
    if ($c.api_secret        -eq "FROM_ENV") { $c.api_secret        = "$env:ALPACA_API_SECRET".Trim() }
    if ($c.anthropic_api_key -eq "FROM_ENV") { $c.anthropic_api_key = "$env:ANTHROPIC_API_KEY".Trim() }
    return $c
}

# ── Internal helpers ──────────────────────────────────────────────────────────

function Get-AlpacaBaseUrl($cfg) {
    if ($cfg.paper_trading) { return $cfg.base_url_paper } else { return $cfg.base_url_live }
}

function Invoke-AlpacaApi($cfg, [string]$method, [string]$path, [hashtable]$body = $null) {
    $base    = Get-AlpacaBaseUrl $cfg
    $uri     = $base + $path
    $headers = @{
        "APCA-API-KEY-ID"     = $cfg.api_key
        "APCA-API-SECRET-KEY" = $cfg.api_secret
        "Accept"              = "application/json"
    }
    try {
        if ($null -ne $body) {
            $json = $body | ConvertTo-Json -Depth 5
            return Invoke-RestMethod -Uri $uri -Method $method -Headers $headers `
                -Body $json -ContentType "application/json" -UseBasicParsing
        } else {
            return Invoke-RestMethod -Uri $uri -Method $method -Headers $headers -UseBasicParsing
        }
    } catch {
        $msg = $_.Exception.Message
        try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch {}
        Write-Host ("  [API ERROR] {0} {1} -> {2}" -f $method, $path, $msg) -ForegroundColor Red
        return $null
    }
}

function Invoke-AlpacaData($cfg, [string]$path) {
    $uri     = $cfg.data_url + $path
    $headers = @{
        "APCA-API-KEY-ID"     = $cfg.api_key
        "APCA-API-SECRET-KEY" = $cfg.api_secret
        "Accept"              = "application/json"
    }
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing
    } catch {
        $msg = $_.Exception.Message
        try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch {}
        Write-Host ("  [DATA ERROR] {0} -> {1}" -f $path, $msg) -ForegroundColor Red
        return $null
    }
}

# ── Account ───────────────────────────────────────────────────────────────────

function Get-Account($cfg) {
    return Invoke-AlpacaApi $cfg "GET" "/v2/account"
}

function Get-BuyingPower($cfg) {
    $a = Get-Account $cfg
    if ($null -ne $a) { return [double]$a.buying_power } else { return 0.0 }
}

function Get-Equity($cfg) {
    $a = Get-Account $cfg
    if ($null -ne $a) { return [double]$a.equity } else { return 0.0 }
}

# ── Positions ─────────────────────────────────────────────────────────────────

function Get-Positions($cfg) {
    $raw = Invoke-AlpacaApi $cfg "GET" "/v2/positions"
    if ($null -eq $raw) { return @() }
    return $raw
}

function Get-Position($cfg, [string]$symbol) {
    return Invoke-AlpacaApi $cfg "GET" ("/v2/positions/" + $symbol)
}

function Get-PositionCount($cfg) {
    return (Get-Positions $cfg).Count
}

# ── Orders ────────────────────────────────────────────────────────────────────

function Get-Orders($cfg, [string]$status = "open") {
    $raw = Invoke-AlpacaApi $cfg "GET" ("/v2/orders?status=" + $status + "&limit=50")
    if ($null -eq $raw) { return @() }
    return $raw
}

function Submit-MarketOrder($cfg, [string]$symbol, [string]$side, [int]$qty) {
    if ($cfg.paper_trading) {
        Write-Host ("  [PAPER] {0} {1} x {2} MARKET" -f $side.ToUpper(), $qty, $symbol) -ForegroundColor Cyan
    }
    $body = @{
        symbol        = $symbol
        qty           = $qty.ToString()
        side          = $side.ToLower()
        type          = "market"
        time_in_force = "day"
    }
    return Invoke-AlpacaApi $cfg "POST" "/v2/orders" $body
}

function Submit-LimitOrder($cfg, [string]$symbol, [string]$side, [int]$qty, [double]$limitPrice) {
    if ($cfg.paper_trading) {
        Write-Host ("  [PAPER] {0} {1} x {2} LIMIT @ `${3}" -f $side.ToUpper(), $qty, $symbol, $limitPrice) -ForegroundColor Cyan
    }
    $body = @{
        symbol        = $symbol
        qty           = $qty.ToString()
        side          = $side.ToLower()
        type          = "limit"
        time_in_force = "day"
        limit_price   = $limitPrice.ToString("F2")
    }
    return Invoke-AlpacaApi $cfg "POST" "/v2/orders" $body
}

function Submit-BracketOrder($cfg, [string]$symbol, [string]$side, [int]$qty,
                             [double]$limitPrice, [double]$takeProfit, [double]$stopLoss) {
    if ($cfg.paper_trading) {
        Write-Host ("  [PAPER] BRACKET {0} {1} x {2} entry=`${3} tp=`${4} sl=`${5}" -f `
            $side.ToUpper(), $qty, $symbol, $limitPrice, $takeProfit, $stopLoss) -ForegroundColor Cyan
    }
    $body = @{
        symbol              = $symbol
        qty                 = $qty.ToString()
        side                = $side.ToLower()
        type                = "limit"
        time_in_force       = "day"
        limit_price         = $limitPrice.ToString("F2")
        order_class         = "bracket"
        take_profit         = @{ limit_price = $takeProfit.ToString("F2") }
        stop_loss           = @{ stop_price  = $stopLoss.ToString("F2") }
    }
    return Invoke-AlpacaApi $cfg "POST" "/v2/orders" $body
}

function Cancel-Order($cfg, [string]$orderId) {
    return Invoke-AlpacaApi $cfg "DELETE" ("/v2/orders/" + $orderId)
}

function Cancel-AllOrders($cfg) {
    return Invoke-AlpacaApi $cfg "DELETE" "/v2/orders"
}

function Close-Position($cfg, [string]$symbol) {
    return Invoke-AlpacaApi $cfg "DELETE" ("/v2/positions/" + $symbol)
}

# ── Market Data ───────────────────────────────────────────────────────────────

function Get-Bars($cfg, [string]$symbol, [string]$timeframe, [int]$limit = 100) {
    # timeframe: "1Min", "5Min", "15Min", "1Hour", "1Day"
    $path = "/v2/stocks/{0}/bars?timeframe={1}&limit={2}&adjustment=raw&feed=iex" -f $symbol, $timeframe, $limit
    $r    = Invoke-AlpacaData $cfg $path
    if ($null -eq $r -or $null -eq $r.bars) { return @() }
    return $r.bars | ForEach-Object {
        [pscustomobject]@{
            Time   = [datetime]$_.t
            Open   = [double]$_.o
            High   = [double]$_.h
            Low    = [double]$_.l
            Close  = [double]$_.c
            Volume = [double]$_.v
            VWAP   = if ($null -ne $_.vw) { [double]$_.vw } else { [double]$_.c }
        }
    }
}

function Get-IntradayBars($cfg, [string]$symbol, [string]$timeframe = "1Min") {
    # Fetch today's bars from market open — dynamically resolve ET offset (EDT=-04, EST=-05)
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    $etNow  = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
    $offset = $tz.GetUtcOffset($etNow)
    $sign   = if ($offset.Hours -ge 0) { "+" } else { "-" }
    $offStr = "{0}{1:D2}:00" -f $sign, [Math]::Abs($offset.Hours)
    $today  = $etNow.ToString("yyyy-MM-dd")
    $start  = $today + "T09:30:00" + $offStr
    $path   = "/v2/stocks/{0}/bars?timeframe={1}&start={2}&limit=400&adjustment=raw&feed=iex" -f $symbol, $timeframe, $start
    $r     = Invoke-AlpacaData $cfg $path
    if ($null -eq $r -or $null -eq $r.bars) { return @() }
    return $r.bars | ForEach-Object {
        [pscustomobject]@{
            Time   = [datetime]$_.t
            Open   = [double]$_.o
            High   = [double]$_.h
            Low    = [double]$_.l
            Close  = [double]$_.c
            Volume = [double]$_.v
            VWAP   = if ($null -ne $_.vw) { [double]$_.vw } else { [double]$_.c }
        }
    }
}

function Get-Quote($cfg, [string]$symbol) {
    $path = "/v2/stocks/{0}/quotes/latest?feed=iex" -f $symbol
    $r    = Invoke-AlpacaData $cfg $path
    if ($null -eq $r -or $null -eq $r.quote) { return $null }
    return [pscustomobject]@{
        Symbol  = $symbol
        BidPrice = [double]$r.quote.bp
        AskPrice = [double]$r.quote.ap
        MidPrice = ([double]$r.quote.bp + [double]$r.quote.ap) / 2.0
    }
}

function Get-LatestTrade($cfg, [string]$symbol) {
    $path = "/v2/stocks/{0}/trades/latest?feed=iex" -f $symbol
    $r    = Invoke-AlpacaData $cfg $path
    if ($null -eq $r -or $null -eq $r.trade) { return $null }
    return [double]$r.trade.p
}

function Get-Snapshot($cfg, [string[]]$symbols) {
    $sym  = $symbols -join ","
    $path = "/v2/stocks/snapshots?symbols={0}&feed=iex" -f $sym
    return Invoke-AlpacaData $cfg $path
}

# ── Market Clock ──────────────────────────────────────────────────────────────

function Get-MarketClock($cfg) {
    return Invoke-AlpacaApi $cfg "GET" "/v2/clock"
}

function Test-MarketOpen($cfg) {
    $clock = Get-MarketClock $cfg
    return ($null -ne $clock -and $clock.is_open -eq $true)
}

function Get-EasternTime {
    # Cross-platform: Windows uses "Eastern Standard Time", Linux uses "America/New_York"
    try   { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
    return [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
}

function Test-TradingWindow($cfg) {
    $etNow          = Get-EasternTime
    $noTradeBeforeT = [datetime]::ParseExact($cfg.no_trade_before, "HH:mm", $null)
    $noTradeAfterT  = [datetime]::ParseExact($cfg.no_trade_after,  "HH:mm", $null)
    $noBeforeToday  = $etNow.Date.Add($noTradeBeforeT.TimeOfDay)
    $noAfterToday   = $etNow.Date.Add($noTradeAfterT.TimeOfDay)
    return ($etNow -ge $noBeforeToday -and $etNow -le $noAfterToday)
}
