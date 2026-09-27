#!/usr/bin/env python3
"""Monte Carlo and stress tests for the risk-ladder position sizer.

The ladder is the sizing rule used by XAU_MomentumClose.mq5 when
InpLadderEnable is on: base risk is a fixed share of equity struck once a
day, a loss multiplies the next trade's risk, any win resets it, and three
hard stops bound the progression.

The point of this file is to answer one question the ladder cannot answer
about itself: given a win rate and a reward-to-risk ratio, what does the
distribution of outcomes actually look like - not the average, the tails.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field, replace

import numpy as np


@dataclass(frozen=True)
class Ladder:
    """Sizing rules. Percentages are of equity, matching the EA inputs."""

    base_pct: float = 0.005      # InpLadderBasePct
    mult: float = 1.5            # InpLadderMult
    max_pct: float = 0.05        # InpLadderMaxPct
    max_losses: int = 5          # InpLadderMaxLosses (consecutive, per day)
    day_loss_pct: float = 0.02   # InpLadderDayLossPct
    max_dd_pct: float = 0.25     # InpLadderMaxDDPct
    rr: float = 2.0              # reward-to-risk on a win
    auto_base: bool = True       # InpLadderAutoBase

    def effective_base(self) -> float:
        """Base risk actually used, mirroring LadderBasePct() in the EA.

        With auto_base on, the base is solved so that a full run of
        max_losses spends exactly the daily loss budget:
            b(1 + m + ... + m^(n-1)) = L
        Without it, the two stops fight and the tighter one silences the
        other.
        """
        if not (self.auto_base and self.max_losses and self.day_loss_pct):
            return self.base_pct
        denom = sum(self.mult ** i for i in range(self.max_losses))
        return self.day_loss_pct / denom if denom else self.base_pct


@dataclass
class RunResult:
    equity: float
    peak: float
    max_dd: float
    trades: int
    days: int
    ruined: bool
    dd_halts: int
    day_stops: int = 0
    equity_curve: list[float] = field(default_factory=list)


def simulate(
    win_rate: float,
    lad: Ladder,
    days: int = 250,
    trades_per_day: int = 6,
    start: float = 3000.0,
    ruin_at: float = 0.5,
    rng: np.random.Generator | None = None,
    keep_curve: bool = False,
) -> RunResult:
    """One path. Trade outcomes are i.i.d. Bernoulli - deliberately so.

    Real trades are not independent, but assuming independence is the
    *charitable* case for a loss-progression: any positive autocorrelation in
    losses (which is what a losing streak in a trending market is) makes the
    ladder strictly worse than what this reports.
    """
    rng = rng or np.random.default_rng()
    eq = peak = start
    max_dd = 0.0
    dd_freeze = False
    dd_halts = 0
    day_stops = 0
    n_trades = 0
    curve = [eq] if keep_curve else []

    for _ in range(days):
        if eq <= start * ruin_at:
            break

        base = eq * lad.effective_base()
        risk = base
        losses = 0
        day_pnl = 0.0
        day_start_eq = eq

        for _ in range(trades_per_day):
            # Per-trade cap, struck against live equity as the EA does.
            sized = min(base if dd_freeze else risk, eq * lad.max_pct)
            if sized <= 0 or eq <= 0:
                break

            won = rng.random() < win_rate
            pnl = sized * lad.rr if won else -sized
            eq += pnl
            day_pnl += pnl
            n_trades += 1
            if keep_curve:
                curve.append(eq)

            if won:
                risk, losses = base, 0
            else:
                losses += 1
                if not dd_freeze:
                    risk *= lad.mult

            # Drawdown rule, checked continuously.
            peak = max(peak, eq)
            dd = (peak - eq) / peak if peak > 0 else 0.0
            max_dd = max(max_dd, dd)
            if not dd_freeze and lad.max_dd_pct > 0 and dd >= lad.max_dd_pct:
                dd_freeze, dd_halts = True, dd_halts + 1
                risk, losses = base, 0
            elif dd_freeze and eq >= peak:
                dd_freeze = False

            # Daily stops.
            if lad.max_losses and losses >= lad.max_losses:
                day_stops += 1
                break
            if lad.day_loss_pct and day_pnl <= -day_start_eq * lad.day_loss_pct:
                day_stops += 1
                break

    return RunResult(eq, peak, max_dd, n_trades, days, eq <= start * ruin_at,
                     dd_halts, day_stops, curve)


def monte_carlo(win_rate: float, lad: Ladder, paths: int = 20_000,
                seed: int = 7, **kw) -> dict:
    rng = np.random.default_rng(seed)
    runs = [simulate(win_rate, lad, rng=rng, **kw) for _ in range(paths)]
    finals = np.array([r.equity for r in runs])
    dds = np.array([r.max_dd for r in runs])
    start = kw.get("start", 3000.0)
    return {
        "win_rate": win_rate,
        "median": float(np.median(finals)),
        "mean": float(finals.mean()),
        "p05": float(np.percentile(finals, 5)),
        "p95": float(np.percentile(finals, 95)),
        "ruin_pct": 100.0 * sum(r.ruined for r in runs) / paths,
        "loss_pct": 100.0 * float((finals < start).mean()),
        "med_dd": 100.0 * float(np.median(dds)),
        "p95_dd": 100.0 * float(np.percentile(dds, 95)),
        "worst_dd": 100.0 * float(dds.max()),
        "avg_trades": float(np.mean([r.trades for r in runs])),
    }


def streak(n: int, lad: Ladder, start: float = 3000.0) -> dict:
    """Cost of n consecutive losses, respecting the daily stops.

    A streak longer than max_losses cannot happen inside one day, so it
    spills across days and each new day re-strikes the base off the reduced
    equity. That is the single biggest reason this ladder is survivable.
    """
    eq = start
    left = n
    days = 0
    while left > 0:
        base = eq * lad.effective_base()
        risk = base
        day_pnl = 0.0
        day_start = eq
        days += 1
        losses = 0
        while left > 0:
            sized = min(risk, eq * lad.max_pct)
            eq -= sized
            day_pnl -= sized
            left -= 1
            losses += 1
            risk *= lad.mult
            if lad.max_losses and losses >= lad.max_losses:
                break
            if lad.day_loss_pct and day_pnl <= -day_start * lad.day_loss_pct:
                break
    return {"losses": n, "days": days, "equity": eq,
            "dd_pct": 100.0 * (start - eq) / start}


def losses_to_dd(lad: Ladder, target_dd: float = 0.25,
                 start: float = 3000.0) -> int:
    n = 0
    while True:
        n += 1
        if streak(n, lad, start)["dd_pct"] >= target_dd * 100:
            return n
        if n > 2000:
            return -1


def expectancy(win_rate: float, rr: float) -> float:
    """Per-trade expectancy in R. Sizing cannot change this number's sign."""
    return win_rate * rr - (1 - win_rate)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--paths", type=int, default=20_000)
    ap.add_argument("--days", type=int, default=250)
    ap.add_argument("--tpd", type=int, default=6, help="trades per day")
    ap.add_argument("--start", type=float, default=3000.0)
    ap.add_argument("--rr", type=float, default=2.0)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    lad = Ladder(rr=a.rr)
    flat = replace(lad, mult=1.0, auto_base=False,
                   base_pct=lad.effective_base())  # same risk, no progression

    print(f"\nLADDER: base {lad.base_pct:.2%} x{lad.mult} cap {lad.max_pct:.0%} | "
          f"stops {lad.max_losses} losses / {lad.day_loss_pct:.0%} day / "
          f"{lad.max_dd_pct:.0%} DD | RR 1:{lad.rr:g}")
    print(f"START EUR {a.start:,.0f} | {a.days} days x {a.tpd} trades\n")

    print("=" * 74)
    print("A. REACHABLE RISK  (what the ladder can actually size to)")
    print("=" * 74)
    b = lad.effective_base()
    print(f"  base risk: {b:.4%}"
          f"{'  (auto-derived from the daily loss limit)' if lad.auto_base else ''}")
    r, cum, binds = b, 0.0, 0
    for step in range(1, lad.max_losses + 1):
        sized = min(r, lad.max_pct)
        cum += sized
        tag = "  <- capped" if sized < r else ""
        if not binds and lad.day_loss_pct and cum >= lad.day_loss_pct:
            binds = step
            tag += "  <- daily loss limit reached here"
        print(f"  loss {step}: risk {sized:>8.4%}   cumulative {cum:>8.4%}{tag}")
        r *= lad.mult
    print(f"\n  Worst constructible day: {lad.max_losses} losses = {cum:.4%} of equity.")
    if binds and binds < lad.max_losses:
        print(f"  WARNING: the {lad.day_loss_pct:.2%} daily stop ends the day on loss "
              f"{binds} - the {lad.max_losses}-loss setting is unreachable.")
    need = int(np.ceil(np.log(lad.max_pct / b) / np.log(lad.mult)))
    print(f"  The {lad.max_pct:.0%} per-trade cap needs {need} consecutive losses "
          f"to engage: still never reached.")

    print("\n" + "=" * 74)
    print("B. LOSING-STREAK STRESS TEST")
    print("=" * 74)
    print(f"  {'losses':>7} {'days':>6} {'equity':>12} {'drawdown':>10}")
    for n in (3, 5, 7, 10, 15, 20, 30):
        s = streak(n, lad, a.start)
        print(f"  {s['losses']:>7} {s['days']:>6} {s['equity']:>12,.2f} "
              f"{s['dd_pct']:>9.2f}%")
    n25 = losses_to_dd(lad, 0.25, a.start)
    print(f"\n  Consecutive losses to breach the 25% DD limit: {n25}")
    for p in (0.45, 0.50, 0.55, 0.60):
        prob = (1 - p) ** n25
        print(f"    P(that streak) at {p:.0%} win rate: {prob:.3e}")

    print("\n" + "=" * 74)
    print("C. EXPECTANCY  (sizing cannot change this)")
    print("=" * 74)
    be = 1 / (1 + lad.rr)
    print(f"  Break-even win rate at RR 1:{lad.rr:g} = {be:.2%}")
    for p in (0.35, 0.40, 0.45, 0.50, 0.55, 0.60):
        e = expectancy(p, lad.rr)
        print(f"    {p:.0%} win rate -> {e:+.3f} R/trade  "
              f"{'POSITIVE' if e > 0 else 'NEGATIVE'}")

    print("\n" + "=" * 74)
    print("D. MONTE CARLO: LADDER vs FLAT BASE RISK")
    print("=" * 74)
    kw = dict(paths=a.paths, days=a.days, trades_per_day=a.tpd,
              start=a.start, seed=a.seed)
    hdr = (f"  {'wr':>4} {'sizing':>7} {'median':>10} {'p05':>10} {'p95':>10} "
           f"{'ruin':>6} {'losing':>7} {'medDD':>7} {'p95DD':>7}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for p in (0.40, 0.45, 0.50, 0.55, 0.60):
        for name, cfg in (("ladder", lad), ("flat", flat)):
            m = monte_carlo(p, cfg, **kw)
            print(f"  {p:>4.0%} {name:>7} {m['median']:>10,.0f} {m['p05']:>10,.0f} "
                  f"{m['p95']:>10,.0f} {m['ruin_pct']:>5.2f}% {m['loss_pct']:>6.1f}% "
                  f"{m['med_dd']:>6.1f}% {m['p95_dd']:>6.1f}%")
        print()

    print("=" * 74)
    print("E. SENSITIVITY: what if RR is not really 1:2?")
    print("=" * 74)
    print("  The backtest this sizer is bolted onto ran RR 1:1.15 at a 50% win")
    print("  rate. Setting a 1:2 target does not create a 1:2 outcome - it")
    print("  lowers the win rate. This is that trade-off:\n")
    print(f"  {'RR':>6} {'break-even wr':>14} {'median @ its BE+5pts':>22} {'ruin':>7}")
    for rr in (1.0, 1.15, 1.5, 2.0, 3.0):
        cfg = replace(lad, rr=rr)
        be_rr = 1 / (1 + rr)
        wr = min(be_rr + 0.05, 0.95)
        m = monte_carlo(wr, cfg, paths=max(2000, a.paths // 5),
                        days=a.days, trades_per_day=a.tpd,
                        start=a.start, seed=a.seed)
        print(f"  1:{rr:<4g} {be_rr:>13.1%} {m['median']:>22,.0f} {m['ruin_pct']:>6.2f}%")

    print("\n" + "=" * 74)
    print("F. THE HONEST CASE: this EA's measured edge, and no edge at all")
    print("=" * 74)
    print("  Section D assumes RR 1:2 at a 50% win rate = +0.50 R/trade. No")
    print("  intraday gold strategy has that. Those curves measure the")
    print("  assumption, not the sizer. These two cases are the useful ones.\n")

    cases = [
        ("measured (50.08% @ RR 1.145)", 0.5008, 1.145),
        ("zero edge  (50.00% @ RR 1.00)", 0.5000, 1.000),
        ("half a spread worse (48% @ 1.00)", 0.4800, 1.000),
    ]
    hdr2 = (f"  {'case':>32} {'sizing':>7} {'median':>10} {'p05':>10} "
            f"{'losing':>7} {'medDD':>7} {'p95DD':>7} {'ruin':>7}")
    print(hdr2)
    print("  " + "-" * (len(hdr2) - 2))
    for label, p_win, rr in cases:
        for name, cfgbase in (("ladder", lad), ("flat", flat)):
            cfg = replace(cfgbase, rr=rr)
            m = monte_carlo(p_win, cfg, paths=max(4000, a.paths // 2),
                            days=a.days, trades_per_day=a.tpd,
                            start=a.start, seed=a.seed)
            print(f"  {label if name == 'ladder' else '':>32} {name:>7} "
                  f"{m['median']:>10,.0f} {m['p05']:>10,.0f} "
                  f"{m['loss_pct']:>6.1f}% {m['med_dd']:>6.1f}% "
                  f"{m['p95_dd']:>6.1f}% {m['ruin_pct']:>6.2f}%")
        print()

    print("  Read the zero-edge rows: the ladder does not turn a coin flip")
    print("  into a profit. It widens the distribution around it. That is the")
    print("  whole of what a loss progression does.")
    print()


if __name__ == "__main__":
    main()
