//+------------------------------------------------------------------+
//|                                         TrendGrid_Micro.mq5     |
//|        Trend-following Grid Trading EA (Micro account version)   |
//|                                                                  |
//| Design policy:                                                   |
//|   - Determine trend direction using 200-period MA                 |
//|   - Place orders only in trend direction (do not trade against)   |
//|   - Uptrend → Buy Limit (buy the dip)                             |
//|   - Downtrend → Sell Limit (sell the rally)                       |
//|   - Remove pending orders in the opposite direction when trend    |
//|     reverses                                                       |
//+------------------------------------------------------------------+
#property copyright "Trend Grid EA (Micro)"
#property link      ""
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>

// --- Allowed account list ---
#define ALLOWED_ACCOUNT_COUNT 1
const long g_allowedAccounts[ALLOWED_ACCOUNT_COUNT] = {370394526};

//+------------------------------------------------------------------+
//| Constants                                                         |
//+------------------------------------------------------------------+
#define PAIR_COUNT       3
#define THROTTLE_SEC     30

const string g_symbols[PAIR_COUNT] = {"AUDNZDmicro", "EURGBPmicro", "USDCADmicro"};

enum ENUM_TREND_DIR
{
   TREND_NONE = 0,
   TREND_UP   = 1,
   TREND_DOWN = -1
};

//+------------------------------------------------------------------+
//| Input parameters                                                  |
//+------------------------------------------------------------------+

// --- Basic settings ---
input int    Magic_Number          = 718463;    // Magic number
input double Lots                  = 0.1;      // Lot size
input bool   SinglePairMode        = false;    // Single pair mode (for testing)

// --- AUD/NZD settings ---
input bool   Enable_AUDNZD        = true;     // Enable AUDNZD

// --- EUR/GBP settings ---
input bool   Enable_EURGBP        = true;     // Enable EURGBP

// --- USD/CAD settings ---
input bool   Enable_USDCAD        = true;     // Enable USDCAD

// --- Grid settings ---
input int    Trap_Pips            = 20;       // Trap interval (pips)
input int    Profit_Pips          = 20;       // Take profit width (pips)
input int    GridLines            = 10;       // Number of orders to place

// --- Trend settings ---
input int    MA_Period            = 200;      // Moving average period
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H1; // MA timeframe

// --- Risk management ---
input double MaxSpread            = 5.0;      // Maximum spread (pips, 0 = unlimited)
input int    StopLoss_Pips        = 0;        // Stop loss (pips, 0 = none)
input int    TradingStartHour     = 0;        // Trading start hour (0 = 24h)
input int    TradingEndHour       = 0;        // Trading end hour (0 = 24h)

//+------------------------------------------------------------------+
//| Pair configuration structure                                     |
//+------------------------------------------------------------------+
struct PairConfig
{
   string         symbol;
   bool           enabled;
   int            magicNumber;
   double         pip;
   int            digits;
   int            maHandle;        // MA indicator handle
   ENUM_TREND_DIR lastTrend;       // Last trend direction
   datetime       lastManageTime;
};

//+------------------------------------------------------------------+
//| Global variables                                                  |
//+------------------------------------------------------------------+
PairConfig   g_pairs[PAIR_COUNT];
CTrade       g_trade;
int          g_activePairCount;
datetime     g_lastTPCheckTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Account number check ---
   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   bool accountAllowed = false;
   for(int i = 0; i < ALLOWED_ACCOUNT_COUNT; i++)
   {
      if(accountNumber == g_allowedAccounts[i]) { accountAllowed = true; break; }
   }
   if(!accountAllowed)
   {
      PrintFormat("[TrendGrid ERROR] This account (%d) is not allowed. Please run on an authorized account.", accountNumber);
      return(INIT_FAILED);
   }

   // --- Parameter validation ---
   if(Lots <= 0 || Trap_Pips <= 0 || Profit_Pips <= 0 || GridLines <= 0)
   {
      Print("[TrendGrid ERROR] Invalid parameters: Lots/Trap_Pips/Profit_Pips/GridLines must be positive");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxSpread < 0 || StopLoss_Pips < 0)
   {
      Print("[TrendGrid ERROR] Invalid parameters: MaxSpread/StopLoss_Pips must be >= 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(TradingStartHour < 0 || TradingStartHour > 23 || TradingEndHour < 0 || TradingEndHour > 23)
   {
      Print("[TrendGrid ERROR] Invalid parameters: TradingStartHour/TradingEndHour must be in range 0-23");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MA_Period <= 0)
   {
      Print("[TrendGrid ERROR] Invalid parameters: MA_Period must be positive");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Pair enable flags ---
   bool enableFlags[PAIR_COUNT];
   enableFlags[0] = Enable_AUDNZD;
   enableFlags[1] = Enable_EURGBP;
   enableFlags[2] = Enable_USDCAD;

   // --- Initialize pair settings ---
   for(int i = 0; i < PAIR_COUNT; i++)
   {
      g_pairs[i].symbol         = g_symbols[i];
      g_pairs[i].enabled        = enableFlags[i];
      g_pairs[i].magicNumber    = Magic_Number + i;
      g_pairs[i].pip            = SymbolInfoDouble(g_symbols[i], SYMBOL_POINT) * 10;
      g_pairs[i].digits         = (int)SymbolInfoInteger(g_symbols[i], SYMBOL_DIGITS);
      g_pairs[i].maHandle       = INVALID_HANDLE;
      g_pairs[i].lastTrend      = TREND_NONE;
      g_pairs[i].lastManageTime = 0;
   }

   // --- Single pair mode ---
   if(SinglePairMode)
   {
      string chartSymbol = _Symbol;
      int foundIdx = -1;
      for(int i = 0; i < PAIR_COUNT; i++)
      {
         if(g_symbols[i] == chartSymbol)
         {
            foundIdx = i;
            break;
         }
      }
      if(foundIdx == -1)
      {
         PrintFormat("[TrendGrid ERROR] Single pair mode: %s is not managed", chartSymbol);
         return(INIT_FAILED);
      }
      if(foundIdx != 0)
      {
         g_pairs[0].symbol         = g_pairs[foundIdx].symbol;
         g_pairs[0].enabled        = true;
         g_pairs[0].magicNumber    = g_pairs[foundIdx].magicNumber;
         g_pairs[0].pip            = g_pairs[foundIdx].pip;
         g_pairs[0].digits         = g_pairs[foundIdx].digits;
         g_pairs[0].maHandle       = INVALID_HANDLE;
         g_pairs[0].lastTrend      = TREND_NONE;
         g_pairs[0].lastManageTime = 0;
      }
      g_activePairCount = 1;
      PrintFormat("[TrendGrid INFO] Single pair mode: only %s is active", chartSymbol);
   }
   else
   {
      for(int i = 0; i < PAIR_COUNT; i++)
      {
         if(g_pairs[i].enabled && !SymbolInfoInteger(g_symbols[i], SYMBOL_EXIST))
         {
            PrintFormat("[TrendGrid ERROR] Symbol not available: %s", g_symbols[i]);
            return(INIT_FAILED);
         }
      }
      g_activePairCount = PAIR_COUNT;
      Print("[TrendGrid INFO] Multi-pair mode active");
   }

   // --- Create MA indicator handles ---
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      g_pairs[i].maHandle = iMA(g_pairs[i].symbol, MA_Timeframe, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].maHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendGrid ERROR] Failed to create MA: %s, err=%d", g_pairs[i].symbol, GetLastError());
         return(INIT_FAILED);
      }
   }

   // --- Initialize CTrade ---
   g_trade.SetDeviationInPoints(10);

   // --- Initialize time for TP detection ---
   g_lastTPCheckTime = TimeCurrent();

   PrintFormat("[TrendGrid INFO] Initialization complete: GridLines=%d, Trap=%dpips, TP=%dpips, MA=%d(%s)",
              GridLines, Trap_Pips, Profit_Pips, MA_Period, EnumToString(MA_Timeframe));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release MA handles
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(g_pairs[i].maHandle != INVALID_HANDLE)
      {
         IndicatorRelease(g_pairs[i].maHandle);
         g_pairs[i].maHandle = INVALID_HANDLE;
      }
   }

   if(reason == REASON_CHARTCHANGE || reason == REASON_PARAMETERS || reason == REASON_REMOVE)
   {
      DeleteAllPendingOrders();
   }
   PrintFormat("[TrendGrid INFO] EA stopped: reason=%d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      ProcessPair(i);
   }
}

//+------------------------------------------------------------------+
//| Main processing per pair                                         |
//+------------------------------------------------------------------+
void ProcessPair(int pairIdx)
{
   if(!IsTradingHour())
      return;

   if(!IsSpreadOK(pairIdx))
      return;

   DetectTPClosures(pairIdx);

   datetime now = TimeCurrent();
   if(now - g_pairs[pairIdx].lastManageTime >= THROTTLE_SEC)
   {
      ManageGrid(pairIdx);
      g_pairs[pairIdx].lastManageTime = now;
   }
}

//+------------------------------------------------------------------+
//| Get trend direction                                              |
//+------------------------------------------------------------------+
ENUM_TREND_DIR GetTrendDirection(int pairIdx)
{
   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);

   if(CopyBuffer(g_pairs[pairIdx].maHandle, 0, 0, 1, maBuffer) <= 0)
      return TREND_NONE;

   double ma = maBuffer[0];
   string symbol = g_pairs[pairIdx].symbol;
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;

   if(currentPrice > ma)
      return TREND_UP;
   if(currentPrice < ma)
      return TREND_DOWN;

   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| Determine trading hours                                          |
//+------------------------------------------------------------------+
bool IsTradingHour()
{
   if(TradingStartHour == 0 && TradingEndHour == 0)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   if(TradingStartHour <= TradingEndHour)
      return (h >= TradingStartHour && h < TradingEndHour);
   else
      return (h >= TradingStartHour || h < TradingEndHour);
}

//+------------------------------------------------------------------+
//| Spread filter                                                     |
//+------------------------------------------------------------------+
bool IsSpreadOK(int pairIdx)
{
   if(MaxSpread <= 0)
      return true;

   double ask = SymbolInfoDouble(g_pairs[pairIdx].symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_pairs[pairIdx].symbol, SYMBOL_BID);
   double spreadPips = (ask - bid) / g_pairs[pairIdx].pip;
   return (spreadPips <= MaxSpread);
}

//+------------------------------------------------------------------+
//| TP closure detection → re-order only when trend matches          |
//+------------------------------------------------------------------+
void DetectTPClosures(int pairIdx)
{
   datetime now = TimeCurrent();
   if(!HistorySelect(g_lastTPCheckTime, now))
      return;

   int totalDeals = HistoryDealsTotal();
   if(totalDeals == 0)
   {
      g_lastTPCheckTime = now;
      return;
   }

   int magic = g_pairs[pairIdx].magicNumber;
   string symbol = g_pairs[pairIdx].symbol;
   double pip = g_pairs[pairIdx].pip;
   int digits = g_pairs[pairIdx].digits;
   ENUM_TREND_DIR currentTrend = GetTrendDirection(pairIdx);

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != magic) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      long dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if(dealReason != DEAL_REASON_TP) continue;

      long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

      double reorderPrice = 0;
      ENUM_ORDER_TYPE reorderType = ORDER_TYPE_BUY_LIMIT;

      if(dealType == DEAL_TYPE_SELL)
      {
         // Sell position closed → re-order is Buy Limit
         reorderPrice = NormalizeDouble(dealPrice - Profit_Pips * pip, digits);
         reorderType  = ORDER_TYPE_BUY_LIMIT;

         // Do not re-order unless trend is up
         if(currentTrend != TREND_UP) continue;
      }
      else if(dealType == DEAL_TYPE_BUY)
      {
         // Buy position closed → re-order is Sell Limit
         reorderPrice = NormalizeDouble(dealPrice + Profit_Pips * pip, digits);
         reorderType  = ORDER_TYPE_SELL_LIMIT;

         // Do not re-order unless trend is down
         if(currentTrend != TREND_DOWN) continue;
      }
      else
         continue;

      // Check validity of re-order
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);

      bool canPlace = false;
      if(reorderType == ORDER_TYPE_SELL_LIMIT && reorderPrice > currentAsk)
         canPlace = true;
      if(reorderType == ORDER_TYPE_BUY_LIMIT && reorderPrice < currentBid)
         canPlace = true;

      if(canPlace)
      {
         PlaceOrder(pairIdx, reorderPrice, reorderType);
         PrintFormat("[TrendGrid INFO][%s] TP re-order: price=%s, type=%s",
                    symbol, DoubleToString(reorderPrice, digits), EnumToString(reorderType));
      }
   }

   g_lastTPCheckTime = now;
}

//+------------------------------------------------------------------+
//| Grid management: place orders only in trend direction             |
//+------------------------------------------------------------------+
void ManageGrid(int pairIdx)
{
   string symbol = g_pairs[pairIdx].symbol;
   double pip = g_pairs[pairIdx].pip;
   int digits = g_pairs[pairIdx].digits;
   double trapInterval = Trap_Pips * pip;

   double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double currentMid = (currentAsk + currentBid) / 2.0;

   // --- Trend determination ---
   ENUM_TREND_DIR trend = GetTrendDirection(pairIdx);
   if(trend == TREND_NONE)
      return;

   // --- Trend reversal detection ---
   if(g_pairs[pairIdx].lastTrend != TREND_NONE && g_pairs[pairIdx].lastTrend != trend)
   {
      PrintFormat("[TrendGrid INFO][%s] Trend reversal: %s → %s",
                 symbol,
                 (g_pairs[pairIdx].lastTrend == TREND_UP) ? "UP" : "DOWN",
                 (trend == TREND_UP) ? "UP" : "DOWN");
      // Delete pending orders in the opposite direction
      DeleteOppositeOrders(pairIdx, trend);
   }
   g_pairs[pairIdx].lastTrend = trend;

   // --- Collect prices of existing pending orders ---
   double existingPrices[];
   int existingCount = CollectExistingOrderPrices(pairIdx, existingPrices);

   // --- If there are already GridLines or more orders, don't place new ones ---
   if(existingCount >= GridLines)
   {
      // Only remove orders that are too far away
      double maxDistance = GridLines * 2 * trapInterval;
      RemoveDistantOrders(pairIdx, currentMid, maxDistance);
      return;
   }

   int placed = 0;
   int maxToPlace = GridLines - existingCount;  // only place the shortage

   if(trend == TREND_UP)
   {
      // --- Uptrend: place Buy Limit below current price ---
      for(int n = 1; n <= GridLines && placed < maxToPlace; n++)
      {
         double levelPrice = NormalizeDouble(currentBid - n * trapInterval, digits);

         if(levelPrice <= 0) continue;

         // Check whether an order already exists
         if(OrderExistsAtPrice(existingPrices, existingCount, levelPrice, symbol))
            continue;

         if(PlaceOrder(pairIdx, levelPrice, ORDER_TYPE_BUY_LIMIT))
            placed++;
      }
   }
   else if(trend == TREND_DOWN)
   {
      // --- Downtrend: place Sell Limit above current price ---
      for(int n = 1; n <= GridLines && placed < maxToPlace; n++)
      {
         double levelPrice = NormalizeDouble(currentAsk + n * trapInterval, digits);

         // Check whether an order already exists
         if(OrderExistsAtPrice(existingPrices, existingCount, levelPrice, symbol))
            continue;

         if(PlaceOrder(pairIdx, levelPrice, ORDER_TYPE_SELL_LIMIT))
            placed++;
      }
   }

   // --- Remove orders that are too far away (distance greater than GridLines*2*Trap from current price) ---
   double maxDistance = GridLines * 2 * trapInterval;
   RemoveDistantOrders(pairIdx, currentMid, maxDistance);

   if(placed > 0)
   {
      PrintFormat("[TrendGrid INFO][%s] Grid updated: %s placed %d orders",
                 symbol, (trend == TREND_UP) ? "BuyLimit" : "SellLimit", placed);
   }
}

//+------------------------------------------------------------------+
//| Delete pending orders in the opposite direction when trend reverses |
//+------------------------------------------------------------------+
void DeleteOppositeOrders(int pairIdx, ENUM_TREND_DIR newTrend)
{
   int magic = g_pairs[pairIdx].magicNumber;
   string symbol = g_pairs[pairIdx].symbol;
   int deleted = 0;

   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;

      long orderType = OrderGetInteger(ORDER_TYPE);

      // If new trend is UP → delete Sell Limit
      if(newTrend == TREND_UP && orderType == ORDER_TYPE_SELL_LIMIT)
      {
         g_trade.SetExpertMagicNumber(magic);
         if(g_trade.OrderDelete(ticket))
            deleted++;
      }
      // If new trend is DOWN → delete Buy Limit
      else if(newTrend == TREND_DOWN && orderType == ORDER_TYPE_BUY_LIMIT)
      {
         g_trade.SetExpertMagicNumber(magic);
         if(g_trade.OrderDelete(ticket))
            deleted++;
      }
   }

   if(deleted > 0)
   {
      PrintFormat("[TrendGrid INFO][%s] Opposite orders deleted: %d", symbol, deleted);
   }
}

//+------------------------------------------------------------------+
//| Collect existing pending order prices for the specified pair     |
//+------------------------------------------------------------------+
int CollectExistingOrderPrices(int pairIdx, double &prices[])
{
   int magic = g_pairs[pairIdx].magicNumber;
   string symbol = g_pairs[pairIdx].symbol;
   int count = 0;

   ArrayResize(prices, 0);

   int totalOrders = OrdersTotal();
   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;

      int newSize = count + 1;
      ArrayResize(prices, newSize);
      prices[count] = OrderGetDouble(ORDER_PRICE_OPEN);
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check whether an order already exists at the specified price     |
//+------------------------------------------------------------------+
bool OrderExistsAtPrice(double &prices[], int count, double targetPrice, string symbol)
{
   double tolerance = SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.5;
   for(int i = 0; i < count; i++)
   {
      if(MathAbs(prices[i] - targetPrice) < tolerance)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Remove distant pending orders                                    |
//+------------------------------------------------------------------+
void RemoveDistantOrders(int pairIdx, double currentMid, double maxDistance)
{
   int magic = g_pairs[pairIdx].magicNumber;
   string symbol = g_pairs[pairIdx].symbol;
   int removed = 0;

   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;

      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double distance = MathAbs(orderPrice - currentMid);

      if(distance > maxDistance)
      {
         g_trade.SetExpertMagicNumber(magic);
         if(g_trade.OrderDelete(ticket))
            removed++;
      }
   }

   if(removed > 0)
   {
      PrintFormat("[TrendGrid INFO][%s] Removed far orders: %d", symbol, removed);
   }
}

//+------------------------------------------------------------------+
//| Place a pending order                                             |
//+------------------------------------------------------------------+
bool PlaceOrder(int pairIdx, double price, ENUM_ORDER_TYPE type)
{
   string symbol = g_pairs[pairIdx].symbol;
   int digits = g_pairs[pairIdx].digits;
   double pip = g_pairs[pairIdx].pip;
   int magic = g_pairs[pairIdx].magicNumber;

   g_trade.SetExpertMagicNumber(magic);

   price = NormalizeDouble(price, digits);

   // --- TP calculation ---
   double tp = 0;
   if(type == ORDER_TYPE_BUY_LIMIT)
      tp = NormalizeDouble(price + Profit_Pips * pip, digits);
   else if(type == ORDER_TYPE_SELL_LIMIT)
      tp = NormalizeDouble(price - Profit_Pips * pip, digits);

   // --- SL calculation ---
   double sl = 0;
   if(StopLoss_Pips > 0)
   {
      if(type == ORDER_TYPE_BUY_LIMIT)
         sl = NormalizeDouble(price - StopLoss_Pips * pip, digits);
      else if(type == ORDER_TYPE_SELL_LIMIT)
         sl = NormalizeDouble(price + StopLoss_Pips * pip, digits);
   }

   // --- Send order ---
   bool result = false;
   if(type == ORDER_TYPE_BUY_LIMIT)
      result = g_trade.BuyLimit(Lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, "TrendGrid");
   else if(type == ORDER_TYPE_SELL_LIMIT)
      result = g_trade.SellLimit(Lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, "TrendGrid");

   if(!result)
   {
      PrintFormat("[TrendGrid ERROR][%s] Order failed: price=%s, type=%s, err=%d",
                 symbol, DoubleToString(price, digits), EnumToString(type), GetLastError());
   }

   return result;
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                         |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   int deleted = 0;
   for(int p = 0; p < g_activePairCount; p++)
   {
      if(!g_pairs[p].enabled) continue;

      int magic = g_pairs[p].magicNumber;
      string symbol = g_pairs[p].symbol;

      int totalOrders = OrdersTotal();
      for(int i = totalOrders - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
         if(OrderGetString(ORDER_SYMBOL) != symbol) continue;

         g_trade.SetExpertMagicNumber(magic);
         if(g_trade.OrderDelete(ticket))
            deleted++;
      }
   }
   if(deleted > 0)
      PrintFormat("[TrendGrid INFO] All pending orders deleted: %d", deleted);
}
//+------------------------------------------------------------------+
