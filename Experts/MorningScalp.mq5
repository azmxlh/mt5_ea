//+------------------------------------------------------------------+
//| MorningScalp.mq5 - 朝スキャルピングEA（MT5マルチペア版）V2      |
//| 日本時間早朝のレンジ相場でRSI逆張り + 利益追従ロジック           |
//| 改善: トレーリング/ブレイクイーブン/部分利確/動的TP/SL/ADXフィルター |
//+------------------------------------------------------------------+
#property copyright "MorningScalp EA V2"
#property version   "2.00"
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
input int      RSI_UpperLine     = 75;          // RSI上限（売りシグナル）※80→75に調整
input int      RSI_LowerLine     = 25;          // RSI下限（買いシグナル）※20→25に調整
input ENUM_TIMEFRAMES RSI_TF     = PERIOD_M5;   // RSI計算時間足
input int      RSI_ConfirmBars   = 2;           // RSI確認本数（連続で閾値超え要求）

//--- TP/SL設定（ATRベース）
input bool     UseDynamicTPSL    = true;        // ATRベース動的TP/SLを使用
input double   TP_ATR_Multi      = 1.5;         // TP = ATR × この倍率
input double   SL_ATR_Multi      = 1.0;         // SL = ATR × この倍率
input double   TakeProfit_Pips   = 15.0;        // 固定TP（動的TP未使用時）
input double   LossCut_Pips      = 10.0;        // 固定SL（動的SL未使用時）※15→10に縮小

//--- トレーリングストップ設定
input bool     UseTrailing       = true;        // トレーリングストップを使用
input double   TrailStart_Pips   = 8.0;         // トレーリング開始（含み益pips）
input double   TrailStep_Pips    = 3.0;         // トレーリングステップ（pips）

//--- ブレイクイーブン設定
input bool     UseBreakEven      = true;        // ブレイクイーブンを使用
input double   BE_Trigger_Pips   = 5.0;         // BEトリガー（含み益pips）
input double   BE_Offset_Pips    = 1.0;         // BE時のオフセット（+1pipsで微益確保）

//--- 部分利確設定
input bool     UsePartialClose   = true;        // 部分利確を使用
input double   Partial_Pips      = 10.0;        // 部分利確トリガー（含み益pips）
input double   Partial_Percent   = 50.0;        // 部分利確割合（%）

//--- 取引時間設定（サーバー時間）
input int      TradeStartHour    = 21;          // 取引開始時間（XMサーバー時間 21=日本時間4時頃）
input int      TradeEndHour      = 1;           // 取引終了時間（XMサーバー時間 1=日本時間8時頃）

//--- リスク管理
input double   MaxSpread_Pips    = 2.5;         // 最大スプレッド※3→2.5に縮小
input int      MaxPosPerPair     = 1;
input int      MaxTotalPositions = 7;

//--- ATRフィルター（高ボラ日はエントリーしない）
input bool     UseATRFilter      = true;
input int      ATR_Period        = 14;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H1;   // ATR計算時間足※D1→H1に変更（より敏感に）
input double   ATR_Threshold     = 1.5;

//--- ADXフィルター（レンジ確認）
input bool     UseADXFilter      = true;        // ADXフィルターを使用
input int      ADX_Period        = 14;          // ADX期間
input ENUM_TIMEFRAMES ADX_TF     = PERIOD_M15;  // ADX計算時間足
input double   ADX_MaxLevel      = 25.0;        // ADXがこの値以下ならレンジ判定

//--- 金曜スキップ（週末ギャップ対策）
input bool     SkipFriday        = true;

//--- 連敗制限
input bool     UseLossLimit      = true;
input int      MaxLossPerPairDay = 2;

//--- 許可口座
input string   AllowedAccounts   = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleRSI[];
int    handleATR[];
int    handleADX[];
bool   pairEnabled[];
bool   partialClosed[];        // 部分利確済みフラグ（ポジションごと）

//+------------------------------------------------------------------+
double GetMinLot() { return MicroMode ? 0.1 : 0.01; }

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(AllowedAccounts) > 0 && !IsAccountAllowed()) return INIT_FAILED;

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) return INIT_FAILED;

   ArrayResize(handleRSI, pairCount);
   ArrayResize(handleATR, pairCount);
   ArrayResize(handleADX, pairCount);
   ArrayResize(pairEnabled, pairCount);
   ArrayResize(partialClosed, pairCount);

   int enabledCount = 0;
   for(int i = 0; i < pairCount; i++) {
      StringTrimRight(pairs[i]);
      StringTrimLeft(pairs[i]);
      partialClosed[i] = false;
      if(!SymbolSelect(pairs[i], true)) { pairEnabled[i] = false; continue; }

      handleRSI[i] = iRSI(pairs[i], RSI_TF, RSIPeriod, RSIPrice);
      if(handleRSI[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }

      handleATR[i] = iATR(pairs[i], ATR_TF, ATR_Period);
      if(handleATR[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }

      if(UseADXFilter) {
         handleADX[i] = iADX(pairs[i], ADX_TF, ADX_Period);
         if(handleADX[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }
      } else {
         handleADX[i] = INVALID_HANDLE;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[MorningScalp V2] 初期化: %d/%d pairs, RSI(%d)x%d bars, ADX<%0.f, Time=%d-%d",
              enabledCount, pairCount, RSIPeriod, RSI_ConfirmBars,
              ADX_MaxLevel, TradeStartHour, TradeEndHour);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleRSI[i] != INVALID_HANDLE) IndicatorRelease(handleRSI[i]);
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
      if(handleADX[i] != INVALID_HANDLE) IndicatorRelease(handleADX[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 既存ポジションの管理（時間外でも実行 → 利益を逃さない）
   ManagePositions();

   // 取引時間チェック（新規エントリーのみ制限）
   if(!IsTradingTime()) return;

   // 金曜スキップ
   if(SkipFriday && IsFriday()) return;

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];

      if(!IsSpreadOK(sym)) continue;
      if(CountPositions(sym, magic) >= MaxPosPerPair) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;
      if(UseLossLimit && IsDailyLossLimitHit(i)) continue;
      if(UseATRFilter && IsHighVolatility(i)) continue;
      if(UseADXFilter && !IsRangeMarket(i)) continue;

      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
// ポジション管理: トレーリング / ブレイクイーブン / 部分利確
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];

      for(int p = PositionsTotal() - 1; p >= 0; p--) {
         ulong ticket = PositionGetTicket(p);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         double volume    = PositionGetDouble(POSITION_VOLUME);
         long   posType   = PositionGetInteger(POSITION_TYPE);
         double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
         int    digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double pipValue  = point * 10;
         double profit_pips = 0;

         if(posType == POSITION_TYPE_BUY) {
            double bid = SymbolInfoDouble(sym, SYMBOL_BID);
            profit_pips = (bid - openPrice) / pipValue;

            // ブレイクイーブン
            if(UseBreakEven && profit_pips >= BE_Trigger_Pips) {
               double newSL = NormalizeDouble(openPrice + BE_Offset_Pips * pipValue, digits);
               if(currentSL < newSL) {
                  ModifySL(ticket, newSL, currentTP, sym);
               }
            }

            // トレーリングストップ
            if(UseTrailing && profit_pips >= TrailStart_Pips) {
               double trailSL = NormalizeDouble(bid - TrailStep_Pips * pipValue, digits);
               if(trailSL > currentSL) {
                  ModifySL(ticket, trailSL, currentTP, sym);
               }
            }

            // 部分利確
            if(UsePartialClose && profit_pips >= Partial_Pips && !partialClosed[i]) {
               double closeLot = CalcPartialLot(volume, sym);
               if(closeLot > 0) {
                  PartialClose(ticket, closeLot, sym);
                  partialClosed[i] = true;
               }
            }
         }
         else if(posType == POSITION_TYPE_SELL) {
            double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
            profit_pips = (openPrice - ask) / pipValue;

            // ブレイクイーブン
            if(UseBreakEven && profit_pips >= BE_Trigger_Pips) {
               double newSL = NormalizeDouble(openPrice - BE_Offset_Pips * pipValue, digits);
               if(currentSL > newSL || currentSL == 0) {
                  ModifySL(ticket, newSL, currentTP, sym);
               }
            }

            // トレーリングストップ
            if(UseTrailing && profit_pips >= TrailStart_Pips) {
               double trailSL = NormalizeDouble(ask + TrailStep_Pips * pipValue, digits);
               if(trailSL < currentSL || currentSL == 0) {
                  ModifySL(ticket, trailSL, currentTP, sym);
               }
            }

            // 部分利確
            if(UsePartialClose && profit_pips >= Partial_Pips && !partialClosed[i]) {
               double closeLot = CalcPartialLot(volume, sym);
               if(closeLot > 0) {
                  PartialClose(ticket, closeLot, sym);
                  partialClosed[i] = true;
               }
            }
         }
      }

      // ポジションがなければ部分利確フラグリセット
      if(CountPositions(pairs[i], MagicBase + i) == 0)
         partialClosed[i] = false;
   }
}

//+------------------------------------------------------------------+
void ModifySL(ulong ticket, double newSL, double tp, string sym)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   req.action    = TRADE_ACTION_SLTP;
   req.position  = ticket;
   req.symbol    = sym;
   req.sl        = NormalizeDouble(newSL, digits);
   req.tp        = NormalizeDouble(tp, digits);

   OrderSend(req, res);
}

//+------------------------------------------------------------------+
double CalcPartialLot(double volume, string sym)
{
   double closeLot = volume * (Partial_Percent / 100.0);
   double stepLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   closeLot = MathFloor(closeLot / stepLot) * stepLot;

   // 残りロットが最小ロット未満にならないようチェック
   double remaining = volume - closeLot;
   if(remaining < minLot) return 0;
   if(closeLot < minLot) return 0;

   return closeLot;
}

//+------------------------------------------------------------------+
void PartialClose(ulong ticket, double closeLot, string sym)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // ポジション情報を取得
   if(!PositionSelectByTicket(ticket)) return;
   long posType = PositionGetInteger(POSITION_TYPE);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = closeLot;
   req.position     = ticket;
   req.type         = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
   req.deviation    = 10;
   req.magic        = (int)PositionGetInteger(POSITION_MAGIC);
   req.comment      = "MornScalp_Partial";
   req.type_filling = GetFillingMode(sym);

   OrderSend(req, res);
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
bool IsFriday()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 5);
}

//+------------------------------------------------------------------+
// ADXフィルター: ADXが閾値以下ならレンジ=トレードOK
//+------------------------------------------------------------------+
bool IsRangeMarket(int idx)
{
   if(handleADX[idx] == INVALID_HANDLE) return true;

   double adx[];
   ArraySetAsSeries(adx, true);
   if(CopyBuffer(handleADX[idx], 0, 1, 1, adx) < 1) return true;

   return (adx[0] < ADX_MaxLevel);
}

//+------------------------------------------------------------------+
// ATRフィルター: 当日ATRが直近平均の閾値倍を超えたらスキップ
//+------------------------------------------------------------------+
bool IsHighVolatility(int idx)
{
   if(handleATR[idx] == INVALID_HANDLE) return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR[idx], 0, 1, 21, atr) < 21) return false;

   double currentATR = atr[0];
   double sum = 0;
   for(int i = 1; i < 21; i++) sum += atr[i];
   double avgATR = sum / 20.0;

   if(avgATR <= 0) return false;
   return (currentATR > avgATR * ATR_Threshold);
}

//+------------------------------------------------------------------+
// ATR値を取得（動的TP/SL計算用）
//+------------------------------------------------------------------+
double GetATRValue(int idx)
{
   if(handleATR[idx] == INVALID_HANDLE) return 0;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR[idx], 0, 1, 1, atr) < 1) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipValue = point * 10;

   // RSI取得（確認本数分）
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleRSI[idx], 0, 1, RSI_ConfirmBars, rsi) < RSI_ConfirmBars) return;

   // RSI確認: 全本数が閾値を超えていることを要求（ダマシ排除）
   bool buySignal = true;
   bool sellSignal = true;
   for(int k = 0; k < RSI_ConfirmBars; k++) {
      if(rsi[k] >= RSI_LowerLine) buySignal = false;
      if(rsi[k] <= RSI_UpperLine) sellSignal = false;
   }

   // TP/SL計算
   double tp_pips, sl_pips;
   if(UseDynamicTPSL) {
      double atrVal = GetATRValue(idx);
      if(atrVal <= 0) return;
      // ATRをpipsに変換
      double atr_pips = atrVal / pipValue;
      tp_pips = atr_pips * TP_ATR_Multi;
      sl_pips = atr_pips * SL_ATR_Multi;
      // 最低値を設定（あまりに小さいTP/SLは避ける）
      tp_pips = MathMax(tp_pips, 5.0);
      sl_pips = MathMax(sl_pips, 3.0);
      // 最大値も制限（リスク管理）
      tp_pips = MathMin(tp_pips, 30.0);
      sl_pips = MathMin(sl_pips, 20.0);
   } else {
      tp_pips = TakeProfit_Pips;
      sl_pips = LossCut_Pips;
   }

   // === Buy: RSIが下限以下を連続確認 ===
   if(buySignal) {
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(ask - sl_pips * pipValue, digits);
      double tpPrice = NormalizeDouble(ask + tp_pips * pipValue, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[MorningScalp] BUY %s lot=%.2f RSI=%.1f TP=%.1f SL=%.1f pips",
                    sym, lot, rsi[0], tp_pips, sl_pips);
      }
      return;
   }

   // === Sell: RSIが上限以上を連続確認 ===
   if(sellSignal) {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(bid + sl_pips * pipValue, digits);
      double tpPrice = NormalizeDouble(bid - tp_pips * pipValue, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[MorningScalp] SELL %s lot=%.2f RSI=%.1f TP=%.1f SL=%.1f pips",
                    sym, lot, rsi[0], tp_pips, sl_pips);
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
// 1日あたりの負け回数を確認
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit(int idx)
{
   int magic = MagicBase + idx;
   string sym = pairs[idx];

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);

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

   return (losses >= MaxLossPerPairDay);
}
//+------------------------------------------------------------------+
