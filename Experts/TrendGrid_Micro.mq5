//+------------------------------------------------------------------+
//|                                         TrendGrid_Micro.mq5     |
//|        トレンドフォロー・グリッドトレードEA（マイクロ口座版）   |
//|                                                                  |
//| 設計方針:                                                         |
//|   - 200期間MAでトレンド方向を判定                                  |
//|   - トレンド方向のみに注文を配置（逆張りしない）                    |
//|   - 上昇トレンド → Buy Limit（押し目買い）                         |
//|   - 下降トレンド → Sell Limit（戻り売り）                          |
//|   - トレンド転換時は逆方向のPending Orderを削除                    |
//+------------------------------------------------------------------+
#property copyright "Trend Grid EA (Micro)"
#property link      ""
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| 定数                                                              |
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
//| 入力パラメータ                                                     |
//+------------------------------------------------------------------+

// --- 基本設定 ---
input int    Magic_Number          = 12345;    // マジックナンバー
input double Lots                  = 0.1;      // ロット数
input bool   SinglePairMode        = false;    // シングルペアモード(テスト用)

// --- AUD/NZD設定 ---
input bool   Enable_AUDNZD        = true;     // AUDNZD 有効

// --- EUR/GBP設定 ---
input bool   Enable_EURGBP        = true;     // EURGBP 有効

// --- USD/CAD設定 ---
input bool   Enable_USDCAD        = true;     // USDCAD 有効

// --- グリッド設定 ---
input int    Trap_Pips            = 20;       // トラップ間隔(pips)
input int    Profit_Pips          = 20;       // 利確幅(pips)
input int    GridLines            = 10;       // 配置する注文数

// --- トレンド設定 ---
input int    MA_Period            = 200;      // 移動平均期間
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H1; // MA計算時間足

// --- リスク管理 ---
input double MaxSpread            = 5.0;      // 最大スプレッド(pips, 0=無制限)
input int    StopLoss_Pips        = 0;        // ストップロス(pips, 0=なし)
input int    TradingStartHour     = 0;        // 取引開始時間(0=24時間)
input int    TradingEndHour       = 0;        // 取引終了時間(0=24時間)

//+------------------------------------------------------------------+
//| ペア設定構造体                                                     |
//+------------------------------------------------------------------+
struct PairConfig
{
   string         symbol;
   bool           enabled;
   int            magicNumber;
   double         pip;
   int            digits;
   int            maHandle;        // MA indicator handle
   ENUM_TREND_DIR lastTrend;       // 前回のトレンド方向
   datetime       lastManageTime;
};

//+------------------------------------------------------------------+
//| グローバル変数                                                     |
//+------------------------------------------------------------------+
PairConfig   g_pairs[PAIR_COUNT];
CTrade       g_trade;
int          g_activePairCount;
datetime     g_lastTPCheckTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- パラメータ検証 ---
   if(Lots <= 0 || Trap_Pips <= 0 || Profit_Pips <= 0 || GridLines <= 0)
   {
      Print("[TrendGrid ERROR] パラメータ不正: Lots/Trap_Pips/Profit_Pips/GridLines は正の値が必要");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxSpread < 0 || StopLoss_Pips < 0)
   {
      Print("[TrendGrid ERROR] パラメータ不正: MaxSpread/StopLoss_Pips は0以上が必要");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(TradingStartHour < 0 || TradingStartHour > 23 || TradingEndHour < 0 || TradingEndHour > 23)
   {
      Print("[TrendGrid ERROR] パラメータ不正: TradingStartHour/TradingEndHour は0-23の範囲");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MA_Period <= 0)
   {
      Print("[TrendGrid ERROR] パラメータ不正: MA_Period は正の値が必要");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- ペア有効フラグ ---
   bool enableFlags[PAIR_COUNT];
   enableFlags[0] = Enable_AUDNZD;
   enableFlags[1] = Enable_EURGBP;
   enableFlags[2] = Enable_USDCAD;

   // --- ペア設定初期化 ---
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

   // --- シングルペアモード ---
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
         PrintFormat("[TrendGrid ERROR] シングルペアモード: %s は管理対象外", chartSymbol);
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
      PrintFormat("[TrendGrid INFO] シングルペアモード: %s のみ稼働", chartSymbol);
   }
   else
   {
      for(int i = 0; i < PAIR_COUNT; i++)
      {
         if(g_pairs[i].enabled && !SymbolInfoInteger(g_symbols[i], SYMBOL_EXIST))
         {
            PrintFormat("[TrendGrid ERROR] シンボル利用不可: %s", g_symbols[i]);
            return(INIT_FAILED);
         }
      }
      g_activePairCount = PAIR_COUNT;
      Print("[TrendGrid INFO] マルチペアモード稼働");
   }

   // --- MAインジケータハンドル作成 ---
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      g_pairs[i].maHandle = iMA(g_pairs[i].symbol, MA_Timeframe, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].maHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendGrid ERROR] MA作成失敗: %s, err=%d", g_pairs[i].symbol, GetLastError());
         return(INIT_FAILED);
      }
   }

   // --- CTrade初期化 ---
   g_trade.SetDeviationInPoints(10);

   // --- TP検知用時刻初期化 ---
   g_lastTPCheckTime = TimeCurrent();

   PrintFormat("[TrendGrid INFO] 初期化完了: GridLines=%d, Trap=%dpips, TP=%dpips, MA=%d(%s)",
              GridLines, Trap_Pips, Profit_Pips, MA_Period, EnumToString(MA_Timeframe));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // MAハンドル解放
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
   PrintFormat("[TrendGrid INFO] EA停止: reason=%d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
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
//| ペアごとのメイン処理                                               |
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
//| トレンド方向取得                                                   |
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
//| 取引時間判定                                                       |
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
//| スプレッドフィルター                                               |
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
//| TP決済検知 → トレンド方向一致時のみ再注文                          |
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
         // Buyポジション決済 → 再注文はBuy Limit
         reorderPrice = NormalizeDouble(dealPrice - Profit_Pips * pip, digits);
         reorderType  = ORDER_TYPE_BUY_LIMIT;

         // トレンドが上昇でなければ再注文しない
         if(currentTrend != TREND_UP) continue;
      }
      else if(dealType == DEAL_TYPE_BUY)
      {
         // Sellポジション決済 → 再注文はSell Limit
         reorderPrice = NormalizeDouble(dealPrice + Profit_Pips * pip, digits);
         reorderType  = ORDER_TYPE_SELL_LIMIT;

         // トレンドが下降でなければ再注文しない
         if(currentTrend != TREND_DOWN) continue;
      }
      else
         continue;

      // 再注文の有効性チェック
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
         PrintFormat("[TrendGrid INFO][%s] TP再注文: price=%s, type=%s",
                    symbol, DoubleToString(reorderPrice, digits), EnumToString(reorderType));
      }
   }

   g_lastTPCheckTime = now;
}

//+------------------------------------------------------------------+
//| グリッド管理: トレンド方向のみに注文を配置                         |
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

   // --- トレンド判定 ---
   ENUM_TREND_DIR trend = GetTrendDirection(pairIdx);
   if(trend == TREND_NONE)
      return;

   // --- トレンド転換検知 ---
   if(g_pairs[pairIdx].lastTrend != TREND_NONE && g_pairs[pairIdx].lastTrend != trend)
   {
      PrintFormat("[TrendGrid INFO][%s] トレンド転換: %s → %s",
                 symbol,
                 (g_pairs[pairIdx].lastTrend == TREND_UP) ? "UP" : "DOWN",
                 (trend == TREND_UP) ? "UP" : "DOWN");
      // 逆方向のPending Orderを削除
      DeleteOppositeOrders(pairIdx, trend);
   }
   g_pairs[pairIdx].lastTrend = trend;

   // --- 既存Pending Orderの価格を収集 ---
   double existingPrices[];
   int existingCount = CollectExistingOrderPrices(pairIdx, existingPrices);

   // --- 既にGridLines本以上の注文がある場合は新規配置しない ---
   if(existingCount >= GridLines)
   {
      // 遠すぎる注文の削除のみ実行
      double maxDistance = GridLines * 2 * trapInterval;
      RemoveDistantOrders(pairIdx, currentMid, maxDistance);
      return;
   }

   int placed = 0;
   int maxToPlace = GridLines - existingCount;  // 不足分のみ配置

   if(trend == TREND_UP)
   {
      // --- 上昇トレンド: Buy Limit を現在価格の下に配置 ---
      for(int n = 1; n <= GridLines && placed < maxToPlace; n++)
      {
         double levelPrice = NormalizeDouble(currentBid - n * trapInterval, digits);

         if(levelPrice <= 0) continue;

         // 既に注文が存在するか確認
         if(OrderExistsAtPrice(existingPrices, existingCount, levelPrice, symbol))
            continue;

         if(PlaceOrder(pairIdx, levelPrice, ORDER_TYPE_BUY_LIMIT))
            placed++;
      }
   }
   else if(trend == TREND_DOWN)
   {
      // --- 下降トレンド: Sell Limit を現在価格の上に配置 ---
      for(int n = 1; n <= GridLines && placed < maxToPlace; n++)
      {
         double levelPrice = NormalizeDouble(currentAsk + n * trapInterval, digits);

         // 既に注文が存在するか確認
         if(OrderExistsAtPrice(existingPrices, existingCount, levelPrice, symbol))
            continue;

         if(PlaceOrder(pairIdx, levelPrice, ORDER_TYPE_SELL_LIMIT))
            placed++;
      }
   }

   // --- 遠すぎる注文の削除（現在価格からGridLines*2*Trap以上離れたもの） ---
   double maxDistance = GridLines * 2 * trapInterval;
   RemoveDistantOrders(pairIdx, currentMid, maxDistance);

   if(placed > 0)
   {
      PrintFormat("[TrendGrid INFO][%s] グリッド更新: %s %d本配置",
                 symbol, (trend == TREND_UP) ? "BuyLimit" : "SellLimit", placed);
   }
}

//+------------------------------------------------------------------+
//| トレンド転換時に逆方向のPending Orderを削除                        |
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

      // 新トレンドがUP → Sell Limitを削除
      if(newTrend == TREND_UP && orderType == ORDER_TYPE_SELL_LIMIT)
      {
         g_trade.SetExpertMagicNumber(magic);
         if(g_trade.OrderDelete(ticket))
            deleted++;
      }
      // 新トレンドがDOWN → Buy Limitを削除
      else if(newTrend == TREND_DOWN && orderType == ORDER_TYPE_BUY_LIMIT)
      {
         g_trade.SetExpertMagicNumber(magic);
         if(g_trade.OrderDelete(ticket))
            deleted++;
      }
   }

   if(deleted > 0)
   {
      PrintFormat("[TrendGrid INFO][%s] 逆方向注文削除: %d本", symbol, deleted);
   }
}

//+------------------------------------------------------------------+
//| 指定ペアの既存Pending Order価格を収集                              |
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
//| 指定価格に既に注文が存在するか確認                                 |
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
//| 遠すぎるPending Orderを削除                                       |
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
      PrintFormat("[TrendGrid INFO][%s] 遠方注文削除: %d本", symbol, removed);
   }
}

//+------------------------------------------------------------------+
//| Pending Order配置                                                  |
//+------------------------------------------------------------------+
bool PlaceOrder(int pairIdx, double price, ENUM_ORDER_TYPE type)
{
   string symbol = g_pairs[pairIdx].symbol;
   int digits = g_pairs[pairIdx].digits;
   double pip = g_pairs[pairIdx].pip;
   int magic = g_pairs[pairIdx].magicNumber;

   g_trade.SetExpertMagicNumber(magic);

   price = NormalizeDouble(price, digits);

   // --- TP計算 ---
   double tp = 0;
   if(type == ORDER_TYPE_BUY_LIMIT)
      tp = NormalizeDouble(price + Profit_Pips * pip, digits);
   else if(type == ORDER_TYPE_SELL_LIMIT)
      tp = NormalizeDouble(price - Profit_Pips * pip, digits);

   // --- SL計算 ---
   double sl = 0;
   if(StopLoss_Pips > 0)
   {
      if(type == ORDER_TYPE_BUY_LIMIT)
         sl = NormalizeDouble(price - StopLoss_Pips * pip, digits);
      else if(type == ORDER_TYPE_SELL_LIMIT)
         sl = NormalizeDouble(price + StopLoss_Pips * pip, digits);
   }

   // --- 注文送信 ---
   bool result = false;
   if(type == ORDER_TYPE_BUY_LIMIT)
      result = g_trade.BuyLimit(Lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, "TrendGrid");
   else if(type == ORDER_TYPE_SELL_LIMIT)
      result = g_trade.SellLimit(Lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, "TrendGrid");

   if(!result)
   {
      PrintFormat("[TrendGrid ERROR][%s] 注文失敗: price=%s, type=%s, err=%d",
                 symbol, DoubleToString(price, digits), EnumToString(type), GetLastError());
   }

   return result;
}

//+------------------------------------------------------------------+
//| 全Pending Order削除                                               |
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
      PrintFormat("[TrendGrid INFO] Pending Order全削除: %d本", deleted);
}
//+------------------------------------------------------------------+
