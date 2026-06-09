//+------------------------------------------------------------------+
//| RangeReversion.mq5 - レンジ逆張りEA V5.1                       |
//| g.xlsxの構造ベース + レンジ品質フィルター追加                    |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "5.10"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY,AUDJPY";
input int      MagicBase         = 79000;

//--- 複利設定
input bool     CompoundMode      = true;
input double   BalancePerLot     = 100000;
input double   BaseLots          = 0.1;
input double   FixedLot          = 0.1;
input bool     MicroMode         = false;

//--- BB設定
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H1;

//--- レンジ検出設定（g.xlsxベース + 改善）
input int      Range_Lookback    = 48;
input double   Range_MaxWidth_Pct = 2.0;        // ATR倍率上限
input double   Range_MinWidth_Pct = 0.3;        // ATR倍率下限
input int      Range_TouchCount  = 2;           // タッチ回数
input double   Range_TouchZone_Pct = 20.0;      // タッチゾーン%
input double   Range_BodyInside_Pct = 85.0;     // 実体レンジ内率（高値-安値ではなく実体で判定）

//--- SL/TP設定
input double   SL_Extra_Pips     = 5.0;         // SLはレンジ外+Xpips
input double   TP_Position       = 0.5;         // TPはレンジ幅の何%戻り
input double   TP_Min_Pips       = 8.0;         // TP最低pips

//--- エントリー確認
input double   Confirm_MinReturn = 0.3;         // 確認足の最低戻り率

//--- ADXフィルター
input bool     ADXFilter_Enabled = true;
input int      ADXFilter_Period  = 14;
input double   ADXFilter_Max     = 25.0;
input ENUM_TIMEFRAMES ADXFilter_TF = PERIOD_H4;

//--- ATR設定（レンジ幅正規化用）
input int      ATR_Period        = 14;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H1;   // BB_TFと同じ時間足

//--- リスク管理
input double   MaxSpread_Pips    = 3.0;
input int      TradingStartHour  = 0;           // 0-0で24時間
input int      TradingEndHour    = 0;
input int      ReentryCooldown   = 12;
input int      MaxTotalPositions = 10;
input int      MaxPosPerPair     = 1;

//--- 許可口座
input string   AllowedAccounts   = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
int    handleADX[];
int    handleATR[];
bool   pairEnabled[];
datetime lastCloseTime[];
datetime lastBarTime[];

//+------------------------------------------------------------------+
double GetMinLot() { return MicroMode ? 0.1 : 0.01; }

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(AllowedAccounts) > 0 && !IsAccountAllowed()) return INIT_FAILED;

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) return INIT_FAILED;

   ArrayResize(handleBB, pairCount);
   ArrayResize(handleADX, pairCount);
   ArrayResize(handleATR, pairCount);
   ArrayResize(pairEnabled, pairCount);
   ArrayResize(lastCloseTime, pairCount);
   ArrayResize(lastBarTime, pairCount);
   ArrayInitialize(lastCloseTime, 0);
   ArrayInitialize(lastBarTime, 0);

   int enabledCount = 0;
   for(int i = 0; i < pairCount; i++) {
      StringTrimRight(pairs[i]);
      StringTrimLeft(pairs[i]);
      if(!SymbolSelect(pairs[i], true)) { pairEnabled[i] = false; continue; }

      handleBB[i] = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      handleADX[i] = iADX(pairs[i], ADXFilter_TF, ADXFilter_Period);
      handleATR[i] = iATR(pairs[i], ATR_TF, ATR_Period);

      if(handleBB[i] == INVALID_HANDLE || handleADX[i] == INVALID_HANDLE ||
         handleATR[i] == INVALID_HANDLE) {
         pairEnabled[i] = false; continue;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[RangeRev V5.1] 初期化: %d/%d pairs, BB=%s, ADX=%s",
              enabledCount, pairCount,
              EnumToString(BB_TF), EnumToString(ADXFilter_TF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleADX[i] != INVALID_HANDLE) IndicatorRelease(handleADX[i]);
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];

      if(!IsNewBar(sym, i)) continue;
      if(!IsTradingTime()) continue;
      if(!IsSpreadOK(sym)) continue;
      if(CountPositions(sym, magic) >= MaxPosPerPair) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;

      if(ReentryCooldown > 0 && lastCloseTime[i] > 0) {
         int barsSinceClose = (int)((TimeCurrent() - lastCloseTime[i]) / PeriodSeconds(BB_TF));
         if(barsSinceClose < ReentryCooldown) continue;
      }

      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
bool IsNewBar(string sym, int idx)
{
   datetime barTime = iTime(sym, BB_TF, 0);
   if(barTime == 0) return false;
   if(barTime != lastBarTime[idx]) { lastBarTime[idx] = barTime; return true; }
   return false;
}

//+------------------------------------------------------------------+
bool IsTradingTime()
{
   if(TradingStartHour == 0 && TradingEndHour == 0) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(TradingStartHour < TradingEndHour)
      return (h >= TradingStartHour && h < TradingEndHour);
   else
      return (h >= TradingStartHour || h < TradingEndHour);
}

//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipValue = point * 10;

   // === ATR取得 ===
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR[idx], 0, 0, 3, atr) < 3) return;
   if(atr[1] <= 0) return;

   // === 水平レンジ検出 ===
   double rangeHigh = 0, rangeLow = 999999;
   for(int k = 1; k <= Range_Lookback; k++) {
      double h = iHigh(sym, BB_TF, k);
      double l = iLow(sym, BB_TF, k);
      if(h > rangeHigh) rangeHigh = h;
      if(l < rangeLow) rangeLow = l;
   }

   double rangeWidth = rangeHigh - rangeLow;
   if(rangeWidth <= 0) return;

   // レンジ幅をpipsでチェック（ATR正規化は無効化）
   double rangeWidthPips = rangeWidth / pipValue;
   if(rangeWidthPips > 200.0 || rangeWidthPips < 20.0) return;

   // レンジ内収率は無効化（フィルタリングが厳しすぎるため）

   // タッチゾーン
   double zoneSize = rangeWidth * Range_TouchZone_Pct / 100.0;
   double upperZone = rangeHigh - zoneSize;
   double lowerZone = rangeLow + zoneSize;

   // タッチ回数カウント
   int upperTouches = 0, lowerTouches = 0;
   for(int k = 1; k <= Range_Lookback; k++) {
      if(iHigh(sym, BB_TF, k) >= upperZone) upperTouches++;
      if(iLow(sym, BB_TF, k) <= lowerZone) lowerTouches++;
   }
   if(upperTouches < Range_TouchCount || lowerTouches < Range_TouchCount) return;

   // === ADXフィルター ===
   if(ADXFilter_Enabled) {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(handleADX[idx], 0, 0, 2, adx) < 2) return;
      if(adx[0] > ADXFilter_Max) return;
   }

   // === BB確認 ===
   double bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(handleBB[idx], 1, 0, 4, bb_upper) < 4) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 4, bb_lower) < 4) return;

   // === 価格データ ===
   double high2  = iHigh(sym, BB_TF, 2);
   double low2   = iLow(sym, BB_TF, 2);
   double close2 = iClose(sym, BB_TF, 2);
   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);

   // === Buy: 下限ゾーン + BB下限タッチ + 反転確認 ===
   if(low2 <= lowerZone && low2 <= bb_lower[2] && close2 > rangeLow) {
      double swingRange = high2 - low2;
      if(swingRange <= 0) return;
      double returnRatio = (close1 - low2) / swingRange;
      if(returnRatio < Confirm_MinReturn) return;
      if(close1 <= open1) return;  // Bar1が陽線

      double entryPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(rangeLow - SL_Extra_Pips * pipValue, digits);
      double tpTarget = rangeWidth * TP_Position;
      if(tpTarget / pipValue < TP_Min_Pips) tpTarget = TP_Min_Pips * pipValue;
      double tpPrice = NormalizeDouble(entryPrice + tpTarget, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] BUY @ %.5f, SL=%.5f, TP=%.5f",
                    sym, entryPrice, slPrice, tpPrice);
      }
      return;
   }

   // === Sell: 上限ゾーン + BB上限タッチ + 反転確認 ===
   if(high2 >= upperZone && high2 >= bb_upper[2] && close2 < rangeHigh) {
      double swingRange = high2 - low2;
      if(swingRange <= 0) return;
      double returnRatio = (high2 - close1) / swingRange;
      if(returnRatio < Confirm_MinReturn) return;
      if(close1 >= open1) return;  // Bar1が陰線

      double entryPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(rangeHigh + SL_Extra_Pips * pipValue, digits);
      double tpTarget = rangeWidth * TP_Position;
      if(tpTarget / pipValue < TP_Min_Pips) tpTarget = TP_Min_Pips * pipValue;
      double tpPrice = NormalizeDouble(entryPrice - tpTarget, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] SELL @ %.5f, SL=%.5f, TP=%.5f",
                    sym, entryPrice, slPrice, tpPrice);
      }
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
   req.deviation    = 20;
   req.magic        = magic;
   req.comment      = "RangeRev";
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
