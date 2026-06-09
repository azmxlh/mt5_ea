//+------------------------------------------------------------------+
//| MorningScalp.mq5 - 朝スキャルピングEA（MT5マルチペア版）V3      |
//| 日本時間早朝のレンジ相場でRSI逆張り                              |
//| V3: 損大利小問題を根本修正 - クールダウン/広SL/浅TP/厳格フィルター |
//+------------------------------------------------------------------+
#property copyright "MorningScalp EA V3"
#property version   "3.00"
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
input int      RSIPeriod         = 14;          // RSI期間※6→14に変更（安定化）
input ENUM_APPLIED_PRICE RSIPrice = PRICE_CLOSE;
input int      RSI_UpperLine     = 70;          // RSI上限（売りシグナル）※75→70
input int      RSI_LowerLine     = 30;          // RSI下限（買いシグナル）※25→30
input ENUM_TIMEFRAMES RSI_TF     = PERIOD_M15;  // RSI計算時間足※M5→M15（ノイズ軽減）
input int      RSI_ConfirmBars   = 2;           // RSI確認本数

//--- TP/SL設定（ATRベース）
input bool     UseDynamicTPSL    = true;        // ATRベース動的TP/SLを使用
input double   TP_ATR_Multi      = 0.8;         // TP = ATR × この倍率※1.5→0.8（浅く確実に利確）
input double   SL_ATR_Multi      = 2.0;         // SL = ATR × この倍率※1.0→2.0（広く刈られにくく）
input double   TakeProfit_Pips   = 10.0;        // 固定TP（動的TP未使用時）
input double   LossCut_Pips      = 20.0;        // 固定SL（動的SL未使用時）※10→20

//--- トレーリングストップ設定
input bool     UseTrailing       = true;        // トレーリングストップを使用
input double   TrailStart_Pips   = 5.0;         // トレーリング開始※8→5（早めに追従）
input double   TrailStep_Pips    = 2.0;         // トレーリングステップ※3→2

//--- ブレイクイーブン設定
input bool     UseBreakEven      = true;        // ブレイクイーブンを使用
input double   BE_Trigger_Pips   = 3.0;         // BEトリガー※5→3（早めに建値移動）
input double   BE_Offset_Pips    = 0.5;         // BE時のオフセット※1→0.5

//--- 部分利確設定
input bool     UsePartialClose   = true;        // 部分利確を使用
input double   Partial_Pips      = 6.0;         // 部分利確トリガー※10→6
input double   Partial_Percent   = 50.0;        // 部分利確割合（%）

//--- 取引時間設定（サーバー時間）
input int      TradeStartHour    = 21;          // 取引開始時間
input int      TradeEndHour      = 1;           // 取引終了時間

//--- リスク管理
input double   MaxSpread_Pips    = 2.0;         // 最大スプレッド※2.5→2.0
input int      MaxPosPerPair     = 1;
input int      MaxTotalPositions = 5;           // 最大同時ポジション※7→5

//--- ATRフィルター
input bool     UseATRFilter      = true;
input int      ATR_Period        = 14;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_D1;   // ATR計算時間足※H1→D1に戻す（SLに余裕）
input double   ATR_Threshold     = 1.3;         // ATR倍率閾値※1.5→1.3（厳格化）

//--- ADXフィルター（レンジ確認）
input bool     UseADXFilter      = true;
input int      ADX_Period        = 14;
input ENUM_TIMEFRAMES ADX_TF     = PERIOD_M30;  // ADX計算時間足※M15→M30
input double   ADX_MaxLevel      = 20.0;        // ADXがこの値以下ならレンジ※25→20（厳格化）

//--- クールダウン設定（再エントリー暴走防止）
input bool     UseCooldown       = true;        // クールダウンを使用
input int      CooldownMinutes   = 60;          // SL後の再エントリー禁止時間（分）※重要

//--- ボリンジャーバンドフィルター（レンジ幅確認）
input bool     UseBBFilter       = true;        // BBフィルターを使用
input int      BB_Period         = 20;          // BB期間
input double   BB_MaxWidth_Pips  = 30.0;        // BB幅がこの値以下ならレンジ（pips）

//--- 金曜スキップ
input bool     SkipFriday        = true;

//--- 連敗制限
input bool     UseLossLimit      = true;
input int      MaxLossPerPairDay = 2;           // 1ペア1日あたりの最大負け回数

//--- 許可口座
input string   AllowedAccounts   = "";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleRSI[];
int    handleATR[];
int    handleADX[];
int    handleBB[];
bool   pairEnabled[];
bool   partialClosed[];
datetime lastLossTime[];         // 各ペアの最後のSL時刻（クールダウン用）

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
   ArrayResize(handleBB, pairCount);
   ArrayResize(pairEnabled, pairCount);
   ArrayResize(partialClosed, pairCount);
   ArrayResize(lastLossTime, pairCount);

   int enabledCount = 0;
   for(int i = 0; i < pairCount; i++) {
      StringTrimRight(pairs[i]);
      StringTrimLeft(pairs[i]);
      partialClosed[i] = false;
      lastLossTime[i] = 0;
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

      if(UseBBFilter) {
         handleBB[i] = iBands(pairs[i], RSI_TF, BB_Period, 0, 2.0, PRICE_CLOSE);
         if(handleBB[i] == INVALID_HANDLE) { pairEnabled[i] = false; continue; }
      } else {
         handleBB[i] = INVALID_HANDLE;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) return INIT_FAILED;
   PrintFormat("[MorningScalp V3] 初期化: %d/%d pairs, RSI(%d)x%d, ADX<%0.f, CD=%dmin",
              enabledCount, pairCount, RSIPeriod, RSI_ConfirmBars,
              ADX_MaxLevel, CooldownMinutes);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleRSI[i] != INVALID_HANDLE) IndicatorRelease(handleRSI[i]);
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
      if(handleADX[i] != INVALID_HANDLE) IndicatorRelease(handleADX[i]);
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 既存ポジションの管理（時間外でも実行）
   ManagePositions();

   // クールダウン時刻の更新（SLヒット検出）
   UpdateCooldownTimes();

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
      if(UseBBFilter && !IsNarrowBB(i)) continue;
      if(UseCooldown && IsCooldownActive(i)) continue;

      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
// クールダウン: 直近のSLヒットを検出して時刻を記録
//+------------------------------------------------------------------+
void UpdateCooldownTimes()
{
   if(!UseCooldown) return;

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];

      // 当日の履歴を確認
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime dayStart = StructToTime(dt);

      HistorySelect(dayStart, TimeCurrent());
      int total = HistoryDealsTotal();

      for(int j = total - 1; j >= 0; j--) {
         ulong ticket = HistoryDealGetTicket(j);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != sym) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) {
            datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            if(dealTime > lastLossTime[i]) {
               lastLossTime[i] = dealTime;
            }
            break; // 最新の負けだけ確認
         }
      }
   }
}

//+------------------------------------------------------------------+
bool IsCooldownActive(int idx)
{
   if(lastLossTime[idx] == 0) return false;
   return (TimeCurrent() - lastLossTime[idx] < CooldownMinutes * 60);
}

//+------------------------------------------------------------------+
// ボリンジャーバンド幅フィルター: バンド幅が狭い=レンジ
//+------------------------------------------------------------------+
bool IsNarrowBB(int idx)
{
   if(handleBB[idx] == INVALID_HANDLE) return true;

   double upper[], lower[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);

   if(CopyBuffer(handleBB[idx], 1, 1, 1, upper) < 1) return true; // Upper band
   if(CopyBuffer(handleBB[idx], 2, 1, 1, lower) < 1) return true; // Lower band

   double point = SymbolInfoDouble(pairs[idx], SYMBOL_POINT);
   double pipValue = point * 10;
   double bbWidth = (upper[0] - lower[0]) / pipValue;

   return (bbWidth <= BB_MaxWidth_Pips);
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

   if(!OrderSend(req, res)) {
      // SL変更失敗（許容）
   }
}

//+------------------------------------------------------------------+
double CalcPartialLot(double volume, string sym)
{
   double closeLot = volume * (Partial_Percent / 100.0);
   double stepLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   closeLot = MathFloor(closeLot / stepLot) * stepLot;

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

   if(!OrderSend(req, res)) {
      // 部分利確失敗（許容）
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
bool IsFriday()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 5);
}

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

   // RSI確認: 全本数が閾値を超えていることを要求
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
      double atr_pips = atrVal / pipValue;
      tp_pips = atr_pips * TP_ATR_Multi;
      sl_pips = atr_pips * SL_ATR_Multi;
      // 最低値・最大値を制限
      tp_pips = MathMax(tp_pips, 3.0);
      sl_pips = MathMax(sl_pips, 10.0);
      tp_pips = MathMin(tp_pips, 20.0);
      sl_pips = MathMin(sl_pips, 40.0);
   } else {
      tp_pips = TakeProfit_Pips;
      sl_pips = LossCut_Pips;
   }

   // === Buy ===
   if(buySignal) {
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = NormalizeDouble(ask - sl_pips * pipValue, digits);
      double tpPrice = NormalizeDouble(ask + tp_pips * pipValue, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[MorningScalp V3] BUY %s lot=%.2f RSI=%.1f TP=%.1f SL=%.1f",
                    sym, lot, rsi[0], tp_pips, sl_pips);
      }
      return;
   }

   // === Sell ===
   if(sellSignal) {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = NormalizeDouble(bid + sl_pips * pipValue, digits);
      double tpPrice = NormalizeDouble(bid - tp_pips * pipValue, digits);

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[MorningScalp V3] SELL %s lot=%.2f RSI=%.1f TP=%.1f SL=%.1f",
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
