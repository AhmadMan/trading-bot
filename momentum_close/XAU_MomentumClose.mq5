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
#property version   "1.30"
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
input double InpTargetR        = 1.0;    // Target (R multiples)
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
input int    InpMaxHoldMin     = 15;     // Force-flat a position older than N min, 0 = off

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
   PrintFormat("MIC init OK - %s %s | window=%dm lead=%dm | sizing=%s | thresh=%s | stop=%s | target=%s | flat_at_close=%s | digits=%d point=%g",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpWindowMin, InpEntryLeadMin,
               InpUseFixedLot ? StringFormat("fixed %.2f lots", InpFixedLots)
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

   // Everything is decided on closed M1 bars, matching the Pine version's
   // calc_on_every_tick=false. Intrabar ticks only matter for the broker-side
   // stop, which is already sitting on the server.
   datetime barTime = iTime(_Symbol, Period(), 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   RollDay();
   EnforceMaxHold();

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
   if(haltedToday || tradesToday >= InpMaxTradesDay || !InSession(signalBar))
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
   double riskCash = equity * InpRiskPct / 100.0;
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
