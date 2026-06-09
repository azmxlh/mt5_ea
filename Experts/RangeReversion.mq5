//+------------------------------------------------------------------+
//| RangeReversion.mq5 - レンジ逆張りEA V5                         |
//| 高品質レンジ検出 + 複合フィルターで逆張り精度を向上             |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "5.00"
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

//--- レンジ検出設定
input int      Range_Lookback    = 48;          // レンジ判定バー数
input double   Range_MaxWidth_Pct = 1.5;        // レンジ幅上限(ATR倍率) ← 2.0→1.5に厳格化
input double   Range_MinWidth_Pct = 0.4;        // レンジ幅下限(ATR倍率) ← 0.3→0.4に
input int      Range_TouchCount  = 3;           // 上下端タッチ最低回数 ← 2→3に厳格化
input double   Range_TouchZone_Pct = 15.0;      // タッチゾーン(レンジ幅の%) ← 20→15に
input double   Range_BodyInside_Pct = 75.0;     // レンジ内に収まるバーの割合(%)

//--- SL/TP設定
input double   SL_Extra_Pips     = 8.0;         // SLはレンジ外+Xpips ← 5→8に余裕
input double   TP_Position       = 0.4;         // TPはレンジ幅の何%戻り(0.5=中央) ← 0.5→0.4に控えめ
input double   TP_Min_Pips       = 10.0;        // TP最低pips

//--- エントリー確認
input double   Confirm_MinReturn = 0.4;         // 確認足の最低戻り率 ← 0.3→0.4に
input bool     Confirm_DoubleBar = true;        // 2本連続反転確認

//--- ADXフィルター
input bool     ADXFilter_Enabled = true;
input int      ADXFilter_Period  = 14;
input double   ADXFilter_Max     = 22.0;        // ADX閾値 ← 25→22に厳格化
input ENUM_TIMEFRAMES ADXFilter_TF = PERIOD_H4;

//--- MAフィルター（トレンド方向）
input bool     MAFilter_Enabled  = true;
input int      MAFilter_Period   = 50;
input double   MAFilter_FlatPips = 5.0;         // MA傾きが平坦とみなすpips幅
input ENUM_TIMEFRAMES MAFilter_TF = PERIOD_H4;

//--- ATR設定（レンジ幅正規化用）
input int      ATR_Period        = 14;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H4;

//--- スプレッド・リスク管理
input double   MaxSpread_Pips    = 3.0;
input int      TradingStartHour  = 1;           // 取引開始時間(サーバー時間)
input int      TradingEndHour    = 20;          // 取引終了時間(サーバー時間)
input int      ReentryCooldown   = 12;          // 決済後の再エントリー抑制(バー数)
input int      MaxTotalPositions = 8;
input int      MaxPosPerPair     = 1;

//--- 許可口座
input string   AllowedAccounts   = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
int    handleADX[];
int    handleMA[];
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
   ArrayResize(handleMA, pairCount);
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
      handleMA[i] = iMA(pairs[i], MAFilter_TF, MAFilter_Period, 0, MODE_SMA, PRICE_CLOSE);
      handleATR[i] = iATR(pairs[i], ATR_TF, ATR_Period);

      if(handleBB[i] == INVALID_HANDLE || handleADX[i] == INVALID_HANDLE ||
         handleMA[i] == INVALID_HANDLE || handleATR[i] == INVALID_HANDLE) {
         pairEnabled[i] = false; continue;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[RangeRev V5] 初期化: %d/%d pairs, BB=%s, ADX=%s",
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
      if(handleMA[i] != INVALID_HANDLE) IndicatorRelease(handleMA[i]);
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

      // 時間フィルター
      if(!IsTradingTime()) continue;

      if(!IsSpreadOK(sym)) continue;
      if(CountPositions(sym, magic) >= MaxPosPerPair) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;

      // クールダウン（バー数ベース）
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

   // === ATR取得（レンジ幅正規化用）===
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR[idx], 0, 0, 3, atr) < 3) return;
   if(atr[1] <= 0) return;

   // === 水平レンジ検出 ===
   double rangeHigh = 0, rangeLow = 999999;
   int insideCount = 0;

   for(int k = 1; k <= Range_Lookback; k++) {
      double h = iHigh(sym, BB_TF, k);
      double l = iLow(sym, BB_TF, k);
      if(h > rangeHigh) rangeHigh = h;
      if(l < rangeLow) rangeLow = l;
   }

   double rangeWidth = rangeHigh - rangeLow;
   if(rangeWidth <= 0) return;

   // ATR正規化によるレンジ幅チェック
   double rangeRatio = rangeWidth / atr[1];
   if(rangeRatio > Range_MaxWidth_Pct || rangeRatio < Range_MinWidth_Pct) return;

   // レンジ内収率チェック（バーの実体がレンジ内に収まっている割合）
   for(int k = 1; k <= Range_Lookback; k++) {
      double h = iHigh(sym, BB_TF, k);
      double l = iLow(sym, BB_TF, k);
      // バーの高値と安値の両方がレンジ内ならカウント
      if(h <= rangeHigh && l >= rangeLow) insideCount++;
   }
   double insideRatio = (double)insideCount / Range_Lookback * 100.0;
   if(insideRatio < Range_BodyInside_Pct) return;

   // タッチゾーン
   double zoneSize = rangeWidth * Range_TouchZone_Pct / 100.0;
   double upperZone = rangeHigh - zoneSize;
   double lowerZone = rangeLow + zoneSize;

   // タッチ回数カウント（連続タッチは1回とカウント）
   int upperTouches = 0, lowerTouches = 0;
   bool wasInUpperZone = false, wasInLowerZone = false;

   for(int k = 1; k <= Range_Lookback; k++) {
      bool inUpper = (iHigh(sym, BB_TF, k) >= upperZone);
      bool inLower = (iLow(sym, BB_TF, k) <= lowerZone);

      if(inUpper && !wasInUpperZone) upperTouches++;
      if(inLower && !wasInLowerZone) lowerTouches++;

      wasInUpperZone = inUpper;
      wasInLowerZone = inLower;
   }
   if(upperTouches < Range_TouchCount || lowerTouches < Range_TouchCount) return;

   // === ADXフィルター ===
   if(ADXFilter_Enabled) {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(handleADX[idx], 0, 0, 3, adx) < 3) return;
      if(adx[0] > ADXFilter_Max) return;
      // ADXが上昇中（トレンド加速中）も除外
      if(adx[0] > adx[1] && adx[1] > adx[2] && adx[0] > ADXFilter_Max * 0.8) return;
   }

   // === MAフラットフィルター ===
   if(MAFilter_Enabled) {
      double ma[];
      ArraySetAsSeries(ma, true);
      if(CopyBuffer(handleMA[idx], 0, 0, 6, ma) < 6) return;
      // MA傾きをチェック（5本分の変化がフラットか）
      double maSlope = MathAbs(ma[0] - ma[4]) / pipValue;
      // フラットでなければ除外（トレンドが出ている）
      if(maSlope > MAFilter_FlatPips) return;
   }

   // === BB確認 ===
   double bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(handleBB[idx], 1, 0, 4, bb_upper) < 4) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 4, bb_lower) < 4) return;

   // === 価格データ取得 ===
   double high3  = iHigh(sym, BB_TF, 3);
   double low3   = iLow(sym, BB_TF, 3);
   double close3 = iClose(sym, BB_TF, 3);
   double open3  = iOpen(sym, BB_TF, 3);
   double high2  = iHigh(sym, BB_TF, 2);
   double low2   = iLow(sym, BB_TF, 2);
   double close2 = iClose(sym, BB_TF, 2);
   double open2  = iOpen(sym, BB_TF, 2);
   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);
   double high1  = iHigh(sym, BB_TF, 1);
   double low1   = iLow(sym, BB_TF, 1);

   // === Buy条件: 下限ゾーン接触 + BB下限 + 反転確認 ===
   if(low2 <= lowerZone && low2 <= bb_lower[2]) {
      // 確認足（Bar1）が反転を示す
      double swingRange = high2 - low2;
      if(swingRange <= 0) return;
      double returnRatio = (close1 - low2) / swingRange;
      if(returnRatio < Confirm_MinReturn) return;

      // Bar1が陽線であること
      if(close1 <= open1) return;

      // ダブルバー確認：Bar2が下ヒゲを出し、Bar1がそれを上回る
      if(Confirm_DoubleBar) {
         if(close1 <= close2) return;  // Bar1がBar2の終値を上回る
         if(low1 > lowerZone) {}      // Bar1は下限ゾーンから離脱している方が良い（任意）
      }

      // エントリー位置がレンジ中間より下であること
      double rangeMid = (rangeHigh + rangeLow) / 2.0;
      double currentAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(currentAsk > rangeMid) return;  // 既にレンジ中央以上なら遅い

      // SL/TP計算
      double slPrice = NormalizeDouble(rangeLow - SL_Extra_Pips * pipValue, digits);
      double tpTarget = rangeWidth * TP_Position;
      if(tpTarget / pipValue < TP_Min_Pips) tpTarget = TP_Min_Pips * pipValue;
      double tpPrice = NormalizeDouble(currentAsk + tpTarget, digits);

      // リスクリワードチェック（最低1.0以上）
      double risk = currentAsk - slPrice;
      double reward = tpPrice - currentAsk;
      if(risk <= 0 || reward / risk < 1.0) return;

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         lastCloseTime[idx] = 0;  // エントリー時にリセットはしない
         PrintFormat("[RangeRev V5][%s] BUY @ %.5f, SL=%.5f, TP=%.5f, RR=%.2f, ADX=ok",
                    sym, currentAsk, slPrice, tpPrice, reward/risk);
      }
      return;
   }

   // === Sell条件: 上限ゾーン接触 + BB上限 + 反転確認 ===
   if(high2 >= upperZone && high2 >= bb_upper[2]) {
      // 確認足（Bar1）が反転を示す
      double swingRange = high2 - low2;
      if(swingRange <= 0) return;
      double returnRatio = (high2 - close1) / swingRange;
      if(returnRatio < Confirm_MinReturn) return;

      // Bar1が陰線であること
      if(close1 >= open1) return;

      // ダブルバー確認
      if(Confirm_DoubleBar) {
         if(close1 >= close2) return;  // Bar1がBar2の終値を下回る
      }

      // エントリー位置がレンジ中間より上であること
      double rangeMid = (rangeHigh + rangeLow) / 2.0;
      double currentBid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(currentBid < rangeMid) return;  // 既にレンジ中央以下なら遅い

      // SL/TP計算
      double slPrice = NormalizeDouble(rangeHigh + SL_Extra_Pips * pipValue, digits);
      double tpTarget = rangeWidth * TP_Position;
      if(tpTarget / pipValue < TP_Min_Pips) tpTarget = TP_Min_Pips * pipValue;
      double tpPrice = NormalizeDouble(currentBid - tpTarget, digits);

      // リスクリワードチェック
      double risk = slPrice - currentBid;
      double reward = currentBid - tpPrice;
      if(risk <= 0 || reward / risk < 1.0) return;

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         lastCloseTime[idx] = 0;
         PrintFormat("[RangeRev V5][%s] SELL @ %.5f, SL=%.5f, TP=%.5f, RR=%.2f, ADX=ok",
                    sym, currentBid, slPrice, tpPrice, reward/risk);
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
