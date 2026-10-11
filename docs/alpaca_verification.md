# Alpaca verification record — Opus options sleeves

Required by spec v1.2 §6.4 and §9.7 step 2. Paper account `PA3YCA5A39KV`. Verified 2026-10-11 unless noted.

## Verified

| Item | Result | How |
|---|---|---|
| Options level | `options_approved_level: 3`, `options_trading_level: 3` | `GET /v2/account` |
| Options buying power | `options_buying_power: 80301.14` (shared account) | `GET /v2/account` |
| Contracts endpoint fields | `symbol, strike_price, expiration_date, open_interest, open_interest_date, style, tradable, close_price, type, size, …` | `GET /v2/options/contracts` (MSFT calls) |
| Greeks on the free feed | `feed=indicative` snapshots return `greeks.delta/gamma/theta/vega/rho`, `impliedVolatility`, `latestQuote.bp/ap`. 49 of 72 MSFT contracts had a delta; far-from-money strikes return none. | `GET /v1beta1/options/snapshots/MSFT` |
| mleg credit sign | **NEGATIVE.** API reference (`POST /v2/orders`, `limit_price`): *"A positive value indicates a debit … A negative value signifies a credit."* Paper test: SPY 20 Nov 2026 753/748 put credit spread, $0.66 mid credit, sent at `+4.50` and `-4.50`; both accepted with the sign kept as sent, both cancelled with 0 filled, account verified clean. | Docs + paper test, market closed (Sunday) |
| Nasdaq earnings rate (one machine) | 104 requests (today−3 … today+100) in 40 s, zero errors | Local machine, browser headers as in `alpaca_earnings.ps1` |
| Nasdaq from **GitHub Actions** | Backfill 100 dates in 55 s and refresh 74 dates in 40 s (4 requests in parallel), zero errors; ~2.3 s per request from the runner vs ~0.4 s locally | `tools/opus_smoke.ps1`, workflow run 38124826082 |
| Nasdaq past its horizon | `rCode 200`, `data: null`, `bCodeMessage` code 1002 "No record found" = an empty day, not a failure | Dates 2026-12-04 … 2026-12-20 |
| Nasdaq listing horizon | Rows by days ahead: 0–14: 406; 15–30: 2,801; 31–50: 1,188; 51–70: 79; 71–100: 0 | Same run |
| Nasdaq empty day | `status.rCode = 200`, `data.rows = null` (distinct from a failed request) | `date=2026-10-11` |

**Never repeat the sign test with the market open.** A "+4.50 unfillable credit" is read as "willing to pay up to $4.50" and fills immediately.

## Still to verify before `DRY_RUN = false`

- [ ] Activity type codes for assignment / exercise / expiry (`OPASG`, `OPEXC`, `OPEXP`).
- [ ] Corporate-actions endpoint for ex-dividend dates (A5). The module skips A5 and logs `EXDIV_DATA_UNAVAILABLE` if it fails.
- [ ] mleg net-price tick (`PRICE_TICK = 0.01`, fallback 0.05).
- [ ] mleg partial-fill behaviour.
- [ ] Whether Alpaca accepts a single-leg close of a leg opened via mleg.
- [ ] Intraday liquidity of monthly legs on individual names (review figures used closing quotes).

## Not yet implemented (live-only paths)

These never run while `DRY_RUN = true` and must be built and tested before going live:

- **E0 automatic flattening** of stock left by an assignment. In live mode E0 is detected (leg quantity mismatch vs `/v2/positions`) and sets `manual_review_required`, which blocks all entries until the owner clears it. Nothing is flattened automatically.
- **`SHORT_LEG_ONLY_CLOSE`** — closing only the short leg with a single-leg order when the long leg has no bid during a forced exit.
