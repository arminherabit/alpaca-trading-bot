# Alpaca Swing Trading Bot — The Brain

> Complete reference for how this bot thinks, decides, sizes, learns, and survives in swing mode.
> Optimized for 2–10 day holds with disciplined, high R:R setups. Designed for consistent +35% style performance on free GitHub + Alpaca paper.

---

## TL;DR (60 seconds)

A self-learning swing trading bot for U.S. equities. Runs 1–2 times daily via free GitHub Actions + cron-job.org. Scans dynamic watchlist, takes only high-conviction setups (regime + risk + catalyst + memory), holds 2–10 days, and improves from closed swing results.

Built like a veteran Wall Street swing trader: patient, high R:R, gap-resistant risk management.

---

## Table of Contents

1. System Architecture
2. Run-Scan Lifecycle
3. Four Pillars of Discipline
4. Market Regime Detection
5. Strategy Engine (Swing Setups)
6. Risk & Position Sizing
7. Self-Learning Loop
8. Dynamic Screener
9. News & Earnings Catalysts
10. Order Execution & Management
11. Configuration
12. State & Memory
13. Failure Modes
14. Module Map

---

## 1. System Architecture

Cron-job.org triggers **twice daily** (e.g. 08:30 ET pre-market + 16:30 ET post-close) → GitHub Actions → PowerShell → Alpaca Paper API.

Heavy use of daily + 4H bars. GTC bracket orders for multi-day holds. State persisted via git.

---

## 2. Run-Scan Lifecycle (Simplified)

1. Sync closed trades (30-day lookback)
2. Regime detection (SPY daily/weekly)
3. Manage open positions (trailing, time exits)
4. Refresh watchlist & catalysts
5. Scan for new entries
6. Submit brackets if limits allow
7. Save state + git commit/push

---

## 3. Four Pillars of Discipline

- **Regime**: Daily + weekly SPY trend filter
- **Risk Limits**: 1.25% max per trade, 6 positions max, -5% weekly DD cap
- **Adaptive Sizing**: Memory-based edge multiplier
- **Catalyst**: Earnings run-up, sector strength, news momentum required

---

## 4. Market Regime Detection

SPY daily bars + VIX:
- STRONG_BULL / BULL → full size
- RANGING → reduced size
- BEAR → cash or selective shorts
- HIGH_VOL (VIX>25) → halve size

---

## 5. Strategy Engine (Swing Setups)

**All require daily + 4H confluence + weekly alignment (hard gate).**

### 5a. Daily Breakout
Break above 20-day high + volume > 1.5x avg. Stop below swing low / 2×ATR. Target 4–6R.

### 5b. EMA Pullback
Uptrend (price > EMA20 > EMA50 daily). Pullback to EMA zone + 4H bounce. Stop below EMA50. Target 4R+.

### 5c. Momentum Base
Tight consolidation + rising volume → breakout. 4H confirmation.

### 5d. Catalyst Momentum
Earnings 3–12 days out + strong relative strength + technical setup.

---

## 6. Risk & Position Sizing

```powershell
effective_risk = 1.0% * edge_mult * regime_mult
shares = equity * effective_risk / risk_per_share
```

Min R:R = **4.0**. Smaller sizing to survive gaps.

---

## 7. Self-Learning Loop

Tracks avg_hold_days, win_rate by duration, best catalysts. Strongly rewards multi-day winners.

---

## 8–10. Screener, Catalysts, Execution

- Screener favors relative strength, sector leaders, pre-earnings drift
- GTC brackets + daily trailing (BE at +2R, then ATR trail)
- Max hold: 12 trading days (time stop)

---

## 11. Key Config Changes

```json
"scan_mode": "swing",
"scan_times": ["08:30", "16:30"],
"max_positions": 6,
"max_risk_pct": 1.25,
"min_rr_ratio": 4.0,
"hold_days_max": 12,
"trailing_enabled": true
```

---

*Last updated: June 2026 — Swing Mode v1.0*  
Optimized for free GitHub deployment.
