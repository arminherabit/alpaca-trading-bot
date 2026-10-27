"""
Generate flow diagrams for BTC and Alpaca trading bots.
Outputs: btc_flow.png, alpaca_flow.png
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import matplotlib.patheffects as pe

# ── Colour palette ──────────────────────────────────────────────────────────
C = {
    "bg":       "#0d1117",
    "start":    "#238636",
    "stop":     "#da3633",
    "decision": "#d29922",
    "action":   "#1f6feb",
    "data":     "#8957e5",
    "warn":     "#e85010",
    "text":     "#f0f6fc",
    "subtext":  "#8b949e",
    "edge":     "#30363d",
    "arrow":    "#58a6ff",
}

def make_fig(title, w=14, h=22):
    fig = plt.figure(figsize=(w, h), facecolor=C["bg"])
    ax  = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, w); ax.set_ylim(0, h)
    ax.axis("off")
    ax.set_facecolor(C["bg"])
    fig.text(0.5, 0.975, title, ha="center", va="top",
             fontsize=18, fontweight="bold", color=C["text"],
             fontfamily="monospace")
    return fig, ax

def box(ax, x, y, w, h, label, sublabel="", color=C["action"],
        shape="round,pad=0.05", fontsize=9):
    b = FancyBboxPatch((x - w/2, y - h/2), w, h,
                        boxstyle=shape, linewidth=1.2,
                        edgecolor=color, facecolor=color + "33",
                        zorder=3)
    ax.add_patch(b)
    ax.text(x, y + (0.10 if sublabel else 0), label,
            ha="center", va="center", fontsize=fontsize,
            fontweight="bold", color=C["text"], zorder=4, wrap=True,
            multialignment="center")
    if sublabel:
        ax.text(x, y - 0.20, sublabel, ha="center", va="center",
                fontsize=7, color=C["subtext"], zorder=4,
                multialignment="center")

def diamond(ax, x, y, w, h, label, color=C["decision"]):
    dx, dy = w/2, h/2
    pts = [[x, y+dy],[x+dx, y],[x, y-dy],[x-dx, y]]
    poly = plt.Polygon(pts, closed=True, linewidth=1.2,
                        edgecolor=color, facecolor=color + "33", zorder=3)
    ax.add_patch(poly)
    ax.text(x, y, label, ha="center", va="center", fontsize=8,
            fontweight="bold", color=C["text"], zorder=4,
            multialignment="center")

def arrow(ax, x1, y1, x2, y2, label="", color=C["arrow"]):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color,
                                lw=1.5, mutation_scale=14), zorder=2)
    if label:
        mx, my = (x1+x2)/2, (y1+y2)/2
        ax.text(mx + 0.12, my, label, fontsize=7.5,
                color=C["decision"], fontweight="bold", zorder=5)

def side_arrow(ax, x1, y1, x2, y2, label=""):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=C["warn"],
                                lw=1.4, linestyle="dashed",
                                mutation_scale=12), zorder=2)
    if label:
        mx, my = (x1+x2)/2 + 0.1, (y1+y2)/2
        ax.text(mx, my, label, fontsize=7, color=C["warn"],
                fontweight="bold", zorder=5)

def legend(ax, items, x, y):
    for i, (color, label) in enumerate(items):
        b = FancyBboxPatch((x, y - i*0.42), 0.28, 0.28,
                            boxstyle="round,pad=0.04", linewidth=1,
                            edgecolor=color, facecolor=color+"33")
        ax.add_patch(b)
        ax.text(x + 0.38, y - i*0.42 + 0.14, label,
                fontsize=7.5, color=C["subtext"], va="center")

# ════════════════════════════════════════════════════════════════════════════
#  ALPACA DIAGRAM
# ════════════════════════════════════════════════════════════════════════════
def draw_alpaca():
    fig, ax = make_fig("Alpaca Day Trading Bot  —  GitHub Actions Flow", 14, 24)
    cx = 7.0   # centre x

    # ── Nodes (x, y, label, sublabel, color) ──
    nodes = [
        # y=23 start
        (cx, 22.8, "GitHub Actions\nCron Trigger", "*/5 13-20 UTC  Mon–Fri", C["start"]),
        (cx, 21.6, "Checkout Repo\n+ Load State", "alpaca_state.json", C["data"]),
        (cx, 20.4, "Market Open?\n(Alpaca /v2/clock)", "", C["decision"]),
        (cx, 19.0, "Trading Window?\n09:45 – 15:30 ET", "", C["decision"]),
        (cx, 17.8, "Positions < 3?", "", C["decision"]),
        (cx, 16.6, "Fetch Intraday Bars\n1-min + 5-min", "alpaca_client.ps1", C["action"]),
        # strategies
        (3.5, 15.0, "ORB\nBreakout", "First 15-min\nhigh/low", C["action"]),
        (cx,  15.0, "VWAP\nBounce",  "Dip + reclaim", C["action"]),
        (10.5,15.0, "EMA\nPullback", "9/21 EMA bounce", C["action"]),
        # merge
        (cx, 13.6, "Best Signal?\nConf ≥ 65%  R:R ≥ 2.5", "", C["decision"]),
        (cx, 12.2, "Validate Risk\n1% Rule + Buying Power", "alpaca_risk.ps1", C["action"]),
        (cx, 10.8, "Risk OK?", "", C["decision"]),
        (cx,  9.5, "Size Position\nshares = equity×1% ÷ risk/share", "", C["action"]),
        (cx,  8.2, "Submit Bracket Order\nEntry + Stop + Take-Profit", "alpaca_client.ps1", C["action"]),
        (cx,  6.9, "Order Filled?", "", C["decision"]),
        (cx,  5.7, "Update State\ntrades++ / P&L", "alpaca_state.json", C["data"]),
        (cx,  4.5, "Commit State\nto GitHub Repo", "[skip ci]", C["data"]),
        (cx,  3.3, "SMS via Twilio\n(on trade only)", "TWILIO_* secrets", C["data"]),
        (cx,  2.1, "VM Shuts Down\nUntil Next Trigger", "", C["stop"]),
    ]

    for (x, y, lbl, sub, col) in nodes:
        if col == C["decision"]:
            diamond(ax, x, y, 3.8, 0.70, lbl, col)
        else:
            box(ax, x, y, 3.4, 0.68, lbl, sub, col)

    # ── Main vertical arrows ──
    ys = [22.8, 21.6, 20.4, 19.0, 17.8, 16.6]
    for i in range(len(ys)-1):
        arrow(ax, cx, ys[i]-0.34, cx, ys[i+1]+0.34)

    # 16.6 → fan out to strategies
    arrow(ax, 3.5, 16.26, 3.5, 15.34)
    arrow(ax, cx,  16.26, cx,  15.34)
    arrow(ax, 10.5,16.26, 10.5,15.34)
    ax.annotate("", xy=(3.5, 16.26), xytext=(cx, 16.26),
                arrowprops=dict(arrowstyle="-", color=C["arrow"], lw=1.5))
    ax.annotate("", xy=(10.5, 16.26), xytext=(cx, 16.26),
                arrowprops=dict(arrowstyle="-", color=C["arrow"], lw=1.5))

    # strategies → merge point 13.6
    for sx in [3.5, cx, 10.5]:
        arrow(ax, sx, 14.66, cx if sx != cx else cx, 13.94)
    ax.annotate("", xy=(cx, 13.94), xytext=(3.5, 14.66),
                arrowprops=dict(arrowstyle="-|>", color=C["arrow"], lw=1.5))
    ax.annotate("", xy=(cx, 13.94), xytext=(10.5, 14.66),
                arrowprops=dict(arrowstyle="-|>", color=C["arrow"], lw=1.5))

    # continue vertical
    pairs = [(13.6,12.2),(12.2,10.8),(10.8,9.5),(9.5,8.2),(8.2,6.9),
             (6.9,5.7),(5.7,4.5),(4.5,3.3),(3.3,2.1)]
    for (ya, yb) in pairs:
        arrow(ax, cx, ya-0.35, cx, yb+0.35)

    # ── NO side exits ──
    # Market closed
    side_arrow(ax, cx+1.9, 20.4, 11.8, 20.4, "Closed")
    box(ax, 12.5, 20.4, 1.6, 0.55, "Sleep\n60 s", "", C["warn"])
    # Outside window
    side_arrow(ax, cx+1.9, 19.0, 11.8, 19.0, "Outside")
    box(ax, 12.5, 19.0, 1.6, 0.55, "Monitor\nOnly", "", C["warn"])
    # Max positions
    side_arrow(ax, cx+1.9, 17.8, 11.8, 17.8, "Full")
    box(ax, 12.5, 17.8, 1.6, 0.55, "Skip\nEntries", "", C["warn"])
    # No signal
    side_arrow(ax, cx+1.9, 13.6, 11.8, 13.6, "None")
    box(ax, 12.5, 13.6, 1.6, 0.55, "WATCH\nLog", "", C["warn"])
    # Risk fail
    side_arrow(ax, cx+1.9, 10.8, 11.8, 10.8, "Fail")
    box(ax, 12.5, 10.8, 1.6, 0.55, "Discard\nTrade", "", C["warn"])
    # Order fail
    side_arrow(ax, cx+1.9, 6.9, 11.8, 6.9, "No")
    box(ax, 12.5, 6.9,  1.6, 0.55, "Log\nError", "", C["warn"])

    # Yes labels on decisions
    for y in [20.4, 19.0, 17.8, 13.6, 10.8, 6.9]:
        ax.text(cx - 0.25, y - 0.52, "Yes", fontsize=7.5,
                color=C["start"], fontweight="bold")

    # Legend
    legend(ax, [
        (C["start"],    "Start / Stop"),
        (C["action"],   "Process / Action"),
        (C["decision"], "Decision Gate"),
        (C["data"],     "Data / State"),
        (C["warn"],     "Exit / Skip path"),
    ], 0.4, 22.0)

    fig.savefig("alpaca_flow.png", dpi=150, bbox_inches="tight",
                facecolor=C["bg"])
    plt.close(fig)
    print("alpaca_flow.png saved.")


# ════════════════════════════════════════════════════════════════════════════
#  BTC DIAGRAM
# ════════════════════════════════════════════════════════════════════════════
def draw_btc():
    fig, ax = make_fig("BTC Dip Ladder Bot  —  GitHub Actions Flow", 14, 24)
    cx = 7.0

    nodes = [
        (cx, 22.8, "GitHub Actions\nCron Trigger", "Every hour  24 / 7", C["start"]),
        (cx, 21.6, "Checkout Repo\n+ Load Config", "btc_config.json\nbtc_state.json", C["data"]),
        (cx, 20.3, "Fetch BTC Price\n+ 4H Klines", "Binance.US  /api/v3", C["action"]),
        (cx, 19.0, "Compute Indicators\nRSI(14)  Dip%  Volume", "btc_indicators.ps1", C["action"]),
        (cx, 17.7, "Get News Sentiment\n(Claude AI)", "btc_news.ps1\nANTHROPIC_API_KEY", C["data"]),
        (cx, 16.4, "News Score\n≤ –5 (Block)?", "", C["decision"]),
        # in position check
        (cx, 15.1, "In Position?", "", C["decision"]),
        # exit branch
        (3.5,13.6, "Check Exit\nConditions", "RSI ≥ 60\nTrail / Hard stop", C["action"]),
        (3.5,12.3, "Exit Signal?", "", C["decision"]),
        (3.5,11.0, "SELL All BTC\nMarket Order", "Binance.US", C["stop"]),
        # entry branch
        (10.5,13.6,"Check Entry\nConditions", "RSI threshold\nDip% + Volume", C["action"]),
        (10.5,12.3,"Buy Signal?", "", C["decision"]),
        (10.5,11.0,"BUY Tranche\n$167 Market Order", "T1/T2/T3 ladder", C["start"]),
        # merge
        (cx,  9.5, "Update State\ntranche_count / avg_entry", "btc_state.json", C["data"]),
        (cx,  8.2, "Generate Dashboard\ndashboard.html", "btc_indicators.ps1", C["action"]),
        (cx,  7.0, "Commit State\nto GitHub Repo", "[skip ci]", C["data"]),
        (cx,  5.8, "Send SMS\nvia Twilio", "Signal + Tranches\n+ Avg Entry", C["data"]),
        (cx,  4.5, "VM Shuts Down\nUntil Next Hour", "", C["stop"]),
    ]

    for (x, y, lbl, sub, col) in nodes:
        if col == C["decision"]:
            diamond(ax, x, y, 3.8, 0.70, lbl, col)
        else:
            box(ax, x, y, 3.4, 0.68, lbl, sub, col)

    # ── Main top arrows ──
    for ya, yb in [(22.8,21.6),(21.6,20.3),(20.3,19.0),(19.0,17.7),(17.7,16.4)]:
        arrow(ax, cx, ya-0.34, cx, yb+0.34)

    # News block → skip to state
    side_arrow(ax, cx-1.9, 16.4, 2.2, 16.4, "Blocked")
    box(ax, 1.4, 16.4, 1.4, 0.55, "NEWS\nBLOCK", "", C["warn"])

    # 16.4 Yes → In Position
    arrow(ax, cx, 16.05, cx, 15.44, "Clear")

    # In Position → exit (left) and entry (right)
    arrow(ax, cx-1.9, 15.1, 3.5+1.7, 15.1)
    ax.annotate("", xy=(3.5+1.7, 15.1), xytext=(cx-1.9, 15.1),
                arrowprops=dict(arrowstyle="-|>", color=C["arrow"], lw=1.5))
    arrow(ax, cx+1.9, 15.1, 10.5-1.7, 15.1)
    ax.annotate("", xy=(10.5-1.7, 15.1), xytext=(cx+1.9, 15.1),
                arrowprops=dict(arrowstyle="-|>", color=C["arrow"], lw=1.5))
    ax.text(4.5, 15.2, "Yes", fontsize=7.5, color=C["start"], fontweight="bold")
    ax.text(8.8, 15.2, "No", fontsize=7.5, color=C["warn"], fontweight="bold")

    # Exit branch
    arrow(ax, 3.5, 15.1-0.34, 3.5, 13.6+0.34)
    arrow(ax, 3.5, 13.6-0.34, 3.5, 12.3+0.34)
    arrow(ax, 3.5, 12.3-0.34, 3.5, 11.0+0.34, "Yes")
    # Exit No → merge
    side_arrow(ax, 3.5+1.9, 12.3, cx-1.9, 9.6, "No / Hold")

    # Entry branch
    arrow(ax, 10.5, 15.1-0.34, 10.5, 13.6+0.34)
    arrow(ax, 10.5, 13.6-0.34, 10.5, 12.3+0.34)
    arrow(ax, 10.5, 12.3-0.34, 10.5, 11.0+0.34, "Yes")
    # Entry No → merge
    side_arrow(ax, 10.5-1.9, 12.3, cx+1.9, 9.6, "No")

    # Sell + Buy → merge
    arrow(ax, 3.5, 11.0-0.34, cx-1.9, 9.6)
    arrow(ax, 10.5, 11.0-0.34, cx+1.9, 9.6)

    # Continue vertical
    for ya, yb in [(9.5,8.2),(8.2,7.0),(7.0,5.8),(5.8,4.5)]:
        arrow(ax, cx, ya-0.34, cx, yb+0.34)

    # Legend
    legend(ax, [
        (C["start"],    "Start / Buy signal"),
        (C["stop"],     "Stop / Sell signal"),
        (C["action"],   "Process / Indicator"),
        (C["decision"], "Decision Gate"),
        (C["data"],     "Data / State / API"),
        (C["warn"],     "Exit / Block path"),
    ], 0.4, 22.2)

    fig.savefig("btc_flow.png", dpi=150, bbox_inches="tight",
                facecolor=C["bg"])
    plt.close(fig)
    print("btc_flow.png saved.")


if __name__ == "__main__":
    draw_alpaca()
    draw_btc()
    print("Done.")
