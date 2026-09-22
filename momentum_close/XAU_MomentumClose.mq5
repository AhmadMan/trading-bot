//+------------------------------------------------------------------+
//| XAU_MomentumClose.mq5                                            |
//|                                                                  |
//| MT5 port of momentum_close/XAU_MomentumClose.pine.               |
//|                                                                  |
//| The clock is cut into fixed windows (default 5 minutes, anchored |
//| to the epoch). With InpEntryLeadMin minutes left in a window, if  |
//| price has moved far enough from the window's open and the signal  |
//| bar agrees, enter with the move; flatten on the window boundary.  |
//|                                                                  |
//| Do not run this live until the Pine version has shown a positive  |
//| expectancy on the same symbol and the same parameters. The two    |
//| files are deliberately the same logic so the backtest means       |
//| something.                                                        |
//+------------------------------------------------------------------+
#property copyright "trading-bot"
#property version   "1.50"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//--- Window
input int    InpWindowMin      = 5;      // Window length (minutes)
input int    InpEntryLeadMin   = 2;      // Enter with N minutes left

//--- Entry
input bool   InpUseAtrThresh   = true;   // Threshold from ATR instead of $
input double InpMoveThreshUsd  = 2.5;    // Min move from window open ($)
input double InpMoveAtrMult    = 1.0;    // Min move (ATR multiples)
input int    InpAtrPeriod      = 14;     // ATR period
input bool   InpRequireAlign   = false;  // Signal bar must close with the move
input double InpMinBodyPct     = 0.0;    // Min signal-bar body (% of range)
input bool   InpAllowLong      = true;
input bool   InpAllowShort     = true;
input bool   InpAllowAdds      = false;  // Take signals while already in a trade
input int    InpMaxAdds        = 10;     // Max stacked entries per direction

//--- Exit
// SIGNAL puts the stop just beyond a candle instead of a fixed or ATR distance,
// so risk is defined by the structure that produced the entry rather than by a
// number chosen in advance.
enum EStopMode
{
   STOP_USD    = 0,  // Fixed $ distance
   STOP_ATR    = 1,  // ATR multiple
   STOP_SIGNAL = 2   // Beyond the signal candle
};

enum EStopAnchor
{
   ANCHOR_SIGNAL = 0,  // The candle that fired the entry
   ANCHOR_PREV   = 1,  // The candle before it
   ANCHOR_BOTH   = 2   // Whichever extreme is wider
};

input EStopMode   InpStopMode   = STOP_SIGNAL;   // Stop mode
input EStopAnchor InpStopAnchor = ANCHOR_SIGNAL; // SIGNAL stop anchored to
input double InpStopUsd        = 3.0;    // Stop distance ($) - USD mode
input double InpStopAtrMult    = 1.5;    // Stop distance (ATR mult) - ATR mode
input bool   InpBufUseAtr      = false;  // SIGNAL buffer from ATR instead of $
input double InpBufUsd         = 0.30;   // SIGNAL buffer ($)
input double InpBufAtrMult     = 0.10;   // SIGNAL buffer (ATR mult)
// Position size is risk / stop distance, so a doji signal candle implies a
// near-zero stop and a size limited only by the broker. Reject those.
input double InpMinStopUsd     = 0.80;   // Reject signal if stop is tighter than ($)
input bool   InpUseTarget      = true;   // Use profit target
// 2R is the ratio the risk ladder is built around: its progression only pays
// for itself if a win returns twice what a loss costs. Note that setting the
// ratio does not create it - a 2R target is reached less often than a 1R one,
// so the win rate falls and the two effects have to be measured against each
// other, not assumed. Break-even at 2R is a 33.3% win rate.
input double InpTargetR        = 2.0;    // Target (R multiples)
// The window close was the original premise, but it cuts the trade within a few
// bars - so any target above roughly 1R could never be reached with it on, and
// every InpTargetR produced the same result. Off means stop and target decide.
input bool   InpFlatAtWinClose = false;  // Flatten at the window boundary

//--- Sizing
// Fixed lots make every trade the same size, so the backtest is a clean sample
// of the edge rather than a compounding curve. Risk-% sizing grows positions as
// equity grows, which is what pushed run 3 from 0.5 to 5.36 lots.
input bool   InpUseFixedLot    = false;  // Trade a fixed lot instead of risk %
input double InpFixedLots      = 0.10;   // Lot size when fixed sizing is on
input double InpMaxLots        = 0.0;    // Hard lot cap, 0 = broker maximum

//--- Risk ladder (survival-first progression)
// Base risk is a fixed % of equity, recomputed once per trading day. A loss
// multiplies the NEXT trade's risk by InpLadderMult; any win resets it to base.
// Three hard stops bound the progression: a per-trade % cap, a consecutive-loss
// count, and a daily loss %. The consecutive-loss stop is the binding one -
// with the defaults below the ladder can only reach step 3 (0.5 -> 0.75 ->
// 1.125%) before the day ends, so the 5% per-trade cap never actually engages.
// That is deliberate: the cap is a backstop for looser settings, not the
// mechanism. Raise InpLadderMaxLosses if you want the cap to matter.
input bool   InpLadderEnable     = false; // Use the risk ladder instead of InpRiskPct
input double InpLadderBasePct    = 0.5;   // Base risk (% equity), recomputed daily
input double InpLadderMult       = 1.5;   // Risk multiplier after a loss
input double InpLadderMaxPct     = 5.0;   // Hard per-trade risk cap (% equity)
input int    InpLadderMaxLosses  = 5;     // Stop for the day after N consecutive losses, 0 = off
input double InpLadderDayLossPct = 2.0;   // Stop for the day at this daily loss (% equity), 0 = off
input double InpLadderMaxDDPct   = 25.0;  // Freeze progression above this peak-to-trough DD, 0 = off
// Time-based exits close trades between -1R and +1R, so most results are not
// clean wins or losses. A result inside +/- this many currency units is a
// scratch: it neither advances the ladder nor resets it.
input double InpLadderScratchCcy = 0.0;   // Dead band around zero (account currency)
// The consecutive-loss stop and the daily loss stop are two ways of saying the
// same thing, and whichever is tighter silences the other. A 0.5% base at 1.5x
// costs 6.59% of equity to run five losses, so a 2% daily limit ends the day on
// the third - and raising the loss count alone changes nothing. This solves the
// base instead: base = DayLossPct / (1 + m + m^2 + ... + m^(n-1)), so the full
// ladder depth spends exactly the daily budget and both stops bind together.
input bool   InpLadderAutoBase   = true;  // Derive base risk so N losses = the daily loss limit

//--- Risk
input double InpRiskPct        = 0.3;    // Risk per trade (% equity)
input int    InpMaxTradesDay   = 100;    // Max trades per day (adds count)
input double InpDailyLossPct   = 0.0;    // Daily loss stop (% equity), 0 = off
input double InpMinAtr         = 0.0;    // Min ATR to trade ($), 0 = off
input double InpMaxAtr         = 0.0;    // Max ATR to trade ($), 0 = off
input double InpMaxSpreadUsd   = 0.0;    // Max spread ($), 0 = off
input bool   InpVerbose        = true;   // Log why entries are skipped
input bool   InpCalibrate      = false;  // Measure moves, place no trades

//--- Session (server time). Set both to 0 to trade around the clock.
// A contiguous start/end window cannot express "every hour except 23", which
// is the hour whose trades hold through the daily rollover and weekend gaps.
// InpBlockHours removes individual hours regardless of the session window.
input string InpBlockHours     = "23";   // Hours to skip, e.g. "23" or "23,0,22"
input int    InpSessionStartHr = 0;
input int    InpSessionEndHr   = 0;

//--- FTMO / prop-firm guards
// Prop rules are measured on EQUITY, floating P/L included, against the
// balance at the start of the trading day - not against day-start equity and
// not on bar close. So these are checked on every tick and reference balance.
// Defaults sit inside FTMO's 5% / 10% limits so the buffer absorbs slippage on
// the closing trade; a breach that closes at the limit is still a breach.
input bool   InpFtmoEnable     = false;  // Enforce prop-firm loss limits
input double InpFtmoDailyPct   = 4.0;    // Daily loss limit (% of day-start balance)
input double InpFtmoMaxPct     = 8.0;    // Overall loss limit (% of start balance)
input double InpFtmoStartBal   = 0.0;    // Account start balance, 0 = balance at attach
input int    InpFtmoResetHr    = 0;      // Server hour the prop day resets
input double InpFtmoTargetPct  = 0.0;    // Stop for the day at +N% profit, 0 = off

//--- Gap protection
// Both backtests to date owed nearly all of their net profit to a handful of
// positions opened just before the Friday close and exited after the weekend
// gap. Those are not this strategy's edge, they are a lottery on the gap, and
// the same mechanism produced every one of the five largest losses. These two
// inputs remove that trade so the remaining sample answers the actual
// question: does late-window momentum in gold pay for its own spread?
input int    InpNoEntryFriHr   = 19;     // No new entries Friday from this hour, 0 = off
// The hold limit is a ceiling on how far a target can be reached. At 15 minutes
// a 2R target on an M1 signal-candle stop is mostly cut short by the clock, so
// the ratio would be nominal: losses run their full -1R while winners are
// truncated well before +2R, which is the arithmetic the ladder cannot survive.
// 45 minutes leaves the target room and still closes the position long before
// the weekend gap this input exists to avoid.
input int    InpMaxHoldMin     = 45;     // Force-flat a position older than N min, 0 = off

//--- Plumbing
input long   InpMagic          = 590105;
input int    InpSlippagePts    = 20;

CTrade         trade;
CPositionInfo  pos;

int      atrHandle   = INVALID_HANDLE;
int      barMin      = 1;   // chart timeframe in minutes
datetime lastBarTime = 0;

// Window state, tracked forward bar by bar. Deriving it with iBarShift() was
// wrong: gold M1 has minutes with no ticks, so the bar that opens a window is
// often absent and an exact lookup returned -1, silently voiding the window.
long   curWinId   = -1;
double curWinOpen = 0.0;

// Diagnostics — a strategy that takes no trades must be able to say why.
int signalBars    = 0;   // bars that reached the entry slot
int rejGovernor   = 0;   // halted / max trades / out of session
int rejNoAtr      = 0;   // ATR not ready
int rejAtrBand    = 0;   // outside min/max ATR
int rejSpread     = 0;   // spread too wide
int rejNoWinOpen  = 0;   // window open unknown
int rejBody       = 0;   // signal bar body too small
int rejMove       = 0;   // move below threshold
int rejLots       = 0;   // risk budget below min lot
int rejOpposite   = 0;   // opposite signal while in a position
int rejMaxAdds    = 0;   // add limit reached
int rejStopTight  = 0;   // signal candle implies a stop too tight to trade
int rejBlockedHour= 0;   // hour listed in InpBlockHours
int addCount      = 0;   // stacked entries in the current position
int entriesSent   = 0;

// Calibration samples: |move| expressed in ATR multiples at each entry slot.
double moveSamples[];
int    sampleCount = 0;
datetime lastFunnelDay = 0;

// Daily governor
datetime dayStamp        = 0;
double   dayStartEquity  = 0.0;
double   dayStartBalance = 0.0;   // FTMO measures the daily limit against this
int      tradesToday     = 0;
bool     haltedToday     = false;

// Prop-firm state. ftmoStartBal anchors the overall limit for the life of the
// account, so it is captured once and never rolled with the day.
double   ftmoStartBal    = 0.0;
bool     ftmoBreached    = false;  // overall limit hit: stop trading permanently

// Risk-ladder state. ladderRisk is an absolute cash figure, not a percentage:
// the base is struck from equity once a day and the progression then works in
// currency, so a mid-day equity swing cannot silently resize the ladder.
double   ladderBaseCash  = 0.0;   // BaseRisk = day-start equity * InpLadderBasePct
double   ladderRiskCash  = 0.0;   // risk for the NEXT trade
int      ladderLosses    = 0;     // consecutive losses, reset by any win
double   ladderDayPnl    = 0.0;   // realised P/L since the day rolled
double   ladderPeakEq    = 0.0;   // high-water equity, for the drawdown rule
bool     ladderDDFreeze  = false; // drawdown limit breached: base risk only
ulong    ladderLastDeal  = 0;     // highest closing deal ticket already counted
datetime ladderScanFrom  = 0;     // history window start for the deal scan

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpWindowMin < 2 || InpEntryLeadMin < 1 || InpEntryLeadMin >= InpWindowMin)
   {
      Print("Bad window settings: entry lead must be >=1 and < window length.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   // minsLeft steps down one minute per M1 bar, so any whole-minute lead below
   // the window length is reachable. This is why the M1 requirement above is
   // not cosmetic: on an M5 chart minsLeft would skip the lead entirely.

   // Adapt to whatever timeframe the chart or tester supplies instead of
   // demanding M1. Refusing to start was silently indistinguishable from
   // taking no trades, which cost several rounds of misdiagnosis.
   int tfSec = PeriodSeconds();
   if(tfSec < 60 || tfSec > 3600 || tfSec % 60 != 0)
   {
      PrintFormat("Use a whole-minute timeframe from M1 to H1. Got %s.",
                  EnumToString((ENUM_TIMEFRAMES)Period()));
      return(INIT_PARAMETERS_INCORRECT);
   }
   barMin = tfSec / 60;

   if(InpWindowMin % barMin != 0)
   {
      PrintFormat("Window (%d min) must be a whole multiple of the %d-minute timeframe.",
                  InpWindowMin, barMin);
      return(INIT_PARAMETERS_INCORRECT);
   }
   // minsLeft moves in steps of one bar, so a lead that is not a multiple of
   // the timeframe is never reached and the EA would run but never enter.
   if(InpEntryLeadMin % barMin != 0)
   {
      PrintFormat("Entry lead (%d min) must be a multiple of the %d-minute timeframe. Valid leads here: %d, %d, %d ...",
                  InpEntryLeadMin, barMin, barMin, barMin * 2, barMin * 3);
      return(INIT_PARAMETERS_INCORRECT);
   }

   atrHandle = iATR(_Symbol, Period(), InpAtrPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpUseFixedLot && InpFixedLots <= 0.0)
   {
      Print("Fixed sizing is on but InpFixedLots is 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpFtmoEnable && InpFtmoDailyPct >= InpFtmoMaxPct)
      Print("Warning: daily limit is not below the overall limit — one day can end the account.");

   // Anchored once, for the life of the run: the overall limit is measured from
   // the account's original balance, so it must not move with deposits or with
   // the daily reset.
   ftmoStartBal = (InpFtmoStartBal > 0.0) ? InpFtmoStartBal
                                          : AccountInfoDouble(ACCOUNT_BALANCE);

   ResetDay();

   if(InpFtmoEnable)
      PrintFormat("FTMO guard ON | start balance %.2f | daily -%.2f%% | overall -%.2f%% | target %s | day resets %02d:00",
                  ftmoStartBal, InpFtmoDailyPct, InpFtmoMaxPct,
                  InpFtmoTargetPct > 0.0 ? StringFormat("+%.2f%%", InpFtmoTargetPct) : "off",
                  InpFtmoResetHr);

   // If this line is absent from the Journal, the EA never started and nothing
   // below it ran — that is a setup problem, not a signal problem.
   if(InpLadderEnable)
   {
      if(InpUseFixedLot)
      {
         Print("Init failed: the risk ladder sizes by risk, so InpUseFixedLot must be off.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpLadderBasePct <= 0.0 || InpLadderMult < 1.0)
      {
         Print("Init failed: InpLadderBasePct must be > 0 and InpLadderMult >= 1.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpLadderMaxPct > 0.0 && InpLadderMaxPct < LadderBasePct())
      {
         Print("Init failed: InpLadderMaxPct is below InpLadderBasePct - every trade would be capped.");
         return(INIT_PARAMETERS_INCORRECT);
      }

      // Every stop here can be silenced by a tighter one. Rather than let a dead
      // parameter look live, walk the ladder at init and say which rule ends
      // the day and what the others would have allowed.
      if(InpLadderMaxLosses > 0)
      {
         double basePct = LadderBasePct();
         double riskPct = basePct;
         double cumPct  = 0.0;
         int    bindsAt = 0;
         string binder  = "consecutive-loss stop";

         PrintFormat("Ladder ladder-depth check (base %.4f%%%s):",
                     basePct, InpLadderAutoBase ? ", auto-derived" : "");
         for(int n = 1; n <= InpLadderMaxLosses; n++)
         {
            double sized = (InpLadderMaxPct > 0.0 && riskPct > InpLadderMaxPct)
                         ? InpLadderMaxPct : riskPct;
            cumPct += sized;
            PrintFormat("    loss %d: risk %.4f%%%s  cumulative %.4f%%",
                        n, sized, sized < riskPct ? " (capped)" : "", cumPct);

            if(bindsAt == 0 && InpLadderDayLossPct > 0.0 && cumPct >= InpLadderDayLossPct)
            {
               bindsAt = n;
               if(n < InpLadderMaxLosses)
                  binder = "daily loss stop";
            }
            riskPct *= InpLadderMult;
         }

         if(bindsAt > 0 && bindsAt < InpLadderMaxLosses)
            PrintFormat("Ladder WARNING: the %.2f%% daily loss stop ends the day on loss %d, "
                        "so InpLadderMaxLosses=%d is unreachable. Enable InpLadderAutoBase, "
                        "or raise InpLadderDayLossPct to %.2f%%.",
                        InpLadderDayLossPct, bindsAt, InpLadderMaxLosses, cumPct);
         else
            PrintFormat("Ladder: worst day = %d losses costing %.2f%% of equity (%s binds).",
                        InpLadderMaxLosses, cumPct, binder);
      }

      ladderPeakEq = AccountInfoDouble(ACCOUNT_EQUITY);
      LadderResetDay();

      PrintFormat("Ladder ON - base=%.4f%% mult=%.2fx cap=%.2f%% | stops: %d consec losses, %.2f%% day, %.2f%% DD",
                  LadderBasePct(), InpLadderMult, InpLadderMaxPct,
                  InpLadderMaxLosses, InpLadderDayLossPct, InpLadderMaxDDPct);
   }

   PrintFormat("MIC init OK - %s %s | window=%dm lead=%dm | sizing=%s | thresh=%s | stop=%s | target=%s | flat_at_close=%s | digits=%d point=%g",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpWindowMin, InpEntryLeadMin,
               InpLadderEnable ? StringFormat("ladder %.4f%% base", LadderBasePct())
                               : InpUseFixedLot ? StringFormat("fixed %.2f lots", InpFixedLots)
                              : StringFormat("%.2f%% risk", InpRiskPct),
               InpUseAtrThresh ? StringFormat("%.2f x ATR", InpMoveAtrMult)
                               : StringFormat("$%.2f", InpMoveThreshUsd),
               InpStopMode == STOP_SIGNAL
                  ? StringFormat("signal candle (%s) +%.2f %s buffer",
                       InpStopAnchor == ANCHOR_PREV ? "previous"
                     : InpStopAnchor == ANCHOR_BOTH ? "both" : "signal",
                       InpBufUseAtr ? InpBufAtrMult : InpBufUsd,
                       InpBufUseAtr ? "xATR" : "USD")
                  : InpStopMode == STOP_ATR
                     ? StringFormat("%.2f x ATR", InpStopAtrMult)
                     : StringFormat("$%.2f", InpStopUsd),
               InpUseTarget ? StringFormat("%.2f R", InpTargetR) : "off",
               InpFlatAtWinClose ? "yes" : "no",
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   PrintFunnel("final");
   if(signalBars == 0)
      Print("    No bars reached the entry slot — check that the tester has M1 history and the chart is M1.");
   else if(entriesSent == 0)
      Print("    Entry slots were reached but every one was filtered. The largest counter above is the cause.");
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Prop limits are breached intrabar, not on bar close, so this runs on every
   // tick and before anything else. Everything below it is bar-gated.
   if(!PropGuard())
      return;

   // Ladder state is account state, so it is maintained on every tick, ahead of
   // the bar gate: a stop filled mid-bar must move the ladder and can trip the
   // consecutive-loss stop before the next entry slot is even considered.
   if(InpLadderEnable)
   {
      LadderTrackDrawdown();
      LadderPoll();
   }

   // The max-hold backstop exists for the case where bars stop printing - an
   // illiquid window, a halt, a weekend - so it cannot live behind the bar gate
   // that those same conditions freeze.
   EnforceMaxHold();

   // Everything is decided on closed M1 bars, matching the Pine version's
   // calc_on_every_tick=false. Intrabar ticks only matter for the broker-side
   // stop, which is already sitting on the server.
   datetime barTime = iTime(_Symbol, Period(), 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   RollDay();

   MqlDateTime fd;
   TimeToStruct(closedBarOrNow(), fd);
   fd.hour = 0; fd.min = 0; fd.sec = 0;
   if(InpVerbose && StructToTime(fd) != lastFunnelDay)
   {
      if(lastFunnelDay != 0)
         PrintFunnel("daily");
      lastFunnelDay = StructToTime(fd);
   }

   datetime closedBar = iTime(_Symbol, Period(), 1);
   if(closedBar == 0)
      return;

   long   winSec     = (long)InpWindowMin * 60;
   long   winId      = (long)closedBar / winSec;
   long   secIntoWin = (long)closedBar % winSec;
   int    minsLeft   = InpWindowMin - (int)(secIntoWin / 60) - barMin;

   // First bar seen inside a new window defines that window's open price.
   if(winId != curWinId)
   {
      curWinId   = winId;
      curWinOpen = iOpen(_Symbol, Period(), 1);
   }

   if(minsLeft == 0)
   {
      if(InpFlatAtWinClose)
      {
         CloseAll("window close");
         addCount = 0;
         return;
      }
      addCount = 0;
   }

   if(!HasPosition())
      addCount = 0;

   if(minsLeft != InpEntryLeadMin)
      return;

   if(HasPosition() && !InpAllowAdds)
      return;

   TryEnter(closedBar);
}

//+------------------------------------------------------------------+
datetime closedBarOrNow()
{
   datetime t = iTime(_Symbol, Period(), 1);
   return(t == 0 ? TimeCurrent() : t);
}

//+------------------------------------------------------------------+
void PrintFunnel(const string tag)
{
   PrintFormat("=== MIC funnel (%s) === entry slots:%d  sent:%d", tag, signalBars, entriesSent);
   PrintFormat("    rejected - move:%d body:%d governor:%d atr_band:%d atr_na:%d spread:%d win_open:%d lots:%d",
               rejMove, rejBody, rejGovernor, rejAtrBand, rejNoAtr, rejSpread, rejNoWinOpen, rejLots);
   PrintFormat("    rejected - opposite_signal:%d max_adds:%d blocked_hour:%d stop_too_tight:%d",
               rejOpposite, rejMaxAdds, rejBlockedHour, rejStopTight);

   if(sampleCount > 0)
   {
      double sorted[];
      ArrayResize(sorted, sampleCount);
      ArrayCopy(sorted, moveSamples, 0, 0, sampleCount);
      ArraySort(sorted);
      PrintFormat("    |move|/ATR at entry slot over %d samples - median:%.2f  p75:%.2f  p90:%.2f  p99:%.2f  max:%.2f",
                  sampleCount,
                  sorted[(int)(sampleCount * 0.50)],
                  sorted[(int)(sampleCount * 0.75)],
                  sorted[(int)(sampleCount * 0.90)],
                  sorted[(int)MathMin(sampleCount - 1, (int)(sampleCount * 0.99))],
                  sorted[sampleCount - 1]);
      Print("    Set InpMoveAtrMult near p75-p90 to trade the top quarter to tenth of moves.");
   }
}

//+------------------------------------------------------------------+
void TryEnter(const datetime signalBar)
{
   signalBars++;
   if(haltedToday || tradesToday >= InpMaxTradesDay || !InSession(signalBar)
      || (InpLadderEnable && LadderRiskForTrade() <= 0.0))
   {
      rejGovernor++;
      return;
   }
   if(IsBlockedHour(signalBar) || IsFridayCutoff(signalBar))
   {
      rejBlockedHour++;
      return;
   }

   double atr = Atr();
   if(atr <= 0.0)
   {
      rejNoAtr++;
      return;
   }
   if((InpMinAtr > 0.0 && atr < InpMinAtr) || (InpMaxAtr > 0.0 && atr > InpMaxAtr))
   {
      rejAtrBand++;
      return;
   }

   if(InpMaxSpreadUsd > 0.0)
   {
      double spreadUsd = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(spreadUsd > InpMaxSpreadUsd)
      {
         rejSpread++;
         return;
      }
   }

   if(curWinOpen <= 0.0)
   {
      rejNoWinOpen++;
      return;
   }
   double winOpen = curWinOpen;

   double o = iOpen (_Symbol, Period(), 1);
   double h = iHigh (_Symbol, Period(), 1);
   double l = iLow  (_Symbol, Period(), 1);
   double c = iClose(_Symbol, Period(), 1);

   double move      = c - winOpen;
   double threshold = InpUseAtrThresh ? atr * InpMoveAtrMult : InpMoveThreshUsd;

   // Every entry slot is sampled before any threshold is applied, so the run
   // can report what gold actually does instead of only whether it cleared a
   // number picked in advance.
   if(atr > 0.0)
   {
      if(sampleCount >= ArraySize(moveSamples))
         ArrayResize(moveSamples, sampleCount + 4096);
      moveSamples[sampleCount++] = MathAbs(move) / atr;
   }

   if(InpCalibrate)
      return;

   double range   = h - l;
   double bodyPct = range > 0.0 ? MathAbs(c - o) / range * 100.0 : 0.0;
   if(bodyPct < InpMinBodyPct)
   {
      rejBody++;
      return;
   }

   bool alignedUp   = !InpRequireAlign || c > o;
   bool alignedDown = !InpRequireAlign || c < o;

   bool goLong  = InpAllowLong  && move >=  threshold && alignedUp;
   bool goShort = InpAllowShort && move <= -threshold && alignedDown;
   if(!goLong && !goShort)
   {
      rejMove++;
      if(InpVerbose && MathAbs(move) >= threshold * 0.5)
         PrintFormat("skip @%s move=%.2f thresh=%.2f atr=%.2f body=%.0f%%",
                     TimeToString(signalBar, TIME_MINUTES), move, threshold, atr, bodyPct);
      return;
   }

   // Under netting an opposite order reduces the open position instead of
   // opening a new trade, which is not what the signal means. Skip it and let
   // the window boundary do the flattening.
   int    openDir = PositionDir();
   int    wantDir = goLong ? 1 : -1;
   if(openDir != 0)
   {
      if(openDir != wantDir)
      {
         rejOpposite++;
         return;
      }
      if(addCount >= InpMaxAdds)
      {
         rejMaxAdds++;
         return;
      }
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // The stop as a PRICE. In SIGNAL mode it is fixed by the candle, so the
   // distance follows from where we actually fill rather than the other way
   // round - which is what makes InpTargetR a true ratio on realised risk.
   double slPrice = 0.0;
   double stopDist = 0.0;

   if(InpStopMode == STOP_SIGNAL)
   {
      double buf = InpBufUseAtr ? atr * InpBufAtrMult : InpBufUsd;

      // Bar 1 is the signal candle, bar 2 the one before it.
      double pH = iHigh(_Symbol, Period(), 2);
      double pL = iLow (_Symbol, Period(), 2);

      // iHigh/iLow return 0 when the bar is not available, and a zero anchor
      // would put the stop at price 0 and size the position off the full price
      // of gold. Stand down instead.
      if(InpStopAnchor != ANCHOR_SIGNAL && (pH <= 0.0 || pL <= 0.0))
      {
         rejNoWinOpen++;
         if(InpVerbose)
            Print("skip: previous candle unavailable for the stop anchor");
         return;
      }

      double anchLow  = l;
      double anchHigh = h;
      if(InpStopAnchor == ANCHOR_PREV)
      {
         anchLow  = pL;
         anchHigh = pH;
      }
      else if(InpStopAnchor == ANCHOR_BOTH)
      {
         anchLow  = MathMin(l, pL);
         anchHigh = MathMax(h, pH);
      }

      slPrice  = goLong ? anchLow - buf : anchHigh + buf;
      stopDist = goLong ? ask - slPrice : slPrice - bid;

      // A stop tighter than the spread is a coin flip with leverage, and the
      // PREV anchor can land the stop on the wrong side of the entry entirely
      // (a fast move leaves the prior candle's low above the current ask), which
      // the <= 0 case catches.
      if(stopDist <= 0.0 || stopDist < InpMinStopUsd)
      {
         rejStopTight++;
         if(InpVerbose)
            PrintFormat("skip @%s stop too tight: dist=%.2f min=%.2f anchor=%.2f",
                        TimeToString(signalBar, TIME_MINUTES), stopDist,
                        InpMinStopUsd, slPrice);
         return;
      }
   }
   else
   {
      stopDist = (InpStopMode == STOP_ATR) ? atr * InpStopAtrMult : InpStopUsd;
      if(stopDist <= 0.0)
         return;
      slPrice = goLong ? ask - stopDist : bid + stopDist;
   }

   double lots = LotsForRisk(stopDist);
   if(lots <= 0.0)
   {
      rejLots++;
      return;
   }

   bool ok = false;
   if(goLong)
   {
      double sl = NormalizeDouble(slPrice, dg);
      double tp = InpUseTarget ? NormalizeDouble(ask + stopDist * InpTargetR, dg) : 0.0;
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, "MIC long");
   }
   else
   {
      double sl = NormalizeDouble(slPrice, dg);
      double tp = InpUseTarget ? NormalizeDouble(bid - stopDist * InpTargetR, dg) : 0.0;
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, "MIC short");
   }

   if(ok)
   {
      tradesToday++;
      entriesSent++;
      addCount++;
      // A netted position has one average price and one stop, so every add
      // moves the stop; without this the bracket still refers to the first fill.
      ApplyBracket(slPrice, stopDist);
   }
   else
      PrintFormat("Order rejected: retcode=%d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//|                            RISK LADDER                            |
//|                                                                   |
//| Position size is decided by one number: how much cash this trade  |
//| is allowed to lose. The ladder sets that number. The progression  |
//| does not change expectancy - with independent trades no sizing    |
//| rule can - it redistributes it, buying a higher chance of a small |
//| winning day with a lower chance of a large losing one. The stops  |
//| below are what keep that trade honest.                            |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| The base risk % actually used. With InpLadderAutoBase on it is    |
//| solved from the daily loss budget so that a full run of           |
//| InpLadderMaxLosses spends exactly that budget and no more, which  |
//| is what makes the loss count the real stop rather than a number   |
//| the daily limit silently overrides.                               |
//|                                                                   |
//| Sum of the geometric progression b(1 + m + ... + m^(n-1)) = L.    |
//+------------------------------------------------------------------+
double LadderBasePct()
{
   if(!InpLadderAutoBase || InpLadderMaxLosses <= 0 || InpLadderDayLossPct <= 0.0)
      return(InpLadderBasePct);

   double sum = 0.0;
   for(int i = 0; i < InpLadderMaxLosses; i++)
      sum += MathPow(InpLadderMult, i);

   if(sum <= 0.0)
      return(InpLadderBasePct);

   return(InpLadderDayLossPct / sum);
}

void LadderResetDay()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   ladderBaseCash = eq * LadderBasePct() / 100.0;
   ladderRiskCash = ladderBaseCash;
   ladderLosses   = 0;
   ladderDayPnl   = 0.0;
   ladderScanFrom = TimeCurrent();

   if(ladderPeakEq <= 0.0)
      ladderPeakEq = eq;

   if(InpLadderEnable && InpVerbose)
      PrintFormat("Ladder day reset - equity=%.2f base=%.2f (%.4f%%) cap=%.2f",
                  eq, ladderBaseCash, LadderBasePct(), eq * InpLadderMaxPct / 100.0);
}

//+------------------------------------------------------------------+
//| Peak-to-trough drawdown on equity. Measured on every tick because |
//| a drawdown is a fact about the account, not about bar closes.     |
//| The freeze is one-way within a run: once the account has been     |
//| 25% down, the progression stays off until it makes a new high.    |
//+------------------------------------------------------------------+
void LadderTrackDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > ladderPeakEq)
      ladderPeakEq = eq;

   if(InpLadderMaxDDPct <= 0.0 || ladderPeakEq <= 0.0)
      return;

   double dd = (ladderPeakEq - eq) / ladderPeakEq * 100.0;

   if(!ladderDDFreeze && dd >= InpLadderMaxDDPct)
   {
      ladderDDFreeze = true;
      ladderRiskCash = ladderBaseCash;
      ladderLosses   = 0;
      PrintFormat("Ladder DD freeze at %.2f%% (peak=%.2f equity=%.2f) - base risk only.",
                  dd, ladderPeakEq, eq);
   }
   else if(ladderDDFreeze && eq >= ladderPeakEq)
   {
      ladderDDFreeze = false;
      Print("Ladder DD freeze cleared - equity back at the high-water mark.");
   }
}

//+------------------------------------------------------------------+
//| Advance the ladder from closed deals. Polled rather than driven   |
//| from OnTrade so it is identical in the tester and live, and so a  |
//| stop filled while the EA was detached is still counted.           |
//|                                                                   |
//| A deal's result is profit + commission + swap: sizing off gross   |
//| profit would let a trade that paid its costs and nothing else     |
//| count as a win.                                                   |
//+------------------------------------------------------------------+
void LadderPoll()
{
   if(!HistorySelect(ladderScanFrom, TimeCurrent() + 86400))
      return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || ticket <= ladderLastDeal)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      ladderLastDeal = ticket;

      double net = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP);

      ladderDayPnl += net;

      if(net > InpLadderScratchCcy)
      {
         // Any win resets the whole progression. Not a partial step back -
         // the point of the ladder is that one win ends the sequence.
         ladderRiskCash = ladderBaseCash;
         ladderLosses   = 0;
      }
      else if(net < -InpLadderScratchCcy)
      {
         ladderLosses++;
         if(!ladderDDFreeze)
            ladderRiskCash *= InpLadderMult;
      }
      // Inside the dead band: a scratch. The ladder holds where it is.

      if(InpVerbose)
         PrintFormat("Ladder: deal #%I64u net=%.2f -> next risk=%.2f consec_losses=%d day_pnl=%.2f",
                     ticket, net, LadderRiskForTrade(), ladderLosses, ladderDayPnl);
   }

   LadderCheckStops();
}

//+------------------------------------------------------------------+
//| The two daily stops. Both are checked after every closed deal, so |
//| the halt lands before the next entry slot rather than after it.   |
//+------------------------------------------------------------------+
void LadderCheckStops()
{
   if(haltedToday)
      return;

   if(InpLadderMaxLosses > 0 && ladderLosses >= InpLadderMaxLosses)
   {
      haltedToday = true;
      CloseAll("ladder consecutive-loss stop");
      PrintFormat("Ladder stop: %d consecutive losses - flat for the rest of the day.",
                  ladderLosses);
      return;
   }

   if(InpLadderDayLossPct > 0.0 && dayStartEquity > 0.0)
   {
      double limit = dayStartEquity * InpLadderDayLossPct / 100.0;
      if(ladderDayPnl <= -limit)
      {
         haltedToday = true;
         CloseAll("ladder daily loss stop");
         PrintFormat("Ladder stop: day P/L %.2f breached the %.2f limit - flat for the day.",
                     ladderDayPnl, limit);
      }
   }
}

//+------------------------------------------------------------------+
//| The cash this trade may lose, after the per-trade cap. The cap is |
//| struck against LIVE equity, not day-start equity, so a day that   |
//| has already lost ground cannot keep sizing off the morning's      |
//| balance.                                                          |
//+------------------------------------------------------------------+
double LadderRiskForTrade()
{
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk = ladderDDFreeze ? ladderBaseCash : ladderRiskCash;

   if(InpLadderMaxPct > 0.0)
   {
      double cap = eq * InpLadderMaxPct / 100.0;
      if(risk > cap)
         risk = cap;
   }

   return(risk > 0.0 ? risk : 0.0);
}

//+------------------------------------------------------------------+
//| Lots such that stopDist dollars-per-ounce costs InpRiskPct of     |
//| equity. Derived from tick value so it holds for any XAU contract. |
//+------------------------------------------------------------------+
double LotsForRisk(const double stopDist)
{
   if(InpUseFixedLot)
      return(ClampLots(InpFixedLots));

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);

   double lossPerLot = stopDist / tickSize * tickValue;
   if(lossPerLot <= 0.0)
      return(0.0);

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = InpLadderEnable ? LadderRiskForTrade()
                                     : equity * InpRiskPct / 100.0;
   double lots     = riskCash / lossPerLot;

   return(ClampLots(lots));
}

//+------------------------------------------------------------------+
//| Round down to the broker's lot step and apply both the broker and |
//| InpMaxLots ceilings. Returns 0 when the size cannot be traded at  |
//| all, which callers treat as "stand down" rather than "use minimum".|
//+------------------------------------------------------------------+
double ClampLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(InpMaxLots > 0.0 && maxLot > InpMaxLots)
      maxLot = InpMaxLots;

   if(lots > maxLot)
      lots = maxLot;
   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot)
      return(0.0);

   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
double Atr()
{
   double buf[];
   if(CopyBuffer(atrHandle, 0, 1, 1, buf) != 1)
      return(0.0);
   return(buf[0]);
}

//+------------------------------------------------------------------+
//| +1 long, -1 short, 0 flat, for this symbol and magic.              |
//+------------------------------------------------------------------+
int PositionDir()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         return(pos.PositionType() == POSITION_TYPE_BUY ? 1 : -1);
   return(0);
}

//+------------------------------------------------------------------+
void ApplyBracket(const double slPrice, const double stopDist)
{
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != _Symbol || pos.Magic() != InpMagic)
         continue;

      bool   isLong = pos.PositionType() == POSITION_TYPE_BUY;
      double avg    = pos.PriceOpen();

      // SIGNAL mode keeps the candle-anchored price; the other modes keep their
      // distance from the netted average, which is what an add re-anchors.
      double sl = NormalizeDouble(
                     InpStopMode == STOP_SIGNAL ? slPrice
                                                : (isLong ? avg - stopDist : avg + stopDist), dg);

      // Risk measured from the position's actual average, so InpTargetR is a
      // true ratio on realised risk rather than on the distance estimated
      // before the fill. After an add the average has moved, so both levels
      // move with it.
      double risk = MathAbs(avg - sl);
      double tp   = InpUseTarget
                  ? NormalizeDouble(isLong ? avg + risk * InpTargetR : avg - risk * InpTargetR, dg)
                  : 0.0;

      if(MathAbs(pos.StopLoss() - sl) > SymbolInfoDouble(_Symbol, SYMBOL_POINT))
         if(!trade.PositionModify(pos.Ticket(), sl, tp))
            PrintFormat("Stop re-anchor failed: retcode=%d", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         return(true);
   return(false);
}

void CloseAll(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         if(!trade.PositionClose(pos.Ticket(), InpSlippagePts))
            PrintFormat("Close failed (%s): retcode=%d", reason, trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//| Friday cutoff. The window clock cannot flatten a position when the |
//| market stops producing bars, so the only reliable guard against    |
//| holding over the weekend is to not open the position at all.       |
//+------------------------------------------------------------------+
bool IsFridayCutoff(const datetime t)
{
   if(InpNoEntryFriHr <= 0)
      return(false);

   MqlDateTime st;
   TimeToStruct(t, st);
   return(st.day_of_week == 5 && st.hour >= InpNoEntryFriHr);
}

//+------------------------------------------------------------------+
//| Backstop for the case the window clock misses: a position that     |
//| outlives its window (a gap, a halt, a missed bar) is closed on the |
//| first tick after the limit. Wall-clock, not bar-counted, so it     |
//| still fires when no bars printed in between.                       |
//+------------------------------------------------------------------+
void EnforceMaxHold()
{
   if(InpMaxHoldMin <= 0)
      return;

   long limit = (long)InpMaxHoldMin * 60;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != _Symbol || pos.Magic() != InpMagic)
         continue;
      if((long)TimeCurrent() - (long)pos.Time() < limit)
         continue;
      if(!trade.PositionClose(pos.Ticket(), InpSlippagePts))
         PrintFormat("Max-hold close failed: retcode=%d", trade.ResultRetcode());
      else if(InpVerbose)
         PrintFormat("Max-hold flat: ticket=%I64u held=%d min", pos.Ticket(),
                     (int)(((long)TimeCurrent() - (long)pos.Time()) / 60));
   }
}

//+------------------------------------------------------------------+
//| True when the signal falls in an hour listed in InpBlockHours.     |
//| Parsed per call rather than cached: this runs once per entry slot, |
//| not per tick, so the cost is irrelevant next to the clarity.       |
//+------------------------------------------------------------------+
bool IsBlockedHour(const datetime t)
{
   if(StringLen(InpBlockHours) == 0)
      return(false);

   MqlDateTime st;
   TimeToStruct(t, st);

   string parts[];
   int n = StringSplit(InpBlockHours, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string one = parts[i];
      StringTrimLeft(one);
      StringTrimRight(one);
      if(StringLen(one) > 0 && (int)StringToInteger(one) == st.hour)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
bool InSession(const datetime t)
{
   if(InpSessionStartHr == 0 && InpSessionEndHr == 0)
      return(true);

   MqlDateTime st;
   TimeToStruct(t, st);

   if(InpSessionStartHr <= InpSessionEndHr)
      return(st.hour >= InpSessionStartHr && st.hour < InpSessionEndHr);
   return(st.hour >= InpSessionStartHr || st.hour < InpSessionEndHr);   // wraps midnight
}

//+------------------------------------------------------------------+
//| Prop-firm limits, evaluated on every tick against live equity so  |
//| floating losses count - which is how the firm measures them.      |
//| Returns false when trading must stop for now; the caller returns  |
//| immediately, so no new entry can follow a breach within the tick. |
//+------------------------------------------------------------------+
bool PropGuard()
{
   if(!InpFtmoEnable)
      return(true);

   if(ftmoBreached)
      return(false);   // overall limit is terminal: never trade again

   // The day may have rolled since the last bar; refresh the daily anchors
   // here rather than waiting for RollDay, which only runs on a new bar.
   if(PropDayStamp() != dayStamp)
      ResetDay();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Overall loss, measured from the account's starting balance for life.
   if(ftmoStartBal > 0.0)
   {
      double totalPct = (equity - ftmoStartBal) / ftmoStartBal * 100.0;
      if(totalPct <= -InpFtmoMaxPct)
      {
         ftmoBreached = true;
         haltedToday  = true;
         CloseAll("FTMO overall loss limit");
         PrintFormat("FTMO overall limit hit: %.2f%% from start balance %.2f. Trading stopped.",
                     totalPct, ftmoStartBal);
         return(false);
      }
   }

   if(haltedToday)
      return(false);

   if(dayStartBalance <= 0.0)
      return(true);

   double dayPct = (equity - dayStartBalance) / dayStartBalance * 100.0;

   if(dayPct <= -InpFtmoDailyPct)
   {
      haltedToday = true;
      CloseAll("FTMO daily loss limit");
      PrintFormat("FTMO daily limit hit: %.2f%% of day-start balance %.2f. Flat until the next prop day.",
                  dayPct, dayStartBalance);
      return(false);
   }

   // Banking a good day is a rule of the same kind: it protects the account
   // from giving the profit back, so it halts rather than merely reporting.
   if(InpFtmoTargetPct > 0.0 && dayPct >= InpFtmoTargetPct)
   {
      haltedToday = true;
      CloseAll("daily profit target");
      PrintFormat("Daily profit target hit: +%.2f%%. Flat until the next prop day.", dayPct);
      return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
void ResetDay()
{
   dayStamp        = PropDayStamp();
   dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   tradesToday     = 0;
   haltedToday     = false;

   LadderResetDay();
}

//+------------------------------------------------------------------+
//| Midnight of the current prop day. FTMO's day rolls at 00:00 in the|
//| firm's timezone; InpFtmoResetHr shifts it when the broker's server|
//| clock differs, so the guard resets when the firm's does, not when |
//| the server date changes.                                          |
//+------------------------------------------------------------------+
datetime PropDayStamp()
{
   datetime shifted = (datetime)((long)TimeCurrent() - (long)InpFtmoResetHr * 3600);
   MqlDateTime st;
   TimeToStruct(shifted, st);
   st.hour = 0; st.min = 0; st.sec = 0;
   return(StructToTime(st));
}

void RollDay()
{
   if(PropDayStamp() != dayStamp)
   {
      ResetDay();
      return;
   }

   // 0 disables the governor entirely. Without this guard a threshold of 0 halts
   // the moment the day is a cent down, which silently empties the run.
   if(InpDailyLossPct > 0.0 && dayStartEquity > 0.0 && !haltedToday)
   {
      double pnlPct = (AccountInfoDouble(ACCOUNT_EQUITY) - dayStartEquity) / dayStartEquity * 100.0;
      if(pnlPct <= -InpDailyLossPct)
      {
         haltedToday = true;
         CloseAll("daily loss stop");
         PrintFormat("Daily loss stop hit (%.2f%%) — flat for the rest of the day.", pnlPct);
      }
   }
}
//+------------------------------------------------------------------+
