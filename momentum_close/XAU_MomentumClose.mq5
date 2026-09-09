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
#property version   "1.00"
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
input bool   InpUseAtrStop     = true;   // Stop from ATR instead of $
input double InpStopUsd        = 3.0;    // Stop distance ($)
input double InpStopAtrMult    = 1.5;    // Stop distance (ATR mult)
input bool   InpUseTarget      = false;  // Use profit target
input double InpTargetR        = 1.0;    // Target (R multiples)

//--- Risk
input double InpRiskPct        = 0.5;    // Risk per trade (% equity)
input int    InpMaxTradesDay   = 200;    // Max trades per day (adds count)
input double InpDailyLossPct   = 3.0;    // Daily loss stop (% equity)
input double InpMinAtr         = 0.0;    // Min ATR to trade ($), 0 = off
input double InpMaxAtr         = 0.0;    // Max ATR to trade ($), 0 = off
input double InpMaxSpreadUsd   = 0.0;    // Max spread ($), 0 = off
input bool   InpVerbose        = true;   // Log why entries are skipped
input bool   InpCalibrate      = false;  // Measure moves, place no trades

//--- Session (server time). Set both to 0 to trade around the clock.
input int    InpSessionStartHr = 0;
input int    InpSessionEndHr   = 0;

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
int addCount      = 0;   // stacked entries in the current position
int entriesSent   = 0;

// Calibration samples: |move| expressed in ATR multiples at each entry slot.
double moveSamples[];
int    sampleCount = 0;
datetime lastFunnelDay = 0;

// Daily governor
datetime dayStamp        = 0;
double   dayStartEquity  = 0.0;
int      tradesToday     = 0;
bool     haltedToday     = false;

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

   ResetDay();

   // If this line is absent from the Journal, the EA never started and nothing
   // below it ran — that is a setup problem, not a signal problem.
   PrintFormat("MIC init OK - %s %s | window=%dm lead=%dm | thresh=%s | digits=%d point=%g",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpWindowMin, InpEntryLeadMin,
               InpUseAtrThresh ? StringFormat("%.2f x ATR", InpMoveAtrMult)
                               : StringFormat("$%.2f", InpMoveThreshUsd),
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
      CloseAll("window close");
      addCount = 0;
      return;
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
   PrintFormat("    rejected - opposite_signal:%d max_adds:%d", rejOpposite, rejMaxAdds);

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

   double stopDist = InpUseAtrStop ? atr * InpStopAtrMult : InpStopUsd;
   if(stopDist <= 0.0)
      return;

   double lots = LotsForRisk(stopDist);
   if(lots <= 0.0)
   {
      rejLots++;
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   bool ok = false;
   if(goLong)
   {
      double sl = NormalizeDouble(ask - stopDist, dg);
      double tp = InpUseTarget ? NormalizeDouble(ask + stopDist * InpTargetR, dg) : 0.0;
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, "MIC long");
   }
   else
   {
      double sl = NormalizeDouble(bid + stopDist, dg);
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
      ResetStopFromAverage(stopDist);
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

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot)
      return(0.0);   // risk budget cannot buy the minimum lot — stand down
   if(lots > maxLot)
      lots = maxLot;

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
void ResetStopFromAverage(const double stopDist)
{
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i) || pos.Symbol() != _Symbol || pos.Magic() != InpMagic)
         continue;

      bool   isLong = pos.PositionType() == POSITION_TYPE_BUY;
      double avg    = pos.PriceOpen();
      double sl     = NormalizeDouble(isLong ? avg - stopDist : avg + stopDist, dg);
      double tp     = InpUseTarget
                    ? NormalizeDouble(isLong ? avg + stopDist * InpTargetR : avg - stopDist * InpTargetR, dg)
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
void ResetDay()
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   st.hour = 0; st.min = 0; st.sec = 0;

   dayStamp       = StructToTime(st);
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   tradesToday    = 0;
   haltedToday    = false;
}

void RollDay()
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   st.hour = 0; st.min = 0; st.sec = 0;

   if(StructToTime(st) != dayStamp)
   {
      ResetDay();
      return;
   }

   if(dayStartEquity > 0.0 && !haltedToday)
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
