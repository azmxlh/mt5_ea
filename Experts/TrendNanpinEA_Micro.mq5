//+------------------------------------------------------------------+
//| TrendNanpinEA_Micro.mq5 - Trend + Nanpin EA                     |
//| Patterns A~D Multi-concurrent operation support (Micro account)  |
//+------------------------------------------------------------------+
#property copyright "Trend Nanpin EA (Micro)"
#property version   "3.00"
#property strict
#include <Trade/Trade.mqh>

// --- Allowed Account List ---
#define ALLOWED_ACCOUNT_COUNT 1
const long g_allowedAccounts[ALLOWED_ACCOUNT_COUNT] = {370394526};

#define PAIR_COUNT     4
#define PATTERN_COUNT  4
#define MAX_PAIRS      (PATTERN_COUNT * PAIR_COUNT)  // Max 16 pairs

// Pattern-specific symbol definitions
const string g_patternSymbols[PATTERN_COUNT][PAIR_COUNT] = {
   {"USDJPYmicro", "GBPJPYmicro", "AUDJPYmicro", "EURAUDmicro"},  // A: Yen sell + Euro sell
   {"NZDJPYmicro", "CADJPYmicro", "CHFJPYmicro", "GBPAUDmicro"},  // B: Yen sell alt pairs + Pound buy
   {"EURUSDmicro", "GBPUSDmicro", "AUDUSDmicro", "USDCHFmicro"},  // C: Dollar buy focus
   {"EURJPYmicro", "USDJPYmicro", "GBPCHFmicro", "AUDNZDmicro"}   // D: High interest currency buy
};

// Pattern-specific swap directions
const int g_patternSwapDir[PATTERN_COUNT][PAIR_COUNT] = {
   { 1,  1,  1, -1},  // A: Buy, Buy, Buy, Sell
   { 1,  1,  1, -1},  // B: Buy, Buy, Buy, Sell
   {-1, -1, -1,  1},  // C: Sell, Sell, Sell, Buy
   { 1,  1,  1,  1}   // D: Buy, Buy, Buy, Buy
};

// Pattern names (for logging)
const string g_patternNames[PATTERN_COUNT] = {"A", "B", "C", "D"};

// --- Basic Settings ---
input int    Magic_Number       = 563718;
input double Lots               = 0.1;
input bool   SinglePairMode     = false;

// --- Pattern Enable/Disable (multiple simultaneous ON possible) ---
input bool   EnablePattern_A    = true;     // Pattern A (USDJPY,GBPJPY,AUDJPY,EURAUD)
input bool   EnablePattern_B    = true;    // Pattern B (NZDJPY,CADJPY,CHFJPY,GBPAUD)
input bool   EnablePattern_C    = true;    // Pattern C (EURUSD,GBPUSD,AUDUSD,USDCHF)
input bool   EnablePattern_D    = true;    // Pattern D (EURJPY,USDJPY,GBPCHF,AUDNZD)

// --- MA Settings ---
input int    MA_Period           = 100;
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H4;

// --- Nanpin Settings ---
input int    Nanpin_Pips         = 50;
input int    Max_Nanpin          = 0;      // 0=unlimited
input double Lot_Multiplier      = 1.0;

// --- Close Settings ---
input int    Profit_Pips         = 30;

// --- Risk Management ---
input double MaxSpread           = 5.0;
input int    TradingStartHour    = 0;
input int    TradingEndHour      = 0;

struct PairState {
   string   symbol;
   bool     enabled;
   bool     windingDown;     // true=pattern OFF, waiting for existing position close
   int      magicNumber;
   int      patternIndex;    // which pattern it belongs to (0=A,1=B,2=C,3=D)
   int      pairIndex;       // pair number within pattern (0-3)
   double   pip;
   int      digits;
   int      maHandle;
   int      swapDirection;   // +1=BUY, -1=SELL
   int      nanpinCount;
   double   lastEntryPrice;
   datetime lastBarTime;
};

PairState g_pairs[MAX_PAIRS];
CTrade    g_trade;
int       g_activePairCount;

//--- Get Pattern Enabled ---
bool IsPatternEnabled(int patIdx)
{
   switch(patIdx)
   {
      case 0: return EnablePattern_A;
      case 1: return EnablePattern_B;
      case 2: return EnablePattern_C;
      case 3: return EnablePattern_D;
   }
   return false;
}

//--- HasPositionsForMagic ---
// Check if position exists for specified magic & symbol
bool HasPositionsForMagic(int magic, string symbol)
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      return true;
   }
   return false;
}

//--- OnInit ---
int OnInit()
{
   // --- Account Number Check ---
   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   bool accountAllowed = false;
   for(int i = 0; i < ALLOWED_ACCOUNT_COUNT; i++)
   {
      if(accountNumber == g_allowedAccounts[i]) { accountAllowed = true; break; }
   }
   if(!accountAllowed)
   {
      PrintFormat("[TrendNanpin ERROR] This account(%d) is not allowed. Please run with an authorized account.", accountNumber);
      return(INIT_FAILED);
   }

   // Parameter validation
   if(Lots <= 0)
   { Print("[TrendNanpin ERROR] Lots must be a positive value"); return(INIT_PARAMETERS_INCORRECT); }
   if(Nanpin_Pips <= 0)
   { Print("[TrendNanpin ERROR] Nanpin_Pips must be a positive value"); return(INIT_PARAMETERS_INCORRECT); }
   if(Profit_Pips <= 0)
   { Print("[TrendNanpin ERROR] Profit_Pips must be a positive value"); return(INIT_PARAMETERS_INCORRECT); }
   if(Max_Nanpin < 0)
   { Print("[TrendNanpin ERROR] Max_Nanpin must be 0 or positive (0=unlimited)"); return(INIT_PARAMETERS_INCORRECT); }
   if(MA_Period <= 0)
   { Print("[TrendNanpin ERROR] MA_Period must be a positive value"); return(INIT_PARAMETERS_INCORRECT); }

   // At least one pattern must be valid (windingDown-only startup also allowed - check later)

   // Initialize pair settings (register pairs from enabled patterns in order)
   g_activePairCount = 0;

   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      bool patEnabled = IsPatternEnabled(pat);

      for(int p = 0; p < PAIR_COUNT; p++)
      {
         int magic = Magic_Number + pat * 10 + p;
         string sym = g_patternSymbols[pat][p];

         if(patEnabled)
         {
            // Enabled pattern: register normally
            int idx = g_activePairCount;
            g_pairs[idx].symbol         = sym;
            g_pairs[idx].enabled        = true;
            g_pairs[idx].windingDown    = false;
            g_pairs[idx].patternIndex   = pat;
            g_pairs[idx].pairIndex      = p;
            g_pairs[idx].magicNumber    = magic;
            g_pairs[idx].pip            = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
            g_pairs[idx].digits         = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
            g_pairs[idx].swapDirection  = g_patternSwapDir[pat][p];
            g_pairs[idx].maHandle       = INVALID_HANDLE;
            g_pairs[idx].nanpinCount    = 0;
            g_pairs[idx].lastEntryPrice = 0;
            g_pairs[idx].lastBarTime    = 0;
            g_activePairCount++;
         }
         else
         {
            // Disabled pattern: if existing positions exist, register as windingDown
            if(HasPositionsForMagic(magic, sym))
            {
               int idx = g_activePairCount;
               g_pairs[idx].symbol         = sym;
               g_pairs[idx].enabled        = true;
               g_pairs[idx].windingDown    = true;
               g_pairs[idx].patternIndex   = pat;
               g_pairs[idx].pairIndex      = p;
               g_pairs[idx].magicNumber    = magic;
               g_pairs[idx].pip            = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
               g_pairs[idx].digits         = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
               g_pairs[idx].swapDirection  = g_patternSwapDir[pat][p];
               g_pairs[idx].maHandle       = INVALID_HANDLE;
               g_pairs[idx].nanpinCount    = 0;
               g_pairs[idx].lastEntryPrice = 0;
               g_pairs[idx].lastBarTime    = 0;
               g_activePairCount++;
               PrintFormat("[TrendNanpin INFO][Pat%s][%s] Pattern OFF - Waiting for existing position close",
                          g_patternNames[pat], sym);
            }
         }
      }
   }

   // Error if no valid pair
   if(g_activePairCount == 0)
   { Print("[TrendNanpin ERROR] No valid pairs available (requires pattern ON or existing positions)"); return(INIT_PARAMETERS_INCORRECT); }

   // Single pair mode
   if(SinglePairMode)
   {
      string chartSymbol = _Symbol;
      int foundIdx = -1;
      for(int i = 0; i < g_activePairCount; i++)
      {
         if(g_pairs[i].symbol == chartSymbol) { foundIdx = i; break; }
      }
      if(foundIdx == -1)
      {
         PrintFormat("[TrendNanpin ERROR] Single pair mode: %s is not managed by enabled patterns", chartSymbol);
         return(INIT_FAILED);
      }
      // Copy found pair to first position and operate only 1 pair
      if(foundIdx != 0)
      {
         g_pairs[0].symbol        = g_pairs[foundIdx].symbol;
         g_pairs[0].enabled       = true;
         g_pairs[0].patternIndex  = g_pairs[foundIdx].patternIndex;
         g_pairs[0].pairIndex     = g_pairs[foundIdx].pairIndex;
         g_pairs[0].pip           = g_pairs[foundIdx].pip;
         g_pairs[0].digits        = g_pairs[foundIdx].digits;
         g_pairs[0].swapDirection = g_pairs[foundIdx].swapDirection;
      }
      g_pairs[0].magicNumber    = Magic_Number;
      g_pairs[0].windingDown    = false;
      g_pairs[0].maHandle       = INVALID_HANDLE;
      g_pairs[0].nanpinCount    = 0;
      g_pairs[0].lastEntryPrice = 0;
      g_pairs[0].lastBarTime    = 0;
      g_activePairCount = 1;
      PrintFormat("[TrendNanpin INFO] Single pair mode: Only %s operating (Pattern %s)",
                 chartSymbol, g_patternNames[g_pairs[0].patternIndex]);
   }
   else
   {
      // Symbol existence check & auto-add to Market Watch
      for(int i = 0; i < g_activePairCount; i++)
      {
         if(!g_pairs[i].enabled) continue;
         if(!SymbolInfoInteger(g_pairs[i].symbol, SYMBOL_EXIST))
         {
            PrintFormat("[TrendNanpin ERROR] Symbol unavailable: %s (Pattern %s)",
                       g_pairs[i].symbol, g_patternNames[g_pairs[i].patternIndex]);
            return(INIT_FAILED);
         }
         // Add to Market Watch
         if(!SymbolSelect(g_pairs[i].symbol, true))
         {
            PrintFormat("[TrendNanpin WARN][%s] Failed to add to Market Watch", g_pairs[i].symbol);
         }
      }
      PrintFormat("[TrendNanpin INFO] Multi-pair mode running: %d pairs", g_activePairCount);
   }

   // Create MA indicator handle + resolve swap direction
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      g_pairs[i].maHandle = iMA(g_pairs[i].symbol, MA_Timeframe, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].maHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendNanpin ERROR] MA creation failed: %s, err=%d", g_pairs[i].symbol, GetLastError());
         return(INIT_FAILED);
      }
      GetSwapDirection(i);
   }

   // Initialize CTrade
   g_trade.SetDeviationInPoints(10);

   // Restore nanpin state from existing positions
   RestoreStateFromPositions();

   // Startup log
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] Magic=%d, SwapDir=%s",
                 g_patternNames[g_pairs[i].patternIndex],
                 g_pairs[i].symbol, g_pairs[i].magicNumber,
                 (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
   }

   // Enabled patterns log
   string enabledPatterns = "";
   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      if(IsPatternEnabled(pat))
      {
         if(enabledPatterns != "") enabledPatterns += ",";
         enabledPatterns += g_patternNames[pat];
      }
   }
   PrintFormat("[TrendNanpin INFO] Initialization complete: Patterns=[%s], MA=%d(%s), Nanpin=%dpips, Max=%d, Profit=%dpips",
              enabledPatterns, MA_Period, EnumToString(MA_Timeframe), Nanpin_Pips, Max_Nanpin, Profit_Pips);
   return(INIT_SUCCEEDED);
}

//--- OnDeinit ---
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(g_pairs[i].maHandle != INVALID_HANDLE)
      {
         IndicatorRelease(g_pairs[i].maHandle);
         g_pairs[i].maHandle = INVALID_HANDLE;
      }
   }
   PrintFormat("[TrendNanpin INFO] EA stopped: reason=%d", reason);
}

//--- OnTick ---
void OnTick()
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      ProcessPair(i);
   }
}

//--- ProcessPair ---
void ProcessPair(int idx)
{
   CheckBatchClose(idx);

   // windingDown: Pattern OFF but waiting for existing position close
   if(g_pairs[idx].windingDown)
   {
      // Disable if all positions are gone
      if(CountPositions(idx) == 0)
      {
         g_pairs[idx].enabled = false;
         PrintFormat("[TrendNanpin INFO][Pat%s][%s] All positions closed - Stopped",
                    g_patternNames[g_pairs[idx].patternIndex], g_pairs[idx].symbol);
      }
      else
      {
         // Continue nanpin (assist in closing)
         if(IsNewBar(idx))
            CheckNanpin(idx);
      }
      return;
   }

   if(!IsNewBar(idx)) return;

   // Lot change detection: if existing positions exist, continue with previous lot
   int posCount = CountPositions(idx);
   double existingLot = GetExistingLot(idx);
   if(existingLot > 0)
   {
      // Existing position & lot mismatch → continue nanpin with previous lot, no new entry
      if(posCount > 0)
         CheckNanpinWithLot(idx, existingLot);
      return;
   }

   if(posCount == 0)
      CheckEntry(idx);
   else
      CheckNanpin(idx);
}

//--- IsLotMismatch ---
// Determine if existing position's initial lot differs from current Lots setting
// If different, return existing position's lot (for nanpin continuation)
// If matching or no positions, return 0
double GetExistingLot(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   datetime oldestTime = D'2099.01.01';
   double oldestLot = 0;
   bool hasPosition = false;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      hasPosition = true;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime < oldestTime)
      {
         oldestTime = openTime;
         oldestLot  = PositionGetDouble(POSITION_VOLUME);
      }
   }

   if(!hasPosition) return 0;

   // Compare first entry lot with current setting (considering floating point error)
   if(MathAbs(oldestLot - Lots) > 0.0001)
      return oldestLot;

   return 0;
}

//--- GetSwapDirection ---
void GetSwapDirection(int idx)
{
   if(g_pairs[idx].swapDirection == 1 || g_pairs[idx].swapDirection == -1)
      return;

   // Auto-detect
   string symbol = g_pairs[idx].symbol;
   double swapLong  = SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG);
   double swapShort = SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT);

   if(swapLong >= swapShort)
      g_pairs[idx].swapDirection = 1;
   else
      g_pairs[idx].swapDirection = -1;

   PrintFormat("[TrendNanpin INFO][%s] Swap auto-detected: Long=%.2f, Short=%.2f → %s",
              symbol, swapLong, swapShort,
              (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL");
}

//--- IsTrendAligned ---
bool IsTrendAligned(int idx)
{
   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   if(CopyBuffer(g_pairs[idx].maHandle, 0, 0, 1, maBuffer) <= 0)
   {
      PrintFormat("[TrendNanpin ERROR][%s] MA retrieval failed: err=%d", g_pairs[idx].symbol, GetLastError());
      return false;
   }

   double ma = maBuffer[0];
   string symbol = g_pairs[idx].symbol;
   double currentPrice = (SymbolInfoDouble(symbol, SYMBOL_ASK) + SymbolInfoDouble(symbol, SYMBOL_BID)) / 2.0;

   if(g_pairs[idx].swapDirection == 1)
      return (currentPrice > ma);
   else
      return (currentPrice < ma);
}

//--- IsNewBar ---
bool IsNewBar(int idx)
{
   datetime barTime = iTime(g_pairs[idx].symbol, MA_Timeframe, 0);
   if(barTime == 0) return false;
   if(barTime != g_pairs[idx].lastBarTime)
   {
      g_pairs[idx].lastBarTime = barTime;
      return true;
   }
   return false;
}

//--- CheckEntry ---
void CheckEntry(int idx)
{
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(Lots, symbol, 0, 0, 0, "TrendNanpin");
   else
      result = g_trade.Sell(Lots, symbol, 0, 0, 0, "TrendNanpin");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] First entry: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 Lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] Order failed: err=%d", symbol, GetLastError());
}

//--- CheckNanpin ---
void CheckNanpin(int idx)
{
   if(Max_Nanpin > 0 && g_pairs[idx].nanpinCount >= Max_Nanpin) return;
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   double lastPrice = g_pairs[idx].lastEntryPrice;

   // Unrealized loss check (distance from lastEntryPrice)
   bool nanpinTrigger = false;
   if(g_pairs[idx].swapDirection == 1)
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      nanpinTrigger = (lastPrice - currentAsk >= Nanpin_Pips * pip);
   }
   else
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      nanpinTrigger = (currentBid - lastPrice >= Nanpin_Pips * pip);
   }
   if(!nanpinTrigger) return;

   // Nanpin order
   double lots = CalcNanpinLots(g_pairs[idx].nanpinCount);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpin");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpin");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount++;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] Nanpin #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] Nanpin order failed: err=%d", symbol, GetLastError());
}

//--- CheckNanpinWithLot ---
// Continue nanpin based on previous lot when lot is changed
void CheckNanpinWithLot(int idx, double baseLot)
{
   if(Max_Nanpin > 0 && g_pairs[idx].nanpinCount >= Max_Nanpin) return;
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   double lastPrice = g_pairs[idx].lastEntryPrice;

   bool nanpinTrigger = false;
   if(g_pairs[idx].swapDirection == 1)
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      nanpinTrigger = (lastPrice - currentAsk >= Nanpin_Pips * pip);
   }
   else
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      nanpinTrigger = (currentBid - lastPrice >= Nanpin_Pips * pip);
   }
   if(!nanpinTrigger) return;

   // Calculate nanpin lot based on previous lot (+1 applies multiplier from first nanpin)
   double lots = baseLot * MathPow(Lot_Multiplier, g_pairs[idx].nanpinCount + 1);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpin");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpin");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount++;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] Nanpin(old lot) #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] Nanpin order failed: err=%d", symbol, GetLastError());
}

//--- CalcNanpinLots ---
double CalcNanpinLots(int count)
{
   // count=0 (first nanpin) applies multiplier from the start (+1 for first nanpin)
   return Lots * MathPow(Lot_Multiplier, count + 1);
}

//--- CalcAveragePrice ---
double CalcAveragePrice(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double totalLots = 0, totalWeighted = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      double posLots  = PositionGetDouble(POSITION_VOLUME);
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      totalLots     += posLots;
      totalWeighted += posPrice * posLots;
   }
   if(totalLots <= 0) return 0.0;
   return totalWeighted / totalLots;
}

//--- CheckBatchClose ---
void CheckBatchClose(int idx)
{
   if(CountPositions(idx) == 0) return;

   double avgPrice = CalcAveragePrice(idx);
   if(avgPrice <= 0) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   bool closeCondition = false;

   if(g_pairs[idx].swapDirection == 1)
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      closeCondition = (currentBid >= avgPrice + Profit_Pips * pip);
   }
   else
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      closeCondition = (currentAsk <= avgPrice - Profit_Pips * pip);
   }

   if(closeCondition)
      CloseAllPositions(idx);
}

//--- CloseAllPositions ---
void CloseAllPositions(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   int closed = 0;
   double totalProfit = 0;

   g_trade.SetExpertMagicNumber(magic);

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_trade.PositionClose(ticket))
         closed++;
      else
         PrintFormat("[TrendNanpin ERROR][%s] Close failed: ticket=%d, err=%d", symbol, ticket, GetLastError());
   }

   if(closed > 0)
   {
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = 0;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] Batch close: %d positions, Profit %.0f",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, closed, totalProfit);
   }
}

//--- RestoreStateFromPositions ---
void RestoreStateFromPositions()
{
   for(int idx = 0; idx < g_activePairCount; idx++)
   {
      if(!g_pairs[idx].enabled) continue;

      int magic = g_pairs[idx].magicNumber;
      string symbol = g_pairs[idx].symbol;
      int posCount = 0;
      double latestPrice = 0;
      datetime latestTime = 0;

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

         posCount++;
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime > latestTime)
         {
            latestTime  = openTime;
            latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }

      if(posCount > 0)
      {
         g_pairs[idx].nanpinCount    = posCount - 1;  // Exclude initial entry
         g_pairs[idx].lastEntryPrice = latestPrice;
         PrintFormat("[TrendNanpin INFO][Pat%s][%s] State restored: Positions=%d, Nanpin count=%d, Latest price=%s",
                    g_patternNames[g_pairs[idx].patternIndex],
                    symbol, posCount, g_pairs[idx].nanpinCount,
                    DoubleToString(latestPrice, g_pairs[idx].digits));
      }
   }
}

//--- CountPositions ---
int CountPositions(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   int count = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      count++;
   }
   return count;
}

//--- IsTradingHour ---
bool IsTradingHour()
{
   if(TradingStartHour == 0 && TradingEndHour == 0) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   if(TradingStartHour <= TradingEndHour)
      return (h >= TradingStartHour && h < TradingEndHour);
   else
      return (h >= TradingStartHour || h < TradingEndHour);
}

//--- IsSpreadOK ---
bool IsSpreadOK(int idx)
{
   if(MaxSpread <= 0) return true;

   double ask = SymbolInfoDouble(g_pairs[idx].symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_pairs[idx].symbol, SYMBOL_BID);
   double spreadPips = (ask - bid) / g_pairs[idx].pip;
   return (spreadPips <= MaxSpread);
}
