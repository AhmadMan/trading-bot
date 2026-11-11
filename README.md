# Gold Bot — XAUUSD ICT/SMC System

One deterministic engine, one asset: **XAUUSD only**, scalp + swing + intraday,
built around ICT/Smart-Money-Concepts detection (liquidity sweeps, order
blocks, fair value gaps, session killzones) with additive confluence scoring.

**This system only sends alerts (Telegram + dashboard). It does not place
real trades or connect to a broker.** You decide whether to act on a signal.

## Why gold-only, why one engine

This was originally a 9-asset system running five different, philosophically
different scoring engines in parallel: indicator-threshold scoring
(`scalp_engine.py`, `swing_engine.py`), multi-agent debate/voting
(`council.py`), and ICT/SMC-style detection (`forecast_engine.py`,
`btc_deep_pipeline.py`/`deep_pipeline.py`). Running all five across nine
assets produced exactly the "no real signals, and the ones that fire
disagree with each other" complaint that prompted this rebuild — a legitimate
1-bull/3-bear/3-neutral council split on BTCUSD, for example, is a
correctly-conservative NO_TRADE, but it's also a deadlock: five engines with
five different opinions, none of them wrong exactly, none of them useful
together.

The rebuild removes four of the five engines and the multi-agent voting
model entirely, narrows scope to the one asset actually worth this much
attention, and replaces "agents debate, majority wins" with **additive
confluence scoring** — each factor (session liquidity sweep, higher-timeframe
structure agreement, order block/FVG confluence, COT positioning) adds to a
single confidence number. Disagreement lowers confidence instead of
blocking the trade outright, so there's no debate-gated deadlock possible.

## The pipeline (`python main.py`, no flags)

```
COT  →  Macro (Gemini)  →  Gold Bias  →  Gold Scalp  →  Gold Swing  →  Performance
```

| # | Step | What it does |
|---|---|---|
| 1 | `cot_agent.py` | Official CFTC gold positioning (insider-week.com fallback). Cached 180 min. Read as an additive input downstream, never a veto. |
| 2 | `macro_agent.py` | Gemini (Google Search grounded) gathers a live factual brief — Fed stance, DXY/yields, risk sentiment, next 14 days of high-impact US calendar — then Gemini synthesizes it. Optional — skips cleanly if `GEMINI_API_KEY` isn't set. |
| 3 | `gold_engine.run_gold_bias()` | H4 EMA-stack + swing-structure read (BULLISH/BEARISH/NEUTRAL) + COT + USD-proxy context. Informational — surfaced on its own, doesn't gate scalp/swing. |
| 4 | `gold_engine.run_gold_scalp()` | **Session-gated** (London 07-10 UTC / NY 12-16 UTC killzones only). Detects a liquidity sweep on M15 (stop hunt beyond a recent swing high/low that reverses) — the core entry trigger — then scores confluence: HTF structure agreement, order block/FVG overlap, COT alignment, Judas Swing context. Fires only above `GOLD_MIN_CONFIDENCE` (0.55), gated by cooldown, daily loss limit, and trade-count cap. |
| 5 | `gold_engine.run_gold_swing()` | Same detection logic on H1/H4 for multi-day structure, not session-gated (swing doesn't need killzone timing) — still risk/cooldown/news gated. |
| 6 | `performance_tracker.py` | Resolves open signals (TP1/TP2/STOP/EXPIRED), posts a scorecard, feeds outcomes back into the daily-loss circuit breaker, refreshes dashboard stats. |

Runs **every 30 minutes, 07-16 UTC weekdays** (`pipeline.yml`) — spans both
killzones plus the gap between them, since bias/swing aren't session-gated
even though scalp is. Every step is individually runnable:

```bash
python main.py --layer cot
python main.py --layer macro
python main.py --layer gold_bias
python main.py --layer gold_scalp
python main.py --layer gold_swing
python main.py --layer performance
```

### ICT/SMC concepts used

- **Liquidity sweep** — price exceeds a recent swing high/low (hunting the
  stops resting there) then closes back inside it. This is the entry
  trigger, not a filter — the reversal *is* the setup.
- **Judas Swing** — the first `GOLD_JUDAS_WINDOW_MIN` (60) minutes of a
  session are watched specifically for a sweep-then-reverse, since that's
  a classic false-move-then-real-move pattern at session open.
- **Order blocks** — the last opposing candle before an impulsive move
  (>`GOLD_IMPULSE_ATR_MULT` × ATR range), used as a confluence zone.
- **Fair value gaps** — 3-candle imbalances, same role as order blocks.
- **Session killzones** — London and NY overlap windows are when gold's
  liquidity (and therefore sweep reliability) is highest; scalp only scans
  inside them.
- **Structure bias** — EMA stack (20>50>200 bullish / reverse for bearish)
  plus higher-high/higher-low vs lower-high/lower-low swing sequencing.

All of this lives in `gold_engine.py` — one file, no cross-engine handoff.

### Signal taxonomy

Carried forward from the old BTC-only `btc_deep_pipeline.py` (where this
labeling scheme was first built), trimmed to the labels that make sense for
gold: `SNIPER`, `HIGH_PROBABILITY`, `WYCKOFF_SPRING`, `LIQUIDITY_ABSORPTION`,
`SWING_LONG`, `SWING_SHORT`, `SCALP_LONG`, `SCALP_SHORT`, `NO_SIGNAL`. Sniper
still gets the loudest Telegram treatment (distinct header + "why this is
higher-conviction" callout) and its own dashboard filter tab.

### Risk controls

- **ATR-based structural stops** — `swept_level ± ATR × GOLD_ATR_STOP_BUFFER`,
  not a fixed pip count.
- **Fixed R:R targets** — TP1 at `GOLD_TP1_RR` (2.0), TP2 at `GOLD_TP2_RR`
  (3.0), TP3 at `GOLD_TP3_RR` (4.0, a runner target for trends that keep
  extending), all expressed as risk multiples.
- **Daily loss circuit breaker** — stops firing new signals for the rest of
  the day after losing `GOLD_DAILY_LOSS_LIMIT_PCT` (3%) of equity;
  `data/gold_risk_state.json` tracks this, updated by the performance layer
  as trades resolve.
- **Max trades/day cap** — `GOLD_MAX_TRADES_PER_DAY` (3), regardless of how
  many valid setups appear.
- **Cooldowns** — `GOLD_SCALP_COOLDOWN_MIN` (30min) / `GOLD_SWING_COOLDOWN_H`
  (6h) between re-fires, tracked in `data/gold_engine_state.json`.

All of these are tunable constants in `config.py`.

### Telegram format

Each fired signal sends two messages: a compact summary card first
(direction, entry, SL, TP1-3, R:R, entry timeframe — nothing else), then a
detailed follow-up with the signal taxonomy label, confidence, the factor
list behind the call, and a dashboard link. `telegram.format_gold_signal_short()`
/ `format_gold_signal()` respectively.

### COT sourcing

Official CFTC Socrata API is primary (`publicreporting.cftc.gov`).
insider-week.com is kept as an explicit fallback, using the corrected URL
pattern (`/en/cot/{path}/?all_data=ok`).

## Standalone agents (outside the chain, own schedules)

- **`news_agent.py`** — watches the ForexFactory high-impact ("red folder")
  calendar for USD events (gold is heavily USD-correlated). ~15 minutes
  before a watched release it sends the previous reading + forecast; once
  the actual posts, a second message gives a beat/miss read on typical
  USD/gold bias. Every 5 min, 06-22 UTC weekdays.
- **`tracer_agent.py`** — for every open position, checks live progress
  toward TP1 vs SL and sends a nudge the first time it crosses 50%/75%/100%.
  Every 15 min, 07-20 UTC weekdays.
- **`daily_brief.py`** — Arabic-language executive daily brief, computed
  from `gold_engine.structure_bias()` on H4+H1 plus COT and recent-signal
  direction, combined into a -4..+4 score. Daily 06:15 UTC weekdays.
- **`cot_weekly.py`** (via `--layer cot_weekly`) — standalone COT snapshot,
  once a week (Friday 19:45 UTC).
- **`backtest.py`** — walk-forward simulation. Manual dispatch only.

## Dashboard

`docs/index.html`: Arabic daily brief, Macro Context card, COT — Institutional
Positioning (snapshot + ~90-day weekly history), a **Gold Scenarios** section
(1H / 4H / Daily / Weekly cards — each with its own chart, bias, EMA20/50/200,
and nearest support/resistance, via `gold_engine.run_gold_scenarios()`), a
Gold Bias card (H4 structure), latest trade setups filterable by
Scalp/Swing/🎯 Sniper only (Sniper cards get a gold highlight, TP1-3 shown),
performance stats, and open positions.
Reads `docs/dashboard.json`, updated automatically by `dashboard_export.py`
whenever a step fires a signal, bias read, scenario snapshot, macro synthesis, COT snapshot, or
resolves a trade.

**Hosted on GitHub Pages.** Telegram messages link straight to it. One-time
setup: Settings → General → Danger Zone → Public; Settings → Pages → Deploy
from branch → `main` → `/docs`.

`config.py`'s `DASHBOARD_URL` defaults to
`https://ahmadman1991.github.io/trading-bot` — override via env var if
hosted elsewhere.

**To view locally instead**: `python3 serve_dashboard.py` from inside
`Trading_Bot_COT` — `http://127.0.0.1:8765`, auto-refreshes every 60s.

## GitHub Actions

One scheduler runs the chain — **`pipeline.yml`**, every 30min, 07-16 UTC
weekdays. `news_agent.yml`, `tracer_agent.yml`, `daily_brief.yml`,
`cot_weekly.yml`, `performance.yml` keep their own independent schedules (or
manual-only, for `performance.yml`).

`scalp.yml`, `swing.yml`, `council.yml`, `forecast.yml`, `btc_deep.yml` are
**deprecated no-ops** (manual-dispatch only, print an explanation and exit) —
kept only because files can't be deleted from this environment's project
folder. Delete them yourself whenever convenient; nothing depends on them.

## Setup

```bash
pip install -r requirements.txt
```

Set these as GitHub repo secrets (Settings → Secrets and variables →
Actions):

| Secret | Used for |
|---|---|
| `TELEGRAM_TOKEN` | Bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Channel/chat to post signals to |
| `TWELVEDATA_KEY` | TwelveData market data |
| `GEMINI_API_KEY` | Gemini — all LLM text: live macro gather + synthesis (step 2), signal reasoning, Arabic executive summary. Steps fall back to plain-text output if unset. |
| `GEMINI_MODEL` | Optional — overrides the default `gemini-3.7-flash`. |

For local runs, export the same variables in your shell (or use a local
`.env` file — loaded automatically via `python-dotenv`).

## Markets covered

**XAUUSD only.** See `config.py` → `MARKETS` and the `GOLD_*` constants for
all tuning knobs (sessions, ATR multiples, cooldowns, risk limits).

## Safety notes

- This is a **signal-only** system — it does not execute trades. You still
  place every order yourself.
- Do not run this GitHub Actions setup alongside any other local/cron copy
  of the same bot — two schedulers against the same Telegram channel
  produces duplicate signals.
- Backtest results are informative, not a guarantee — sanity check any
  strategy change against the score-bucket report before trusting it live.
