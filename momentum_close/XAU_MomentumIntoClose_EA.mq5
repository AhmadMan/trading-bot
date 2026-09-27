//+------------------------------------------------------------------+
//|                                   XAU_MomentumIntoClose_EA.mq5   |
//|                                                                  |
//|  Port of the "XAU Momentum Into Close" Pine backtest, merged     |
//|  with the martingale-style recovery-risk system:                 |
//|                                                                  |
//|   ENTRY  (from the Pine script)                                  |
//|    * The clock is cut into fixed windows (default 5m), anchored   |
//|      to the epoch so they line up with :00/:05/... regardless of  |
//|      session - same boundary an expiring binary market would use. |
//|    * With N minutes left in the window, measure the move from the |
//|      window's open. If it clears the threshold (USD or ATR) AND   |
//|      the signal bar's close agrees with the move AND the body is  |
//|      big enough, that is the signal - evaluated ONCE per window,   |
//|      on the confirmed close of that one bar (no repaint).          |
//|                                                                  |
//|   EXIT                                                            |
//|    * Protective SL (ATR or fixed $) at entry, TP at a fixed R      |
//|      multiple - MT5 has no equivalent of Pine's "flatten only at   |
//|      window close with no real target", so this port adds a true   |
//|      1:2 R:R take-profit by default (InpUseTarget/InpTargetR).     |
//|    * Optional flatten at the window boundary (InpCloseAtWindowEnd) |
//|      to keep the original "edge lives only in the final minutes"   |
//|      premise if you want it; turn it off to let the 1:2 TP run.    |
//|    * RUNNER: the boundary is a guillotine - it cuts a trade that    |
//|      is running at the same clock tick as one that is not. With     |
//|      InpAllowRunner on, a trade already past InpRunnerMinR is       |
//|      promoted instead of closed: its take-profit is removed and a   |
//|      trailing stop takes over. Losers still die on the clock.       |
//|                                                                  |
//|   RISK (from the recovery-ladder spec)                            |
//|    * BaseRisk = day-start equity x InpBaseRiskPct, fixed for the   |
//|      day.                                                         |
//|    * After a loss: risk = previousRisk x InpLossMultiplier.        |
//|      After a win: risk resets to BaseRisk.                        |
//|    * Hard cap: risk never exceeds InpMaxRiskPct of CURRENT equity  |
//|      (recalculated every trade) - this is what keeps the ladder    |
//|      survivable; it is not optional.                              |
//|    * Daily circuit breaker: halt for the day after                |
//|      InpMaxConsecLosses in a row OR a daily loss of                |
//|      InpDailyLossLimitPct of day-start equity.                     |
//|    * Account circuit breaker: halt ALL trading (persists across    |
//|      restarts) if equity drops InpMaxDrawdownPct below its peak;   |
//|      also resets the ladder progression back to BaseRisk. Clear    |
//|      it with InpResetBreaker=true + reapply inputs, same pattern   |
//|      as the other EAs in this folder.                              |
//|                                                                  |
//|  The ladder step is rebuilt from today's CLOSED DEALS every tick,  |
//|  not carried in a plain variable - a restart mid-day replays the   |
//|  same step and can never forget a losing streak or double count.   |
//+------------------------------------------------------------------+
#property copyright "Built for Ahmad Mansour"
#property version   "1.20"
#property strict

#include <Trade/Trade.mqh>

//============================ INPUTS ================================
enum ENUM_MOVE_MODE { MOVE_USD, MOVE_ATR };
enum ENUM_STOP_MODE { STOP_USD, STOP_ATR };

input group "--- Window clock ---"
input int    InpWindowMin        = 5;     // Window length (minutes) - must divide evenly by the chart TF
input int    InpEntryLeadMin     = 2;     // Enter with N minutes left in the window
input bool   InpCloseAtWindowEnd = true;  // Flatten at the window boundary (the Pine premise)

input group "--- Runner: let a winner survive the window close ---"
// The boundary cuts a trade that is running at the same clock tick as one that
// is not, which caps every winner at the minutes left in the window while
// losers still pay their full stop. This keeps the guillotine for everything
// that has NOT proved itself and hands the rest to a trail instead.
//
// Promotion REMOVES the take-profit. A runner capped at InpTargetR is a normal
// trade with extra steps - the cap is the thing being traded away, in exchange
// for giving back part of the best price when the move ends.
input bool   InpAllowRunner      = true;  // Let a qualifying winner past the window boundary
input double InpRunnerMinR       = 1.0;   // Only run a trade already this many R in profit
input double InpRunnerTrailAtr   = 1.5;   // Trail the stop this far behind price (x ATR)
input double InpRunnerKeepPct    = 50.0;  // Bank if it gives back to this % of its best profit
input int    InpRunnerMaxMin     = 0;     // Hard cap on runner life (minutes), 0 = off

input group "--- Entry / momentum filter ---"
input ENUM_MOVE_MODE InpMoveMode = MOVE_ATR;  // Move threshold mode
input double InpMoveThreshUSD    = 2.5;   // Min move from window open ($) - used when mode = USD
input double InpMoveATRMult      = 1.5;   // Min move (ATR multiples) - used when mode = ATR
input int    InpATRPeriod        = 14;    // ATR length
input bool   InpRequireAlign     = true;  // Signal bar must close with the move
input double InpMinBodyPct       = 40.0;  // Min signal-bar body (% of range)
input bool   InpAllowLong        = true;
input bool   InpAllowShort       = true;
input bool   InpAllowAdds        = false; // Pyramid same-direction signals while already in a trade

input group "--- Exit ---"
input ENUM_STOP_MODE InpStopMode = STOP_ATR;  // Stop mode
input double InpStopUSD          = 3.0;   // Stop distance ($) - used when mode = USD
input double InpStopATRMult      = 1.5;   // Stop distance (ATR mult) - used when mode = ATR
input bool   InpUseTarget        = true;  // Use a fixed take-profit (MT5 port default: on)
input double InpTargetR          = 2.0;   // Target in R multiples - 2.0 = 1:2 risk:reward

input group "--- Risk ladder (loss-recovery progression) ---"
input double InpBaseRiskPct       = 2.0;   // Base risk (% of DAY-START equity), recalculated daily
input double InpLossMultiplier    = 1.5;   // Risk multiplier after each consecutive loss
input double InpMaxRiskPct        = 5.0;   // Hard cap: risk never exceeds this % of CURRENT equity
input double InpDailyLossLimitPct = 2.0;   // Stand down for the day at this cumulative loss %
input int    InpMaxConsecLosses   = 5;     // Stand down for the day after this many losses in a row
// The consecutive-loss stop and the daily loss stop are two ways of saying the
// same thing, and whichever is tighter silences the other. At a 2% base the
// FIRST trade already risks the whole of a 2% daily limit, so the day would end
// on loss 1 and the progression would never run. On derives the daily limit
// from what the ladder actually costs - sum of base x mult^i, each capped by
// InpMaxRiskPct - so both stops bind at the same point. Off uses the literal
// InpDailyLossLimitPct above, and init says which stop wins.
input bool   InpAutoDayLimit      = true;  // Derive the daily limit from the ladder depth
input int    InpMaxTradesPerDay   = 20;    // Hard cap on entries per day

input group "--- Account drawdown breaker (persists across restarts) ---"
input double InpMaxDrawdownPct = 25.0;   // Halt ALL trading if equity falls this % below its peak
input bool   InpResetBreaker   = false;  // Set true + reapply inputs to clear a tripped breaker

input group "--- Session filter (SERVER time, 24h) ---"
input bool   InpUseSession       = false;
input int    InpSessionStartHour = 8;
input int    InpSessionEndHour   = 17;

input group "--- Liquidity band (ATR $), 0 = off ---"
input double InpMinATR = 0.0;
input double InpMaxATR = 0.0;

input group "--- Misc ---"
input long   InpMagic    = 30952;
input int    InpSlippage = 30;
// The BAR/CHECK lines print once per bar, which is what makes a silent EA
// diagnosable - and on M1 it is also thousands of lines a day on a VPS. Off
// turns those two off and keeps every decision and failure message.
input bool   InpVerboseBars = true;       // Log the per-bar BAR / CHECK lines

//============================ GLOBALS ===============================
CTrade   trade;

// One ATR handle for the life of the EA. Building and releasing a handle per
// call works in the tester, where indicators are calculated synchronously, and
// fails live: a handle created on this tick has no data yet, CopyBuffer
// returns -1, and ATR reads 0.0 forever. Every downstream test then refuses
// to trade without saying so - the threshold, the stop and the liquidity band
// all go through it.
int      g_atrHandle        = INVALID_HANDLE;

datetime g_curDay           = 0;
double   g_dayStartEquity   = 0.0;
double   g_baseRiskMoney    = 0.0;
int      g_tradesToday      = 0;
bool     g_dayHalted        = false;

int      g_ladderStep       = 0;      // consecutive losses since g_ladderResetTime, replayed each tick
int      g_consecLossesToday = 0;     // consecutive losses today (breaker-reset independent)
double   g_dailyLossMoney   = 0.0;

double   g_peakEquity       = 0.0;
bool     g_breakerTripped   = false;
datetime g_ladderResetTime  = 0;      // ladder step only counts deals closed at/after this time

datetime g_lastBarTime      = 0;
long     g_lastWinId        = -1;
double   g_windowOpen       = 0.0;

// Runner state. g_entryStopDist is the ORIGINAL stop distance, captured at
// entry: once the trail starts moving the stop, entry-to-stop no longer
// describes the risk that was actually taken, so R has to be stored.
bool     g_runnerActive     = false;
double   g_runnerPeak       = 0.0;    // best open profit seen while running
datetime g_runnerSince      = 0;
double   g_entryStopDist    = 0.0;    // stop distance of the live position

string   g_status           = "starting";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   int tfMin = (int)MathRound(PeriodSeconds() / 60.0);
   if(PeriodSeconds() < 60 || PeriodSeconds() % 60 != 0)
   {
      Alert("Attach this EA to a whole-minute intraday chart (M1 recommended).");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpWindowMin % tfMin != 0)
   {
      Alert("Window length must be a whole multiple of the chart timeframe.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpEntryLeadMin >= InpWindowMin)
   {
      Alert("Entry lead must be shorter than the window.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpEntryLeadMin % tfMin != 0)
   {
      Alert(StringFormat("Entry lead must be a multiple of the chart timeframe (%d min).", tfMin));
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Alert("Could not create the ATR handle.");
      return(INIT_FAILED);
   }

   LoadBreakerState();
   NewDayReset();
   PrintFormat("INIT ok | %s %s | window %dm lead %dm | peak %.2f equity %.2f | breaker %s | algo trading %s",
               _Symbol, EnumToString(_Period), InpWindowMin, InpEntryLeadMin, g_peakEquity,
               AccountInfoDouble(ACCOUNT_EQUITY), g_breakerTripped ? "TRIPPED" : "clear",
               TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "allowed" : "DISABLED in terminal");
   ReportLadderDepth();
   PrintFormat("INIT runner | %s | needs %.2fR at the boundary | trail %.2f x ATR | keep %.0f%% of best | max %s",
               InpAllowRunner ? "ON" : "off", InpRunnerMinR, InpRunnerTrailAtr, InpRunnerKeepPct,
               InpRunnerMaxMin > 0 ? StringFormat("%d min", InpRunnerMaxMin) : "no limit");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| The daily loss limit actually enforced. With InpAutoDayLimit on it |
//| is what a full run of InpMaxConsecLosses costs, so the loss count  |
//| is the real stop rather than a number the daily limit overrides.   |
//+------------------------------------------------------------------+
double DailyLimitPct()
{
   if(!InpAutoDayLimit || InpMaxConsecLosses <= 0)
      return(InpDailyLossLimitPct);

   double risk = InpBaseRiskPct;
   double cum  = 0.0;
   for(int i = 0; i < InpMaxConsecLosses; i++)
   {
      double sized = risk;
      if(InpMaxRiskPct > 0.0 && sized > InpMaxRiskPct) sized = InpMaxRiskPct;
      cum += sized;
      risk *= InpLossMultiplier;
   }
   return(cum);
}

//+------------------------------------------------------------------+
//| Walk the ladder at startup and say what the worst day costs and    |
//| which rule ends it. A stop that a tighter one silences should not  |
//| look configured.                                                   |
//+------------------------------------------------------------------+
void ReportLadderDepth()
{
   if(InpMaxConsecLosses <= 0)
      return;

   double risk  = InpBaseRiskPct;
   double cum   = 0.0;
   double lim   = DailyLimitPct();
   int    binds = 0;

   PrintFormat("LADDER depth | base %.4f%% x%.2f | per-trade cap %.2f%% | daily limit %.2f%%%s",
               InpBaseRiskPct, InpLossMultiplier, InpMaxRiskPct, lim,
               InpAutoDayLimit ? " (derived)" : "");
   for(int n = 1; n <= InpMaxConsecLosses; n++)
   {
      double sized  = risk;
      bool   capped = (InpMaxRiskPct > 0.0 && sized > InpMaxRiskPct);
      if(capped) sized = InpMaxRiskPct;
      cum += sized;
      PrintFormat("   loss %d: risk %.4f%%%s  cumulative %.4f%%",
                  n, sized, capped ? " (capped)" : "", cum);
      if(binds == 0 && lim > 0.0 && cum >= lim) binds = n;
      risk *= InpLossMultiplier;
   }

   if(binds > 0 && binds < InpMaxConsecLosses)
      PrintFormat("LADDER WARNING: the %.2f%% daily limit ends the day on loss %d, so "
                  "InpMaxConsecLosses=%d is unreachable. Turn on InpAutoDayLimit, or "
                  "raise InpDailyLossLimitPct to %.2f%%.",
                  lim, binds, InpMaxConsecLosses, cum);
   else
      PrintFormat("LADDER: worst day is %d losses costing %.2f%% of equity. At that rate "
                  "the %.1f%% drawdown breaker trips after %.1f such days.",
                  InpMaxConsecLosses, cum, InpMaxDrawdownPct,
                  cum > 0.0 ? InpMaxDrawdownPct / cum : 0.0);
}

//| Peak equity + breaker + ladder-reset survive EA restarts           |
string GVKey(string k) { return(StringFormat("%s_%I64d_%I64d_mic_%s", _Symbol, AccountInfoInteger(ACCOUNT_LOGIN), InpMagic, k)); }
string GVPeak()        { return(GVKey("peak")); }
string GVBreaker()     { return(GVKey("brk")); }
string GVLadderReset() { return(GVKey("ldrst")); }

void LoadBreakerState()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity      = GlobalVariableCheck(GVPeak())        ? GlobalVariableGet(GVPeak())        : eq;
   g_breakerTripped  = GlobalVariableCheck(GVBreaker())     ? (GlobalVariableGet(GVBreaker()) > 0.5) : false;
   g_ladderResetTime = GlobalVariableCheck(GVLadderReset()) ? (datetime)GlobalVariableGet(GVLadderReset()) : 0;
   if(eq > g_peakEquity) g_peakEquity = eq;

   if(InpResetBreaker && g_breakerTripped)
   {
      g_breakerTripped  = false;
      g_peakEquity      = eq;              // don't re-trip instantly off the old peak
      g_ladderResetTime = TimeCurrent();   // resume at BaseRisk, not mid-ladder
      Print("Drawdown breaker manually cleared via InpResetBreaker.");
   }
   SaveBreakerState();
}

void SaveBreakerState()
{
   GlobalVariableSet(GVPeak(),        g_peakEquity);
   GlobalVariableSet(GVBreaker(),     g_breakerTripped ? 1.0 : 0.0);
   GlobalVariableSet(GVLadderReset(), (double)g_ladderResetTime);
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(DayStart(TimeCurrent()) != g_curDay) NewDayReset();

   // ---- account drawdown breaker (whole-account, survives restarts) --
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) { g_peakEquity = equity; SaveBreakerState(); }
   double dd = (g_peakEquity > 0.0) ? (g_peakEquity - equity) / g_peakEquity : 0.0;

   if(!g_breakerTripped && InpMaxDrawdownPct > 0.0 && dd >= InpMaxDrawdownPct / 100.0)
   {
      g_breakerTripped  = true;
      g_ladderResetTime = TimeCurrent();
      SaveBreakerState();
      CloseAll();
      PrintFormat("DRAWDOWN BREAKER TRIPPED at %.1f%% below peak (%.2f -> %.2f). "
                  "Halted until InpResetBreaker is set true and inputs reapplied.",
                  dd * 100.0, g_peakEquity, equity);
   }
   if(g_breakerTripped)
   {
      g_status = StringFormat("BREAKER TRIPPED (%.1f%% drawdown) - manual reset required", dd * 100.0);
      Comment(g_status);
      return;
   }

   // A runner is managed on every tick, not on the bar close: the whole point
   // of it is to follow a move that is still happening.
   ManageRunner();

   UpdateLadderFromHistory();

   if(!g_dayHalted)
   {
      if(g_consecLossesToday >= InpMaxConsecLosses)
         { g_dayHalted = true; g_status = StringFormat("DAILY HALT - %d losses in a row", g_consecLossesToday); PrintFormat("%s", g_status); }
      else if(DailyLimitPct() > 0.0 && g_dailyLossMoney >= g_dayStartEquity * DailyLimitPct() / 100.0)
         { g_dayHalted = true; g_status = StringFormat("DAILY HALT - loss %.2f reached", g_dailyLossMoney); PrintFormat("%s", g_status); }
   }

   bool longSig = false, shortSig = false, lastBar = false;
   bool newBar = RefreshWindowAndSignal(longSig, shortSig, lastBar);

   if(newBar && lastBar && HasOpenPosition())
      HandleWindowClose();

   ShowPanel();

   if(!newBar)                  return;
   if(!(longSig || shortSig))   return;
   string side = longSig ? "LONG" : "SHORT";
   if(g_dayHalted)              { PrintFormat("%s signal skipped: %s", side, g_status); return; }
   if(InpUseSession && !InSession()) { PrintFormat("%s signal skipped: outside session", side); return; }
   if(g_tradesToday >= InpMaxTradesPerDay) { PrintFormat("%s signal skipped: max trades/day", side); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      { PrintFormat("%s signal skipped: algo trading disabled (terminal or EA)", side); return; }

   int haveDir = PositionDirection();
   int wantDir = longSig ? 1 : -1;
   if(haveDir != 0)
   {
      // A runner owns the position. A new signal must not add to it, reverse
      // it or reset its trail - it is a different trade now, on different rules.
      if(g_runnerActive)       { PrintFormat("%s signal skipped: runner still open", side); return; }
      if(!InpAllowAdds)        { PrintFormat("%s signal skipped: already in a trade", side); return; }
      if(haveDir != wantDir)   { PrintFormat("%s signal skipped: opposite trade open", side); return; }
   }

   TryEnter(longSig, wantDir);
}

//+------------------------------------------------------------------+
//| RUNNER                                                            |
//|                                                                  |
//| The window boundary. Everything that has not proved itself is cut |
//| here exactly as before; a trade already past InpRunnerMinR is      |
//| promoted instead and handed to the trail.                         |
//+------------------------------------------------------------------+
void HandleWindowClose()
{
   if(g_runnerActive)
      return;                                   // already running, the trail owns it

   if(!InpCloseAtWindowEnd)
      return;                                   // boundary flattening is off entirely

   if(!InpAllowRunner)
   {
      CloseAll();
      return;
   }

   double rMult = OpenProfitR();
   if(rMult < InpRunnerMinR)
   {
      PrintFormat("WINDOW CLOSE: flat at %.2fR (runner needs %.2fR).", rMult, InpRunnerMinR);
      CloseAll();
      return;
   }

   PromoteToRunner(rMult);
}

//--- Open profit of the live position, expressed in R.
double OpenProfitR()
{
   if(g_entryStopDist <= 0.0)
      return(0.0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double move = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                  ? cur - open : open - cur;
      return(move / g_entryStopDist);
   }
   return(0.0);
}

//--- Money profit of the live position, for the give-back rule.
double OpenProfitMoney()
{
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return(sum);
}

//--- Strip the take-profit and start the trail.
void PromoteToRunner(const double rMult)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double sl = PositionGetDouble(POSITION_SL);
      if(!trade.PositionModify(tk, sl, 0.0))
      {
         PrintFormat("RUNNER PROMOTE FAILED on %I64u: retcode %u (%s) - closing as normal.",
                     tk, trade.ResultRetcode(), trade.ResultRetcodeDescription());
         CloseAll();
         return;
      }
   }

   g_runnerActive = true;
   g_runnerPeak   = OpenProfitMoney();
   g_runnerSince  = TimeCurrent();

   PrintFormat("RUNNER ON: %.2fR up at the window close - target removed, trailing %.2f x ATR.",
               rMult, InpRunnerTrailAtr);
}

//+------------------------------------------------------------------+
//| The runner's three ways to end: the trailing stop catches it, it  |
//| gives back too much of its best, or it outlives its time cap.     |
//| The trail is a broker-side stop - the one that still fires if the |
//| VPS drops - and the other two close at market.                    |
//+------------------------------------------------------------------+
void ManageRunner()
{
   if(!g_runnerActive)
      return;

   if(!HasOpenPosition())
   {
      // The trail, or a gap, already closed it.
      PrintFormat("RUNNER CLOSED by its stop. Best open profit was %.2f.", g_runnerPeak);
      g_runnerActive = false;
      g_runnerPeak   = 0.0;
      return;
   }

   double profit = OpenProfitMoney();
   if(profit > g_runnerPeak)
      g_runnerPeak = profit;

   // Give-back: bank what is left rather than watch a winner round-trip.
   if(InpRunnerKeepPct > 0.0 && g_runnerPeak > 0.0)
   {
      double floorProfit = g_runnerPeak * InpRunnerKeepPct / 100.0;
      if(profit <= floorProfit)
      {
         PrintFormat("RUNNER BANKED: %.2f of a best %.2f (floor %.0f%%).",
                     profit, g_runnerPeak, InpRunnerKeepPct);
         CloseAll();
         return;
      }
   }

   if(InpRunnerMaxMin > 0 && TimeCurrent() - g_runnerSince >= InpRunnerMaxMin * 60)
   {
      PrintFormat("RUNNER TIMED OUT after %d minutes at %.2f.", InpRunnerMaxMin, profit);
      CloseAll();
      return;
   }

   // Trail. Ratchets one way only - a stop that can loosen is not a stop.
   double atr = ATR();
   if(atr <= 0.0 || InpRunnerTrailAtr <= 0.0)
      return;

   double dist    = InpRunnerTrailAtr * atr;
   double minDist = StopLevelPrice();
   if(dist < minDist) dist = minDist;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   isLong = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double cur    = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl     = PositionGetDouble(POSITION_SL);
      double want   = NormalizeDouble(isLong ? cur - dist : cur + dist, _Digits);

      if(isLong)
      {
         if(sl > 0.0 && want <= sl) continue;   // never loosen
         if(cur - want < minDist)   continue;   // broker would reject it
      }
      else
      {
         if(sl > 0.0 && want >= sl) continue;
         if(want - cur < minDist)   continue;
      }

      if(!trade.PositionModify(tk, want, 0.0))
         PrintFormat("RUNNER TRAIL FAILED on %I64u: retcode %u (%s)",
                     tk, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Window clock + signal - evaluated once per new, confirmed bar     |
//+------------------------------------------------------------------+
bool RefreshWindowAndSignal(bool &longSig, bool &shortSig, bool &lastBar)
{
   longSig = false; shortSig = false; lastBar = false;

   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == g_lastBarTime) return(false);      // no new bar yet
   g_lastBarTime = t0;

   datetime t = iTime(_Symbol, _Period, 1);    // the bar that just closed
   if(t == 0) return(false);
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);

   int winSec = InpWindowMin * 60;
   long winId = (long)(t / winSec);
   if(winId != g_lastWinId) { g_windowOpen = open1; g_lastWinId = winId; }

   int tfMin      = (int)MathRound(PeriodSeconds() / 60.0);
   int secIntoWin = (int)(t % winSec);
   int minsLeft   = InpWindowMin - (secIntoWin / 60) - tfMin;

   bool isEntryBar = (minsLeft == InpEntryLeadMin);
   lastBar = (minsLeft <= 0);
   if(InpVerboseBars)
      PrintFormat("BAR %s | minsLeft %d (entry at %d) | window open %.2f",
                  TimeToString(t, TIME_DATE | TIME_MINUTES), minsLeft, InpEntryLeadMin, g_windowOpen);

   if(!isEntryBar || g_windowOpen <= 0.0) return(true);

   double atr = ATR();
   double move = close1 - g_windowOpen;
   double threshold = (InpMoveMode == MOVE_ATR) ? atr * InpMoveATRMult : InpMoveThreshUSD;

   double barRange = high1 - low1;
   double bodyPct  = (barRange > 0.0) ? MathAbs(close1 - open1) / barRange * 100.0 : 0.0;
   bool   barUp    = close1 > open1;
   bool   barDown  = close1 < open1;
   bool   alignedUp   = !InpRequireAlign || barUp;
   bool   alignedDown = !InpRequireAlign || barDown;
   bool   bodyOk      = bodyPct >= InpMinBodyPct;
   bool   liquidityOk = (atr > 0.0) &&
                        (InpMinATR <= 0.0 || atr >= InpMinATR) &&
                        (InpMaxATR <= 0.0 || atr <= InpMaxATR);

   longSig  = InpAllowLong  && move >=  threshold && alignedUp   && bodyOk && liquidityOk;
   shortSig = InpAllowShort && move <= -threshold && alignedDown && bodyOk && liquidityOk;
   if(InpVerboseBars)
      PrintFormat("CHECK %s | move %.2f vs thr %.2f | body %.0f%% (min %.0f) | ATR %.2f | aligned %s | long %s short %s",
                  TimeToString(t, TIME_DATE | TIME_MINUTES), move, threshold, bodyPct, InpMinBodyPct, atr,
                  (move >= 0 ? alignedUp : alignedDown) ? "yes" : "no",
                  longSig ? "YES" : "no", shortSig ? "YES" : "no");
   return(true);
}

//+------------------------------------------------------------------+
//| Sizing + order placement                                          |
//+------------------------------------------------------------------+
void TryEnter(bool isLong, int dir)
{
   double atr = ATR();
   double stopDist = (InpStopMode == STOP_ATR) ? atr * InpStopATRMult : InpStopUSD;
   if(stopDist <= StopLevelPrice())
   {
      g_status = "stop distance inside broker stop level - skipped";
      Print(g_status);
      return;
   }

   double maxRiskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpMaxRiskPct / 100.0;
   double riskMoney    = MathMin(g_baseRiskMoney * MathPow(InpLossMultiplier, g_ladderStep), maxRiskMoney);

   double lots = LotForRisk(stopDist, riskMoney, maxRiskMoney);
   if(lots <= 0.0)
   {
      g_status = "risk too small for min lot - skipped";
      Print(g_status);
      return;
   }

   double price = isLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(isLong ? price - stopDist : price + stopDist, _Digits);
   double tp = InpUseTarget
             ? NormalizeDouble(isLong ? price + stopDist * InpTargetR : price - stopDist * InpTargetR, _Digits)
             : 0.0;

   bool ok = isLong ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "MIC")
                     : trade.Sell(lots, _Symbol, 0.0, sl, tp, "MIC");
   if(ok)
   {
      g_tradesToday++;
      g_entryStopDist = stopDist;               // the R this trade is measured in
      PrintFormat("%s lots %.2f  risk %.2f (step %d)  SL %.2f  TP %.2f",
                  isLong ? "BUY" : "SELL", lots, riskMoney, g_ladderStep, sl, tp);
   }
   else
      PrintFormat("ORDER FAILED %s lots %.2f SL %.2f TP %.2f -> retcode %u (%s)",
                  isLong ? "BUY" : "SELL", lots, sl, tp,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//| Lot that risks exactly riskMoney over stopDist, capped by maxRiskMoney |
double LotForRisk(double stopDist, double riskMoney, double maxRiskMoney)
{
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickVal <= 0.0 || stopDist <= 0.0 || riskMoney <= 0.0) return(0.0);

   double lots = riskMoney / ((stopDist / tickSize) * tickVal);
   lots = NormalizeLots(lots);

   // guard the classic "rounds down to zero on a high priced symbol" trap
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minLot)
   {
      double minRisk = minLot * (stopDist / tickSize) * tickVal;
      if(minRisk > maxRiskMoney) return(0.0);   // even the min lot would blow the hard cap
      lots = minLot;
   }
   return(lots);
}

double NormalizeLots(double lots)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0.0) st = 0.01;
   lots = MathFloor(lots / st + 0.0000001) * st;
   lots = MathMax(mn, MathMin(mx, lots));
   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
//| Daily math + ladder replay                                        |
//+------------------------------------------------------------------+
void NewDayReset()
{
   g_curDay         = DayStart(TimeCurrent());
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_baseRiskMoney  = g_dayStartEquity * InpBaseRiskPct / 100.0;
   g_tradesToday    = 0;
   g_dayHalted      = false;
   g_lastWinId      = -1;
   g_windowOpen     = 0.0;
   if(g_ladderResetTime < g_curDay) g_ladderResetTime = g_curDay;

   PrintFormat("NEW DAY %s  start=%.2f  base risk=%.2f",
               TimeToString(g_curDay, TIME_DATE), g_dayStartEquity, g_baseRiskMoney);
}

//| Rebuilt from CLOSED DEALS each tick, not carried in a variable -    |
//| a restart mid-day replays today's history and lands on the same    |
//| step, so it can never forget a losing streak or double-count one.  |
//| g_ladderStep only counts deals closed at/after g_ladderResetTime,   |
//| so a drawdown-breaker trip truly resets the progression to base.    |
void UpdateLadderFromHistory()
{
   g_ladderStep        = 0;
   g_consecLossesToday = 0;
   g_dailyLossMoney    = 0.0;
   if(!HistorySelect(g_curDay, TimeCurrent() + 60)) return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)   // oldest first
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) continue;   // only closes

      double net = HistoryDealGetDouble(d, DEAL_PROFIT)
                 + HistoryDealGetDouble(d, DEAL_SWAP)
                 + HistoryDealGetDouble(d, DEAL_COMMISSION);
      datetime dt = (datetime)HistoryDealGetInteger(d, DEAL_TIME);

      if(net > 0.0)
      {
         g_consecLossesToday = 0;
         if(dt >= g_ladderResetTime) g_ladderStep = 0;
      }
      else
      {
         g_dailyLossMoney += MathAbs(net);
         g_consecLossesToday++;
         if(dt >= g_ladderResetTime) g_ladderStep++;
      }
   }
}

datetime DayStart(datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   d.hour = 0; d.min = 0; d.sec = 0;
   return(StructToTime(d));
}

//+------------------------------------------------------------------+
//| Small helpers                                                      |
//+------------------------------------------------------------------+
double ATR()
{
   if(g_atrHandle == INVALID_HANDLE) return(0.0);
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1) return(0.0);
   return(buf[0]);
}

bool InSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpSessionStartHour <= InpSessionEndHour)
      return(dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
   return(dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);   // overnight wrap
}

int PositionDirection()   // +1 long, -1 short, 0 flat (this EA's magic on this symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      return(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
   }
   return(0);
}

bool HasOpenPosition() { return(PositionDirection() != 0); }

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      trade.PositionClose(tk);
   }
   g_runnerActive = false;
   g_runnerPeak   = 0.0;
}

double StopLevelPrice()
{
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point);
}

void ShowPanel()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_peakEquity > 0.0) ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0.0;
   double nextRisk = MathMin(g_baseRiskMoney * MathPow(InpLossMultiplier, g_ladderStep),
                              equity * InpMaxRiskPct / 100.0);

   string runnerTxt = "off";
   if(InpAllowRunner)
      runnerTxt = g_runnerActive
                ? StringFormat("RUNNING - now %.2f, best %.2f, floor %.2f",
                               OpenProfitMoney(), g_runnerPeak,
                               g_runnerPeak * InpRunnerKeepPct / 100.0)
                : StringFormat("armed - needs %.2fR at the close (now %.2fR)",
                               InpRunnerMinR, OpenProfitR());

   Comment(StringFormat(
      "XAU Momentum-Into-Close EA\n"
      "-----------------------------------\n"
      "Day start equity  : %.2f\n"
      "Base risk / day    : %.2f\n"
      "Ladder step / next : %d / %.2f\n"
      "Trades today       : %d / %d\n"
      "Consec losses      : %d / %d\n"
      "Daily loss used     : %.2f / %.2f\n"
      "Drawdown vs peak    : %.1f%% / %.1f%%\n"
      "Runner              : %s\n"
      "Status              : %s",
      g_dayStartEquity, g_baseRiskMoney,
      g_ladderStep, nextRisk,
      g_tradesToday, InpMaxTradesPerDay,
      g_consecLossesToday, InpMaxConsecLosses,
      g_dailyLossMoney, g_dayStartEquity * DailyLimitPct() / 100.0,
      dd, InpMaxDrawdownPct,
      runnerTxt,
      g_dayHalted ? "DAILY HALT" : g_status
   ));
}

//| Optimiser score: profit factor * recovery factor, >= 30 trades      |
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 30) return(0.0);
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double rf = TesterStatistics(STAT_RECOVERY_FACTOR);
   if(pf <= 0.0 || rf <= 0.0) return(0.0);
   return(pf * rf);
}
//+------------------------------------------------------------------+
