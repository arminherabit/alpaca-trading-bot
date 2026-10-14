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
function Get-AggrStockPartialQty([double]$rMult, [int]$qty, [bool]$partialDone, $a) {
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

# ── Position management: AI migration + partials + call exits ────────────────

function Get-AggrJournalOpen([string]$sym) {
    try { $j = Load-Journal } catch { return $null }
    return @($j.open) | Where-Object { $_.symbol -eq $sym } | Sort-Object opened_at -Descending | Select-Object -First 1
}

function Invoke-AggrManage($cfg, $state, $myPositions, $allPositions) {
    $a = Get-AggrCfg $cfg; $dry = Test-AggrDryRun $cfg
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

        # (2) One-time 1/3 partial at +2R (stocks).
        $pq = Get-AggrStockPartialQty $rMult $qty (@($state.aggr_partial_done) -contains $sym) $a
        if ($pq -gt 0) {
            $side = if ($pos.side -eq "long") { "sell" } else { "buy" }
            $payload = [ordered]@{ symbol = $sym; qty = $pq.ToString(); side = $side; type = "market"; time_in_force = "day"
                                   client_order_id = ("PARTIAL_{0}_{1}" -f $sym, (Get-Date -Format "HHmmss")) }
            if ($dry) { Write-AggrSkip @{ sym = $sym; event = "PARTIAL"; skip_reason = "DRYRUN_PARTIAL"; r_mult = [Math]::Round($rMult, 2); payload = $payload; note = "then resize stop to remaining qty" } }
            else {
                $res = Invoke-AggrApi $cfg "POST" "/v2/orders" $payload
                if ($res) { $state.aggr_partial_done = @($state.aggr_partial_done) + $sym }
                # Remaining-qty stop resize is handled by Repair-DuplicateStops/protective fallback on next scan.
                Write-AggrSkip @{ sym = $sym; event = "PARTIAL"; skip_reason = $(if ($res) { "PARTIAL_SENT" } else { "PARTIAL_FAILED" }); payload = $payload }
            }
        }
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

function Invoke-AggrEntries($cfg, $state, $regime, $spyDaily, [double]$equity, [double]$bp, $myPositions, $allPositions, $workingOrderSyms) {
    $a = Get-AggrCfg $cfg; $dry = Test-AggrDryRun $cfg
    $etToday = (Get-EasternTime).ToString("yyyy-MM-dd")
    if ($state.aggr_day -ne $etToday) { $state.aggr_day = $etToday; $state.aggr_trades_today = 0; $state.aggr_dry_entered = @() }

    $dd = Get-AggrDdState $equity $a ([bool]$state.aggr_halted)
    if ($dd.Halted -and -not $state.aggr_halted) { $state.aggr_halted = $true; Write-Host "  [AGGR][HALT] equity <= floor -- no new aggressive entries until manual reset" -ForegroundColor Red }

    # Heat from live book (+ simulated dry-run entries today)
    $heatItems = @()
    $stockCount = 0; $callCount = 0
    foreach ($p in @($myPositions)) {
        if ($p.asset_class -eq "us_option") { $callCount++; $heatItems += @{ Kind = 'call'; MarketValue = [double]$p.market_value }; continue }
        $stockCount++
        $legs = Get-LiveExitLegs $cfg $p
        $heatItems += @{ Kind = 'stock'; Side = $p.side; Qty = [double]$p.qty; Entry = [double]$p.avg_entry_price; Stop = [double]$legs.stop }
    }
    foreach ($s in @($state.aggr_dry_entered)) { if ($s) { if ($s.kind -eq 'call') { $callCount++ } else { $stockCount++ }; $heatItems += @{ Kind = 'call'; MarketValue = [double]$s.risk_usd } } }
    $heat = Get-AggrHeat $heatItems

    $opusSyms = Get-AggrOpusUnderlyings $allPositions
    $watch = if (@($state.aggr_watchlist).Count -gt 0) { @($state.aggr_watchlist) } else { @($state.active_watchlist) }
    $confFloor = if ($regime.Regime -eq "BULL") { [int]$a.conf_floor_bull } else { [int]$a.conf_floor_neutral }
    $entered = $false
    $allSyms = @{}; foreach ($p in @($allPositions)) { if ($p) { $allSyms[$p.symbol] = $true } }
    $dryEnteredSyms = @(@($state.aggr_dry_entered) | ForEach-Object { $_.sym })

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
                    if ([int]$sig.Confidence -lt $confFloor) { $skip = "CONF_FLOOR" }
                }
            }
        }
        if ($null -ne $skip) { $rec.skip_reason = $skip; Write-AggrSkip $rec; continue }

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
            if (-not (Test-AggrHeatOk $heat $risk $equity $a)) { $rec.skip_reason = "HEAT"; Write-AggrSkip $rec; continue }
            $payload = New-AggrCallOrderPayload $pick.Occ $callSize.Contracts $limit $sym ([string]$a.call_entry_prefix)
            $rec.call_contract = @{ occ = $pick.Occ; dte = $pick.Dte; delta = $pick.Delta; bid = $pick.Bid; ask = $pick.Ask; oi = $pick.Oi; volume = $pick.Volume }
            $rec.quote_caveat = $script:AggrQuoteCaveat; $rec.feed = $a.options_feed
        } else {
            if ($stockCount -ge [int]$a.max_stock_positions) { $rec.skip_reason = "STOCK_SLOTS_FULL"; Write-AggrSkip $rec; continue }
            $sz = Get-AggrStockSize -equity $equity -buyingPower $bp -entry $sig.Entry -stop $sig.Stop -a $a -edgeMult $edge -regimeMult ([double]$regime.SizeMult) -ddMult $dd.Mult
            if ($sz.Shares -lt 1) { $rec.skip_reason = "SIZE_ZERO"; Write-AggrSkip $rec; continue }
            $risk = $sz.RiskUsd
            if (-not (Test-AggrHeatOk $heat $risk $equity $a)) { $rec.skip_reason = "HEAT"; $rec.risk_usd = $risk; Write-AggrSkip $rec; continue }
            $payload = New-AggrStockOrderPayload $sym $sig.Side $sz.Shares $sig.Entry $sig.Stop ([double]$a.dummy_tp_r) $sig.Strategy
            $rec.riskPct = $sz.RiskPct
        }
        $rec.risk_usd = $risk; $rec.heat_after = [Math]::Round($heat + $risk, 2); $rec.payload = $payload
        if ($dry) {
            $rec.skip_reason = "DRYRUN_ENTERED"
            $state.aggr_dry_entered = @($state.aggr_dry_entered) + [pscustomobject]@{ sym = $sym; kind = $instrument; risk_usd = $risk }
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

# Single entry point called from Run-Scan.
function Invoke-AggrCycle($cfg, $state, $regime, $spyDaily, [double]$equity, [double]$bp, $myPositions, $allPositions, $workingOrderSyms, [bool]$inEntryWindow) {
    if (-not (Test-AggrEnabled $cfg)) { return }
    Initialize-AggrState $state
    $mode = if (Test-AggrDryRun $cfg) { "DRY-RUN (read-only)" } else { "LIVE (paper)" }
    Write-Host ("  [AGGR] Swing aggressive v1.1 -- {0}" -f $mode) -ForegroundColor Magenta
    Invoke-AggrManage $cfg $state $myPositions $allPositions
    if ($inEntryWindow) {
        Invoke-AggrEntries $cfg $state $regime $spyDaily $equity $bp $myPositions $allPositions $workingOrderSyms
    }
}
