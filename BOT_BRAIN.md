# Alpaca Day Trading Bot — The Brain

> Complete reference for how this bot thinks, decides, sizes, learns, and survives.
> Read this top-to-bottom and you'll know every rule it follows and every fact it remembers.

---

## TL;DR (60 seconds)

A self-learning, paper-trading bot for U.S. equities. Lives entirely in the cloud (cron-job.org + GitHub Actions + Alpaca paper API). Scans a dynamic watchlist every 10 minutes during market hours, only takes setups that pass a 4-pillar discipline check (regime + risk + catalyst + memory), and updates its own knowledge after every closed trade so the next decision is better than the last.

It is built like a disciplined junior analyst: small, repeatable edges + iron rules against revenge trading, sized adaptively based on what's actually been working.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [The Run-Scan Lifecycle](#2-the-run-scan-lifecycle)
3. [The Four Pillars of Discipline](#3-the-four-pillars-of-discipline)
4. [Market Regime Detection](#4-market-regime-detection)
5. [Strategy Engine](#5-strategy-engine-3-setups)
6. [Risk & Position Sizing](#6-risk--position-sizing)
7. [The Self-Learning Loop](#7-the-self-learning-loop)
8. [Dynamic Screener](#8-dynamic-screener)
9. [News Catalyst Detection](#9-news-catalyst-detection)
10. [Earnings Calendar](#10-earnings-calendar)
11. [Order Execution](#11-order-execution)
12. [Configuration Reference](#12-configuration-reference)
13. [State & Memory Files](#13-state--memory-files)
14. [Failure Modes & Known Limits](#14-failure-modes--known-limits)
15. [Module Map](#15-module-map)

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
|  - Regime classification (SPY 5m)      |
|  - Discipline gates (5 trades, 2L, DD) |
|  - Screener rebuild (10 AM ET)         |
|    -> news catalysts                   |
|    -> earnings calendar (Nasdaq)       |
|    -> Alpaca most-actives + movers     |
|  - Per-symbol scan:                    |
|    -> Fetch 1m + 5m IEX bars           |
|    -> ORB / VWAP / EMA signal eval     |
|    -> Validate (R:R, conf, sizing)     |
|    -> Auto-execute bracket order       |
+----------------+-----------------------+
                 |
                 +-> Alpaca paper API   (orders, positions, bars, snapshots)
                 +-> Alpaca News API    (catalyst tickers)
                 +-> Nasdaq calendar    (earnings dates)
                 +-> git commit         (state + memory + dashboard back to repo)
```

**Compute & data are 100% cloud-based.** No local machine required.

| Service | Role | Free? |
|---------|------|-------|
| cron-job.org | Triggers every 10 min | yes |
| GitHub Actions | Runs the bot scan | yes (~2k min/month) |
| Alpaca paper | Trades + market data + news | yes |
| Nasdaq public calendar | Earnings dates | yes (no signup) |
| Git repo | State + memory persistence | yes |

---

## 2. The Run-Scan Lifecycle

Every 10 minutes, `Run-Scan` executes in this exact order:

```
01.  Print header (UTC time, mode, interval)
02.  Daily counter reset    -> if ET date changed since last scan,
                                wipe trades_today / wins / losses / pnl_today
03.  Sync-ClosedTrades       -> 7-day lookback, dedup by recorded_exits,
                                update wins / losses / pnl_today / memory
                                (runs BEFORE market gate so closes are captured
                                 even after-hours)
04.  Market-open gate        -> if closed, save state and return
05.  Trading-window check    -> if outside 09:45-15:00 or in 11:30-13:00 pause,
                                print warning but continue (still updates state)
06.  State backward-compat   -> Add new fields to old state.json if missing
07.  Capture equity_at_open  -> Once per ET day; drawdown baseline locked
08.  Get-MarketRegime        -> BULL_TREND / BEAR_TREND / VOLATILE /
                                RANGING / NEUTRAL + size multiplier
09.  Watchlist refresh       -> If date != today OR list <= 2 tickers,
                                AND clock >= 10:00 AM ET:
                                  - Refresh earnings calendar (24h TTL)
                                  - Get-DynamicWatchlist (news + screener)
10.  Account summary         -> Equity, BP, positions, today's stats
11.  Display open positions  -> Per-position unrealized P&L
12.  Max-positions check     -> If full, monitor-only, return
13.  Trading-window block    -> If outside window, return
14.  BEAR regime block       -> If BEAR_TREND, no new entries, return
15.  Daily limits block      -> If trades_today >= 5 OR losses >= 2
                                OR daily DD <= -3%, return
16.  Scan watchlist loop:
        For each symbol:
          - Skip if already holding / pending
          - Fetch 1m bars (need >= 20) + 5m bars (need >= 10)
          - Get-BestSignal (highest-confidence valid setup)
          - If NEUTRAL regime, require confidence >= 80
          - Validate-Trade (R:R, sizing, BP, edge multiplier)
          - Write trade card to log
          - Submit bracket order with strategy tag in client_order_id
          - Increment trades_today
17.  Save final state
```

The flow is **idempotent and recovery-safe**: any single step can fail without corrupting state.

---

## 3. The Four Pillars of Discipline

These are non-negotiable. They run on every entry decision, before any signal even gets evaluated.

### Pillar 1: Regime Awareness
Don't trade every setup the same way. Same ORB breakout = gold in calm uptrend, trap in VIX spike. The bot classifies the market into 5 regimes and adjusts size + behavior accordingly.

### Pillar 2: Daily Loss Limits
Three hard stops that end the day immediately if breached:

| Limit | Default | Triggers |
|-------|---------|----------|
| `max_trades_per_day` | 5 | No more entries |
| `max_losses_per_day` | 2 | Day done — no revenge trading |
| `max_daily_drawdown_pct` | -3.0% | Day done — preserve capital |

`equity_at_open` is captured on the first scan of each ET day so drawdown has a stable reference.

### Pillar 3: Edge-Based Sizing
Adaptive position sizing pulled from real win-rate data in memory. Hard cap at 1.5% risk to prevent compounding overconfidence.

### Pillar 4: Catalyst Awareness
Don't trade noise. Bias toward stocks with active news cycles or in earnings run-up windows. Hard-reject names within ±2 days of earnings (binary event = unpredictable).

---

## 4. Market Regime Detection

`alpaca_regime.ps1` — runs once per scan, classifies SPY 5-min state.

### Inputs (computed from SPY 5-min bars)
- **EMA 9** and **EMA 20**
- **ATR(14)** as % of current price (intraday VIX proxy)
- **60-min momentum** (% change over last 12 5-min bars)
- **EMA alignment** (bullAligned, bearAligned booleans)

### Classification Decision Tree

```
if volatility > 0.25%                                   -> VOLATILE     (size 0.50x)
elif close<EMA9<EMA20  AND  60-min < -0.20%             -> BEAR_TREND   (size 0.00x = skip)
elif close>EMA9>EMA20  AND  60-min > +0.20%             -> BULL_TREND   (size 1.00x)
elif |60-min| < 0.15%  AND  EMAs not aligned            -> RANGING      (size 0.75x)
else                                                    -> NEUTRAL      (size 0.85x)
```

### Output
```
Regime          : <one of 5 strings>
Volatility      : ATR as % of price (e.g. 0.052%)  -- intraday volatility
TrendStrength   : signed 60-min move % (e.g. +0.78%)
SizeMult        : multiplier applied to base risk in Get-PositionSize
PreferTrend     : bool, hints to strategy selection
PreferReversion : bool, hints to strategy selection
VIX             : actual ^VIX level from Yahoo Finance, or null if unavailable
HighVol         : bool flag, true when VIX > 25
Reason          : human-readable explanation logged to console
```

### VIX Overlay (external fear gauge)

After the intraday regime is classified, the SPY ATR-based size multiplier is
further reduced by the actual ^VIX level. VIX measures S&P 500 30-day implied
volatility — institutional hedging spikes show up in VIX before they show up
in SPY's intraday range, so this is a leading-indicator on top of our
lagging-indicator ATR%.

Fetched once per scan from Yahoo Finance's unofficial `^VIX` endpoint (free,
no key). Falls back to null on Yahoo failure -- bot keeps trading on the
intraday regime alone.

```
VIX > 40        size multiplier *= 0.25   (PANIC)
VIX > 30        size multiplier *= 0.40   (HIGH)
VIX > 25        size multiplier *= 0.60   (elevated)
13 <= VIX <= 25 no change                 (normal)
VIX < 13        no change but logged       (complacency, watch for spike)
```

These stack with the regime multipliers, so e.g. a NEUTRAL regime (0.85x) on
a VIX=32 day becomes 0.85 * 0.40 = 0.34x effective.

### Effects
- `BEAR_TREND` → entry loop returns early. **No new longs ever.**
- `VOLATILE` → all entries sized at 50% of baseline.
- `NEUTRAL` → confidence threshold raised from 65 to 80 to require higher conviction.
- `BULL_TREND` / `RANGING` → standard processing, but size multiplier applied.

---

## 5. Strategy Engine (3 setups)

All three strategies are evaluated for every symbol every scan. The highest-confidence valid one wins.

### 5a. ORB — Opening Range Breakout

**Setup window:** 9:45 – 10:45 ET only. Stale signals after that get hard-rejected so the bot never chases an old breakout.

```
ORB range = high/low of first 15 min of the session
Long entry  : Close > ORB high on a 1-min bar AND prev close <= ORB high
Short entry : Close < ORB low  on a 1-min bar AND prev close >= ORB low
Stop        : Opposite end of ORB range (+/- 0.01)
T1          : Entry +/- 1.0x range
T2          : Entry +/- 2.0x range
```

**Confidence build (starts at 50):**
- +20 if RelVol >= 1.5x (volume surge)
- +15 if RSI in 50-70 (long) or 30-50 (short)
- +15 if candle direction confirms (green for long, red for short)

**Valid if:** `Confidence >= 65 AND R:R >= 2.5`

### 5b. VWAP Bounce

5-minute chart. Bullish reversion to VWAP after a dip.

```
Trigger : prev bar low <= VWAP AND current bar close > VWAP
Stop    : min(prev.low, current.low) - 0.25 * ATR
T1      : entry + 2.5 * risk
T2      : entry + 4.0 * risk
```

**Confidence build (starts at 55):**
- +15 if price > EMA9 (uptrend confirmation)
- +15 if RSI rising AND prev RSI <= 45 AND current RSI <= 65
- +15 if RelVol >= 1.2x

**Valid if:** `Confidence >= 70 AND R:R >= 2.5`

### 5c. EMA Pullback

5-minute chart. Trend-continuation buy after pullback to 9 EMA.

```
Trend filter : price > EMA9 > EMA21
Trigger      : prev bar low <= EMA9 AND current close > EMA9 (bounce)
Stop         : EMA21 - 0.15 * ATR
T1           : entry + 2.5 * risk
T2           : entry + 4.0 * risk
```

**Confidence build (starts at 50):**
- +20 if RSI in 40-60 (healthy pullback zone)
- +10 if RSI turning up
- +10 if RelVol >= 1.2x
- +10 if current candle is green

**Valid if:** `Confidence >= 70 AND R:R >= 2.5`

### 5b-SHORT. VWAP Rejection

Mirror of VWAP Bounce. 5-minute chart. Bearish rejection back below VWAP.

```
Trigger : prev bar high >= VWAP AND current bar close < VWAP
Stop    : max(prev.high, current.high) + 0.25 * ATR
T1      : entry - 2.5 * risk
T2      : entry - 4.0 * risk
```

**Confidence build (starts at 55):**
- +15 if price < EMA9 (downtrend confirmation)
- +15 if RSI falling AND prev RSI >= 55 AND current RSI >= 35
- +15 if RelVol >= 1.2x
- +10 if HTF 15m BEARISH (alignment bonus)

**Valid if:** `Confidence >= 70 AND R:R >= 2.5`

### 5c-SHORT. EMA Pullback Short (Rejection)

Mirror of EMA Pullback. 5-minute chart. Trend-continuation short after rally fails at 9 EMA.

```
Trend filter : price < EMA9 < EMA21
Trigger      : prev bar high >= EMA9 AND current close < EMA9 (rejection)
Stop         : EMA21 + 0.15 * ATR
T1           : entry - 2.5 * risk
T2           : entry - 4.0 * risk
```

**Confidence build (starts at 50):**
- +20 if RSI in 40-60 (healthy bounce zone, not exhausted)
- +10 if RSI turning down
- +10 if RelVol >= 1.2x
- +10 if current candle is red
- +10 if HTF 15m BEARISH

**Valid if:** `Confidence >= 70 AND R:R >= 2.5`

### How the bot decides direction now

```
SPY in BULL_TREND  -> Most symbols 15m BULLISH -> longs eligible,  shorts hard-rejected
SPY in BEAR_TREND  -> Most symbols 15m BEARISH -> shorts eligible, longs  hard-rejected
SPY in RANGING     -> Mixed HTF per symbol     -> both directions possible
SPY in VOLATILE    -> All sizes halved
```

The decision is made **per symbol** by its own 15-min HTF bias, not by SPY's bias. A name with strong relative strength might still be a clean long even on a BEAR_TREND SPY day if its own 15m is BULLISH. This was always the way pros traded; now the bot does too.

### 5d. Higher Timeframe Bias Filter (HARD GATE in each strategy)

Multi-timeframe confluence check. A long setup against the 15-min downtrend is fighting the tape on a higher frame — and that's the #1 way day-trade setups fail. **This is now a hard reject**, not a soft modifier.

```
Get-HigherTimeframeBias($symbol, "15Min"):
  Fetch last 50 x 15-min bars
  Compute EMA9 and EMA20
  BULLISH = close > EMA9 > EMA20
  BEARISH = close < EMA9 < EMA20
  NEUTRAL = mixed OR insufficient data (cautious default)
```

Each strategy applies the gate itself, immediately after detecting a setup but before computing confidence:

```
Long  signal + BEARISH HTF -> HARD REJECT (signal returned with Side="" and Valid=false)
Short signal + BULLISH HTF -> HARD REJECT
Long  signal + BULLISH HTF -> proceed, +10 confidence (aligned)
Short signal + BEARISH HTF -> proceed, +10 confidence (aligned)
Any signal   + NEUTRAL HTF -> proceed, no modifier (allowed but not rewarded)
```

Long-only strategies (VWAP Bounce, EMA Pullback) only check the BEARISH gate. ORB checks both because it can emit shorts.

**Why a hard gate and not a confidence modifier?**
The previous design subtracted 25 confidence on opposition, which still let high-confidence setups slip through against a clear trend. Pros never do this. The hard gate makes the rule absolute: *if the 15-min trend is against you, you don't take the trade — no matter how clean the lower-timeframe setup looks.*

Computed once per symbol in `Get-BestSignal` and passed to each strategy as a parameter. One API call per symbol, three filtered evaluations.

### Strategy Selection
`Get-BestSignal` fetches HTF once, passes it to all three strategies, collects any whose `Valid=true`, and returns the highest-confidence one. Ties don't occur in practice because the alignment bonuses differ across strategies.

---

## 6. Risk & Position Sizing

`alpaca_risk.ps1` — every entry must pass `Validate-Trade`.

### Position Sizing Formula

```
effective_risk_pct = base_risk_pct * edge_multiplier * regime_multiplier
                     (capped at 1.5%; under 0.1% blocks the trade)

max_dollar_risk    = equity * (effective_risk_pct / 100)
risk_per_share     = |entry - stop|
shares             = floor(max_dollar_risk / risk_per_share)

# Buying power cap
max_position_value = (buying_power / max_positions) * 0.80
shares_by_bp       = floor(max_position_value / entry)
shares             = min(shares, shares_by_bp)
```

### Strategy Edge Multipliers

Pulled from `memory.strategy_stats[strategy].win_rate`:

| Sample size | Win rate | Multiplier | Reason |
|-------------|----------|-----------:|--------|
| < 5 trades | — | 0.75x | Cold-start cautious |
| ≥ 5 | ≥ 60% | 1.25x | Proven edge |
| ≥ 5 | 45–60% | 1.00x | Marginal edge / baseline |
| ≥ 5 | 35–45% | 0.65x | Weak edge — cut size |
| ≥ 5 | < 35% | 0.40x | Negative edge — minimal |

### Validation Errors that Reject a Trade

| Check | Threshold |
|-------|-----------|
| R:R | < `min_rr_ratio` (default 2.5) |
| Buying power | Required > available |
| Position count | >= `max_positions` (default 3) |
| Confidence | < 65% (or < 80% if NEUTRAL regime) |
| Sizing | Returned 0 shares (regime or edge cut it to zero) |

Rejected trades log a `[REJECTED]` card with reasons. Approved trades log `[APPROVED]`.

---

## 7. The Self-Learning Loop

`alpaca_ticker_memory.json` — updated after every closed trade.

### Per-Ticker Stats
```
{
  "trades": int, "wins": int, "losses": int,
  "total_pnl": float, "avg_pnl": float, "win_rate": 0.0-1.0,
  "score": 0.1-3.0,              # composite memory score
  "consecutive_losses": int,     # streak penalty
  "best_strategy": "ORB|VWAP_BOUNCE|EMA_PULLBACK",
  "strategy_wins":    { strategy_name: int },
  "strategy_trades":  { strategy_name: int },
  "last_trade": iso8601,
  "added_count": int             # times screener picked it
}
```

### Global Rollups (the brain)
Three new aggregates updated atomically on every closed trade:

```
strategy_stats : { "ORB":         {trades, wins, losses, total_pnl, win_rate, avg_pnl},
                   "VWAP_BOUNCE": {...},
                   "EMA_PULLBACK":{...} }

hour_stats     : { "10": {...}, "11": {...}, ... 15": {...} }   # ET hour buckets

regime_stats   : { "BULL_TREND": {...}, "RANGING": {...}, ... }
```

### How Memory Feeds Back into Decisions

1. **Sizing** — `strategy_stats` directly drives `Get-StrategyEdge` multiplier.
2. **Screener bias** — per-ticker `score` adds ±0.8 to candidate scoring.
3. **Future** — `hour_stats` and `regime_stats` will gate trades once data accumulates (hooks built, filtering not yet active).

### Memory Score Composition
The per-ticker 0.1–3.0 score blends three signals (only after 3+ trades):

```
score starts at 1.0
+0.6 if WR >= 70%        -0.4 if WR < 35%
+0.4 if WR >= 60%        -0.6 if WR < 25%
+0.2 if WR >= 50%
+0.3 if avg_pnl >= $100  -0.3 if avg_pnl <= -$80
+0.15 if avg_pnl >= $40  -0.15 if avg_pnl <= -$40
-0.5 if consecutive_losses >= 4
-0.2 if consecutive_losses >= 2
clamped to [0.1, 3.0]
```

---

## 8. Dynamic Screener

`alpaca_screener.ps1` — rebuilds the watchlist once per ET day, at or after 10:00 AM.

### Why 10:00 AM?
At 9:31 AM volume and range data are too thin to score meaningfully. RVOL math needs ≥30 min of price action.

### Candidate Pool Sources

```
1. Curated universe of ~60 names (mega-cap tech, semis, finance, energy,
                                  healthcare, consumer, sector ETFs)
2. Alpaca most-actives API (top 30 by volume)
3. Top movers API (gainers + losers)
4. News catalysts (tickers with >= 2 mentions in 24h)
```

All four are merged and de-duplicated. Result: typically 80-120 candidates per day.

### Scoring (Score-Candidate)

```
+0.5  Price in $20-$300 sweet spot
+3.0  RVOL >= 4.0x  (EXTREME)              [time-of-day adjusted]
+2.0  RVOL >= 2.5x  (HIGH)
+1.0  RVOL >= 1.5x  (elevated)
+2.0  |gap| >= 5.0% (LARGE)
+1.2  |gap| >= 2.0%
+0.5  |gap| >= 0.8%
+1.5  intraday range >= 3.0% (HIGH)
+1.0  intraday range >= 1.5%
+0.3  intraday range >= 0.5%
+0.1  intraday range >= session-floor (early session leniency)
+0.8  |change| >= 3.0% (directional momentum)
+1.5  news cycle active (>= 2 mentions in 24h)
+0.5  headlines lean BULL
-0.5  headlines lean BEAR
+1.0  earnings in 3..10 days (run-up window)
+1.0  memory score >= 1.5  (proven)
+0.3  memory score >= 1.0
-0.8  memory score <= 0.5  (poor)

HARD REJECTS (return null):
  price < $10 or > $500
  earnings within 2 days (blackout)
  RVOL < 0.8
  intraday range below session-adjusted floor
```

### Time-of-Day Adjusted RVOL

The single most important screener fix. Without adjustment, RVOL compares today's *partial* volume to yesterday's *full* volume — rejecting every candidate at 10 AM.

```
session_progress = elapsed_minutes_since_open / 390 (total session minutes)
expected_volume  = prev_day_full_volume * session_progress
RVOL             = today_cumulative_volume / expected_volume
```

Now `RVOL > 1.0` genuinely means "above-pace" at any clock time.

### Cycle Leader Detection (overlay on the base screener)

A separate module (`alpaca_cycle_screener.ps1`) adds five "is this institutional accumulation, not noise?" signals on top of the base candidate scoring. Layered, not replacement.

**Five cycle signals:**

```
1. News Acceleration   24h mentions > 1.5x prior 24h AND >= 3 fresh
                       (or 4+ fresh today with zero yesterday = brand-new cycle)
                       Bonus: +2.5 (+1.0 bull lean, -0.5 bear lean)

2. Sector Heat         Sector ETF (XLK/XLF/XLE/etc.) day change vs SPY
                       Outperforming SPY by >=1% today  -> +2.0
                       Underperforming SPY by >=1% today -> -1.0

3. Theme Match         Headlines mention any "hot theme" keyword
                       (AI, semiconductor, GLP-1, tariff, EV, quantum, ...)
                       Bonus: +1.5

4. Pre-Market Strength Fetch IEX 5-min bars from 4 AM ET
                       Gap >= 5% with >= 100k vol      -> strength 3.0
                       Gap >= 3% with >= 50k vol       -> strength 2.0
                       Gap >= 1.5%                      -> strength 1.0
                       Free-tier IEX pre-market is sparse -- best effort

5. Technical Coiling   STUB. Real impl needs 252 daily bars per ticker.
                       Framework hooks wired and ready to enable.
```

### Watchlist Tiering

After scoring, each candidate is assigned a tier so the scan loop hits the highest-conviction setups first (matters most on days with daily limits):

```
Tier 1  HIGH CONVICTION
        News accelerating AND (premarket strong OR sector hot OR memory >= 1.5)

Tier 2  STANDARD
        At least one strong catalyst (news accel, premkt, hot sector, OR theme)

Tier 3  FALLBACK
        Memory-proven only (use sparingly on quiet days)
```

Final selection sorts by **Tier ascending, then Score descending**. The screener output table now shows the tier column so the prioritization is auditable.

### Final Selection

```
1. Sort candidates by score descending
2. Always include SPY + QQQ as core anchors
3. Add top (max_watchlist - 2) candidates by score
4. Bump in memory-proven tickers (score >= 1.3, trades >= 3)
   if there's room in the list
5. Record each selected ticker's added_count++ in memory
```

### Self-Heal

If today's screener somehow produced ≤2 tickers (data outage at run time, etc.), the *next* scan re-runs the screener even though `watchlist_date == today`. This prevents a bad single morning from killing the entire day.

---

## 9. News Catalyst Detection

`alpaca_news.ps1` — pulls headlines from Alpaca's `/v1beta1/news`.

### Fetch
```
GET https://data.alpaca.markets/v1beta1/news
    ?start=<24h ago in UTC ISO>
    &limit=50
    &sort=DESC
```

Caps at 50 because that's Alpaca's hard max. `sort=DESC` (uppercase — case-sensitive).

### Tallying
Per ticker, count mentions across all headlines + summaries in the lookback window. Drop crypto pairs and 5+ char symbols.

### Keyword Sentiment
A compact bull/bear lexicon scores each headline + summary the ticker appears in:

```
BULL : beats, raises, upgrade, outperform, surge, jump, soar, rally,
       breakthrough, partnership, acquire, buyback, dividend, wins,
       record, strong, exceed, tops, bullish, launch, expand, growth

BEAR : miss, cut, downgrade, underperform, plunge, drop, tumble,
       recall, lawsuit, sued, fraud, probe, investigation, SEC,
       restatement, warning, weak, decline, bearish, layoffs,
       bankruptcy, default, sell, reduce
```

Per-ticker sentiment score = sum across all headlines about it.

### Resolved Lean
- `Sentiment >= +2` → `bull`
- `Sentiment <= -2` → `bear`
- otherwise → `neutral`

### Effect on Screener
- Adds the ticker to the candidate pool even if not in the static universe
- Score `+1.5` for active cycle
- Score `±0.5` based on lean
- Lean does NOT change trade direction (bot is long-only) but does affect the threshold for taking longs on bear-leaning names

---

## 10. Earnings Calendar

`alpaca_earnings.ps1` — pulls from Nasdaq's free public calendar.

### Fetch
```
GET https://api.nasdaq.com/api/calendar/earnings?date=YYYY-MM-DD
    Headers: realistic Chrome UA + Origin + Referer
```

Walks 14 days forward, 250ms politeness delay between calls, 5s timeout per call.

### Failure Handling
Three layers of resilience:

1. **24h cache TTL** — successful fetch valid for a full day.
2. **4h attempt back-off** — even on failure, don't retry for 4 hours (prevents 70+s of timeouts per scan).
3. **Early abort** — if 3 dates in a row return empty before any data is collected, stop the loop.

### Cache Schema (`earnings_calendar.json`)
```json
{
  "last_refreshed": "<iso8601 of last successful refresh>",
  "last_attempted": "<iso8601 of last attempt, success or failure>",
  "events": [
    { "symbol": "NVDA", "date": "2026-05-28", "time": "time-after-hours" }
  ]
}
```

### Effects on Screener

```
days_to_earnings <= blackout_days (default 2)   -> HARD REJECT
days_to_earnings in (blackout, runup_days=10]   -> +1.0 score (run-up bonus)
no upcoming earnings                            -> no effect
```

Earnings dates older than today are ignored (`Get-DaysToEarnings` filters past dates).

---

## 11. Order Execution

### Active Position Management: Break-Even Stop at +1R

After every scan, each open position is checked. When the unrealized P&L reaches **+1R** (one unit of original risk = `qty × |entry − current_stop|`), the bot **PATCHes the bracket's stop-loss leg to entry + 0.1% buffer**.

Effect: from that point forward the position can only finish flat (scratch at the BE stop) or with a profit (TP hit). The downside has been removed without sacrificing any upside.

Implementation (`Manage-OpenPositions` in `alpaca_bot.ps1`):

```
1. Get open orders with nested=true for the position's symbol
2. Find the bracket parent (filled buy) with matching symbol
3. Locate the stop leg (sell+stop for long, buy+stop for short)
4. Compute risk = |entry - current_stop| * qty
5. If unrealized_pl < risk:                       no-op (not yet at +1R)
   If stop already past entry (idempotency):     no-op (managed prior scan)
   Else:
     new_stop = entry +/- 0.1% buffer
     PATCH /v2/orders/{stop_leg.id}  stop_price = new_stop
```

**Idempotency**: the check `currentStop >= entry` (long) or `currentStop <= entry` (short) means re-running on every 10-min scan never moves the stop twice. The state is in Alpaca, not in our memory.

**Why no scale-out yet?**
Partial close (sell 50% at +1R) requires rebalancing the bracket leg quantity atomically. If we sell half via a separate market order, the bracket TP/SL legs still reference the original qty and can fire on the remaining shares before we PATCH them down. Deferred until we have ≥30 sample trades validating the BE-only rule is correctly improving expectancy.

### Bracket Orders
Every entry submits an Alpaca **bracket** order: parent buy limit + child take-profit limit + child stop-loss stop. Server-managed by Alpaca — bot doesn't poll for management.

```json
{
  "symbol":         "NVDA",
  "qty":            "12",
  "side":           "buy",
  "type":           "limit",
  "time_in_force":  "day",
  "limit_price":    "138.42",
  "order_class":    "bracket",
  "take_profit":    { "limit_price": "141.05" },
  "stop_loss":      { "stop_price":  "137.35" },
  "client_order_id":"ORB_NVDA_103047"
}
```

### Strategy Tag
The `client_order_id` follows the pattern `{STRATEGY}_{SYMBOL}_{HHmmss}`. When `Sync-ClosedTrades` reads it back, it strips at the first underscore to learn which strategy generated the trade. This is how memory ends up with proper strategy keys instead of GUID hashes.

### Sync-ClosedTrades (the reconciler)
Runs **before** the market-open gate on every scan so exits get recorded even after hours.

```
1. Fetch closed orders, last 7 days, nested=true (legs embedded in parent)
2. For each filled BUY parent order:
     For each leg in parent.legs:
       if leg is filled SELL:
         Skip if leg.id in recorded_exits
         PnL = (exit_price - entry_price) * qty
         Won = PnL > 0
         Update memory (per-ticker + strategy_stats + hour_stats from filled_at)
         Append leg.id to recorded_exits
         Increment state.wins / state.losses
         Add to state.pnl_today
```

The 7-day lookback + `recorded_exits` dedup makes the call idempotent and recovery-safe.

---

## 12. Configuration Reference

All in `alpaca_config.json`.

### API
```
api_key, api_secret, anthropic_api_key   "FROM_ENV"  # never hard-coded
paper_trading                            true
base_url_paper, base_url_live, data_url
```

### Strategy Engine
```
watchlist                ["SPY","QQQ","AAPL","NVDA","TSLA","MSFT","AMD"]  # fallback only
max_watchlist            12        # screener target size
max_risk_pct             1.0       # baseline % equity per trade
min_rr_ratio             2.5       # minimum reward:risk
max_positions            3         # concurrent slots
orb_minutes              15        # opening range duration
orb_cutoff               "10:45"   # ORB signals stale after this
no_trade_before          "09:45"   # post-open wild zone
no_trade_after           "15:00"   # last hour cutoff
midday_pause_start       "11:30"   # chop window start
midday_pause_end         "13:00"   # chop window end
scan_interval_sec        60        # local loop interval (unused in CI mode)
require_approval         false     # auto-execute on signal
screener_enabled         true
```

### Discipline
```
max_trades_per_day       5
max_losses_per_day       2
max_daily_drawdown_pct   -3.0      # negative %
adaptive_sizing          true
min_trades_for_edge      5         # cold-start cutoff
```

### Catalysts
```
news_catalyst_enabled    true
news_lookback_hours      24
news_min_mentions        2

earnings_enabled         true
earnings_blackout_days   2         # ± window hard rejects
earnings_runup_days      10        # bonus window upper bound
```

---

## 13. State & Memory Files

### `alpaca_state.json`
The bot's working state — read at the start of every scan, written at the end.

```json
{
  "trades_today":       5,        // entries submitted today
  "wins":               3,        // exits classified as winners today
  "losses":             1,        // exits classified as losers today
  "pnl_today":          412.50,   // realized only
  "last_scan":          "iso8601",
  "session_start":      "iso8601",  // never resets
  "watchlist_date":     "YYYY-MM-DD",
  "active_watchlist":   ["SPY","QQQ","NVDA",...],
  "recorded_exits":     ["leg_id_1","leg_id_2",...],
  "equity_at_open":     99876.36,
  "equity_at_open_date":"YYYY-MM-DD"
}
```

### `alpaca_ticker_memory.json`
The bot's long-term learned knowledge.

```json
{
  "tickers": { "<SYMBOL>": <per-ticker block> },
  "strategy_stats": { "ORB": {...}, "VWAP_BOUNCE": {...}, "EMA_PULLBACK": {...} },
  "hour_stats":     { "10": {...}, "11": {...}, "13": {...}, "14": {...} },
  "regime_stats":   { "BULL_TREND": {...}, "RANGING": {...}, ... },
  "last_updated":   "iso8601",
  "last_screened":  "iso8601",
  "total_trades":   42
}
```

### `earnings_calendar.json`
Nasdaq earnings cache (see [section 10](#10-earnings-calendar)).

### `pending_approval.json` (rarely used)
Only populated when `require_approval: true`. Queue of signals awaiting manual `-Approve` invocation. Deleted when empty.

### `alpaca_dashboard.html`
Static dashboard regenerated each scan. Uploaded as a GitHub Actions artifact for download.

### `alpaca_bot_flow.png`
Visual flow diagram generated by `generate_flow.py`. Updated manually after major changes.

---

## 14. Failure Modes & Known Limits

### Things That Will Stop the Bot

| Condition | Symptom | Fix |
|-----------|---------|-----|
| GitHub Actions minutes exhausted | Runs stop firing | Wait for monthly reset / upgrade plan |
| Alpaca paper API key revoked | Every API call fails | Rotate keys in repo secrets |
| cron-job.org account paused | Backup cron still fires (less reliable) | Re-enable cron-job.org |
| Repo made private without PAT update | git push step fails silently | Add fresh PAT |
| Nasdaq blocks the User-Agent | Earnings cache stays stale | Bot still runs, just no earnings logic |
| Alpaca News API quota | 400 errors in log | Bot still runs, just no news catalysts |
| Free-tier IEX feed sparse | "insufficient bar data" on illiquid tickers | Stick to liquid mega-cap watchlist |

### Things Deliberately NOT in the Bot

- **Shorting** — paper allows it but easy to misconfigure; long-only is safer for now.
- **Partial exits / trailing stops** — requires position polling + bracket cancel/resubmit; defer until larger trade sample.
- **Earnings beat/miss reaction strategy** — would require post-event price scanning logic.
- **Premium data (SIP, Benzinga, Bloomberg)** — pay-tier features.
- **Machine learning models** — chose rules-based for auditability.
- **Options** — different beast.

### Things That Look Like Bugs But Aren't

- **"Market closed -- waiting"** during off-hours — correct behavior.
- **"Outside trading window -- monitoring only"** during 11:30-13:00 — correct behavior (midday pause).
- **0 trades on quiet days** — correct behavior. SPY with 0.05% ATR isn't tradeable.
- **Screener selecting only SPY+QQQ on slow tape** — correct when nothing scores above the threshold.
- **No new entries after 2 losses** — correct (daily discipline).

---

## 15. Module Map

| File | Purpose |
|------|---------|
| `alpaca_bot.ps1` | Main orchestrator — `Run-Scan` lifecycle, daily reset, limits |
| `alpaca_client.ps1` | Alpaca REST API wrapper (account, orders, bars, snapshots) |
| `alpaca_indicators.ps1` | EMA, RSI, MACD, ATR, VWAP, opening range, relative volume |
| `alpaca_signals.ps1` | ORB / VWAP Bounce / EMA Pullback strategy implementations |
| `alpaca_risk.ps1` | Position sizing + R:R + buying power + full validation |
| `alpaca_regime.ps1` | Market regime classifier + size multiplier |
| `alpaca_screener.ps1` | Dynamic watchlist + memory update + edge lookups |
| `alpaca_news.ps1` | Alpaca News API + keyword sentiment |
| `alpaca_earnings.ps1` | Nasdaq earnings calendar fetch + cache + lookups |
| `alpaca_dashboard_html.ps1` | Static HTML dashboard generator |
| `.github/workflows/alpaca_bot.yml` | Triggers + runner + persist back to repo |
| `generate_flow.py` | Visual flow diagram generator |

### Dot-source Tree (so PowerShell finds functions)

```
alpaca_bot.ps1
├── alpaca_client.ps1
├── alpaca_signals.ps1
│   └── alpaca_indicators.ps1
├── alpaca_risk.ps1
│   └── alpaca_client.ps1
├── alpaca_screener.ps1
│   ├── alpaca_client.ps1
│   ├── alpaca_news.ps1
│   │   └── alpaca_client.ps1
│   └── alpaca_earnings.ps1
├── alpaca_indicators.ps1   (direct, for Get-MarketBias backstop)
└── alpaca_regime.ps1
    ├── alpaca_client.ps1
    └── alpaca_indicators.ps1
```

---

## Operating Philosophy (the part that matters)

This bot doesn't try to be brilliant. It tries to be **disciplined**, **patient**, and **honest**.

- It doesn't chase trades on quiet days. It waits.
- It doesn't double down after a loss. It stops.
- It doesn't trade through earnings. It steps aside.
- It doesn't trust setups it hasn't proven. It cold-starts cautiously.
- It doesn't fight the tape. It checks SPY first.
- It doesn't lie to itself about win rate. The memory file is the truth.

**Edge emerges from process discipline + survival, not heroic trades.**

That's how index-beaters actually beat the index — not by being right more often, but by losing smaller and quitting on bad days.

---

*Last updated: 2026-05-28 — covers commits through `dabe17d`.*
