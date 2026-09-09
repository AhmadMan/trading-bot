# Momentum-Into-Close — gold

Port of the "5-minute BTC Up/Down momentum" idea (Polymarket binaries) to spot
gold, written to be **falsified before it is deployed**.

| File | What it is |
|---|---|
| `XAU_MomentumClose.pine` | Pine v6 **strategy** — the backtest. Run this first. |
| `XAU_MomentumClose.mq5`  | MT5 EA — same logic, same defaults, for forward testing. |

## The translation

Polymarket resolves a binary at a fixed clock boundary. Spot gold has no expiry,
so the boundary is synthesised: the clock is cut into fixed windows (default 5
minutes, anchored to the epoch so they land on :00/:05/:10…), and each window is
treated as its own market.

Inside a window:

1. Record the price at the window open.
2. With `entryLeadMin` minutes left (default 2), measure the move from that open.
3. If `|move| >= threshold` **and** the signal bar closes in the same direction
   with a body of at least `minBodyPct` of its range → enter with the move.
4. Flatten on the window's last bar. The stop is protective only.

The original's "order-book skew confirmation" has no spot equivalent, so the
signal-bar alignment + body filter stands in for it: both are asking whether the
move is real flow or a wick.

## Defaults, and why

- **Threshold 1.5 × ATR(M1), not a fixed dollar amount.** The first cut used
  $2.50, reasoning from the source's $70–100 move on $100k BTC (≈0.08%) applied
  to gold near $3,500. That reasoning was wrong: BTC's 5-minute realised
  volatility is several times gold's, so $2.50 in three minutes is a multi-sigma
  move on gold M1 and the EA took **zero trades**. Scaling off ATR fixes it and
  keeps the threshold honest across sessions and across years of backtest.
- **Risk 0.5% per trade, 3% daily stop.** The source suggested up to 15% per
  trade with 50%-of-capital sizing. On 5-minute momentum that is a blow-up
  schedule, not a risk control. These defaults are what the same idea looks like
  when it is allowed to be wrong twenty times in a row.
- **ATR floor and ceiling are off by default (0 = disabled).** The original
  $0.50 floor was above gold's typical M1 ATR, so it blocked every entry on its
  own. Set them from what the funnel log below actually shows.

## When it takes no trades

The EA prints a funnel at the end of every tester run:

```
=== MIC funnel === entry slots:4180  sent:126
    rejected — move:3702 body:340 governor:12 atr_band:0 atr_na:0 spread:0 win_open:0 lots:0
```

Read it top-down. `entry slots: 0` means no bar ever reached the entry minute —
wrong chart timeframe or missing M1 history, not a signal problem. Otherwise the
largest rejection counter is the cause, and `InpVerbose` logs near-misses with
the actual move, threshold and ATR so the threshold can be set from data rather
than from a guess.

## How to test it — in this order

1. Load the Pine strategy on **XAUUSD, 1-minute**, set commission and slippage
   to your broker's real numbers (the defaults are 0 and that is a lie).
2. Look at **trade count first**. Fewer than ~300 trades means the result is
   noise regardless of how good it looks.
3. Then profit factor and max drawdown. A momentum edge that survives costs
   should show PF > 1.15 with a trade count in the thousands.
4. **Walk the parameters.** Vary threshold, lead time and window length. If the
   result is only good at one setting, there is no edge — there is a fit.
5. Only if steps 2–4 pass: run the EA on a demo account for a month and compare
   its fill quality to the backtest.

The honest prior is that this fails. Late-window continuation in a liquid
24-hour market is the most-arbitraged pattern there is, and the spread on gold
is wide relative to a $2.50 move. The value of these two files is that they
settle the question cheaply.

## Stacking signals (allowAdds / InpAllowAdds)

Off by default: one trade at a time, so a signal firing before the window
closes is skipped. Turning it on takes every signal and stacks the position.

Two things behave differently in MT5 than in Pine, because MT5 nets:

- An opposite signal while a position is open would *reduce* the netted
  position rather than open a new trade, so the EA skips it and lets the
  window boundary flatten instead. Pine would reverse. The funnel counts these
  under `opposite_signal`.
- A netted position has one average price and one stop, so every add
  re-anchors the stop to the new average. Pine keeps a stop per entry.

Read the results knowing that stacked entries are not independent trades —
they are one directional bet counted several times, so profit factor
flatters and drawdown understates. For deciding whether the edge is real,
leave adds off.

## Reading a backtest of this strategy

The first real result (XAUUSD+, M1, Jun-Sep 2026, 1241 trades, 100% real ticks)
returned profit factor 1.09 on a 60-minute window with a 5-minute lead. It does
not survive inspection, and the same checks apply to any later run:

- **Check what the top trade contributed.** In that run the single largest win
  was 59% of net profit, and it was a weekend gap: the take-profit sat at
  4224.87 and filled at 4269.54. Removing it drops profit factor to 1.04;
  removing the top three drops it to 1.01.
- **Check LR Correlation.** 0.47 there. A tradeable equity curve runs above
  0.85; below that the curve is noise with a few jumps in it.
- **Check that commission is not zero.** Spread is in the tick data but broker
  commission is not modelled by default. At ~$6 per lot round turn it consumed
  about 62% of that run's net profit.
- **Check the rollover hour.** Entries in the 23:00 hour hold through the daily
  break and over weekends. They netted close to zero while producing both the
  largest win and the largest loss. `InpBlockHours = "23"` removes them; if net
  profit collapses when they are gone, the gaps were the edge.

## EA notes

- Attach to an **M1** chart; the window clock counts whole minutes.
- Sizing is derived from `SYMBOL_TRADE_TICK_VALUE`, so it adapts to whatever
  contract size the broker uses for XAU. If the risk budget cannot buy the
  minimum lot, the EA stands down instead of oversizing.
- `InpMaxSpreadPts` blocks entries when the spread is wide. Set it from your
  broker's typical XAU spread, not from the default.

## Final build (v1.10) — recommended defaults

Shipped defaults now match every recommendation from the two Strategy Tester
runs analysed so far:

| Input | Default | Why |
|---|---|---|
| `InpBlockHours` | `"23"` | The 23:00 hour is where entries hold through the daily rollover. |
| `InpNoEntryFriHr` | `21` | No new entries late Friday. The window clock cannot flatten a position once the market stops printing bars, so the only reliable guard is not to open it. |
| `InpMaxHoldMin` | `15` | Backstop, wall-clock not bar-counted: any position outliving three windows is closed on the first tick after the limit, whatever the bar stream did. |
| `InpRiskPct` | `0.3` | Run 2 raised net profit over run 1 purely by raising risk; every quality metric fell. Keep risk fixed while the edge is unproven. |
| `InpUseTarget` | `false` | Unchanged, but note it is what let the weekend gap run in run 2. |
| `InpMaxTradesDay` | `100`, `InpDailyLossPct` `2.5` | Match the last tested configuration. |
| `InpAllowAdds` | `false` | Adds correlate trades. Keep them independent observations until the edge question is settled. |

### Set commission before reading any result

Both runs so far reported `$0.00` commission on every deal. At a typical
$6/lot round turn that is roughly 62% of run 1's net profit. A backtest with
zero commission is not a backtest of this strategy. Set the tester's
commission to your broker's real figure first.

### What these defaults are for

They are not a claim that the strategy works. Two runs, 2,450 trades:
profit factor 1.09 and 1.07, LR correlation 0.47 and 0.44, and in run 2 a
single Friday-night gap fill accounted for 93% of the $12,844.92 net — the
other 1,208 trades made $943.32 against a 13.47% drawdown. The gap trades
that produced the profit are the same mechanism that produced all five
largest losses.

This build removes that trade. Re-run it, with real commission, and read the
result as the first honest measurement of the underlying idea:

1. Same period (Jun 1 – Sep 8 2026) with commission on, as the baseline.
2. An out-of-sample period (e.g. Jan – May 2026), settings untouched.
3. Only if both clear a profit factor near 1.2 with LR correlation above
   0.85, walk the move threshold and entry lead.

If step 1 lands near breakeven, that is the answer, and it is a useful one.
