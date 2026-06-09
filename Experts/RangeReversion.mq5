//+------------------------------------------------------------------+
//| RangeReversion.mq5 - レンジ逆張りEA V6                         |
//| スイングハイ/ロー基準のレンジ検出 + ATR縮小確認                 |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "6.00"
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

//--- レンジ検出設定（H4スイングベース）
input ENUM_TIMEFRAMES Range_TF   = PERIOD_H4;   // レンジ検出用時間足
input int      Swing_Lookback    = 30;          // スイングハイ/ロー検出範囲(H4バー)
input int      Swing_Bars        = 3;           // スイング確定に必要な両側バー数
input int      NoBreak_Bars      = 10;          // レンジ上下端が破られていない期間(H4)
input double   Range_MaxPips     = 150.0;       // レンジ幅上限(pips)
input double   Range_MinPips     = 30.0;        // レンジ幅下限(pips)

//--- ATR縮小確認
input int      ATR_Period        = 14;
input double   ATR_Shrink_Ratio  = 0.8;         // 直近ATR / 過去ATR がこの値以下

//--- エントリー設定（H1）
input ENUM_TIMEFRAMES Entry_TF   = PERIOD_H1;   // エントリー判定時間足
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;
input double   Confirm_MinReturn = 0.3;         // 確認足戻り率

//--- SL/TP設定
input double   SL_Extra_Pips     = 5.0;         // レンジ外+Xpips
input double   TP_Ratio          = 0.5;         // レンジ幅に対するTP比率（0.5=中央）

//--- リスク管理
input double   MaxSpread_Pips    = 3.0;
input int      TradingStartHour  = 0;
input int      TradingEndHour    = 0;
input int      ReentryCooldown   = 6;           // H1バー数
input int      MaxTotalPositions = 10;
input int      MaxPosPerPair     = 1;

//--- 許可口座
input string   AllowedAccounts   = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
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

      handleBB[i] = iBands(pairs[i], Entry_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      handleATR[i] = iATR(pairs[i], Range_TF, ATR_Period);

      if(handleBB[i] == INVALID_HANDLE || handleATR[i] == INVALID_HANDLE) {
         pairEnabled[i] = false; continue;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[RangeRev V6] 初期化: %d/%d pairs, Range=%s, Entry=%s",
              enabledCount, pairCount, EnumToString(Range_TF), EnumToString(Entry_TF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
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
         int barsSinceClose = (int)((TimeCurrent() - lastCloseTime[i]) / PeriodSeconds(Entry_TF));
         if(barsSinceClose < ReentryCooldown) continue;
      }

      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
bool IsNewBar(string sym, int idx)
{
   datetime barTime = iTime(sym, Entry_TF, 0);
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
// スイングハイを検出（左右Swing_Bars本より高い高値）
//+------------------------------------------------------------------+
bool FindSwingHigh(string sym, int startBar, int &foundBar, double &foundPrice)
{
   for(int i = startBar + Swing_Bars; i <= Swing_Lookback - Swing_Bars; i++) {
      double h = iHigh(sym, Range_TF, i);
      bool isSwing = true;
      for(int j = 1; j <= Swing_Bars; j++) {
         if(iHigh(sym, Range_TF, i - j) >= h || iHigh(sym, Range_TF, i + j) >= h) {
            isSwing = false;
            break;
         }
      }
      if(isSwing) {
         foundBar = i;
         foundPrice = h;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
// スイングローを検出（左右Swing_Bars本より低い安値）
//+------------------------------------------------------------------+
bool FindSwingLow(string sym, int startBar, int &foundBar, double &foundPrice)
{
   for(int i = startBar + Swing_Bars; i <= Swing_Lookback - Swing_Bars; i++) {
      double l = iLow(sym, Range_TF, i);
      bool isSwing = true;
      for(int j = 1; j <= Swing_Bars; j++) {
         if(iLow(sym, Range_TF, i - j) <= l || iLow(sym, Range_TF, i + j) <= l) {
            isSwing = false;
            break;
         }
      }
      if(isSwing) {
         foundBar = i;
         foundPrice = l;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipValue = point * 10;

   // === スイングハイ/ロー検出 ===
   int swHighBar = 0, swLowBar = 0;
   double rangeHigh = 0, rangeLow = 0;

   if(!FindSwingHigh(sym, 0, swHighBar, rangeHigh)) return;
   if(!FindSwingLow(sym, 0, swLowBar, rangeLow)) return;

   double rangeWidth = rangeHigh - rangeLow;
   double rangeWidthPips = rangeWidth / pipValue;
   if(rangeWidthPips > Range_MaxPips || rangeWidthPips < Range_MinPips) return;

   // === レンジ未ブレイク確認 ===
   // 直近NoBreak_Bars本のH4バーがレンジを超えていないこと
   for(int k = 1; k <= NoBreak_Bars; k++) {
      if(iHigh(sym, Range_TF, k) > rangeHigh + 2 * pipValue) return;  // 2pips余裕
      if(iLow(sym, Range_TF, k) < rangeLow - 2 * pipValue) return;
   }

   // === ATR縮小確認 ===
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR[idx], 0, 0, ATR_Period * 2, atr) < ATR_Period * 2) return;

   double recentATR = 0, pastATR = 0;
   for(int k = 0; k < ATR_Period; k++) recentATR += atr[k];
   for(int k = ATR_Period; k < ATR_Period * 2; k++) pastATR += atr[k];
   recentATR /= ATR_Period;
   pastATR /= ATR_Period;

   if(pastATR <= 0) return;
   if(recentATR / pastATR > ATR_Shrink_Ratio) return;  // ATRが縮小していない

   // === BB確認（Entry_TF = H1）===
   double bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(handleBB[idx], 1, 0, 4, bb_upper) < 4) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 4, bb_lower) < 4) return;

   // === H1価格データ ===
   double high2  = iHigh(sym, Entry_TF, 2);
   double low2   = iLow(sym, Entry_TF, 2);
   double close2 = iClose(sym, Entry_TF, 2);
   double close1 = iClose(sym, Entry_TF, 1);
   double open1  = iOpen(sym, Entry_TF, 1);

   // レンジ下端ゾーン（下20%）
   double lowerZone = rangeLow + rangeWidth * 0.2;
   double upperZone = rangeHigh - rangeWidth * 0.2;

   // === Buy: 下端ゾーン + BB下限 + 反転足 ===
   if(low2 <= lowerZone && low2 <= bb_lower[2]) {
      double swingRange = high2 - low2;
      if(swingRange <= 0) return;
      if((close1 - low2) / swingRange < Confirm_MinReturn) return;
      if(close1 <= open1) return;

      double entryPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(rangeLow - SL_Extra_Pips * pipValue, digits);
      double tpPrice = NormalizeDouble(entryPrice + rangeWidth * TP_Ratio, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev V6][%s] BUY @ %.5f, SL=%.5f, TP=%.5f, Range=%.0fp",
                    sym, entryPrice, slPrice, tpPrice, rangeWidthPips);
      }
      return;
   }

   // === Sell: 上端ゾーン + BB上限 + 反転足 ===
   if(high2 >= upperZone && high2 >= bb_upper[2]) {
      double swingRange = high2 - low2;
      if(swingRange <= 0) return;
      if((high2 - close1) / swingRange < Confirm_MinReturn) return;
      if(close1 >= open1) return;

      double entryPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(rangeHigh + SL_Extra_Pips * pipValue, digits);
      double tpPrice = NormalizeDouble(entryPrice - rangeWidth * TP_Ratio, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev V6][%s] SELL @ %.5f, SL=%.5f, TP=%.5f, Range=%.0fp",
                    sym, entryPrice, slPrice, tpPrice, rangeWidthPips);
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
