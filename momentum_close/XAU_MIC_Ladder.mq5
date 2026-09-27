//+------------------------------------------------------------------+
//| XAU_MIC_Ladder.mq5                                               |
//|                                                                  |
//| Momentum-in-candle entry with risk-ladder position sizing.        |
//|                                                                  |
//| The clock is cut into fixed windows. With InpEntryLeadMin minutes |
//| left in a window, if price has moved far enough from that         |
//| window's open, enter with the move. The stop sits beyond the      |
//| signal candle so risk is defined by the structure that produced   |
//| the entry, which is what makes InpTargetR a true ratio on risk    |
//| actually taken rather than on a distance guessed beforehand.      |
//|                                                                  |
//| Size comes from the ladder: base risk is struck once a day, a     |
//| loss multiplies the next trade's risk, any win resets it. The     |
//| progression does not create expectancy - with independent trades  |
//| no sizing rule can - it trades a higher chance of a small winning |
//| day for a lower chance of a large losing one. The daily stops are |
//| what keep that trade honest.                                     |
//+------------------------------------------------------------------+
#property copyright "trading-bot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//--- Window
input int    InpWindowMin        = 60;    // Window length (minutes)
input int    InpEntryLeadMin     = 5;     // Enter with N minutes left

//--- Entry
input bool   InpUseAtrThresh     = true;  // Threshold from ATR instead of $
input double InpMoveThreshUsd    = 2.5;   // Min move from window open ($)
input double InpMoveAtrMult      = 1.0;   // Min move (ATR multiples)
input int    InpAtrPeriod        = 14;    // ATR period
input bool   InpAllowLong        = true;
input bool   InpAllowShort       = true;

//--- Stop
enum EStopMode
{
   STOP_SIGNAL = 0,  // Beyond the signal candle
   STOP_ATR    = 1,  // ATR multiple
   STOP_USD    = 2   // Fixed $ distance
};
input EStopMode InpStopMode      = STOP_SIGNAL;
input double InpStopAtrMult      = 1.5;   // Stop distance (ATR mult) - ATR mode
input double InpStopUsd          = 3.0;   // Stop distance ($) - USD mode
input double InpBufUsd           = 0.30;  // SIGNAL mode: buffer beyond the candle ($)
// Size is risk / stop distance, so a doji signal candle implies a near-zero
// stop and a position limited only by the broker. Reject those.
input double InpMinStopUsd       = 0.80;  // Reject if the stop is tighter than ($)

//--- Target
// 2R is the ratio the ladder is built around: its progression only pays for
// itself if a win returns twice what a loss costs. Setting the ratio does not
// create it - a 2R target is reached less often than a 1R one, so the win rate
// falls and the two effects must be measured against each other. Break-even at
// 2R is a 33.3% win rate.
input double InpTargetR          = 2.0;   // Target (R multiples), 0 = no target

//--- Risk ladder
input double InpLadderBasePct    = 0.5;   // Base risk (% equity), recomputed daily
input double InpLadderMult       = 1.5;   // Risk multiplier after a loss
input double InpLadderMaxPct     = 5.0;   // Hard per-trade risk cap (% equity)
input int    InpLadderMaxLosses  = 5;     // Stop for the day after N consecutive losses
input double InpLadderDayLossPct = 2.0;   // Stop for the day at this daily loss (% equity)
input double InpLadderMaxDDPct   = 25.0;  // Freeze progression above this peak-to-trough DD
// Two stops that say the same thing, and the tighter silences the other: a
// 0.5% base at 1.5x costs 6.59% of equity to run five losses, so a 2% daily
// limit ends the day on the third and raising the loss count changes nothing.
// This solves the base instead - b(1 + m + ... + m^(n-1)) = L - so the full
// depth spends exactly the daily budget and both stops bind together.
input bool   InpLadderAutoBase   = true;  // Derive base so N losses = the daily limit
// Time-based exits close trades between -1R and +1R, so not every result is a
// clean win or loss. A result inside this band is a scratch: it neither
// advances the ladder nor resets it. Set it near your round-trip cost.
input double InpLadderScratchCcy = 0.0;   // Dead band around zero (account currency)

//--- Guards
input int    InpMaxTradesDay     = 100;   // Max trades per day
input double InpMaxSpreadUsd     = 0.0;   // Max spread ($), 0 = off
input string InpBlockHours       = "23";  // Hours to skip, e.g. "23" or "23,0,22"
input int    InpNoEntryFriHr     = 19;    // No new entries Friday from this hour, 0 = off
// A ceiling on which targets can be reached at all. Too tight and losses run
// their full -1R while winners are cut short of +2R, which is the one
// arithmetic a loss progression cannot survive.
input int    InpMaxHoldMin       = 45;    // Force-flat a position older than N min, 0 = off

//--- Plumbing
input long   InpMagic            = 590105;
input int    InpSlippagePts      = 20;
input bool   InpVerbose          = true;

CTrade        trade;
CPositionInfo pos;

int      atrHandle   = INVALID_HANDLE;
int      barMin      = 1;
datetime lastBarTime = 0;

// Window state, tracked forward bar by bar. Deriving it by timestamp lookup is
// wrong: gold M1 has minutes with no ticks, so the bar that opens a window is
// often absent and an exact lookup fails, silently voiding the window.
long     curWinId    = -1;
double   curWinOpen  = 0.0;

// Daily governor
datetime dayStamp       = 0;
double   dayStartEquity = 0.0;
int      tradesToday    = 0;
bool     haltedToday    = false;

// Ladder state. The risk is an absolute cash figure, not a percentage: the
// base is struck from equity once a day and the progression then works in
// currency, so a mid-day equity swing cannot silently resize the ladder.
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
      Print("Init failed: unsupported chart timeframe.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpWindowMin < 2 || InpEntryLeadMin < 1 || InpEntryLeadMin >= InpWindowMin)
   {
      Print("Init failed: need InpWindowMin >= 2 and 0 < InpEntryLeadMin < InpWindowMin.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   // The entry slot is found by matching minutes-left exactly, so the window
   // and the lead must both land on bar boundaries or the test never fires.
   if(InpWindowMin % barMin != 0 || InpEntryLeadMin % barMin != 0)
   {
      PrintFormat("Init failed: window (%d) and lead (%d) must both be multiples of the %d-minute bar.",
                  InpWindowMin, InpEntryLeadMin, barMin);
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLadderBasePct <= 0.0 || InpLadderMult < 1.0)
   {
      Print("Init failed: InpLadderBasePct must be > 0 and InpLadderMult >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   atrHandle = iATR(_Symbol, Period(), InpAtrPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Init failed: could not create the ATR handle.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   ladderPeakEq = AccountInfoDouble(ACCOUNT_EQUITY);
   ResetDay();
   ReportLadderDepth();

   PrintFormat("MIC+Ladder init OK - %s %s | window=%dm lead=%dm | stop=%s | target=%s",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpWindowMin, InpEntryLeadMin,
               InpStopMode == STOP_SIGNAL ? "signal candle"
                  : (InpStopMode == STOP_ATR ? StringFormat("%.2f x ATR", InpStopAtrMult)
                                             : StringFormat("$%.2f", InpStopUsd)),
               InpTargetR > 0.0 ? StringFormat("%.2fR", InpTargetR) : "off");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Every stop here can be silenced by a tighter one. Rather than let |
//| a dead parameter look live, walk the ladder at init and say which |
//| rule ends the day and what the others would have allowed.         |
//+------------------------------------------------------------------+
void ReportLadderDepth()
{
   if(InpLadderMaxLosses <= 0)
      return;

   double basePct = LadderBasePct();
   double riskPct = basePct;
   double cumPct  = 0.0;
   int    bindsAt = 0;

   PrintFormat("Ladder depth (base %.4f%%%s):", basePct,
               InpLadderAutoBase ? ", auto-derived" : "");
   for(int n = 1; n <= InpLadderMaxLosses; n++)
   {
      double sized = (InpLadderMaxPct > 0.0 && riskPct > InpLadderMaxPct)
                   ? InpLadderMaxPct : riskPct;
      cumPct += sized;
      PrintFormat("    loss %d: risk %.4f%%%s  cumulative %.4f%%",
                  n, sized, sized < riskPct ? " (capped)" : "", cumPct);
      if(bindsAt == 0 && InpLadderDayLossPct > 0.0 && cumPct >= InpLadderDayLossPct)
         bindsAt = n;
      riskPct *= InpLadderMult;
   }

   if(bindsAt > 0 && bindsAt < InpLadderMaxLosses)
      PrintFormat("Ladder WARNING: the %.2f%% daily loss stop ends the day on loss %d, "
                  "so InpLadderMaxLosses=%d is unreachable. Turn on InpLadderAutoBase, "
                  "or raise InpLadderDayLossPct to %.2f%%.",
                  InpLadderDayLossPct, bindsAt, InpLadderMaxLosses, cumPct);
   else
      PrintFormat("Ladder: worst day = %d losses costing %.2f%% of equity.",
                  InpLadderMaxLosses, cumPct);
}

//+------------------------------------------------------------------+
//| The base risk % actually used. With InpLadderAutoBase on it is    |
//| solved from the daily loss budget so a full run of                |
//| InpLadderMaxLosses spends exactly that budget and no more, which  |
//| makes the loss count the real stop rather than a number the daily |
//| limit silently overrides.                                         |
//+------------------------------------------------------------------+
double LadderBasePct()
{
   if(!InpLadderAutoBase || InpLadderMaxLosses <= 0 || InpLadderDayLossPct <= 0.0)
      return(InpLadderBasePct);

   double sum = 0.0;
   for(int i = 0; i < InpLadderMaxLosses; i++)
      sum += MathPow(InpLadderMult, i);

   return(sum > 0.0 ? InpLadderDayLossPct / sum : InpLadderBasePct);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Ladder and hold limits are account state, so they run on every tick and
   // ahead of the bar gate: a stop filled mid-bar must move the ladder and can
   // end the day before the next entry slot is even considered, and the hold
   // limit exists precisely for when bars stop printing.
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

   // The first bar seen inside a new window defines that window's open price.
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
   if(InpMaxSpreadUsd > 0.0 && (ask - bid) > InpMaxSpreadUsd)
      return;

   double h = iHigh (_Symbol, Period(), 1);
   double l = iLow  (_Symbol, Period(), 1);
   double c = iClose(_Symbol, Period(), 1);

   double move      = c - curWinOpen;
   double threshold = InpUseAtrThresh ? atr * InpMoveAtrMult : InpMoveThreshUsd;

   bool goLong  = InpAllowLong  && move >=  threshold;
   bool goShort = InpAllowShort && move <= -threshold;
   if(!goLong && !goShort)
      return;

   // The stop as a PRICE. In SIGNAL mode it is fixed by the candle, so the
   // distance follows from where we actually fill rather than the other way
   // round - which is what makes InpTargetR a true ratio on realised risk.
   double slPrice, stopDist;
   if(InpStopMode == STOP_SIGNAL)
   {
      slPrice  = goLong ? l - InpBufUsd : h + InpBufUsd;
      stopDist = goLong ? ask - slPrice : slPrice - bid;
   }
   else
   {
      stopDist = (InpStopMode == STOP_ATR) ? atr * InpStopAtrMult : InpStopUsd;
      slPrice  = goLong ? ask - stopDist : bid + stopDist;
   }

   // A stop tighter than the spread is a coin flip with leverage; a negative
   // one means the anchor sits on the wrong side of the entry entirely.
   if(stopDist <= 0.0 || stopDist < InpMinStopUsd)
   {
      if(InpVerbose)
         PrintFormat("skip @%s stop too tight: dist=%.2f min=%.2f",
                     TimeToString(signalBar, TIME_MINUTES), stopDist, InpMinStopUsd);
      return;
   }

   double lots = LotsForRisk(stopDist);
   if(lots <= 0.0)
      return;

   int    dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(slPrice, dg);
   double tp = 0.0;
   bool   ok;

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
         PrintFormat("Entry %s %.2f lots | stop=%.2f (%.2f) target=%.2f risk=%.2f",
                     goLong ? "LONG" : "SHORT", lots, sl, stopDist, tp,
                     LadderRiskForTrade());
   }
   else
      PrintFormat("Order rejected: retcode=%d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Lots such that stopDist dollars-per-ounce costs exactly the       |
//| ladder's cash risk. Derived from tick value so it holds for any   |
//| XAU contract size.                                                |
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
//| Round down to the broker's lot step and apply its ceiling.        |
//| Returns 0 when the size cannot be traded at all, which callers    |
//| treat as "stand down" rather than "use the minimum" - rounding a  |
//| rejected size up to min lot would silently exceed the risk.       |
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
//|                            RISK LADDER                            |
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
      PrintFormat("Ladder day reset - equity=%.2f base=%.2f (%.4f%%)",
                  eq, ladderBaseCash, LadderBasePct());
}

//+------------------------------------------------------------------+
//| Peak-to-trough drawdown on equity, measured every tick because a  |
//| drawdown is a fact about the account, not about bar closes. The   |
//| freeze clears only at a new high, not merely when the drawdown    |
//| ticks back under the limit - otherwise the progression re-arms    |
//| while the account is still deep underwater.                       |
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
//| A result is profit + commission + swap: sizing off gross profit   |
//| would let a trade that only paid its own costs count as a win and |
//| reset the progression.                                            |
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
         // Any win resets the whole progression. Not a step back - the point
         // of the ladder is that one win ends the sequence.
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
         PrintFormat("Ladder: deal #%I64u net=%.2f -> next risk=%.2f losses=%d day=%.2f",
                     ticket, net, LadderRiskForTrade(), ladderLosses, ladderDayPnl);
   }

   LadderCheckStops();
}

//+------------------------------------------------------------------+
//| The two daily stops, checked after every closed deal so the halt  |
//| lands before the next entry slot rather than after it.            |
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
//| has already lost ground cannot keep sizing off the morning.       |
//+------------------------------------------------------------------+
double LadderRiskForTrade()
{
   double risk = ladderDDFreeze ? ladderBaseCash : ladderRiskCash;

   if(InpLadderMaxPct > 0.0)
   {
      double cap = AccountInfoDouble(ACCOUNT_EQUITY) * InpLadderMaxPct / 100.0;
      if(risk > cap)
         risk = cap;
   }

   return(risk > 0.0 ? risk : 0.0);
}

//+------------------------------------------------------------------+
//|                             PLUMBING                              |
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
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         return(true);
   return(false);
}

//+------------------------------------------------------------------+
void CloseAll(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         if(!trade.PositionClose(pos.Ticket(), InpSlippagePts))
            PrintFormat("Close failed (%s): retcode=%d", reason, trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//| Wall-clock, not bar-counted, so it still fires when no bars have  |
//| printed in between - a halt, an illiquid window, a weekend.       |
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
         PrintFormat("Max-hold flat: ticket=%I64u", pos.Ticket());
   }
}

//+------------------------------------------------------------------+
//| True when the signal falls in an hour listed in InpBlockHours.    |
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
      if(StringLen(s) > 0 && (int)StringToInteger(s) == st.hour)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| The window clock cannot flatten a position when the market stops  |
//| producing bars, so the only reliable guard against holding over   |
//| the weekend is to not open the position at all.                   |
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
datetime DayStamp()
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   st.hour = 0; st.min = 0; st.sec = 0;
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
