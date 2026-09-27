# EMA20 Close Fade — analysis and changes

## What the signal actually is

```pine
rawSell = close > emaS and emaF < emaS
```

Two statements, and they should be read separately:

- `emaF < emaS` — the trend is down.
- `close > emaS` — price has poked back up through the mean.

So the trade is **fade a pullback into the mean, in the direction of the trend**.
That is a sound, well-worn idea. The edge, if there is one, comes from the
pullback failing and the trend resuming.

## Where it loses

The signal cannot distinguish two situations that produce an identical candle:

1. A pullback into resistance inside a live downtrend → the trade works.
2. The **first candle of a genuine reversal** → the trade loses, and loses
   badly, because the stop sits just above that candle and price keeps going.

Every filter added here exists to separate (1) from (2). None of them invent a
new signal; they ask whether the context that makes the fade sensible is
actually present.

## The sizing change matters more than the filters

The original sized every trade at 100% of equity. The stop is placed beyond the
signal candle, so the distance to it varies with candle size — meaning a
wide-candle signal and a narrow-candle signal took the **same position** and
risked **wildly different amounts**.

Gross loss was therefore dominated by whichever losers happened to have big
candles. That is noise, not edge. `useRiskSizing` makes every trade risk
`riskPct` of equity regardless of stop distance.

This does not improve the signal at all. It makes the loss distribution flat
instead of fat-tailed, which is most of what "reduce the gross loss" means in
practice. Set `useRiskSizing = false` to get the original behaviour back and
compare.

## Two bugs in the original

**Scale-out percentages compounded.** `qty_percent` in `strategy.exit` is a
percent of the position *at that moment*, not of the original. Chaining 34 / 33
meant TP1 took 34%, then TP2 took 33% of the remaining 66% — about 22% of the
original, leaving 44% for TP3 instead of 33%. The split was skewed towards the
furthest, least-likely target. Absolute quantities are now taken from the
position size captured at the fill, so 34/33/33 means 34/33/33.

**Filled exits were re-issued every bar.** `strategy.exit` called again with an
ID that has already filled places a *new* order. Re-issuing `"TP1"` after TP1
filled put another take-profit at a level price had already passed, so it filled
immediately — collapsing the scale-out into "exit everything at TP1" and
throwing away the TP2 and TP3 runners the strategy exists to capture. `tp1Done`
and `tp2Done` now gate those calls. `TP3` carries no `qty` and is always
re-issued, so the stop still covers the whole remaining position.

## The filters, all in ATR units

ATR normalisation means one number means the same thing on any symbol and any
timeframe. Set any of them to `0` to disable.

| Input | Default | Rejects |
|---|---|---|
| `minSlopeAtr` | 0.10 | A flat slow EMA. A flat mean is chop, and in chop every poke through it looks like a signal while none of them are. |
| `minSepAtr` | 0.15 | Converging EMAs. Converging means the trend is ending, so the "pullback" may be the reversal. |
| `maxExtAtr` | 1.00 | A candle that closed far beyond the mean. That is a breakout, not a poke, and fading breakouts is how an account dies. |
| `minStopAtr` | 0.20 | A stop tighter than noise — which under risk sizing also implies a very large position. |
| `maxStopAtr` | 2.50 | A signal candle so large the trade needs an implausible move to reach TP3. |

Defaults are deliberately mild. They are meant to cut the worst cases, not to
curve-fit the sample.

## Read the funnel before believing anything

The table counts raw signals and what each filter rejected, and dropped signals
are drawn as faded arrows. Check it on the first run:

- A filter rejecting **almost everything** is too tight — you are fitting.
- A filter rejecting **almost nothing** is not earning its place — remove it.
- Compare net profit *per trade*, not total. Filters reduce trade count, so
  total profit can fall while the strategy gets better.

## How to evaluate this honestly

Change one thing at a time against your existing baseline:

1. Bugs only — filters off (all to 0), `useRiskSizing` off. This isolates what
   the two fixes did on their own.
2. Add risk sizing. Expect gross loss to drop and the largest loss to shrink
   sharply; net profit may also fall, because the old outsized winners were
   sized by the same accident.
3. Add filters one at a time, watching the funnel and profit-per-trade.

If step 1 alone changes the result materially, the original backtest was
measuring the bugs rather than the strategy.
