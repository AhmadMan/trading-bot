"""Central configuration — gold-only (XAUUSD) ICT/SMC engine.

Rebuilt from a 9-asset, 5-competing-engine system (scalp_engine + swing_engine
+ council + forecast_engine + btc_deep_pipeline, each with their own scoring
method) down to ONE deterministic engine (gold_engine.py) focused entirely on
XAUUSD, because running five different methods in parallel on nine assets was
producing exactly the kind of cross-engine disagreement (and debate-gated
NO_TRADE deadlock) that made signals rare and inconsistent."""

import os

try:
    from dotenv import load_dotenv
    load_dotenv()   # loads a local .env file if present — no-op in GitHub Actions
except ImportError:
    pass

# ── Credentials ───────────────────────────────────────────────────────────────
TELEGRAM_TOKEN   = os.environ.get("TELEGRAM_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
TELEGRAM_URL     = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"

TWELVEDATA_KEY   = os.environ.get("TWELVEDATA_KEY", "")

GEMINI_API_KEY   = os.environ.get("GEMINI_API_KEY", "")
# All LLM text — macro synthesis, signal reasoning, the Arabic executive
# summary — now runs through the google-genai SDK (Interactions API) via
# gemini_text() below. One model, one key; the old Ollama Cloud endpoint was
# removed. genai.Client() reads GEMINI_API_KEY / GOOGLE_API_KEY from the env.
GEMINI_MODEL     = os.environ.get("GEMINI_MODEL", "gemini-3.7-flash")


# ── Gemini text helper (shared LLM synthesis) ─────────────────────────────────
# Lazily-built single client, reused by gold_engine (signal reasoning),
# macro_agent (macro synthesis) and daily_brief (Arabic summary). Mirrors the
# proven interactions.create(model=, input=) call already used for the
# Google-Search-grounded macro gather.
_genai_client = None


def _gemini_client():
    global _genai_client
    if _genai_client is None:
        from google import genai
        _genai_client = genai.Client()  # reads GEMINI_API_KEY / GOOGLE_API_KEY
    return _genai_client


def gemini_text(system: str, user: str, *, search: bool = False) -> str:
    """Free-form text synthesis via Gemini. Returns the stripped output, or ""
    on any failure (every caller supplies its own fallback). `system` is folded
    into the single `input` string the Interactions API expects."""
    if not GEMINI_API_KEY:
        return ""
    prompt = f"{system.strip()}\n\n{user.strip()}" if system else user
    kwargs = {"model": GEMINI_MODEL, "input": prompt}
    if search:
        kwargs["tools"] = [{"type": "google_search"}]
    try:
        interaction = _gemini_client().interactions.create(**kwargs)
        return (interaction.output_text or "").strip()
    except Exception as e:
        print(f"  [Gemini] text synthesis failed: {e}")
        return ""

# GitHub Pages URL for the dashboard (repo made public, Pages serving /docs).
# Override via env var if you host it elsewhere (Cloudflare Pages, Vercel, a
# custom domain, etc.) — Telegram messages link here for "full report" reads.
DASHBOARD_URL = os.environ.get("DASHBOARD_URL", "https://ahmadman1991.github.io/trading-bot")

_missing = [n for n, v in [("TELEGRAM_TOKEN", TELEGRAM_TOKEN), ("TWELVEDATA_KEY", TWELVEDATA_KEY)] if not v]
if _missing:
    print(f"  [config] WARNING: missing env secrets: {', '.join(_missing)} "
          f"(set them as repo secrets — see README)")

# ── Account & Risk ────────────────────────────────────────────────────────────
ACCOUNT_SIZE  = float(os.environ.get("ACCOUNT_SIZE") or 1000)
RISK_PCT      = 0.01

# ── Indicators ────────────────────────────────────────────────────────────────
EMA_FAST = 20; EMA_MID = 50; EMA_SLOW = 200
ATR_PERIOD = RSI_PERIOD = 14
CHART_BARS = 150

# ── COT ───────────────────────────────────────────────────────────────────────
COT_EXTREME_LONG  = 75
COT_EXTREME_SHORT = 25
COT_LOOKBACK      = 25

# ── News agent (red-folder USD pre/post alerts) ───────────────────────────────
NEWS_PRE_ALERT_MIN    = 15   # send the "coming up" alert this many minutes before release
NEWS_PRE_ALERT_WINDOW = 6    # tolerance window (minutes) around that mark, matched to the 5-min poll cadence
NEWS_WATCH_CURRENCIES = ["USD"]   # extend later, e.g. ["USD", "EUR"]
NEWS_POST_GRACE_MIN   = 15   # if "actual" still hasn't populated this many minutes after
                              # release, send a fallback "released, no numeric print" alert
                              # instead of waiting forever — covers qualitative events (FOMC
                              # Minutes, speeches, testimony) that never get a numeric actual,
                              # and numeric releases where the free calendar feed lags/never fills it in

# ── Tracer / live position updater ────────────────────────────────────────────
TRACER_MILESTONES = [0.5, 0.75, 1.0]   # fraction of the way to TP1/SL that triggers a Telegram nudge

# ── Markets ───────────────────────────────────────────────────────────────────
# Gold only. dollar_bias() in data_feeds.py still reads a raw EUR/USD quote
# for USD-direction context — that's a background input, not a second traded
# market, so it doesn't need its own MARKETS entry.
MARKETS = {
    "XAUUSD": {
        "td": "XAU/USD", "yf": "GC=F", "iw_path": "gold",
        "cot_name": "GOLD - COMMODITY EXCHANGE INC.",
        "asset_class": "commodity", "pip_digits": 2, "pip_usd": None,
        "sessions_utc": [(7, 21)], "rsi_os": 30, "rsi_ob": 70,
        "decimals": 2, "emoji": "🥇", "name": "Gold",
    },
    # BTC + EUR are handled by the additive multi_asset.py layer (same
    # deterministic engine as gold), added to consolidate the retired
    # scalp-council's coverage into the one validated engine.
    "BTCUSD": {
        "td": "BTC/USD", "yf": "BTC-USD", "asset_class": "crypto",
        "decimals": 2, "emoji": "₿", "name": "Bitcoin",
        "session_gated": False, "weekend": True,   # crypto trades 24/7
    },
    "EURUSD": {
        "td": "EUR/USD", "yf": "EURUSD=X", "asset_class": "fx",
        "decimals": 5, "emoji": "🇪🇺", "name": "Euro",
        "session_gated": True, "weekend": False,   # FX: London/NY, weekdays
    },
}

# ── Multi-asset layer (BTC + EUR via the same engine) ────────────────────────
# Set MULTI_ASSET=0 as an env var to run gold-only (the original behaviour).
MULTI_ASSET_ENABLED = os.environ.get("MULTI_ASSET", "1") != "0"
EXTRA_ASSETS = ["BTCUSD", "EURUSD"]
EXTRA_MAX_TRADES_PER_DAY = 3   # per-asset daily cap for BTC/EUR (independent of gold)

# ── Gold engine — ICT/SMC concepts ────────────────────────────────────────────
# One deterministic engine, not a multi-agent debate: confluence of these
# factors produces a confidence score directly, so there's no "agents
# disagree -> NO_TRADE" deadlock possible.
GOLD_SESSIONS_UTC = [
    (7, 16, "London/NY"),
]   # highest-liquidity window — outside this, the scalp scan doesn't run.
    # Rebuilt to ONE continuous 07-16 UTC window (was two split killzones
    # 07-10 + 12-16). The 10-12 gap was excluding perfectly good London-close/
    # NY-premarket pullback setups, and the boundary bug (hour < end meant the
    # whole :00-:59 of hour 16 was already "outside") cost the last hour too.
    # A month-long GC=F backtest showed the continuous window is where the
    # trend-pullback edge lives. Adjust if you trade a different focus.

GOLD_JUDAS_WINDOW_MIN   = 60     # first N minutes of a session — actively watched
                                  # for a sweep-then-reverse (the "Judas Swing"),
                                  # not filtered out, since that reversal IS the setup
GOLD_IMPULSE_ATR_MULT   = 1.5    # a move counts as "impulsive" (order-block-forming)
                                  # if its range exceeds this many x current ATR
GOLD_SWEEP_LOOKBACK     = 20     # bars searched for the swing high/low being swept
GOLD_STRUCTURE_LOOKBACK = 40     # bars used for H4/H1 higher-high/lower-low structure

# ── Risk geometry — TRADE-TYPE AWARE ─────────────────────────────────────────
# The old build used ONE stop formula (min(low,ema20) - 0.6*ATR) for BOTH
# scalp and swing. On the 1h swing frame that collapsed to a $1-5 stop when
# price sat on the EMA — not a swing, not even a scalp. And scalp targets were
# scaled off that tiny risk, so they sat oddly far for a quick trade. Scalp and
# swing are different trades and now get different geometry.
#
# Stop = structural swing low/high over LOOKBACK bars, buffered by STOP_ATR x
# ATR, then CLAMPED to [MIN_STOP_PCT, MAX_STOP_PCT] of price — so gold (≈$4500)
# always gets a sane absolute stop, never a micro-stop. Targets are R multiples
# of that clamped risk. Profiles: (lookback, stop_atr, min_pct, max_pct, (tp1,tp2,tp3)).
GOLD_SCALP_RISK = {
    "lookback":  10,       # M15 bars for the structural stop reference
    "stop_atr":  0.8,      # buffer beyond that swing low/high, in M15 ATRs
    "min_pct":   0.0012,   # >= 0.12% of price  (~$5.4 @ 4500) — a real scalp stop
    "max_pct":   0.005,    # <= 0.50% of price  (~$22   @ 4500)
    "tp":        (1.0, 1.6, 2.5),   # NEAR targets — scalps bank quickly
}
GOLD_SWING_RISK = {
    "lookback":  20,       # H1 bars for the structural stop reference
    "stop_atr":  1.2,      # buffer beyond the swing, in H1 ATRs
    "min_pct":   0.005,    # >= 0.50% of price  (~$22  @ 4500) — real swing room
    "max_pct":   0.025,    # <= 2.50% of price  (~$112 @ 4500)
    "tp":        (1.5, 3.0, 5.0),   # WIDE targets — multi-day holds run further
}

# Back-compat aliases (some tooling/telegram reads these). Default = scalp TP1.
GOLD_ATR_STOP_BUFFER    = 0.8
GOLD_TP1_RR             = 1.0
GOLD_TP2_RR             = 1.6
GOLD_TP3_RR             = 2.5

# ADX regime gate — the single biggest quality lever in the rebuild backtest:
# ADX>=18 lifted win-rate ~36%->52% and monthly expectancy ~+5R->+16R by
# refusing to take pullback entries in chop. Raise toward 20-25 for fewer,
# cleaner trades; lower toward 15 for more (noisier) ones.
GOLD_ADX_MIN            = 18

GOLD_MIN_CONFIDENCE     = 0.55   # minimum confluence score to fire a signal
GOLD_SCALP_COOLDOWN_MIN = 45     # don't re-fire a scalp signal within this many minutes
GOLD_SWING_COOLDOWN_H   = 6      # don't re-fire a swing signal within this many hours

GOLD_DAILY_LOSS_LIMIT_PCT = 0.03   # stop trading for the rest of the day after
                                    # losing this % of account equity
GOLD_MAX_TRADES_PER_DAY   = 4      # hard cap on fired signals/day (scalp+swing
                                    #  combined). Backtest averages ~1.8 scalp +
                                    #  swing, so 4 is headroom, not a target — the
                                    #  ADX+confluence gates are what keep it honest.
