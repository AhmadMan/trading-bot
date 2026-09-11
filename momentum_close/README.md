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

## Prop-firm (FTMO) guards and fixed sizing — v1.20

### Sizing

| Input | Default | What it does |
|---|---|---|
| `InpUseFixedLot` | `false` | Trade `InpFixedLots` on every entry instead of risk-% sizing. |
| `InpFixedLots` | `0.10` | The fixed size. |
| `InpMaxLots` | `0.0` | Hard ceiling on any lot, 0 = broker maximum. |

Risk-% sizing compounds: in the 60-minute run it grew positions from 0.5 lots in
June to 5.36 lots in September, which flatters the curve on the way up and hurts
disproportionately in a losing streak. Fixed lots make every trade the same size,
so the equity curve measures the edge rather than the compounding. **Test with
fixed lots; trade with whichever you have decided you want.**

### FTMO guards

All limits are measured on **equity** (floating P/L included) against the
**balance at the start of the prop day** — that is how the firm measures them —
and they are checked on **every tick**, not on bar close. The daily governor
already in the EA (`InpDailyLossPct`) checks only on new bars and measures from
day-start equity; it stays as a strategy-level brake, but it is not a prop-rule
guard and must not be relied on as one.

| Input | Default | What it does |
|---|---|---|
| `InpFtmoEnable` | `false` | Turn the guards on. |
| `InpFtmoDailyPct` | `4.0` | Close everything and stop for the day at this loss. |
| `InpFtmoMaxPct` | `8.0` | Overall loss from the starting balance. **Terminal** — the EA never trades again this run. |
| `InpFtmoStartBal` | `0.0` | Account starting balance; 0 captures the balance when the EA attaches. |
| `InpFtmoResetHr` | `0` | Server hour the prop day rolls, when the broker clock differs from the firm's. |
| `InpFtmoTargetPct` | `0.0` | Optionally stop for the day at +N%, so a good day is not given back. |

The defaults sit **inside** FTMO's 5% / 10% limits on purpose. A guard set at
exactly 5% closes the position *at* the limit, and the slippage on that close is
enough to breach it. The 1–2% buffer is what makes the guard a guard.

Two things it cannot do: a limit breached by a weekend gap happens with no ticks
to act on (which is what `InpNoEntryFriHr`, now `19`, is for), and it governs
only positions carrying `InpMagic` on this symbol — anything you trade manually
in the same account is invisible to it and still counts against your limits.

## Signal-candle stop with 1:1 target

`stopMode = 'SIGNAL'` places the stop just beyond a candle instead of a fixed or
ATR distance: under its low for a long, over its high for a short, plus `bufUsd`
(default $0.30) or `bufAtrMult`. `stopAnchor` chooses which candle:

- **Signal** (default) — the bar that fired the entry.
- **Previous** — the bar before it. On a strong signal bar this usually sits
  further away, and it is not itself part of the move being traded.
- **Both** — whichever extreme is wider, so the stop clears either candle.

`Previous` can put the stop on the *wrong side* of the entry: in a fast move the
prior candle's low can sit above the signal close, which would mean a long with
its stop above its entry. Those signals are rejected, not traded, and land in the
funnel's "stop too tight" row — so expect that count to rise when you switch
anchors, and read it rather than assuming signals went missing. `useTarget` defaults on
with `targetR = 1.0`, so the target sits the same distance the other side of the
fill. `strategy.exit` fills the instant either level trades, which is the
close-on-touch behaviour.

Three things this changes that are easy to miss:

**Risk is measured from the fill, not the signal close.** The stop is a *price*
fixed by the candle; the entry fills at the next bar's open. So the target is
computed from `position_avg_price` against that fixed stop — `targetR = 1` is a
true 1:1 on realised risk, not on the distance estimated at signal time. The two
differ by whatever the market did between the signal close and the fill.

**A tight signal candle means a huge position.** Position size is
`risk / stop distance`, so a doji signal candle implies a near-zero stop and a
size limited only by the broker. `minStopUsd` (default $0.80) rejects those
signals outright; the count appears in the funnel table as "stop too tight". Do
not set it to zero.

**`flatAtWinClose` defaults OFF, and that is deliberate.** The window close was the
original premise — the edge lives in the final minutes and does not survive
being held. A 1:1 target needs room to be reached. Leave the flatten on and most
trades exit at the boundary with the target rarely firing; turn it off and the
trade is decided by stop and target alone, which is what a 1:1 RR strategy
normally means. It now defaults off, because with it on
every `targetR` above roughly 1 gave the same result — the boundary arrived
within a few bars and cut the trade before a 2R or 3R target could be touched,
which looks exactly like "the strategy is ignoring my RR setting". Turn it back
on only to test the original momentum-into-close idea, not an RR strategy.
**Decide which of the two you are testing before reading the result**, because
they produce completely different trade populations from the same signals.

The live stop and target are plotted while a position is open, so the levels the
strategy is actually working can be read off the chart rather than inferred from
the trade list.
