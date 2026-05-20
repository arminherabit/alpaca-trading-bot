"""
Alpaca Day Trading Bot — Full Logic & Parameters Flow Diagram
Generates: alpaca_bot_flow.png  (300 DPI, dark theme)
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

# ── Colour palette ────────────────────────────────────────────────────────────
BG       = "#0d1117"
C_START  = "#1f6feb"   # blue  – start / end
C_CHECK  = "#9e6a03"   # amber – decision
C_PROC   = "#1a3a2a"   # dark green – process
C_PROC2  = "#1a2a3a"   # dark blue  – sub-process
C_REJECT = "#3a1a1a"   # dark red   – reject / stop
C_EXEC   = "#0d3320"   # deep green – execute
C_PARAM  = "#161b22"   # panel bg
TXT      = "#e6edf3"
TXT_DIM  = "#8b949e"
GREEN    = "#3fb950"
AMBER    = "#d29922"
RED      = "#f85149"
BLUE     = "#58a6ff"
PURPLE   = "#bc8cff"
CYAN     = "#76e3ea"

fig = plt.figure(figsize=(28, 48), facecolor=BG)
ax  = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 28)
ax.set_ylim(0, 48)
ax.axis("off")
ax.set_facecolor(BG)

# ── Drawing helpers ───────────────────────────────────────────────────────────

def box(ax, x, y, w, h, label, sublabel=None, color=C_PROC, txt=TXT,
        radius=0.25, fontsize=9, subfontsize=7.5, bold=False):
    patch = FancyBboxPatch((x - w/2, y - h/2), w, h,
                           boxstyle=f"round,pad=0.05,rounding_size={radius}",
                           facecolor=color, edgecolor="#30363d", linewidth=1.2, zorder=3)
    ax.add_patch(patch)
    weight = "bold" if bold else "normal"
    ty = y + (h * 0.12 if sublabel else 0)
    ax.text(x, ty, label, ha="center", va="center", fontsize=fontsize,
            color=txt, weight=weight, zorder=4, wrap=False)
    if sublabel:
        ax.text(x, y - h * 0.22, sublabel, ha="center", va="center",
                fontsize=subfontsize, color=TXT_DIM, zorder=4, style="italic")

def diamond(ax, x, y, w, h, label, color=C_CHECK, fontsize=8.5):
    dx, dy = w/2, h/2
    xs = [x,     x+dx, x,     x-dx, x    ]
    ys = [y+dy,  y,    y-dy,  y,    y+dy ]
    ax.fill(xs, ys, color=color, zorder=3)
    ax.plot(xs, ys, color="#30363d", linewidth=1.2, zorder=4)
    ax.text(x, y, label, ha="center", va="center", fontsize=fontsize,
            color=TXT, weight="bold", zorder=5)

def arrow(ax, x1, y1, x2, y2, label=None, color="#30363d", lw=1.5):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color,
                                lw=lw, mutation_scale=14),
                zorder=2)
    if label:
        mx, my = (x1+x2)/2, (y1+y2)/2
        ax.text(mx+0.12, my, label, fontsize=7.5, color=AMBER, va="center", zorder=5)

def section_label(ax, x, y, text, color=BLUE):
    ax.text(x, y, text, fontsize=8, color=color, weight="bold",
            va="center", zorder=5,
            bbox=dict(boxstyle="round,pad=0.3", facecolor="#161b22",
                      edgecolor=color, linewidth=1))

def param_panel(ax, x, y, w, h, title, lines, title_color=CYAN):
    patch = FancyBboxPatch((x, y), w, h,
                           boxstyle="round,pad=0.1,rounding_size=0.2",
                           facecolor=C_PARAM, edgecolor="#30363d",
                           linewidth=1, zorder=2)
    ax.add_patch(patch)
    ax.text(x + w/2, y + h - 0.28, title, ha="center", va="center",
            fontsize=8.5, color=title_color, weight="bold", zorder=4)
    # divider
    ax.plot([x+0.15, x+w-0.15], [y+h-0.52, y+h-0.52],
            color="#30363d", linewidth=0.8, zorder=3)
    line_h = (h - 0.65) / max(len(lines), 1)
    for i, (k, v) in enumerate(lines):
        ly = y + h - 0.65 - (i + 0.5) * line_h
        ax.text(x + 0.25, ly, k, fontsize=7.2, color=TXT_DIM, va="center", zorder=4)
        ax.text(x + w - 0.2, ly, v,  fontsize=7.2, color=TXT,     va="center",
                ha="right", zorder=4, weight="bold")

# ═══════════════════════════════════════════════════════════════════════════════
#  TITLE
# ═══════════════════════════════════════════════════════════════════════════════
ax.text(14, 47.4, "Alpaca Day Trading Bot", ha="center", va="center",
        fontsize=20, color=TXT, weight="bold")
ax.text(14, 46.9, "Full Logic & Parameters Flow  •  Paper Trading  •  GitHub Actions Automated",
        ha="center", va="center", fontsize=10, color=TXT_DIM)
ax.plot([0.5, 27.5], [46.55, 46.55], color="#30363d", linewidth=1)

# ═══════════════════════════════════════════════════════════════════════════════
#  COLUMN LAYOUT  (main flow centre=10, right panels x=19–27)
# ═══════════════════════════════════════════════════════════════════════════════
CX = 10   # centre x of main flow

# ── 1. GITHUB ACTIONS TRIGGER ─────────────────────────────────────────────────
Y = 45.8
box(ax, CX, Y, 7, 0.8, "GitHub Actions Cron Trigger",
    "Every 10 min  |  Mon–Fri  |  13:30–20:00 UTC  (6:30 AM–1 PM PT)",
    color=C_START, fontsize=10, subfontsize=8, bold=True)

arrow(ax, CX, Y-0.4, CX, Y-1.05, color=BLUE)

# ── 2. INSTALL PWSH & CHECKOUT ────────────────────────────────────────────────
Y = 44.6
box(ax, CX, Y, 7, 0.7, "Checkout Repo  →  Install PowerShell",
    "ubuntu-latest runner  •  timeout 8 min",
    color=C_PROC2, subfontsize=7.5)

arrow(ax, CX, Y-0.35, CX, Y-1.0, color=BLUE)

# ── 3. MARKET OPEN CHECK ─────────────────────────────────────────────────────
Y = 43.3
diamond(ax, CX, Y, 6, 0.9, "Market Open?\n(Alpaca Clock API)")

arrow(ax, CX, Y-0.45, CX, Y-1.1, color=GREEN, label="YES")
ax.annotate("", xy=(CX+5.5, Y), xytext=(CX+3, Y),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
box(ax, CX+6.8, Y, 2.4, 0.55, "EXIT — Save State",
    color=C_REJECT, fontsize=8)
ax.text(CX+4.5, Y+0.12, "NO", fontsize=7.5, color=RED)

# ── 4. TRADING WINDOW CHECK ──────────────────────────────────────────────────
Y = 41.95
diamond(ax, CX, Y, 6.2, 0.9, "Within Trading Window?\n09:45 – 15:30 ET")

arrow(ax, CX, Y-0.45, CX, Y-1.1, color=GREEN, label="YES")
ax.annotate("", xy=(CX+5.5, Y), xytext=(CX+3.1, Y),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
box(ax, CX+6.8, Y, 2.4, 0.55, "Monitor Only\nSave State",
    color=C_REJECT, fontsize=8)
ax.text(CX+4.5, Y+0.12, "NO", fontsize=7.5, color=RED)

# ── 5. MAX POSITIONS CHECK ───────────────────────────────────────────────────
Y = 40.6
diamond(ax, CX, Y, 6, 0.9, "Open Positions < 3?\n(Max Positions Check)")

arrow(ax, CX, Y-0.45, CX, Y-1.1, color=GREEN, label="YES")
ax.annotate("", xy=(CX+5.5, Y), xytext=(CX+3, Y),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
box(ax, CX+6.8, Y, 2.4, 0.55, "Max Positions\nReached — Skip",
    color=C_REJECT, fontsize=8)
ax.text(CX+4.5, Y+0.12, "NO", fontsize=7.5, color=RED)

# ── 6. WATCHLIST LOOP ────────────────────────────────────────────────────────
Y = 39.2
box(ax, CX, Y, 7, 0.75,
    "Iterate Watchlist: SPY  QQQ  AAPL  NVDA  TSLA  MSFT  AMD",
    color=C_PROC2, fontsize=9)

arrow(ax, CX, Y-0.38, CX, Y-1.0, color=BLUE)

# ── 7. FETCH BAR DATA ────────────────────────────────────────────────────────
Y = 37.95
box(ax, CX, Y, 7, 0.75, "Fetch Intraday Bars",
    "1-Min + 5-Min bars  •  Today 09:30 ET → Now  (Alpaca Data API)",
    color=C_PROC, subfontsize=7.5)

arrow(ax, CX, Y-0.38, CX, Y-1.0, color=BLUE)

# ── 8. SUFFICIENT DATA? ──────────────────────────────────────────────────────
Y = 36.65
diamond(ax, CX, Y, 6, 0.85, "Sufficient Data?\n≥20 x 1-min bars  |  ≥10 x 5-min bars")

arrow(ax, CX, Y-0.43, CX, Y-1.05, color=GREEN, label="YES")
ax.annotate("", xy=(CX+5.5, Y), xytext=(CX+3, Y),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
box(ax, CX+6.8, Y, 2.4, 0.5, "SKIP Symbol", color=C_REJECT, fontsize=8)
ax.text(CX+4.5, Y+0.12, "NO", fontsize=7.5, color=RED)

# ── 9. COMPUTE INDICATORS ────────────────────────────────────────────────────
Y = 35.3
box(ax, CX, Y, 7.5, 1.15, "Compute Technical Indicators",
    "EMA9 • EMA21 • RSI(14) • MACD • ATR(14) • VWAP • Opening Range (15-min ORB)",
    color=C_PROC, fontsize=9.5, subfontsize=8)

arrow(ax, CX, Y-0.58, CX, Y-1.2, color=BLUE)

# ── 10. STRATEGY SIGNALS ─────────────────────────────────────────────────────
Y = 33.65
section_label(ax, CX-3.5, Y+0.6, "  STRATEGY EVALUATION  ", color=PURPLE)

# Three strategy boxes side by side
bw = 3.8
for i, (sx, strat, detail) in enumerate([
    (CX-4.3, "ORB  (Opening Range Breakout)",
     "Price breaks 15-min high/low\nVolume > 1.5× avg  •  ATR filter"),
    (CX,     "VWAP Bounce",
     "Price dips to VWAP, reclaims\nRSI 35–60  •  Volume spike"),
    (CX+4.3, "EMA Pullback",
     "EMA9 > EMA21 (uptrend)\nPullback to EMA9, bounce candle"),
]):
    box(ax, sx, Y, bw-0.1, 1.0, strat, detail,
        color="#1a1a3a", fontsize=8.5, subfontsize=7.5)

arrow(ax, CX, Y-0.5, CX, Y-1.15, color=BLUE)

# ── 11. VALID SIGNAL? ────────────────────────────────────────────────────────
Y = 32.15
diamond(ax, CX, Y, 6, 0.85, "Valid Signal Found?\n(Confidence ≥ 65%  •  Entry / Stop / T1 / T2)")

arrow(ax, CX, Y-0.43, CX, Y-1.05, color=GREEN, label="YES")
ax.annotate("", xy=(CX+5.5, Y), xytext=(CX+3, Y),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
box(ax, CX+6.8, Y, 2.4, 0.5, "WATCH\n(no setup)", color=C_REJECT, fontsize=8)
ax.text(CX+4.5, Y+0.12, "NO", fontsize=7.5, color=RED)

# ── 12. RISK MANAGEMENT ──────────────────────────────────────────────────────
Y = 30.75
section_label(ax, CX-3.5, Y+0.62, "  RISK MANAGEMENT  ", color=AMBER)
box(ax, CX, Y, 7.5, 1.1, "Position Sizing  &  Risk Validation",
    "Shares = min( (Equity × 1%) ÷ ATR ,  BuyingPower ÷ MaxPositions × 80% )",
    color="#2a1a0a", fontsize=9.5, subfontsize=8)

arrow(ax, CX, Y-0.55, CX, Y-1.15, color=BLUE)

# ── 13. RISK CHECKS ──────────────────────────────────────────────────────────
Y = 29.25
# Four check boxes
checks = [
    (CX-5.25, "R:R Ratio\n≥ 2.5 : 1"),
    (CX-1.75, "Buying Power\nSufficient"),
    (CX+1.75, "Confidence\n≥ 65%"),
    (CX+5.25, "Max Positions\n< 3"),
]
for cx2, lbl in checks:
    box(ax, cx2, Y, 2.9, 0.75, lbl, color="#1a2a1a", fontsize=8.5)
    arrow(ax, CX, Y-0.38, CX, Y-1.0, color=BLUE)

arrow(ax, CX, Y-0.38, CX, Y-1.0, color=BLUE)

# ── 14. ALL CHECKS PASS? ─────────────────────────────────────────────────────
Y = 27.9
diamond(ax, CX, Y, 6, 0.85, "All Risk Checks Pass?")

arrow(ax, CX, Y-0.43, CX, Y-1.05, color=GREEN, label="YES")
ax.annotate("", xy=(CX+5.5, Y), xytext=(CX+3, Y),
            arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.5, mutation_scale=12), zorder=2)
box(ax, CX+6.8, Y, 2.4, 0.55, "REJECTED\nLog reason", color=C_REJECT, fontsize=8)
ax.text(CX+4.5, Y+0.12, "NO", fontsize=7.5, color=RED)

# ── 15. AUTO-EXECUTE ─────────────────────────────────────────────────────────
Y = 26.5
box(ax, CX, Y, 7.5, 1.0,
    "AUTO-EXECUTE  (paper_trading=true, require_approval=false)",
    "Submit Bracket Order to Alpaca Paper API",
    color=C_EXEC, fontsize=9.5, subfontsize=8, bold=True, txt=GREEN)

arrow(ax, CX, Y-0.5, CX, Y-1.1, color=GREEN)

# ── 16. BRACKET ORDER ────────────────────────────────────────────────────────
Y = 25.05
section_label(ax, CX-3.5, Y+0.62, "  BRACKET ORDER  ", color=GREEN)
bw2 = 4.5
for bx2, lbl, detail in [
    (CX-4.0, "Entry Order", "Limit Buy @ Signal Entry\nGTD (Good-Till-Day)"),
    (CX,     "Take Profit", "Limit Sell @ T1 target\nR:R ≥ 2.5 × risk"),
    (CX+4.0, "Stop Loss",   "Stop Sell @ Stop price\nATR-based distance"),
]:
    box(ax, bx2, Y, bw2-0.2, 0.95, lbl, detail,
        color="#0d2818" if "Profit" in lbl else
              "#2a1010" if "Stop"   in lbl else "#0d1f35",
        fontsize=8.5, subfontsize=7.5)

arrow(ax, CX, Y-0.48, CX, Y-1.05, color=BLUE)

# ── 17. ORDER LIFECYCLE ──────────────────────────────────────────────────────
Y = 23.65
box(ax, CX, Y, 7.5, 0.85, "Alpaca Manages Order Lifecycle",
    "Fills entry → monitors price → auto-triggers TP or SL when hit",
    color=C_PROC2, fontsize=9, subfontsize=8)

arrow(ax, CX, Y-0.43, CX, Y-1.05, color=BLUE)

# ── 18. TRADE OUTCOME ────────────────────────────────────────────────────────
Y = 22.25
for ox2, lbl, detail, col in [
    (CX-3.0, "WIN", "Take-profit filled\nP&L > 0", C_EXEC),
    (CX+3.0, "LOSS", "Stop-loss filled\nP&L < 0", C_REJECT),
]:
    box(ax, ox2, Y, 4.8, 0.85, lbl, detail, color=col, fontsize=10, bold=True)

arrow(ax, CX, Y-0.43, CX, Y-1.05, color=BLUE)

# ── 19. STATE UPDATE ─────────────────────────────────────────────────────────
Y = 20.9
box(ax, CX, Y, 7.5, 0.85, "Update State  →  Commit to GitHub",
    "alpaca_state.json  •  trades_today  wins  losses  pnl_today  last_scan",
    color=C_PROC, fontsize=9, subfontsize=7.5)

arrow(ax, CX, Y-0.43, CX, Y-1.05, color=BLUE)

# ── 20. DASHBOARD ────────────────────────────────────────────────────────────
Y = 19.5
box(ax, CX, Y, 7.5, 0.85, "Generate HTML Dashboard",
    "alpaca_dashboard.html  →  GitHub Artifact  →  Commit to repo",
    color=C_PROC2, fontsize=9, subfontsize=7.5)

arrow(ax, CX, Y-0.43, CX, Y-1.0, color=BLUE)

# ── 21. NEXT SYMBOL LOOP ─────────────────────────────────────────────────────
Y = 18.15
box(ax, CX, Y, 7, 0.75, "Next Symbol in Watchlist  (continue loop)",
    color=C_PROC2, fontsize=9)

# Loop-back arrow
ax.annotate("", xy=(CX-5.5, 39.2), xytext=(CX-5.5, Y),
            arrowprops=dict(arrowstyle="-|>", color="#30363d",
                            lw=1.2, mutation_scale=12,
                            connectionstyle="arc3,rad=0.0"), zorder=2)
ax.plot([CX-3.5, CX-5.5], [Y, Y], color="#30363d", lw=1.2, zorder=2)
ax.plot([CX-5.5, CX-5.5], [Y, 39.2], color="#30363d", lw=1.2, zorder=2)
ax.text(CX-6.3, (Y+39.2)/2, "next\nsymbol", fontsize=7, color=TXT_DIM,
        ha="center", va="center")

arrow(ax, CX, Y-0.38, CX, Y-1.0, color=BLUE)

# ── 22. WAIT FOR NEXT CRON ───────────────────────────────────────────────────
Y = 16.85
box(ax, CX, Y, 7, 0.75, "Runner Exits  •  Wait for Next Cron Fire  (10 min)",
    color=C_START, fontsize=9)

# ═══════════════════════════════════════════════════════════════════════════════
#  RIGHT PANEL — PARAMETERS
# ═══════════════════════════════════════════════════════════════════════════════
PX = 18.8   # left edge of panels
PW = 8.5

# Panel 1 – Account / Config
param_panel(ax, PX, 42.5, PW, 3.8, "ACCOUNT & CONFIG",
    [("Mode",             "Paper Trading"),
     ("Paper API URL",    "paper-api.alpaca.markets"),
     ("Data API URL",     "data.alpaca.markets"),
     ("Auth",             "APCA-API-KEY-ID headers"),
     ("Scheduler",        "GitHub Actions cron"),
     ("Runner",           "ubuntu-latest"),
     ("Timeout",          "8 minutes"),
     ("Concurrency",      "cancel-in-progress: false"),
    ], title_color=BLUE)

# Panel 2 – Watchlist
param_panel(ax, PX, 39.1, PW, 3.1, "WATCHLIST  (7 symbols)",
    [("1", "SPY  —  S&P 500 ETF"),
     ("2", "QQQ  —  Nasdaq ETF"),
     ("3", "AAPL — Apple"),
     ("4", "NVDA — Nvidia"),
     ("5", "TSLA — Tesla"),
     ("6", "MSFT — Microsoft"),
     ("7", "AMD  — AMD"),
    ], title_color=CYAN)

# Panel 3 – Risk Parameters
param_panel(ax, PX, 35.8, PW, 3.0, "RISK PARAMETERS",
    [("Max risk / trade",  "1.0% of equity"),
     ("Min R:R ratio",     "2.5 : 1"),
     ("Max positions",     "3 simultaneous"),
     ("Max position value","BP ÷ 3 × 80%  (~$53K)"),
     ("Stop type",         "ATR-based distance"),
     ("Order type",        "Bracket (entry+TP+SL)"),
    ], title_color=AMBER)

# Panel 4 – Trading Window
param_panel(ax, PX, 32.8, PW, 2.7, "TRADING WINDOW  (ET)",
    [("No trade before",   "09:45 AM ET"),
     ("No trade after",    "03:30 PM ET"),
     ("Cron window",       "09:25 AM–04:05 PM ET"),
     ("ORB period",        "First 15 minutes"),
     ("Scan interval",     "Every 10 minutes"),
    ], title_color=GREEN)

# Panel 5 – Indicators
param_panel(ax, PX, 29.5, PW, 3.0, "TECHNICAL INDICATORS",
    [("EMA Fast",          "EMA 9"),
     ("EMA Slow",          "EMA 21"),
     ("RSI period",        "14  (range 35–60 ideal)"),
     ("ATR period",        "14  (stop sizing)"),
     ("VWAP",              "Intraday (09:30 reset)"),
     ("MACD",              "12 / 26 / 9"),
    ], title_color=PURPLE)

# Panel 6 – ORB Strategy
param_panel(ax, PX, 26.5, PW, 2.7, "STRATEGY: ORB",
    [("ORB period",        "First 15 min candles"),
     ("Breakout trigger",  "Close > ORB high/low"),
     ("Volume filter",     "≥ 1.5× avg volume"),
     ("Entry",             "Limit @ breakout level"),
     ("Stop",              "Opposite ORB boundary"),
    ], title_color=PURPLE)

# Panel 7 – VWAP Strategy
param_panel(ax, PX, 23.6, PW, 2.6, "STRATEGY: VWAP BOUNCE",
    [("Signal",            "Price dips to VWAP"),
     ("Confirmation",      "Reclaim + RSI 35–60"),
     ("Volume",            "Spike on bounce"),
     ("Entry",             "Limit @ VWAP level"),
     ("Stop",              "Below VWAP - ATR"),
    ], title_color=PURPLE)

# Panel 8 – EMA Strategy
param_panel(ax, PX, 20.7, PW, 2.6, "STRATEGY: EMA PULLBACK",
    [("Trend filter",      "EMA9 > EMA21"),
     ("Signal",            "Price pulls to EMA9"),
     ("Confirmation",      "Green bounce candle"),
     ("RSI zone",          "45–65 (healthy zone)"),
     ("Entry",             "Limit @ EMA9 level"),
    ], title_color=PURPLE)

# Panel 9 – Position Sizing Formula
param_panel(ax, PX, 17.8, PW, 2.6, "POSITION SIZING FORMULA",
    [("Risk $ / trade",    "Equity × 1%"),
     ("Risk shares",       "Risk$ ÷ ATR"),
     ("BP cap shares",     "(BP ÷ 3) × 80% ÷ Entry"),
     ("Final shares",      "min(risk shares, BP cap)"),
     ("Actual risk",       "Shares × (Entry − Stop)"),
    ], title_color=AMBER)

# Panel 10 – GitHub Actions
param_panel(ax, PX, 14.9, PW, 2.6, "GITHUB ACTIONS WORKFLOW",
    [("Repo",              "arminherabit/alpaca-trading-bot"),
     ("Workflow",          "alpaca_bot.yml"),
     ("Trigger",           "schedule + workflow_dispatch"),
     ("Cron (UTC)",        "0,10,20,30,40,50 13-20 * * 1-5"),
     ("Persists",          "state.json + dashboard.html"),
    ], title_color=BLUE)

# ═══════════════════════════════════════════════════════════════════════════════
#  LEGEND
# ═══════════════════════════════════════════════════════════════════════════════
leg_x, leg_y = 0.5, 15.8
ax.text(leg_x, leg_y, "LEGEND", fontsize=8, color=TXT_DIM, weight="bold")
for i, (col, lbl) in enumerate([
    (C_START,  "Trigger / Terminal"),
    (C_CHECK,  "Decision"),
    (C_PROC,   "Process"),
    (C_PROC2,  "Sub-process"),
    (C_EXEC,   "Execute Trade"),
    (C_REJECT, "Reject / Stop"),
]):
    lx = leg_x + (i % 3) * 2.8
    ly = leg_y - 0.55 - (i // 3) * 0.55
    rect = FancyBboxPatch((lx, ly-0.18), 0.4, 0.35,
                          boxstyle="round,pad=0.04", facecolor=col,
                          edgecolor="#30363d", linewidth=0.8, zorder=3)
    ax.add_patch(rect)
    ax.text(lx+0.55, ly, lbl, fontsize=7.2, color=TXT_DIM, va="center", zorder=4)

# Footer
ax.plot([0.5, 27.5], [0.55, 0.55], color="#30363d", linewidth=0.8)
ax.text(14, 0.3, "Alpaca Day Trading Bot  •  Paper Mode  •  Auto-generated diagram  •  arminherabit/alpaca-trading-bot",
        ha="center", va="center", fontsize=7.5, color=TXT_DIM)

# ── Save ──────────────────────────────────────────────────────────────────────
out = "D:/Claude-code/Alpaca/alpaca_bot_flow.png"
plt.savefig(out, dpi=200, bbox_inches="tight",
            facecolor=BG, edgecolor="none")
plt.close()
print(f"Saved: {out}")
