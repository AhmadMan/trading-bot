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

- **Threshold ≈ $2.50 / 0.8 ATR.** The source used a $70–100 move on BTC around
  $100k — roughly 0.07–0.10%. On gold near $3,500 that is $2.50–3.50.
- **Risk 0.5% per trade, 3% daily stop.** The source suggested up to 15% per
  trade with 50%-of-capital sizing. On 5-minute momentum that is a blow-up
  schedule, not a risk control. These defaults are what the same idea looks like
  when it is allowed to be wrong twenty times in a row.
- **ATR floor and ceiling.** Skips dead tape and skips news spikes, where the
  spread eats the entire edge.

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

## EA notes

- Attach to an **M1** chart; the window clock counts whole minutes.
- Sizing is derived from `SYMBOL_TRADE_TICK_VALUE`, so it adapts to whatever
  contract size the broker uses for XAU. If the risk budget cannot buy the
  minimum lot, the EA stands down instead of oversizing.
- `InpMaxSpreadPts` blocks entries when the spread is wide. Set it from your
  broker's typical XAU spread, not from the default.
