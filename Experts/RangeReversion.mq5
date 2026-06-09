//+------------------------------------------------------------------+
//| RangeReversion.mq5 - 東京時間スキャル型レンジ逆張りEA          |
//| M15足 / 東京時間限定 / 水平レンジ+BB確認                        |
//| 短い保有時間＋タイトなTP/SLで素早く決着                         |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "4.00"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURJPY,GBPJPY,AUDJPY,EURUSD,GBPUSD,AUDUSD";
input int      MagicBase         = 79000;

//--- 複利設定
input bool     CompoundMode      = true;
input double   BalancePerLot     = 100000;
input double   BaseLots          = 0.1;
input double   FixedLot          = 0.1;
input bool     MicroMode         = false;

//--- 時間足・BB設定
input ENUM_TIMEFRAMES BB_TF      = PERIOD_M15;  // M15足
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;

//--- 水平レンジ設定
input int      Range_Lookback    = 32;          // レンジ判定バー数(M15x32=8時間分)
input double   Range_MaxPips     = 40.0;        // レンジ幅上限(pips)
input double   Range_MinPips     = 10.0;        // レンジ幅下限(pips)
input int      Range_TouchCount  = 3;           // 上下端タッチ最低回数
input double   Range_TouchZone_Pct = 25.0;      // タッチゾーン(レンジ幅の%)

//--- 東京時間設定（サーバー時間）
input int      Tokyo_Start       = 0;           // 東京時間開始(サーバー時間)
input int      Tokyo_End         = 8;           // 東京時間終了(サーバー時間)

//--- TP/SL設定（pips）
input double   TP_Pips           = 15.0;        // 利確(pips)
input double   SL_Pips           = 12.0;        // 損切り(pips)
input int      MaxHoldBars       = 8;           // 最大保有バー数(超えたら成行決済)

//--- エントリー条件
input double   Confirm_MinReturn = 0.3;         // 確認足の最低戻り率

//--- リスク管理
input double   MaxSpread_Pips   = 2.0;          // スキャルなのでスプレッド制限厳しめ
input int      ReentryCooldown  = 4;            // 決済後の抑制(バー数)
input int      MaxTotalPositions = 5;
input int      MaxPosPerPair    = 1;

//--- 許可口座
input string   AllowedAccounts  = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
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

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[RangeRev Scalp] 初期化: %d/%d pairs, M15, Tokyo %d:00-%d:00",
              enabledCount, pairCount, Tokyo_Start, Tokyo_End);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++)
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
}

//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];

      // 保有中ポジションの時間管理
      ManagePosition(sym, magic);

      if(!IsNewBar(sym, i)) continue;

      // 東京時間チェック
      if(!IsTokyoTime()) continue;

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
// 最大保有時間超過で成行決済
//+------------------------------------------------------------------+
void ManagePosition(string sym, int magic)
{
   for(int j = PositionsTotal() - 1; j >= 0; j--) {
      ulong ticket = PositionGetTicket(j);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int barsHeld = (int)((TimeCurrent() - openTime) / PeriodSeconds(BB_TF));

      if(barsHeld >= MaxHoldBars) {
         ClosePosition(ticket, sym, magic);
         int idx = magic - MagicBase;
         if(idx >= 0 && idx < pairCount) lastCloseTime[idx] = TimeCurrent();
      }
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
bool IsTokyoTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(Tokyo_Start < Tokyo_End)
      return (h >= Tokyo_Start && h < Tokyo_End);
   else
      return (h >= Tokyo_Start || h < Tokyo_End);
}

//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipValue = point * 10;  // 1pip

   // === 水平レンジ検出 ===
   double rangeHigh = 0, rangeLow = 999999;
   for(int k = 1; k <= Range_Lookback; k++) {
      double h = iHigh(sym, BB_TF, k);
      double l = iLow(sym, BB_TF, k);
      if(h > rangeHigh) rangeHigh = h;
      if(l < rangeLow) rangeLow = l;
   }

   double rangeWidth = rangeHigh - rangeLow;
   double rangeWidthPips = rangeWidth / pipValue;

   // レンジ幅チェック(pips)
   if(rangeWidthPips > Range_MaxPips || rangeWidthPips < Range_MinPips) return;

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

   // === BB確認 ===
   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(handleBB[idx], 0, 0, 3, bb_mid) < 3) return;
   if(CopyBuffer(handleBB[idx], 1, 0, 3, bb_upper) < 3) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 3, bb_lower) < 3) return;

   // === 2本足確認 ===
   double high2  = iHigh(sym, BB_TF, 2);
   double low2   = iLow(sym, BB_TF, 2);
   double close2 = iClose(sym, BB_TF, 2);
   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);

   // === Buy: 下限ゾーン+BB下限タッチ+確認足陽線 ===
   if(low2 <= lowerZone && low2 <= bb_lower[2] && close2 > rangeLow) {
      double touchRange = high2 - low2;
      if(touchRange <= 0) return;
      if(!(close1 > open1 && (close1 - low2) / touchRange >= Confirm_MinReturn)) return;

      double entryPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(entryPrice - SL_Pips * pipValue, digits);
      double tpPrice = NormalizeDouble(entryPrice + TP_Pips * pipValue, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] BUY @ %.5f, SL=%.0fp, TP=%.0fp, Range=%.0fp",
                    sym, entryPrice, SL_Pips, TP_Pips, rangeWidthPips);
      }
      return;
   }

   // === Sell: 上限ゾーン+BB上限タッチ+確認足陰線 ===
   if(high2 >= upperZone && high2 >= bb_upper[2] && close2 < rangeHigh) {
      double touchRange = high2 - low2;
      if(touchRange <= 0) return;
      if(!(close1 < open1 && (high2 - close1) / touchRange >= Confirm_MinReturn)) return;

      double entryPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(entryPrice + SL_Pips * pipValue, digits);
      double tpPrice = NormalizeDouble(entryPrice - TP_Pips * pipValue, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] SELL @ %.5f, SL=%.0fp, TP=%.0fp, Range=%.0fp",
                    sym, entryPrice, SL_Pips, TP_Pips, rangeWidthPips);
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
void ClosePosition(ulong ticket, string sym, int magic)
{
   if(!PositionSelectByTicket(ticket)) return;
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   long type = PositionGetInteger(POSITION_TYPE);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.type         = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
   req.deviation    = 20;
   req.position     = ticket;
   req.magic        = magic;
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         OrderSend(req, res);
      }
   }
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
