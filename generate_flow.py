"""
Alpaca Day Trading Bot — Full Logic & Parameters Flow Diagram v2
Includes: self-learning screener, cron-job.org trigger, memory system
Generates: alpaca_bot_flow.png  (200 DPI, dark theme)
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

BG      = "#0d1117"
C_START = "#1f6feb"
C_CHECK = "#9e6a03"
C_PROC  = "#1a3a2a"
C_PROC2 = "#1a2a3a"
C_KILL  = "#3a1a1a"
C_EXEC  = "#0d3320"
C_LEARN = "#2a1a3a"
C_PARAM = "#161b22"
TXT     = "#e6edf3"
TXT_DIM = "#8b949e"
GREEN   = "#3fb950"
AMBER   = "#d29922"
RED     = "#f85149"
BLUE    = "#58a6ff"
PURPLE  = "#bc8cff"
CYAN    = "#76e3ea"
ORANGE  = "#e3b341"

fig = plt.figure(figsize=(30, 56), facecolor=BG)
ax  = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 30)
ax.set_ylim(0, 56)
ax.axis("off")
ax.set_facecolor(BG)

# ── helpers ───────────────────────────────────────────────────────────────────
def box(ax, x, y, w, h, label, sub=None, color=C_PROC, txt=TXT,
        r=0.22, fs=9, sfs=7.5, bold=False):
    p = FancyBboxPatch((x-w/2, y-h/2), w, h,
                       boxstyle=f"round,pad=0.05,rounding_size={r}",
                       facecolor=color, edgecolor="#30363d", linewidth=1.2, zorder=3)
    ax.add_patch(p)
    wt = "bold" if bold else "normal"
    ty = y + (h*0.13 if sub else 0)
    ax.text(x, ty, label, ha="center", va="center", fontsize=fs,
            color=txt, weight=wt, zorder=4)
    if sub:
        ax.text(x, y-h*0.22, sub, ha="center", va="center",
                fontsize=sfs, color=TXT_DIM, zorder=4, style="italic")

def diamond(ax, x, y, w, h, label, color=C_CHECK, fs=8.5):
    xs = [x, x+w/2, x, x-w/2, x]
    ys = [y+h/2, y, y-h/2, y, y+h/2]
    ax.fill(xs, ys, color=color, zorder=3)
    ax.plot(xs, ys, color="#30363d", linewidth=1.2, zorder=4)
    ax.text(x, y, label, ha="center", va="center", fontsize=fs,
            color=TXT, weight="bold", zorder=5)

def arrow(ax, x1, y1, x2, y2, lbl=None, color="#30363d", lw=1.5):
    ax.annotate("", xy=(x2,y2), xytext=(x1,y1),
                arrowprops=dict(arrowstyle="-|>", color=color, lw=lw, mutation_scale=14), zorder=2)
    if lbl:
        ax.text((x1+x2)/2+0.12, (y1+y2)/2, lbl, fontsize=7.5, color=AMBER, va="center", zorder=5)

def side_box(ax, x, y, w, h, lbl, color=C_KILL, fs=8):
    p = FancyBboxPatch((x-w/2, y-h/2), w, h,
                       boxstyle="round,pad=0.05,rounding_size=0.15",
                       facecolor=color, edgecolor="#30363d", linewidth=1, zorder=3)
    ax.add_patch(p)
    ax.text(x, y, lbl, ha="center", va="center", fontsize=fs, color=TXT, zorder=4)

def slabel(ax, x, y, txt, color=BLUE):
    ax.text(x, y, txt, fontsize=8, color=color, weight="bold", va="center", zorder=5,
            bbox=dict(boxstyle="round,pad=0.3", facecolor="#161b22", edgecolor=color, linewidth=1))

def panel(ax, x, y, w, h, title, lines, tc=CYAN):
    p = FancyBboxPatch((x, y), w, h,
                       boxstyle="round,pad=0.1,rounding_size=0.2",
                       facecolor=C_PARAM, edgecolor="#30363d", linewidth=1, zorder=2)
    ax.add_patch(p)
    ax.text(x+w/2, y+h-0.28, title, ha="center", va="center",
            fontsize=8.5, color=tc, weight="bold", zorder=4)
    ax.plot([x+0.15, x+w-0.15], [y+h-0.52]*2, color="#30363d", linewidth=0.8, zorder=3)
    lh = (h-0.65) / max(len(lines), 1)
    for i,(k,v) in enumerate(lines):
        ly = y+h-0.65-(i+0.5)*lh
        ax.text(x+0.22, ly, k, fontsize=7.2, color=TXT_DIM, va="center", zorder=4)
        ax.text(x+w-0.18, ly, v, fontsize=7.2, color=TXT, va="center", ha="right", zorder=4, weight="bold")

CX = 10.5   # main flow centre x

# ══════════════════════════════════════════════════════════════════════════════
# TITLE
# ══════════════════════════════════════════════════════════════════════════════
ax.text(15, 55.3, "Alpaca Day Trading Bot  —  Full Architecture", ha="center",
        fontsize=21, color=TXT, weight="bold")
ax.text(15, 54.75, "Self-Learning Screener  •  Dynamic Watchlist  •  GitHub Actions + cron-job.org  •  Paper Trading",
        ha="center", fontsize=10, color=TXT_DIM)
ax.plot([0.5, 29.5], [54.4, 54.4], color="#30363d", linewidth=1)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION A — TRIGGER LAYER
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 53.8, "  TRIGGER LAYER  ", color=BLUE)

# Two trigger sources side by side
box(ax, CX-3.2, 53.1, 5.5, 0.85,
    "cron-job.org  (PRIMARY)",
    "Every 10 min  |  Mon-Fri  |  6:30 AM-1 PM PT",
    color=C_START, fs=9.5, bold=True)
box(ax, CX+3.2, 53.1, 4.8, 0.85,
    "GitHub Cron  (BACKUP)",
    "Every 20 min  |  flaky fallback",
    color="#1a2040", fs=9, sfs=7.5)

# Both arrows merge down
arrow(ax, CX-3.2, 52.65, CX-0.6, 52.05, color=BLUE)
arrow(ax, CX+3.2, 52.65, CX+0.6, 52.05, color="#30363d")

box(ax, CX, 51.7, 7.5, 0.6,
    "GitHub Actions Runner  (ubuntu-latest  •  timeout 8 min)",
    color=C_PROC2, fs=9)

arrow(ax, CX, 51.4, CX, 50.75, color=BLUE)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION B — MARKET GATE
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 50.4, "  MARKET GATE  ", color=AMBER)

diamond(ax, CX, 50.1, 6.2, 0.85, "Market Open?\n(Alpaca Clock API)")
arrow(ax, CX, 49.67, CX, 49.02, color=GREEN, lbl="YES")
ax.annotate("", xy=(CX+5.8,50.1), xytext=(CX+3.1,50.1),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
side_box(ax, CX+7.1, 50.1, 2.3, 0.55, "EXIT\nSave State")
ax.text(CX+4.3, 50.22, "NO", fontsize=7.5, color=RED)

diamond(ax, CX, 48.65, 6.5, 0.85, "Trading Window?\n09:45 – 15:30 ET")
arrow(ax, CX, 48.22, CX, 47.57, color=GREEN, lbl="YES")
ax.annotate("", xy=(CX+5.8,48.65), xytext=(CX+3.25,48.65),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
side_box(ax, CX+7.1, 48.65, 2.3, 0.55, "Monitor Only\nSave State")
ax.text(CX+4.3, 48.77, "NO", fontsize=7.5, color=RED)

diamond(ax, CX, 47.2, 6, 0.85, "Positions < 3 max?")
arrow(ax, CX, 46.77, CX, 46.12, color=GREEN, lbl="YES")
ax.annotate("", xy=(CX+5.8,47.2), xytext=(CX+3.0,47.2),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
side_box(ax, CX+7.1, 47.2, 2.3, 0.55, "Max Positions\nReached")
ax.text(CX+4.3, 47.32, "NO", fontsize=7.5, color=RED)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION C — SELF-LEARNING SCREENER
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 45.8, "  SELF-LEARNING SCREENER  (once per trading day)  ", color=PURPLE)

diamond(ax, CX, 45.75, 7, 0.85, "Watchlist fresh today?\n(watchlist_date == ET date)")
arrow(ax, CX+3.5, 45.75, CX+5.5, 45.75, color=GREEN, lbl="YES →")
side_box(ax, CX+7.1, 45.75, 2.3, 0.55, "Use cached\nwatchlist", color=C_PROC2)
arrow(ax, CX, 45.32, CX, 44.62, color=RED, lbl="NO")

# Screener pipeline
box(ax, CX-3.5, 44.2, 5.2, 0.75,
    "Alpaca Most-Actives API",
    "top 30 by volume today", color="#1a1a3a", fs=8.5, sfs=7.5)
box(ax, CX+3.5, 44.2, 5.2, 0.75,
    "Alpaca Top Movers API",
    "gainers + losers top 20", color="#1a1a3a", fs=8.5, sfs=7.5)
arrow(ax, CX-3.5, 43.82, CX-0.8, 43.42, color=PURPLE)
arrow(ax, CX+3.5, 43.82, CX+0.8, 43.42, color=PURPLE)

box(ax, CX, 43.1, 7.5, 0.55,
    "Merge + curated universe (~60 liquid names)  →  ~90 candidates",
    color="#1a1a3a", fs=8.5)

arrow(ax, CX, 42.82, CX, 42.17, color=PURPLE)

box(ax, CX, 41.85, 7.5, 0.55,
    "Batch Snapshot Fetch  (Alpaca Data API  •  batches of 40)",
    color=C_PROC2, fs=8.5)

arrow(ax, CX, 41.57, CX, 40.92, color=PURPLE)

# Scoring boxes
for bx2, lbl, detail in [
    (CX-4.5, "Relative Volume", "0–3 pts\nRVOL >1.5x / >2.5x / >4x"),
    (CX-1.5, "Gap %",           "0–2 pts\n>0.8% / >2% / >5%"),
    (CX+1.5, "Intraday Range",  "0–1.5 pts\n>0.5% / >1.5% / >3%"),
    (CX+4.5, "Memory Score",    "±1 pt\nWin rate history"),
]:
    box(ax, bx2, 40.55, 2.65, 0.9, lbl, detail,
        color="#20103a", fs=8, sfs=7)

arrow(ax, CX, 40.1, CX, 39.45, color=PURPLE)

box(ax, CX, 39.15, 7.5, 0.55,
    "Rank by score  →  Top 10 + SPY / QQQ anchors  =  Today's Watchlist",
    color=C_PROC, fs=8.5, txt=GREEN)

arrow(ax, CX, 38.87, CX, 38.22, color=BLUE)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION D — SYMBOL SCAN LOOP
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 37.9, "  SYMBOL SCAN LOOP  ", color=CYAN)

box(ax, CX, 37.8, 8, 0.7,
    "Iterate Dynamic Watchlist  (up to 12 symbols)",
    "SPY  QQQ  +  top screened names for today",
    color=C_PROC2, fs=9, sfs=7.5)

arrow(ax, CX, 37.45, CX, 36.8, color=BLUE)

box(ax, CX, 36.5, 7.5, 0.55,
    "Fetch 1-Min + 5-Min Intraday Bars  (Alpaca Data API)",
    color=C_PROC, fs=8.5)

arrow(ax, CX, 36.22, CX, 35.57, color=BLUE)

diamond(ax, CX, 35.2, 6.5, 0.72, "Sufficient data?\n≥20 x 1-min  |  ≥10 x 5-min bars")
arrow(ax, CX, 34.84, CX, 34.19, color=GREEN, lbl="YES")
ax.annotate("", xy=(CX+5.8,35.2), xytext=(CX+3.25,35.2),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
side_box(ax, CX+7.1, 35.2, 2.3, 0.5, "SKIP symbol", color=C_KILL)
ax.text(CX+4.3, 35.32, "NO", fontsize=7.5, color=RED)

# Indicators
box(ax, CX, 33.87, 8, 0.65,
    "Compute Indicators",
    "EMA9  EMA21  RSI(14)  ATR(14)  VWAP  MACD  Opening Range (15-min ORB)",
    color=C_PROC, fs=9, sfs=7.5)

arrow(ax, CX, 33.54, CX, 32.89, color=BLUE)

# 3 strategies
slabel(ax, 0.6, 32.65, "  STRATEGY ENGINE  ", color=PURPLE)
for sx2, st, det in [
    (CX-4.3, "ORB Breakout",    "Price breaks 15-min H/L\nVol >1.5× avg  •  ATR filter"),
    (CX,     "VWAP Bounce",     "Dip to VWAP, reclaim\nRSI 35–60  •  Vol spike"),
    (CX+4.3, "EMA Pullback",    "EMA9>EMA21 uptrend\nBounce off EMA9"),
]:
    box(ax, sx2, 32.3, 3.8, 0.95, st, det, color="#1a1030", fs=8.5, sfs=7.5)

arrow(ax, CX, 31.82, CX, 31.17, color=BLUE)

diamond(ax, CX, 30.8, 6.2, 0.72, "Valid signal?\nConfidence ≥ 65%  •  Entry / Stop / T1 / T2")
arrow(ax, CX, 30.44, CX, 29.79, color=GREEN, lbl="YES")
ax.annotate("", xy=(CX+5.8,30.8), xytext=(CX+3.1,30.8),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
side_box(ax, CX+7.1, 30.8, 2.3, 0.5, "WATCH\nno setup", color=C_KILL)
ax.text(CX+4.3, 30.92, "NO", fontsize=7.5, color=RED)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION E — RISK ENGINE
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 29.5, "  RISK ENGINE  ", color=AMBER)

box(ax, CX, 29.42, 8, 0.65,
    "Position Sizing",
    "Shares = min( Equity×1% ÷ ATR ,  BuyingPower÷3×80% ÷ Entry )",
    color="#2a1a0a", fs=9, sfs=7.5)

arrow(ax, CX, 29.1, CX, 28.45, color=BLUE)

for bx2, lbl in [
    (CX-4.5, "R:R ≥ 2.5:1"),
    (CX-1.5, "BP sufficient"),
    (CX+1.5, "Confidence ≥65%"),
    (CX+4.5, "Positions < 3"),
]:
    box(ax, bx2, 28.1, 2.65, 0.6, lbl, color="#1a2a1a", fs=8)

arrow(ax, CX, 27.8, CX, 27.15, color=BLUE)

diamond(ax, CX, 26.78, 6, 0.72, "All risk checks pass?")
arrow(ax, CX, 26.42, CX, 25.77, color=GREEN, lbl="YES")
ax.annotate("", xy=(CX+5.8,26.78), xytext=(CX+3.0,26.78),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
side_box(ax, CX+7.1, 26.78, 2.3, 0.5, "REJECTED\nlog reason", color=C_KILL)
ax.text(CX+4.3, 26.9, "NO", fontsize=7.5, color=RED)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION F — EXECUTION
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 25.45, "  ORDER EXECUTION  ", color=GREEN)

box(ax, CX, 25.4, 8, 0.65,
    "AUTO-EXECUTE  (paper_trading=true  require_approval=false)",
    "Submit Bracket Order → Alpaca Paper API",
    color=C_EXEC, fs=9.5, sfs=8, bold=True, txt=GREEN)

arrow(ax, CX, 25.07, CX, 24.42, color=GREEN)

for bx2, lbl, det, col in [
    (CX-4.2, "Entry Order",  "Limit Buy\n@ signal entry price", "#0d1f35"),
    (CX,     "Take Profit",  "Limit Sell\n@ T1  (R:R ×2.5)", "#0d2818"),
    (CX+4.2, "Stop Loss",    "Stop Sell\n@ ATR-based stop",   "#2a1010"),
]:
    box(ax, bx2, 24.05, 3.8, 0.88, lbl, det, color=col, fs=8.5, sfs=7.5)

arrow(ax, CX, 23.61, CX, 22.96, color=BLUE)

box(ax, CX, 22.65, 8, 0.65,
    "Alpaca Manages Lifecycle",
    "fills entry → monitors → auto-triggers TP or SL",
    color=C_PROC2, fs=9, sfs=7.5)

arrow(ax, CX, 22.32, CX, 21.62, color=BLUE)

for bx2, lbl, col in [
    (CX-2.8, "WIN  —  Take Profit Hit\nPnL > 0", C_EXEC),
    (CX+2.8, "LOSS  —  Stop Loss Hit\nPnL < 0", C_KILL),
]:
    box(ax, bx2, 21.3, 4.8, 0.85, lbl, color=col, fs=9.5, bold=True)

arrow(ax, CX, 20.87, CX, 20.22, color=BLUE)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION G — SELF-LEARNING FEEDBACK LOOP
# ══════════════════════════════════════════════════════════════════════════════
slabel(ax, 0.6, 19.9, "  SELF-LEARNING FEEDBACK LOOP  ", color=PURPLE)

box(ax, CX, 19.85, 8, 0.75,
    "Sync-ClosedTrades  (every scan cycle)",
    "Detects newly filled exits  →  calculates PnL per trade",
    color=C_LEARN, fs=9, sfs=7.5)

arrow(ax, CX, 19.47, CX, 18.82, color=PURPLE)

box(ax, CX, 18.55, 8, 0.55,
    "Update-TickerMemory  (symbol, won, pnl, strategy)",
    color=C_LEARN, fs=8.5)

arrow(ax, CX, 18.27, CX, 17.62, color=PURPLE)

for bx2, lbl, det in [
    (CX-3.8, "Win / Loss count",    "trades  wins  losses\nconsecutive_losses"),
    (CX,     "Score recalculated",  "WR≥70%: +0.6\nWR<35%: -0.4\nstreak≥3: -0.3"),
    (CX+3.8, "Strategy tracking",   "per-strategy WR\nbest_strategy"),
]:
    box(ax, bx2, 17.3, 3.5, 0.85, lbl, det, color="#1e103a", fs=8, sfs=7)

arrow(ax, CX, 16.87, CX, 16.22, color=PURPLE)

box(ax, CX, 15.95, 8, 0.55,
    "alpaca_ticker_memory.json  →  committed to GitHub after every run",
    color=C_LEARN, fs=8.5, txt=PURPLE)

# Loop-back arrow — memory feeds next morning's screener
ax.plot([CX-7.5, CX-7.5], [15.95, 38.9], color=PURPLE, lw=1.5, zorder=2, linestyle="--")
ax.annotate("", xy=(CX-4.0, 38.9), xytext=(CX-7.5, 38.9),
            arrowprops=dict(arrowstyle="-|>", color=PURPLE, lw=1.5, mutation_scale=13), zorder=2)
ax.text(CX-8.2, 28.0, "Memory\nfeeds\nnext day\nscreener", fontsize=7.5, color=PURPLE,
        ha="center", va="center", style="italic")

arrow(ax, CX, 15.67, CX, 15.02, color=BLUE)

# ══════════════════════════════════════════════════════════════════════════════
# SECTION H — PERSIST & LOOP
# ══════════════════════════════════════════════════════════════════════════════
box(ax, CX, 14.75, 8, 0.55,
    "Update State  →  Generate Dashboard  →  Commit to GitHub",
    color=C_PROC, fs=8.5)

arrow(ax, CX, 14.47, CX, 13.82, color=BLUE)

box(ax, CX, 13.55, 7.5, 0.55,
    "Next Symbol in Watchlist  (continue loop)",
    color=C_PROC2, fs=8.5)

# loop-back
ax.plot([CX-5.5, CX-5.5], [13.55, 37.8], color="#30363d", lw=1.2, zorder=2)
ax.annotate("", xy=(CX-4.0, 37.8), xytext=(CX-5.5, 37.8),
            arrowprops=dict(arrowstyle="-|>", color="#30363d", lw=1.2, mutation_scale=12), zorder=2)
ax.text(CX-6.2, 26.0, "next\nsymbol", fontsize=7.5, color=TXT_DIM, ha="center", va="center")

arrow(ax, CX, 13.27, CX, 12.62, color=BLUE)

box(ax, CX, 12.35, 7.5, 0.55,
    "Runner exits  •  cron-job.org fires again in 10 min",
    color=C_START, fs=9)

# ══════════════════════════════════════════════════════════════════════════════
# RIGHT PANELS
# ══════════════════════════════════════════════════════════════════════════════
PX = 20.5
PW = 9.0

panel(ax, PX, 50.5, PW, 3.6, "TRIGGER INFRASTRUCTURE", [
    ("Primary",        "cron-job.org (external)"),
    ("Reliability",    "99.9% — SLA-backed"),
    ("Frequency",      "Every 10 min"),
    ("Method",         "POST GitHub API workflow_dispatch"),
    ("Auth",           "BOT_TRIGGER_PAT secret"),
    ("Backup",         "GitHub cron 0,20,40 13-20 UTC"),
    ("Runner",         "ubuntu-latest  •  timeout 8 min"),
], tc=BLUE)

panel(ax, PX, 47.0, PW, 3.2, "SELF-LEARNING SCREENER", [
    ("Universe",       "~60 curated + API additions"),
    ("APIs",           "most-actives + movers (Alpaca)"),
    ("Snapshot batch", "40 symbols per call"),
    ("Score range",    "0 – 9+ points"),
    ("Refresh",        "Once per trading day (9:45 AM ET)"),
    ("Watchlist cap",  "12 symbols (10 screened + 2 anchors)"),
], tc=PURPLE)

panel(ax, PX, 43.6, PW, 3.1, "SCORING WEIGHTS", [
    ("RVOL > 4×",      "+3.0 pts  EXTREME"),
    ("RVOL > 2.5×",    "+2.0 pts  HIGH"),
    ("RVOL > 1.5×",    "+1.0 pts  elevated"),
    ("Gap > 5%",       "+2.0 pts  LARGE catalyst"),
    ("Range > 3%",     "+1.5 pts  HIGH movement"),
    ("Memory proven",  "+1.0 pts  WR ≥ 1.5 score"),
], tc=PURPLE)

panel(ax, PX, 40.3, PW, 3.0, "MEMORY SYSTEM", [
    ("File",           "alpaca_ticker_memory.json"),
    ("Tracks",         "trades  wins  losses  avg_pnl"),
    ("Score range",    "0.1 (avoid) – 3.0 (elite)"),
    ("WR ≥ 70%",       "score +0.6"),
    ("WR < 35%",       "score -0.4"),
    ("Loss streak ≥3", "score -0.3  (cool-off)"),
], tc=PURPLE)

panel(ax, PX, 37.1, PW, 2.9, "TRADING PARAMETERS", [
    ("Anchors",        "SPY  QQQ  (always included)"),
    ("Max positions",  "3 simultaneous"),
    ("Max risk/trade", "1.0% of equity"),
    ("Min R:R",        "2.5 : 1"),
    ("Window",         "09:45 – 15:30 ET"),
    ("Mode",           "Paper trading (auto-execute)"),
], tc=AMBER)

panel(ax, PX, 34.1, PW, 2.8, "STRATEGIES", [
    ("ORB",            "15-min opening range breakout"),
    ("VWAP Bounce",    "Dip to VWAP + reclaim"),
    ("EMA Pullback",   "EMA9 > EMA21 bounce"),
    ("Confidence min", "65%  to qualify"),
    ("Best strategy",  "tracked per ticker in memory"),
], tc=PURPLE)

panel(ax, PX, 31.2, PW, 2.7, "POSITION SIZING", [
    ("Risk$ per trade", "Equity × 1%"),
    ("Shares (risk)",   "Risk$ ÷ ATR"),
    ("Shares (BP cap)", "(BP ÷ 3) × 80% ÷ Entry"),
    ("Final shares",    "min(risk, BP cap)"),
    ("Max pos value",   "~$53K on $100K account"),
], tc=AMBER)

panel(ax, PX, 28.3, PW, 2.7, "INDICATORS", [
    ("EMA Fast / Slow", "9 / 21"),
    ("RSI period",      "14  (zone 35–65)"),
    ("ATR period",      "14  (stop distance)"),
    ("VWAP",            "Intraday reset 09:30 ET"),
    ("ORB",             "First 15-min candle range"),
], tc=CYAN)

panel(ax, PX, 25.4, PW, 2.7, "ORDER STRUCTURE", [
    ("Type",            "Bracket order (3 legs)"),
    ("Leg 1",           "Limit buy @ entry"),
    ("Leg 2",           "Limit sell @ T1 (take profit)"),
    ("Leg 3",           "Stop sell @ stop loss"),
    ("Duration",        "GTD (Good-Till-Day)"),
], tc=GREEN)

panel(ax, PX, 22.5, PW, 2.7, "ACCOUNT (PAPER)", [
    ("Account #",       "PA3YCA5A39KV"),
    ("Starting equity", "$100,000.00"),
    ("API endpoint",    "paper-api.alpaca.markets"),
    ("Data endpoint",   "data.alpaca.markets"),
    ("Auth headers",    "APCA-API-KEY-ID / SECRET"),
], tc=BLUE)

panel(ax, PX, 19.6, PW, 2.7, "GITHUB ACTIONS WORKFLOW", [
    ("Repo",            "arminherabit/alpaca-trading-bot"),
    ("File",            ".github/workflows/alpaca_bot.yml"),
    ("Triggers",        "repository_dispatch + schedule"),
    ("Persists",        "state.json + memory.json + dashboard"),
    ("Concurrency",     "cancel-in-progress: false"),
], tc=BLUE)

panel(ax, PX, 16.7, PW, 2.7, "SECRETS CONFIGURED", [
    ("ALPACA_API_KEY",    "Paper trading key"),
    ("ALPACA_API_SECRET", "Paper trading secret"),
    ("BOT_TRIGGER_PAT",   "cron-job.org dispatch auth"),
    ("GitHub GITHUB_TOKEN","auto-provided by Actions"),
], tc=AMBER)

# ══════════════════════════════════════════════════════════════════════════════
# LEGEND
# ══════════════════════════════════════════════════════════════════════════════
lx, ly = 0.5, 11.8
ax.text(lx, ly, "LEGEND", fontsize=8, color=TXT_DIM, weight="bold")
items = [
    (C_START,  "Trigger/Terminal"), (C_CHECK, "Decision"),
    (C_PROC,   "Process"),          (C_PROC2, "Sub-process"),
    (C_EXEC,   "Execute Trade"),    (C_KILL,  "Reject/Stop"),
    (C_LEARN,  "Learning/Memory"),  ("#1a1030","Strategy"),
]
for i, (col, lbl) in enumerate(items):
    lx2 = lx + (i % 4) * 3.5
    ly2 = ly - 0.55 - (i // 4) * 0.55
    p = FancyBboxPatch((lx2, ly2-0.18), 0.4, 0.35,
                       boxstyle="round,pad=0.04", facecolor=col,
                       edgecolor="#30363d", linewidth=0.8, zorder=3)
    ax.add_patch(p)
    ax.text(lx2+0.55, ly2, lbl, fontsize=7.2, color=TXT_DIM, va="center", zorder=4)

ax.plot([0.5, 29.5], [0.6, 0.6], color="#30363d", linewidth=0.8)
ax.text(15, 0.32, "Alpaca Day Trading Bot  v2  •  Self-Learning  •  Paper Mode  •  arminherabit/alpaca-trading-bot",
        ha="center", fontsize=7.5, color=TXT_DIM)

out = "D:/Claude-code/Alpaca/alpaca_bot_flow.png"
plt.savefig(out, dpi=200, bbox_inches="tight", facecolor=BG, edgecolor="none")
plt.close()
print(f"Saved: {out}")
