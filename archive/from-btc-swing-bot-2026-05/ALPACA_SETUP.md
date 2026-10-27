# Alpaca Day Trading Framework — Setup Guide

## Step 1: Create an Alpaca Account

1. Go to **https://alpaca.markets** and sign up (free)
2. Complete identity verification (required for live trading)
3. Navigate to **Paper Trading** first — no real money needed

## Step 2: Get API Keys

### Paper Trading Keys
1. Log in → click your name (top right) → **Paper Trading**
2. Click **Your API Keys** (right sidebar)
3. Click **Generate New Key**
4. Copy both **Key ID** and **Secret Key** — secret is shown once only

### Live Trading Keys (when ready)
1. Log in → **Live Trading** tab
2. Same process — these keys hit real money, guard them carefully

---

## Step 3: Set Environment Variables (Windows)

Open PowerShell as Administrator and run:

```powershell
[System.Environment]::SetEnvironmentVariable("ALPACA_API_KEY",    "your-key-id-here",    "User")
[System.Environment]::SetEnvironmentVariable("ALPACA_API_SECRET", "your-secret-here",    "User")
[System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "your-anthropic-key",  "User")
```

Restart your terminal after setting these. Verify:

```powershell
$env:ALPACA_API_KEY      # should print your key
$env:ALPACA_API_SECRET   # should print your secret
```

---

## Step 4: Test the Connection

```powershell
cd D:\Claude-code\.claude\worktrees\nervous-merkle-47ec33

# Load client and fetch account info
. .\alpaca_client.ps1
$cfg = Load-AlpacaConfig
$acct = Get-Account $cfg
$acct | Select-Object equity, buying_power, cash, status
```

You should see your paper account equity (~$100,000 by default).

---

## Step 5: Run the Bot

### One scan (test run)
```powershell
.\alpaca_bot.ps1 -Once
```

### Continuous scanning (every 60s during market hours)
```powershell
.\alpaca_bot.ps1
```

### Approve pending trades
```powershell
# View pending
Get-Content .\pending_approval.json | ConvertFrom-Json

# Approve all pending
.\alpaca_bot.ps1 -Approve

# Approve a specific trade by ID
.\alpaca_bot.ps1 -ApproveId abc12345
```

### Emergency stop (cancel all orders + close all positions)
```powershell
.\alpaca_bot.ps1 -Cancel
```

### Live dashboard (separate terminal)
```powershell
.\alpaca_dashboard.ps1
```

---

## Step 6: Automate with Windows Task Scheduler

### Auto-start at market open (9:30 AM ET = 8:30 AM CT / adjust for your timezone)

Open PowerShell as Administrator:

```powershell
$scriptPath = "D:\Claude-code\.claude\worktrees\nervous-merkle-47ec33\alpaca_bot.ps1"
$action  = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$scriptPath`""

# Mon-Fri at 9:28 AM Eastern (adjust offset for your local timezone)
$trigger = New-ScheduledTaskTrigger `
    -Weekly `
    -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
    -At "9:28AM"

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName "AlpacaDayTrader" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -Force

Write-Host "Task registered. Bot will start Mon-Fri at 9:28 AM."
```

### Auto-stop at 3:45 PM

```powershell
$stopScript = @"
Stop-Process -Name powershell -ErrorAction SilentlyContinue
& powershell.exe -File "$scriptPath" -Cancel
"@
$stopScriptPath = "D:\Claude-code\.claude\worktrees\nervous-merkle-47ec33\alpaca_stop.ps1"
$stopScript | Set-Content $stopScriptPath

$stopAction  = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -File `"$stopScriptPath`""
$stopTrigger = New-ScheduledTaskTrigger `
    -Weekly `
    -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
    -At "3:45PM"

Register-ScheduledTask `
    -TaskName "AlpacaDayTraderStop" `
    -Action $stopAction `
    -Trigger $stopTrigger `
    -RunLevel Highest `
    -Force
```

### Verify tasks
```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -like "Alpaca*" }
```

---

## Step 7: Claude Code MCP Integration (Optional)

To give Claude Code direct Alpaca tool access (so I can call Get-Account,
Submit orders, etc. natively), install the Alpaca MCP server:

### Option A: Python MCP server (recommended)

```bash
pip install alpaca-trade-api mcp
```

Create `alpaca_mcp_server.py`:

```python
import os
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp import Tool
import alpaca_trade_api as tradeapi

api = tradeapi.REST(
    os.environ["ALPACA_API_KEY"],
    os.environ["ALPACA_API_SECRET"],
    base_url="https://paper-api.alpaca.markets"
)

server = Server("alpaca")

@server.tool()
def get_account() -> dict:
    """Get Alpaca account info: equity, buying_power, cash."""
    a = api.get_account()
    return {"equity": a.equity, "buying_power": a.buying_power,
            "cash": a.cash, "status": a.status}

@server.tool()
def get_positions() -> list:
    """List all open positions."""
    return [{"symbol": p.symbol, "qty": p.qty,
             "avg_entry": p.avg_entry_price,
             "unrealized_pl": p.unrealized_pl} for p in api.list_positions()]

@server.tool()
def get_quote(symbol: str) -> dict:
    """Get latest quote for a symbol."""
    q = api.get_latest_quote(symbol)
    return {"symbol": symbol, "bid": q.bp, "ask": q.ap}

@server.tool()
def submit_order(symbol: str, qty: int, side: str,
                 order_type: str = "market", limit_price: float = None) -> dict:
    """Submit an order. side: buy/sell. order_type: market/limit."""
    kwargs = {"symbol": symbol, "qty": qty, "side": side,
              "type": order_type, "time_in_force": "day"}
    if limit_price:
        kwargs["limit_price"] = limit_price
    o = api.submit_order(**kwargs)
    return {"id": o.id, "status": o.status, "symbol": o.symbol}

@server.tool()
def cancel_all_orders() -> str:
    """Cancel all open orders."""
    api.cancel_all_orders()
    return "All orders cancelled"

async def main():
    async with stdio_server() as streams:
        await server.run(*streams)

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
```

Add to Claude Code settings (`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "alpaca": {
      "command": "python",
      "args": ["D:/Claude-code/.claude/worktrees/nervous-merkle-47ec33/alpaca_mcp_server.py"],
      "env": {
        "ALPACA_API_KEY": "${ALPACA_API_KEY}",
        "ALPACA_API_SECRET": "${ALPACA_API_SECRET}"
      }
    }
  }
}
```

Restart Claude Code — I'll then have native `get_account`, `get_positions`,
`get_quote`, `submit_order`, and `cancel_all_orders` tools.

---

## Configuration Reference (`alpaca_config.json`)

| Field               | Default       | Description                                      |
|---------------------|---------------|--------------------------------------------------|
| `paper_trading`     | `true`        | **Always start here.** Switch to `false` for live |
| `max_risk_pct`      | `1.0`         | Max % of equity risked per trade                 |
| `min_rr_ratio`      | `2.5`         | Minimum reward:risk (1:2.5)                      |
| `max_positions`     | `3`           | Max simultaneous open positions                  |
| `watchlist`         | 7 symbols     | Symbols to scan each cycle                       |
| `orb_minutes`       | `15`          | Opening range duration in minutes                |
| `no_trade_before`   | `"09:45"`     | ET — avoid first 15min chop                     |
| `no_trade_after`    | `"15:30"`     | ET — avoid last 30min volatility                 |
| `scan_interval_sec` | `60`          | Seconds between watchlist scans                  |
| `require_approval`  | `true`        | `false` = auto-execute (paper only!)             |

---

## Workflow Summary

```
Market opens 9:30 ET
        │
        ▼
Bot starts scanning at 9:45 ET (no_trade_before)
        │
        ▼
Every 60s: fetch 1m + 5m bars for each symbol
        │
        ├─ ORB:          breakout above/below first-15min range?
        ├─ VWAP Bounce:  price dipped to VWAP and reclaimed it?
        └─ EMA Pullback: bounced off 9 EMA in confirmed uptrend?
                │
                ▼
        Risk validation:
          ✓ R:R >= 2.5
          ✓ Risk <= 1% equity
          ✓ Buying power sufficient
          ✓ < 3 open positions
                │
          PASS ─┼─ FAIL → discard, keep watching
                │
                ▼
        Write to pending_approval.json
                │
                ▼
        Human runs:  .\alpaca_bot.ps1 -Approve
                │
                ▼
        Bracket order submitted (entry + stop + take-profit)
                │
                ▼
        Monitor via:  .\alpaca_dashboard.ps1
                │
                ▼
        Bot stops new entries at 15:30 ET
        Task Scheduler kills process at 15:45 ET
```

---

## Going Live Checklist

- [ ] Ran for 2+ weeks in paper mode with consistent results
- [ ] R:R averaged above 2.5 across all trades
- [ ] Win rate above 40% (enough at 1:2.5 R:R to be profitable)
- [ ] Switched `paper_trading` to `false` in config
- [ ] Updated env vars to **live** API keys (not paper keys)
- [ ] Set `require_approval` to `true` (should be true for live regardless)
- [ ] Reduced position size initially (lower `max_risk_pct` to 0.5% first week)
- [ ] PDT Rule: maintain $25,000+ equity if making >3 round-trip trades/5 days
