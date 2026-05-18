# Alpaca HTML Dashboard Generator
# Generates alpaca_dashboard.html with live positions, entries, targets, P&L.
# Usage:
#   .\alpaca_dashboard_html.ps1              # generate + open in browser
#   .\alpaca_dashboard_html.ps1 -GenerateOnly # CI mode (no browser open)

param([switch]$GenerateOnly)

. (Join-Path $PSScriptRoot "alpaca_client.ps1")

$cfg     = Load-AlpacaConfig
$OutFile = Join-Path $PSScriptRoot "alpaca_dashboard.html"

# ── Fetch all data ────────────────────────────────────────────────────────────
Write-Host "Fetching Alpaca data..." -ForegroundColor Cyan

$acct      = Get-Account  $cfg
$positions = Get-Positions $cfg
$orders    = Get-Orders    $cfg "all"
$clock     = Get-MarketClock $cfg

$state = if (Test-Path (Join-Path $PSScriptRoot "alpaca_state.json")) {
    Get-Content (Join-Path $PSScriptRoot "alpaca_state.json") | ConvertFrom-Json
} else {
    [pscustomobject]@{ trades_today=0; wins=0; losses=0; pnl_today=0.0; last_scan="" }
}

# ── Build position cards data ─────────────────────────────────────────────────
$posData = @()
foreach ($p in $positions) {
    $entry   = [double]$p.avg_entry_price
    $current = [double]$p.current_price
    $qty     = [double]$p.qty
    $side    = $p.side   # "long" or "short"
    $unrlPnl = [double]$p.unrealized_pl
    $unrlPct = [double]$p.unrealized_plpc * 100

    # Try to find matching bracket order for stop/target
    $bracketOrders = @($orders | Where-Object {
        $_.symbol -eq $p.symbol -and $_.order_class -eq "bracket"
    })
    $stopPrice   = 0.0
    $targetPrice = 0.0
    if ($bracketOrders.Count -gt 0) {
        $legs = $bracketOrders[0]
        # Stop leg
        $stopLeg   = $legs.legs | Where-Object { $_.type -eq "stop" }      | Select-Object -First 1
        $targetLeg = $legs.legs | Where-Object { $_.type -eq "limit" }     | Select-Object -First 1
        if ($null -ne $stopLeg)   { $stopPrice   = [double]$stopLeg.stop_price    }
        if ($null -ne $targetLeg) { $targetPrice = [double]$targetLeg.limit_price }
    }

    # Fallback: estimate from state or use ATR-based defaults
    if ($stopPrice   -eq 0) { $stopPrice   = if ($side -eq "long") { [Math]::Round($entry * 0.99, 2) } else { [Math]::Round($entry * 1.01, 2) } }
    if ($targetPrice -eq 0) { $targetPrice = if ($side -eq "long") { [Math]::Round($entry * 1.025, 2) } else { [Math]::Round($entry * 0.975, 2) } }

    $riskPerShare   = [Math]::Abs($entry - $stopPrice)
    $rewardPerShare = [Math]::Abs($targetPrice - $entry)
    $rr             = if ($riskPerShare -gt 0) { [Math]::Round($rewardPerShare / $riskPerShare, 2) } else { 0 }
    $projProfit     = [Math]::Round($rewardPerShare * $qty, 2)
    $projLoss       = [Math]::Round($riskPerShare   * $qty, 2)
    $pctToTarget    = if ($side -eq "long") {
        [Math]::Round(($targetPrice - $current) / $current * 100, 2)
    } else {
        [Math]::Round(($current - $targetPrice) / $current * 100, 2)
    }
    $pctToStop      = if ($side -eq "long") {
        [Math]::Round(($current - $stopPrice) / $current * 100, 2)
    } else {
        [Math]::Round(($stopPrice - $current) / $current * 100, 2)
    }

    # Progress bar: 0% = at stop, 100% = at target
    $range    = $targetPrice - $stopPrice
    $progress = if ($range -ne 0) {
        [Math]::Max(0, [Math]::Min(100, [Math]::Round(($current - $stopPrice) / $range * 100, 1)))
    } else { 50 }

    $posData += [pscustomobject]@{
        symbol       = $p.symbol
        side         = $side
        qty          = $qty
        entry        = $entry
        current      = $current
        stop         = $stopPrice
        target       = $targetPrice
        rr           = $rr
        unrlPnl      = [Math]::Round($unrlPnl, 2)
        unrlPct      = [Math]::Round($unrlPct, 2)
        projProfit   = $projProfit
        projLoss     = $projLoss
        pctToTarget  = $pctToTarget
        pctToStop    = $pctToStop
        progress     = $progress
        value        = [Math]::Round($qty * $current, 2)
    }
}

# ── Closed trades today ────────────────────────────────────────────────────────
$today       = (Get-Date).ToString("yyyy-MM-dd")
$closedToday = @($orders | Where-Object {
    $_.status -eq "filled" -and
    $_.filled_at -ne $null -and
    ([datetime]$_.filled_at).ToString("yyyy-MM-dd") -eq $today
})

$closedData = @()
foreach ($o in $closedToday) {
    $filledAt = "n/a"
    try { $filledAt = ([datetime]$o.filled_at).ToLocalTime().ToString("HH:mm:ss") } catch {}
    $closedData += [pscustomobject]@{
        symbol    = $o.symbol
        side      = $o.side
        qty       = $o.filled_qty
        fillPrice = [Math]::Round([double]$o.filled_avg_price, 2)
        filledAt  = $filledAt
        orderType = $o.type
    }
}

# ── Account numbers ────────────────────────────────────────────────────────────
$equity    = if ($null -ne $acct) { [double]$acct.equity }        else { 0 }
$cash      = if ($null -ne $acct) { [double]$acct.cash }          else { 0 }
$bp        = if ($null -ne $acct) { [double]$acct.buying_power }  else { 0 }
$lastEq    = if ($null -ne $acct) { [double]$acct.last_equity }   else { $equity }
$dayPnl    = [Math]::Round($equity - $lastEq, 2)
$dayPnlPct = if ($lastEq -gt 0) { [Math]::Round($dayPnl / $lastEq * 100, 2) } else { 0 }
$mktStatus = if ($null -ne $clock -and $clock.is_open) { "OPEN" } else { "CLOSED" }
$mktColor  = if ($mktStatus -eq "OPEN") { "#3fb950" } else { "#8b949e" }
$nextEvent = if ($null -ne $clock) {
    if ($clock.is_open) {
        "Closes " + ([datetime]$clock.next_close).ToLocalTime().ToString("h:mm tt")
    } else {
        "Opens "  + ([datetime]$clock.next_open ).ToLocalTime().ToString("ddd h:mm tt")
    }
} else { "" }

$genTime   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$modeLabel = if ($cfg.paper_trading) { "PAPER TRADING" } else { "LIVE TRADING" }
$modeColor = if ($cfg.paper_trading) { "#d29922" } else { "#da3633" }

# ── Serialise to JSON for embedding ───────────────────────────────────────────
$posJson    = $posData    | ConvertTo-Json -Depth 5 -Compress
$closedJson = $closedData | ConvertTo-Json -Depth 5 -Compress
if ($posJson    -eq "null") { $posJson    = "[]" }
if ($closedJson -eq "null") { $closedJson = "[]" }

# ── HTML ──────────────────────────────────────────────────────────────────────
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="30">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Alpaca Dashboard</title>
<style>
  :root {
    --bg:      #0d1117; --bg2: #161b22; --bg3: #21262d;
    --border:  #30363d; --text: #f0f6fc; --sub: #8b949e;
    --green:   #3fb950; --red: #f85149; --yellow: #d29922;
    --blue:    #58a6ff; --purple: #8957e5; --orange: #e85010;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', monospace; font-size: 14px; }

  header { background: var(--bg2); border-bottom: 1px solid var(--border);
           padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; }
  header h1 { font-size: 18px; font-weight: 700; letter-spacing: 1px; color: var(--blue); }
  .badges { display: flex; gap: 10px; align-items: center; }
  .badge { padding: 3px 10px; border-radius: 20px; font-size: 11px; font-weight: 700;
           border: 1px solid; letter-spacing: .5px; }
  .gen-time { font-size: 11px; color: var(--sub); }

  .grid-top { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; padding: 16px 24px; }
  .stat-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px;
               padding: 14px 16px; }
  .stat-card .label { font-size: 11px; color: var(--sub); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 6px; }
  .stat-card .value { font-size: 22px; font-weight: 700; }
  .stat-card .sub   { font-size: 11px; color: var(--sub); margin-top: 4px; }

  .section { padding: 0 24px 20px; }
  .section h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 1px;
                color: var(--sub); margin-bottom: 12px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }

  /* Position cards */
  .pos-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(420px, 1fr)); gap: 14px; }
  .pos-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 10px; padding: 18px; }
  .pos-card.long  { border-left: 3px solid var(--green); }
  .pos-card.short { border-left: 3px solid var(--red); }

  .pos-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 14px; }
  .pos-symbol { font-size: 22px; font-weight: 800; letter-spacing: 1px; }
  .pos-side   { font-size: 11px; font-weight: 700; padding: 3px 9px; border-radius: 4px; }
  .pos-side.long  { background: #3fb95022; color: var(--green); border: 1px solid var(--green); }
  .pos-side.short { background: #f8514922; color: var(--red);   border: 1px solid var(--red); }
  .pos-pnl { text-align: right; }
  .pos-pnl .pnl-val { font-size: 20px; font-weight: 700; }
  .pos-pnl .pnl-pct { font-size: 12px; color: var(--sub); }

  .price-row { display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 8px; margin-bottom: 14px; }
  .price-cell { background: var(--bg3); border-radius: 6px; padding: 8px 10px; }
  .price-cell .p-label { font-size: 10px; color: var(--sub); text-transform: uppercase; margin-bottom: 3px; }
  .price-cell .p-val   { font-size: 14px; font-weight: 700; }
  .price-cell .p-sub   { font-size: 10px; color: var(--sub); }

  /* Progress bar */
  .progress-wrap { margin-bottom: 14px; }
  .progress-labels { display: flex; justify-content: space-between; font-size: 10px; color: var(--sub); margin-bottom: 4px; }
  .progress-track { background: var(--bg3); border-radius: 4px; height: 8px; position: relative; overflow: hidden; }
  .progress-fill  { height: 100%; border-radius: 4px; transition: width .4s; }

  .proj-row { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
  .proj-cell { background: var(--bg3); border-radius: 6px; padding: 8px 10px; text-align: center; }
  .proj-cell .p-label { font-size: 10px; color: var(--sub); text-transform: uppercase; margin-bottom: 3px; }
  .proj-cell .p-val   { font-size: 13px; font-weight: 700; }

  /* Orders table */
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { background: var(--bg3); color: var(--sub); font-size: 11px; text-transform: uppercase;
       letter-spacing: .8px; padding: 8px 12px; text-align: left; border-bottom: 1px solid var(--border); }
  td { padding: 9px 12px; border-bottom: 1px solid var(--border); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: var(--bg3); }
  .tag { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; }
  .tag.buy  { background: #3fb95022; color: var(--green); }
  .tag.sell { background: #f8514922; color: var(--red); }

  .empty { color: var(--sub); font-style: italic; padding: 20px; text-align: center; }
  .green { color: var(--green); } .red { color: var(--red); }
  .yellow { color: var(--yellow); } .blue { color: var(--blue); }

  footer { text-align: center; padding: 16px; color: var(--sub); font-size: 11px;
           border-top: 1px solid var(--border); margin-top: 10px; }
</style>
</head>
<body>

<header>
  <h1>&#9650; ALPACA TRADING DASHBOARD</h1>
  <div class="badges">
    <span class="badge" style="color:$modeColor; border-color:$modeColor;">$modeLabel</span>
    <span class="badge" style="color:$mktColor;  border-color:$mktColor;">$mktStatus</span>
    <span class="badge" style="color:var(--sub); border-color:var(--border);">$nextEvent</span>
  </div>
  <span class="gen-time">Generated: $genTime &nbsp;|&nbsp; Auto-refresh: 30s</span>
</header>

<!-- Account Stats -->
<div class="grid-top">
  <div class="stat-card">
    <div class="label">Equity</div>
    <div class="value blue">`$$($equity.ToString("N2"))</div>
    <div class="sub">Paper account</div>
  </div>
  <div class="stat-card">
    <div class="label">Day P&amp;L</div>
    <div class="value $(if ($dayPnl -ge 0) { 'green' } else { 'red' })">`$$($dayPnl.ToString("N2"))</div>
    <div class="sub">$(if ($dayPnlPct -ge 0) { '+' })$($dayPnlPct)%</div>
  </div>
  <div class="stat-card">
    <div class="label">Buying Power</div>
    <div class="value">`$$($bp.ToString("N2"))</div>
    <div class="sub">Cash: `$$($cash.ToString("N2"))</div>
  </div>
  <div class="stat-card">
    <div class="label">Trades Today</div>
    <div class="value">$($state.trades_today)</div>
    <div class="sub">W: $($state.wins) &nbsp;/&nbsp; L: $($state.losses)</div>
  </div>
  <div class="stat-card">
    <div class="label">Open Positions</div>
    <div class="value">$($posData.Count) <span style="font-size:14px;color:var(--sub)">/ $($cfg.max_positions)</span></div>
    <div class="sub">Max $($cfg.max_positions) allowed</div>
  </div>
  <div class="stat-card">
    <div class="label">Risk Per Trade</div>
    <div class="value yellow">$($cfg.max_risk_pct)%</div>
    <div class="sub">Min R:R 1:$($cfg.min_rr_ratio)</div>
  </div>
</div>

<!-- Open Positions -->
<div class="section">
  <h2>Open Positions</h2>
  <div class="pos-grid" id="posGrid"></div>
</div>

<!-- Closed Trades Today -->
<div class="section">
  <h2>Filled Orders Today</h2>
  <table id="closedTable">
    <thead>
      <tr>
        <th>Symbol</th><th>Side</th><th>Qty</th>
        <th>Fill Price</th><th>Type</th><th>Time</th>
      </tr>
    </thead>
    <tbody id="closedBody"></tbody>
  </table>
</div>

<footer>
  Alpaca Paper Trading &nbsp;|&nbsp; Strategies: ORB &bull; VWAP Bounce &bull; EMA Pullback
  &nbsp;|&nbsp; Max Risk 1% equity per trade &nbsp;|&nbsp; Auto-refreshes every 30s
</footer>

<script>
const positions = $posJson;
const closed    = $closedJson;

function fmt(n, d=2) {
  return (n >= 0 ? '+' : '') + Number(n).toFixed(d);
}
function fmtUSD(n) {
  return (n < 0 ? '-$' : '$') + Math.abs(n).toLocaleString('en-US', {minimumFractionDigits:2, maximumFractionDigits:2});
}

// ── Position cards ──────────────────────────────────────────────────────────
const grid = document.getElementById('posGrid');
if (!positions || positions.length === 0) {
  grid.innerHTML = '<div class="empty">No open positions</div>';
} else {
  positions.forEach(p => {
    const pnlColor  = p.unrlPnl >= 0 ? '#3fb950' : '#f85149';
    const fillColor = p.progress > 66 ? '#3fb950' : p.progress > 33 ? '#d29922' : '#f85149';
    const isLong    = p.side === 'long';

    grid.innerHTML += `
    <div class="pos-card ${p.side}">
      <div class="pos-header">
        <div>
          <div class="pos-symbol">${p.symbol}</div>
          <div style="color:var(--sub);font-size:12px;margin-top:3px">
            ${p.qty} shares &nbsp;&bull;&nbsp; Value ${fmtUSD(p.value)}
          </div>
        </div>
        <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px">
          <span class="pos-side ${p.side}">${p.side.toUpperCase()}</span>
          <div class="pos-pnl">
            <div class="pnl-val" style="color:${pnlColor}">${fmtUSD(p.unrlPnl)}</div>
            <div class="pnl-pct">${fmt(p.unrlPct)}%</div>
          </div>
        </div>
      </div>

      <div class="price-row">
        <div class="price-cell">
          <div class="p-label">Entry</div>
          <div class="p-val">${'$'}${p.entry.toFixed(2)}</div>
          <div class="p-sub">Avg cost</div>
        </div>
        <div class="price-cell">
          <div class="p-label">Current</div>
          <div class="p-val" style="color:${pnlColor}">${'$'}${p.current.toFixed(2)}</div>
          <div class="p-sub">${fmt(p.unrlPct)}% vs entry</div>
        </div>
        <div class="price-cell">
          <div class="p-label">Stop Loss</div>
          <div class="p-val" style="color:#f85149">${'$'}${p.stop.toFixed(2)}</div>
          <div class="p-sub">${p.pctToStop.toFixed(2)}% away</div>
        </div>
        <div class="price-cell">
          <div class="p-label">Target T1</div>
          <div class="p-val" style="color:#3fb950">${'$'}${p.target.toFixed(2)}</div>
          <div class="p-sub">${p.pctToTarget.toFixed(2)}% away</div>
        </div>
      </div>

      <div class="progress-wrap">
        <div class="progress-labels">
          <span style="color:#f85149">STOP ${'$'}${p.stop.toFixed(2)}</span>
          <span style="color:var(--sub)">${p.progress.toFixed(0)}% to target</span>
          <span style="color:#3fb950">TARGET ${'$'}${p.target.toFixed(2)}</span>
        </div>
        <div class="progress-track">
          <div class="progress-fill" style="width:${p.progress}%;background:${fillColor}"></div>
        </div>
      </div>

      <div class="proj-row">
        <div class="proj-cell">
          <div class="p-label">Proj. Profit (T1)</div>
          <div class="p-val" style="color:#3fb950">+${fmtUSD(p.projProfit)}</div>
        </div>
        <div class="proj-cell">
          <div class="p-label">Proj. Loss (Stop)</div>
          <div class="p-val" style="color:#f85149">-${fmtUSD(p.projLoss)}</div>
        </div>
        <div class="proj-cell">
          <div class="p-label">R:R Ratio</div>
          <div class="p-val" style="color:${p.rr >= 2.5 ? '#3fb950' : '#d29922'}">1:${p.rr.toFixed(2)}</div>
        </div>
      </div>
    </div>`;
  });
}

// ── Closed trades table ──────────────────────────────────────────────────────
const tbody = document.getElementById('closedBody');
if (!closed || closed.length === 0) {
  tbody.innerHTML = '<tr><td colspan="6" class="empty">No filled orders today</td></tr>';
} else {
  [...closed].reverse().forEach(o => {
    const tagClass = o.side === 'buy' ? 'buy' : 'sell';
    tbody.innerHTML += `<tr>
      <td><strong>${o.symbol}</strong></td>
      <td><span class="tag ${tagClass}">${o.side.toUpperCase()}</span></td>
      <td>${o.qty}</td>
      <td><strong>${'$'}${Number(o.fillPrice).toFixed(2)}</strong></td>
      <td style="color:var(--sub)">${o.orderType}</td>
      <td style="color:var(--sub)">${o.filledAt}</td>
    </tr>`;
  });
}
</script>
</body>
</html>
"@

$html | Set-Content $OutFile -Encoding UTF8
Write-Host "Dashboard saved: $OutFile" -ForegroundColor Green

if (-not $GenerateOnly) {
    Start-Process $OutFile
    Write-Host "Opened in browser." -ForegroundColor Cyan
}
