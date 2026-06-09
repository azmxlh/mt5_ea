//+------------------------------------------------------------------+
//| MorningScalp.mq5 - 朝スキャルピングEA（MT5マルチペア版）        |
//| 日本時間早朝のレンジ相場でRSI逆張り                              |
//| 参考: OANDA 朝スキャEA                                           |
//+------------------------------------------------------------------+
#property copyright "MorningScalp EA"
#property version   "1.00"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,GBPJPY,EURJPY,AUDJPY";
input int      MagicBase         = 80000;

//--- ロット設定
input bool     CompoundMode      = true;
input double   BalancePerLot     = 100000;
input double   BaseLots          = 0.1;
input double   FixedLot          = 0.1;
input bool     MicroMode         = false;

//--- RSI設定
input int      RSIPeriod         = 6;
input ENUM_APPLIED_PRICE RSIPrice = PRICE_CLOSE;
input int      RSI_UpperLine     = 80;          // RSI上限（売りシグナル）
input int      RSI_LowerLine     = 20;          // RSI下限（買いシグナル）
input ENUM_TIMEFRAMES RSI_TF     = PERIOD_M5;   // RSI計算時間足

//--- TP/SL設定（pips）
input double   TakeProfit_Pips   = 15.0;
input double   LossCut_Pips      = 15.0;

//--- 取引時間設定（サーバー時間）
input int      TradeStartHour    = 21;          // 取引開始時間（XMサーバー時間 21=日本時間4時頃）
input int      TradeEndHour      = 1;           // 取引終了時間（XMサーバー時間 1=日本時間8時頃）

//--- リスク管理
input double   MaxSpread_Pips    = 3.0;
input int      MaxPosPerPair     = 1;
input int      MaxTotalPositions = 7;

//--- 連敗制限
input bool     UseLossLimit      = false;        // 1日あたり連敗制限を使用
input int      MaxLossPerPairDay = 2;            // 1ペア1日あたりの最大負け回数

//--- 許可口座
input string   AllowedAccounts   = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleRSI[];
bool   pairEnabled[];
int    dailyLossCount[];  // ペアごとの当日負け回数
int    lastLossDay[];     // 最後にリセットした日

//+------------------------------------------------------------------+
double GetMinLot() { return MicroMode ? 0.1 : 0.01; }

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(AllowedAccounts) > 0 && !IsAccountAllowed()) return INIT_FAILED;

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) return INIT_FAILED;

   ArrayResize(handleRSI, pairCount);
   ArrayResize(pairEnabled, pairCount);
   ArrayResize(dailyLossCount, pairCount);
   ArrayResize(lastLossDay, pairCount);

   int enabledCount = 0;
   for(int i = 0; i < pairCount; i++) {
      StringTrimRight(pairs[i]);
      StringTrimLeft(pairs[i]);
      dailyLossCount[i] = 0;
      lastLossDay[i] = 0;
      if(!SymbolSelect(pairs[i], true)) { pairEnabled[i] = false; continue; }

      handleRSI[i] = iRSI(pairs[i], RSI_TF, RSIPeriod, RSIPrice);
      if(handleRSI[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[MorningScalp] 初期化: %d/%d pairs, RSI(%d), TF=%s, Time=%d-%d",
              enabledCount, pairCount, RSIPeriod,
              EnumToString(RSI_TF), TradeStartHour, TradeEndHour);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++)
      if(handleRSI[i] != INVALID_HANDLE) IndicatorRelease(handleRSI[i]);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 取引時間チェック
   if(!IsTradingTime()) return;

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];

      if(!IsSpreadOK(sym)) continue;
      if(CountPositions(sym, magic) >= MaxPosPerPair) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;
      if(UseLossLimit && IsDailyLossLimitHit(i)) continue;

      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   if(TradeStartHour < TradeEndHour)
      return (h >= TradeStartHour && h < TradeEndHour);
   else
      return (h >= TradeStartHour || h < TradeEndHour);
}

//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipValue = point * 10;

   // RSI取得（1本前の確定足）
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleRSI[idx], 0, 1, 1, rsi) < 1) return;

   double currentRSI = rsi[0];

   // === Buy: RSIが下限以下 ===
   if(currentRSI < RSI_LowerLine) {
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(ask - LossCut_Pips * pipValue, digits);
      double tpPrice = NormalizeDouble(ask + TakeProfit_Pips * pipValue, digits);

      double lot = CalcLot(sym);
      OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice);
      return;
   }

   // === Sell: RSIが上限以上 ===
   if(currentRSI > RSI_UpperLine) {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(bid + LossCut_Pips * pipValue, digits);
      double tpPrice = NormalizeDouble(bid - TakeProfit_Pips * pipValue, digits);

      double lot = CalcLot(sym);
      OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice);
      return;
   }
}

//+------------------------------------------------------------------+
double CalcLot(string sym)
{
   if(!CompoundMode) return FixedLot;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot = (balance / BalancePerLot) * BaseLots;
   double minLot = GetMinLot();
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / stepLot) * stepLot;
   return MathMin(MathMax(lot, minLot), maxLot);
}

//+------------------------------------------------------------------+
bool OpenOrder(string sym, ENUM_ORDER_TYPE type, double lot, int magic, double sl, double tp)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = lot;
   req.type         = type;
   req.price        = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   req.sl           = NormalizeDouble(sl, digits);
   req.tp           = NormalizeDouble(tp, digits);
   req.deviation    = 10;
   req.magic        = magic;
   req.comment      = "MornScalp";
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         if(!OrderSend(req, res)) return false;
      } else return false;
   }
   return true;
}

//+------------------------------------------------------------------+
int CountPositions(string sym, int magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int CountAllPositions()
{
   int count = 0;
   int magicMax = MagicBase + pairCount - 1;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg < MagicBase || mg > magicMax) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool IsSpreadOK(string sym)
{
   if(MaxSpread_Pips <= 0) return true;
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   return ((ask - bid) / (point * 10) <= MaxSpread_Pips);
}

//+------------------------------------------------------------------+
bool IsAccountAllowed()
{
   string accounts[];
   int cnt = StringSplit(AllowedAccounts, ',', accounts);
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   for(int i = 0; i < cnt; i++)
      if(StringToInteger(accounts[i]) == login) return true;
   return false;
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode(string sym)
{
   long fillMode = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   if(fillMode == 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
// 1日あたりの負け回数を確認・更新
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit(int idx)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int today = dt.day_of_year;

   // 日付が変わったらリセット
   if(lastLossDay[idx] != today) {
      dailyLossCount[idx] = 0;
      lastLossDay[idx] = today;
      // 当日の負け回数を履歴から数える
      CountTodayLosses(idx, today);
   }

   return (dailyLossCount[idx] >= MaxLossPerPairDay);
}

//+------------------------------------------------------------------+
// 当日の負けトレードを履歴から数える
//+------------------------------------------------------------------+
void CountTodayLosses(int idx, int todayDOY)
{
   int magic = MagicBase + idx;
   string sym = pairs[idx];
   datetime dayStart = TimeCurrent() - (datetime)(TimeCurrent() % 86400);

   HistorySelect(dayStart, TimeCurrent());
   int total = HistoryDealsTotal();
   int losses = 0;

   for(int i = 0; i < total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != sym) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) losses++;
   }
   dailyLossCount[idx] = losses;
}
//+------------------------------------------------------------------+
