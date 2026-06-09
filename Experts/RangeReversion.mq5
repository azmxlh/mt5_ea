//+------------------------------------------------------------------+
//| RangeReversion.mq5 - ボリンジャーバンド逆張りレンジEA           |
//| エントリー: スクイーズ検出 + バンドタッチ + 確認足で反転確認    |
//| SL: タッチ足の高安値+バッファ（狭いSL）                        |
//| TP: 中央線（レンジの中央に戻るシナリオ）                        |
//| 複利対応 / マルチペア / RSI+ADXフィルター                        |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "2.00"
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
input int      BB_Period         = 20;          // BB期間
input double   BB_Deviation      = 2.0;         // エントリー用BB偏差（±2σ）
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H1;   // BB時間足

//--- レンジ（スクイーズ）判定設定
input int      Squeeze_Lookback  = 20;          // バンド幅の平均を計算する過去バー数
input double   Squeeze_Mult     = 1.0;          // バンド幅がこの倍率以下でスクイーズ判定
input int      Squeeze_MinBars  = 2;            // スクイーズが最低何バー継続しているか

//--- SL/TP設定
input double   SL_Extra_Pips    = 5.0;          // SLバッファ(pips) タッチ足の高安+この値
input bool     TP_UseMidLine    = true;         // TP=中央線(true) / RR比で計算(false)
input double   TP_RR_Ratio      = 2.0;          // RR比(TP_UseMidLine=falseの場合)

//--- RSIフィルター
input bool     RSI_Enabled      = true;         // RSIフィルター(有効/無効)
input int      RSI_Period       = 14;           // RSI期間
input double   RSI_Oversold     = 35.0;         // 買い:RSIがこの値以下
input double   RSI_Overbought   = 65.0;         // 売り:RSIがこの値以上

//--- ADXフィルター（低ADX=レンジ確認）
input bool     ADXFilter_Enabled = true;        // ADXフィルター(有効/無効)
input int      ADXFilter_Period  = 14;          // ADX期間
input double   ADXFilter_Max    = 25.0;         // ADXがこの値以下でレンジ判定
input ENUM_TIMEFRAMES ADXFilter_TF = PERIOD_H4; // ADX判定の時間足

//--- エントリー条件（2本足確認方式）
input double   BB_Touch_Margin  = 0.0;          // バンドタッチのマージン(pips)
input double   NearTouch_Sigma  = 1.8;          // ニアタッチ判定のσ閾値
input double   Confirm_MinReturn = 0.3;         // 確認足の最低戻り率

//--- リスク管理
input double   MaxSpread_Pips   = 3.0;
input int      TradingStartHour = 0;
input int      TradingEndHour   = 0;
input int      ReentryCooldown  = 12;           // 決済後の再エントリー抑制(時間)
input int      MaxTotalPositions = 10;
input int      MaxPosPerPair    = 1;            // 1ペアあたりの最大ポジション数

//--- 許可口座
input string   AllowedAccounts  = "";           // 空=全口座許可

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
int    handleRSI[];
int    handleADX[];
bool   pairEnabled[];
datetime lastCloseTime[];
datetime lastBarTime[];

//+------------------------------------------------------------------+
double GetMinLot()
{
   return MicroMode ? 0.1 : 0.01;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(AllowedAccounts) > 0 && !IsAccountAllowed()) {
      Print("[RangeRev ERROR] この口座では使用できません: ", AccountInfoInteger(ACCOUNT_LOGIN));
      return INIT_FAILED;
   }

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) {
      Print("[RangeRev ERROR] 通貨ペアが指定されていません");
      return INIT_FAILED;
   }

   ArrayResize(handleBB, pairCount);
   ArrayResize(handleRSI, pairCount);
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

      if(!SymbolSelect(pairs[i], true)) {
         handleBB[i] = INVALID_HANDLE;
         pairEnabled[i] = false;
         continue;
      }

      handleBB[i] = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(handleBB[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }

      if(RSI_Enabled) {
         handleRSI[i] = iRSI(pairs[i], BB_TF, RSI_Period, PRICE_CLOSE);
         if(handleRSI[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }
      } else {
         handleRSI[i] = INVALID_HANDLE;
      }

      if(ADXFilter_Enabled) {
         handleADX[i] = iADX(pairs[i], ADXFilter_TF, ADXFilter_Period);
         if(handleADX[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }
      } else {
         handleADX[i] = INVALID_HANDLE;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) {
      Print("[RangeRev ERROR] 有効な通貨ペアがありません");
      return INIT_FAILED;
   }

   PrintFormat("[RangeRev] 初期化完了: ペア=%d/%d, BB(%d,%.1f) on %s",
              enabledCount, pairCount, BB_Period, BB_Deviation, EnumToString(BB_TF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleRSI[i] != INVALID_HANDLE) IndicatorRelease(handleRSI[i]);
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

      if(ReentryCooldown > 0 && lastCloseTime[i] > 0) {
         if(TimeCurrent() - lastCloseTime[i] < ReentryCooldown * 3600) continue;
      }

      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
bool IsNewBar(string sym, int idx)
{
   datetime barTime = iTime(sym, BB_TF, 0);
   if(barTime == 0) return false;
   if(barTime != lastBarTime[idx]) {
      lastBarTime[idx] = barTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// エントリー判定（2本足確認方式）
// bar[2] = タッチ足: ヒゲがバンドにタッチした足
// bar[1] = 確認足: 中央方向に戻ったことを確認する足
// → 確認足の確定後にエントリー
// SL = タッチ足の安値/高値 + バッファ（狭いSL）
// TP = 中央線（広いTP）→ RR比が自然に良くなる
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);

   int needBars = Squeeze_Lookback + Squeeze_MinBars + 5;
   if(CopyBuffer(handleBB[idx], 0, 0, needBars, bb_mid) < needBars) return;
   if(CopyBuffer(handleBB[idx], 1, 0, needBars, bb_upper) < needBars) return;
   if(CopyBuffer(handleBB[idx], 2, 0, needBars, bb_lower) < needBars) return;

   // === スクイーズ判定（bar[2]時点） ===
   double bw2 = bb_upper[2] - bb_lower[2];
   double avgBW = 0;
   for(int k = 3; k < Squeeze_Lookback + 3; k++) {
      avgBW += bb_upper[k] - bb_lower[k];
   }
   avgBW /= Squeeze_Lookback;
   if(avgBW <= 0) return;
   if(bw2 > avgBW * Squeeze_Mult) return;

   // スクイーズ継続チェック
   for(int s = 0; s < Squeeze_MinBars - 1; s++) {
      double bw = bb_upper[s + 3] - bb_lower[s + 3];
      if(bw > avgBW * Squeeze_Mult) return;
   }

   // === ADXフィルター ===
   if(ADXFilter_Enabled && !IsADXBelowMax(idx)) return;

   // === タッチ足(bar[2])と確認足(bar[1])のデータ ===
   double high2  = iHigh(sym, BB_TF, 2);
   double low2   = iLow(sym, BB_TF, 2);
   double close2 = iClose(sym, BB_TF, 2);
   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double touchMargin = BB_Touch_Margin * point * 10;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double sigmaWidth = (bb_upper[2] - bb_mid[2]) / BB_Deviation;
   if(sigmaWidth <= 0) return;

   // ================================================================
   // === Buy条件 ===
   // タッチ足: ヒゲが下限バンド(-2σ)以下、または-1.8σ以下にタッチ
   // 確認足: 陽線で中央方向に戻った
   // ================================================================
   bool touchLower = (low2 <= bb_lower[2] + touchMargin);
   if(!touchLower) {
      double nearLevel = bb_mid[2] - sigmaWidth * NearTouch_Sigma;
      touchLower = (low2 <= nearLevel + touchMargin);
   }

   if(touchLower && close2 > bb_lower[2]) {  // タッチ足の実体はバンド内
      // 確認足チェック: 陽線 + 安値からの戻り率
      double touchRange = high2 - low2;
      if(touchRange <= 0) return;
      double returnAmt = close1 - low2;
      bool confirmed = (close1 > open1) && (returnAmt / touchRange >= Confirm_MinReturn);
      if(!confirmed) return;

      // RSIフィルター(bar[2]時点で売られすぎ)
      if(RSI_Enabled && !IsRSIOversold(idx)) return;

      // SL = タッチ足の安値 - バッファ
      double entryPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(low2 - SL_Extra_Pips * point * 10, digits);

      // TP = 中央線 or RR比
      double tpPrice;
      if(TP_UseMidLine)
         tpPrice = NormalizeDouble(bb_mid[1], digits);
      else {
         double slDist = entryPrice - slPrice;
         tpPrice = NormalizeDouble(entryPrice + slDist * TP_RR_Ratio, digits);
      }

      // 有効性チェック
      if(slPrice >= entryPrice || tpPrice <= entryPrice) return;
      double slDist = entryPrice - slPrice;
      double tpDist = tpPrice - entryPrice;
      if(slDist <= 0 || tpDist / slDist < 1.0) return;  // RR最低1:1

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] BUY @ %.5f, SL=%.5f(%.0fp), TP=%.5f(%.0fp), RR=1:%.1f",
                    sym, entryPrice, slPrice, slDist/point/10, tpPrice, tpDist/point/10, tpDist/slDist);
      }
      return;
   }

   // ================================================================
   // === Sell条件 ===
   // タッチ足: ヒゲが上限バンド(+2σ)以上、または+1.8σ以上にタッチ
   // 確認足: 陰線で中央方向に戻った
   // ================================================================
   bool touchUpper = (high2 >= bb_upper[2] - touchMargin);
   if(!touchUpper) {
      double nearLevel = bb_mid[2] + sigmaWidth * NearTouch_Sigma;
      touchUpper = (high2 >= nearLevel - touchMargin);
   }

   if(touchUpper && close2 < bb_upper[2]) {  // タッチ足の実体はバンド内
      // 確認足チェック: 陰線 + 高値からの戻り率
      double touchRange = high2 - low2;
      if(touchRange <= 0) return;
      double returnAmt = high2 - close1;
      bool confirmed = (close1 < open1) && (returnAmt / touchRange >= Confirm_MinReturn);
      if(!confirmed) return;

      // RSIフィルター(bar[2]時点で買われすぎ)
      if(RSI_Enabled && !IsRSIOverbought(idx)) return;

      // SL = タッチ足の高値 + バッファ
      double entryPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(high2 + SL_Extra_Pips * point * 10, digits);

      // TP = 中央線 or RR比
      double tpPrice;
      if(TP_UseMidLine)
         tpPrice = NormalizeDouble(bb_mid[1], digits);
      else {
         double slDist = slPrice - entryPrice;
         tpPrice = NormalizeDouble(entryPrice - slDist * TP_RR_Ratio, digits);
      }

      // 有効性チェック
      if(slPrice <= entryPrice || tpPrice >= entryPrice) return;
      double slDist = slPrice - entryPrice;
      double tpDist = entryPrice - tpPrice;
      if(slDist <= 0 || tpDist / slDist < 1.0) return;  // RR最低1:1

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeRev][%s] SELL @ %.5f, SL=%.5f(%.0fp), TP=%.5f(%.0fp), RR=1:%.1f",
                    sym, entryPrice, slPrice, slDist/point/10, tpPrice, tpDist/point/10, tpDist/slDist);
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
bool IsRSIOversold(int idx)
{
   if(handleRSI[idx] == INVALID_HANDLE) return true;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleRSI[idx], 0, 0, 3, rsi) < 3) return true;
   return (rsi[2] <= RSI_Oversold);  // タッチ足(bar[2])時点のRSI
}

//+------------------------------------------------------------------+
bool IsRSIOverbought(int idx)
{
   if(handleRSI[idx] == INVALID_HANDLE) return true;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleRSI[idx], 0, 0, 3, rsi) < 3) return true;
   return (rsi[2] >= RSI_Overbought);  // タッチ足(bar[2])時点のRSI
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
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return lot;
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
         if(!OrderSend(req, res)) {
            PrintFormat("[RangeRev ERROR] 注文失敗: %s, err=%d", sym, res.retcode);
            return false;
         }
      } else {
         PrintFormat("[RangeRev ERROR] 注文失敗: %s, err=%d", sym, res.retcode);
         return false;
      }
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
   double spreadPips = (ask - bid) / (point * 10);
   return (spreadPips <= MaxSpread_Pips);
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
   for(int i = 0; i < cnt; i++) {
      if(StringToInteger(accounts[i]) == login) return true;
   }
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
