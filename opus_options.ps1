# opus_options.ps1
# Opus options sleeves (spec v1.2) -- orchestrator: Invoke-OpusOptionsScan.
#
# Runs as its own workflow step after the swing scan (pwsh ./opus_options.ps1),
# not from inside alpaca_bot.ps1. The spec names alpaca_bot.ps1 as the caller;
# a separate process is used instead so that nothing the options module does --
# a parse error, an exception, a hung request -- can ever reach the swing scan,
# and so the swing file stays unchanged (owner decision). Recorded per spec
# "SHOULD ... record the reason".
#
# DRY_RUN (default true): everything is computed, simulated orders are tracked
# and filled per spec 8 step 15, nothing is ever POSTed or DELETEd. All order
# traffic goes through Submit-OpusOrder / Remove-OpusOrder, which refuse to act
# in DRY_RUN as a second line of defence.
#
# Not yet implemented (live-only paths, required before DRY_RUN=false; see
# docs/alpaca_verification.md): automatic E0 flattening of assigned stock and
# the single-leg SHORT_LEG_ONLY_CLOSE. In live mode E0 is detected and sets
# manual_review_required, which blocks entries until the owner clears it.

param([switch]$NoRun)

$script:OPUS_ROOT = $PSScriptRoot
. (Join-Path $PSScriptRoot "alpaca_client.ps1")
. (Join-Path $PSScriptRoot "alpaca_regime.ps1")
. (Join-Path $PSScriptRoot "opus_options_core.ps1")
. (Join-Path $PSScriptRoot "opus_options_data.ps1")

# Explicit setters: Pester 5 runs dot-sourced scripts inside its own scopes, so
# tests set module context through these rather than relying on $script: lookup.
function Set-OpusConfig($cfg) { $script:OpusCfg = $cfg }
function Set-OpusAlpacaConfig($cfg) { $script:AlpacaCfg = $cfg }

function Write-Opus([string]$msg, [string]$color = 'Gray') { Write-Host ("  [OPUS] " + $msg) -ForegroundColor $color }

# ── Time ──────────────────────────────────────────────────────────────────────

function Get-OpusTimeZone {
    foreach ($id in 'America/New_York', 'Eastern Standard Time') {
        try { return [System.TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { }
    }
    throw 'Eastern time zone not found'
}

function Get-OpusUtcNow { return [datetime]::UtcNow }

function ConvertTo-OpusUtc($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }
        return $v.ToUniversalTime()
    }
    return ([DateTimeOffset]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function ConvertTo-OpusEt([datetime]$utc) { return [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, (Get-OpusTimeZone)) }

function Get-OpusEtTime([string]$date, [string]$hhmm) {
    return [datetime]::ParseExact("$date $hhmm", 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
}

# ── API adapters (mocked in tests) ────────────────────────────────────────────

function Get-OpusClock { return Invoke-AlpacaApi $script:AlpacaCfg 'GET' '/v2/clock' }
function Get-OpusCalendar([string]$start, [string]$end) { return Invoke-AlpacaApi $script:AlpacaCfg 'GET' "/v2/calendar?start=$start&end=$end" }
function Get-OpusAccount { return Invoke-AlpacaApi $script:AlpacaCfg 'GET' '/v2/account' }
function Get-OpusPositions { return Invoke-AlpacaApi $script:AlpacaCfg 'GET' '/v2/positions' }
function Get-OpusOrderById([string]$id) { return Invoke-AlpacaApi $script:AlpacaCfg 'GET' "/v2/orders/$id" }
function Get-OpusOrderByClientId([string]$cid) { return Invoke-AlpacaApi $script:AlpacaCfg 'GET' "/v2/orders:by_client_order_id?client_order_id=$cid" }

function Submit-OpusOrder($payload) {
    if ($script:OpusCfg.DRY_RUN) { throw 'DRY_RUN violation: Submit-OpusOrder called' }
    return Invoke-AlpacaApi $script:AlpacaCfg 'POST' '/v2/orders' ([hashtable]$payload)
}

function Remove-OpusOrder([string]$id) {
    if ($script:OpusCfg.DRY_RUN) { throw 'DRY_RUN violation: Remove-OpusOrder called' }
    return Invoke-AlpacaApi $script:AlpacaCfg 'DELETE' "/v2/orders/$id"
}

function ConvertTo-OpusBar($b) {
    $t = ConvertTo-OpusUtc $b.t
    return [pscustomobject]@{ Date = $t.ToString('yyyy-MM-dd'); Open = [double]$b.o; High = [double]$b.h; Low = [double]$b.l; Close = [double]$b.c; Volume = [double]$b.v }
}

# Multi-symbol daily bars, split+dividend adjusted, IEX. Returns symbol -> bars.
function Get-OpusBars([string[]]$symbols, [string]$start) {
    $out = @{}
    foreach ($s in $symbols) { $out[$s] = @() }
    for ($i = 0; $i -lt $symbols.Count; $i += 50) {
        $chunk = ($symbols[$i..([Math]::Min($i + 49, $symbols.Count - 1))]) -join ','
        $tok = $null
        do {
            $path = "/v2/stocks/bars?symbols=$chunk&timeframe=1Day&start=$start&feed=$($script:OpusCfg.STOCK_DATA_FEED)&adjustment=$($script:OpusCfg.BAR_ADJUSTMENT)&limit=10000"
            if ($tok) { $path += "&page_token=$tok" }
            $r = Invoke-AlpacaData $script:AlpacaCfg $path
            if ($null -eq $r) { break }
            if ($null -ne $r.bars) {
                foreach ($p in $r.bars.PSObject.Properties) { $out[$p.Name] = @($out[$p.Name]) + @($p.Value | ForEach-Object { ConvertTo-OpusBar $_ }) }
            }
            $tok = $r.next_page_token
        } while ($tok)
    }
    foreach ($s in @($out.Keys)) { $out[$s] = @($out[$s] | Sort-Object Date) }
    return $out
}

function Get-OpusLatestPrices([string[]]$symbols) {
    $out = @{}
    if ($symbols.Count -eq 0) { return $out }
    $r = Invoke-AlpacaData $script:AlpacaCfg ("/v2/stocks/trades/latest?symbols={0}&feed={1}" -f ($symbols -join ','), $script:OpusCfg.STOCK_DATA_FEED)
    if ($null -ne $r -and $null -ne $r.trades) { foreach ($p in $r.trades.PSObject.Properties) { $out[$p.Name] = [double]$p.Value.p } }
    return $out
}

function Get-OpusContracts([string]$symbol, [string]$type, [string]$gte, [string]$lte) {
    $all = @(); $tok = $null
    do {
        $path = "/v2/options/contracts?underlying_symbols=$symbol&type=$type&status=active&expiration_date_gte=$gte&expiration_date_lte=$lte&limit=1000"
        if ($tok) { $path += "&page_token=$tok" }
        $r = Invoke-AlpacaApi $script:AlpacaCfg 'GET' $path
        if ($null -eq $r) { break }
        $all += @($r.option_contracts)
        $tok = $r.next_page_token
    } while ($tok)
    return @($all | Where-Object { $null -ne $_ -and $_.tradable -and $_.style -eq 'american' })
}

function ConvertTo-OpusLeg($contract, $snap, [string]$type) {
    $q = if ($null -ne $snap) { $snap.latestQuote } else { $null }
    $g = if ($null -ne $snap) { $snap.greeks } else { $null }
    return @{
        Occ = [string]$contract.symbol; Type = $type; Strike = [double]$contract.strike_price
        Expiration = (ConvertTo-OpusDate $contract.expiration_date); Oi = [double]($(if ($null -ne $contract.open_interest) { $contract.open_interest } else { 0 }))
        Bid = $(if ($null -ne $q) { [double]$q.bp } else { $null }); Ask = $(if ($null -ne $q) { [double]$q.ap } else { $null })
        Delta = $(if ($null -ne $g -and $null -ne $g.delta) { [double]$g.delta } else { $null })
        Iv = $(if ($null -ne $snap -and $null -ne $snap.impliedVolatility) { [double]$snap.impliedVolatility } else { $null })
    }
}

# Snapshots for one underlying/type/expiration (paginated).
function Get-OpusChainSnapshots([string]$symbol, [string]$type, [string]$expiration, $strikeLo = $null, $strikeHi = $null) {
    $out = @{}; $tok = $null
    do {
        $path = "/v1beta1/options/snapshots/${symbol}?feed=$($script:OpusCfg.OPTIONS_DATA_FEED)&type=$type&expiration_date=$expiration&limit=1000"
        if ($null -ne $strikeLo) { $path += "&strike_price_gte=$strikeLo" }
        if ($null -ne $strikeHi) { $path += "&strike_price_lte=$strikeHi" }
        if ($tok) { $path += "&page_token=$tok" }
        $r = Invoke-AlpacaData $script:AlpacaCfg $path
        if ($null -eq $r) { break }
        if ($null -ne $r.snapshots) { foreach ($p in $r.snapshots.PSObject.Properties) { $out[$p.Name] = $p.Value } }
        $tok = $r.next_page_token
    } while ($tok)
    return $out
}

# Snapshots for a list of OCC symbols -> occ -> leg-like quote.
function Get-OpusLegQuotes([string[]]$occs) {
    $out = @{}
    $occs = @($occs | Where-Object { $_ } | Sort-Object -Unique)
    for ($i = 0; $i -lt $occs.Count; $i += 50) {
        $chunk = ($occs[$i..([Math]::Min($i + 49, $occs.Count - 1))]) -join ','
        $r = Invoke-AlpacaData $script:AlpacaCfg "/v1beta1/options/snapshots?symbols=$chunk&feed=$($script:OpusCfg.OPTIONS_DATA_FEED)"
        if ($null -eq $r -or $null -eq $r.snapshots) { continue }
        foreach ($p in $r.snapshots.PSObject.Properties) {
            $q = $p.Value.latestQuote; $g = $p.Value.greeks
            $out[$p.Name] = @{ Occ = $p.Name; Bid = $(if ($q) { [double]$q.bp } else { $null }); Ask = $(if ($q) { [double]$q.ap } else { $null })
                               Delta = $(if ($g -and $null -ne $g.delta) { [double]$g.delta } else { $null }); Iv = $p.Value.impliedVolatility; Oi = 0 }
        }
    }
    return $out
}

function Get-OpusDividends([string]$symbol, [string]$start, [string]$end) {
    return Invoke-AlpacaData $script:AlpacaCfg "/v1/corporate-actions?symbols=$symbol&types=cash_dividend&start=$start&end=$end"
}

# ── Scan context helpers ──────────────────────────────────────────────────────

function Get-OpusMode { return [bool]$script:OpusCfg.DRY_RUN }

function Get-OpusModePositions($state) { $dry = Get-OpusMode; return @(@($state.positions) | Where-Object { $null -ne $_ -and [bool]$_.dry_run -eq $dry }) }
function Get-OpusModeOrders($state) { $dry = Get-OpusMode; return @(@($state.working_orders) | Where-Object { $null -ne $_ -and [bool]$_.dry_run -eq $dry }) }
function Get-OpusModeClosed { $dry = Get-OpusMode; return @(Get-OpusClosedTrades | Where-Object { [bool]$_.dry_run -eq $dry }) }

function Get-OpusOpenRisk($pos) {
    if ($pos.sleeve -like 'A*') { return [double]$pos.entry_fill_price * 100 * [int]$pos.qty_open }
    return ([double]$pos.width - [double]$pos.entry_fill_price) * 100 * [int]$pos.qty_open
}
function Get-OpusExposure($pos) {
    if ($pos.sleeve -like 'A*') { return [double]$pos.entry_fill_price * 100 * [int]$pos.qty_open }
    return [double]$pos.width * 100 * [int]$pos.qty_open
}
# Working entries count with intended values (5.1).
function Get-OpusOrderRisk($o) {
    $draft = $o.entry_ctx
    if ($o.sleeve_code -eq 'A') { return [double]$o.limit * 100 * [int]$o.qty }
    return ([double]$draft.width - [double]$o.limit) * 100 * [int]$o.qty
}
function Get-OpusOrderExposure($o) {
    if ($o.sleeve_code -eq 'A') { return [double]$o.limit * 100 * [int]$o.qty }
    return [double]$o.entry_ctx.width * 100 * [int]$o.qty
}

function Get-OpusUnrealized($pos) {
    $v = $pos.last_value
    if ($null -eq $v) { return 0.0 }
    if ($pos.sleeve -like 'A*') { return ([double]$v - [double]$pos.entry_fill_price) * 100 * [int]$pos.qty_open }
    return ([double]$pos.entry_fill_price - [double]$v) * 100 * [int]$pos.qty_open
}

function Get-OpusEquity($state) {
    $realized = 0.0
    foreach ($t in (Get-OpusModeClosed)) { $realized += [double]$t.net_pnl }
    $unreal = 0.0
    foreach ($p in (Get-OpusModePositions $state)) { $realized += [double]$p.realized_partial; $unreal += Get-OpusUnrealized $p }
    return [double]$script:OpusCfg.STARTING_CAPITAL + $realized + $unreal
}

function Add-OpusAction([string]$a) { $script:OpusActions += $a }

# ── Order lifecycle ───────────────────────────────────────────────────────────

function New-OpusWorkingOrder([string]$sleeveCode, [string]$action, [string]$underlying, [string]$tradeId, [hashtable]$legs,
                              [int]$qty, [double]$mid, [double]$natural, [int]$attempt, [bool]$forced, [string]$exitReason, $entryCtx, [string]$today, [string]$prefix) {
    $kind = Get-OpusOrderKind $sleeveCode $(if ($action -eq 'E') { 'open' } else { 'close' })
    $price = if ($forced -and $attempt -ge [int]$script:OpusCfg.EXIT_FORCED_GO_NATURAL_AFTER) {
        Get-OpusRoundToTick $natural ([double]$script:OpusCfg.PRICE_TICK)
    } else { Get-OpusRepricePrice $mid $natural $kind $attempt $script:OpusCfg }
    $cid = New-OpusClientOrderId $prefix $underlying ($today -replace '-', '') $action $attempt
    return [ordered]@{
        trade_id = $tradeId; client_order_id = $cid; alpaca_order_id = $null; action = $action; sleeve_code = $sleeveCode
        underlying = $underlying; kind = $kind; qty = $qty; attempt = $attempt; limit = $price; mid0 = $mid; natural0 = $natural
        session_date = $today; submitted_at = (Get-OpusUtcNow).ToString('o'); forced = $forced; exit_reason = $exitReason
        legs = $legs; entry_ctx = $entryCtx; dry_run = (Get-OpusMode); prefix = $prefix; status = 'working'
    }
}

# Sends (live) or records (dry) a working order. Returns $true when it is working.
function Send-OpusOrder($o) {
    $payload = New-OpusMlegPayload $o.sleeve_code $(if ($o.action -eq 'E') { 'open' } else { 'close' }) $o.legs ([int]$o.qty) ([double]$o.limit) $o.client_order_id $script:OpusCfg
    $evt = [ordered]@{ ts = (Get-OpusUtcNow).ToString('o'); trade_id = $o.trade_id; client_order_id = $o.client_order_id; alpaca_order_id = $null
                       action = $o.action; attempt = $o.attempt; limit_price = $payload.limit_price; mid = $o.mid0; natural = $o.natural0
                       status = $null; filled_qty = 0; filled_avg_price = $null; reject_reason = $null; dry_run = $o.dry_run }
    if ($o.dry_run) {
        $evt.status = 'simulated_new'
        Add-OpusOrderEvent $evt
        return $true
    }
    $r = Submit-OpusOrder $payload
    if ($null -eq $r) { $evt.status = 'rejected'; $evt.reject_reason = 'submit failed'; Add-OpusOrderEvent $evt; return $false }
    $o.alpaca_order_id = $r.id
    $evt.alpaca_order_id = $r.id; $evt.status = $r.status
    Add-OpusOrderEvent $evt
    return $true
}

function Remove-OpusWorkingOrder($state, $o, [string]$status) {
    if (-not $o.dry_run -and $o.alpaca_order_id) {
        Remove-OpusOrder $o.alpaca_order_id | Out-Null
        $g = Get-OpusOrderById $o.alpaca_order_id
        if ($null -ne $g -and $g.status -notin 'canceled', 'expired', 'filled', 'rejected') { return $false }   # confirm next scan
    }
    Add-OpusOrderEvent ([ordered]@{ ts = (Get-OpusUtcNow).ToString('o'); trade_id = $o.trade_id; client_order_id = $o.client_order_id
                                    alpaca_order_id = $o.alpaca_order_id; action = $o.action; attempt = $o.attempt; limit_price = $null
                                    status = $status; filled_qty = 0; dry_run = $o.dry_run })
    $state.working_orders = @(@($state.working_orders) | Where-Object { $_.client_order_id -ne $o.client_order_id })
    return $true
}

# Applies a fill to state: entry -> new position; exit -> reduce/close.
function Complete-OpusFill($state, $o, [double]$fillMag, [int]$filledQty, [string]$today, $ctx) {
    $state.working_orders = @(@($state.working_orders) | Where-Object { $_.client_order_id -ne $o.client_order_id })
    Add-OpusOrderEvent ([ordered]@{ ts = (Get-OpusUtcNow).ToString('o'); trade_id = $o.trade_id; client_order_id = $o.client_order_id
                                    alpaca_order_id = $o.alpaca_order_id; action = $o.action; attempt = $o.attempt
                                    limit_price = (Format-OpusLimitPrice ([double]$o.limit) $o.kind $script:OpusCfg)
                                    status = $(if ($o.dry_run) { 'simulated_filled' } else { 'filled' }); filled_qty = $filledQty; filled_avg_price = $fillMag; dry_run = $o.dry_run })
    if ($o.action -eq 'E') {
        $p = $o.entry_ctx
        $p.qty_initial = $filledQty; $p.qty_open = $filledQty
        $p.entry_time = (Get-OpusUtcNow).ToString('o'); $p.entry_fill_date = $today
        $p.entry_fill_price = $fillMag; $p.entry_attempts = [int]$o.attempt + 1
        $mid0 = [double]$p.entry_mid
        $p.entry_slippage = if ($o.sleeve_code -eq 'A') { $fillMag - $mid0 } else { $mid0 - $fillMag }
        $p.entry_slippage_pct = if ($mid0 -ne 0) { $p.entry_slippage / $mid0 } else { $null }
        $p.max_risk_usd = Get-OpusOpenRisk $p
        $p.last_value = $fillMag
        $state.positions = @(@($state.positions) + , $p)
        Write-Opus ("ENTRY FILLED {0} {1} x{2} @ {3:F2} ({4})" -f $p.prefix, $p.underlying, $filledQty, $fillMag, $(if ($o.dry_run) { 'simulated' } else { 'live' })) 'Green'
        Add-OpusAction "fill-entry:$($p.underlying)"
        return
    }
    $pos = @(@($state.positions) | Where-Object { $_.trade_id -eq $o.trade_id })[0]
    if ($null -eq $pos) { return }
    $entry = [double]$pos.entry_fill_price
    $pnl = if ($pos.sleeve -like 'A*') { ($fillMag - $entry) * 100 * $filledQty } else { ($entry - $fillMag) * 100 * $filledQty }
    $slip = if ($o.kind -eq 'credit') { [double]$o.mid0 - $fillMag } else { $fillMag - [double]$o.mid0 }
    $pos.qty_open = [int]$pos.qty_open - $filledQty
    if ($pos.qty_open -gt 0) {
        $pos.realized_partial = [double]$pos.realized_partial + $pnl
        $pos.partial_exits = @(@($pos.partial_exits) + , ([ordered]@{ time = (Get-OpusUtcNow).ToString('o'); qty = $filledQty; fill_price = $fillMag; mid = $o.mid0; slippage = $slip; reason = $o.exit_reason }))
        if ($o.exit_reason -eq 'TP_PARTIAL') { $pos.partial_taken = $true; $pos.partial_fill_date = $today }
        Write-Opus ("PARTIAL EXIT {0} {1} x{2} @ {3:F2} reason {4}" -f $pos.prefix, $pos.underlying, $filledQty, $fillMag, $o.exit_reason) 'Cyan'
        Add-OpusAction "fill-partial:$($pos.underlying)"
        return
    }
    $net = [double]$pos.realized_partial + $pnl
    $pos.exit_time = (Get-OpusUtcNow).ToString('o'); $pos.exit_reason = $o.exit_reason
    $pos.exit_mid = $o.mid0; $pos.exit_fill_price = $fillMag; $pos.exit_slippage = $slip; $pos.exit_attempts = [int]$o.attempt + 1
    $pos.gross_pnl = $net; $pos.net_pnl = $net - [double]$pos.fees
    $pos.r_multiple = if ([double]$pos.max_risk_usd -gt 0) { $pos.net_pnl / [double]$pos.max_risk_usd } else { $null }
    $pos.days_held_calendar = Get-OpusDayDiff $pos.entry_fill_date $today
    $pos.days_held_trading = Get-OpusTradingDaysBetween $pos.entry_fill_date $today $ctx.Sessions
    $pos.close_date = $today
    if ($pos.entry_fill_date -eq $today) { $pos.notes = @(@($pos.notes) + 'SAME_DAY_EXIT') }
    Add-OpusClosedTrade $pos
    $state.positions = @(@($state.positions) | Where-Object { $_.trade_id -ne $pos.trade_id })
    # Loss bookkeeping (P3/P4/P9).
    if ([double]$pos.net_pnl -lt 0) {
        $state.consec_losses = [int]$state.consec_losses + 1
        $state.cooldown[$pos.underlying] = Add-OpusTradingDays $today ([int]$script:OpusCfg.SYMBOL_COOLDOWN_AFTER_LOSS_DAYS) $ctx.Sessions
        if ([int]$state.consec_losses -ge [int]$script:OpusCfg.CONSEC_LOSS_LIMIT) {
            $state.pause_until = Add-OpusTradingDays $today ([int]$script:OpusCfg.CONSEC_LOSS_PAUSE_DAYS) $ctx.Sessions
        }
    } else { $state.consec_losses = 0 }
    Write-Opus ("CLOSED {0} {1} reason {2} net {3:F2} ({4})" -f $pos.prefix, $pos.underlying, $o.exit_reason, $pos.net_pnl, $(if ($o.dry_run) { 'simulated' } else { 'live' })) 'Yellow'
    Add-OpusAction "close:$($pos.underlying):$($o.exit_reason)"
}

# Fresh spread mid/natural for a working order from this scan's quotes.
function Get-OpusOrderQuote($o, [hashtable]$quotes) {
    $L = $quotes[$o.legs.Long]; $S = $quotes[$o.legs.Short]
    $q = Get-OpusSpreadQuote $o.sleeve_code $L $S $script:OpusCfg
    if ($null -eq $q) { return $null }
    $nat = if ($o.action -eq 'E') { $q.OpenNatural } else { $q.CloseNatural }
    return @{ Mid = [double]$q.Mid; Natural = [double]$nat }
}

# Step 5 (fills) for every working order of this mode.
function Update-OpusOrderFills($state, [hashtable]$quotes, [string]$today, $ctx) {
    foreach ($o in @(Get-OpusModeOrders $state)) {
        if ($o.dry_run) {
            if ((ConvertTo-OpusDate $o.session_date) -ne $today) { continue }   # DAY order from a prior session: expiry handled in Step 11/10
            $q = Get-OpusOrderQuote $o $quotes
            if ($null -eq $q) { continue }
            if (Test-OpusSimulatedFill ([double]$o.limit) $q.Natural $o.kind) {
                Complete-OpusFill $state $o ([double]$o.limit) ([int]$o.qty) $today $ctx
            }
            continue
        }
        if (-not $o.alpaca_order_id) { continue }
        $g = Get-OpusOrderById $o.alpaca_order_id
        if ($null -eq $g) { continue }
        $filled = [int]([double]$g.filled_qty)
        if ($g.status -eq 'filled') {
            Complete-OpusFill $state $o ([Math]::Abs([double]$g.filled_avg_price)) $filled $today $ctx
        } elseif ($g.status -in 'canceled', 'expired', 'rejected') {
            if ($filled -gt 0) { Complete-OpusFill $state $o ([Math]::Abs([double]$g.filled_avg_price)) $filled $today $ctx }
            else { $state.working_orders = @(@($state.working_orders) | Where-Object { $_.client_order_id -ne $o.client_order_id }) }
            Add-OpusOrderEvent ([ordered]@{ ts = (Get-OpusUtcNow).ToString('o'); trade_id = $o.trade_id; client_order_id = $o.client_order_id
                                            alpaca_order_id = $o.alpaca_order_id; action = $o.action; attempt = $o.attempt; status = $g.status
                                            filled_qty = $filled; reject_reason = $g.status; dry_run = $false })
        }
    }
}

# ── Exits (step 10) ───────────────────────────────────────────────────────────

function Get-OpusBarCache($state, [string]$symbol, [hashtable]$barsBySym, [string]$lastSession) {
    $c = $state.bar_cache[$symbol]
    if ($null -ne $c -and (ConvertTo-OpusDate $c.date) -eq $lastSession) { return $c }
    if (-not $barsBySym.ContainsKey($symbol)) { return $c }
    $ind = Get-OpusIndicators $barsBySym[$symbol] $script:OpusCfg
    if ($null -eq $ind) { return $c }
    $c = [ordered]@{ date = $ind.Date; close = $ind.Close; ema20 = $ind.Ema20; ema50 = $ind.Ema50; atr = $ind.Atr }
    $state.bar_cache[$symbol] = $c
    return $c
}

function Invoke-OpusExits($state, [hashtable]$quotes, [hashtable]$prices, [hashtable]$barsBySym, $ctx) {
    $today = $ctx.Today
    foreach ($pos in @(Get-OpusModePositions $state)) {
        $L = $quotes[$pos.long_occ]; $S = $quotes[$pos.short_occ]
        $q = Get-OpusSpreadQuote $(if ($pos.sleeve -like 'A*') { 'A' } else { 'B' }) $L $S $script:OpusCfg
        if ($null -ne $q) {
            $pos.last_value = [double]$q.Mid
            $e = [double]$pos.entry_fill_price
            $pct = if ($pos.sleeve -like 'A*') { ([double]$q.Mid - $e) / $e } else { ($e - [double]$q.Mid) / $e }
            if ($null -eq $pos.mfe_pct -or $pct -gt [double]$pos.mfe_pct) { $pos.mfe_pct = $pct }
            if ($null -eq $pos.mae_pct -or $pct -lt [double]$pos.mae_pct) { $pos.mae_pct = $pct }
        } else { Write-Opus ("QUOTE_UNAVAILABLE {0} {1}" -f $pos.prefix, $pos.underlying) 'DarkYellow' }

        # Stop confirmation counter: consecutive scans in the same session.
        if ((ConvertTo-OpusDate $pos.stop_hits_date) -ne $today) { $pos.stop_hits = 0; $pos.stop_hits_date = $today }
        $pos.stop_hits = if (Test-OpusStopCondition $pos $q $script:OpusCfg) { [int]$pos.stop_hits + 1 } else { 0 }

        if (-not $ctx.ExitWindow) { continue }

        $earn = Get-OpusEarningsFor $ctx.Earnings $pos.underlying
        $nx = $earn.Next
        if ($null -eq $nx) {
            $since = if ($null -ne $earn.Last) { Get-OpusDayDiff $earn.Last $today } else { $null }
            $key = "earn-$($pos.trade_id)-$today"
            if ($null -ne $since -and $since -le [int]$script:OpusCfg.EARNINGS_MAX_DAYS_SINCE_LAST) {
                if (-not $state.info_logged.ContainsKey($key)) { Write-Opus "EARNINGS_NEXT_NOT_LISTED $($pos.underlying)" 'DarkGray'; $state.info_logged[$key] = $true }
            } else { Write-Opus "EARNINGS_DATA_MISSING $($pos.underlying)" 'DarkYellow' }
        }
        $bar = Get-OpusBarCache $state $pos.underlying $barsBySym $ctx.LastSession
        $lastBar = $null
        if ($null -ne $bar -and (ConvertTo-OpusDate $bar.date) -gt (ConvertTo-OpusDate $pos.entry_fill_date)) {
            $lastBar = @{ Date = $bar.date; Close = $bar.close; Ema20 = $bar.ema20; Ema50 = $bar.ema50 }
        }
        $exDiv = $false; $div = $null
        if ($pos.sleeve -like 'A*' -and $null -ne $ctx.ExDiv -and $ctx.ExDiv.ContainsKey($pos.underlying)) {
            $exDiv = ($ctx.ExDiv[$pos.underlying].ExDate -eq $ctx.NextSession); $div = $ctx.ExDiv[$pos.underlying].Amount
        }
        $x = @{
            Today = $today; NextEarnings = $nx; Dte = (Get-OpusDayDiff $today $pos.expiration); Quote = $q
            PNow = $prices[$pos.underlying]; ShortMid = $(if ($null -ne $S -and (Test-OpusQuotable $S $script:OpusCfg)) { Get-OpusMid $S } else { $null })
            StopHits = $pos.stop_hits; LastBar = $lastBar
            TradingDaysHeld = (Get-OpusTradingDaysBetween $pos.entry_fill_date $ctx.LastSession $ctx.Sessions)
            ExDivTomorrow = $exDiv; DividendPerShare = $div
        }
        $dec = Get-OpusExitDecision $pos $x $script:OpusCfg
        $working = @(@($state.working_orders) | Where-Object { $_.trade_id -eq $pos.trade_id -and $_.action -ne 'E' })[0]
        $sleeveCode = if ($pos.sleeve -like 'A*') { 'A' } else { 'B' }

        if ($null -ne $working) {
            if ($null -ne $dec -and $dec.Type -eq 'FORCED' -and -not $working.forced) {
                if (Remove-OpusWorkingOrder $state $working 'canceled_for_forced') { $working = $null }
            } else {
                Update-OpusExitOrder $state $working $quotes $ctx
                continue
            }
        }
        if ($null -eq $dec -or $null -ne $working) { continue }
        if ($null -eq $q) { continue }   # no quotes -> cannot price an exit this scan
        $action = if ([int]$dec.Qty -lt [int]$pos.qty_open) { 'P' } else { 'X' }
        $o = New-OpusWorkingOrder $sleeveCode $action $pos.underlying $pos.trade_id @{ Long = $pos.long_occ; Short = $pos.short_occ } ([int]$dec.Qty) `
                ([double]$q.Mid) ([double]$q.CloseNatural) 0 ($dec.Type -eq 'FORCED') $dec.Reason $null $today $pos.prefix
        if (Send-OpusOrder $o) {
            $state.working_orders = @(@($state.working_orders) + , $o)
            Write-Opus ("EXIT {0} {1} {2} ({3}) x{4} limit {5}" -f $dec.Rule, $pos.underlying, $dec.Reason, $dec.Type, $dec.Qty, (Format-OpusLimitPrice $o.limit $o.kind $script:OpusCfg)) 'Cyan'
            Add-OpusAction "exit:$($pos.underlying):$($dec.Reason)"
        }
    }
}

# Reprice a working exit (6.3). Discretionary: attempts 0-2 then abandon.
# Forced: attempts >= 2 at natural, reprice every scan, never abandon.
function Update-OpusExitOrder($state, $o, [hashtable]$quotes, $ctx) {
    $q = Get-OpusOrderQuote $o $quotes
    if ($null -eq $q) { return }
    $next = [int]$o.attempt + 1
    if (-not $o.forced -and $next -gt [int]$script:OpusCfg.EXIT_MAX_REPRICES_DISCRETIONARY) {
        Remove-OpusWorkingOrder $state $o 'abandoned_discretionary' | Out-Null
        return
    }
    if (-not (Remove-OpusWorkingOrder $state $o 'canceled_for_reprice')) { return }
    $n = New-OpusWorkingOrder $o.sleeve_code $o.action $o.underlying $o.trade_id $o.legs ([int]$o.qty) $q.Mid $q.Natural $next ([bool]$o.forced) $o.exit_reason $null $ctx.Today $o.prefix
    if (Send-OpusOrder $n) { $state.working_orders = @(@($state.working_orders) + , $n) }
    if ($o.forced -and $ctx.Et -ge $ctx.ForcedLateEt -and $o.exit_reason -eq 'DTE') { Write-Opus "ERROR FORCED_EXIT_UNFILLED $($o.underlying)" 'Red' }
}

# ── Working entries (step 11) ─────────────────────────────────────────────────

function Update-OpusEntryOrders($state, [hashtable]$quotes, $ctx) {
    foreach ($o in @(Get-OpusModeOrders $state | Where-Object { $_.action -eq 'E' })) {
        if ((ConvertTo-OpusDate $o.session_date) -ne $ctx.Today -or -not $ctx.EntryWindow) {
            Remove-OpusWorkingOrder $state $o 'ENTRY_ABANDONED_UNFILLED' | Out-Null
            Add-OpusSkip $ctx.Today $o.underlying $o.sleeve_code 'ENTRY_ABANDONED_UNFILLED' "attempt $($o.attempt), limit $($o.limit)"
            continue
        }
        $next = [int]$o.attempt + 1
        if ($next -gt [int]$script:OpusCfg.ENTRY_MAX_REPRICES) {
            Remove-OpusWorkingOrder $state $o 'ENTRY_ABANDONED_UNFILLED' | Out-Null
            Add-OpusSkip $ctx.Today $o.underlying $o.sleeve_code 'ENTRY_ABANDONED_UNFILLED' "3 attempts, last limit $($o.limit)"
            continue
        }
        $q = Get-OpusOrderQuote $o $quotes
        if ($null -eq $q) { continue }
        $price = Get-OpusRepricePrice $q.Mid $q.Natural $o.kind $next $script:OpusCfg
        $width = [double]$o.entry_ctx.width
        if (-not (Test-OpusEntryPriceOk $o.sleeve_code $price $width $ctx.Equity $script:OpusCfg)) {
            Remove-OpusWorkingOrder $state $o 'ENTRY_ABANDONED_PRICE' | Out-Null
            Add-OpusSkip $ctx.Today $o.underlying $o.sleeve_code 'ENTRY_ABANDONED_PRICE' ("attempt {0} price {1:F2} fails constraint" -f $next, $price)
            continue
        }
        if (-not (Remove-OpusWorkingOrder $state $o 'canceled_for_reprice')) { continue }
        $n = New-OpusWorkingOrder $o.sleeve_code 'E' $o.underlying $o.trade_id $o.legs ([int]$o.qty) $q.Mid $q.Natural $next $false $null $o.entry_ctx $ctx.Today $o.prefix
        if (Send-OpusOrder $n) { $state.working_orders = @(@($state.working_orders) + , $n) }
    }
}

# ── Entry evaluation (step 12) ────────────────────────────────────────────────

function Get-OpusRegimeMult([string]$sleeve, [string]$regime) {
    $m = if ($sleeve -eq 'A') { $script:OpusCfg.A_REGIME_MULT } else { $script:OpusCfg.B_REGIME_MULT }
    if (-not $m.ContainsKey($regime)) { return 0.0 }
    return [double]$m[$regime]
}

function Invoke-OpusEntryEvaluation($state, $ctx) {
    $cfg = $script:OpusCfg; $today = $ctx.Today
    $state.last_entry_eval_date = $today
    Save-OpusState $state $cfg
    Write-Opus "entry evaluation $today" 'Cyan'

    $uni = $ctx.Universe
    foreach ($d in $uni.Dropped) { Add-OpusSkip $today $d.symbol 'ALL' 'FUNDAMENTALS' $d.reason }
    if ($uni.TooSmall) { Add-OpusSkip $today '*' 'ALL' 'UNIVERSE_TOO_SMALL' "$($uni.Symbols.Count) symbols pass the fundamentals filter (need >= 10)"; Write-Opus 'UNIVERSE_TOO_SMALL -- no entries' 'Yellow'; return }

    $syms = @($uni.Symbols)
    $bars = $ctx.Bars
    $spy = $bars[[string]$cfg.BENCHMARK]
    $prices = $ctx.Prices
    $spyNow = $prices[[string]$cfg.BENCHMARK]

    # Regime (existing swing function, completed SPY bars).
    $regime = $null
    try {
        $r = Get-SwingRegime $script:AlpacaCfg $spy
        if ($null -ne $r -and $r.Regime -in 'BULL', 'NEUTRAL', 'RANGING', 'BEAR' -and -not ([string]$r.Reason -like 'Insufficient*')) { $regime = $r.Regime }
    } catch { $regime = $null }
    if ($null -eq $regime) {
        Write-Opus 'REGIME_UNAVAILABLE -- treated as BEAR, no entries' 'Yellow'
        Add-OpusSkip $today '*' 'ALL' 'REGIME_UNAVAILABLE' 'regime function failed or had insufficient SPY data'
        return
    }

    # Indicators, RS ranking.
    $ind = @{}; $scores = @{}; $rsInfo = @{}
    foreach ($s in $syms) {
        $b = @($bars[$s])
        if ($b.Count -lt [int]$cfg.MIN_BARS_REQUIRED) { Add-OpusSkip $today $s 'ALL' 'INSUFFICIENT_BARS' "$($b.Count) completed bars"; continue }
        $ind[$s] = Get-OpusIndicators $b $cfg
        $rs = Get-OpusRsScore $b $spy $cfg
        if ($null -eq $rs) { Add-OpusSkip $today $s 'ALL' 'INSUFFICIENT_BARS' 'RS lookback unavailable'; continue }
        if ($rs.BarGap) { Write-Opus "BAR_GAP $s" 'DarkGray' }
        $scores[$s] = [double]$rs.Score; $rsInfo[$s] = $rs
    }
    $pct = Get-OpusRsPercentile $scores ([double]$cfg.RS_TOP_PCT)

    # IV history (7.3) for the eligible universe.
    $ivMap = @{}
    foreach ($s in $scores.Keys) { $iv = Get-OpusAtmIv $s $prices[$s] $today; if ($null -ne $iv) { $ivMap[$s] = $iv } }
    $ivRanks = Update-OpusIvHistory $cfg $today $ivMap

    # Gates per sleeve (steps 1, 4, 5).
    $cand = @{ A = @(); B = @() }
    foreach ($s in $scores.Keys) {
        $i = $ind[$s]; $pNow = $prices[$s]
        $earn = Get-OpusEarningsFor $ctx.Earnings $s
        $eg = Test-OpusEarningsGate $today $earn.Next $earn.Last $cfg
        foreach ($sl in 'A', 'B') {
            $mult = Get-OpusRegimeMult $sl $regime
            $en = if ($sl -eq 'A') { $cfg.A_ENABLED } else { $cfg.B_ENABLED }
            if (-not $en -or $mult -le 0) { Add-OpusSkip $today $s $sl 'REGIME_BLOCK' "regime $regime"; continue }
            if (-not (Test-OpusTrendGate $i.Close $i.Ema20 $i.Ema50)) { Add-OpusSkip $today $s $sl 'TREND_GATE' ("C {0:F2} EMA20 {1:F2} EMA50 {2:F2}" -f $i.Close, $i.Ema20, $i.Ema50); continue }
            if (-not $pct[$s].Pass) { Add-OpusSkip $today $s $sl 'RS_PERCENTILE' ("rank {0}/{1} (top {2})" -f $pct[$s].Rank, $pct[$s].M, $pct[$s].K); continue }
            if (-not $eg.Pass) { Add-OpusSkip $today $s $sl $eg.Reason $eg.Detail; continue }
            $detail = [ordered]@{ close = $i.Close; open = $i.Open; ema20 = $i.Ema20; ema50 = $i.Ema50; atr = $i.Atr; p_now = $pNow
                                  rs63 = $rsInfo[$s].Rs63; rs126 = $rsInfo[$s].Rs126; rs_score = $scores[$s]; rs_rank = $pct[$s].Rank }
            if ($sl -eq 'A') {
                $pb = Get-OpusPullbackTrigger $bars[$s] $i.Ema20 $i.Ema50 $i.Atr $pNow $spy $spyNow $cfg
                $detail.ema20_zone = $pb.Zone; $detail.pullback_touch_date = $pb.TouchDate; $detail.trend_q = $pb.TrendQ; $detail.rs20_diff = $pb.Rs20Diff
                if (-not $pb.Pullback) {
                    $why = @(); if (-not $pb.Touched) { $why += 'no EMA20 touch' }; if (-not $pb.Reclaimed) { $why += 'no reclaim' }
                    if (-not $pb.TrendOk) { $why += ("trend_q {0:F2}" -f $pb.TrendQ) }; if (-not $pb.RsOk) { $why += ("rs20 {0:F2}" -f $pb.Rs20Diff) }
                    Add-OpusSkip $today $s 'A' 'NO_PULLBACK' ($why -join ', '); continue
                }
                if ($null -eq $pNow -or $pNow -lt $i.Ema20 -or $pNow -lt $i.Ema50) { Add-OpusSkip $today $s 'A' 'INTRADAY_INVALIDATED' "p_now $pNow"; continue }
            } else {
                if (-not (Test-OpusSleeveBTrigger $i.Close $i.Open $i.Ema20 $i.Atr $cfg)) { Add-OpusSkip $today $s 'B' 'NO_TRIGGER' ("C-EMA20 {0:F2}, ATR {1:F2}, green {2}" -f ($i.Close - $i.Ema20), $i.Atr, ($i.Close -gt $i.Open)); continue }
                if ($null -eq $pNow -or $pNow -lt $i.Ema20 -or ($pNow - $i.Ema20) -gt [double]$cfg.B_ENTRY_MAX_ATR_ABOVE_EMA_FAST * $i.Atr) { Add-OpusSkip $today $s 'B' 'INTRADAY_INVALIDATED' "p_now $pNow"; continue }
            }
            $cand[$sl] += , @{ Symbol = $s; Score = $scores[$s]; Ind = $i; Spot = $pNow; Earn = $eg; Detail = $detail; Mult = $mult; IvRank = $ivRanks[$s] }
        }
    }
    foreach ($sl in 'A', 'B') { $cand[$sl] = @($cand[$sl] | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Symbol } }) }

    # Priority loop (5.3) with guards, selection, sizing.
    $idx = @{ A = 0; B = 0 }
    while ($idx.A -lt $cand.A.Count -or $idx.B -lt $cand.B.Count) {
        $openA = 0.0; $openB = 0.0
        foreach ($p in (Get-OpusModePositions $state)) { if ($p.sleeve -like 'A*') { $openA += Get-OpusOpenRisk $p } else { $openB += Get-OpusOpenRisk $p } }
        foreach ($o in @(Get-OpusModeOrders $state | Where-Object { $_.action -eq 'E' })) { if ($o.sleeve_code -eq 'A') { $openA += Get-OpusOrderRisk $o } else { $openB += Get-OpusOrderRisk $o } }
        $order = Get-OpusSleeveOrder $openA $openB $ctx.Equity $cfg
        $sl = $order.First
        if ($idx[$sl] -ge $cand[$sl].Count) { $sl = if ($sl -eq 'A') { 'B' } else { 'A' } }
        $c = $cand[$sl][$idx[$sl]]; $idx[$sl]++
        $res = Invoke-OpusCandidate $state $sl $c $regime $ctx
        if ($res -in 'DAILY_ENTRY_CAP', 'DD_POSITION_LIMIT', 'RISK_CAP') {
            foreach ($rest in 'A', 'B') {
                for ($j = $idx[$rest]; $j -lt $cand[$rest].Count; $j++) { Add-OpusSkip $today $cand[$rest][$j].Symbol $rest "LOOP_STOPPED_$res" 'not evaluated' }
            }
            break
        }
    }
}

# One candidate: sleeve-full, symbol guards, contracts, price, sizing, submit.
# Returns $null on entry, else the skip reason.
function Invoke-OpusCandidate($state, [string]$sl, $c, [string]$regime, $ctx) {
    $cfg = $script:OpusCfg; $today = $ctx.Today; $s = $c.Symbol
    $prefix = if ($sl -eq 'A') { $cfg.A_PREFIX } else { $cfg.B_PREFIX }
    $sleeveName = if ($sl -eq 'A') { 'A_CALL_DEBIT' } else { 'B_PUT_CREDIT' }
    $skip = { param($reason, $detail) Add-OpusSkip $today $s $sl $reason $detail; return $reason }

    $nOpen = @(Get-OpusModePositions $state | Where-Object { $_.sleeve -eq $sleeveName }).Count + @(Get-OpusModeOrders $state | Where-Object { $_.action -eq 'E' -and $_.sleeve_code -eq $sl }).Count
    $max = if ($sl -eq 'A') { [int]$cfg.A_MAX_OPEN } else { [int]$cfg.B_MAX_OPEN }
    if ($nOpen -ge $max) { return (& $skip 'SLEEVE_FULL' "$nOpen open/working") }

    $gctx = Get-OpusGuardContext $state $ctx
    $block = Get-OpusSymbolBlock $s $today $gctx
    if ($block) { return (& $skip $block '') }

    # Contracts + expiry selection.
    $type = if ($sl -eq 'A') { 'call' } else { 'put' }
    $dMin = if ($sl -eq 'A') { [int]$cfg.A_DTE_MIN } else { [int]$cfg.B_DTE_MIN }
    $dMax = if ($sl -eq 'A') { [int]$cfg.A_DTE_MAX } else { [int]$cfg.B_DTE_MAX }
    $dTg  = if ($sl -eq 'A') { [int]$cfg.A_DTE_TARGET } else { [int]$cfg.B_DTE_TARGET }
    $xDte = if ($sl -eq 'A') { [int]$cfg.A_EXIT_DTE } else { [int]$cfg.B_EXIT_DTE }
    $contracts = Get-OpusContracts $s $type (Add-OpusDays $today ($xDte + 1)) (Add-OpusDays $today ($dMax + 35))
    if ($contracts.Count -eq 0) { return (& $skip 'NO_VALID_CONTRACTS' 'contracts endpoint returned none') }
    $exps = @($contracts | ForEach-Object { ConvertTo-OpusDate $_.expiration_date } | Sort-Object -Unique)
    $sel = Select-OpusExpiries $exps $today $dMin $dMax $dTg $xDte $ctx.SessionSet $ctx.CalFrom $ctx.CalTo
    if ($sel.Expiries.Count -eq 0) { return (& $skip 'NO_VALID_CONTRACTS' 'no monthly expiration') }
    if ($sel.Fallback) { Write-Opus "EXPIRY_FALLBACK $s $sl -> $($sel.Expiries[0].Date)" 'DarkGray' }

    $reason = 'NO_VALID_CONTRACTS'; $pick = $null; $pickExp = $null
    foreach ($e in $sel.Expiries) {
        $snaps = Get-OpusChainSnapshots $s $type $e.Date
        $legs = @($contracts | Where-Object { (ConvertTo-OpusDate $_.expiration_date) -eq $e.Date } | ForEach-Object { ConvertTo-OpusLeg $_ $snaps[[string]$_.symbol] $type })
        $r = if ($sl -eq 'A') { Select-OpusSleeveAPair $legs ([double]$c.Spot) $cfg } else { Select-OpusSleeveBPair $legs ([double]$c.Ind.Ema50) $cfg }
        if ($null -ne $r.Pair) { $pick = $r.Pair; $pickExp = $e; break }
        $reason = $r.Reason
    }
    if ($null -eq $pick) { return (& $skip $reason ("expiries tried: " + (($sel.Expiries | ForEach-Object { $_.Date }) -join ','))) }

    # Sizing + P5/P6.
    if ($sl -eq 'A') {
        $sz = Get-OpusSizingA ([double]$pick.DebitMid) $ctx.Equity $c.Mult $cfg
        if (-not $sz.Ok) { return (& $skip $sz.Reason ("cost_1 {0:F0} > cap {1:F0} ({2} {3}/{4})" -f $sz.Cost1, $sz.SingleCap, $pickExp.Date, $pick.Long.Strike, $pick.Short.Strike)) }
        $unitRisk = $sz.Cost1; $unitExp = $sz.Cost1; $mid = [double]$pick.DebitMid; $nat = [double]$pick.DebitNatural; $width = [double]$pick.Width
    } else {
        $sz = Get-OpusSizingB ([double]$pick.CreditMid) ([double]$pick.Width) $ctx.Equity $c.Mult $cfg
        if (-not $sz.Ok) { return (& $skip $sz.Reason ("max loss {0:F0} > cap {1:F0}" -f $sz.MaxLoss1, $sz.HardCap)) }
        $unitRisk = $sz.MaxLoss1; $unitExp = [double]$pick.Width * 100; $mid = [double]$pick.CreditMid; $nat = [double]$pick.CreditNatural; $width = [double]$pick.Width
    }
    $caps = Resolve-OpusRiskCaps ([int]$sz.Contracts) $unitRisk $unitExp $gctx.OpenRiskTotal ([double]$gctx.Exposure[$s]) $ctx.Equity $cfg
    if ($caps.Contracts -le 0) { return (& $skip $caps.Reason ("open risk {0:F0}, unit {1:F0}" -f $gctx.OpenRiskTotal, $unitRisk)) }
    $qty = [int]$caps.Contracts

    # Buying power feasibility (5.1).
    $cost = if ($sl -eq 'A') { $mid * 100 * $qty } else { $width * 100 * $qty }
    if ($null -ne $ctx.OptionsBuyingPower -and [double]$ctx.OptionsBuyingPower -lt $cost) { return (& $skip 'BUYING_POWER' ("need {0:F0}" -f $cost)) }

    # Draft trade record (spec 7.1) + attempt 0.
    $long = $pick.Long; $short = $pick.Short
    $tradeId = New-OpusTradeId $prefix $s ($today -replace '-', '')
    $legRec = { param($leg, $side) [ordered]@{ occ_symbol = $leg.Occ; type = $leg.Type; side = $side; strike = $leg.Strike; expiration = $leg.Expiration; ratio = 1
                                              delta_at_entry = $leg.Delta; iv_at_entry = $leg.Iv; oi_at_entry = $leg.Oi; bid_at_entry = $leg.Bid; ask_at_entry = $leg.Ask } }
    $c.Detail.expiry_fallback = [bool]$sel.Fallback
    $draft = [ordered]@{
        trade_id = $tradeId; strategy_version = $cfg.STRATEGY_VERSION; sleeve = $sleeveName; prefix = $prefix; underlying = $s
        legs = @((& $legRec $long 'long'), (& $legRec $short 'short'))
        long_occ = $long.Occ; short_occ = $short.Occ; long_strike = $long.Strike; short_strike = $short.Strike; expiration = $pickExp.Date
        width = $width; qty_initial = $qty; qty_open = $qty; entry_signal_date = $c.Ind.Date; entry_time = $null; entry_fill_date = $null
        entry_mid = $mid; entry_natural = $nat; entry_fill_price = $null; entry_attempts = 0; entry_slippage = $null; entry_slippage_pct = $null
        max_risk_usd = $qty * $unitRisk; regime = $regime; regime_mult = $c.Mult; dd_mode = [bool]$state.dd_mode
        equity_at_entry = $ctx.Equity; spot_at_entry = $c.Spot; signal_detail = $c.Detail; iv_rank = $c.IvRank
        earnings_next_at_entry = $c.Earn.Next; earnings_last_at_entry = $c.Earn.Last; dte_at_entry = $pickExp.Dte
        partial_exits = @(); partial_taken = $false; partial_fill_date = $null; realized_partial = 0.0
        exit_time = $null; exit_reason = $null; exit_mid = $null; exit_fill_price = $null; exit_slippage = $null; exit_attempts = 0
        fees = 0.0; gross_pnl = $null; net_pnl = $null; r_multiple = $null; days_held_calendar = $null; days_held_trading = $null
        mfe_pct = $null; mae_pct = $null; stop_hits = 0; stop_hits_date = $null; last_value = $null; dry_run = (Get-OpusMode); notes = @()
    }
    $o = New-OpusWorkingOrder $sl 'E' $s $tradeId @{ Long = $long.Occ; Short = $short.Occ } $qty $mid $nat 0 $false $null $draft $today $prefix
    if (-not (Send-OpusOrder $o)) { return (& $skip 'ORDER_REJECTED' 'submit failed') }
    $state.working_orders = @(@($state.working_orders) + , $o)
    Write-Opus ("ENTRY {0} {1} x{2} {3} {4}/{5} limit {6} ({7})" -f $prefix, $s, $qty, $pickExp.Date, $long.Strike, $short.Strike, (Format-OpusLimitPrice $o.limit $o.kind $cfg), $(if ($o.dry_run) { 'DRY_RUN' } else { 'live' })) 'Green'
    Add-OpusAction "entry:$s"
    return $null
}

# Guard context: what is open/working, other strategies' stock, cooldowns.
function Get-OpusGuardContext($state, $ctx) {
    $under = @{}; $expo = @{}; $openRisk = 0.0; $n = 0; $entriesToday = 0
    foreach ($p in (Get-OpusModePositions $state)) {
        $under[$p.underlying] = $true; $expo[$p.underlying] = [double]$expo[$p.underlying] + (Get-OpusExposure $p)
        $openRisk += Get-OpusOpenRisk $p; $n++
        if ((ConvertTo-OpusDate $p.entry_fill_date) -eq $ctx.Today) { $entriesToday++ }
    }
    foreach ($o in @(Get-OpusModeOrders $state | Where-Object { $_.action -eq 'E' })) {
        $under[$o.underlying] = $true; $expo[$o.underlying] = [double]$expo[$o.underlying] + (Get-OpusOrderExposure $o)
        $openRisk += Get-OpusOrderRisk $o; $n++
        if ((ConvertTo-OpusDate $o.session_date) -eq $ctx.Today) { $entriesToday++ }
    }
    return @{ Cfg = $script:OpusCfg; OpusUnderlyings = $under; StockHeld = $ctx.StockHeld; EntriesToday = $entriesToday
              Cooldown = $state.cooldown; DdMode = [bool]$state.dd_mode; OpenPlusWorking = $n; OpenRiskTotal = $openRisk; Exposure = $expo }
}

# IV of the call nearest ATM in the expiry nearest 30 DTE (7.3).
function Get-OpusAtmIv([string]$symbol, $spot, [string]$today) {
    if ($null -eq $spot) { return $null }
    try {
        $cons = Get-OpusContracts $symbol 'call' (Add-OpusDays $today 15) (Add-OpusDays $today 45)
        if ($cons.Count -eq 0) { return $null }
        $exp = @($cons | ForEach-Object { ConvertTo-OpusDate $_.expiration_date } | Sort-Object -Unique |
                 Sort-Object @{ Expression = { [Math]::Abs((Get-OpusDayDiff $today $_) - 30) } })[0]
        $snaps = Get-OpusChainSnapshots $symbol 'call' $exp ([Math]::Floor($spot * 0.95)) ([Math]::Ceiling($spot * 1.05))
        $best = $null; $bestDist = [double]::MaxValue
        foreach ($c in @($cons | Where-Object { (ConvertTo-OpusDate $_.expiration_date) -eq $exp })) {
            $sn = $snaps[[string]$c.symbol]
            if ($null -eq $sn -or $null -eq $sn.impliedVolatility) { continue }
            $d = [Math]::Abs([double]$c.strike_price - [double]$spot)
            if ($d -lt $bestDist) { $bestDist = $d; $best = [double]$sn.impliedVolatility }
        }
        return $best
    } catch { return $null }
}

# ── Live reconciliation (steps 5-6, E0 detection) ─────────────────────────────

function Test-OpusLiveIntegrity($state, $positions) {
    if (Get-OpusMode) { return }
    $byOcc = @{}
    foreach ($p in @($positions)) { if ($p.asset_class -eq 'us_option') { $byOcc[[string]$p.symbol] = [int]([double]$p.qty) } }
    foreach ($pos in (Get-OpusModePositions $state)) {
        $expLong = [int]$pos.qty_open; $expShort = -[int]$pos.qty_open
        $gotLong = [int]$byOcc[$pos.long_occ]; $gotShort = [int]$byOcc[$pos.short_occ]
        if ($gotLong -ne $expLong -or $gotShort -ne $expShort) {
            Write-Opus ("ERROR E0 LEG_MISMATCH {0}: long {1}/{2}, short {3}/{4} -- manual review required" -f $pos.underlying, $gotLong, $expLong, $gotShort, $expShort) 'Red'
            $state.manual_review_required = $true
        }
    }
}

# ── Main scan (Section 8) ─────────────────────────────────────────────────────

function Import-OpusConfig {
    $path = Join-Path $script:OPUS_ROOT 'config/opus_options_config.psd1'
    try { $cfg = Import-PowerShellDataFile -LiteralPath $path } catch { return @{ Cfg = $null; Errors = @("cannot load ${path}: $($_.Exception.Message)") } }
    $cfg = Set-OpusEnvOverrides $cfg
    $v = Test-OpusConfig $cfg
    if (-not $v.Valid) { return @{ Cfg = $null; Errors = $v.Errors } }
    return @{ Cfg = $cfg; Errors = @() }
}

function Invoke-OpusOptionsScan {
    $script:OpusActions = @()
    $loaded = Import-OpusConfig
    if ($null -eq $loaded.Cfg) {
        Write-Opus ("CONFIG_INVALID -- options module disabled this run: " + ($loaded.Errors -join '; ')) 'Red'
        return
    }
    $cfg = $loaded.Cfg; $script:OpusCfg = $cfg
    if (-not $cfg.OPTIONS_ENABLED) { Write-Opus 'OPTIONS_ENABLED = false -- nothing to do' 'DarkGray'; return }
    $script:AlpacaCfg = Load-AlpacaConfig

    $utc = Get-OpusUtcNow; $et = ConvertTo-OpusEt $utc; $today = $et.ToString('yyyy-MM-dd')
    Write-Opus ("scan {0} ET | {1} | v{2}" -f $et.ToString('yyyy-MM-dd HH:mm'), $(if ($cfg.DRY_RUN) { 'DRY_RUN' } else { 'LIVE' }), $cfg.STRATEGY_VERSION) 'Cyan'

    $loadedState = Import-OpusState $cfg; $state = $loadedState.State
    if ($loadedState.Rebuilt) { Write-Opus 'state file missing -- starting fresh (5.4 reconciliation applies in live mode)' 'Yellow' }

    # Calendar: 40 days back (trading-day counts) .. 130 days ahead (monthly holiday checks).
    $calFrom = Add-OpusDays $today -40; $calTo = Add-OpusDays $today 130
    $cal = @(Get-OpusCalendar $calFrom $calTo)
    $sessions = @($cal | ForEach-Object { ConvertTo-OpusDate $_.date } | Where-Object { $_ } | Sort-Object)
    $sessionSet = @{}; foreach ($d in $sessions) { $sessionSet[$d] = $true }
    $todayCal = @($cal | Where-Object { (ConvertTo-OpusDate $_.date) -eq $today })[0]
    $isSession = ($null -ne $todayCal)
    $lastSession = @($sessions | Where-Object { $_ -lt $today -or ($_ -eq $today -and $isSession -and $et -ge (Get-OpusEtTime $today ([string]$todayCal.close))) } | Select-Object -Last 1)[0]
    $nextSession = @($sessions | Where-Object { $_ -gt $today } | Select-Object -First 1)[0]

    # Universe (all symbols from the file feed the earnings refresh, even before fundamentals pass).
    $uni = Import-OpusUniverse $cfg $today
    if ($uni.Warn -and -not $uni.Stale) { Write-Opus "universe refreshed $($uni.AgeDays) days ago (warn > $($cfg.UNIVERSE_STALE_WARN_DAYS))" 'DarkYellow' }
    $uniRaw = Read-OpusJson $cfg.UNIVERSE_FILE
    $uniAll = if ($null -ne $uniRaw) { @(@($uniRaw.symbols) | Where-Object { $_ } | ForEach-Object { ([string]$_.symbol).ToUpper() }) } else { @() }

    # Earnings: one-time backfill, then once per ET trading day.
    if ($isSession -and (ConvertTo-OpusDate $state.last_earnings_refresh) -ne $today) {
        $ovr = Read-OpusJson $cfg.EARNINGS_OVERRIDE_FILE
        $earnSyms = @($uniAll) + @($(if ($null -ne $ovr -and $ovr.symbols -is [hashtable]) { $ovr.symbols.Keys } else { @() }))
        $nowIso = $utc.ToString('o')
        $prev = Read-OpusJson $cfg.EARNINGS_FILE
        if ($cfg.EARNINGS_BACKFILL_ENABLED -and ($null -eq $prev -or $null -eq $prev.backfill_completed_at)) {
            Write-Opus "earnings backfill ($($cfg.EARNINGS_BACKFILL_DAYS) days)..." 'Cyan'
            $bf = Invoke-OpusEarningsBackfill $cfg $today $earnSyms $null $nowIso
            if ($bf.Written) { Write-Opus ("earnings backfill done; no report in window: " + ($bf.Missing -join ', ')) 'Green' }
            else { Write-Opus ("EARNINGS_BACKFILL_FAILED ({0} days failed) -- retry next refresh" -f @($bf.Failed).Count) 'Yellow' }
        }
        $up = Update-OpusEarnings $cfg $today $earnSyms $null $nowIso
        if ($up.Written) { $state.last_earnings_refresh = $today; Write-Opus 'earnings refreshed' 'Green' }
        else { Write-Opus ("EARNINGS_REFRESH_FAILED ({0} days failed) -- previous file kept" -f @($up.Failed).Count) 'Yellow' }
    }
    $earn = Import-OpusEarnings $cfg $today

    # Clock.
    $clock = Get-OpusClock
    $open = ($null -ne $clock -and $clock.is_open)

    # Account (options level, buying power). Positions (P7, E0).
    $acct = $null; $levelLow = $false; $obp = $null
    if ($open) {
        $acct = Get-OpusAccount
        if ($null -ne $acct) {
            $levelLow = ([int]$acct.options_trading_level -lt 3)
            $obp = $acct.options_buying_power
            if ($acct.trading_blocked -or $acct.account_blocked) { $levelLow = $true }
        }
    }
    $positions = if ($open) { @(Get-OpusPositions) } else { @() }
    $stockHeld = @{}; foreach ($p in $positions) { if ($p.asset_class -eq 'us_equity') { $stockHeld[[string]$p.symbol] = $true } }

    # Quotes for open legs + working orders; prices for open underlyings.
    $occs = @(); $unders = @()
    foreach ($p in (Get-OpusModePositions $state)) { $occs += $p.long_occ, $p.short_occ; $unders += $p.underlying }
    foreach ($o in (Get-OpusModeOrders $state)) { $occs += $o.legs.Long, $o.legs.Short; $unders += $o.underlying }
    $quotes = if ($open -and $occs.Count -gt 0) { Get-OpusLegQuotes $occs } else { @{} }

    $ctx = @{
        Today = $today; Et = $et; Sessions = $sessions; SessionSet = $sessionSet; CalFrom = $calFrom; CalTo = $calTo
        LastSession = $lastSession; NextSession = $nextSession; Earnings = $earn; Universe = $uni; StockHeld = $stockHeld
        OptionsBuyingPower = $obp; ExitWindow = $false; EntryWindow = $false; Equity = 0.0; ForcedLateEt = $null; ExDiv = @{}
    }

    # Step 5-6: fills and integrity (also while closed, for live orders).
    Update-OpusOrderFills $state $quotes $today $ctx
    if ($open) { Test-OpusLiveIntegrity $state $positions }

    if (-not $open -or -not $isSession) {
        $state.last_scan = $utc.ToString('o'); Save-OpusState $state $cfg
        Write-Opus ("market closed | positions {0} | working {1}" -f @(Get-OpusModePositions $state).Count, @(Get-OpusModeOrders $state).Count) 'DarkGray'
        return
    }

    # Step 8: equity, HWM, drawdown, day start, loss counters.
    $equity = Get-OpusEquity $state
    $hwmKey = if ($cfg.DRY_RUN) { 'hwm_dry' } else { 'hwm' }
    $state[$hwmKey] = [Math]::Max([double]$state[$hwmKey], $equity)
    $dd = Update-OpusDrawdownMode $equity ([double]$state[$hwmKey]) ([bool]$state.dd_mode) $state.hwm_at_trigger $cfg
    $state.dd_mode = $dd.DdMode; $state.hwm_at_trigger = $dd.HwmAtTrigger
    $state.max_drawdown = [Math]::Max([double]$state.max_drawdown, $dd.Drawdown)
    if ((ConvertTo-OpusDate $state.day_start_date) -ne $today) { $state.day_start_date = $today; $state.day_start_equity = $equity }
    if (Test-OpusDailyLossHalt $equity ([double]$state.day_start_equity) $cfg) { if ((ConvertTo-OpusDate $state.entries_halted_date) -ne $today) { Write-Opus 'DAILY_LOSS_HALT' 'Yellow' }; $state.entries_halted_date = $today }
    $ctx.Equity = $equity
    Save-OpusState $state $cfg

    # Windows (ET): exits open+15m .. close-3m; entries close-30m .. close-5m.
    $openEt = Get-OpusEtTime $today ([string]$todayCal.open); $closeEt = Get-OpusEtTime $today ([string]$todayCal.close)
    $ctx.ExitWindow  = ($et -ge $openEt.AddMinutes([int]$cfg.EXIT_EARLIEST_MIN_AFTER_OPEN) -and $et -lt $closeEt.AddMinutes(-[int]$cfg.EXIT_LATEST_MIN_BEFORE_CLOSE))
    $winStart = $closeEt.AddMinutes(-[int]$cfg.ENTRY_WINDOW_START_MIN_BEFORE_CLOSE); $winEnd = $closeEt.AddMinutes(-[int]$cfg.ENTRY_WINDOW_END_MIN_BEFORE_CLOSE)
    $ctx.EntryWindow = ($et -ge $winStart -and $et -lt $winEnd)
    $ctx.ForcedLateEt = $closeEt.AddMinutes(-10)

    # Step 9: completed bars. Full universe only at the entry evaluation; open underlyings when their cache is stale.
    $needEval = ($ctx.EntryWindow -and (ConvertTo-OpusDate $state.last_entry_eval_date) -ne $today -and $cfg.ENTRIES_ENABLED)
    $barSyms = @()
    if ($needEval) { $barSyms += @($uni.Symbols) + [string]$cfg.BENCHMARK }
    foreach ($u in ($unders | Sort-Object -Unique)) { $c = $state.bar_cache[$u]; if ($null -eq $c -or (ConvertTo-OpusDate $c.date) -ne $lastSession) { $barSyms += $u } }
    $barSyms = @($barSyms | Where-Object { $_ } | Sort-Object -Unique)
    $bars = @{}
    if ($barSyms.Count -gt 0) {
        $raw = Get-OpusBars $barSyms (Add-OpusDays $today (-[int]$cfg.BAR_LOOKBACK_CALENDAR_DAYS))
        foreach ($k in $raw.Keys) { $bars[$k] = Get-OpusCompletedBars $raw[$k] $et $(if ($isSession) { $closeEt } else { $null }) }
    }
    $ctx.Bars = $bars

    $priceSyms = @($unders) + $(if ($needEval) { @($uni.Symbols) + [string]$cfg.BENCHMARK } else { @() })
    $prices = Get-OpusLatestPrices @($priceSyms | Where-Object { $_ } | Sort-Object -Unique)
    $ctx.Prices = $prices

    # A5 ex-dividend data for Sleeve A underlyings (best effort).
    foreach ($p in @(Get-OpusModePositions $state | Where-Object { $_.sleeve -like 'A*' })) {
        $dv = $null; try { $dv = Get-OpusDividends $p.underlying $today (Add-OpusDays $today 7) } catch { $dv = $null }
        $hit = $null
        if ($null -ne $dv -and $null -ne $dv.corporate_actions -and $null -ne $dv.corporate_actions.cash_dividends) {
            $hit = @($dv.corporate_actions.cash_dividends | Where-Object { (ConvertTo-OpusDate $_.ex_date) -eq $nextSession })[0]
        }
        if ($null -ne $hit) { $ctx.ExDiv[$p.underlying] = @{ ExDate = $nextSession; Amount = [double]$hit.rate } }
        elseif ($null -eq $dv) {
            $key = "exdiv-$today"
            if (-not $state.info_logged.ContainsKey($key)) { Write-Opus 'EXDIV_DATA_UNAVAILABLE -- A5 skipped today' 'DarkGray'; $state.info_logged[$key] = $true }
        }
    }

    # Step 10: exits. Step 11: working entries.
    Invoke-OpusExits $state $quotes $prices $bars $ctx
    Update-OpusEntryOrders $state $quotes $ctx

    # Step 12: entry evaluation once per day inside the window.
    $evalDecision = Get-OpusEntryEvalDecision $et $winStart $winEnd $state.last_entry_eval_date $today
    if ($evalDecision -eq 'EVAL') {
        $gctx = Get-OpusGuardContext $state $ctx
        $lossesToday = @(Get-OpusModeClosed | Where-Object { (ConvertTo-OpusDate $_.close_date) -eq $today -and [double]$_.net_pnl -lt 0 }).Count
        $pblock = Get-OpusPortfolioBlock $state $today @{ Cfg = $cfg; LossesToday = $lossesToday; LevelInsufficient = $levelLow
                                                        DataStale = ($uni.Stale -or $earn.Stale); RegimeUnavailable = $false }
        if (-not $cfg.ENTRIES_ENABLED) { Write-Opus 'ENTRIES_ENABLED = false -- exits only' 'DarkGray' }
        elseif ($pblock) {
            $state.last_entry_eval_date = $today
            Add-OpusSkip $today '*' 'ALL' $pblock $(if ($pblock -eq 'DATA_STALE') { "universe stale $($uni.Stale), earnings stale $($earn.Stale)" } else { '' })
            Write-Opus "entries blocked: $pblock" 'Yellow'
        } else { Invoke-OpusEntryEvaluation $state $ctx }
    } elseif ($evalDecision -eq 'MISSED' -and $cfg.ENTRIES_ENABLED) {
        $state.last_entry_eval_date = $today
        Add-OpusSkip $today '*' 'ALL' 'ENTRY_WINDOW_MISSED' ("first scan in window at {0}" -f $et.ToString('HH:mm'))
        Write-Opus 'ENTRY_WINDOW_MISSED' 'Yellow'
    }

    # Steps 13-14: persist, metrics, summary.
    $state.last_scan = $utc.ToString('o')
    Invoke-OpusMetrics $state
    Save-OpusState $state $cfg
    $openRisk = 0.0; foreach ($p in (Get-OpusModePositions $state)) { $openRisk += Get-OpusOpenRisk $p }
    $guards = @(); if ($state.dd_mode) { $guards += 'DD_MODE' }; if ((ConvertTo-OpusDate $state.entries_halted_date) -eq $today) { $guards += 'DAILY_LOSS_HALT' }
    if ($state.strategy_halted) { $guards += 'HALTED' }; if ($state.manual_review_required) { $guards += 'MANUAL_REVIEW' }
    Write-Opus ("equity {0:F2} | hwm {1:F2} | dd {2:P1} | open_risk {3:F0} | positions {4} | working_orders {5} | actions {6} | guards_active {7}" -f
        $equity, [double]$state[$hwmKey], $dd.Drawdown, $openRisk, @(Get-OpusModePositions $state).Count, @(Get-OpusModeOrders $state).Count,
        $(if ($script:OpusActions.Count) { $script:OpusActions -join ',' } else { 'none' }), $(if ($guards.Count) { $guards -join ',' } else { 'none' })) 'White'
}

# 8.1: review at 20 trades, kill at 30 with PF < 1, go-live gates (non-dry trades only).
function Invoke-OpusMetrics($state) {
    $cfg = $script:OpusCfg
    $m = Get-OpusMetrics (Get-OpusClosedTrades) $cfg
    if ($m.Trades -ge [int]$cfg.REVIEW_AFTER_TRADES -and -not $state.reviewed_20) {
        $path = Resolve-OpusPath 'reports/opus_options_review_20.md'
        $dir = Split-Path -Parent $path; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lines = @('# Opus options review after 20 closed trades', '', "PF: $($m.PF)", "PF (haircut): $($m.PFH)", "Win rate A: $($m.WinRateA)", "Win rate B: $($m.WinRateB)")
        [System.IO.File]::WriteAllText($path, ($lines -join "`n") + "`n")
        $state.reviewed_20 = $true
    }
    if (Test-OpusKill $m $cfg) {
        if (-not $state.strategy_halted) { Write-Opus 'ERROR KILL: PF < 1.0 at >= 30 trades -- entries halted (manual reset only)' 'Red' }
        $state.strategy_halted = $true
    }
    $state.golive_gates_met = (Test-OpusGoLiveGates $m ([double]$state.max_drawdown) $cfg)
    if ($m.Trades -gt 0) { Write-Opus ("GOLIVE_GATES_MET={0} (trades {1}, PF {2})" -f $state.golive_gates_met.ToString().ToLower(), $m.Trades, $m.PF) 'DarkGray' }
}

if (-not $NoRun -and $MyInvocation.InvocationName -ne '.') {
    try { Invoke-OpusOptionsScan }
    catch {
        Write-Host ("  [OPUS] ERROR scan aborted: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 1
    }
}
