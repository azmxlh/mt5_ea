//+------------------------------------------------------------------+
//| RangeReversion.mq5 - 水平線レンジ+BB逆張りEA                   |
//| レンジ判定: 直近高安値の水平レンジを検出                        |
//| エントリー: レンジ端+BB確認+反転足でタイミング                  |
//| SL: レンジの外側（レンジブレイクで撤退）                        |
//| TP: レンジの反対側 or 中央                                      |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "3.00"
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

//--- BB設定（タイミング補助）
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H1;   // 判定時間足

//--- 水平レンジ判定設定
input int      Range_Lookback    = 48;          // レンジ判定に使う過去バー数
input double   Range_MaxWidth_Pct = 2.0;        // レンジ幅の上限（価格に対する%）
input double   Range_MinWidth_Pct = 0.3;        // レンジ幅の下限（%）狭すぎるのはNG
input int      Range_TouchCount  = 2;           // 高値/安値ゾーンへのタッチ最低回数
input double   Range_TouchZone_Pct = 20.0;      // タッチゾーン（レンジ幅の上下何%をゾーンとする）

//--- SL/TP設定
input double   SL_Extra_Pips    = 5.0;          // SL=レンジ外側+この値(pips)
input double   TP_Position      = 0.5;          // TP位置(0=反対側, 0.5=中央, 1.0=エントリー位置)

//--- エントリー確認設定
input double   Confirm_MinReturn = 0.3;         // 確認足の最低戻り率

//--- ADXフィルター
input bool     ADXFilter_Enabled = true;
input int      ADXFilter_Period  = 14;
input double   ADXFilter_Max    = 25.0;
input ENUM_TIMEFRAMES ADXFilter_TF = PERIOD_H4;

//--- リスク管理
input double   MaxSpread_Pips   = 3.0;
input int      TradingStartHour = 0;
input int      TradingEndHour   = 0;
input int      ReentryCooldown  = 12;
input int      MaxTotalPositions = 10;
input int      MaxPosPerPair    = 1;

//--- 許可口座
input string   AllowedAccounts  = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
int    handleADX[];
bool   pairEnabled[];
datetime lastCloseTime[];
datetime lastBarTime[];

//+------------------------------------------------------------------+
double GetMinLot() { return MicroMode ? 0.1 : 0.01; }

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(AllowedAccounts) > 0 && !IsAccountAllowed()) {
      Print("[RangeRev ERROR] この口座では使用できません");
      return INIT_FAILED;
   }

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) return INIT_FAILED;

   ArrayResize(handleBB, pairCount);
   ArrayResize(handleADX, pairCount);
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
      if(handleBB[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }

      if(ADXFilter_Enabled) {
         handleADX[i] = iADX(pairs[i], ADXFilter_TF, ADXFilter_Period);
         if(handleADX[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }
      } else {
         handleADX[i] = INVALID_HANDLE;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[RangeRev] 初期化完了: ペア=%d/%d, Range=%dbars, BB(%d,%.1f)",
              enabledCount, pairCount, Range_Lookback, BB_Period, BB_Deviation);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleADX[i] != INVALID_HANDLE) IndicatorRelease(handleADX[i]);
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
      if(!IsTradingHour()) continue;
      if(!IsSpreadOK(sym)) continue;
      if(CountPositions(sym, magic) >= MaxPosPerPair) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;
      if(ReentryCooldown > 0 && lastCloseTime[i] > 0)
         if(TimeCurrent() - lastCloseTime[i] < ReentryCooldown * 3600) continue;

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
// 水平レンジ検出 + BB確認 + 反転足確認 → エントリー
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   // === 水平レンジ検出 ===
   // 直近Range_Lookback本のHigh/Lowからレンジ上限/下限を算出
   double rangeHigh = 0, rangeLow = 999999;
   for(int k = 1; k <= Range_Lookback; k++) {
      double h = iHigh(sym, BB_TF, k);
      double l = iLow(sym, BB_TF, k);
      if(h > rangeHigh) rangeHigh = h;
      if(l < rangeLow) rangeLow = l;
   }

   double rangeWidth = rangeHigh - rangeLow;
   double midPrice = (rangeHigh + rangeLow) / 2.0;
   if(midPrice <= 0) return;

   // レンジ幅チェック（価格に対する%）
   double widthPct = rangeWidth / midPrice * 100.0;
   if(widthPct > Range_MaxWidth_Pct || widthPct < Range_MinWidth_Pct) return;

   // タッチゾーン（レンジの上下端ゾーン）
   double zoneSize = rangeWidth * Range_TouchZone_Pct / 100.0;
   double upperZone = rangeHigh - zoneSize;  // この価格以上が上限ゾーン
   double lowerZone = rangeLow + zoneSize;   // この価格以下が下限ゾーン

   // タッチ回数カウント（高値ゾーン・安値ゾーンに何回触れたか）
   int upperTouches = 0, lowerTouches = 0;
   for(int k = 1; k <= Range_Lookback; k++) {
      double h = iHigh(sym, BB_TF, k);
      double l = iLow(sym, BB_TF, k);
      if(h >= upperZone) upperTouches++;
      if(l <= lowerZone) lowerTouches++;
   }

   // 上下ともに最低タッチ回数を満たす=レンジとして成立
   if(upperTouches < Range_TouchCount || lowerTouches < Range_TouchCount) return;

   // === ADXフィルター ===
   if(ADXFilter_Enabled && !IsADXBelowMax(idx)) return;

   // === BB確認（現在価格がBBバンド端付近か）===
   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(handleBB[idx], 0, 0, 3, bb_mid) < 3) return;
   if(CopyBuffer(handleBB[idx], 1, 0, 3, bb_upper) < 3) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 3, bb_lower) < 3) return;

   // === 2本足確認: bar[2]=タッチ足, bar[1]=確認足 ===
   double high2  = iHigh(sym, BB_TF, 2);
   double low2   = iLow(sym, BB_TF, 2);
   double close2 = iClose(sym, BB_TF, 2);
   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // ================================================================
   // Buy条件:
   // 1. タッチ足(bar[2])の安値がレンジ下限ゾーンに到達
   // 2. タッチ足の安値がBB下限バンド以下（BB確認）
   // 3. タッチ足の実体はレンジ内（ブレイクしていない）
   // 4. 確認足(bar[1])が陽線で戻り確認
   // ================================================================
   if(low2 <= lowerZone && low2 <= bb_lower[2] && close2 > rangeLow) {
      // 確認足: 陽線 + 戻り率チェック
      double touchRange = high2 - low2;
      if(touchRange <= 0) return;
      double returnAmt = close1 - low2;
      if(!(close1 > open1 && returnAmt / touchRange >= Confirm_MinReturn)) return;

      // SL = レンジ下限 - バッファ
      double entryPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(rangeLow - SL_Extra_Pips * point * 10, digits);

      // TP = レンジ内の指定位置 (0=上限, 0.5=中央, 1.0=下限)
      double tpPrice = NormalizeDouble(rangeHigh - rangeWidth * TP_Position, digits);

      if(slPrice >= entryPrice || tpPrice <= entryPrice) return;

      // RR比チェック
      double slDist = entryPrice - slPrice;
      double tpDist = tpPrice - entryPrice;
      if(slDist <= 0 || tpDist / slDist < 1.0) return;

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] BUY @ %.5f, SL=%.5f(%.0fp), TP=%.5f(%.0fp), RR=1:%.1f, Range=[%.5f-%.5f]",
                    sym, entryPrice, slPrice, slDist/point/10, tpPrice, tpDist/point/10,
                    tpDist/slDist, rangeLow, rangeHigh);
      }
      return;
   }

   // ================================================================
   // Sell条件:
   // 1. タッチ足(bar[2])の高値がレンジ上限ゾーンに到達
   // 2. タッチ足の高値がBB上限バンド以上（BB確認）
   // 3. タッチ足の実体はレンジ内
   // 4. 確認足(bar[1])が陰線で戻り確認
   // ================================================================
   if(high2 >= upperZone && high2 >= bb_upper[2] && close2 < rangeHigh) {
      // 確認足: 陰線 + 戻り率チェック
      double touchRange = high2 - low2;
      if(touchRange <= 0) return;
      double returnAmt = high2 - close1;
      if(!(close1 < open1 && returnAmt / touchRange >= Confirm_MinReturn)) return;

      // SL = レンジ上限 + バッファ
      double entryPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(rangeHigh + SL_Extra_Pips * point * 10, digits);

      // TP = レンジ内の指定位置 (0=下限, 0.5=中央)
      double tpPrice = NormalizeDouble(rangeLow + rangeWidth * TP_Position, digits);

      if(slPrice <= entryPrice || tpPrice >= entryPrice) return;

      // RR比チェック
      double slDist = slPrice - entryPrice;
      double tpDist = entryPrice - tpPrice;
      if(slDist <= 0 || tpDist / slDist < 1.0) return;

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] SELL @ %.5f, SL=%.5f(%.0fp), TP=%.5f(%.0fp), RR=1:%.1f, Range=[%.5f-%.5f]",
                    sym, entryPrice, slPrice, slDist/point/10, tpPrice, tpDist/point/10,
                    tpDist/slDist, rangeLow, rangeHigh);
      }
      return;
   }
}

//+------------------------------------------------------------------+
bool IsADXBelowMax(int idx)
{
   if(handleADX[idx] == INVALID_HANDLE) return true;
   double adx[];
   ArraySetAsSeries(adx, true);
   if(CopyBuffer(handleADX[idx], 0, 0, 2, adx) < 2) return true;
   return (adx[1] <= ADXFilter_Max);
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
   req.deviation    = 30;
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
