//+------------------------------------------------------------------+
//| XAU_Ladder_Min.mq5                                               |
//| Momentum window entry with risk ladder sizing and a 2R target.    |
//+------------------------------------------------------------------+
#property copyright "trading-bot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

input int    InpWindowMin        = 60;
input int    InpEntryLeadMin     = 5;
input bool   InpUseAtrThresh     = true;
input double InpMoveThreshUsd    = 2.5;
input double InpMoveAtrMult      = 1.0;
input int    InpAtrPeriod        = 14;
input bool   InpAllowLong        = true;
input bool   InpAllowShort       = true;

input bool   InpStopFromCandle   = true;
input double InpStopAtrMult      = 1.5;
input double InpBufUsd           = 0.30;
input double InpMinStopUsd       = 0.80;
input double InpTargetR          = 2.0;

input double InpLadderBasePct    = 0.5;
input double InpLadderMult       = 1.5;
input double InpLadderMaxPct     = 5.0;
input int    InpLadderMaxLosses  = 5;
input double InpLadderDayLossPct = 2.0;
input double InpLadderMaxDDPct   = 25.0;
input bool   InpLadderAutoBase   = true;
input double InpLadderScratchCcy = 0.0;

input int    InpMaxTradesDay     = 100;
input double InpMaxSpreadUsd     = 0.0;
input string InpBlockHours       = "23";
input int    InpNoEntryFriHr     = 19;
input int    InpMaxHoldMin       = 45;

input long   InpMagic            = 590105;
input int    InpSlippagePts      = 20;
input bool   InpVerbose          = true;

CTrade        trade;
CPositionInfo pos;

int      atrHandle   = INVALID_HANDLE;
int      barMin      = 1;
datetime lastBarTime = 0;
long     curWinId    = -1;
double   curWinOpen  = 0.0;

datetime dayStamp       = 0;
double   dayStartEquity = 0.0;
int      tradesToday    = 0;
bool     haltedToday    = false;

double   ladderBaseCash = 0.0;
double   ladderRiskCash = 0.0;
int      ladderLosses   = 0;
double   ladderDayPnl   = 0.0;
double   ladderPeakEq   = 0.0;
bool     ladderDDFreeze = false;
ulong    ladderLastDeal = 0;
datetime ladderScanFrom = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   barMin = PeriodSeconds(Period()) / 60;
   if(barMin <= 0)
     {
      Print("Init failed: unsupported timeframe.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpWindowMin < 2 || InpEntryLeadMin < 1)
     {
      Print("Init failed: bad window or lead.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpEntryLeadMin >= InpWindowMin)
     {
      Print("Init failed: lead must be under the window.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   // The entry slot is matched on minutes left, so both must land on bars.
   if(InpWindowMin % barMin != 0 || InpEntryLeadMin % barMin != 0)
     {
      Print("Init failed: window and lead must be bar multiples.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpLadderBasePct <= 0.0 || InpLadderMult < 1.0)
     {
      Print("Init failed: bad ladder base or multiplier.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   atrHandle = iATR(_Symbol, Period(), InpAtrPeriod);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Init failed: no ATR handle.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   ladderPeakEq = AccountInfoDouble(ACCOUNT_EQUITY);
   ResetDay();
   ReportLadderDepth();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Walk the ladder at startup and say which rule ends the day.       |
//| A stop that a tighter one silences should not look configured.    |
//+------------------------------------------------------------------+
void ReportLadderDepth()
{
   if(InpLadderMaxLosses <= 0)
      return;

   double basePct = LadderBasePct();
   double riskPct = basePct;
   double cumPct  = 0.0;
   int    bindsAt = 0;

   PrintFormat("Ladder base risk pct %.4f", basePct);
   for(int n = 1; n <= InpLadderMaxLosses; n++)
     {
      double sized = riskPct;
      if(InpLadderMaxPct > 0.0 && sized > InpLadderMaxPct)
         sized = InpLadderMaxPct;
      cumPct += sized;
      PrintFormat("   loss %d risk %.4f cumulative %.4f", n, sized, cumPct);
      if(bindsAt == 0 && InpLadderDayLossPct > 0.0)
         if(cumPct >= InpLadderDayLossPct)
            bindsAt = n;
      riskPct *= InpLadderMult;
     }

   if(bindsAt > 0 && bindsAt < InpLadderMaxLosses)
      PrintFormat("WARNING daily loss stop ends the day on loss %d so "
                  "InpLadderMaxLosses %d is unreachable. Turn on "
                  "InpLadderAutoBase or raise the daily limit to %.2f",
                  bindsAt, InpLadderMaxLosses, cumPct);
   else
      PrintFormat("Worst day is %d losses costing %.2f pct of equity.",
                  InpLadderMaxLosses, cumPct);
}

//+------------------------------------------------------------------+
//| Base risk pct actually used. With auto base on it is solved from  |
//| the daily budget so a full run of losses spends exactly that      |
//| budget, which makes the loss count the real stop instead of a     |
//| number the daily limit silently overrides.                        |
//+------------------------------------------------------------------+
double LadderBasePct()
{
   if(!InpLadderAutoBase)
      return(InpLadderBasePct);
   if(InpLadderMaxLosses <= 0 || InpLadderDayLossPct <= 0.0)
      return(InpLadderBasePct);

   double sum = 0.0;
   for(int i = 0; i < InpLadderMaxLosses; i++)
      sum += MathPow(InpLadderMult, i);

   if(sum <= 0.0)
      return(InpLadderBasePct);

   return(InpLadderDayLossPct / sum);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Account state, so ahead of the bar gate: a stop filled mid bar must
   // move the ladder, and the hold limit exists for when bars stop.
   LadderTrackDrawdown();
   LadderPoll();
   EnforceMaxHold();

   datetime barTime = iTime(_Symbol, Period(), 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   RollDay();

   datetime closedBar = iTime(_Symbol, Period(), 1);
   if(closedBar == 0)
      return;

   long winSec     = (long)InpWindowMin * 60;
   long winId      = (long)closedBar / winSec;
   long secIntoWin = (long)closedBar % winSec;
   int  minsLeft   = InpWindowMin - (int)(secIntoWin / 60) - barMin;

   // First bar seen inside a window defines that window's open price.
   if(winId != curWinId)
     {
      curWinId   = winId;
      curWinOpen = iOpen(_Symbol, Period(), 1);
     }

   if(minsLeft != InpEntryLeadMin)
      return;
   if(HasPosition())
      return;

   TryEnter(closedBar);
}

//+------------------------------------------------------------------+
void TryEnter(const datetime signalBar)
{
   if(haltedToday || tradesToday >= InpMaxTradesDay)
      return;
   if(IsBlockedHour(signalBar) || IsFridayCutoff(signalBar))
      return;
   if(curWinOpen <= 0.0)
      return;

   double atr = Atr();
   if(atr <= 0.0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(InpMaxSpreadUsd > 0.0 && ask - bid > InpMaxSpreadUsd)
      return;

   double hi = iHigh(_Symbol, Period(), 1);
   double lo = iLow(_Symbol, Period(), 1);
   double cl = iClose(_Symbol, Period(), 1);

   double move = cl - curWinOpen;
   double thr  = InpMoveThreshUsd;
   if(InpUseAtrThresh)
      thr = atr * InpMoveAtrMult;

   bool goLong  = InpAllowLong && move >= thr;
   bool goShort = InpAllowShort && move <= -thr;
   if(!goLong && !goShort)
      return;

   // Stop as a price. From the candle it is fixed by structure, so the
   // distance follows from where we fill. That is what makes the target
   // a true ratio on risk actually taken.
   double slPrice = 0.0;
   double stopDist = 0.0;

   if(InpStopFromCandle)
     {
      if(goLong)
         slPrice = lo - InpBufUsd;
      else
         slPrice = hi + InpBufUsd;

      if(goLong)
         stopDist = ask - slPrice;
      else
         stopDist = slPrice - bid;
     }
   else
     {
      stopDist = atr * InpStopAtrMult;
      if(goLong)
         slPrice = ask - stopDist;
      else
         slPrice = bid + stopDist;
     }

   // A stop tighter than the spread is a coin flip with leverage.
   if(stopDist <= 0.0 || stopDist < InpMinStopUsd)
     {
      if(InpVerbose)
         PrintFormat("skip: stop too tight %.2f", stopDist);
      return;
     }

   double lots = LotsForRisk(stopDist);
   if(lots <= 0.0)
      return;

   int    dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(slPrice, dg);
   double tp = 0.0;
   bool   ok = false;

   if(goLong)
     {
      if(InpTargetR > 0.0)
         tp = NormalizeDouble(ask + stopDist * InpTargetR, dg);
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, "MIC long");
     }
   else
     {
      if(InpTargetR > 0.0)
         tp = NormalizeDouble(bid - stopDist * InpTargetR, dg);
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, "MIC short");
     }

   if(ok)
     {
      tradesToday++;
      if(InpVerbose)
         PrintFormat("Entry lots %.2f stop %.2f dist %.2f target %.2f risk %.2f",
                     lots, sl, stopDist, tp, LadderRiskForTrade());
     }
   else
      PrintFormat("Order rejected retcode %d", trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//| Lots so the stop distance costs exactly the ladder cash risk.     |
//| Derived from tick value so it holds for any contract size.        |
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

   return(ClampLots(LadderRiskForTrade() / lossPerLot));
}

//+------------------------------------------------------------------+
//| Zero means stand down, not use the minimum: rounding a rejected   |
//| size up to min lot would exceed the risk it was refusing.         |
//+------------------------------------------------------------------+
double ClampLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lots > maxLot)
      lots = maxLot;
   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot)
      return(0.0);

   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
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

   if(InpVerbose)
      PrintFormat("Ladder reset equity %.2f base %.2f", eq, ladderBaseCash);
}

//+------------------------------------------------------------------+
//| Drawdown is a fact about the account, not about bar closes, so    |
//| it is measured every tick. The freeze clears only at a new high,  |
//| never merely when the drawdown eases, or the progression re-arms  |
//| while the account is still far underwater.                        |
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
      PrintFormat("Ladder drawdown freeze at %.2f pct", dd);
     }
   else
      if(ladderDDFreeze && eq >= ladderPeakEq)
        {
         ladderDDFreeze = false;
         Print("Ladder drawdown freeze cleared at a new high.");
        }
}

//+------------------------------------------------------------------+
//| Advance the ladder from closed deals. Polled, not driven from     |
//| OnTrade, so it is the same in the tester and live and still       |
//| counts a stop that filled while the expert was detached.          |
//| A result is profit plus commission plus swap: sizing off gross    |
//| profit would let a trade that only paid its costs count as a win. |
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
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      ladderLastDeal = ticket;

      double net = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      net += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      net += HistoryDealGetDouble(ticket, DEAL_SWAP);
      ladderDayPnl += net;

      if(net > InpLadderScratchCcy)
        {
         // Any win resets the whole progression. The point of the ladder
         // is that one win ends the sequence, not that it steps back.
         ladderRiskCash = ladderBaseCash;
         ladderLosses   = 0;
        }
      else
         if(net < -InpLadderScratchCcy)
           {
            ladderLosses++;
            if(!ladderDDFreeze)
               ladderRiskCash *= InpLadderMult;
           }
      // Inside the dead band it is a scratch and the ladder holds.

      if(InpVerbose)
         PrintFormat("Ladder deal net %.2f next risk %.2f losses %d day %.2f",
                     net, LadderRiskForTrade(), ladderLosses, ladderDayPnl);
     }

   LadderCheckStops();
}

//+------------------------------------------------------------------+
//| Both daily stops, checked after every closed deal so the halt     |
//| lands before the next entry slot rather than after it.            |
//+------------------------------------------------------------------+
void LadderCheckStops()
{
   if(haltedToday)
      return;

   if(InpLadderMaxLosses > 0 && ladderLosses >= InpLadderMaxLosses)
     {
      haltedToday = true;
      CloseAll("consecutive loss stop");
      PrintFormat("Stop: %d consecutive losses, flat for the day.",
                  ladderLosses);
      return;
     }

   if(InpLadderDayLossPct > 0.0 && dayStartEquity > 0.0)
     {
      double limit = dayStartEquity * InpLadderDayLossPct / 100.0;
      if(ladderDayPnl <= -limit)
        {
         haltedToday = true;
         CloseAll("daily loss stop");
         PrintFormat("Stop: day pnl %.2f past limit %.2f, flat for the day.",
                     ladderDayPnl, limit);
        }
     }
}

//+------------------------------------------------------------------+
//| Cash this trade may lose, after the cap. The cap uses live        |
//| equity, so a day already down cannot keep sizing off the morning. |
//+------------------------------------------------------------------+
double LadderRiskForTrade()
{
   double risk = ladderRiskCash;
   if(ladderDDFreeze)
      risk = ladderBaseCash;

   if(InpLadderMaxPct > 0.0)
     {
      double cap = AccountInfoDouble(ACCOUNT_EQUITY) * InpLadderMaxPct / 100.0;
      if(risk > cap)
         risk = cap;
     }

   if(risk <= 0.0)
      return(0.0);
   return(risk);
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
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         return(true);
     }
   return(false);
}

//+------------------------------------------------------------------+
void CloseAll(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic)
         continue;
      if(!trade.PositionClose(pos.Ticket(), InpSlippagePts))
         PrintFormat("Close failed %s retcode %d", reason,
                     trade.ResultRetcode());
     }
}

//+------------------------------------------------------------------+
//| Wall clock, not bar counted, so it still fires when no bars have  |
//| printed in between: a halt, a thin window, a weekend.             |
//+------------------------------------------------------------------+
void EnforceMaxHold()
{
   if(InpMaxHoldMin <= 0)
      return;

   long limit = (long)InpMaxHoldMin * 60;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic)
         continue;
      if((long)TimeCurrent() - (long)pos.Time() < limit)
         continue;
      if(!trade.PositionClose(pos.Ticket(), InpSlippagePts))
         PrintFormat("Max hold close failed retcode %d",
                     trade.ResultRetcode());
     }
}

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
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0)
         continue;
      if((int)StringToInteger(s) == st.hour)
         return(true);
     }
   return(false);
}

//+------------------------------------------------------------------+
//| The window clock cannot flatten a position when the market stops  |
//| printing bars, so the only reliable guard against holding over    |
//| the weekend is to not open the position at all.                   |
//+------------------------------------------------------------------+
bool IsFridayCutoff(const datetime t)
{
   if(InpNoEntryFriHr <= 0)
      return(false);

   MqlDateTime st;
   TimeToStruct(t, st);
   if(st.day_of_week == 5 && st.hour >= InpNoEntryFriHr)
      return(true);
   return(false);
}

//+------------------------------------------------------------------+
datetime DayStamp()
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   st.hour = 0;
   st.min = 0;
   st.sec = 0;
   return(StructToTime(st));
}

//+------------------------------------------------------------------+
void ResetDay()
{
   dayStamp       = DayStamp();
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   tradesToday    = 0;
   haltedToday    = false;
   LadderResetDay();
}

//+------------------------------------------------------------------+
void RollDay()
{
   if(DayStamp() != dayStamp)
      ResetDay();
}
//+------------------------------------------------------------------+
