//+------------------------------------------------------------------+
//| BBSigma_V2.mq5 - ボリンジャーバンド順張りEA + マーチンゲール     |
//| エントリー: エクスパンション + ±2σバンドタッチ + 実体大         |
//| 順行時: ピラミッディング（既存ロジック）                          |
//| 逆行時: マーチンゲール（ロット倍増ナンピン）                      |
//| 決済: マーチンゲール群がトータルプラスで全決済                    |
//| 複利対応 / マルチペア                                            |
//+------------------------------------------------------------------+
#property copyright "BBSigma V2 EA"
#property version   "1.00"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY,AUDJPY,NZDJPY,CADJPY,CHFJPY,EURGBP,EURAUD,EURNZD,EURCAD,EURCHF,GBPAUD,GBPNZD,GBPCAD,GBPCHF,AUDNZD,AUDCAD,AUDCHF,NZDCAD,NZDCHF,CADCHF";
input int      MagicBase         = 79000;

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
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H4;
input int      BB_Expand_Lookback = 8;
input double   BB_Body_Ratio     = 0.5;

//--- 安定エクスパンションフィルター
input bool     StableExpand_Enabled  = true;
input int      StableExpand_Bars     = 3;
input double   StableExpand_MinGrowth = 0.0;

//--- ピラミッティング設定（順行時）
input double   Pyramid_Sigma     = 0.3;
input double   LotHalving        = 0.5;
input int      MaxPyramid        = 5;

//--- マーチンゲール設定（逆行時）
input double   Martin_Multiplier = 2.0;         // マーチンゲールロット倍率
input int      Martin_MaxCount   = 5;           // マーチンゲール最大回数（0=無制限）
input double   Martin_Distance_Sigma = 1.0;     // ナンピン間隔（σ単位）
input double   Martin_MaxLot     = 10.0;        // マーチンゲール最大ロット

//--- 利確設定
input double   TakeProfit_Equity_Pct = 5.0;
input double   TakeProfit_Pair_Pct   = 0;
input double   StopLoss_Equity_Pct   = 0;
input double   StopLoss_Pair_Pct     = 0;

//--- 適応型利確設定
input bool     AdaptiveTP_Enabled       = true;
input double   AdaptiveTP_Max_Pct       = 30.0;
input double   AdaptiveTP_Min_Pct       = 5.0;
input int      AdaptiveTP_Lookback      = 50;
input double   AdaptiveTP_Expand_Mult   = 1.2;
input double   AdaptiveTP_Squeeze_Mult  = 0.9;
input bool     Bouge_Close           = false;

//--- Equity傾き損切り設定
input bool     EquitySlope_Enabled   = true;
input int      EquitySlope_Hours     = 4;
input int      EquitySlope_Count     = 4;
input int      EquitySlope_Cooldown_Days = 20;

//--- 異常相場フィルター設定
input bool     AbnormalMarket_Enabled = true;
input int      AbnormalMarket_ATR_Period = 14;
input double   AbnormalMarket_Mult   = 2.5;
input int      AbnormalMarket_Avg_Bars = 50;

//--- リスク管理
input double   MaxSpread_Pips    = 4.0;
input int      TradingStartHour  = 0;
input int      TradingEndHour    = 0;
input int      ReentryCooldown   = 8;

//--- 通貨エクスポージャー制限
input bool     Exposure_Enabled  = true;
input int      Exposure_MaxSameCcy = 1;

//--- 週末/月末決済設定
enum ENUM_CLOSE_MODE {
   CLOSE_MODE_OFF      = 0,
   CLOSE_MODE_WEEKLY   = 1,
   CLOSE_MODE_MONTHLY  = 2
};
input ENUM_CLOSE_MODE  CloseMode_Friday     = CLOSE_MODE_OFF;
input int              Friday_EOD_Hour      = 23;

//--- 損失制限
input double   MaxDailyLoss_Pct  = 0;
input double   MaxDrawdown_Pct   = 0;

//--- 連敗停止
input bool     BalanceSlope_Enabled  = false;
input double   BalanceSlope_Stop_Pct = 5.0;
input double   BalanceSlope_Resume_Pct = 2.0;

//--- Equityトレーリング決済
input bool     EquityTrail_Enabled   = false;
input double   EquityTrail_Drop_Pct  = 3.0;

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

// Balance下降検知用
double g_balanceHWM = 0;
bool   g_balanceHalt = false;

// Equityトレーリング決済用
double g_equityPeak = 0;

// Equity傾き損切り用
double g_equitySlopeHistory[];
datetime g_equitySlopeLastTime = 0;
datetime g_equitySlopeCutTime = 0;

// 異常相場フィルター用
int    handleATR[];

//+------------------------------------------------------------------+
double GetMinLot()
{
   return MicroMode ? 0.1 : 0.01;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsAccountAllowed()) {
      Print("[BBSigma_V2 ERROR] この口座では使用できません: ", AccountInfoInteger(ACCOUNT_LOGIN));
      return INIT_FAILED;
   }

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) {
      Print("[BBSigma_V2 ERROR] 通貨ペアが指定されていません");
      return INIT_FAILED;
   }

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

      if(!SymbolSelect(pairs[i], true)) {
         PrintFormat("[BBSigma_V2 WARN] シンボル選択失敗（スキップ）: %s", pairs[i]);
         handleBB[i] = INVALID_HANDLE;
         pairEnabled[i] = false;
         continue;
      }

      handleBB[i] = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(handleBB[i] == INVALID_HANDLE) {
         PrintFormat("[BBSigma_V2 WARN] BBインジケータ作成失敗（スキップ）: %s", pairs[i]);
         pairEnabled[i] = false;
         continue;
      }

      if(AbnormalMarket_Enabled) {
         handleATR[i] = iATR(pairs[i], BB_TF, AbnormalMarket_ATR_Period);
         if(handleATR[i] == INVALID_HANDLE) {
            PrintFormat("[BBSigma_V2 WARN] ATRインジケータ作成失敗（スキップ）: %s", pairs[i]);
            pairEnabled[i] = false;
            continue;
         }
      } else {
         handleATR[i] = INVALID_HANDLE;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) {
      Print("[BBSigma_V2 ERROR] 有効な通貨ペアがありません");
      return INIT_FAILED;
   }

   if(Decay_BaseBalance > 0)
      initialBalance = Decay_BaseBalance;
   else
      initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   highWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);
   g_balanceHWM = AccountInfoDouble(ACCOUNT_BALANCE);
   g_balanceHalt = false;
   g_equityPeak = 0;

   ArrayResize(g_equitySlopeHistory, 0);
   g_equitySlopeLastTime = 0;
   g_equitySlopeCutTime = 0;

   PrintFormat("[BBSigma_V2] 初期化完了: ペア=%d/%d, 複利=%s, BB(%d,%.1f) on %s, Martin=x%.1f",
              enabledCount, pairCount,
              CompoundMode ? "ON" : "OFF",
              BB_Period, BB_Deviation,
              EnumToString(BB_TF),
              Martin_Multiplier);

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
   }
}

//+------------------------------------------------------------------+
void OnTimer()
{
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
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > highWaterMark)
      highWaterMark = currentBalance;

   if(MaxDrawdown_Pct > 0 && IsMaxDrawdownExceeded()) return;
   if(g_ddHalt) return;

   // === エクイティ利確/損切り ===
   double effectiveTP_Pct = TakeProfit_Equity_Pct;
   if(AdaptiveTP_Enabled) {
      effectiveTP_Pct = CalcAdaptiveTP();
   }

   if(effectiveTP_Pct > 0 || StopLoss_Equity_Pct > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(balance > 0) {
         double gainPct = (equity - balance) / balance * 100.0;
         if(effectiveTP_Pct > 0 && gainPct >= effectiveTP_Pct) {
            PrintFormat("[BBSigma_V2] エクイティ利確: equity=%.0f, balance=%.0f, gain=+%.1f%%",
                       equity, balance, gainPct);
            CloseEverything();
            return;
         }
         if(StopLoss_Equity_Pct > 0 && gainPct <= -StopLoss_Equity_Pct) {
            PrintFormat("[BBSigma_V2] エクイティ損切り: equity=%.0f, balance=%.0f, loss=%.1f%%",
                       equity, balance, gainPct);
            CloseEverything();
            return;
         }
      }
   }

   // === Equityトレーリング決済 ===
   if(EquityTrail_Enabled && CountAllPositions() > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

      if(g_equityPeak == 0)
         g_equityPeak = balance;
      if(equity > g_equityPeak)
         g_equityPeak = equity;

      if(g_equityPeak > 0) {
         double dropPct = (g_equityPeak - equity) / g_equityPeak * 100.0;
         if(dropPct >= EquityTrail_Drop_Pct) {
            PrintFormat("[BBSigma_V2] Equityトレーリング決済: equity=%.0f, peak=%.0f, drop=%.1f%%",
                       equity, g_equityPeak, dropPct);
            CloseEverything();
            g_equityPeak = 0;
            g_balanceHWM = AccountInfoDouble(ACCOUNT_BALANCE);
            g_balanceHalt = false;
            return;
         }
      }
   } else if(CountAllPositions() == 0) {
      g_equityPeak = 0;
   }

   // === Equity傾き損切り ===
   if(EquitySlope_Enabled && CountAllPositions() > 0) {
      datetime now = TimeCurrent();
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(g_equitySlopeLastTime == 0 || (now - g_equitySlopeLastTime) >= EquitySlope_Hours * 3600) {
         int size = ArraySize(g_equitySlopeHistory);
         ArrayResize(g_equitySlopeHistory, size + 1);
         g_equitySlopeHistory[size] = equity;
         g_equitySlopeLastTime = now;

         int maxKeep = EquitySlope_Count + 1;
         if(ArraySize(g_equitySlopeHistory) > maxKeep) {
            int removeCount = ArraySize(g_equitySlopeHistory) - maxKeep;
            for(int s = 0; s < maxKeep; s++)
               g_equitySlopeHistory[s] = g_equitySlopeHistory[s + removeCount];
            ArrayResize(g_equitySlopeHistory, maxKeep);
         }

         if(ArraySize(g_equitySlopeHistory) >= EquitySlope_Count + 1) {
            bool allDecline = true;
            int histSize = ArraySize(g_equitySlopeHistory);
            for(int s = 1; s < histSize; s++) {
               if(g_equitySlopeHistory[s] >= g_equitySlopeHistory[s - 1]) {
                  allDecline = false;
                  break;
               }
            }
            if(allDecline) {
               PrintFormat("[BBSigma_V2] Equity傾き損切り: %d回連続下降", EquitySlope_Count);
               CloseEverything();
               ArrayResize(g_equitySlopeHistory, 0);
               g_equitySlopeLastTime = 0;
               g_equitySlopeCutTime = TimeCurrent();
               g_equityPeak = 0;
               g_balanceHWM = AccountInfoDouble(ACCOUNT_BALANCE);
               g_balanceHalt = false;
               return;
            }
         }
      }
   } else if(CountAllPositions() == 0 && ArraySize(g_equitySlopeHistory) > 0) {
      ArrayResize(g_equitySlopeHistory, 0);
      g_equitySlopeLastTime = 0;
   }

   // === Balance下降検知 ===
   if(BalanceSlope_Enabled) {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      if(bal > g_balanceHWM)
         g_balanceHWM = bal;

      if(g_balanceHWM > 0) {
         double balDropPct = (g_balanceHWM - bal) / g_balanceHWM * 100.0;
         double resumeThreshold = (BalanceSlope_Resume_Pct > 0) ? BalanceSlope_Resume_Pct : 0;

         if(!g_balanceHalt && balDropPct >= BalanceSlope_Stop_Pct) {
            g_balanceHalt = true;
            PrintFormat("[BBSigma_V2] Balance下降停止: balance=%.0f, HWM=%.0f, drop=%.1f%%",
                       bal, g_balanceHWM, balDropPct);
         }
         if(g_balanceHalt && balDropPct <= resumeThreshold) {
            g_balanceHalt = false;
            PrintFormat("[BBSigma_V2] Balance回復再開: balance=%.0f, HWM=%.0f", bal, g_balanceHWM);
         }
      }
   }

   // === 金曜決済ロジック ===
   bool isFridayActive = IsFridayCloseActive();
   if(isFridayActive && CountAllPositions() > 0) {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > bal) {
         PrintFormat("[BBSigma_V2] 金曜利確: equity=%.0f > balance=%.0f", eq, bal);
         CloseEverything();
         return;
      }
      MqlDateTime dtFri;
      TimeToStruct(TimeCurrent(), dtFri);
      if(dtFri.hour >= Friday_EOD_Hour) {
         PrintFormat("[BBSigma_V2] 金曜EOD決済: hour=%d >= %d", dtFri.hour, Friday_EOD_Hour);
         CloseEverything();
         return;
      }
   }

   bool dailyLossHit = (MaxDailyLoss_Pct > 0 && IsDailyLossExceeded());

   // === メインループ ===
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;

      int magic = MagicBase + i;
      string sym = pairs[i];

      // ポジション管理（利確・損切り・マーチンゲール決済）
      ManagePositions(sym, magic, i);

      if(dailyLossHit) continue;

      int posCount = CountPositions(sym, magic);
      if(posCount > 0) {
         // 既にポジションあり → ピラミッド or マーチンゲール判定
         CheckPyramidOrMartin(sym, magic, i, posCount);
         continue;
      }

      // 金曜日は新規エントリー禁止
      if(isFridayActive) continue;
      if(g_balanceHalt) continue;

      // Equity傾き損切り後のクールダウン
      if(EquitySlope_Cooldown_Days > 0 && g_equitySlopeCutTime > 0) {
         if(TimeCurrent() - g_equitySlopeCutTime < EquitySlope_Cooldown_Days * 86400) continue;
      }

      // 異常相場フィルター
      if(AbnormalMarket_Enabled && IsAbnormalMarket(sym, i)) continue;

      // 新規エントリー
      if(!IsNewBar(sym, i)) continue;
      if(!IsTradingHour()) continue;
      if(!IsSpreadOK(sym)) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;
      if(MaxActivePairs > 0 && CountActivePairs() >= MaxActivePairs) continue;

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
// エントリー: エクスパンション + ±2σバンドタッチ + 実体大
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);

   int needBars = BB_Expand_Lookback + StableExpand_Bars + 3;
   if(CopyBuffer(handleBB[idx], 0, 0, needBars, bb_mid) < needBars) return;
   if(CopyBuffer(handleBB[idx], 1, 0, needBars, bb_upper) < needBars) return;
   if(CopyBuffer(handleBB[idx], 2, 0, needBars, bb_lower) < needBars) return;

   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);

   // エクスパンション判定
   double bandWidth1 = bb_upper[1] - bb_lower[1];
   double avgWidth = 0;
   for(int k = 2; k < BB_Expand_Lookback + 2; k++) {
      avgWidth += bb_upper[k] - bb_lower[k];
   }
   avgWidth /= BB_Expand_Lookback;
   if(bandWidth1 <= avgWidth) return;

   // 安定エクスパンションフィルター
   if(StableExpand_Enabled) {
      bool stable = true;
      for(int s = 1; s < StableExpand_Bars; s++) {
         double bwCurrent = bb_upper[s] - bb_lower[s];
         double bwPrev    = bb_upper[s + 1] - bb_lower[s + 1];
         if(bwPrev <= 0) { stable = false; break; }
         double growth = (bwCurrent - bwPrev) / bwPrev;
         if(bwCurrent <= bwPrev || growth < StableExpand_MinGrowth) {
            stable = false;
            break;
         }
      }
      if(!stable) return;
   }

   // 実体サイズフィルター
   double bodySize = MathAbs(close1 - open1);
   if(BB_Body_Ratio > 0) {
      if(bodySize < bandWidth1 * BB_Body_Ratio) return;
   }

   double lot = CalcInitialLot(sym);

   // Buy条件
   if(close1 > open1 && close1 >= bb_upper[1]) {
      if(Exposure_Enabled && IsExposureExceeded(sym, 1)) return;
      OpenOrder(sym, ORDER_TYPE_BUY, lot, magic);
      return;
   }

   // Sell条件
   if(close1 < open1 && close1 <= bb_lower[1]) {
      if(Exposure_Enabled && IsExposureExceeded(sym, -1)) return;
      OpenOrder(sym, ORDER_TYPE_SELL, lot, magic);
      return;
   }
}

//+------------------------------------------------------------------+
// ピラミッディング or マーチンゲール判定
// 最初のポジションが含み益 → ピラミッド（順行）
// 最初のポジションが含み損 → マーチンゲール（逆行）
//+------------------------------------------------------------------+
void CheckPyramidOrMartin(string sym, int magic, int idx, int posCount)
{
   if(!IsSpreadOK(sym)) return;
   if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) return;

   // 最初のポジション（最古）の損益方向を確認
   double firstProfit = GetFirstPositionProfit(sym, magic);
   
   if(firstProfit >= 0) {
      // 順行中 → ピラミッディング
      CheckPyramid(sym, magic, idx, posCount);
   } else {
      // 逆行中 → マーチンゲール
      CheckMartingale(sym, magic, idx, posCount);
   }
}

//+------------------------------------------------------------------+
// ピラミッディング: +1σ超えてσ単位で追加（従来ロジック）
//+------------------------------------------------------------------+
void CheckPyramid(string sym, int magic, int idx, int posCount)
{
   if(MaxPyramid > 0 && posCount - 1 >= MaxPyramid) return;

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
   double sigmaWidth = (bb_upper[0] - bb_mid[0]) / BB_Deviation;
   double pyramidDistance = sigmaWidth * Pyramid_Sigma;

   double currentPrice;
   bool pyramidTrigger = false;

   if(direction == 1) {
      currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      pyramidTrigger = (currentPrice >= lastEntryPrice + pyramidDistance);
   } else {
      currentPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      pyramidTrigger = (currentPrice <= lastEntryPrice - pyramidDistance);
   }

   if(!pyramidTrigger) return;

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

   if(OpenOrder(sym, (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot, magic)) {
      PrintFormat("[BBSigma_V2][%s] ピラミッド #%d: %.2f lots", sym, pyramidCount + 1, lot);
   }
}

//+------------------------------------------------------------------+
// マーチンゲール: 逆行時にロット倍増でナンピン
// 最後のエントリーからσ単位で逆方向に離れたら追加
//+------------------------------------------------------------------+
void CheckMartingale(string sym, int magic, int idx, int posCount)
{
   // マーチンゲール回数制限チェック（最初の1ポジションを除く）
   int martinCount = posCount - 1;
   if(Martin_MaxCount > 0 && martinCount >= Martin_MaxCount) return;

   double bb_mid[], bb_upper[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);

   if(CopyBuffer(handleBB[idx], 0, 0, 1, bb_mid) < 1) return;
   if(CopyBuffer(handleBB[idx], 1, 0, 1, bb_upper) < 1) return;

   int direction = GetPositionDirection(sym, magic);
   if(direction == 0) return;

   double lastEntryPrice = GetLastEntryPrice(sym, magic);
   double sigmaWidth = (bb_upper[0] - bb_mid[0]) / BB_Deviation;
   double martinDistance = sigmaWidth * Martin_Distance_Sigma;

   double currentPrice;
   bool martinTrigger = false;

   // 逆方向に一定距離離れたらナンピン
   if(direction == 1) { // Buy保有中 → 価格が下落
      currentPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      martinTrigger = (currentPrice <= lastEntryPrice - martinDistance);
   } else { // Sell保有中 → 価格が上昇
      currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      martinTrigger = (currentPrice >= lastEntryPrice + martinDistance);
   }

   if(!martinTrigger) return;

   // ロット計算: 直前ロット × マーチンゲール倍率
   double lastLot = GetLastLot(sym, magic);
   double lot = lastLot * Martin_Multiplier;

   // 最大ロット制限（0=制限なし、ブローカー上限に依存）
   if(Martin_MaxLot > 0 && lot > Martin_MaxLot) lot = Martin_MaxLot;

   double minLot = GetMinLot();
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX));
   if(lot < minLot) return;

   // 同方向にナンピン（逆方向ではない）
   if(OpenOrder(sym, (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot, magic)) {
      PrintFormat("[BBSigma_V2][%s] マーチンゲール #%d: %.2f lots @ %.5f",
                 sym, martinCount + 1, lot, currentPrice);
   }
}

//+------------------------------------------------------------------+
// ポジション管理: マーチンゲール群がプラスなら決済 + ボージ決済
//+------------------------------------------------------------------+
void ManagePositions(string sym, int magic, int idx)
{
   int posCount = CountPositions(sym, magic);
   if(posCount == 0) return;

   // ペア単位の損切り判定
   if(StopLoss_Pair_Pct > 0) {
      double pairLoss = GetPairProfit(sym, magic);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > 0 && pairLoss < 0) {
         double lossPct = MathAbs(pairLoss) / balance * 100.0;
         if(lossPct >= StopLoss_Pair_Pct) {
            PrintFormat("[BBSigma_V2][%s] ペア損切り: loss=%.0f (%.1f%%)", sym, pairLoss, lossPct);
            CloseAllPairPositions(sym, magic);
            lastCloseTime[idx] = TimeCurrent();
            return;
         }
      }
   }

   // ペア全体の含み益
   double pairProfit = GetPairProfit(sym, magic);

   // ペア単位の利確判定
   if(TakeProfit_Pair_Pct > 0 && pairProfit > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > 0) {
         double gainPct = pairProfit / balance * 100.0;
         if(gainPct >= TakeProfit_Pair_Pct) {
            PrintFormat("[BBSigma_V2][%s] ペア利確: profit=%.0f (+%.1f%%)", sym, pairProfit, gainPct);
            CloseAllPairPositions(sym, magic);
            lastCloseTime[idx] = TimeCurrent();
            return;
         }
      }
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
         PrintFormat("[BBSigma_V2][%s] ボージ利確: profit=%.0f", sym, pairProfit);
      } else {
         PrintFormat("[BBSigma_V2][%s] ボージ損切り: profit=%.0f", sym, pairProfit);
      }
      CloseAllPairPositions(sym, magic);
      lastCloseTime[idx] = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
// ペアの合計損益を取得
//+------------------------------------------------------------------+
double GetPairProfit(string sym, int magic)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

//+------------------------------------------------------------------+
// 最初のポジション（最古）の含み損益を取得
//+------------------------------------------------------------------+
double GetFirstPositionProfit(string sym, int magic)
{
   datetime oldest = D'2099.01.01';
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t < oldest) {
         oldest = t;
         profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
// 最後のポジションのロットを取得
//+------------------------------------------------------------------+
double GetLastLot(string sym, int magic)
{
   datetime newest = 0;
   double lot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t > newest) { newest = t; lot = PositionGetDouble(POSITION_VOLUME); }
   }
   return lot;
}

//+------------------------------------------------------------------+
void CloseAllPairPositions(string sym, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      ClosePosition(ticket, sym, magic);
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
            PrintFormat("[BBSigma_V2 ERROR] 決済失敗: %s ticket=%d err=%d", sym, ticket, res.retcode);
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
bool OpenOrder(string sym, ENUM_ORDER_TYPE type, double lot, int magic)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = lot;
   req.type         = type;
   req.price        = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   req.deviation    = 30;
   req.magic        = magic;
   req.comment      = "BBSigma_V2";
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         if(!OrderSend(req, res)) {
            PrintFormat("[BBSigma_V2 ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
            return false;
         }
      } else {
         PrintFormat("[BBSigma_V2 ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
         return false;
      }
   }

   PrintFormat("[BBSigma_V2][%s] %s %.4f lots @ %.5f",
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
         PrintFormat("[BBSigma_V2 ALERT] DD=%.1f%% → 全決済＆停止", ddPct);
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
bool IsFridayCloseActive()
{
   if(CloseMode_Friday == CLOSE_MODE_OFF) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week != 5) return false;

   if(CloseMode_Friday == CLOSE_MODE_WEEKLY) return true;

   if(CloseMode_Friday == CLOSE_MODE_MONTHLY) {
      MqlDateTime dtNext;
      datetime nextWeek = TimeCurrent() + 7 * 24 * 60 * 60;
      TimeToStruct(nextWeek, dtNext);
      if(dtNext.mon != dt.mon) return true;
      return false;
   }

   return false;
}

//+------------------------------------------------------------------+
bool IsAbnormalMarket(string sym, int idx)
{
   if(handleATR[idx] == INVALID_HANDLE) return false;

   int needBars = AbnormalMarket_Avg_Bars + 1;
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(handleATR[idx], 0, 0, needBars, atr) < needBars) return false;

   double currentATR = atr[1];
   double avgATR = 0;
   for(int k = 2; k < needBars; k++) {
      avgATR += atr[k];
   }
   avgATR /= (needBars - 2);

   if(avgATR <= 0) return false;

   double ratio = currentATR / avgATR;
   if(ratio >= AbnormalMarket_Mult) {
      PrintFormat("[BBSigma_V2][%s] 異常相場検知: ATR=%.5f, 平均ATR=%.5f, 倍率=%.1f",
                 sym, currentATR, avgATR, ratio);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
bool IsExposureExceeded(string sym, int direction)
{
   string base = StringSubstr(sym, 0, 3);
   string quote = StringSubstr(sym, 3, 3);

   int baseExp = direction;
   int quoteExp = -direction;

   int baseCount = 0;
   int quoteCount = 0;

   int magicMax = MagicBase + pairCount - 1;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg < MagicBase || mg > magicMax) continue;

      string posSym = PositionGetString(POSITION_SYMBOL);
      int posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;

      string posBase = StringSubstr(posSym, 0, 3);
      string posQuote = StringSubstr(posSym, 3, 3);

      if(posBase == base && posDir == baseExp) baseCount++;
      if(posQuote == base && (-posDir) == baseExp) baseCount++;

      if(posBase == quote && posDir == quoteExp) quoteCount++;
      if(posQuote == quote && (-posDir) == quoteExp) quoteCount++;
   }

   if(baseCount >= Exposure_MaxSameCcy) return true;
   if(quoteCount >= Exposure_MaxSameCcy) return true;

   return false;
}

//+------------------------------------------------------------------+
double CalcAdaptiveTP()
{
   double totalRatio = 0;
   int activePairCount = 0;

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      if(handleBB[i] == INVALID_HANDLE) continue;

      int magic = MagicBase + i;
      if(CountPositions(pairs[i], magic) == 0) continue;

      double bb_upper[], bb_lower[];
      ArraySetAsSeries(bb_upper, true);
      ArraySetAsSeries(bb_lower, true);

      int needBars = AdaptiveTP_Lookback + 2;
      if(CopyBuffer(handleBB[i], 1, 0, needBars, bb_upper) < needBars) continue;
      if(CopyBuffer(handleBB[i], 2, 0, needBars, bb_lower) < needBars) continue;

      double currentBW = bb_upper[1] - bb_lower[1];

      double maxBW = 0;
      double avgBW = 0;
      for(int k = 2; k < needBars; k++) {
         double bw = bb_upper[k] - bb_lower[k];
         avgBW += bw;
         if(bw > maxBW) maxBW = bw;
      }
      avgBW /= AdaptiveTP_Lookback;

      if(maxBW <= 0) continue;

      double ratio = currentBW / maxBW;
      totalRatio += ratio;
      activePairCount++;
   }

   if(activePairCount == 0) return TakeProfit_Equity_Pct;

   double avgRatio = totalRatio / activePairCount;

   double tpPct;
   if(avgRatio >= AdaptiveTP_Expand_Mult) {
      tpPct = AdaptiveTP_Max_Pct;
   } else if(avgRatio <= AdaptiveTP_Squeeze_Mult) {
      tpPct = AdaptiveTP_Min_Pct;
   } else {
      double interpRatio = (avgRatio - AdaptiveTP_Squeeze_Mult) / (AdaptiveTP_Expand_Mult - AdaptiveTP_Squeeze_Mult);
      tpPct = AdaptiveTP_Min_Pct + interpRatio * (AdaptiveTP_Max_Pct - AdaptiveTP_Min_Pct);
   }

   return tpPct;
}
//+------------------------------------------------------------------+
