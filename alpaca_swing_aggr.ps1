# alpaca_swing_aggr.ps1 -- Swing Aggressive Mode (spec v1.1).
#
# Everything here is gated by cfg.aggr.enabled. With cfg.aggr.dry_run = $true
# (stage S1) this module is READ-ONLY against Alpaca: every API call goes
# through Invoke-AggrApi, which refuses any non-GET while dry-run is on. It
# evaluates the aggressive rules in SHADOW alongside the unchanged legacy bot,
# writes one line per symbol per scan to data/journal_swing_skips.jsonl and
# logs the full order payload it WOULD have sent (DRYRUN_ENTERED / DRYRUN_*).
#
# The Opus options sleeve (opus_options*.ps1) is not touched. Swing skips any
# underlying Opus holds or works (OPUS_CONFLICT).
#
# Dot-source dependencies: alpaca_client, alpaca_indicators, alpaca_swing_signals,
# alpaca_screener (memory, blocklists), alpaca_earnings, alpaca_risk.

$script:AggrSkipJournal = Join-Path $PSScriptRoot "data/journal_swing_skips.jsonl"
$script:AggrOpusState   = Join-Path $PSScriptRoot "data/opus_options_state.json"
$script:AggrQuoteCaveat = "FREE indicative options feed: quotes/greeks may be delayed or modeled; fills in live trading may differ"

# ── Config helpers ───────────────────────────────────────────────────────────

function Get-AggrCfg($cfg) {
    if ($null -eq $cfg -or $null -eq $cfg.aggr) { return $null }
    return $cfg.aggr
}
function Test-AggrEnabled($cfg) { $a = Get-AggrCfg $cfg; return ($null -ne $a -and [bool]$a.enabled) }
function Test-AggrDryRun($cfg)  { $a = Get-AggrCfg $cfg; return ($null -eq $a -or $null -eq $a.dry_run -or [bool]$a.dry_run) }  # default SAFE

# The ONLY door to Alpaca for this module. Dry-run => GET only.
function Invoke-AggrApi($cfg, [string]$method, [string]$path, [hashtable]$body = $null) {
    if ((Test-AggrDryRun $cfg) -and $method.ToUpper() -ne "GET") {
        throw "AGGR DRY-RUN GUARD: refused $method $path (no order changes while aggr.dry_run=true)"
    }
    return Invoke-AlpacaApi $cfg $method $path $body
}

# ── Account drawdown control (spec 5) ────────────────────────────────────────

function Get-AggrDdState([double]$equity, $a, [bool]$alreadyHalted = $false) {
    $start = [double]$a.dd_start_equity
    $floor = [double]$a.dd_floor_equity
    $ddPct = if ($start -gt 0) { [Math]::Round((($start - $equity) / $start) * 100.0, 3) } else { 0.0 }
    $r = [ordered]@{ Halted = $false; DdPct = $ddPct; Mult = 1.0
                     MaxPositions = [int]$a.max_positions; CallsAllowed = $true; Tier = "NORMAL" }
    if ($alreadyHalted -or $equity -le $floor) {
        $r.Halted = $true; $r.Mult = 0.0; $r.MaxPositions = 0; $r.CallsAllowed = $false; $r.Tier = "HALT"
    } elseif ($ddPct -ge [double]$a.dd_throttle2_pct) {
        $r.Mult = [double]$a.dd_throttle2_mult; $r.MaxPositions = [int]$a.dd_throttle2_max_positions; $r.CallsAllowed = $false; $r.Tier = "THROTTLE2"
    } elseif ($ddPct -ge [double]$a.dd_throttle1_pct) {
        $r.Mult = [double]$a.dd_throttle1_mult; $r.MaxPositions = [int]$a.dd_throttle1_max_positions; $r.CallsAllowed = $false; $r.Tier = "THROTTLE1"
    }
    return [pscustomobject]$r
}

# ── Sizing (spec 6.1 / 6.2) ──────────────────────────────────────────────────

function Get-AggrStockSize {
    param([double]$equity, [double]$buyingPower, [double]$entry, [double]$stop, $a,
          [double]$edgeMult = 1.0, [double]$regimeMult = 1.0, [double]$ddMult = 1.0)
    $rps = [Math]::Abs($entry - $stop)
    if ($entry -le 0 -or $rps -le 0 -or $ddMult -le 0) { return [pscustomobject]@{ Shares = 0; RiskPct = 0; RiskUsd = 0; Notional = 0; CappedBy = "invalid" } }
    $riskPct = [Math]::Min([double]$a.max_risk_pct * $edgeMult * $regimeMult * $ddMult, [double]$a.max_risk_pct_cap)
    $shares  = [Math]::Floor($equity * $riskPct / 100.0 / $rps)
    $cappedBy = "risk"
    $slotVal  = if ($buyingPower -gt 0) { $buyingPower / [double]$a.max_positions * 0.80 } else { [double]::MaxValue }
    $maxVal   = [Math]::Min($slotVal, [double]$a.max_notional_pct / 100.0 * $equity)
    $maxByVal = [Math]::Floor($maxVal / $entry)
    if ($maxByVal -lt $shares) { $shares = $maxByVal; $cappedBy = "notional" }
    if ($shares -lt 0) { $shares = 0 }
    return [pscustomobject]@{
        Shares = [int]$shares; RiskPct = [Math]::Round($riskPct, 4)
        RiskUsd = [Math]::Round($shares * $rps, 2); Notional = [Math]::Round($shares * $entry, 2); CappedBy = $cappedBy
    }
}

function Get-AggrCallSize([double]$equity, [double]$limitPrice, $a, [double]$ddMult = 1.0) {
    $budget = $equity * [double]$a.call_premium_pct / 100.0 * $ddMult
    $n = if ($limitPrice -gt 0) { [Math]::Floor($budget / ($limitPrice * 100.0)) } else { 0 }
    return [pscustomobject]@{ Contracts = [int]$n; Budget = [Math]::Round($budget, 2); PremiumUsd = [Math]::Round($n * $limitPrice * 100.0, 2) }
}

# Heat = sum of open risk. Items: @{ Kind='stock'; Qty; Entry; Stop } or @{ Kind='call'; MarketValue }
function Get-AggrHeat([array]$items) {
    $h = 0.0
    foreach ($i in $items) {
        if ($null -eq $i) { continue }
        if ($i.Kind -eq 'call') { $h += [Math]::Max(0.0, [double]$i.MarketValue) }
        elseif ($i.Side -eq 'short') { $h += [Math]::Abs([double]$i.Qty) * [Math]::Max(0.0, [double]$i.Stop - [double]$i.Entry) }
        else { $h += [Math]::Abs([double]$i.Qty) * [Math]::Max(0.0, [double]$i.Entry - [double]$i.Stop) }
    }
    return [Math]::Round($h, 2)
}
function Test-AggrHeatOk([double]$heatBefore, [double]$newRisk, [double]$equity, $a) {
    return (($heatBefore + $newRisk) -le ([double]$a.max_portfolio_heat_pct / 100.0 * $equity))
}

# ── Instrument choice (spec 6) ───────────────────────────────────────────────

function Test-AggrCallEligible($signal, [string]$regime, [double]$rs, $a, $dd, [int]$openCalls) {
    if (-not [bool]$a.call_enabled)                   { return "CALLS_DISABLED" }
    if (-not $dd.CallsAllowed)                         { return "DD_THROTTLE" }
    if ($regime -ne [string]$a.call_regime_required)   { return "REGIME" }
    if ($signal.Side -ne "buy")                        { return "SIDE" }
    if (@("BRKOUT","PULLBK") -notcontains $signal.Strategy) { return "SETUP" }
    if ([int]$signal.Confidence -lt [int]$a.call_min_conf)   { return "CONF" }
    if ($rs -lt [double]$a.call_min_rs)                { return "RS" }
    if ($openCalls -ge [int]$a.max_call_positions)     { return "MAX_CALLS" }
    return $null   # eligible (earnings + chain checked by caller)
}

# ── Call contract selection (spec 7) ─────────────────────────────────────────
# $chain items: @{ Occ; Expiration('yyyy-MM-dd'); Dte; Delta; Bid; Ask; Oi; Volume }

function Select-AggrCallContract([array]$chain, $a) {
    $ok = @()
    foreach ($c in $chain) {
        if ($null -eq $c) { continue }
        $bid = [double]$c.Bid; $ask = [double]$c.Ask
        if ($null -eq $c.Delta -or $bid -le 0 -or $ask -le 0 -or $ask -lt $bid) { continue }
        $dte = [int]$c.Dte; $d = [double]$c.Delta
        if ($dte -lt [int]$a.call_dte_min -or $dte -gt [int]$a.call_dte_max) { continue }
        if ($d -lt [double]$a.call_delta_min -or $d -gt [double]$a.call_delta_max) { continue }
        if ([double]$c.Oi -lt [double]$a.call_min_oi) { continue }
        if ([double]$c.Volume -lt [double]$a.call_min_volume) { continue }
        $mid = ($bid + $ask) / 2.0; $spr = $ask - $bid
        if (($spr / $mid) -gt [double]$a.call_max_spread_pct) { continue }
        if ($spr -gt [double]$a.call_max_spread_abs + 1e-9) { continue }
        $ok += [pscustomobject]@{ C = $c; DteDist = [Math]::Abs($dte - [int]$a.call_dte_target)
                                  DeltaDist = [Math]::Abs($d - [double]$a.call_delta_target); SprPct = $spr / $mid }
    }
    if ($ok.Count -eq 0) { return $null }
    return ($ok | Sort-Object DteDist, DeltaDist, SprPct | Select-Object -First 1).C
}

# attempt 0 = mid, 1 = mid + 25% spread, 2 = mid + 50% spread. Never above ask.
function Get-AggrCallLimit([double]$bid, [double]$ask, [int]$attempt) {
    $steps = @(0.0, 0.25, 0.50)
    $i = [Math]::Min([Math]::Max($attempt, 0), 2)
    $mid = ($bid + $ask) / 2.0
    return [Math]::Round([Math]::Min($ask, $mid + $steps[$i] * ($ask - $bid)), 2)
}
# Exit limit: attempt 0 = bid, 1 = bid - 25% spread, then MARKET (returns $null)
function Get-AggrCallExitLimit([double]$bid, [double]$ask, [int]$attempt) {
    if ($attempt -ge 2) { return $null }
    $px = $bid - (0.25 * $attempt) * ($ask - $bid)
    return [Math]::Round([Math]::Max(0.01, $px), 2)
}

function New-AggrCallOrderPayload([string]$occ, [int]$qty, [double]$limit, [string]$underlying, [string]$prefix, [string]$side = "buy", [string]$stamp = $null) {
    if (-not $stamp) { $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmm") }
    $body = [ordered]@{ symbol = $occ; qty = $qty.ToString(); side = $side; type = "limit"
                        time_in_force = "day"; limit_price = $limit.ToString("F2")
                        client_order_id = ("{0}_{1}_{2}" -f $prefix, $underlying, $stamp) }
    return $body
}
function New-AggrStockOrderPayload([string]$sym, [string]$side, [int]$qty, [double]$entry, [double]$stop, [double]$tpR, [string]$tag, [string]$stamp = $null) {
    if (-not $stamp) { $stamp = (Get-Date).ToString("HHmmss") }
    $r  = [Math]::Abs($entry - $stop)
    $tp = if ($side -eq "buy") { $entry + $tpR * $r } else { [Math]::Max(0.01, $entry - $tpR * $r) }
    return [ordered]@{ symbol = $sym; qty = $qty.ToString(); side = $side; type = "limit"; time_in_force = "gtc"
                       limit_price = $entry.ToString("F2"); order_class = "bracket"
                       take_profit = @{ limit_price = ([Math]::Round($tp, 2)).ToString("F2") }
                       stop_loss   = @{ stop_price  = $stop.ToString("F2") }
                       client_order_id = ("{0}_{1}_{2}" -f $tag, $sym, $stamp) }
}

# ── Exits (spec 8) ───────────────────────────────────────────────────────────

# Stock: one-time 1/3 partial at +partial_exit_r. Returns qty to sell (0 = none).
# partial_exit_r <= 0 (v1.2 Variant I) disables the partial entirely: the bracket
# take-profit at dummy_tp_r (3.5R) is the real exit target instead.
function Get-AggrStockPartialQty([double]$rMult, [int]$qty, [bool]$partialDone, $a) {
    if ($null -eq $a.partial_exit_r -or [double]$a.partial_exit_r -le 0) { return 0 }
    if ($partialDone -or $rMult -lt [double]$a.partial_exit_r) { return 0 }
    $q = [int][Math]::Floor([Math]::Abs($qty) * [double]$a.partial_exit_fraction)
    if ($q -ge [Math]::Abs($qty)) { $q = [Math]::Abs($qty) - 1 }
    return [Math]::Max(0, $q)
}

# Call exit decision. $x: UnderPx, StockStop, UnderEntry, R (per share), EntryPremium,
# Bid, Dte, DaysHeld, EarningsBeforeNextSession, PartialDone, LastClose, HighestClose, Atr, Contracts
function Get-AggrCallExitDecision($x, $a) {
    $n = [int]$x.Contracts
    if ([double]$x.UnderPx -le [double]$x.StockStop)                                      { return [pscustomobject]@{ Action = "EXIT_ALL"; Qty = $n; Reason = "UNDERLYING_STOP" } }
    if ([double]$x.Bid -le [double]$x.EntryPremium * (1.0 - [double]$a.call_premium_stop_pct)) { return [pscustomobject]@{ Action = "EXIT_ALL"; Qty = $n; Reason = "PREMIUM_STOP" } }
    if ([int]$x.Dte -le [int]$a.call_exit_dte)                                            { return [pscustomobject]@{ Action = "EXIT_ALL"; Qty = $n; Reason = "DTE" } }
    if ([int]$x.DaysHeld -ge [int]$a.hold_days_max)                                       { return [pscustomobject]@{ Action = "EXIT_ALL"; Qty = $n; Reason = "MAX_HOLD" } }
    if ([bool]$x.EarningsBeforeNextSession)                                               { return [pscustomobject]@{ Action = "EXIT_ALL"; Qty = $n; Reason = "EARNINGS" } }
    $r = [double]$x.R
    $rMult = if ($r -gt 0) { ([double]$x.UnderPx - [double]$x.UnderEntry) / $r } else { 0 }
    if (-not [bool]$x.PartialDone -and $rMult -ge [double]$a.call_partial_r) {
        $q = [int][Math]::Max(1, [Math]::Floor($n * [double]$a.call_partial_fraction))
        $act = if ($q -ge $n) { "EXIT_ALL" } else { "SELL_PARTIAL" }
        return [pscustomobject]@{ Action = $act; Qty = $q; Reason = "PARTIAL_2R" }
    }
    if ([bool]$x.PartialDone) {
        $trail = [Math]::Max([double]$x.UnderEntry + $r, [double]$x.HighestClose - 2.0 * [double]$x.Atr)
        if ([double]$x.LastClose -lt $trail) { return [pscustomobject]@{ Action = "EXIT_ALL"; Qty = $n; Reason = "TRAIL" } }
    }
    return [pscustomobject]@{ Action = "HOLD"; Qty = 0; Reason = ("{0:F2}R" -f $rMult) }
}

# ── OCC + Opus conflict (spec 10) ────────────────────────────────────────────

function Get-OccUnderlying([string]$occ) {
    if ($occ -match '^([A-Z\.]{1,6})\d{6}[CP]\d{8}$') { return $Matches[1] }
    return $null
}
function Get-AggrOpusUnderlyings($allPositions, [string[]]$myCallPrefixes = @()) {
    $set = @{}
    foreach ($p in @($allPositions)) {
        if ($null -eq $p -or $p.asset_class -ne "us_option") { continue }
        $u = Get-OccUnderlying $p.symbol
        if ($u) { $set[$u] = $true }
    }
    if (Test-Path $script:AggrOpusState) {
        try {
            $s = Get-Content $script:AggrOpusState -Raw | ConvertFrom-Json
            foreach ($x in @($s.positions) + @($s.working_orders)) {
                if ($null -eq $x) { continue }
                $u = if ($x.underlying) { [string]$x.underlying } elseif ($x.symbol) { [string]$x.symbol } else { $null }
                if ($u) { $set[$u.ToUpper()] = $true }
            }
        } catch {}
    }
    return $set
}

# ── Skip journal (spec 9) ────────────────────────────────────────────────────

function Write-AggrSkip([hashtable]$rec) {
    $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString("o") }
    foreach ($k in $rec.Keys) { $o[$k] = $rec[$k] }
    $dir = Split-Path -Parent $script:AggrSkipJournal
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $script:AggrSkipJournal -Value ($o | ConvertTo-Json -Depth 8 -Compress)
}

# ── State ────────────────────────────────────────────────────────────────────

function Initialize-AggrState($state) {
    $defaults = [ordered]@{
        aggr_halted = $false; aggr_day = ""; aggr_trades_today = 0; aggr_dry_entered = @()
        aggr_watchlist = @(); aggr_migrate_logged = @(); aggr_partial_done = @(); aggr_migrated = @(); aggr_calls = @()
        aggr_partial_failed = @(); aggr_protect_restore = @()
        aggr_shadow_open = @(); aggr_shadow_closed = @(); aggr_shadow_realized = 0.0
    }
    foreach ($k in $defaults.Keys) {
        if (-not (Get-Member -InputObject $state -Name $k -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
            $state | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        }
    }
}

# Watchlist for aggressive mode: legacy list first (unchanged), then the next
# best screener candidates up to aggr.max_watchlist. Legacy scanning is untouched.
function Get-AggrWatchlist($legacyList, $candidates, $a) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($legacyList)) { if ($s -and -not $out.Contains($s)) { $out.Add($s) } }
    $ranked = @($candidates) | Where-Object { $_ } | Sort-Object @{Expression="Tier";Ascending=$true}, @{Expression="Score";Descending=$true}
    foreach ($c in $ranked) {
        if ($out.Count -ge [int]$a.max_watchlist) { break }
        if (-not $out.Contains($c.Symbol)) { $out.Add($c.Symbol) }
    }
    return $out.ToArray()
}

# ── Options data (free indicative feed) ──────────────────────────────────────

function Get-AggrCallChain($cfg, [string]$sym, $a) {
    $today = (Get-EasternTime).Date
    $gte = $today.AddDays([int]$a.call_dte_min).ToString("yyyy-MM-dd")
    $lte = $today.AddDays([int]$a.call_dte_max).ToString("yyyy-MM-dd")
    $ct  = Invoke-AggrApi $cfg "GET" ("/v2/options/contracts?underlying_symbols={0}&type=call&status=active&expiration_date_gte={1}&expiration_date_lte={2}&limit=1000" -f $sym, $gte, $lte)
    if ($null -eq $ct -or $null -eq $ct.option_contracts) { return @() }
    $snap = Invoke-AlpacaData $cfg ("/v1beta1/options/snapshots/{0}?feed={1}&type=call&expiration_date_gte={2}&expiration_date_lte={3}&limit=1000" -f $sym, $a.options_feed, $gte, $lte)
    $snaps = if ($null -ne $snap -and $snap.snapshots) { $snap.snapshots } else { $null }
    $out = @()
    foreach ($c in @($ct.option_contracts)) {
        $s = if ($snaps) { $snaps.($c.symbol) } else { $null }
        if ($null -eq $s) { continue }
        $exp = [datetime]::ParseExact($c.expiration_date, "yyyy-MM-dd", $null)
        $out += [pscustomobject]@{
            Occ = $c.symbol; Expiration = $c.expiration_date; Dte = [int]($exp - $today).TotalDays
            Delta = if ($s.greeks) { [double]$s.greeks.delta } else { $null }
            Bid = if ($s.latestQuote) { [double]$s.latestQuote.bp } else { 0 }
            Ask = if ($s.latestQuote) { [double]$s.latestQuote.ap } else { 0 }
            Oi = if ($c.open_interest) { [double]$c.open_interest } else { 0 }
            Volume = if ($s.dailyBar) { [double]$s.dailyBar.v } else { 0 }
        }
    }
    return $out
}

function Test-AggrEarningsBefore([string]$sym, [datetime]$until) {
    $d = Get-DaysToEarnings $sym
    if ($null -eq $d) { return $null }   # unknown
    return ((Get-Date).Date.AddDays($d) -le $until.Date)
}

# ── Stock partial at +2R with an open bracket (spec 8) ───────────────────────
# A bracket's stop and take-profit legs reserve ALL the position's shares, so a
# plain market sell of 1/3 is rejected ("insufficient qty available"). Alpaca
# can only replace a leg's price, never its qty, and cancelling one leg cancels
# the whole group. So the sequence is:
#   1. cancel every live exit order on the symbol and wait until they are gone
#   2. place protection for the REMAINING 2/3 (same kind as before: OCO stop+TP,
#      trailing stop, or plain stop; one retry, then a plain-stop fallback)
#   3. market-sell 1/3 (deterministic client_order_id => no double sell)
#   4. poll the sell; if it is rejected or only partly fills, resize the
#      protection to the actual position qty
# Protection for the kept shares goes in BEFORE the sell, so the only window
# with no stop is between the cancel confirming and step 2 (one round-trip).
# Only one protection order is ever left live: Repair-DuplicateStops keeps a
# single stop per position and would cancel a second one.

$script:AggrPollTries   = 6
$script:AggrPollDelayMs = 500
$script:AggrDeadStatus  = @("filled","canceled","cancelled","expired","rejected","done_for_day","replaced")
$script:AggrStopTypes   = @("stop","stop_limit","stop_loss","trailing_stop")

function Get-AggrOrderType($o) { if ($o.order_type) { return [string]$o.order_type } return [string]$o.type }

# Live exit-side orders for a symbol: standalone orders plus live legs of any
# parent (a filled bracket parent is a BUY with status filled; its legs are the
# live sells). Same nested query the legacy stop lookup uses.
function Get-AggrExitOrders($cfg, [string]$sym, [string]$exitSide) {
    $raw = Invoke-AggrApi $cfg "GET" "/v2/orders?status=all&nested=true&symbols=$sym&limit=200"
    $out = @(); $seen = @{}
    foreach ($o in @($raw)) {
        if ($null -eq $o) { continue }
        foreach ($x in @($o) + @($o.legs)) {
            if ($null -eq $x -or $x.symbol -ne $sym -or $x.side -ne $exitSide) { continue }
            if ($script:AggrDeadStatus -contains [string]$x.status) { continue }
            if ($seen.ContainsKey([string]$x.id)) { continue }
            $seen[[string]$x.id] = $true; $out += $x
        }
    }
    return $out
}

# What protects the position now, so the same kind can be re-placed.
function Get-AggrProtectionSnapshot([array]$orders, [string]$posSide, [double]$price) {
    $isLong = ($posSide -eq "long")
    $snap = [pscustomobject]@{ Kind = "none"; Stop = 0.0; Target = 0.0; TrailPercent = $null; TrailPrice = $null }
    $trail = @($orders | Where-Object { $_ -and (Get-AggrOrderType $_) -eq "trailing_stop" }) | Select-Object -First 1
    if ($trail) {
        $snap.Kind = "trail"; $snap.TrailPercent = $trail.trail_percent; $snap.TrailPrice = $trail.trail_price
        if ($trail.stop_price) { $snap.Stop = [double]$trail.stop_price }
        return $snap
    }
    $stops = @($orders | Where-Object { $_ -and (@("stop","stop_limit","stop_loss") -contains (Get-AggrOrderType $_)) -and [double]$_.stop_price -gt 0 })
    $tps   = @($orders | Where-Object { $_ -and (Get-AggrOrderType $_) -eq "limit" -and [double]$_.limit_price -gt 0 })
    if ($stops.Count -gt 0) {
        # Alpaca returns prices as strings: compare as numbers, never lexically.
        $sp = @($stops | ForEach-Object { [double]$_.stop_price })
        $snap.Stop = if ($isLong) { ($sp | Measure-Object -Maximum).Maximum } else { ($sp | Measure-Object -Minimum).Minimum }
        $snap.Kind = "stop"
    }
    if ($tps.Count -gt 0 -and $snap.Stop -gt 0) {
        $lp = @($tps | ForEach-Object { [double]$_.limit_price })
        $tp = if ($isLong) { ($lp | Measure-Object -Minimum).Minimum } else { ($lp | Measure-Object -Maximum).Maximum }
        # An OCO whose take-profit is already through the market is rejected; keep the stop only.
        $tpOk = if ($isLong) { $tp -gt $price } else { $tp -lt $price }
        if ($tpOk) { $snap.Target = [double]$tp; $snap.Kind = "oco" }
    }
    return $snap
}

function New-AggrProtectionPayload([string]$sym, [string]$exitSide, [int]$qty, $snap, [string]$kind, [string]$stamp) {
    $coid = "PROTECT_AGGR_{0}_{1}" -f $sym, $stamp
    $p = [ordered]@{ symbol = $sym; qty = $qty.ToString(); side = $exitSide; time_in_force = "gtc" }
    switch ($kind) {
        "oco" {
            $p.type = "limit"; $p.order_class = "oco"
            $p.take_profit = @{ limit_price = ([double]$snap.Target).ToString("F2") }
            $p.stop_loss   = @{ stop_price  = ([double]$snap.Stop).ToString("F2") }
        }
        "trail" {
            $p.type = "trailing_stop"
            if ($null -ne $snap.TrailPercent -and "$($snap.TrailPercent)" -ne "") { $p.trail_percent = [string]$snap.TrailPercent }
            else { $p.trail_price = [string]$snap.TrailPrice }
        }
        default { $p.type = "stop"; $p.stop_price = ([double]$snap.Stop).ToString("F2") }
    }
    $p.client_order_id = $coid
    return $p
}

# Primary kind twice, then a plain stop twice. Returns @{ Ok; Kind; Fallback; Order; Payload; Attempts; Error }.
function Set-AggrProtection($cfg, [string]$sym, [string]$exitSide, [int]$qty, $snap, [string]$stamp) {
    $plan = @()
    if ($snap.Kind -eq "oco" -or $snap.Kind -eq "trail") { $plan += $snap.Kind, $snap.Kind }
    if ([double]$snap.Stop -gt 0) { $plan += "stop", "stop" }
    $n = 0; $err = $null
    foreach ($k in $plan) {
        $n++
        $p = New-AggrProtectionPayload $sym $exitSide $qty $snap $k ("{0}{1}" -f $stamp, $n)
        $res = $null
        try { $res = Invoke-AggrApi $cfg "POST" "/v2/orders" ([hashtable]$p) } catch { $err = $_.Exception.Message }
        if ($res) { return [pscustomobject]@{ Ok = $true; Kind = $k; Fallback = ($k -ne $snap.Kind); Order = $res; Payload = $p; Attempts = $n; Error = $err } }
    }
    return [pscustomobject]@{ Ok = $false; Kind = $null; Fallback = $false; Order = $null; Payload = $null; Attempts = $n; Error = $err }
}

function Wait-AggrExitOrdersGone($cfg, [string]$sym, [string]$exitSide) {
    $left = @()
    for ($i = 0; $i -lt $script:AggrPollTries; $i++) {
        $left = @(Get-AggrExitOrders $cfg $sym $exitSide)
        if ($left.Count -eq 0) { return [pscustomobject]@{ Gone = $true; Left = @() } }
        if ($script:AggrPollDelayMs -gt 0) { Start-Sleep -Milliseconds $script:AggrPollDelayMs }
    }
    return [pscustomobject]@{ Gone = $false; Left = $left }
}

function Remove-AggrOrders($cfg, [array]$orders) {
    $errs = @()
    foreach ($o in @($orders)) {
        if ($null -eq $o) { continue }
        # Cancelling one leg cancels its group, so a later DELETE in the same group may 422 -- tolerated.
        try { Invoke-AggrApi $cfg "DELETE" ("/v2/orders/" + $o.id) | Out-Null } catch { $errs += ("{0}: {1}" -f $o.id, $_.Exception.Message) }
    }
    return $errs
}

# Poll an order to a final status; if it is still working after the polls,
# cancel the rest and read the final filled_qty.
function Wait-AggrOrderFinal($cfg, [string]$id) {
    $final = @("filled","canceled","cancelled","expired","rejected","done_for_day")
    $o = $null
    for ($i = 0; $i -lt $script:AggrPollTries; $i++) {
        try { $o = Invoke-AggrApi $cfg "GET" ("/v2/orders/" + $id) } catch { $o = $null }
        if ($o -and $final -contains [string]$o.status) { return $o }
        if ($script:AggrPollDelayMs -gt 0) { Start-Sleep -Milliseconds $script:AggrPollDelayMs }
    }
    try { Invoke-AggrApi $cfg "DELETE" ("/v2/orders/" + $id) | Out-Null } catch {}
    for ($i = 0; $i -lt $script:AggrPollTries; $i++) {
        try { $o = Invoke-AggrApi $cfg "GET" ("/v2/orders/" + $id) } catch {}
        if ($o -and $final -contains [string]$o.status) { return $o }
        if ($script:AggrPollDelayMs -gt 0) { Start-Sleep -Milliseconds $script:AggrPollDelayMs }
    }
    return $o
}

# Cancel whatever protects the position and re-place it on $qty shares.
function Invoke-AggrResizeProtection($cfg, [string]$sym, [string]$exitSide, [int]$qty, $snap, [string]$stamp) {
    $errs = Remove-AggrOrders $cfg @(Get-AggrExitOrders $cfg $sym $exitSide)
    $w = Wait-AggrExitOrdersGone $cfg $sym $exitSide
    if (-not $w.Gone) { return [pscustomobject]@{ Ok = $false; Stage = "CANCEL"; Errors = $errs; Protect = $null } }
    $pr = Set-AggrProtection $cfg $sym $exitSide $qty $snap $stamp
    return [pscustomobject]@{ Ok = [bool]$pr.Ok; Stage = $(if ($pr.Ok) { "DONE" } else { "PROTECT" }); Errors = $errs; Protect = $pr }
}

function Add-AggrProtectRestore($state, [string]$sym, $snap) {
    $state.aggr_protect_restore = @(@($state.aggr_protect_restore) | Where-Object { $_ -and $_.sym -ne $sym }) +
        [pscustomobject]@{ sym = $sym; kind = $snap.Kind; stop = $snap.Stop; target = $snap.Target
                           trail_percent = $snap.TrailPercent; trail_price = $snap.TrailPrice; at = (Get-Date).ToUniversalTime().ToString("o") }
}

# Start of every live manage pass: any symbol a partial left short of full
# stop coverage (cancel stuck in pending_cancel, failed re-place) is re-covered
# on its whole position before anything else happens.
function Invoke-AggrProtectRestore($cfg, $state, $myPositions) {
    if ((Test-AggrDryRun $cfg) -or @($state.aggr_protect_restore).Count -eq 0) { return }
    $keep = @()
    foreach ($e in @($state.aggr_protect_restore)) {
        if ($null -eq $e) { continue }
        $pos = @($myPositions) | Where-Object { $_ -and $_.symbol -eq $e.sym } | Select-Object -First 1
        if ($null -eq $pos) { continue }   # position closed: nothing to protect
        $qty = [int][Math]::Abs([double]$pos.qty)
        $exitSide = if ($pos.side -eq "long") { "sell" } else { "buy" }
        $live = @(Get-AggrExitOrders $cfg $e.sym $exitSide)
        $covered = 0
        foreach ($o in $live) { if ($o.status -ne "pending_cancel" -and $script:AggrStopTypes -contains (Get-AggrOrderType $o)) { $covered += [int][Math]::Abs([double]$o.qty) } }
        if ($covered -ge $qty) { Write-AggrSkip @{ sym = $e.sym; event = "PROTECT_RESTORE"; skip_reason = "PROTECT_RESTORE_COVERED"; qty = $qty }; continue }
        $snap = [pscustomobject]@{ Kind = [string]$e.kind; Stop = [double]$e.stop; Target = [double]$e.target; TrailPercent = $e.trail_percent; TrailPrice = $e.trail_price }
        $rz = Invoke-AggrResizeProtection $cfg $e.sym $exitSide $qty $snap ("R" + (Get-Date).ToUniversalTime().ToString("HHmmss"))
        if ($rz.Ok) { Write-AggrSkip @{ sym = $e.sym; event = "PROTECT_RESTORE"; skip_reason = "PROTECT_RESTORED"; qty = $qty; kind = $rz.Protect.Kind; payload = $rz.Protect.Payload } }
        else {
            $keep += $e
            Write-Host ("  [AGGR][ALERT] {0} still NOT fully protected ({1} of {2} shares covered) -- restore failed at {3}" -f $e.sym, $covered, $qty, $rz.Stage) -ForegroundColor Red
            Write-AggrSkip @{ sym = $e.sym; event = "PROTECT_RESTORE"; skip_reason = "PROTECT_RESTORE_FAILED"; qty = $qty; covered = $covered; stage = $rz.Stage }
        }
    }
    $state.aggr_protect_restore = $keep
}

function Invoke-AggrStockPartial($cfg, $state, $pos, [int]$pq, [double]$rMult) {
    $dry = Test-AggrDryRun $cfg
    $sym = [string]$pos.symbol; $qty = [int][Math]::Abs([double]$pos.qty); $keep = $qty - $pq
    $exitSide = if ($pos.side -eq "long") { "sell" } else { "buy" }
    $day = (Get-EasternTime).ToString("yyyyMMdd"); $dayKey = "{0}:{1}" -f $day, $sym
    $stamp = (Get-Date).ToUniversalTime().ToString("HHmmss")
    $base = @{ sym = $sym; event = "PARTIAL"; r_mult = [Math]::Round($rMult, 2); qty = $qty; sell_qty = $pq; keep_qty = $keep }
    $log = {
        param([string]$reason, [hashtable]$extra = @{})
        $r = @{}; foreach ($k in $base.Keys) { $r[$k] = $base[$k] }; foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] }
        $r.skip_reason = $reason; Write-AggrSkip $r
    }
    $result = { param([string]$o, $extra = @{}) $r = [ordered]@{ Outcome = $o; Sym = $sym }; foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] }; [pscustomobject]$r }

    if (@($state.aggr_partial_failed) -contains $dayKey) { return (& $result "SKIPPED_FAILED_TODAY") }
    if ($pq -lt 1 -or $keep -lt 1) { return (& $result "SKIPPED_QTY") }
    if (-not $dry -and -not (Test-MarketOpen $cfg)) { & $log "PARTIAL_DEFERRED" @{ note = "market closed: a queued market sell would leave shares unprotected overnight" }; return (& $result "DEFERRED") }

    $orders = @(Get-AggrExitOrders $cfg $sym $exitSide)
    $snap = Get-AggrProtectionSnapshot $orders ([string]$pos.side) ([double]$pos.current_price)
    $px = [double]$pos.current_price
    $stopBad = if ($snap.Kind -eq "trail") { $false } elseif ($pos.side -eq "long") { $snap.Stop -le 0 -or $snap.Stop -ge $px } else { $snap.Stop -le 0 -or $snap.Stop -le $px }
    $sellCoid = "PARTIAL_{0}_{1}" -f $sym, $day
    $sellPayload = [ordered]@{ symbol = $sym; qty = $pq.ToString(); side = $exitSide; type = "market"; time_in_force = "day"; client_order_id = $sellCoid }
    if ($orders.Count -eq 0 -or $snap.Kind -eq "none" -or $stopBad) {
        $why = if ($orders.Count -eq 0) { "no live exit orders (position already unprotected; legacy protective fallback owns it)" } else { "no usable stop on the live exit orders" }
        & $log $(if ($dry) { "DRYRUN_PARTIAL" } else { "PARTIAL_ABORTED_NO_STOP" }) @{ step = "ABORT"; note = $why; stop = $snap.Stop; price = $px }
        return (& $result "ABORTED_NO_STOP")
    }

    $protectPayload  = New-AggrProtectionPayload $sym $exitSide $keep $snap $snap.Kind ($stamp + "1")
    $fallbackPayload = if ($snap.Stop -gt 0) { New-AggrProtectionPayload $sym $exitSide $keep $snap "stop" ($stamp + "3") } else { $null }

    if ($dry) {
        $ids = @($orders | ForEach-Object { [ordered]@{ id = $_.id; type = (Get-AggrOrderType $_); stop_price = $_.stop_price; limit_price = $_.limit_price; qty = $_.qty } })
        & $log "DRYRUN_PARTIAL" @{ step = "CANCEL_EXITS"; seq = 1; orders = $ids; note = "DELETE each, then poll until none live" }
        & $log "DRYRUN_PARTIAL" @{ step = "PROTECT"; seq = 2; payload = $protectPayload; fallback_payload = $fallbackPayload; note = "protection for the kept shares BEFORE the sell; 1 retry, then plain-stop fallback" }
        & $log "DRYRUN_PARTIAL" @{ step = "SELL"; seq = 3; payload = $sellPayload }
        & $log "DRYRUN_PARTIAL" @{ step = "VERIFY"; seq = 4; note = "poll the sell; if rejected or partly filled, cancel protection and re-place it on the actual position qty; market hours only" }
        return (& $result "DRYRUN" @{ Protect = $protectPayload; Sell = $sellPayload })
    }

    # 1. Free the shares.
    $cancelErrs = Remove-AggrOrders $cfg $orders
    $w = Wait-AggrExitOrdersGone $cfg $sym $exitSide
    if (-not $w.Gone) {
        $pending = @($w.Left | Where-Object { $_.status -eq "pending_cancel" })
        if ($pending.Count -gt 0) { Add-AggrProtectRestore $state $sym $snap }   # will finish cancelling: re-cover next scan
        $state.aggr_partial_failed = @($state.aggr_partial_failed) + $dayKey
        Write-Host ("  [AGGR][ALERT] {0} partial aborted: exit orders did not cancel ({1})" -f $sym, (($w.Left | ForEach-Object { "$($_.id)=$($_.status)" }) -join ", ")) -ForegroundColor Red
        & $log "PARTIAL_ABORTED_CANCEL" @{ left = @($w.Left | ForEach-Object { "$($_.id)=$($_.status)" }); errors = $cancelErrs; restore_queued = ($pending.Count -gt 0) }
        return (& $result "ABORTED_CANCEL" @{ Errors = $cancelErrs })
    }

    # 2. Protect the shares we keep, before selling anything.
    $prot = Set-AggrProtection $cfg $sym $exitSide $keep $snap $stamp
    if (-not $prot.Ok) {
        $state.aggr_partial_failed = @($state.aggr_partial_failed) + $dayKey
        $full = Set-AggrProtection $cfg $sym $exitSide $qty $snap ($stamp + "F")
        if (-not $full.Ok) {
            Add-AggrProtectRestore $state $sym $snap
            Write-Host ("  [AGGR][ALERT] {0} UNPROTECTED: {1} shares have no stop -- protection re-place failed ({2})" -f $sym, $qty, $prot.Error) -ForegroundColor Red
            & $log "PARTIAL_UNPROTECTED" @{ error = $prot.Error; restore_queued = $true }
            return (& $result "UNPROTECTED")
        }
        & $log "PARTIAL_ABORTED_PROTECT" @{ error = $prot.Error; restored_kind = $full.Kind; restored_qty = $qty }
        return (& $result "ABORTED_PROTECT")
    }
    if ($prot.Fallback) {
        Write-Host ("  [AGGR][ALERT] {0} {1} re-place failed -- FELL BACK to a plain stop @ {2:F2} on {3} shares" -f $sym, $snap.Kind, $snap.Stop, $keep) -ForegroundColor Red
        & $log "PARTIAL_PROTECT_FALLBACK" @{ wanted = $snap.Kind; payload = $prot.Payload; error = $prot.Error }
    }

    # 3. Sell 1/3. The client_order_id is fixed per symbol per day, so a retry can never double-sell.
    $sell = $null; $sellErr = $null
    try { $sell = Invoke-AggrApi $cfg "POST" "/v2/orders" ([hashtable]$sellPayload) } catch { $sellErr = $_.Exception.Message }
    if ($null -eq $sell -or -not $sell.id) {
        try { $sell = Invoke-AggrApi $cfg "GET" ("/v2/orders:by_client_order_id?client_order_id=" + $sellCoid) } catch { $sell = $null }
    }
    $filled = 0; $final = $null
    if ($sell -and $sell.id) {
        $state.aggr_partial_done = @($state.aggr_partial_done) + $sym
        $final = Wait-AggrOrderFinal $cfg ([string]$sell.id)
        if ($final -and $final.filled_qty) { $filled = [int][Math]::Floor([double]$final.filled_qty) }
    } else {
        $state.aggr_partial_failed = @($state.aggr_partial_failed) + $dayKey
    }

    # 4. Anything not sold is not covered yet: resize protection to the real position.
    $leftover = $pq - $filled
    $resize = $null
    if ($leftover -gt 0) {
        $posNow = $null
        try { $posNow = Invoke-AggrApi $cfg "GET" ("/v2/positions/" + $sym) } catch {}
        $posQty = if ($posNow -and $posNow.qty) { [int][Math]::Abs([double]$posNow.qty) } else { $keep + $leftover }
        $resize = Invoke-AggrResizeProtection $cfg $sym $exitSide $posQty $snap ($stamp + "Z")
        if (-not $resize.Ok) {
            Add-AggrProtectRestore $state $sym $snap
            Write-Host ("  [AGGR][ALERT] {0} {1} unsold shares may be UNPROTECTED -- resize failed at {2}; restore queued" -f $sym, $leftover, $resize.Stage) -ForegroundColor Red
        }
        & $log $(if ($resize.Ok) { "PARTIAL_PROTECT_RESIZED" } else { "PARTIAL_RESIZE_FAILED" }) @{ position_qty = $posQty; sold = $filled; stage = $resize.Stage }
    }

    $outcome = if (-not ($sell -and $sell.id)) { "SELL_REJECTED" } elseif ($leftover -gt 0) { "PARTIAL_FILL" } else { "DONE" }
    & $log $(if ($outcome -eq "SELL_REJECTED") { "PARTIAL_SELL_REJECTED" } else { "PARTIAL_DONE" }) @{
        sold = $filled; protect_kind = $prot.Kind; protect_fallback = $prot.Fallback; sell_status = $(if ($final) { $final.status } else { $null }); error = $sellErr; payload = $sellPayload }
    return (& $result $outcome @{ Sold = $filled; Protect = $prot; Resize = $resize; Error = $sellErr })
}

# ── Position management: AI migration + partials + call exits ────────────────

function Get-AggrJournalOpen([string]$sym) {
    try { $j = Load-Journal } catch { return $null }
    return @($j.open) | Where-Object { $_.symbol -eq $sym } | Sort-Object opened_at -Descending | Select-Object -First 1
}

function Invoke-AggrManage($cfg, $state, $myPositions, $allPositions) {
    $a = Get-AggrCfg $cfg; $dry = Test-AggrDryRun $cfg
    Invoke-AggrProtectRestore $cfg $state $myPositions
    foreach ($pos in @($myPositions)) {
        if ($null -eq $pos -or $pos.asset_class -eq "us_option") { continue }
        $sym = $pos.symbol; $qty = [int][Math]::Abs([double]$pos.qty)
        $jr  = Get-AggrJournalOpen $sym
        $entry = [double]$pos.avg_entry_price
        $origStop = if ($jr -and $jr.stop) { [double]$jr.stop } else { 0 }
        $r = if ($origStop -gt 0) { [Math]::Abs($entry - $origStop) } else { 0 }
        $px = [double]$pos.current_price
        $rMult = if ($r -gt 0) { if ($pos.side -eq "long") { ($px - $entry) / $r } else { ($entry - $px) / $r } } else { 0 }

        # (1) Migration: legacy bracket (3.5R TP) -> new rules (TP leg pushed to dummy 10R).
        if (@($state.aggr_migrated) -notcontains $sym -and $r -gt 0) {
            $legs = Get-LiveExitLegs $cfg $pos
            $newTp = if ($pos.side -eq "long") { [Math]::Round($entry + [double]$a.dummy_tp_r * $r, 2) } else { [Math]::Round([Math]::Max(0.01, $entry - [double]$a.dummy_tp_r * $r), 2) }
            $rec = @{ sym = $sym; event = "MIGRATE"; current_tp = $legs.target; current_stop = $legs.stop; new_tp = $newTp; r_per_share = [Math]::Round($r, 4); qty = $qty }
            if ($dry) {
                $rec.skip_reason = "DRYRUN_MIGRATE"; $rec.note = "dry run: no order modified; legacy ladder keeps managing live"
                # Not marked migrated in dry run; logged once per symbol per ET day.
                $key = (Get-EasternTime).ToString("yyyy-MM-dd") + ":" + $sym
                if (@($state.aggr_migrate_logged) -notcontains $key) {
                    Write-AggrSkip $rec
                    $state.aggr_migrate_logged = @(@($state.aggr_migrate_logged) | Where-Object { $_ -like ((Get-EasternTime).ToString("yyyy-MM-dd") + ":*") }) + $key
                }
            } else {
                $tpLeg = $null
                $raw = Invoke-AggrApi $cfg "GET" "/v2/orders?status=all&nested=true&symbols=$sym&limit=200"
                foreach ($o in @($raw)) { foreach ($l in @($o.legs)) { if ($l -and $l.status -notin @("filled","canceled","expired","replaced") -and ($l.order_type -eq "limit" -or $l.type -eq "limit")) { $tpLeg = $l } } }
                if ($tpLeg) { Invoke-AggrApi $cfg "PATCH" ("/v2/orders/" + $tpLeg.id) @{ limit_price = $newTp.ToString("F2") } | Out-Null }
                $state.aggr_migrated = @($state.aggr_migrated) + $sym
                $rec.skip_reason = "MIGRATED"; Write-AggrSkip $rec
            }
        }

        # (2) One-time 1/3 partial at +2R (stocks): cancel exits -> protect the
        # remaining 2/3 -> sell 1/3. See Invoke-AggrStockPartial.
        $pq = Get-AggrStockPartialQty $rMult $qty (@($state.aggr_partial_done) -contains $sym) $a
        if ($pq -gt 0) { $null = Invoke-AggrStockPartial $cfg $state $pos $pq $rMult }
    }
    # clean partial/migrated flags for symbols no longer held
    $held = @($myPositions | ForEach-Object { $_.symbol })
    $state.aggr_partial_done = @(@($state.aggr_partial_done) | Where-Object { $held -contains $_ })
    $state.aggr_migrated     = @(@($state.aggr_migrated) | Where-Object { $held -contains $_ })

    # (3) Call exits (only positions opened by this module, tracked in state.aggr_calls)
    foreach ($c in @($state.aggr_calls)) {
        if ($null -eq $c) { continue }
        $p = @($allPositions) | Where-Object { $_.symbol -eq $c.occ } | Select-Object -First 1
        if ($null -eq $p) { continue }
        $bars = Get-DailyBars $cfg $c.underlying
        $last = if ($bars) { [double]($bars | Select-Object -Last 1).Close } else { 0 }
        $since = @($bars | Where-Object { $_.Time -ge [datetime]$c.opened_at })
        $hi = if ($since.Count) { ($since | Measure-Object Close -Maximum).Maximum } else { $last }
        $atr = if ($bars -and $bars.Count -ge 15) { Get-ATR $bars 14 } else { 0 }
        $exp = [datetime]::ParseExact($c.expiration, "yyyy-MM-dd", $null)
        $earn = Test-AggrEarningsBefore $c.underlying ((Get-Date).Date.AddDays(1))
        $x = @{ UnderPx = $last; StockStop = [double]$c.stock_stop; UnderEntry = [double]$c.under_entry; R = [double]$c.r
                EntryPremium = [double]$c.entry_premium; Bid = [double]$p.current_price; Dte = [int]($exp - (Get-Date).Date).TotalDays
                DaysHeld = (Get-WeekdayCount ([datetime]$c.opened_at) (Get-Date)); EarningsBeforeNextSession = [bool]$earn
                PartialDone = [bool]$c.partial_done; LastClose = $last; HighestClose = $hi; Atr = $atr; Contracts = [int][Math]::Abs([double]$p.qty) }
        $d = Get-AggrCallExitDecision $x $a
        if ($d.Action -eq "HOLD") { continue }
        $q = Invoke-AlpacaData $cfg ("/v1beta1/options/snapshots?symbols={0}&feed={1}" -f $c.occ, $a.options_feed)
        $qq = if ($q -and $q.snapshots) { $q.snapshots.($c.occ).latestQuote } else { $null }
        $attempt = if ($null -ne $c.exit_attempt) { [int]$c.exit_attempt } else { 0 }
        $lim = if ($qq) { Get-AggrCallExitLimit ([double]$qq.bp) ([double]$qq.ap) $attempt } else { $null }
        if ($null -ne $lim) { $payload = New-AggrCallOrderPayload $c.occ $d.Qty $lim $c.underlying "SWCALLX" "sell" }
        else { $payload = [ordered]@{ symbol = $c.occ; qty = $d.Qty.ToString(); side = "sell"; type = "market"; time_in_force = "day"; client_order_id = ("SWCALLX_{0}_{1}" -f $c.underlying, (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmm")) } }
        if ($dry) { Write-AggrSkip @{ sym = $c.underlying; event = "CALL_EXIT"; skip_reason = "DRYRUN_CALL_EXIT"; reason = $d.Reason; payload = $payload; quote_caveat = $script:AggrQuoteCaveat } }
        else {
            # Cancel our previous unfilled exit for this contract, then re-price (attempt+1).
            $open = Invoke-AggrApi $cfg "GET" ("/v2/orders?status=open&symbols={0}" -f $c.occ)
            foreach ($o in @($open)) { if ($o -and $o.client_order_id -like "SWCALLX_*") { Invoke-AggrApi $cfg "DELETE" ("/v2/orders/" + $o.id) | Out-Null } }
            $res = Invoke-AggrApi $cfg "POST" "/v2/orders" ([hashtable]$payload)
            $c | Add-Member -NotePropertyName exit_attempt -NotePropertyValue ($attempt + 1) -Force
            if ($res -and $d.Action -eq "SELL_PARTIAL") { $c.partial_done = $true; $c.exit_attempt = 0 }
            Write-AggrSkip @{ sym = $c.underlying; event = "CALL_EXIT"; skip_reason = "CALL_EXIT_SENT"; reason = $d.Reason; payload = $payload } }
    }
}

# ── Entry evaluation (shadow in dry run) ─────────────────────────────────────

# Breakout extension (logged; gated by Test-AggrExtensionGate since v1.2): same basis as Get-SwingBreakoutSignal
# -- 20-day high and ATR(14) from COMPLETED prior days, price = current bar close.
# Returns nulls instead of throwing, so it can never change an entry decision.
function Get-AggrExtension($bars) {
    $out = [ordered]@{ extension_atr = $null; pct_above_20d_high = $null }
    try {
        if ($null -eq $bars -or @($bars).Count -lt 21) { return $out }
        $split = Split-DailyBars $bars
        $hist  = @($split.History)
        if ($hist.Count -lt 20) { return $out }
        $high20 = (@($hist | Select-Object -Last 20) | Measure-Object -Property High -Maximum).Maximum
        $atr    = Get-ATR $hist 14
        $price  = [double]$split.Current.Close
        if ($atr -gt 0)    { $out.extension_atr      = [Math]::Round(($price - $high20) / $atr, 2) }
        if ($high20 -gt 0) { $out.pct_above_20d_high = [Math]::Round(($price - $high20) / $high20 * 100.0, 2) }
    } catch {}
    return $out
}
function Add-AggrExtension([hashtable]$rec, $bars) {
    if ($rec.ContainsKey('extension_atr')) { return }
    $x = Get-AggrExtension $bars
    $rec.extension_atr = $x.extension_atr; $rec.pct_above_20d_high = $x.pct_above_20d_high
}

# A gate that fails AFTER the signal was re-priced from the live quote is
# reported as STALE_SIGNAL (the original gate kept in rec.gate).
function Get-AggrGateSkip($live, [string]$gate, [hashtable]$rec) {
    if ($null -ne $live -and $live.Action -eq "REPRICED") { $rec.gate = $gate; return "STALE_SIGNAL" }
    return $gate
}

# Slots + heat source. Dry run: shadow book only, shadow stocks booked as stock
# risk (qty x |entry - stop|), shadow calls at their premium (risk_usd).
# Live: the live book only (the shadow book is empty when dry_run=false).
function Get-AggrSlotBook($cfg, $state, $myPositions, [bool]$dry) {
    $items = @(); $sc = 0; $cc = 0
    if ($dry) {
        foreach ($s in @($state.aggr_shadow_open)) {
            if ($null -eq $s) { continue }
            if ($s.kind -eq 'call') { $cc++; $items += @{ Kind = 'call'; MarketValue = [double]$s.risk_usd }; continue }
            $sc++
            $side = if ($s.side -eq 'sell') { 'short' } else { 'long' }
            $items += @{ Kind = 'stock'; Side = $side; Qty = [double]$s.qty; Entry = [double]$s.entry; Stop = [double]$s.stop }
        }
    } else {
        foreach ($p in @($myPositions)) {
            if ($null -eq $p) { continue }
            if ($p.asset_class -eq "us_option") { $cc++; $items += @{ Kind = 'call'; MarketValue = [double]$p.market_value }; continue }
            $sc++
            $legs = Get-LiveExitLegs $cfg $p
            $items += @{ Kind = 'stock'; Side = $p.side; Qty = [double]$p.qty; Entry = [double]$p.avg_entry_price; Stop = [double]$legs.stop }
        }
    }
    return [pscustomobject]@{ StockCount = $sc; CallCount = $cc; HeatItems = $items }
}

# Extension gate (v1.2): BRKOUT more than max_extension_atr ATR above the prior
# 20-day high is skipped as EXTENSION. 0/absent = off. Unknown extension = pass.
function Test-AggrExtensionGate($ext, $a) {
    if ($null -eq $a.max_extension_atr -or [double]$a.max_extension_atr -le 0) { return $true }
    if ($null -eq $ext) { return $true }
    return ([double]$ext -le [double]$a.max_extension_atr)
}

function Invoke-AggrEntries($cfg, $state, $regime, $spyDaily, [double]$equity, [double]$bp, $myPositions, $allPositions, $workingOrderSyms) {
    $a = Get-AggrCfg $cfg; $dry = Test-AggrDryRun $cfg
    $etToday = (Get-EasternTime).ToString("yyyy-MM-dd")
    if ($state.aggr_day -ne $etToday) { $state.aggr_day = $etToday; $state.aggr_trades_today = 0 }

    $dd = Get-AggrDdState $equity $a ([bool]$state.aggr_halted)
    if ($dd.Halted -and -not $state.aggr_halted) { $state.aggr_halted = $true; Write-Host "  [AGGR][HALT] equity <= floor -- no new aggressive entries until manual reset" -ForegroundColor Red }

    # Heat from live book (+ simulated dry-run entries today)
    $heatItems = @()
    $stockCount = 0; $callCount = 0
    # FIX v1.2: in dry run, slots and heat come from the SHADOW book only. The
    # shadow book already mirrors every name the engine would hold (including
    # copies of legacy-held PFE/NKE), so also counting the live book counted
    # those names twice and blocked ABBV/HD/V/PLTR with STOCK_SLOTS_FULL.
    $book = Get-AggrSlotBook $cfg $state $myPositions $dry
    $stockCount = $book.StockCount; $callCount = $book.CallCount
    $heat = Get-AggrHeat $book.HeatItems

    $opusSyms = Get-AggrOpusUnderlyings $allPositions
    $watch = if (@($state.aggr_watchlist).Count -gt 0) { @($state.aggr_watchlist) } else { @($state.active_watchlist) }
    $confFloor = if ($regime.Regime -eq "BULL") { [int]$a.conf_floor_bull } else { [int]$a.conf_floor_neutral }
    $entered = $false
    $allSyms = @{}; foreach ($p in @($allPositions)) { if ($p) { $allSyms[$p.symbol] = $true } }
    $dryEnteredSyms = @(@($state.aggr_shadow_open) | ForEach-Object { $_.sym })

    foreach ($sym in $watch) {
        $rec = @{ sym = $sym; regime = $regime.Regime; dd_pct = $dd.DdPct; dd_tier = $dd.Tier; heat_before = $heat; dry_run = $dry }
        $skip = $null
        if ($dd.Halted)                                  { $skip = "HALT" }
        elseif ($INDEX_ANCHORS -contains $sym)           { $skip = "INDEX_ANCHOR" }
        elseif ($LEVERAGED_BLOCKLIST -contains $sym)     { $skip = "LEVERAGED" }
        elseif ($opusSyms.ContainsKey($sym))             { $skip = "OPUS_CONFLICT" }
        elseif ($allSyms.ContainsKey($sym) -or $workingOrderSyms.ContainsKey($sym) -or $dryEnteredSyms -contains $sym) { $skip = "HELD_OR_WORKING" }
        elseif ($entered)                                { $skip = "ONE_PER_SCAN" }
        elseif ([int]$state.aggr_trades_today -ge [int]$a.max_trades_per_day) { $skip = "TRADES_PER_DAY" }
        elseif ([int]$state.losses -ge [int]$a.max_losses_per_day) { $skip = "DAILY_LOSS_CAP" }
        elseif ([double]$state.equity_at_open -gt 0 -and ((($equity - [double]$state.equity_at_open) / [double]$state.equity_at_open) * 100.0) -le [double]$a.max_daily_drawdown_pct) { $skip = "DAILY_DD" }
        elseif (($stockCount + $callCount) -ge [Math]::Min([int]$a.max_positions, $dd.MaxPositions)) { $skip = "MAX_POS" }
        if ($null -eq $skip) {
            $mem = Get-TickerMemoryInfo $sym
            if ($mem -and [int]$mem.trades -ge 5 -and [double]$mem.score -le 0.3) { $skip = "MEMORY" }
            elseif ($mem -and [int]$mem.consecutive_losses -ge 1 -and $mem.last_trade -and (Get-WeekdayCount ([datetime]::Parse($mem.last_trade).ToUniversalTime()) ([datetime]::UtcNow)) -lt 5) { $skip = "COOLDOWN" }
            elseif ($cfg.earnings_enabled -and (Test-EarningsBlackout $sym ([int]$cfg.earnings_blackout_days))) { $skip = "EARNINGS" }
        }
        $sig = $null; $bars = $null; $rs = $null
        if ($null -eq $skip) {
            $bars = Get-DailyBars $cfg $sym
            if ($null -eq $bars -or $bars.Count -lt 60) { $skip = "NO_DATA" }
            else {
                $sig = Get-SwingBestSignal $cfg $sym $bars $regime.Regime $spyDaily
                if ($null -eq $sig) { $skip = "NO_SETUP" }
                else {
                    $rs = Get-RelativeStrength $bars $spyDaily 20
                    $rec.setup = $sig.Strategy; $rec.conf = $sig.Confidence; $rec.rs = [Math]::Round([double]$rs, 2)
                    if ($sig.Strategy -eq "BRKOUT") { Add-AggrExtension $rec $bars }   # every BRKOUT line from here on
                    if ([int]$sig.Confidence -lt $confFloor) { $skip = "CONF_FLOOR" }
                    elseif ($sig.Strategy -eq "BRKOUT" -and -not (Test-AggrExtensionGate $rec.extension_atr $a)) { $skip = "EXTENSION" }
                }
            }
        }
        if ($null -ne $skip) { $rec.skip_reason = $skip; Write-AggrSkip $rec; continue }

        # Stale-signal guard (same as legacy): re-price from the live quote (GET only).
        $live = Update-SignalForLivePrice $cfg $sym $bars $regime.Regime $spyDaily $sig
        $rec.live_check = $live.Action; $rec.live_mid = $live.Mid; $rec.drift_pct = $live.DriftPct
        $rec.quote_spread_pct = $live.SpreadPct; $rec.quote_age_sec = $live.AgeSec
        if ($live.Action -eq "STALE_SIGNAL") { $rec.skip_reason = "STALE_SIGNAL"; $rec.stale_reason = $live.Reason; Write-AggrSkip $rec; continue }
        if ($live.Action -eq "REPRICED") {
            $rec.signal_entry = $sig.Entry; $sig = $live.Signal
            $rec.conf = $sig.Confidence
            if ([int]$sig.Confidence -lt $confFloor) {
                $rec.skip_reason = "STALE_SIGNAL"; $rec.stale_reason = "repriced conf {0} < floor {1}" -f $sig.Confidence, $confFloor
                Write-AggrSkip $rec; continue
            }
        }

        # Instrument
        $edge = 1.0
        if ($cfg.adaptive_sizing) { try { $edge = (Get-StrategyEdge $sig.Strategy ([string]$regime.Regime)).Mult } catch {} }
        $instrument = "stock"; $callReason = Test-AggrCallEligible $sig $regime.Regime ([double]$rs) $a $dd $callCount
        $pick = $null; $callSize = $null; $limit = 0
        if ($null -eq $callReason) {
            $chain = Get-AggrCallChain $cfg $sym $a
            $pick = Select-AggrCallContract $chain $a
            if ($null -eq $pick) { $callReason = "NO_LIQUID_CALL" }
            else {
                $earn = Test-AggrEarningsBefore $sym ([datetime]::ParseExact($pick.Expiration, "yyyy-MM-dd", $null))
                if ($null -eq $earn -or $earn) { $callReason = "EARNINGS_BEFORE_EXPIRY_OR_UNKNOWN" }
                else {
                    $limit = Get-AggrCallLimit $pick.Bid $pick.Ask 0
                    $callSize = Get-AggrCallSize $equity $limit $a $dd.Mult
                    if ($callSize.Contracts -lt 1) { $callReason = "CALL_TOO_EXPENSIVE" } else { $instrument = "call" }
                }
            }
        }
        $rec.instrument = $instrument; if ($callReason) { $rec.call_skip = $callReason }

        if ($instrument -eq "call") {
            $risk = $callSize.PremiumUsd
            if (-not (Test-AggrHeatOk $heat $risk $equity $a)) { $rec.skip_reason = (Get-AggrGateSkip $live "HEAT" $rec); Write-AggrSkip $rec; continue }
            $payload = New-AggrCallOrderPayload $pick.Occ $callSize.Contracts $limit $sym ([string]$a.call_entry_prefix)
            $rec.call_contract = @{ occ = $pick.Occ; dte = $pick.Dte; delta = $pick.Delta; bid = $pick.Bid; ask = $pick.Ask; oi = $pick.Oi; volume = $pick.Volume }
            $rec.quote_caveat = $script:AggrQuoteCaveat; $rec.feed = $a.options_feed
        } else {
            if ($stockCount -ge [int]$a.max_stock_positions) { $rec.skip_reason = "STOCK_SLOTS_FULL"; Write-AggrSkip $rec; continue }
            $sz = Get-AggrStockSize -equity $equity -buyingPower $bp -entry $sig.Entry -stop $sig.Stop -a $a -edgeMult $edge -regimeMult ([double]$regime.SizeMult) -ddMult $dd.Mult
            if ($sz.Shares -lt 1) { $rec.skip_reason = (Get-AggrGateSkip $live "SIZE_ZERO" $rec); Write-AggrSkip $rec; continue }
            $risk = $sz.RiskUsd
            if (-not (Test-AggrHeatOk $heat $risk $equity $a)) { $rec.skip_reason = (Get-AggrGateSkip $live "HEAT" $rec); $rec.risk_usd = $risk; Write-AggrSkip $rec; continue }
            $payload = New-AggrStockOrderPayload $sym $sig.Side $sz.Shares $sig.Entry $sig.Stop ([double]$a.dummy_tp_r) $sig.Strategy
            $rec.riskPct = $sz.RiskPct
        }
        $rec.risk_usd = $risk; $rec.heat_after = [Math]::Round($heat + $risk, 2); $rec.payload = $payload
        if ($dry) {
            $rec.skip_reason = "DRYRUN_ENTERED"
            Add-AggrExtension $rec $bars   # every dry-run entry, whatever the setup
            $tpSh = if ($payload.take_profit) { [double]$payload.take_profit.limit_price } else { $null }
            $state.aggr_shadow_open = @($state.aggr_shadow_open) + (New-AggrShadow $sym $instrument $sig.Side ([double]$sig.Entry) ([double]$sig.Stop) $tpSh ([int]$payload.qty) $risk ((Get-Date).ToUniversalTime().ToString("o")))
        } else {
            $res = Invoke-AggrApi $cfg "POST" "/v2/orders" ([hashtable]$payload)
            $rec.skip_reason = if ($res) { "ENTERED" } else { "ORDER_FAILED" }
            if ($res) {
                Add-JournalEntry -symbol $sym -strategy $(if ($instrument -eq "call") { [string]$a.call_entry_prefix } else { $sig.Strategy }) -side $sig.Side `
                    -entry $sig.Entry -stop $sig.Stop -qty $(if ($instrument -eq "call") { $callSize.Contracts } else { [int]$payload.qty }) `
                    -riskUsd $risk -confidence $sig.Confidence -regime $regime.Regime -reason $sig.Reason
                if ($instrument -eq "call") {
                    $state.aggr_calls = @($state.aggr_calls) + [pscustomobject]@{ occ = $pick.Occ; underlying = $sym; expiration = $pick.Expiration
                        opened_at = (Get-Date).ToString("o"); under_entry = $sig.Entry; stock_stop = $sig.Stop; r = [Math]::Abs($sig.Entry - $sig.Stop)
                        entry_premium = $limit; partial_done = $false }
                }
            }
        }
        Write-AggrSkip $rec
        $state.aggr_trades_today = [int]$state.aggr_trades_today + 1
        $heat = $heat + $risk; if ($instrument -eq "call") { $callCount++ } else { $stockCount++ }
        $entered = $true
    }
}

# ── Shadow book (dry run): hypothetical positions + exits ────────────────────
# ROOT-CAUSE FIX (2026-10-14, AEHL): shadow entries used to live in
# state.aggr_dry_entered = {sym,kind,risk_usd} with no entry/stop/target and
# NO exit logic -- the only "exit" was the wipe at the next ET day roll. So a
# shadow name stayed "held" (slot + heat + HELD_OR_WORKING) all day after the
# market had already taken out its stop, and multi-day holds vanished at the
# day roll. Now every scan reconciles each open shadow against bars and live
# Alpaca closed orders (GET only) and books a hypothetical exit.

function New-AggrShadow([string]$sym, [string]$kind, [string]$side, [double]$entry, [double]$stop, $tp, [int]$qty, [double]$risk, [string]$openedAt) {
    # entry = the LIMIT until a bar trades through it; then entry = the simulated fill.
    return [pscustomobject]@{ sym = $sym; kind = $kind; side = $side; entry = $entry; stop = $stop
                              tp = $(if ($null -ne $tp) { [double]$tp } else { $null }); qty = $qty; risk_usd = $risk; opened_at = $openedAt
                              limit = $entry; filled = $false; filled_at = $null }
}

# Pure: when does a shadow LIMIT entry fill, and at what price. A resting limit
# only fills on a bar that trades through it; a marketable one fills at the
# market, not at the limit (AEHL: limit 29.00, real fill 26.84). So: the first
# bar strictly after opened_at whose range reaches the limit fills at
# min(limit, bar open) for a long, max(limit, bar open) for a short.
# Returns @{ Price; Time } or $null (still working).
function Get-AggrShadowFill($sh, $bars) {
    $t0 = ConvertTo-UtcTime $sh.opened_at   # zone-safe: unzoned => UTC
    $lim = if ($null -ne $sh.limit) { [double]$sh.limit } else { [double]$sh.entry }
    $long = ($sh.side -ne "sell")
    foreach ($b in @($bars | Where-Object { $_ -and (ConvertTo-UtcTime $_.Time) -gt $t0 } | Sort-Object Time)) {
        if ($long -and [double]$b.Low -le $lim)       { return [pscustomobject]@{ Price = [Math]::Min($lim, [double]$b.Open); Time = $b.Time } }
        if (-not $long -and [double]$b.High -ge $lim) { return [pscustomobject]@{ Price = [Math]::Max($lim, [double]$b.Open); Time = $b.Time } }
    }
    return $null
}

# Pure: live evidence of the entry fill -- a filled ENTRY-side order on the same
# symbol after the shadow opened, at or through the limit (AEHL: the live
# bracket limit 29.00 filled at 26.84). Preferred over the bar model, which can
# miss thin names (IEX bars skip odd-lot prints). Returns @{ Price; Time } or $null.
function Get-AggrShadowLiveFill($sh, $closedOrders) {
    $t0 = ConvertTo-UtcTime $sh.opened_at   # zone-safe: unzoned => UTC
    $lim = if ($null -ne $sh.limit) { [double]$sh.limit } else { [double]$sh.entry }
    $entrySide = if ($sh.side -eq "sell") { "sell" } else { "buy" }
    $fills = @($closedOrders | Where-Object { $_ -and $_.symbol -eq $sh.sym -and $_.status -eq "filled" -and $_.side -eq $entrySide -and $_.filled_at -and
                                               $_.filled_avg_price -and ((ConvertTo-UtcTime $_.filled_at) -gt $t0) } |
               Sort-Object { ConvertTo-UtcTime $_.filled_at })
    foreach ($f in $fills) {
        $px = [double]$f.filled_avg_price
        if ($entrySide -eq "buy" -and $px -le $lim)  { return [pscustomobject]@{ Price = $px; Time = $f.filled_at } }
        if ($entrySide -eq "sell" -and $px -ge $lim) { return [pscustomobject]@{ Price = $px; Time = $f.filled_at } }
    }
    return $null
}

# Pure: first bar strictly after opened_at that hits stop or target. Gap-aware:
# a bar opening through the stop fills at the open. Stop and target in the same
# bar => stop (conservative).
function Get-AggrShadowBarExit($sh, $bars) {
    $t0 = (ConvertTo-UtcTime $sh.opened_at)
    $long = ($sh.side -ne "sell")
    $stop = [double]$sh.stop; $tp = $sh.tp
    foreach ($b in @($bars | Where-Object { $_ -and (ConvertTo-UtcTime $_.Time) -gt $t0 } | Sort-Object Time)) {
        if ($long) {
            if ([double]$b.Low -le $stop) { return [pscustomobject]@{ Reason = "STOP"; Price = [Math]::Min($stop, [double]$b.Open); Time = $b.Time } }
            if ($null -ne $tp -and [double]$b.High -ge [double]$tp) { return [pscustomobject]@{ Reason = "TARGET"; Price = [Math]::Max([double]$tp, [double]$b.Open); Time = $b.Time } }
        } else {
            if ([double]$b.High -ge $stop) { return [pscustomobject]@{ Reason = "STOP"; Price = [Math]::Max($stop, [double]$b.Open); Time = $b.Time } }
            if ($null -ne $tp -and [double]$b.Low -le [double]$tp) { return [pscustomobject]@{ Reason = "TARGET"; Price = [Math]::Min([double]$tp, [double]$b.Open); Time = $b.Time } }
        }
    }
    return $null
}

# Pure: a filled closing order on the live account for the same symbol after the
# shadow opened, at a price at/through the shadow stop, is market evidence the
# stop traded (with real slippage). Returns @{Price;Time;OrderId} or $null.
function Get-AggrShadowLiveExit($sh, $closedOrders) {
    $t0 = (ConvertTo-UtcTime $sh.opened_at)
    $closeSide = if ($sh.side -eq "sell") { "buy" } else { "sell" }
    $fills = @($closedOrders | Where-Object { $_ -and $_.symbol -eq $sh.sym -and $_.status -eq "filled" -and $_.side -eq $closeSide -and $_.filled_at -and
                                               ((ConvertTo-UtcTime $_.filled_at) -gt $t0) } |
               Sort-Object { (ConvertTo-UtcTime $_.filled_at) })
    foreach ($f in $fills) {
        $px = [double]$f.filled_avg_price
        $through = if ($closeSide -eq "sell") { $px -le [double]$sh.stop } else { $px -ge [double]$sh.stop }
        if ($through) { return [pscustomobject]@{ Price = $px; Time = $f.filled_at; OrderId = $f.id } }
    }
    return $null
}

# Pure: decide the exit for one shadow. Live fill (real slippage) wins over the
# bar-model price when both show the stop traded; time stop after hold_days_max.
function Resolve-AggrShadowExit($sh, $bars, $closedOrders, [int]$weekdaysHeld, $a) {
    $bar  = Get-AggrShadowBarExit $sh $bars
    $live = Get-AggrShadowLiveExit $sh $closedOrders
    if ($null -ne $live -and ($null -eq $bar -or $bar.Reason -eq "STOP")) {
        return [pscustomobject]@{ Reason = "STOP"; Price = $live.Price; Source = "LIVE_FILL"; Time = $live.Time; BarPrice = $(if ($bar) { $bar.Price } else { $null }) }
    }
    if ($null -ne $bar) { return [pscustomobject]@{ Reason = $bar.Reason; Price = $bar.Price; Source = "BARS"; Time = $bar.Time; BarPrice = $bar.Price } }
    if ($weekdaysHeld -ge [int]$a.hold_days_max) {
        $last = @($bars | Sort-Object Time) | Select-Object -Last 1
        if ($last) { return [pscustomobject]@{ Reason = "TIME"; Price = [double]$last.Close; Source = "BARS"; Time = $last.Time; BarPrice = [double]$last.Close } }
    }
    return $null
}

function Get-AggrShadowPlannedR($sh) {
    if ($null -ne $sh.PSObject.Properties['limit'] -and $null -ne $sh.limit -and [double]$sh.limit -gt 0) {
        $d = [Math]::Abs([double]$sh.limit - [double]$sh.stop); if ($d -gt 0) { return $d } }
    if ([double]$sh.qty -gt 0 -and [double]$sh.risk_usd -gt 0 -and $sh.kind -ne 'call') { return [double]$sh.risk_usd / [double]$sh.qty }
    return [Math]::Abs([double]$sh.entry - [double]$sh.stop)
}

function Get-AggrShadowPnl($sh, [double]$exitPx) {
    $dir = if ($sh.side -eq "sell") { -1.0 } else { 1.0 }
    $pnl = $dir * ($exitPx - [double]$sh.entry) * [double]$sh.qty
    # R from the PLANNED stop distance (limit - stop), not fill - stop: a fill far
    # through the limit left AEHL 1c above its stop and logged -119.9R (true -0.55R).
    $r = Get-AggrShadowPlannedR $sh
    $rm = if ($r -gt 0) { $dir * ($exitPx - [double]$sh.entry) / $r } else { 0 }
    return [pscustomobject]@{ Pnl = [Math]::Round($pnl, 2); R = [Math]::Round($rm, 2) }
}

# Rebuild full shadow records for legacy {sym,kind,risk_usd} entries from the
# DRYRUN_ENTERED payloads in the skip journal.
function Convert-AggrLegacyDryEntered($state) {
    $old = @($state.aggr_dry_entered | Where-Object { $_ })
    if ($old.Count -eq 0) { return }
    $lines = @()
    if (Test-Path $script:AggrSkipJournal) {
        $lines = @(Get-Content $script:AggrSkipJournal | Where-Object { $_ -match 'DRYRUN_ENTERED' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    }
    foreach ($o in $old) {
        if (@($state.aggr_shadow_open | Where-Object { $_.sym -eq $o.sym }).Count -gt 0) { continue }
        $l = $lines | Where-Object { $_.sym -eq $o.sym -and $_.skip_reason -eq 'DRYRUN_ENTERED' } | Select-Object -Last 1
        if ($null -eq $l -or $null -eq $l.payload) { continue }
        $p = $l.payload
        if ($o.kind -eq 'call' -or $null -eq $p.stop_loss) { continue }   # call shadows had no stock geometry recorded
        $tp = if ($p.take_profit) { [double]$p.take_profit.limit_price } else { $null }
        $state.aggr_shadow_open = @($state.aggr_shadow_open) + (New-AggrShadow $o.sym 'stock' ([string]$p.side) ([double]$p.limit_price) ([double]$p.stop_loss.stop_price) $tp ([int]$p.qty) ([double]$o.risk_usd) ([string]$l.ts))
    }
    $state.aggr_dry_entered = @()
}

# Shadows created before fill tracking carry no 'filled' flag: they were booked
# at the limit, so they are re-evaluated as working orders (limit = entry).
function Test-AggrShadowFilled($sh) { return ($null -ne $sh.PSObject.Properties['filled'] -and [bool]$sh.filled) }
function Get-AggrEtZone {
    try { return [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time") }
    catch { return [System.TimeZoneInfo]::FindSystemTimeZoneById("America/New_York") }
}

function Update-AggrShadowBook($cfg, $state, $allPositions) {
    $a = Get-AggrCfg $cfg
    Initialize-AggrState $state
    Convert-AggrLegacyDryEntered $state
    $still = @()
    foreach ($sh in @($state.aggr_shadow_open)) {
        if ($null -eq $sh) { continue }
        $bars = @(Get-Bars $cfg $sh.sym "5Min" 1000)
        # nested=true: a bracket's stop leg is only visible under its parent; flatten.
        # No 'after' filter: legs carry the PARENT's submit time; filled_at is checked instead.
        $raw = Invoke-AggrApi $cfg "GET" ("/v2/orders?status=closed&nested=true&symbols={0}&direction=desc&limit=100" -f $sh.sym)
        $co = @(); foreach ($o in @($raw)) { if ($o) { $co += $o; foreach ($l in @($o.legs)) { if ($l) { $co += $l } } } }
        # Entry first: a shadow limit is a working order until the market trades through it.
        if (-not (Test-AggrShadowFilled $sh)) {
            if ($null -eq $sh.PSObject.Properties['limit'] -or $null -eq $sh.limit) { $sh | Add-Member -NotePropertyName limit -NotePropertyValue ([double]$sh.entry) -Force }
            $f = Get-AggrShadowLiveFill $sh $co
            $fillSrc = "LIVE_FILL"
            if ($null -eq $f) { $f = Get-AggrShadowFill $sh $bars; $fillSrc = "BARS" }
            if ($null -eq $f) {
                # Legacy cancels an unfilled entry the next ET day (Cancel-StaleEntries); so does the shadow.
                $openedEt = [System.TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-UtcTime $sh.opened_at), (Get-AggrEtZone)).ToString("yyyy-MM-dd")
                if ($openedEt -lt (Get-EasternTime).ToString("yyyy-MM-dd")) {
                    Write-AggrSkip @{ sym = $sh.sym; event = "SHADOW_EXIT"; skip_reason = "DRYRUN_EXIT"; dry_run = $true; exit_reason = "UNFILLED"
                                      limit = $sh.limit; qty = $sh.qty; pnl = 0.0; opened_at = $sh.opened_at; kind = $sh.kind }
                    continue
                }
                $still += $sh; continue
            }
            $sh | Add-Member -NotePropertyName entry -NotePropertyValue ([double]$f.Price) -Force
            $sh | Add-Member -NotePropertyName filled -NotePropertyValue $true -Force
            $sh | Add-Member -NotePropertyName filled_at -NotePropertyValue ((ConvertTo-UtcTime $f.Time).ToString("o")) -Force
            $sh | Add-Member -NotePropertyName fill_source -NotePropertyValue $fillSrc -Force
        }
        $held = Get-WeekdayCount ((ConvertTo-UtcTime $sh.opened_at)) ([datetime]::UtcNow)
        # Exits are only possible from the fill bar on.
        $shx = $sh | Select-Object *
        if ($sh.filled_at) { $shx.opened_at = (ConvertTo-UtcTime $sh.filled_at).AddSeconds(-1).ToString("o") }
        $x = Resolve-AggrShadowExit $shx $bars $co $held $a
        if ($null -eq $x) { $still += $sh; continue }
        $pp = Get-AggrShadowPnl $sh ([double]$x.Price)
        $liveHeld = @($allPositions | Where-Object { $_ -and $_.symbol -eq $sh.sym }).Count -gt 0
        Write-AggrSkip @{ sym = $sh.sym; event = "SHADOW_EXIT"; skip_reason = "DRYRUN_EXIT"; dry_run = $true; exit_reason = $x.Reason
                          source = $x.Source; limit = $sh.limit; entry = $sh.entry; filled_at = $sh.filled_at; fill_source = $sh.fill_source; stop = $sh.stop; tp = $sh.tp; qty = $sh.qty; exit_price = $x.Price
                          bar_model_price = $x.BarPrice; exit_time = [string]$x.Time; pnl = $pp.Pnl; r_multiple = $pp.R
                          kind = $sh.kind; opened_at = $sh.opened_at; live_position_still_open = $liveHeld
                          note = $(if ($sh.kind -eq 'call') { "call shadow: P&L is the stock-equivalent, not option premium" } else { $null }) }
        $closed = $sh | Select-Object *; $closed | Add-Member -NotePropertyName exit -NotePropertyValue ([double]$x.Price) -Force
        $closed | Add-Member -NotePropertyName exit_reason -NotePropertyValue $x.Reason -Force
        $closed | Add-Member -NotePropertyName pnl -NotePropertyValue $pp.Pnl -Force
        $state.aggr_shadow_closed = @(@($state.aggr_shadow_closed) + $closed | Select-Object -Last 100)
        $state.aggr_shadow_realized = [Math]::Round([double]$state.aggr_shadow_realized + $pp.Pnl, 2)
    }
    $state.aggr_shadow_open = @($still)
}

# Single entry point called from Run-Scan.
function Invoke-AggrCycle($cfg, $state, $regime, $spyDaily, [double]$equity, [double]$bp, $myPositions, $allPositions, $workingOrderSyms, [bool]$inEntryWindow) {
    if (-not (Test-AggrEnabled $cfg)) { return }
    Initialize-AggrState $state
    $mode = if (Test-AggrDryRun $cfg) { "DRY-RUN (read-only)" } else { "LIVE (paper)" }
    Write-Host ("  [AGGR] Swing aggressive v1.1 -- {0}" -f $mode) -ForegroundColor Magenta
    if (Test-AggrDryRun $cfg) { Update-AggrShadowBook $cfg $state $allPositions }
    Invoke-AggrManage $cfg $state $myPositions $allPositions
    if ($inEntryWindow) {
        Invoke-AggrEntries $cfg $state $regime $spyDaily $equity $bp $myPositions $allPositions $workingOrderSyms
    }
}
