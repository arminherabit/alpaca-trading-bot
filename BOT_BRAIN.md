# Alpaca Swing Trading Bot — The Brain

> Complete reference for how this bot thinks, decides, sizes, learns, and survives.
> Read this top-to-bottom and you'll know every rule it follows and every fact it remembers.

---

## TL;DR (60 seconds)

A self-learning, paper-trading **swing bot** for U.S. equities. Lives entirely in the cloud (cron-job.org + GitHub Actions + Alpaca paper API). Scans a dynamic watchlist every 10 minutes during market hours, takes **daily-bar setups held 2–10 days**, sizes by risk with stops at 2× daily ATR, and updates its own knowledge after every closed trade.

**Why swing, not day trading:** the first 25 day trades produced a 12% win rate. The cause was structural, not signal quality — stops sized from 5-minute ATR sat *inside* normal market noise while targets needed multi-hour moves, so stops were statistically tagged before any thesis was tested. The account's single profitable trade (an MRVL short that peaked at +$5.8k) was a de facto multi-day swing trade. The bot now trades that way on purpose.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [The Run-Scan Lifecycle](#2-the-run-scan-lifecycle)
3. [The Four Pillars of Discipline](#3-the-four-pillars-of-discipline)
4. [Swing Regime Detection](#4-swing-regime-detection)
5. [Strategy Engine](#5-strategy-engine-swing-setups)
6. [Risk & Position Sizing](#6-risk--position-sizing)
7. [The Self-Learning Loop](#7-the-self-learning-loop)
8. [Dynamic Screener](#8-dynamic-screener)
9. [News & Earnings Catalysts](#9-news--earnings-catalysts)
10. [Order Execution & Management](#10-order-execution--management)
11. [Configuration Reference](#11-configuration-reference)
12. [State & Memory Files](#12-state--memory-files)
13. [Failure Modes & Known Limits](#13-failure-modes--known-limits)
14. [Module Map](#14-module-map)
15. [History: the Day-Trading Era](#15-history-the-day-trading-era)

---

## 1. System Architecture

```
+--------------------+
|   cron-job.org     |   External trigger, every 10 min, 24/7
+----------+---------+
           |  POST /workflows/.../dispatches  (with BOT_TRIGGER_PAT)
           v
+--------------------+
|  GitHub Actions    |   Ubuntu runner, free tier
|  alpaca_bot.yml    |
+----------+---------+
           |  pwsh ./alpaca_bot.ps1 -Once
           v
+----------------------------------------+
|         Run-Scan (single cycle)        |
|                                        |
|  - Sync closed trades from Alpaca      |
|  - Daily reset / equity baseline       |
|  - SWING regime (SPY daily EMA20/50)   |
|  - Manage positions (BE stop at +2R)   |
|  - Time-stop stale holds (>12 days)    |
|  - Reap unfilled GTC entries           |
|  - Discipline gates (2 trades, 2L, DD) |
|  - Screener rebuild (10 AM ET)         |
|  - Per-symbol scan:                    |
|    -> Fetch ~170 DAILY bars (IEX)      |
|    -> BRKOUT / PULLBK signal eval      |
|    -> Validate (R:R 3.0+, sizing)      |
|    -> Submit GTC bracket order         |
+----------------+-----------------------+
                 |
                 +-> Alpaca paper API   (orders, positions, bars, snapshots)
                 +-> Alpaca News API    (catalyst tickers)
                 +-> Nasdaq calendar    (earnings dates)
                 +-> Yahoo Finance      (VIX level)
                 +-> git commit         (state + memory + dashboard)
```

**Compute & data are 100% cloud-based.** No local machine required.

| Service | Role | Free? |
|---------|------|-------|
| cron-job.org | Triggers every 10 min | yes |
| GitHub Actions | Runs the bot scan | yes (~2k min/month) |
| Alpaca paper | Trades + market data + news | yes |
| Nasdaq public calendar | Earnings dates | yes |
| Yahoo Finance | VIX fear gauge | yes |
| Git repo | State + memory persistence | yes |

Daily bars are robust on the free IEX feed — the sparse-data problems that plagued
intraday scanning don't exist at this timescale.

---

## 2. The Run-Scan Lifecycle

Every 10 minutes, `Run-Scan` executes in this exact order:

```
01.  Print header (UTC time, SWING mode, interval)
02.  Daily counter reset    -> if ET date changed since last scan,
                                wipe trades_today / wins / losses / pnl_today
03.  Sync-ClosedTrades       -> 7-day lookback, dedup by recorded_exits,
                                BOTH long and short brackets, direction-aware
                                PnL, updates wins / losses / memory
04.  Market-open gate        -> if closed, save state and return
05.  Swing-window note       -> outside 09:50-15:30 ET = monitor-only warning
06.  State backward-compat   -> add new fields to old state.json if missing
07.  Capture equity_at_open  -> once per ET day; drawdown baseline locked
08.  Get-SwingRegime         -> BULL / NEUTRAL / RANGING / BEAR from SPY
                                daily EMA20/50 + VIX overlay (SPY dailies
                                fetched once, shared with RS calc)
09.  Watchlist refresh       -> once per day at/after 10:00 AM ET
                                (earnings calendar + news + screener)
10.  Account summary         -> equity, BP, positions, today's stats
11.  Display open positions  -> per-position unrealized P&L
12.  Manage-OpenPositions    -> break-even stop at +2R (longs AND shorts)
13.  Close-StalePositions    -> time-stop holds older than 12 trading days
14.  Cancel-StaleEntries     -> kill unfilled GTC entry brackets from
                                prior days (the level was rejected)
15.  Max-positions check     -> if full, monitor-only, return
16.  Entry-window block      -> outside 09:50-15:30 ET, return
17.  Daily limits block      -> trades_today >= 2 OR losses >= 2
                                OR daily DD <= -3%, return
18.  Scan watchlist loop (MAX 1 ENTRY PER SCAN):
        For each symbol:
          - Skip if already holding / pending
          - Skip if leveraged ETF (TQQQ, SQQQ, SOXL, ...)
          - Skip if correlated with existing position or same-scan entry
          - Fetch daily bars (need >= 60)
          - Get-SwingBestSignal (highest-confidence valid setup)
          - Confidence floor: >= 75% (>= 85% in NEUTRAL)
          - Validate-Trade (R:R >= 3.0, sizing, BP, edge multiplier)
          - Submit GTC bracket, strategy tag in client_order_id
          - Increment trades_today, BREAK (one entry per scan)
19.  Save final state
```

The flow is **idempotent and recovery-safe**: any single step can fail without corrupting state.

---

## 3. The Four Pillars of Discipline

### Pillar 1: Regime Awareness
The PRIMARY trend decides direction. SPY daily EMA20/50 alignment gates longs
vs shorts; VIX scales size. A breakout long in a BEAR primary trend is never
taken, no matter how clean the chart.

### Pillar 2: Daily Loss Limits

| Limit | Default | Triggers |
|-------|---------|----------|
| `max_trades_per_day` | 2 | No more entries — swing entries are rare by design |
| `max_losses_per_day` | 2 | Day done — no revenge trading |
| `max_daily_drawdown_pct` | -3.0% | Day done — preserve capital |

`equity_at_open` is captured on the first scan of each ET day so drawdown has a stable reference.

### Pillar 3: Edge-Based Sizing
Adaptive position sizing from real win-rate data in memory (per strategy).
Hard cap at 1.5% risk. Cold-start multiplier 0.75x until a strategy has 5 trades.

### Pillar 4: Catalyst Awareness
The screener biases toward names with active news cycles, sector heat, and
earnings run-ups. Hard-reject anything within ±2 days of earnings — a binary
event can gap straight through a swing stop.

---

## 4. Swing Regime Detection

`Get-SwingRegime` in `alpaca_regime.ps1` — classifies the **primary trend**
from SPY daily bars (fetched once per scan, ~170 trading days).

```
BULL     close > EMA20 > EMA50      longs on, size 1.00x
NEUTRAL  close > EMA50, EMAs mixed  longs on, size 0.75x
BEAR     close < EMA20 < EMA50      SHORTS on, longs off, size 0.75x
RANGING  chopping around EMA50      both sides weak, size 0.60x
```

### VIX Overlay (external fear gauge)

Fetched once per scan from Yahoo Finance (free, no key). Stacks multiplicatively
on the regime multiplier:

```
VIX > 40   size x0.25   (PANIC)
VIX > 30   size x0.40   (HIGH)
VIX > 25   size x0.60   (elevated)
else       no change
```

Falls back gracefully — if Yahoo errors, the bot trades on the daily regime alone.

### Effects
- `BEAR` → long strategies return invalid; short mirrors (BRKDN/RALLYF) become eligible.
- `NEUTRAL` → confidence floor raised from 75 to 85.
- All regimes → `SizeMult` flows into position sizing.

The old intraday 5-min regime classifier (`Get-MarketRegime`) still exists and
runs when `scan_mode != "swing"`.

---

## 5. Strategy Engine (Swing Setups)

`alpaca_swing_signals.ps1`. Two strategies, each with a short mirror. All
operate on daily bars with today's partial bar as the trigger and **completed
prior days only** as the baseline (lookback ranges never include the bar that
triggers them).

### Shared geometry — the fix that motivated the pivot

```
Stop   = 2.0 x ATR(14, daily)   -- typically 3-5% from entry: OUTSIDE noise
Target = 3.5R                    -- needs days, and now has days
Hold   = 2-10 days (12-day hard time stop)
```

Breakeven win rate at 3.5R is ~22%. The old day-trade geometry needed ~29%
and structurally delivered 12%.

### 5a. BRKOUT — Daily Breakout (long)

```
Trigger : today's price > highest HIGH of the prior 20 completed days
Regime  : blocked in BEAR
Stop    : entry - 2.0 x ATR
Target  : entry + 3.5 x risk
```

**Confidence build (starts at 50):**
- +20 volume pace ≥ 1.5x (pace-adjusted for time of day) / +10 if ≥ 1.0x
- +10 fresh break (≤ 0.5 ATR beyond the level) / -15 if extended > 1.5 ATR (chasing)
- +15 relative strength vs SPY ≥ +3% over 20 days / +5 if ≥ +1% / -10 if < -2%
- +10 EMA20 > EMA50 (trend already aligned)

### 5b. PULLBK — Daily EMA Pullback (long)

```
Trend   : EMA20 > EMA50 AND prior close > EMA50 (established uptrend)
Trigger : a low touched the EMA20 zone within the last 3 days
          AND today's price reclaims above EMA20
Regime  : blocked in BEAR
Stop    : max(entry - 2.0 x ATR, EMA50 - 0.25 x ATR)  -- the tighter
          (reject the setup if implied risk > 3 ATR: too sloppy)
Target  : entry + 3.5 x risk
```

**Confidence build (starts at 50):**
- +15 trend quality (EMA20-EMA50 separation ≥ 1 ATR) / +8 if ≥ 0.4 ATR
- +10 RSI(14) in 40-60 (healthy reset, not a broken trend)
- +15 / +5 relative strength vs SPY (as above)
- +5 today's candle is green (buyers showed up)

### 5c. BRKDN — Daily Breakdown (short) — BEAR regime ONLY

Mirror of BRKOUT: today's price < lowest LOW of the prior 20 completed days.
Stop = entry + 2 ATR. RS bonus inverts (weakest names fall hardest).

### 5d. RALLYF — Failed Rally (short) — BEAR regime ONLY

Mirror of PULLBK: downtrend (EMA20 < EMA50), price rallied into the EMA20
zone within 3 days and got rejected back below it today.

### Selection

`Get-SwingBestSignal` evaluates both strategies and returns the
highest-confidence valid one. **Valid if:** confidence ≥ 75 (85 in NEUTRAL)
AND R:R ≥ 3.0 — both enforced again in `Validate-Trade`.

### Volume pace (time-of-day adjustment)

Today's volume is partial during the session. Pace = today's cumulative volume
÷ (20-day average × fraction of session elapsed). Pace > 1.0 genuinely means
"above average participation" at any clock time.

---

## 6. Risk & Position Sizing

`alpaca_risk.ps1` — every entry must pass `Validate-Trade`.

### Position Sizing Formula

```
effective_risk_pct = base_risk_pct * edge_multiplier * regime_multiplier
                     (capped at 1.5%; under 0.1% blocks the trade)

max_dollar_risk    = equity * (effective_risk_pct / 100)
risk_per_share     = |entry - stop|        # now 2 ATR -> larger, so FEWER
shares             = floor(max_dollar_risk / risk_per_share)   # shares: gap-resistant

# Buying power cap
max_position_value = (buying_power / max_positions) * 0.80
shares             = min(shares, floor(max_position_value / entry))
```

Wider stops mean smaller positions for the same dollar risk — this is the
gap-survival property. A -8% overnight gap through a 4% stop on a small
position is painful; on an oversized day-trade position it's lethal.

### Strategy Edge Multipliers

From `memory.strategy_stats[strategy].win_rate` (keys now BRKOUT / PULLBK / BRKDN / RALLYF):

| Sample size | Win rate | Multiplier |
|-------------|----------|-----------:|
| < 5 trades | — | 0.75x (cold start) |
| ≥ 5 | ≥ 60% | 1.25x |
| ≥ 5 | 45–60% | 1.00x |
| ≥ 5 | 35–45% | 0.65x |
| ≥ 5 | < 35% | 0.40x |

### Validation Rejects

| Check | Threshold |
|-------|-----------|
| R:R | < 3.0 |
| Buying power | required > available |
| Position count | ≥ 3 |
| Confidence | < 75% (< 85% NEUTRAL) |
| Sizing | 0 shares after multipliers |

---

## 7. The Self-Learning Loop

`alpaca_ticker_memory.json` — updated after every closed trade by
`Sync-ClosedTrades` (handles **both directions**: buy-entry and sell-entry
brackets, with direction-aware PnL).

### Per-Ticker Stats
trades / wins / losses / total_pnl / win_rate / composite score (0.1–3.0) /
consecutive-loss streak / per-strategy tallies / last_trade / added_count.

### Global Rollups
```
strategy_stats : { "BRKOUT": {...}, "PULLBK": {...}, "BRKDN": {...}, ... }
hour_stats     : ET-hour buckets (less relevant in swing mode; kept for audit)
regime_stats   : reserved, fills as trades close under tagged regimes
```

### Feedback paths
1. **Sizing** — `strategy_stats` drives the edge multiplier directly.
2. **Screener bias** — per-ticker score adds ±0.8 to candidate scoring;
   4+ consecutive losses on a name suppresses it.
3. Legacy day-trade stats (EMA/VWAP keys, GUID keys from the pre-tagging era)
   remain in the file as history; swing strategies start cold on purpose.

---

## 8. Dynamic Screener

`alpaca_screener.ps1` — rebuilds the watchlist once per ET day at/after 10:00 AM.
Unchanged by the swing pivot except in what happens downstream of it.

- **Pool:** ~60-name curated universe + Alpaca most-actives + top movers + news catalysts (~80–120 candidates/day)
- **Scoring:** price sweet spot, pace-adjusted RVOL, gap size, range, momentum, news cycle ±lean, earnings run-up, memory score
- **Hard rejects:** leveraged/inverse ETFs (21 tickers), price <$10 or >$500, earnings within 2 days, RVOL < 0.8, dead range
- **Cycle overlay:** news acceleration, sector heat vs SPY, hot-theme keywords, pre-market strength → Tier 1/2/3 prioritization
- **Selection:** SPY + QQQ anchors + top scorers up to 12, memory-proven names bumped in
- **Self-heal:** a ≤2-ticker list triggers a re-run on the next scan

High-RVOL gappy names are exactly where multi-day moves start, so the screener
feeds swing entries well despite being built in the day-trade era.

### Correlated Ticker Groups

Never two bets on the same underlying (QQQ/TQQQ/SQQQ, SPY/SPXL/SPXS/UPRO/SDS/SH,
IWM/TNA/TZA, SOXX/SOXL/SOXS, GLD/NUGT/DUST/JNUG/JDST) — checked against open
positions AND same-scan entries.

---

## 9. News & Earnings Catalysts

### News (`alpaca_news.ps1`)
Alpaca `/v1beta1/news`, 24h lookback, 50-headline cap. Per-ticker mention
tally + keyword bull/bear lexicon → lean. Feeds candidate pool and scoring;
does not gate direction.

### Earnings (`alpaca_earnings.ps1`)
Nasdaq public calendar, 14 days forward, 24h cache TTL, 4h failure back-off.

### TrumpMarketSentinel (`alpaca_trump_sentinel.ps1`)
Runs every scan cycle, before the market-open gate (news doesn't wait for
9:30 ET). Scans the same Alpaca news feed for headlines matching a
Trump/administration/policy keyword lexicon (tariffs, executive orders,
defense contracts, export controls, etc.) tagged against a small watchlist
(`trump_sentinel_watchlist`, default DJT/PLTR/LMT/INTC/RTX/NOC/GD/TSM/MSTR/BA).
Cross-checks each watchlist name for unusual relative volume (≥2x 20-day avg)
or daily price move (≥3%) via `Get-DailyBars` + `Get-RelativeVolume`.

Alerts print in a fixed format (Event / Affected Tickers / Impact Analysis /
Recommended Action) and are appended to `trump_sentinel_log.json`, which CI
persists like state/memory so headline dedup survives across ephemeral
runners. `RecommendedAction` (Monitor/Buy Dip/Sell/Avoid) is a heuristic
label for a human to act on — **this module never places orders**, same as
the plain news catalyst score.

Known limit: only Alpaca's licensed news wire is wired in — there is no live
X or Truth Social feed, so headline-only catalysts (a raw social post with no
wire pickup yet) won't be caught until financial media covers it.

### Pre-Market Movers Preview (`alpaca_premarket.ps1`)
Runs once per trading day between 06:00 and 09:30 ET (self-gated inside the
scan cycle; `-PreMarket` switch or the `premarket` workflow input runs it
on demand). Combines the three earliest public signals of who moves today:

1. **Scheduled catalysts** — earnings within the next 5 days for the
   sentinel + config watchlists (from the cached Nasdaq calendar). The only
   genuine "advance knowledge" that legally exists.
2. **Pre-market gaps** — snapshot price vs yesterday's close, from 4:00 AM
   ET. IEX pre-market prints are sparse, so gaps are indicative.
3. **Overnight news** — 16h lookback covering post-close through pre-open,
   including the top 5 off-watchlist mention leaders as FYI.

Output prints in the scan log and appends to `premarket_log.json` (persisted
by CI, last 30 previews). Advisory only — never places orders, and it is
NOT prediction: it surfaces public information early, nothing more.

```
days_to_earnings <= 2           -> HARD REJECT (gap risk through stops)
days_to_earnings in (2, 10]     -> +1.0 screener score (run-up drift)
```

The blackout matters MORE in swing mode: a position held a week will often
cross an earnings date that was 8 days out at entry. (Known gap: the bot does
not yet force-exit an open position before earnings — see §13.)

---

## 10. Order Execution & Management

### GTC Bracket Orders

Every entry is an Alpaca bracket — parent limit + TP limit + SL stop — with
`time_in_force: "gtc"` so all three legs persist across sessions.

```json
{
  "symbol": "NVDA", "qty": "9", "side": "buy", "type": "limit",
  "time_in_force": "gtc", "limit_price": "205.10",
  "order_class": "bracket",
  "take_profit": { "limit_price": "233.80" },
  "stop_loss":   { "stop_price":  "196.90" },
  "client_order_id": "BRKOUT_NVDA_143052"
}
```

The strategy tag (BRKOUT/PULLBK/BRKDN/RALLYF — no underscores) is parsed back
by `Sync-ClosedTrades` for per-strategy learning.

### Break-Even Stop at +2R

When unrealized P&L ≥ 2 × original risk (`|entry − stop| × |qty|` — Abs() so
shorts work), the stop leg is PATCHed to entry ± 0.1%. From then on the trade
can only scratch or win. Idempotent: a stop already at/past entry is never
moved again. Works identically on GTC legs.

### Time Stop (12 trading days)

`Close-StalePositions`: entry fill date found from closed orders; weekday count
≥ `hold_days_max` → cancel legs, market-close the position. A swing trade that
hasn't resolved in 12 days is dead capital.

### Stale Entry Reaper

`Cancel-StaleEntries`: an unfilled GTC parent bracket from a prior day means
the market rejected the level — cancel it rather than letting it fill days
later into a different tape.

### Protective Stop Fallback

A position found with NO stop leg gets one planted immediately: breakeven stop
if profitable, max-loss stop (entry ± 2%) if under water.

### Sync-ClosedTrades (the reconciler)

Runs before the market gate every scan. 7-day lookback, `recorded_exits`
dedup, **direction-aware**: accepts buy AND sell parents, matches the opposite-
side filled leg, computes PnL as (exit−entry)×qty for longs and (entry−exit)×qty
for shorts.

### Removed in swing mode
- **3:45 PM EOD close** — swing positions are SUPPOSED to hold overnight.
  (Function retained for day mode.)
- **Midday pause** — meaningless for daily-bar signals.

---

## 11. Configuration Reference

`alpaca_config.json`:

```
api_key / api_secret        "FROM_ENV"   # never hard-coded
paper_trading               true
scan_mode                   "swing"      # the master switch; "day" restores old engine
hold_days_max               12           # time-stop threshold (trading days)

max_watchlist               12
max_risk_pct                1.0          # % equity risked per trade
min_rr_ratio                3.0          # swing minimum (was 2.5)
max_positions               3

max_trades_per_day          2            # swing entries are rare by design
max_losses_per_day          2
max_daily_drawdown_pct      -3.0
adaptive_sizing             true
min_trades_for_edge         5

news_catalyst_enabled       true   (24h lookback, 2+ mentions)
earnings_enabled            true   (blackout 2d, run-up 10d)
screener_enabled            true
cycle_screener_enabled      true

# Day-mode-only settings (ignored in swing mode):
orb_minutes / orb_cutoff / no_trade_before / no_trade_after /
midday_pause_start / midday_pause_end
```

Swing entry window is hard-coded: **09:50–15:30 ET** (post-auction settle to
pre-close cutoff).

---

## 12. State & Memory Files

| File | Purpose |
|------|---------|
| `alpaca_state.json` | Daily counters, watchlist, recorded_exits dedup, equity baseline |
| `alpaca_ticker_memory.json` | Long-term learning: per-ticker + per-strategy + hour/regime rollups |
| `earnings_calendar.json` | Nasdaq cache (24h TTL) |
| `pending_approval.json` | Only with `require_approval: true` (off) |
| `alpaca_dashboard.html` | Regenerated each scan, uploaded as Actions artifact |

All persisted to the repo by the workflow after every run (`[skip ci]` commits).

---

## 13. Failure Modes & Known Limits

### Things That Will Stop the Bot

| Condition | Symptom | Fix |
|-----------|---------|-----|
| GitHub Actions minutes exhausted | Runs stop | Wait for monthly reset |
| Alpaca key revoked | Every API call fails | Rotate repo secrets |
| cron-job.org paused | No triggers | Re-enable |
| Yahoo blocks VIX endpoint | Size mult uses regime only | Cosmetic — keeps trading |
| Nasdaq blocks earnings UA | Stale calendar | Keeps trading, no earnings logic |

### Known Gaps (deliberate, documented)

- **No pre-earnings forced exit.** Entry blackout exists, but a position held
  into week 2 can cross an earnings date. Next planned improvement.
- **No trailing stop after +2R.** BE-then-target only; ATR trailing is the
  natural upgrade once sample size justifies it.
- **No partial exits.** Bracket-leg rebalancing race; deferred.
- **Time stop counts weekdays, not holidays.** Fires a day early on holiday
  weeks. Harmless.
- **regime_stats empty** until swing trades close and tag it.

### Things That Look Like Bugs But Aren't

- "Market closed -- waiting" off-hours — correct.
- "Outside swing entry window (09:50-15:30 ET)" — correct.
- **Positions held overnight / over weekends — THE POINT of swing mode.**
- Zero entries for days at a time — correct; 20-day breakouts and clean
  pullbacks are rare. Two entries a week is a normal pace.
- "[STALE] unfilled entry from <date> -- canceling" — correct reaping.
- "[HOLD] day 4/12 of max hold" — the time-stop counter, informational.
- Old EMA/VWAP/GUID keys in memory — day-trade era history, ignored by
  swing-strategy edge lookups.

---

## 14. Module Map

| File | Purpose |
|------|---------|
| `alpaca_bot.ps1` | Orchestrator — Run-Scan lifecycle, swing/day branch, limits, time-stop, stale reaper |
| `alpaca_swing_signals.ps1` | **Swing engine: BRKOUT / PULLBK / BRKDN / RALLYF** |
| `alpaca_signals.ps1` | Day-mode engine (ORB / VWAP / EMA + shorts) — dormant |
| `alpaca_client.ps1` | Alpaca REST wrapper; `Get-DailyBars`, GTC bracket support |
| `alpaca_indicators.ps1` | EMA, RSI, MACD, ATR, VWAP, swing high/low, RVOL |
| `alpaca_risk.ps1` | Sizing + R:R + buying power + validation |
| `alpaca_regime.ps1` | `Get-SwingRegime` (daily) + `Get-MarketRegime` (5-min, dormant) + VIX |
| `alpaca_screener.ps1` | Watchlist, memory, edge lookups, correlation groups, `Sync-ClosedTrades` |
| `alpaca_news.ps1` | News catalysts + sentiment lexicon |
| `alpaca_earnings.ps1` | Nasdaq earnings cache |
| `alpaca_trump_sentinel.ps1` | TrumpMarketSentinel — Trump/policy headline + volume watch, advisory alerts |
| `alpaca_premarket.ps1` | Pre-market movers preview — gaps, upcoming earnings, overnight news (advisory) |
| `alpaca_cycle_screener.ps1` | Cycle-leader overlay (news accel, sector heat, themes) |
| `alpaca_dashboard_html.ps1` | HTML dashboard generator |
| `.github/workflows/alpaca_bot.yml` | Trigger + runner + state persistence |

---

## 15. History: the Day-Trading Era

For the record, because the lesson is the foundation of the current design:

- **May 14 – June 12, 2026:** 25 closed intraday trades, 3 wins (12%), ≈ -$3,600 realized.
- Eight discipline improvements (leveraged-ETF ban, correlation groups,
  1-entry-per-scan, cap 5→3, confidence 65→75, stops 0.15→0.50 intraday ATR,
  BE +1R→+2R, EOD time-stop) made the bot *safer* but couldn't fix the geometry.
- Three critical bugs found and fixed along the way: short positions invisible
  to BE management (negative qty), short exits never recorded to memory
  (buy-side-only sync), and a 5m-bar gate that locked ORB out of its own window.
- The post-mortem conclusion: **stop distance must be sized to the noise of the
  holding period the target requires.** A 2.5R target needs hours; hours of
  noise exceed a 5-minute ATR stop. Day trading on free 10-minute-cadence
  infrastructure was structurally unwinnable. Swing trading on daily bars is
  the same machine pointed at a game it can actually win.

**Validation gates before real money** (restated from the go-live analysis):
≥30 closed swing trades, ≥35% win rate (breakeven is ~22% at 3.5R), profit
factor ≥1.3, 14 clean days without critical code fixes, ≤2 drawdown-cap hits.
Expected timeline: 6–10 weeks from June 12, 2026.

---

## Operating Philosophy (the part that matters)

This bot doesn't try to be brilliant. It tries to be **disciplined**, **patient**, and **honest**.

- It doesn't trade noise. Its stops live where noise can't reach.
- It doesn't need to be right often. At 3.5R, 1 win pays for 3 losses.
- It doesn't double down after a loss. It stops.
- It doesn't trade through earnings. It steps aside.
- It doesn't fight the primary trend. SPY's daily chart decides direction.
- It doesn't water dead plants. Twelve days without resolution = next idea.
- It doesn't lie to itself about win rate. The memory file is the truth.

**Edge emerges from geometry + process discipline + survival, not from prediction.**

---

*Last updated: 2026-06-12 — covers commits through `aff3adc` (swing pivot).
Previous day-trading edition retired the same day; see §15 for why.*
