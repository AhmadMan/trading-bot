"""
Macro Agent — pipeline step 2.

Gathers real, current macro context that price data + model training
knowledge alone can't provide: central bank stances, analyst views on DXY,
risk sentiment (VIX), and the upcoming high-impact economic calendar.

Two-pass Gemini pattern:
  1. Gemini, with Google Search grounding, gathers a live factual data brief
     (numbers + dates only, no analysis).
  2. Gemini again turns that brief into a short professional synthesis, so
     downstream steps (Gold Bias, Daily Brief) get real current context
     instead of stale training-data assumptions.

COT is deliberately NOT requested here — cot_agent.py already covers that
from the official CFTC API (with insider-week as fallback), so asking Gemini
to search for it too would be redundant and less reliable.
"""

import json
from pathlib import Path

import pandas as pd

from config import GEMINI_API_KEY, gemini_text

DATA_ROOT   = Path(__file__).parent / "data"
LATEST_FILE = DATA_ROOT / "macro_latest.json"

GEMINI_DATA_PROMPT = """Use your web search tool to gather the latest market data (last 7 days) \
and return a structured, factual research brief in English covering exactly these items. \
Be factual, cite dates, use real numbers. Do NOT analyze — only collect and organize data.

## A. Central Banks (Fed, ECB, BOE, BOJ, RBA)
For each: current rate, last meeting date & decision, next meeting date, latest key quote with \
date, hawkish/dovish stance, market-implied probability of next change.

## B. DXY & US Yields
Current DXY level and 1-week trend. US 10Y yield. US 10Y TIPS yield (real rate). Latest views \
from JPMorgan, Goldman Sachs, Citi, Deutsche Bank, BofA on USD direction with price targets and dates.

## C. Asset Prices & Trends (last 7 days)
XAU/USD, EUR/USD, GBP/USD, USD/JPY, S&P 500, Nasdaq, BTC/USD — price and trend for each. \
Gold ETF flows (GLD/IAU). Bitcoin ETF flows.

## D. Risk Sentiment
Current VIX level. Risk-on or risk-off environment? Any notable hedge fund positioning news.

## E. US Economic Calendar — next 14 days (high-impact / red-folder only)
For each event: Date, Time ET, Event name, Forecast, Previous.

Return a clean structured brief with clear section headers and exact dates for every data point."""

MACRO_SYNTHESIS_SYSTEM = """You are a macro strategist at a hedge fund. Given a factual data brief, \
write a concise professional synthesis (150-200 words, plain text, no markdown) covering: overall \
USD bias and why, the single biggest near-term risk/catalyst, and a one-line read on risk sentiment \
(risk-on/risk-off). Base this ONLY on the data provided — do not invent facts."""


def fetch_live_macro_data() -> str:
    # Pass 1 — Google-Search-grounded factual gather (numbers + dates, no analysis).
    return gemini_text("", GEMINI_DATA_PROMPT, search=True)


def synthesize_macro_view(live_data: str) -> str:
    # Pass 2 — turn the factual brief into a short professional synthesis.
    if not live_data:
        return ""
    return gemini_text(MACRO_SYNTHESIS_SYSTEM, live_data[:6000])


def run_macro_agent() -> dict:
    if not GEMINI_API_KEY:
        print("  GEMINI_API_KEY not set — skipping macro agent (optional step)")
        return {"live_data": "", "synthesis": "", "available": False}

    live_data = fetch_live_macro_data()
    synthesis = synthesize_macro_view(live_data) if live_data else ""

    result = {
        "updated_at": str(pd.Timestamp.now(tz="UTC")),
        "live_data": live_data, "synthesis": synthesis,
        "available": bool(live_data),
    }
    DATA_ROOT.mkdir(exist_ok=True)
    LATEST_FILE.write_text(json.dumps(result, indent=2, default=str))

    if synthesis:
        try:
            import dashboard_export as dash
            dash.record_macro(synthesis)
        except Exception as e:
            print(f"  ⚠ dashboard export failed: {e}")

    print(f"  macro agent: {'OK' if live_data else 'no data (Gemini unavailable or empty)'}")
    return result
