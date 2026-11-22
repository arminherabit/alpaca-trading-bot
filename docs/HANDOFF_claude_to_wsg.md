# Handoff: Alpaca paper account, from Claude (D:\Claude-code\Alpaca) to "Wall Street Guy"

Written 2026-11-22 (Sat), about 02:30 UTC, by Claude. The market was closed throughout, and nothing was placed, modified or cancelled while preparing this.

- **Repo:** `arminherabit/alpaca-trading-bot`. Line references are to `master` at `06ec1d611`, the last bot state commit (2026-11-21 07:50 UTC); the last code merge is PR #11, `485649362`.
- **How the facts were gathered:** live Alpaca facts come from read-only GET calls with the bot's own client (`alpaca_client.ps1`) at about 02:20 UTC. Prices move, so re-read before acting.
- **Labels:** *Verified* means I checked it against the code, the repo or the API while writing this. *Reported* means Armin told me and I couldn't confirm it.

---

## 0. TL;DR: what needs attention first

1. **NVDA short −67 (avg $191.77) is about to lose its only stop.**
   - The manual stop `MANUAL_NVDA_20261118-233004` (buy-stop 67 @ $191.77, GTC) has been **`pending_cancel` since 2026-11-22 02:16:50 UTC**. *Verified.* I didn't request that cancel.
   - Reported plan: a 67-share OCO, limit $145.08 / stop $191.77, to be placed **Monday 2026-11-23 06:20 PT**. Nothing on Claude's PC, and none of Claude's schedulers, places it. *Verified.* Whatever does is outside this repo.
   - **Watch out:**
     - NVDA last traded **$125.53**. A buy limit at $145.08 is **above the market**, so the OCO's limit leg would fill **immediately at the open**, as an effective market cover locking roughly +$4.4K. If the intent is a take-profit that waits, the limit has to be **below** the market.
     - If the old stop's cancel hasn't finalised by 06:20 PT, Alpaca may reject the OCO for quantity (the pending stop still reserves the 67 shares), or you could end up with two buy orders.
     - If NVDA has **no** live stop at the first market-hours scan, the bot's `Protect-NakedAggrPositions` (`alpaca_bot.ps1:369`, called at `:1150`) plants **`PROTECT_BREAKEVEN_NVDA_<HHmmss>`, a GTC buy-stop 67 @ $191.58** (entry − 0.1%), because the P&L is positive.
     - The NVDA trade's P&L **won't be journaled automatically** when it closes (§5 and §7, bug B1).
2. **No bot run since 2026-11-21 07:50 UTC.** *Verified:* the last run was `44882064530`.
   - Until then cron-job.org triggered every 10 minutes (as `workflow_dispatch`). It has fired nothing since.
   - GitHub's own backup cron (`'5 13-20 * * 1-5'`, `.github/workflows/alpaca_bot.yml:9`) in practice fires only about **once a day, late (20:00–22:50 UTC)**.
   - **Check that cron-job.org is still enabled before Monday's open.** Otherwise Monday may see no scan until late afternoon.
3. **Opus options sleeve is blocked.** `data/universe.json` was last refreshed **2026-10-11**, past the 21-day staleness block (`config/opus_options_config.psd1:30`). Every Opus evaluation since Nov 1 logs `DATA_STALE`.
4. **Aggressive-mode stock positions have no time stop** (§2.4). Exits are bracket stop / 3.5R target only.

---

## 1. Accounts and environment

### 1.1 Alpaca accounts
| Account | Used by | Notes |
|---|---|---|
| **Paper**, `https://paper-api.alpaca.markets` (`alpaca_config.json` `base_url_paper`) | Everything in this repo | `paper_trading: true`. **Shared with another, unrelated bot.** Our orders and positions are identified only by `client_order_id` prefixes (§3). Account: ACTIVE, options level 3, shorting enabled, margin multiplier 4. |
| Live, `https://api.alpaca.markets` (`base_url_live`) | Nothing | Configured but unused. No code path flips to live unless `paper_trading` is changed. |

- **Market data:** `https://data.alpaca.markets`, always with `feed=iex` (free plan). SIP is not permitted for live data; historical SIP older than 15 minutes worked for read-only analysis. Options use `options_feed: "indicative"`.
- **Key values are never in the repo.** `alpaca_config.json` has `api_key` / `api_secret` / `anthropic_api_key` = `"FROM_ENV"`, resolved in `alpaca_client.ps1:5–15` from the `ALPACA_API_KEY` / `ALPACA_API_SECRET` / `ANTHROPIC_API_KEY` environment variables.

### 1.2 GitHub Actions (the only thing that trades)
- **`alpaca_bot.yml` ("Alpaca Day Trading Bot", id 279253539):**
  - Triggers: `schedule` (backup), `workflow_dispatch` (cron-job.org uses this every 10 minutes), `repository_dispatch`.
  - `concurrency: group alpaca-bot, cancel-in-progress: false`; job timeout 8 minutes; Opus step 4 minutes.
  - Steps, in order: run `alpaca_bot.ps1 -Once` (legacy + aggressive) → `opus_options.ps1` → dashboard (`alpaca_dashboard_html.ps1`, `alpaca_pages.ps1`) → "Persist state to repo".
  - Checkout uses `ref: ${{ github.ref_name }}` so queued runs start from the latest state (PR #2).
- **`opus_options_tests.yml`** (Pester on PRs touching tests/Opus) and **`opus_options_smoke.yml`** (manual, read-only smoke against the paper API).

**Secrets (names only):**
- `ALPACA_API_KEY`, `ALPACA_API_SECRET`: the paper keys, used by every step.
- `BOT_TRIGGER_PAT`: the GitHub token cron-job.org uses to dispatch the workflow. **Owner rule: it must never be stored in any code file.**

**Repo variables:** `OPUS_DRY_RUN` and `OPUS_OPTIONS_ENABLED` are referenced (`alpaca_bot.yml:81–82`) but **not set**, so Opus uses `config/opus_options_config.psd1` (`DRY_RUN = $true`).

### 1.3 Things outside GitHub Actions
| Where | What | Touches the account? |
|---|---|---|
| **cron-job.org** (external) | Every-10-minute `workflow_dispatch` of `alpaca_bot.yml`, using `BOT_TRIGGER_PAT`. I can't see its configuration. | Indirectly (it starts the bot) |
| **Mike-hp** (LAN PC) | Scheduled task "AK Swing Trader Dashboard" (from `install_task.ps1`) runs `C:\Users\Public\AlpacaDashboard\refresh.cmd` → `publish_to_share.ps1`, which copies `docs/index.html` from GitHub to `C:\Users\Public\Desktop\AK's Stocks Swing Trader.html`. **Broken since about 2026-10-10**, last real write; I published one manual copy on 2026-10-22. Mike-hp runs PowerShell 2.0. The `\\Mike-hp\C` share is read-only; `\\Mike-hp\Users` is writable. | **No.** No keys, read-only fetch of a public file |
| **Claude's PC** (D:\Claude-code\Alpaca) | A clone of the repo, plus `ALPACA_API_KEY`/`SECRET` in the user environment (used only for read-only checks and one approved order, §6). Installed for testing: PowerShell 7.6.7 (winget) and Pester 6.2.0 (user scope). Windows Scheduled Tasks: only `SleepWake - Daily Sleep 1AM` and `SleepWake - Weekday Wake 0628`. No trading task, and no Claude scheduled tasks or cron jobs (both lists empty). | Only when Claude runs something by hand |
| Opus `tools/` scripts | `opus_smoke.ps1`, `backfill_earnings.ps1`, `opus_skip_report.ps1`: read-only or local data only. | Read-only |

---

## 2. Strategy spec actually in force

### 2.1 Who trades what
- **Aggressive swing ("Opus Aggressive Swing", v1.2 Variant I) is LIVE on paper:** `aggr.enabled: true`, `aggr.dry_run: false` (`alpaca_config.json`). It places stock entries (`AGSW_`) and long calls (`SWCALL_`).
- **The legacy swing bot places no new entries.** When aggressive mode is live, `Run-Scan` returns straight after the aggressive cycle (`alpaca_bot.ps1:1149–1153`; "aggressive engine takes over entries"). Legacy still *manages* legacy-owned positions, and there are **none right now**.
- **Opus options sleeves** (Sleeve A `OPCALLDEB` call debit spreads, Sleeve B `OPPUTCRED` put credit spreads): `DRY_RUN = $true`, $5K strategy capital, 0 positions. Blocked by `DATA_STALE` (§0).

Scan order in `Run-Scan` (`alpaca_bot.ps1:853`):
1. `Sync-ClosedTrades` (:893)
2. Market-closed exit (:920)
3. Regime via `Get-SwingRegime` (:966)
4. `Cancel-ForeignManagementOrders` (:1055)
5. Ownership, then `Reconcile-Journal` (:1094)
6. Legacy management on **legacy-owned positions only**:
   - `Repair-DuplicateStops` (:1109)
   - `Repair-EntryFillStops` (:1111)
   - `Manage-OpenPositions` (:1119)
   - `Close-StalePositions` (:1124)
7. `Cancel-StaleEntries` (:1134)
8. `Invoke-AggrCycle` (:1144)
9. `Protect-NakedAggrPositions` (:1150)
10. Return (:1151–1153)

### 2.2 Aggressive v1.2 config (`alpaca_config.json` → `aggr`)
| Key | Value | Meaning / where used |
|---|---|---|
| `max_risk_pct` / `max_risk_pct_cap` | 1.75 / 2.0 | Per-trade risk % of equity, × edge × regime × drawdown multipliers, capped (`Get-AggrStockSize`, `alpaca_swing_aggr.ps1:58`) |
| `max_stock_positions` / `max_call_positions` / `max_positions` | 10 / 1 / 11 | Slots count **only AGSW/SWCALL-owned** positions (`Get-AggrSlotBook` :770) |
| `max_portfolio_heat_pct` | 15.0 | Sum of open stock risk (qty × \|entry − stop\|) + call premium, over the whole live book including legacy (`Get-AggrHeat` :85, `Test-AggrHeatOk` :95) |
| `max_notional_pct` | 25.0 | Per-position notional ≤ 25% of equity |
| `bp_cap_divisor` | 5 | Per-position buying-power cap = BP / 5 × 0.8 (:65–66) |
| `max_trades_per_day` / `max_losses_per_day` / `max_daily_drawdown_pct` | 2 / 2 / −3.0 | Entry gates (`Invoke-AggrEntries` :843–845). `losses` is shared with legacy |
| `conf_floor_bull` / `conf_floor_neutral` | 70 / 80 | BULL uses 70; **every other regime (NEUTRAL, RANGING, BEAR) uses 80** (:829) |
| `dummy_tp_r` | 3.5 | Take-profit leg at entry ± 3.5R (`New-AggrStockOrderPayload` :158) |
| `partial_exit_r` | 0 | Partial exits **off** (`Get-AggrStockPartialQty` :176 returns 0 when ≤ 0) |
| `max_extension_atr` | 3.0 | BRKOUT skipped when more than 3 ATR above the prior 20-day high (`Test-AggrExtensionGate` :798, applied :865) |
| `hold_days_max` | 12 | **Calls only** (`Get-AggrCallExitDecision` :191) and shadows. **Not applied to live stocks** (§2.4) |
| `dd_start_equity` / `dd_floor_equity` | 95,554.16 / 76,443.33 | Latched halt when equity ≤ floor (`Get-AggrDdState` :40; `state.aggr_halted`, manual reset) |
| `dd_throttle1_*` / `dd_throttle2_*` | −10% → ×0.5 size, 4 positions, no calls / −15% → ×0.25, 2 positions | Same function |
| Calls | `call_enabled` true; BULL only; confidence ≥ 90; RS ≥ +3%; BRKOUT/PULLBK; 35–70 DTE (target 45); delta 0.60–0.75 (target 0.65); OI ≥ 500; volume ≥ 50; spread ≤ 8% and ≤ $0.40; premium = 1% of equity; exits at −50% premium / ≤ 21 DTE / 12 days / earnings / underlying stop; half at +2R then trail | :101–205 |

**Entry gates, in order** (`Invoke-AggrEntries` :804, `alpaca_swing_aggr.ps1:838–865`):

| Order | Gate | Skip reason |
|---|---|---|
| 1 | Drawdown halt | HALT |
| 2 | SPY/QQQ | INDEX_ANCHOR (`$INDEX_ANCHORS`, `alpaca_screener.ps1:325`) |
| 3 | Leveraged ETFs | LEVERAGED (`$LEVERAGED_BLOCKLIST`, :32) |
| 4 | Opus holds the symbol | OPUS_CONFLICT |
| 5 | Already held, or an order working | HELD_OR_WORKING |
| 6 | One entry per scan | ONE_PER_SCAN |
| 7 | Daily trade limit | TRADES_PER_DAY |
| 8 | Daily loss limit | DAILY_LOSS_CAP |
| 9 | Daily drawdown | DAILY_DD |
| 10 | Position limit | MAX_POS |
| 11 | Ticker memory | MEMORY / COOLDOWN |
| 12 | Earnings blackout (`earnings_blackout_days: 2`; `Test-EarningsBlackout`, `alpaca_earnings.ps1:167`) | EARNINGS |
| 13 | No signal (`Get-SwingBestSignal`) | NO_SETUP |
| 14 | Below confidence floor | CONF_FLOOR |
| 15 | BRKOUT too extended | EXTENSION |
| 16 | **Live-quote guard** (`Update-SignalForLivePrice`, `alpaca_risk.ps1:227`) | STALE_SIGNAL |
| 17 | Heat / size / slots | HEAT / SIZE_ZERO / STOCK_SLOTS_FULL |

The live-quote guard (`entry_max_slippage_pct` 1.0, `entry_quote_max_age_sec` 60, `entry_quote_max_spread_pct` 2.0, `entry_min_stop_atr` 0.5) rejects a quote that is stale or too wide. If the signal is more than 1% from the live price it re-prices the signal, and any later gate failure after a re-price is reported as STALE_SIGNAL. Entries happen only in the swing entry window, **09:50–15:30 ET** (`Test-SwingEntryWindow`, `alpaca_bot.ps1:639`).

### 2.3 Signals and regime (shared by both bots)
`alpaca_swing_signals.ps1`:
- **Stop:** 2 × ATR(14) of completed days (`$SWING_STOP_ATR_MULT`, :23), or a swing level for PULLBK/RALLYF.
- **Untradeable** if stop distance > 10% (`$SWING_MAX_STOP_PCT`, :30).
- **Target:** 3.5R (`$SWING_TARGET_R`, :24).

| Setup | Side | Regime | Rules |
|---|---|---|---|
| **BRKOUT** | long | not BEAR | close > 20-day high, RS ≥ 1.5, volume pace ≥ 1.1 (:110–119) |
| **PULLBK** | long | not BEAR | EMA20 > EMA50 (:211) |
| **BRKDN** | short | **BEAR only** | close < 20-day low (:151) |
| **RALLYF** | short | **BEAR only** | failed rally under EMA50 (:258) |

`Get-SwingRegime` (`alpaca_regime.ps1:168`), from SPY daily:

| Regime | Condition | Size multiplier |
|---|---|---|
| BULL | close > EMA20 > EMA50 | 1.0 |
| BEAR | close < EMA20 < EMA50 | 0.75 (shorts only) |
| NEUTRAL | above EMA50, EMAs mixed | **0.75** |
| RANGING | anything else | 0.60 |

VIX further scales size: × 0.60 above 25, × 0.40 above 30, × 0.25 above 40. `adaptive_sizing: true` also applies a per-strategy edge multiplier (`Get-StrategyEdge`, `alpaca_screener.ps1:231`).

### 2.4 Exits for aggressive stocks
- **Server-side bracket:** stop leg (2 ATR / signal stop) plus TP leg at 3.5R, GTC.
- **No partials** (`partial_exit_r: 0`). The +2R partial code (`Invoke-AggrStockPartial` :492) is dormant.
- **No breakeven, ratchet or trailing stop:** legacy's ladder excludes AGSW since PR #9.
- **No time stop:** the legacy `Close-StalePositions` (12-weekday time stop, 7-day stall cut at −0.5R) excludes AGSW, and the aggressive module has no stock time stop.
- **Protection fallback:** `Protect-NakedAggrPositions` plants a `PROTECT_BREAKEVEN` stop (entry ± 0.1%) if P&L > 0, or a `PROTECT_MAXLOSS` stop (entry ± 2%) otherwise, on any aggressive-owned stock with no live stop (`New-ProtectiveStop`, `alpaca_bot.ps1:206`). It runs only on market-hours scans.

### 2.5 Legacy swing bot (`alpaca_config.json` top level)
- **Config:** `scan_mode: swing`; `max_positions: 3`; `max_risk_pct: 1.0` (cap 1.5, `Get-PositionSize`, `alpaca_risk.ps1:9`); `min_rr_ratio: 3.0`; `max_trades_per_day: 2`; `max_losses_per_day: 2`; `max_daily_drawdown_pct: −3.0`; `hold_days_max: 12`; `stall_cut_*` 7 days / −0.5R; `pyramiding_enabled: false`; `earnings_blackout_days: 2`.
- **Confidence floor:** 75, or 85 in NEUTRAL (`alpaca_bot.ps1:1331`).
- **Exit ladder** (`Manage-OpenPositions` :386): BE at +1R → ratchet to +0.75R at +1.5R → trailing stop at +2R (removes the TP).
- **Also:** after-fill stop re-placement (`Repair-EntryFillStops`, `alpaca_risk.ps1:289`); duplicate-stop repair keeps the single most protective stop (`Repair-DuplicateStops` :298).
- **Entries are skipped while aggressive mode is live.**

### 2.6 Where code and the approved spec differ (flags)
1. **NEUTRAL sizing:** the aggressive v1.2 notes say "NEUTRAL halving". The code uses × 0.75 (`alpaca_regime.ps1:190`), plus a RANGING regime at × 0.60.
2. **`hold_days_max: 12` isn't enforced on live aggressive stocks** (§2.4).
3. **BEAR uses the 80 floor:** `conf_floor_neutral` (80) applies to BEAR and RANGING too, not just NEUTRAL.
4. **`bp_cap_divisor: 5` lets the sum of per-slot BP caps exceed 100%:** 10 slots × 16% of BP = 160% of BP. In practice the 25%-of-equity notional cap and the 15% heat cap bind first.
5. **Journal `strategy` is the signal name, not `AGSW`.** Aggressive trades are journaled as BRKOUT/PULLBK/BRKDN/RALLYF (`Add-JournalEntry`), so journal stats can't separate aggressive from legacy by strategy. Use `opened_at ≥ 2026-10-27`, or the entry order's `client_order_id`.

---

## 3. Order conventions (`client_order_id`)

Format is `<TAG>_<SYMBOL>_<HHmmss>`. The **first `_`-separated token** is what the bot reads.

| Prefix | Placed by | Meaning |
|---|---|---|
| `AGSW_` | Aggressive mode (`alpaca_swing_aggr.ps1:168`) | Stock entry, bracket, GTC |
| `SWCALL_` / `SWCALLX_` | Aggressive mode (:155, :677) | Long call entry / call exit |
| `BRKOUT_ PULLBK_ BRKDN_ RALLYF_ ORB_ VWAP_ EMA_ PYRA_` | Legacy | Entries (PYRA = pyramid add) |
| `PROTECT_BREAKEVEN_` / `PROTECT_MAXLOSS_` | Both bots' fallback (`alpaca_bot.ps1:286`) | Standalone protective stop |
| `PROTECT_AGGR_` | Aggressive partial logic (`alpaca_swing_aggr.ps1:375`) | Re-placed protection (dormant while partials are off) |
| `PARTIAL_` | Aggressive partial (:514) | Partial sale (dormant) |
| `TRAIL_` | Legacy (:357) | Trailing stop at +2R |
| `EOD_CLOSE_` | Legacy (:622) | End-of-day close (intraday mode only, not swing) |
| `OPCALLDEB` / `OPPUTCRED` | Opus | Option spreads (`config/opus_options_config.psd1:75`, :104) |
| `MANUAL_` | Humans | Not a bot prefix; ignored by every bot routine |
| UUID-looking ids | Alpaca | Bracket child legs get system ids (e.g. `307c495f-…`) |

**Ownership.** A symbol is "ours" if any order on it has a first token in `$MY_ENTRY_PREFIXES` (`alpaca_screener.ps1:53`: `BRKOUT, PULLBK, BRKDN, RALLYF, ORB, VWAP, EMA, PYRA, SWCALL, AGSW`) **and some fill**, partial fills included since PR #11 (`Test-OrderHasFill`, :66). It's split further:
- **Aggressive-owned** = an `AGSW`/`SWCALL` entry with a fill (`Get-AggrOwnedSymbols` :734, `Test-AggrOwnedCoid` :726);
- **legacy-owned** = the rest (`Select-LegacyManagedPositions` :757).

Since PR #11, ownership of a *held* position no longer expires with the 20-day order window (`Add-OlderOwnedSymbols`, `alpaca_screener.ps1:81`).

**What the bot cancels, manages or ignores:**
| Routine | Scope | Action |
|---|---|---|
| `Cancel-ForeignManagementOrders` (`alpaca_bot.ps1:837`) | **Whole account** | Cancels any open `PROTECT_*` / `TRAIL_*` / `EOD_*` order on a symbol **not owned** by us |
| `Cancel-StaleEntries` (:763) | **Whole account, any prefix** | Cancels any open **bracket** order with `filled_qty = 0` created on a previous ET day, unless the symbol is held |
| `Repair-DuplicateStops` (:298) | Legacy-owned positions | Keeps the single most protective exit-side stop; **cancels the other stops, any tag** |
| `Protect-NakedAggrPositions` (:369) | Aggressive-owned stocks | Adds a `PROTECT_` stop if there's no live stop leg or standalone stop |
| Everything else | Foreign symbols (no owned, filled entry) | Ignored ("+N other-bot, ignored") |

**How to tag a manual order so the bot leaves it alone:** use **`MANUAL_<SYM>_<YYYYMMDD-HHMMSS>`**, as a **simple** order (not a bracket).
- `MANUAL` isn't a bot prefix, so `Cancel-ForeignManagementOrders` never touches it.
- A simple order isn't a bracket, so `Cancel-StaleEntries` never touches it.
- **Don't** use `PROTECT_`, `TRAIL_` or `EOD_` on a symbol the bot doesn't own: it gets cancelled at the next market-hours scan.
- **Don't** place a manual **bracket entry** and leave it unfilled overnight: it gets cancelled the next ET day.
- A manual stop on a **legacy-owned** position competes in `Repair-DuplicateStops`, and only the most protective stop survives.

---

## 4. Live state (read-only, about 2026-11-22 02:20 UTC, market closed)

**Account:** equity **$105,521.74** (last_equity the same), cash $240,576.83, buying power $260,020.85, ACTIVE, not trading-blocked. The next session opens Mon 2026-11-23 06:30 PT.

**Positions:** all 10 are aggressive-mode shorts, aggressive-owned. No legacy-owned and no foreign positions.

| Sym | Qty | Avg entry | Last | uPnL | Entry `client_order_id` | Stop (live) | Target (live) |
|---|---|---|---|---|---|---|---|
| CVX | −102 | 206.04 | 208.37 | −237.66 | `AGSW_CVX_192024` (filled 11-18) | buy-stop 215.31 `held` (`307c495f-…`) | buy limit 173.59 `new` (`053b7abb-…`) |
| GLD | −64 | 354.60 | 322.87 | +2,030.72 | `AGSW_GLD_150055` (11-12) | 368.25 (`d5377d5a-…`) | 306.83 (`f7d3f789-…`) |
| GOOGL | −44 | 289.26 | 265.29 | +1,054.48 | `AGSW_GOOGL_145029` (11-16) | 309.42 (`8ba2a492-…`) | 218.68 (`e4be2d33-…`) |
| IBIT | −356 | 38.94 | 33.02 | +2,107.52 | `AGSW_IBIT_150129` (11-13) | 41.49 (`def24ada-…`) | 30.01 (`a9440549-…`) |
| NET | −26 | 287.61 | 274.96 | +328.90 | `AGSW_NET_145032` (11-20) | 310.53 (`33ff4797-…`) | 207.39 (`af9a3128-…`) |
| **NVDA** | **−67** | **191.77** | **125.53** | **+4,438.08** | `AGSW_NVDA_150128`: **canceled after 67 of 71 filled** (11-05/06). Its bracket legs (stop 202.95, TP 145.08) were cancelled with it | **`MANUAL_NVDA_20261118-233004` buy-stop 67 @ 191.77, `pending_cancel`** (id `595b73ab-f58d-4bbe-9d42-77e655371c48`) | **none** |
| OXY | −410 | 57.64 | 53.90 | +1,532.61 | `AGSW_OXY_151030` (11-17) | 59.78 (`9e3752c9-…`) | 50.14 (`375ef94f-…`) |
| SOXX | −58 | 154.52 | 123.40 | +1,804.98 | `AGSW_SOXX_194036` (11-12) | 169.83 (`328eb368-…`) | 100.94 (`a9b99e81-…`) |
| SPCX | −123 | 141.28 | 127.79 | +1,659.61 | `AGSW_SPCX_145020` (11-10) | 148.32 (`b3ec000d-…`) | 116.65 (`c886d9e2-…`) |
| UNH | −27 | 388.84 | 339.85 | +1,322.68 | `AGSW_UNH_200034` (11-17) | 409.26 (`14bc71dd-…`) | 317.36 (`1ba59b64-…`) |

- **Open orders:** the 9 bracket TP legs above (`new`), their 9 stop legs (`held`, which Alpaca lists only under their parent), and the NVDA `pending_cancel` stop. **No other open orders.** None are foreign.
- **Short notional:** about $135K on $105.5K equity (≈1.28×). Concentrated in energy (CVX, OXY) and semis/tech (NVDA, SOXX, GOOGL, NET).
- **Recently closed:** ISRG long 15, stopped at $412.92 (journaled 2026-11-19, −$373.53 / −1.0R).
- **Slots:** aggressive mode holds **10/10 stock slots**, so new aggressive stock entries are blocked (`STOCK_SLOTS_FULL`) until one closes. The call slot (1) is free, but calls require a BULL regime.

---

## 5. Journal and state files

All of these are committed by the bot on every run ("Persist state to repo", `alpaca_bot.yml:123–150`).

| File | What | Authoritative? |
|---|---|---|
| Alpaca account (API) | Positions, orders, fills | **The source of truth.** Everything else is derived or runtime |
| `alpaca_state.json` | Runtime state: `recorded_exits` (exit order ids already journaled), `fill_checked`, daily counters (`wins`/`losses`/`pnl_today`, `equity_at_open`), `aggr_*` (`aggr_halted` latch, `aggr_trades_today`, `aggr_shadow_*` from the dry-run era, `aggr_protect_restore`, `aggr_partial_*`, `aggr_calls`) | Authoritative for bot behaviour. Edit only when the workflow is disabled |
| `alpaca_journal.json` | Trade log: `open`, `closed`, `orphaned`, `unfilled`. Stats and reviews read only `closed` | Derived. Repair with preview-by-default tools in `tools/` |
| `alpaca_ticker_memory.json` | Per-ticker learning (wins/losses/score/last_trade) | Drives the MEMORY/COOLDOWN gates |
| `alpaca_equity_history.json`, `docs/index.html`, `alpaca_dashboard.html` | Dashboard data / pages | Display only |
| `earnings_calendar.json` | Legacy earnings calendar | Feed |
| `data/universe.json` | Opus fundamentals (ROIC, revenue growth, FCF positive) for 25 names; owner-approved 2026-10-11 | Owner input. **Stale** (§7) |
| `data/earnings.json` / `data/earnings_override.json` | Opus earnings feed (Nasdaq) / owner overrides | Feed / owner input |
| `data/opus_options_state.json` | Opus legs, working orders, HWM, drawdown mode | **Authoritative for Opus-owned legs** |
| `data/opus_iv_history.json` | IV rank history | Feed |
| `data/journal_options_skips.jsonl` | Opus per-symbol skip reasons | Audit |
| `data/journal_swing_skips.jsonl` | Aggressive mode, one line per symbol per scan (about 700/day): entries, skips, `DRYRUN_*`/`SHADOW_*` history | Audit. Retired shadows carry `excluded_from_results: true` |

**Known inconsistencies, verified, and how to fix them safely:**
1. **NVDA row is in `orphaned`** (BRKDN sell 71 @ $190.09, stop $202.95, opened 2026-11-05, orphaned 2026-11-09) while the position (−67) is held. Before PR #11, NVDA wasn't recognised as ours, so `Reconcile-Journal` orphaned it.
   - **Fix:** a one-time, preview-by-default tool (same style as `tools/fix_journal_unfilled_2026-10.ps1`) that moves it back to `open` with `qty 67`, `planned_qty 71`, and `risk_usd` scaled by 67/71. Otherwise the eventual exit has no open row (and see B1).
2. **HD row is in `orphaned`** (BRKOUT buy 45 @ $334.77, opened 2026-11-02). It **never filled**: `AGSW_HD_151030` was cancelled with `filled_qty 0` on 2026-11-03. **No HD position is held.**
   - **Fix:** move it to `unfilled` (outcome UNFILLED, no P&L).
3. **The Oct 15 UNH entry is correctly in `unfilled`.** `BRKOUT_UNH_135025` (21 @ $405.12) never filled and was cancelled 2026-10-16; it isn't owned. The current UNH short (`AGSW_UNH_200034`) is a separate trade with its own `open` row and live stop. **Nothing to do.**
4. MRNA (2026-08-19) is correctly in `unfilled`.

**How to apply a journal fix safely:**
1. Disable the workflow (§8.2).
2. `git pull`.
3. Run the tool with no flags (preview), then with `-Apply`.
4. Commit and push.
5. Re-enable the workflow.

This avoids racing the bot's 10-minute state commits (the push step rebases, and a conflict fails the run with `STATE_PUSH_FAILED`).

**Journal totals now:** 35 closed, **−$5,381.47**.

| Strategy | Trades | P&L | Total R |
|---|---|---|---|
| BRKOUT | 17 | −$3,550.73 | −5.11 |
| PULLBK | 13 | −$605.65 | +0.58 |
| PYRA | 4 | −$324.37 | −0.80 |
| BRKDN | 1 | −$900.72 | −1.00 |

The open aggressive shorts currently show about +$16.0K unrealized.

---

## 6. Manual interventions by Claude since 2026-10-01 not obvious from git

| Date (UTC) | What | Why |
|---|---|---|
| 2026-10-11 08:30 / 09:29 | Manual `workflow_dispatch` runs of `alpaca_bot.yml` | To verify the Opus merge and the new `universe.json` load (weekend, market closed) |
| 2026-10-13 | Local Pester runs briefly wrote a test record into the **local working copy** of `alpaca_journal.json` (AI split 227/455). Restored at once with `git checkout`; **never committed or pushed** | Test isolation bug, fixed in the tests |
| 2026-10-15 | On Claude's PC: installed Pester 6.2.0 (user scope) and PowerShell 7.6.7 (winget). Left a backup `git stash` (`stash@{0}`) in the local clone | To match CI test conditions. The stash is a local backup only |
| 2026-10-22 03:32 | One-off publish of the dashboard to `\\Mike-hp\Users\Public\Desktop\AK's Stocks Swing Trader.html` (owner-approved) | The Mike-hp scheduled task had stopped (last real write Oct 10) |
| 2026-10-25 / 10-19 | Deleted two **untracked local** files: a stray dashboard copy in the repo root, and my uncommitted MRNA draft script | Cleanup; neither was ever committed |
| **2026-11-18 23:30:04** | **Placed `MANUAL_NVDA_20261118-233004`: buy-stop (stop-market) 67 NVDA @ $191.77, GTC, simple order** (order id `595b73ab-f58d-4bbe-9d42-77e655371c48`). Owner-approved, price chosen by Armin. Tagged `MANUAL_` instead of the requested `PROTECT_MANUAL_` so `Cancel-ForeignManagementOrders` wouldn't cancel it while NVDA was still treated as foreign | NVDA had been naked since 2026-11-06 |
| 2026-11-22 02:16:50 | *(Not me)* Someone requested the cancel of that order; it's now `pending_cancel` | — |

Apart from that one order, every Alpaca call I made was a read-only GET. Earlier owner rule: **never repeat the mleg (multi-leg options) credit-sign test while the market is open.**

---

## 7. Known bugs, open risks, pending decisions

**Bugs:**
- **B1. `Sync-ClosedTrades` can't journal exits of partly filled entries.** It indexes only entries whose status is `filled` (`alpaca_screener.ps1:1043`; pass 1 at :969 too), and skips exits it can't match (:1069). NVDA's entry is `canceled` (67 filled), so its eventual exit, via the manual stop, the OCO or a fallback stop, **won't be journaled**, and ticker memory won't update. The fix is to use `Test-OrderHasFill` in both index loops. Until then, book NVDA's exit by hand.
- **B2. Aggressive stocks have no time stop** (§2.4). Decide whether to add a 12-weekday time stop in aggressive mode.
- **B3. `tools/fix_journal_unfilled_2026-10.ps1` Alpaca verification is broken.** `Get-FixAlpacaCfg` dot-sources `alpaca_client.ps1` *inside a function*, so `Invoke-AlpacaApi` is out of scope ("not recognized"). The applied result (`136f641`) was verified correct by hand. Fix: dot-source at script level.
- **B4. HD and NVDA orphan rows** (§5).
- **B5. Push retry has no backoff.** `alpaca_bot.yml:140–150` retries `git push` up to 3 times immediately after `git pull --rebase`; a rebase conflict fails the job (`STATE_PUSH_FAILED`). It's been quiet lately, but a short `sleep` between attempts would make it more robust.

**Open risks:**
- **R1. Trigger dependency:** cron-job.org is the only real 10-minute trigger (§0.2).
- **R2. IEX-only quotes.** The live-quote guard skips signals when IEX's own book is stale or wide (ABBV 2026-10-15: 19 skips). The AEHL incident (2026-10-14) was a stale IEX print during a halt; the guard now prevents it. Thin names will often show `STALE_SIGNAL`.
- **R3. Shared account.** `Cancel-StaleEntries` and `Cancel-ForeignManagementOrders` act **account-wide**. `alpaca_bot.ps1 -Cancel` (`Invoke-CancelAll`, :103) **cancels every order and closes every position in the shared account, including the other bot's. Never run it** unless you mean to flatten everything.
- **R4. Concentrated short book** (§4) and a 4× margin account.
- **R5. `losses` daily counter is shared** between legacy and aggressive mode (`DAILY_LOSS_CAP`).

**Pending decisions:**
- **D1. `universe.json` refresh** (Opus): stale since 2026-10-11, so Opus has been `DATA_STALE` since Nov 1. Refresh needs owner approval. The method used was SEC EDGAR companyfacts, TTM, ROIC = NOPAT / average invested capital with cash including short-term investments, FCF = OCF − capex, plus public filings for LLY, KLAC, ANET and TSM. 12 names passed.
- **D2. `bp_cap_divisor`** (flag 4): keep 5, or tie it to the slot count / cap total notional.
- **D3. Sizing and one-owner follow-ups:** one-owner is done (PR #9); partial-fill ownership is done (PR #11). Still open: the B1 journal fix, the B2 time stop, and the NEUTRAL × 0.75 vs "halving" (flag 1).
- **D4. Opus structural issue:** high-priced names (e.g. META) can't fit Sleeve A on $5K (a $100-wide spread costs about $4.4K per contract).
- **D5. `BOT_BRAIN_Swing.md` is out of date** (still says 6 positions / 1.25% / R:R 4.0).
- **D6.** The extension gate (v1.2: 3.0 ATR) was chosen with a small sample; the stale-quote guard thresholds (60 s / 2%) are open to tuning.

---

## 8. Runbook

### 8.1 Manual trading without fighting the bot
**Adjust a stop or target on an aggressive bracket:**
- PATCH the leg's `stop_price` or `limit_price` (`/v2/orders/{leg_id}`). Alpaca allows **price** replacement on bracket legs, **not quantity**.
- That's the safest change, and the bot won't undo it (aggressive mode doesn't trail or ratchet).

**Change quantity, or replace a bracket with an OCO:**
1. Cancel one leg (that cancels the whole group).
2. Poll until both legs are `canceled`.
3. Immediately place the new protection (e.g. an OCO: `order_class: oco`, `type: limit`, `take_profit.limit_price`, `stop_loss.stop_price`) with a `MANUAL_` id.

Do it with the **market closed, or between scans**: if a market-hours scan finds the position with no stop, `Protect-NakedAggrPositions` adds a `PROTECT_` stop. While legs are live they reserve all the shares, so a separate order of the same size is rejected for insufficient quantity.

**Close a position by hand:**
1. Cancel that symbol's open orders.
2. Confirm they're gone.
3. Send a market (or marketable limit) order for the full quantity with a `MANUAL_` id, or `DELETE /v2/positions/{symbol}`.
4. Afterwards, check the journal: closes of filled `AGSW` entries are journaled automatically by `Sync-ClosedTrades` pass 2; NVDA's won't be (B1).

**Open a trade by hand:**
- Use a simple order (not a bracket) with a `MANUAL_` id. The bot treats it as foreign: it won't manage it, add a fallback stop, or count it toward slots.
- You own its protection, so place your own stop or OCO, also `MANUAL_`.
- A manual **bracket** that stays unfilled into the next ET day is cancelled by `Cancel-StaleEntries`.

**Don't:**
- tag anything `PROTECT_`, `TRAIL_` or `EOD_`;
- use `alpaca_bot.ps1 -Cancel`;
- edit `alpaca_state.json` or the journal while the workflow is running.

### 8.2 Pausing
| Goal | How | Effect |
|---|---|---|
| **Full pause** | `gh workflow disable "Alpaca Day Trading Bot"` (resume: `gh workflow enable …`) | No runs at all: cron-job.org dispatches and the schedule are rejected. Existing GTC brackets and stops **stay live at Alpaca** and keep protecting. Nothing journals or updates the dashboard. Also pause or disable the cron-job.org job, or it will just log failures |
| **No new entries, keep managing** | Set `aggr.max_trades_per_day` to 0 (PR + merge) | Entries are skipped as `TRADES_PER_DAY`; protection fallback, journaling and Opus continue |
| **Not a pause** | `aggr.dry_run: true` or `aggr.enabled: false` | Either one **re-enables legacy entries**. `dry_run` also stops aggressive-mode protection and management. Don't use them to pause |
| Drawdown latch | Automatic at equity ≤ $76,443.33 (`state.aggr_halted`) | Manual reset = set `aggr_halted` back to false in `alpaca_state.json` (with the workflow disabled) |

### 8.3 After every merge
1. `git pull --rebase` (never force-push; the bot pushes state about every 10 minutes).
2. **Tests:** run under PowerShell 7 with Pester ≥ 5 (CI uses PS 7.6, Pester 6.2): `Invoke-Pester ./tests`. The last known count is **238/238** (after PR #11). Local Windows PowerShell 5.1 gives false failures (`ConvertFrom-Json -AsHashtable`, and others).
3. **Config:** check `aggr.enabled`/`aggr.dry_run` and anything the PR touched.
4. **First market-hours run log after the merge** (Actions → the run → "Run Alpaca bot scan"):
   - `[AGGR] Swing aggressive v1.2 -- LIVE (paper)`;
   - `Legacy Positions: n/3 (+k aggr, managed separately)`, with **no** `+N other-bot, ignored` unless the other bot really holds something;
   - no `[AGGR] cycle error`, no `[OWNERSHIP] could not resolve`, no `::error::STATE_PUSH_FAILED` annotation.
5. **Every position has exactly one live stop:** `status=all&nested=true` per symbol, since stop legs show as `held` under their parent.

### 8.4 Emergency
1. Pause (§8.2, full pause).
2. For each position, confirm there's a live stop; if not, place a `MANUAL_` GTC stop.
3. To flatten **one** symbol: cancel its orders, then close it (§8.1).
4. **Never run `-Cancel`** on the shared account (R3).
5. If equity nears $76,443, the aggressive latch stops new entries but doesn't close positions.

---

## 9. Things not written down anywhere else
- **Alpaca behaviour:**
  - Bracket legs activate only after the parent fills completely.
  - Cancelling a partly filled parent cancels its legs, which is how NVDA went naked.
  - Cancelling one leg cancels the group.
  - Replacing a leg changes only its price.
  - `status=open` listings miss stop legs of a filled parent; use `status=all&nested=true`.
  - Prices come back as strings.
- **PowerShell 7 quirks:** it turns ISO date strings in JSON into `[datetime]`. Code that does `[datetime]::Parse([string]$x).ToUniversalTime()` is correct on the UTC runner but off by the local offset on a Pacific-time PC; the shadow code now uses `ConvertTo-UtcTime`. In Pester, `Should -Be -3.0` passes `'-3.0'` as a string; wrap negatives in parentheses.
- **Logs:** the `[LEARN]` lines used `(if …)`, which failed silently in production until it was fixed (`$(if …)`) on 2026-10-14.
- **The legacy watchlist comes from a screener** (`Get-DynamicWatchlist`). Aggressive mode extends it to 20 names (`Get-AggrWatchlist` :261). SPY and QQQ are never traded.
- **Dry-run history:** dry-run stats (shadow book, −$510.94 realized, all AEHL) are frozen. Eight shadows were retired with `excluded_from_results` (2 at the v1.1→v1.2 switch, 6 at go-live). Any report must filter on that flag.
- **The dashboard copy on Mike-hp is stale**; the cloud page `docs/index.html` is current every run.
- **Claude's PC sleeps nightly** (1 AM) and wakes on weekdays (05:28 local). Nothing on it is needed for trading.

---

## Things I'm not certain about
- **How the Monday 06:20 PT NVDA OCO is scheduled, and its exact `client_order_id`** (reported, not verified). Whether Alpaca will finalise the `pending_cancel` before 06:20 PT, and whether it will accept the OCO with a $145.08 limit above the market (I expect it fills at once).
- **Why cron-job.org stopped** after 2026-11-21 07:50 UTC, and whether it resumes Monday.
- **Whether the approved v1.2 spec's "NEUTRAL halving" was meant to replace the code's × 0.75**, and whether a stock time stop was intended for aggressive mode.
