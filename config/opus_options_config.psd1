# config/opus_options_config.psd1
# Opus options sleeves -- every key below is REQUIRED (spec v1.2, section 2.2).
# Copied verbatim from the spec's config block. Env overrides: OPUS_DRY_RUN,
# OPUS_OPTIONS_ENABLED. Invalid or missing keys disable the options module for
# the run (CONFIG_INVALID); the swing bot is unaffected.
@{
  # ---------------- Master switches ----------------
  OPTIONS_ENABLED                 = $true      # false = module does nothing except log
  DRY_RUN                         = $true      # true = compute everything, never POST/PATCH/DELETE orders
  ENTRIES_ENABLED                 = $true      # false = manage exits only
  STRATEGY_VERSION                = '1.2'

  # ---------------- Capital / equity ----------------
  STARTING_CAPITAL                = 5000.00    # USD. Opus option-sleeve equity baseline. Owner decision (v1.1): stays 5000; Sleeve A will rarely trade at this size (3.A note, L4)
  EQUITY_MODE                     = 'STRATEGY' # 'STRATEGY' = STARTING_CAPITAL + realized + unrealized Opus P&L (see 5.1)
  MULTIPLIER                      = 100

  # ---------------- Data ----------------
  STOCK_DATA_FEED                 = 'iex'      # free feed
  OPTIONS_DATA_FEED               = 'indicative' # free; returns greeks, IV, bp/ap (verified 2026-10-11); 'opra' requires subscription
  BAR_ADJUSTMENT                  = 'all'      # split+dividend adjusted daily bars [VERIFY param value]
  BAR_LOOKBACK_CALENDAR_DAYS      = 400        # enough for 126-day RS + EMA50 warmup (>= 260 trading days)
  MIN_BARS_REQUIRED               = 180        # skip symbol if fewer completed bars
  UNIVERSE_FILE                   = 'data/universe.json'
  EARNINGS_FILE                   = 'data/earnings.json'          # written by the extended Nasdaq feed (2.3); map to the existing feed's output path
  EARNINGS_OVERRIDE_FILE          = 'data/earnings_override.json' # owner-maintained; wins over the feed per symbol (2.3)
  STATE_FILE                      = 'data/opus_options_state.json'
  IV_HISTORY_FILE                 = 'data/opus_iv_history.json'
  UNIVERSE_STALE_WARN_DAYS        = 10         # calendar days since refreshed_at -> warning
  UNIVERSE_STALE_BLOCK_DAYS       = 21         # -> block new entries
  EARNINGS_STALE_BLOCK_DAYS       = 8          # earnings.json refreshed_at older -> block new entries
  EARNINGS_LOOKAHEAD_DAYS         = 70         # Nasdaq feed: today .. today+70 (>= A_DTE_MAX); in practice Nasdaq lists only ~50 days ahead (2.3)
  EARNINGS_LOOKBACK_DAYS          = 3          # Nasdaq feed: today-3 .. today-1 (covers the 2-day post-earnings blackout)
  EARNINGS_REFRESH                = 'DAILY'    # once per ET trading day (2.3)
  EARNINGS_BACKFILL_ENABLED       = $true      # v1.2: run the one-time backfill if EARNINGS_FILE has no backfill_completed_at (2.3)
  EARNINGS_BACKFILL_DAYS          = 100        # v1.2: one-time backfill window today-100 .. today-1, seeds last_earnings_date (2.3)

  # ---------------- Fundamentals filter (applied on load of universe.json) ----------------
  MIN_ROIC                        = 0.20       # strictly greater than
  MIN_REV_GROWTH                  = 0.15       # strictly greater than (YoY)
  REQUIRE_FCF_POSITIVE            = $true

  # ---------------- Indicators ----------------
  EMA_FAST                        = 20
  EMA_SLOW                        = 50
  ATR_PERIOD                      = 14         # Wilder
  RS_LOOKBACK_SHORT               = 63
  RS_LOOKBACK_LONG                = 126
  RS_WEIGHT_SHORT                 = 0.5
  RS_WEIGHT_LONG                  = 0.5
  RS_TOP_PCT                      = 0.20       # top 20% of eligible universe by RS_SCORE
  BENCHMARK                       = 'SPY'

  # ---------------- Common trend gates ----------------
  REQUIRE_CLOSE_ABOVE_EMA_FAST    = $true
  REQUIRE_CLOSE_ABOVE_EMA_SLOW    = $true
  REQUIRE_EMA_FAST_ABOVE_SLOW     = $true

  # ---------------- Expiry selection (3.0.10) ----------------
  EXPIRY_TYPE                     = 'MONTHLY'  # standard monthly expirations only; weeklies excluded (illiquid in testing)

  # ---------------- Liquidity gates (per leg) ----------------
  MIN_OPEN_INTEREST               = 1000       # strictly greater than, each leg
  MAX_LEG_SPREAD_PCT_OF_MID       = 0.10       # (ask-bid)/mid <= 0.10, each leg
  MIN_LEG_BID                     = 0.05       # each leg bid must be >= this

  # ---------------- Earnings gates ----------------
  EARNINGS_MIN_DAYS_AHEAD         = 10         # calendar days: next_earnings_date - today >= 10
  EARNINGS_POST_BLACKOUT_DAYS     = 2          # calendar days: skip if 0 <= today - last_earnings_date <= 2
  EARNINGS_EXIT_DAYS              = 3          # calendar days: exit if 0 <= next_earnings_date - today <= 3
  EARNINGS_MAX_DAYS_SINCE_LAST    = 45         # v1.2: next date missing -> pass the >=10-day gate iff last_earnings_date known and today - last <= 45 (3.0.8)

  # ---------------- Sleeve A: call debit spread (OPCALLDEB) ----------------
  A_ENABLED                       = $true
  A_PREFIX                        = 'OPCALLDEB'
  A_RISK_SHARE                    = 0.60       # share of TOTAL_OPEN_RISK_CAP used for sleeve priority (5.3)
  A_PULLBACK_LOOKBACK_DAYS        = 3          # touched EMA20 zone within last 3 completed bars (incl. signal bar)
  A_PULLBACK_ZONE_PCT             = 0.005      # zone: Low <= EMA20_latest * (1 + 0.005); matches existing swing PULLBK
  A_MIN_TREND_QUALITY_ATR         = 0.40       # (EMA20 - EMA50)/ATR >= 0.40; HARD gate for options (intentional difference: swing code uses it only as a confidence bonus)
  A_MIN_RS_PULLBK                 = 1.5        # percentage points: (stock_ret_20 - SPY_ret_20)*100 >= 1.5 (difference formula, as in swing code)
  A_RS_PULLBK_LOOKBACK            = 20         # matches existing swing PULLBK
  A_DTE_MIN                       = 38         # monthly expirations only (EXPIRY_TYPE)
  A_DTE_MAX                       = 70
  A_DTE_TARGET                    = 52         # fallback if no monthly in [38,70]: monthly nearest 52 DTE
  A_LONG_DELTA_MIN                = 0.60
  A_LONG_DELTA_MAX                = 0.70
  A_LONG_DELTA_TARGET             = 0.65
  A_SHORT_OTM_MIN                 = 0.08       # short strike >= spot*1.08
  A_SHORT_OTM_MAX                 = 0.10       # short strike <= spot*1.10
  A_SHORT_OTM_TARGET              = 0.09
  A_MAX_DEBIT_PCT_WIDTH           = 0.45       # debit <= 0.45 * width
  A_RISK_PCT                      = 0.06       # target max loss per trade, % of equity
  A_MAX_SINGLE_CONTRACT_PCT       = 0.08       # skip if 1 contract's debit*100 > 8% of equity
  A_MAX_OPEN                      = 3
  A_TP_PCT                        = 0.70       # partial take-profit at spread value >= debit*(1+0.70)
  A_STOP_PCT                      = 0.50       # full close at spread value <= debit*(1-0.50)
  A_TIME_STOP_DAYS                = 10         # trading days held
  A_TIME_STOP_MIN_GAIN            = 0.20       # close if gain < +20% at/after 10 trading days
  A_EXIT_DTE                      = 14         # close when DTE <= 14
  A_REGIME_MULT                   = @{ BULL = 1.00; NEUTRAL = 0.75; RANGING = 0.50; BEAR = 0.00 }

  # ---------------- Sleeve B: put credit spread (OPPUTCRED) ----------------
  B_ENABLED                       = $true
  B_PREFIX                        = 'OPPUTCRED'
  B_RISK_SHARE                    = 0.40
  B_ENTRY_MAX_ATR_ABOVE_EMA_FAST  = 1.00       # 0 < Close - EMA20 <= 1.0*ATR
  B_REQUIRE_GREEN_CLOSE           = $true      # Close > Open on signal bar
  B_DTE_MIN                       = 30         # monthly expirations only (EXPIRY_TYPE)
  B_DTE_MAX                       = 45
  B_DTE_TARGET                    = 38         # fallback if no monthly in [30,45]: monthly nearest 38 DTE
  B_SHORT_DELTA_MIN               = 0.20       # absolute delta
  B_SHORT_DELTA_MAX               = 0.25
  B_SHORT_DELTA_TARGET            = 0.225
  B_SHORT_STRIKE_BELOW_EMA_SLOW   = $true      # short strike < EMA50 (strictly)
  B_WIDTH                         = 5.00       # long strike = short strike - 5.00 (must be listed exactly)
  B_MIN_CREDIT_PCT_WIDTH          = 0.3333333333 # credit >= width/3
  B_RISK_PCT                      = 0.065      # target max loss per trade, % of equity
  B_MAX_LOSS_PCT                  = 0.07       # hard cap: 1 spread max loss must be <= 7% of equity
  B_MAX_OPEN                      = 2
  B_TP_PCT                        = 0.50       # close when cost-to-close <= credit*(1-0.50)
  B_STOP_MULT                     = 2.00       # close when cost-to-close >= 2.0*credit
  B_EXIT_DTE                      = 10         # close when DTE <= 10
  B_REGIME_MULT                   = @{ BULL = 1.00; NEUTRAL = 0.75; RANGING = 0.75; BEAR = 0.00 }

  # ---------------- Portfolio guards ----------------
  TOTAL_OPEN_RISK_CAP_PCT         = 0.15
  MAX_UNDERLYING_EXPOSURE_PCT     = 0.25
  ONE_POSITION_PER_UNDERLYING     = $true      # across both sleeves
  EXCLUDE_UNDERLYINGS_HELD_BY_OTHER_STRATEGIES = $true  # owner decision: block if any us_equity position in /v2/positions (5.2 P7)
  MAX_NEW_ENTRIES_PER_DAY         = 2
  SYMBOL_COOLDOWN_AFTER_LOSS_DAYS = 5          # trading days
  DD_THRESHOLD_PCT                = 0.10       # drawdown from HWM that activates drawdown mode (P10)
  DD_MAX_OPEN_POSITIONS           = 1          # in drawdown mode: max open positions + working entries, total across sleeves, until new equity high
  CONSEC_LOSS_LIMIT               = 3
  CONSEC_LOSS_PAUSE_DAYS          = 5          # trading days
  DAILY_LOSS_HALT_PCT             = 0.03       # -3% of start-of-day equity
  MAX_LOSSES_PER_DAY              = 2

  # ---------------- Timing (ET) ----------------
  ENTRY_WINDOW_START_MIN_BEFORE_CLOSE = 30     # entry window opens at close-30m (15:30 normal day)
  ENTRY_WINDOW_END_MIN_BEFORE_CLOSE   = 5      # no new entry orders after close-5m (15:55)
  EXIT_EARLIEST_MIN_AFTER_OPEN        = 15     # no exit orders before open+15m (09:45), except assignment handling
  EXIT_LATEST_MIN_BEFORE_CLOSE        = 3      # no new exit orders after close-3m

  # ---------------- Order handling ----------------
  ORDER_TIF                       = 'day'
  ENTRY_MAX_REPRICES              = 2          # initial + 2 cancel/replace = 3 attempts, then abandon
  EXIT_MAX_REPRICES_DISCRETIONARY = 2          # profit-taking exits: abandon after, re-evaluate next scan
  EXIT_FORCED_GO_NATURAL_AFTER    = 2          # forced exits: attempt index >=2 priced at natural, keep repricing every scan
  REPRICE_FRACTIONS               = @(0.00, 0.33, 0.67)  # fraction of |natural - mid| moved toward natural per attempt
  PRICE_TICK                      = 0.01       # [VERIFY] mleg price increment; fallback 0.05
  STOP_CONFIRM_SCANS              = 2          # quote-based stops must hold on 2 consecutive scans [ASSUMPTION]
  MLEG_CREDIT_PRICE_SIGN          = 'NEGATIVE' # negative limit_price = net credit, positive = net debit (Alpaca docs; tested 2026-10-11, 6.4)

  # ---------------- Metrics / gates ----------------
  REVIEW_AFTER_TRADES             = 20
  KILL_MIN_TRADES                 = 30
  KILL_PF_BELOW                   = 1.00
  GOLIVE_MIN_TRADES               = 30
  GOLIVE_MIN_PF                   = 1.30
  GOLIVE_MIN_WINRATE_A            = 0.35
  GOLIVE_MIN_WINRATE_B            = 0.60
  GOLIVE_MAX_DRAWDOWN             = 0.25
  PAPER_HAIRCUT_PCT               = 0.15       # gross profits *(1-0.15) for haircut metrics (8.1)
  GATES_USE_HAIRCUT               = $true      # [OWNER] go-live gates evaluated on haircut metrics
}
