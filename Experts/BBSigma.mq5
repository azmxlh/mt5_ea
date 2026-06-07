//+------------------------------------------------------------------+
//| BBSigma.mq5 - ボリンジャーバンド順張りEA                         |
//| エントリー: エクスパンション + ±2σバンドタッチ + 実体大         |
//| 保持: バンドウォーク(±1σ〜±2σの間)                             |
//| 利確: バンドウォーク崩れ(±1σ割り込み) / 損切り: 中央線戻り     |
//| 複利対応 / マルチペア / ピラミッディング対応                      |
//+------------------------------------------------------------------+
#property copyright "BBSigma EA"
#property version   "2.00"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY,AUDJPY,NZDJPY,CADJPY,CHFJPY,EURGBP,EURAUD,EURNZD,EURCAD,EURCHF,GBPAUD,GBPNZD,GBPCAD,GBPCHF,AUDNZD,AUDCAD,AUDCHF,NZDCAD,NZDCHF,CADCHF";
input int      MagicBase         = 78000;

//--- 複利設定
input bool     CompoundMode      = true;
input double   BalancePerLot     = 100000;
input double   BaseLots          = 0.1;
input double   FixedLot          = 0.1;
input bool     MicroMode         = false;

//--- 複利逓減設定
input bool     Decay_Enabled     = true;
input double   Decay_Step        = 500000;
input double   Decay_Reduce      = 0.2;
input double   Decay_MinMulti    = 0.4;
input double   Decay_BaseBalance = 0;

//--- BB設定
input int      BB_Period         = 20;          // BB期間（=中央線MA期間）
input double   BB_Deviation      = 2.0;         // BB偏差
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H4;   // BB時間足
input int      BB_Expand_Lookback = 5;          // エクスパンション判定の過去本数
input double   BB_Body_Ratio     = 0.5;         // バンドタッチ足の実体/バンド幅比率(0=無効)

//--- ピラミッティング設定
input double   Pyramid_Sigma     = 0.3;         // 追加エントリー間隔(σ単位) +1σ超えてさらに+0.3σごとに追加
input double   LotHalving        = 0.5;         // ロット減少率
input int      MaxPyramid        = 0;           // 最大追加回数(0=無制限)

//--- 利確設定
input double   TakeProfit_Equity_Pct = 30.0;    // エクイティが残高のこの%上回ったら全決済(0=無効)
input double   StopLoss_Equity_Pct   = 0;    // エクイティが残高のこの%下回ったら全決済(0=無効)
input double   StopLoss_Pair_Pct     = 0;  // 通貨ペア単位の含み損が残高のこの%超えたらそのペア決済(0=無効)
input bool     Bouge_Close           = false;     // ボージ（トレンド終了）で決済する
input bool     OriginBase_SL         = false;     // 起点ベース損切り（含み損起点から残高10%で利確/起点に戻ったら損切り）

//--- リスク管理
input double   MaxSpread_Pips    = 4.0;
input int      TradingStartHour  = 0;
input int      TradingEndHour    = 0;
input int      ReentryCooldown   = 8;           // 決済後の再エントリー抑制(時間)

//--- 損失制限
input double   MaxDailyLoss_Pct  = 0;
input double   MaxDrawdown_Pct   = 0;

//--- 全体ポジション制限
input int      MaxTotalPositions  = 15;
input int      MaxActivePairs    = 0;

//--- 許可口座
input string   AllowedAccounts   = "75545335,70643523,75548484";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
bool   pairEnabled[];
double initialBalance = 0;
double highWaterMark  = 0;
datetime lastCloseTime[];
datetime lastBarTime[];
bool   g_ddHalt = false;

// 起点ベース損切り用
double g_equityBottom;     // 含み損の起点
bool   g_equityRecovered;  // 起点確定フラグ

//+------------------------------------------------------------------+
double GetMinLot()
{
   return MicroMode ? 0.1 : 0.01;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsAccountAllowed()) {
      Print("[BBSigma ERROR] この口座では使用できません: ", AccountInfoInteger(ACCOUNT_LOGIN));
      return INIT_FAILED;
   }

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) {
      Print("[BBSigma ERROR] 通貨ペアが指定されていません");
      return INIT_FAILED;
   }

   ArrayResize(handleBB, pairCount);
   ArrayResize(pairEnabled, pairCount);
   ArrayResize(lastCloseTime, pairCount);
   ArrayResize(lastBarTime, pairCount);
   ArrayInitialize(lastCloseTime, 0);
   ArrayInitialize(lastBarTime, 0);
   g_equityBottom = 0;
   g_equityRecovered = false;

   int enabledCount = 0;
   for(int i = 0; i < pairCount; i++) {
      StringTrimRight(pairs[i]);
      StringTrimLeft(pairs[i]);

      if(!SymbolSelect(pairs[i], true)) {
         PrintFormat("[BBSigma WARN] シンボル選択失敗（スキップ）: %s", pairs[i]);
         handleBB[i] = INVALID_HANDLE;
         pairEnabled[i] = false;
         continue;
      }

      handleBB[i] = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);

      if(handleBB[i] == INVALID_HANDLE) {
         PrintFormat("[BBSigma WARN] インジケータ作成失敗（スキップ）: %s", pairs[i]);
         pairEnabled[i] = false;
         continue;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) {
      Print("[BBSigma ERROR] 有効な通貨ペアがありません");
      return INIT_FAILED;
   }

   if(Decay_BaseBalance > 0)
      initialBalance = Decay_BaseBalance;
   else
      initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   highWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);

   PrintFormat("[BBSigma] 初期化完了: ペア=%d/%d, 複利=%s, BB(%d,%.1f) on %s",
              enabledCount, pairCount,
              CompoundMode ? "ON" : "OFF",
              BB_Period, BB_Deviation,
              EnumToString(BB_TF));

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
   }
}

//+------------------------------------------------------------------+
void OnTimer()
{
   // 他シンボルのSL管理を定期実行
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];
      if(CountPositions(sym, magic) > 0)
         ManagePositions(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 最高残高更新
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > highWaterMark)
      highWaterMark = currentBalance;

   // 全体ドローダウンチェック
   if(MaxDrawdown_Pct > 0 && IsMaxDrawdownExceeded()) return;
   if(g_ddHalt) return;

   // エクイティ利確: 残高に対してX%以上の含み益が出たら全決済
   if(TakeProfit_Equity_Pct > 0 || StopLoss_Equity_Pct > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(balance > 0) {
         double gainPct = (equity - balance) / balance * 100.0;
         if(TakeProfit_Equity_Pct > 0 && gainPct >= TakeProfit_Equity_Pct) {
            PrintFormat("[BBSigma] エクイティ利確: equity=%.0f, balance=%.0f, gain=+%.1f%%",
                       equity, balance, gainPct);
            CloseEverything();
            g_equityBottom = 0;
            g_equityRecovered = false;
            return;
         }
         if(StopLoss_Equity_Pct > 0 && gainPct <= -StopLoss_Equity_Pct) {
            PrintFormat("[BBSigma] エクイティ損切り: equity=%.0f, balance=%.0f, loss=%.1f%%",
                       equity, balance, gainPct);
            CloseEverything();
            g_equityBottom = 0;
            g_equityRecovered = false;
            return;
         }
      }
   }

   // 日次損失チェック
   bool dailyLossHit = (MaxDailyLoss_Pct > 0 && IsDailyLossExceeded());

   // === ダブルボトム損切り（含み損起点ベース） ===
   // 含み損が発生した点を起点として:
   //   利確: 起点から残高の10%伸びたら全決済
   //   損切り: 起点に戻ってきたら全決済
   if(OriginBase_SL && CountAllPositions() > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double unrealized = equity - balance;

      if(!g_equityRecovered) {
         // まだ起点が確定していない
         if(unrealized < 0 && g_equityBottom == 0) {
            // 初めて含み損になった → 起点を記録
            g_equityBottom = unrealized;
            g_equityRecovered = true;
         }
      } else {
         // 起点確定済み
         double targetProfit = g_equityBottom + balance * 0.10;  // 起点から残高10%上

         if(unrealized >= targetProfit) {
            // 利確: 起点から残高10%伸びた
            PrintFormat("[BBSigma] 起点ベース利確: unrealized=%.0f, target=%.0f, origin=%.0f",
                       unrealized, targetProfit, g_equityBottom);
            CloseEverything();
            g_equityBottom = 0;
            g_equityRecovered = false;
            return;
         }
         if(unrealized >= 0 && g_equityBottom < 0) {
            // 損切り: 起点(マイナス)から0に戻ってきた
            PrintFormat("[BBSigma] 起点ベース損切り: unrealized=%.0f, origin=%.0f",
                       unrealized, g_equityBottom);
            CloseEverything();
            g_equityBottom = 0;
            g_equityRecovered = false;
            return;
         }
      }
   } else if(CountAllPositions() == 0) {
      g_equityBottom = 0;
      g_equityRecovered = false;
   }

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;

      int magic = MagicBase + i;
      string sym = pairs[i];

      // ポジション管理 - 常に実行（利確・損切り）
      ManagePositions(sym, magic, i);

      // 損失制限到達
      if(dailyLossHit) continue;

      // 既存ポジション → ピラミッディング
      int posCount = CountPositions(sym, magic);
      if(posCount > 0) {
         CheckPyramid(sym, magic, i, posCount);
         continue;
      }

      // 新規エントリー（バー確定ベース）
      if(!IsNewBar(sym, i)) continue;
      if(!IsTradingHour()) continue;
      if(!IsSpreadOK(sym)) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;
      if(MaxActivePairs > 0 && CountActivePairs() >= MaxActivePairs) continue;

      // クールダウン
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
// エントリー: エクスパンション + ±2σバンドタッチ + 実体大の足
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);

   int needBars = BB_Expand_Lookback + 3;
   if(CopyBuffer(handleBB[idx], 0, 0, needBars, bb_mid) < needBars) return;
   if(CopyBuffer(handleBB[idx], 1, 0, needBars, bb_upper) < needBars) return;
   if(CopyBuffer(handleBB[idx], 2, 0, needBars, bb_lower) < needBars) return;

   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);

   // エクスパンション判定: 現在のバンド幅が直近N本の平均より大きい
   double bandWidth1 = bb_upper[1] - bb_lower[1];
   double avgWidth = 0;
   for(int k = 2; k < BB_Expand_Lookback + 2; k++) {
      avgWidth += bb_upper[k] - bb_lower[k];
   }
   avgWidth /= BB_Expand_Lookback;
   if(bandWidth1 <= avgWidth) return;  // エクスパンションなし → スキップ

   // 実体サイズフィルター
   double bodySize = MathAbs(close1 - open1);
   if(BB_Body_Ratio > 0) {
      if(bodySize < bandWidth1 * BB_Body_Ratio) return;  // 実体が小さい → スキップ
   }

   double lot = CalcInitialLot(sym);

   // Buy条件: 陽線 + 終値が+2σにタッチ（以上）
   if(close1 > open1 && close1 >= bb_upper[1]) {
      OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, 0);
      return;
   }

   // Sell条件: 陰線 + 終値が-2σにタッチ（以下）
   if(close1 < open1 && close1 <= bb_lower[1]) {
      OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, 0);
      return;
   }
}

//+------------------------------------------------------------------+
// ピラミッディング: +1σ超えてさらにσ単位で追加
//+------------------------------------------------------------------+
void CheckPyramid(string sym, int magic, int idx, int posCount)
{
   if(MaxPyramid > 0 && posCount - 1 >= MaxPyramid) return;
   if(!IsSpreadOK(sym)) return;
   if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) return;

   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);

   if(CopyBuffer(handleBB[idx], 0, 0, 1, bb_mid) < 1) return;
   if(CopyBuffer(handleBB[idx], 1, 0, 1, bb_upper) < 1) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 1, bb_lower) < 1) return;

   int direction = GetPositionDirection(sym, magic);
   if(direction == 0) return;

   double lastEntryPrice = GetLastEntryPrice(sym, magic);
   // σ1単位の幅を計算
   double sigmaWidth = (bb_upper[0] - bb_mid[0]) / BB_Deviation;
   double pyramidDistance = sigmaWidth * Pyramid_Sigma;

   double currentPrice;
   bool pyramidTrigger = false;

   if(direction == 1) { // Buy
      currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      pyramidTrigger = (currentPrice >= lastEntryPrice + pyramidDistance);
   } else { // Sell
      currentPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      pyramidTrigger = (currentPrice <= lastEntryPrice - pyramidDistance);
   }

   if(!pyramidTrigger) return;

   // ロット半減計算
   double initLot = GetFirstLot(sym, magic);
   int pyramidCount = posCount - 1;
   double lot = initLot * MathPow(LotHalving, pyramidCount + 1);

   double minLot = GetMinLot();
   if(lot < minLot) return;

   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX));
   if(lot < minLot) return;

   if(OpenOrder(sym, (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot, magic, 0)) {
      PrintFormat("[BBSigma][%s] ピラミッド #%d: %.2f lots", sym, pyramidCount + 1, lot);
   }
}

//+------------------------------------------------------------------+
// ポジション管理: ダブルボトム損切り + ボージ決済
//+------------------------------------------------------------------+
void ManagePositions(string sym, int magic, int idx)
{
   if(CountPositions(sym, magic) == 0) return;

   // ペア単位の損切り判定
   if(StopLoss_Pair_Pct > 0) {
      double pairLoss = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         pairLoss += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > 0 && pairLoss < 0) {
         double lossPct = MathAbs(pairLoss) / balance * 100.0;
         if(lossPct >= StopLoss_Pair_Pct) {
            PrintFormat("[BBSigma][%s] ペア損切り: loss=%.0f (%.1f%%)", sym, pairLoss, lossPct);
            for(int i = PositionsTotal() - 1; i >= 0; i--) {
               ulong ticket = PositionGetTicket(i);
               if(ticket == 0) continue;
               if(PositionGetString(POSITION_SYMBOL) != sym) continue;
               if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
               ClosePosition(ticket, sym, magic);
            }
            lastCloseTime[idx] = TimeCurrent();
            return;
         }
      }
   }

   // ペア全体の含み益を計算
   double pairProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      pairProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   // === ボージ決済 ===
   double bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);

   if(CopyBuffer(handleBB[idx], 1, 0, 3, bb_upper) < 3) return;
   if(CopyBuffer(handleBB[idx], 2, 0, 3, bb_lower) < 3) return;

   double bw0 = bb_upper[0] - bb_lower[0];
   double bw1 = bb_upper[1] - bb_lower[1];
   double bw2 = bb_upper[2] - bb_lower[2];

   if(Bouge_Close && bw0 < bw1 && bw1 < bw2) {
      if(pairProfit > 0) {
         PrintFormat("[BBSigma][%s] ボージ利確: profit=%.0f", sym, pairProfit);
      } else {
         PrintFormat("[BBSigma][%s] ボージ損切り: profit=%.0f", sym, pairProfit);
      }
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         ClosePosition(ticket, sym, magic);
      }
      lastCloseTime[idx] = TimeCurrent();
   }
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
   req.deviation    = 30;
   req.position     = ticket;
   req.magic        = magic;
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         if(!OrderSend(req, res))
            PrintFormat("[BBSigma ERROR] 決済失敗: %s ticket=%d err=%d", sym, ticket, res.retcode);
      }
   }
}

//+------------------------------------------------------------------+
double CalcInitialLot(string sym)
{
   if(!CompoundMode) return FixedLot;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot = (balance / BalancePerLot) * BaseLots;

   if(Decay_Enabled && Decay_Step > 0) {
      double baseBalance = (initialBalance > 0) ? initialBalance : balance;
      double growth = balance - baseBalance;
      if(growth > 0) {
         int steps = (int)MathFloor(growth / Decay_Step);
         double multiplier = 1.0 - (steps * Decay_Reduce);
         multiplier = MathMax(multiplier, Decay_MinMulti);
         lot = lot * multiplier;
      }
   }

   double minLot = GetMinLot();
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

//+------------------------------------------------------------------+
bool OpenOrder(string sym, ENUM_ORDER_TYPE type, double lot, int magic, double sl)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = lot;
   req.type         = type;
   req.price        = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   req.sl           = NormalizeDouble(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   req.deviation    = 30;
   req.magic        = magic;
   req.comment      = "BBSigma";
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         if(!OrderSend(req, res)) {
            PrintFormat("[BBSigma ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
            return false;
         }
      } else {
         PrintFormat("[BBSigma ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
         return false;
      }
   }

   PrintFormat("[BBSigma][%s] %s %.4f lots @ %.5f",
              sym, (type == ORDER_TYPE_BUY) ? "BUY" : "SELL", lot, res.price);
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
int CountActivePairs()
{
   int count = 0;
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      if(CountPositions(pairs[i], magic) > 0)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int GetPositionDirection(string sym, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
double GetFirstLot(string sym, int magic)
{
   datetime oldest = D'2099.01.01';
   double lot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t < oldest) { oldest = t; lot = PositionGetDouble(POSITION_VOLUME); }
   }
   return lot;
}

//+------------------------------------------------------------------+
double GetLastEntryPrice(string sym, int magic)
{
   datetime newest = 0;
   double price = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t > newest) { newest = t; price = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   return price;
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
bool IsDailyLossExceeded()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;
   double lossPct = (balance - equity) / balance * 100.0;
   return (lossPct >= MaxDailyLoss_Pct);
}

//+------------------------------------------------------------------+
bool IsMaxDrawdownExceeded()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(highWaterMark <= 0) return false;
   double ddPct = (highWaterMark - equity) / highWaterMark * 100.0;
   if(ddPct >= MaxDrawdown_Pct) {
      if(!g_ddHalt) {
         PrintFormat("[BBSigma ALERT] DD=%.1f%% → 全決済＆停止", ddPct);
         CloseEverything();
         g_ddHalt = true;
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseEverything()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];
      for(int j = PositionsTotal() - 1; j >= 0; j--) {
         ulong ticket = PositionGetTicket(j);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         ClosePosition(ticket, sym, magic);
      }
   }
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
