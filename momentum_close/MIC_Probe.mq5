//+------------------------------------------------------------------+
//| MIC_Probe.mq5 — does this terminal trade at all?                  |
//|                                                                  |
//| Deliberately stupid. No ATR, no threshold, no risk sizing, no     |
//| session, no spread guard, no daily governor. It buys 0.01 lots at |
//| the entry slot of every window and closes at the window boundary. |
//|                                                                  |
//| It exists to split one question in two:                          |
//|   - Probe takes trades  -> plumbing is fine, the filters in the   |
//|                            real EA are what reject everything.    |
//|   - Probe takes none    -> the problem is the terminal or the     |
//|                            data, not the strategy. The Journal    |
//|                            lines below say which.                 |
//|                                                                  |
//| Attach to XAUUSD M1, enable AutoTrading, run it, read the Journal.|
//+------------------------------------------------------------------+
#property copyright "trading-bot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

input int    InpWindowMin    = 5;      // Window length (minutes)
input int    InpEntryLeadMin = 2;      // Enter with N minutes left
input double InpLots         = 0.01;   // Fixed volume
input long   InpMagic        = 590199;

CTrade        trade;
CPositionInfo pos;

datetime lastBarTime = 0;
int      slots = 0, sent = 0, failed = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("PROBE init | %s %s | digits=%d minLot=%.2f maxLot=%.2f step=%.2f",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
   PrintFormat("PROBE      | equity=%.2f  free_margin=%.2f  trade_allowed=%s  expert_allowed=%s",
               AccountInfoDouble(ACCOUNT_EQUITY),
               AccountInfoDouble(ACCOUNT_MARGIN_FREE),
               (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)  ? "yes" : "NO",
               (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT)   ? "yes" : "NO");
   PrintFormat("PROBE      | terminal_trade_allowed=%s  bars_available=%d",
               (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "yes" : "NO",
               Bars(_Symbol, PERIOD_M1));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   PrintFormat("PROBE done | entry slots reached:%d  orders sent:%d  orders failed:%d", slots, sent, failed);
   if(slots == 0)
      Print("PROBE     | No entry slot was ever reached: no M1 bars, or the lead is unreachable on this timeframe.");
   else if(sent == 0)
      Print("PROBE     | Slots reached but no order succeeded — read the retcodes above.");
}

void OnTick()
{
   datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 == lastBarTime)
      return;
   lastBarTime = t0;

   datetime closedBar = iTime(_Symbol, PERIOD_M1, 1);
   if(closedBar == 0)
      return;

   long winSec   = (long)InpWindowMin * 60;
   int  minsLeft = InpWindowMin - (int)(((long)closedBar % winSec) / 60) - 1;

   if(minsLeft == 0)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
         if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
            trade.PositionClose(pos.Ticket(), 50);
      return;
   }

   if(minsLeft != InpEntryLeadMin)
      return;

   slots++;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagic)
         return;   // already in one

   // Direction is arbitrary — this measures whether an order can be placed,
   // not whether it should be.
   bool up = iClose(_Symbol, PERIOD_M1, 1) >= iOpen(_Symbol, PERIOD_M1, 1);
   bool ok = up ? trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0, "probe")
                : trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0, "probe");

   if(ok)
      sent++;
   else
   {
      failed++;
      if(failed <= 10)
         PrintFormat("PROBE fail | retcode=%d %s | lots=%.2f ask=%.2f bid=%.2f free_margin=%.2f",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription(), InpLots,
                     SymbolInfoDouble(_Symbol, SYMBOL_ASK),
                     SymbolInfoDouble(_Symbol, SYMBOL_BID),
                     AccountInfoDouble(ACCOUNT_MARGIN_FREE));
   }
}
