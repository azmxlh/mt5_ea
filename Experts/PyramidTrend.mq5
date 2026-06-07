//+------------------------------------------------------------------+
//| PyramidTrend.mq5 - ピラミッティング順張りEA V3                   |
//| ブレイクアウト型: BB外バンド突破 + 長期MA + 強ADXでエントリー     |
//| ATRベース追加エントリー / ロット半減 / トレーリングSL             |
//| 複利対応 / マルチペア / MicroMode対応                             |
//+------------------------------------------------------------------+
#property copyright "PyramidTrend EA"
#property version   "3.00"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY,AUDJPY,NZDJPY,CADJPY,CHFJPY,EURGBP,EURAUD,EURNZD,EURCAD,EURCHF,GBPAUD,GBPNZD,GBPCAD,GBPCHF,AUDNZD,AUDCAD,AUDCHF,NZDCAD,NZDCHF,CADCHF";
input int      MagicBase         = 77000;

//--- 複利設定
input bool     CompoundMode      = true;        // 複利モード
input double   BalancePerLot     = 100000;      // 1ロット単位あたりの必要残高(円)
input double   BaseLots          = 0.1;        // 複利計算の基準ロット
input double   FixedLot          = 0.1;        // 固定ロット（複利OFF時）
input bool     MicroMode         = false;       // Microモード(true=最小0.1lot)

//--- 複利逓減設定
input bool     Decay_Enabled     = true;
input double   Decay_Step        = 500000;
input double   Decay_Reduce      = 0.2;
input double   Decay_MinMulti    = 0.4;
input double   Decay_BaseBalance = 0;           // 0=起動時残高を自動使用

//--- MA設定（大トレンド方向判定）
input int      MA_Period         = 200;         // 200MA（長期トレンド）
input ENUM_TIMEFRAMES MA_TF      = PERIOD_H4;   // H4の200MA ≒ D1の50MA相当
input int      MA_HTF_Period     = 50;          // 上位足MAフィルター期間
input ENUM_TIMEFRAMES MA_HTF_TF  = PERIOD_D1;   // 上位足MA時間足
input bool     MA_HTF_Filter     = false;        // 上位足MAフィルター有効

//--- BB設定（ブレイクアウトトリガー）
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H4;   // H4 BBブレイクでエントリー
input int      BB_Squeeze_Lookback = 20;         // スクイーズ判定の過去本数
input double   BB_Squeeze_Ratio  = 0.8;          // バンド幅が平均のこの倍率以下ならスクイーズ
input double   BB_Break_Body_ATR = 0.3;          // ブレイク足の実体がATR×この倍率以上で有効(0=無効)

//--- ADX設定（トレンド強度フィルター）
input int      ADX_Period        = 14;
input double   ADX_Min           = 20.0;        // ADXがこの値以上でのみエントリー
input ENUM_TIMEFRAMES ADX_TF     = PERIOD_H4;   // H4 ADX

//--- ATR設定
input int      ATR_Period        = 14;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H4;   // H4 ATR

//--- ピラミッティング設定
input double   Pyramid_ATR_Multi = 1.5;         // 追加エントリー間隔(ATR倍率)
input double   LotHalving        = 0.5;         // ロット減少率(0.5=半減)
input int      MaxPyramid        = 0;           // 最大追加回数

//--- SL管理設定
input double   SL_Initial_ATR    = 2.0;         // 初期SL(ATR倍率) ※損切り
input double   SL_BE_Even_ATR    = 1.5;         // 含み益がこれ超えたら建値保護開始(ATR倍率)
input double   TrailingStop_ATR  = 1.5;         // 最高益からの許容戻し幅(ATR倍率) ※狭めて早めに利確
input double   SL_Emergency_Pct  = 0;         // 緊急損切り(建値からの%幅) 0=無効

//--- 利確設定
input double   TP_ATR_Multi      = 2.0;           // 利確目標(ATR倍率) 0=無効(トレーリングのみ)
input bool     TP_UseBBBand      = false;       // BB外バンド利確

//--- リスク管理
input double   MaxSpread_Pips    = 4.0;
input int      TradingStartHour  = 0;           // 0=制限なし(日足ベースなので不要)
input int      TradingEndHour    = 0;
input int      ReentryCooldown   = 12;          // 決済後の再エントリー抑制(時間)

//--- 損失制限
input double   MaxDailyLoss_Pct  = 0;           // 日次最大損失(残高の%) 0=無効
input double   MaxDrawdown_Pct   = 0;           // 全体最大ドローダウン(%) 0=無効

//--- 全体ポジション制限
input int      MaxTotalPositions  = 15;          // 全ポジション上限(0=無制限)
input int      MaxActivePairs    = 0;           // 同時エントリー通貨ペア数上限(0=無制限)

//--- 許可口座
input string   AllowedAccounts   = "75545335,70643523,75548484";

//--- 内部変数
string pairs[];
int    pairCount;
int    handleMA[];
int    handleMA_HTF[];
int    handleBB[];
int    handleATR[];
int    handleADX[];
bool   pairEnabled[];
double initialBalance = 0;
double highWaterMark  = 0;
datetime lastCloseTime[];
datetime lastBarTime[];

// ポジション毎の最高利益を記録（チケット番号→最高利益のマッピング）
#define MAX_TRACKED_POS 100
ulong  g_trackedTickets[MAX_TRACKED_POS];
double g_trackedHighProfit[MAX_TRACKED_POS];  // 各ポジションの最高含み益(価格差)
bool   g_trackedBEReached[MAX_TRACKED_POS];   // 建値ライン到達済みフラグ
int    g_trackedCount = 0;
bool   g_ddHalt = false;  // ドローダウン停止フラグ

//+------------------------------------------------------------------+
double GetMinLot()
{
   return MicroMode ? 0.1 : 0.01;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsAccountAllowed()) {
      Print("[PyramidTrend ERROR] この口座では使用できません: ", AccountInfoInteger(ACCOUNT_LOGIN));
      return INIT_FAILED;
   }

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) {
      Print("[PyramidTrend ERROR] 通貨ペアが指定されていません");
      return INIT_FAILED;
   }

   ArrayResize(handleMA, pairCount);
   ArrayResize(handleMA_HTF, pairCount);
   ArrayResize(handleBB, pairCount);
   ArrayResize(handleATR, pairCount);
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
         PrintFormat("[PyramidTrend WARN] シンボル選択失敗（スキップ）: %s", pairs[i]);
         handleMA[i] = INVALID_HANDLE;
         handleMA_HTF[i] = INVALID_HANDLE;
         handleBB[i] = INVALID_HANDLE;
         handleATR[i] = INVALID_HANDLE;
         handleADX[i] = INVALID_HANDLE;
         pairEnabled[i] = false;
         continue;
      }

      handleMA[i]  = iMA(pairs[i], MA_TF, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      handleMA_HTF[i] = iMA(pairs[i], MA_HTF_TF, MA_HTF_Period, 0, MODE_SMA, PRICE_CLOSE);
      handleBB[i]  = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      handleATR[i] = iATR(pairs[i], ATR_TF, ATR_Period);
      handleADX[i] = iADX(pairs[i], ADX_TF, ADX_Period);

      if(handleMA[i] == INVALID_HANDLE || handleMA_HTF[i] == INVALID_HANDLE || handleBB[i] == INVALID_HANDLE ||
         handleATR[i] == INVALID_HANDLE || handleADX[i] == INVALID_HANDLE) {
         PrintFormat("[PyramidTrend WARN] インジケータ作成失敗（スキップ）: %s", pairs[i]);
         if(handleMA[i] != INVALID_HANDLE) { IndicatorRelease(handleMA[i]); handleMA[i] = INVALID_HANDLE; }
         if(handleMA_HTF[i] != INVALID_HANDLE) { IndicatorRelease(handleMA_HTF[i]); handleMA_HTF[i] = INVALID_HANDLE; }
         if(handleBB[i] != INVALID_HANDLE) { IndicatorRelease(handleBB[i]); handleBB[i] = INVALID_HANDLE; }
         if(handleATR[i] != INVALID_HANDLE) { IndicatorRelease(handleATR[i]); handleATR[i] = INVALID_HANDLE; }
         if(handleADX[i] != INVALID_HANDLE) { IndicatorRelease(handleADX[i]); handleADX[i] = INVALID_HANDLE; }
         pairEnabled[i] = false;
         continue;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) {
      Print("[PyramidTrend ERROR] 有効な通貨ペアがありません");
      return INIT_FAILED;
   }

   if(Decay_BaseBalance > 0)
      initialBalance = Decay_BaseBalance;
   else
      initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   highWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);

   PrintFormat("[PyramidTrend V3] 初期化完了: ペア=%d/%d, 複利=%s, Micro=%s, 同時ペア上限=%d, ADX>%.0f, 日足BB突破エントリー",
              enabledCount, pairCount,
              CompoundMode ? "ON" : "OFF",
              MicroMode ? "ON" : "OFF",
              MaxActivePairs, ADX_Min);

   // タイマー: 1秒ごとに全ペアチェック（OnTickに依存しない）
   EventSetTimer(1);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < pairCount; i++) {
      if(handleMA[i] != INVALID_HANDLE) IndicatorRelease(handleMA[i]);
      if(handleMA_HTF[i] != INVALID_HANDLE) IndicatorRelease(handleMA_HTF[i]);
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
      if(handleADX[i] != INVALID_HANDLE) IndicatorRelease(handleADX[i]);
   }
}

//+------------------------------------------------------------------+
// OnTimer: OnTickが来ない他シンボルのSL管理を定期実行
//+------------------------------------------------------------------+
void OnTimer()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      int magic = MagicBase + i;
      string sym = pairs[i];
      if(CountPositions(sym, magic) > 0)
         ManageStopLoss(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // === 緊急安全装置: 全ポジション直接スキャン（最優先） ===
   EmergencyCheck();

   // 最高残高更新
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > highWaterMark)
      highWaterMark = currentBalance;

   // 全体ドローダウンチェック
   if(MaxDrawdown_Pct > 0 && IsMaxDrawdownExceeded()) return;

   // DD停止中は何もしない
   if(g_ddHalt) return;

   // 日次損失チェック
   bool dailyLossHit = (MaxDailyLoss_Pct > 0 && IsDailyLossExceeded());

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;

      int magic = MagicBase + i;
      string sym = pairs[i];

      // SL管理 - 常に実行
      ManageStopLoss(sym, magic, i);

      // 利確チェック - 常に実行
      CheckTakeProfit(sym, magic, i);

      // 損失制限到達
      if(dailyLossHit) continue;

      // 既存ポジション → ピラミッディング
      int posCount = CountPositions(sym, magic);
      if(posCount > 0) {
         CheckPyramid(sym, magic, i, posCount);
         continue;
      }

      // 新規エントリー（日足確定ベース）
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
// エントリー: 日足BBアッパー/ロワー突破 + 200MA方向一致 + ADXフィルター
//             + BBスクイーズからのブレイクアウトのみ
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double ma[], bb_upper[], bb_lower[], bb_mid[], atr[], adx[];
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(handleMA[idx], 0, 0, 2, ma) < 2) return;
   if(CopyBuffer(handleBB[idx], 0, 0, 3, bb_mid) < 3) return;
   if(CopyBuffer(handleBB[idx], 1, 0, BB_Squeeze_Lookback + 3, bb_upper) < BB_Squeeze_Lookback + 3) return;
   if(CopyBuffer(handleBB[idx], 2, 0, BB_Squeeze_Lookback + 3, bb_lower) < BB_Squeeze_Lookback + 3) return;
   if(CopyBuffer(handleATR[idx], 0, 0, 1, atr) < 1) return;
   if(CopyBuffer(handleADX[idx], 0, 0, 2, adx) < 2) return;

   // 上位足MAフィルター（日足MAの方向と一致しない場合はスキップ）
   bool htfBullish = true;
   bool htfBearish = true;
   if(MA_HTF_Filter) {
      double maHTF[];
      ArraySetAsSeries(maHTF, true);
      if(CopyBuffer(handleMA_HTF[idx], 0, 0, 2, maHTF) < 2) return;
      double close1_htf = iClose(sym, MA_HTF_TF, 1);
      htfBullish = (close1_htf > maHTF[1]);
      htfBearish = (close1_htf < maHTF[1]);
   }

   // ADXフィルター（前の確定足）
   if(adx[1] < ADX_Min) return;

   // BBスクイーズフィルター:
   // 直近のバンド幅が過去平均より狭い = ボラ収縮中からのブレイクのみ許可
   double bandWidthNow = bb_upper[1] - bb_lower[1];  // 前日のバンド幅
   double bandWidthAvg = 0;
   for(int k = 2; k < BB_Squeeze_Lookback + 2; k++) {
      bandWidthAvg += bb_upper[k] - bb_lower[k];
   }
   bandWidthAvg /= BB_Squeeze_Lookback;

   // スクイーズ判定: 直近バンド幅が平均の80%以下でないとエントリーしない
   if(bandWidthNow > bandWidthAvg * BB_Squeeze_Ratio) return;

   double close1 = iClose(sym, BB_TF, 1);  // 前日確定足
   double close2 = iClose(sym, BB_TF, 2);  // 2日前
   double open1  = iOpen(sym, BB_TF, 1);   // 前日始値

   // ブレイク足の実体サイズフィルター（ヒゲだけのブレイクを除外）
   if(BB_Break_Body_ATR > 0) {
      double bodySize = MathAbs(close1 - open1);
      if(bodySize < atr[0] * BB_Break_Body_ATR) return;
   }

   double lot = CalcInitialLot(sym);

   // 買いエントリー条件（スクイーズからのブレイクアウト）:
   // BB中央線が上向き + BB上バンドブレイク
   if(htfBullish && bb_mid[1] > bb_mid[2] && close1 > bb_upper[1] && close2 <= bb_upper[2] && close1 > ma[1] && close1 > open1) {
      OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, 0);
      return;
   }

   // 売りエントリー条件:
   // BB中央線が下向き + BB下バンドブレイク
   if(htfBearish && bb_mid[1] < bb_mid[2] && close1 < bb_lower[1] && close2 >= bb_lower[2] && close1 < ma[1] && close1 < open1) {
      OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, 0);
      return;
   }
}

//+------------------------------------------------------------------+
// ピラミッディング: 含み益ATR×N + ADX継続 + MA方向維持
//+------------------------------------------------------------------+
void CheckPyramid(string sym, int magic, int idx, int posCount)
{
   // 最大追加回数チェック（0=最小ロットまで無制限）
   if(MaxPyramid > 0 && posCount - 1 >= MaxPyramid) return;
   if(!IsSpreadOK(sym)) return;
   if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) return;

   double atr[], ma[], adx[];
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(adx, true);
   if(CopyBuffer(handleATR[idx], 0, 0, 1, atr) < 1) return;
   if(CopyBuffer(handleMA[idx], 0, 0, 1, ma) < 1) return;
   if(CopyBuffer(handleADX[idx], 0, 0, 1, adx) < 1) return;

   // ピラミッディングにもADXチェック（トレンド弱体化で追加しない）
   if(adx[0] < ADX_Min) return;

   double lastEntryPrice = GetLastEntryPrice(sym, magic);
   int direction = GetPositionDirection(sym, magic);
   if(direction == 0) return;

   double pyramidDistance = atr[0] * Pyramid_ATR_Multi;
   double currentPrice;
   bool pyramidTrigger = false;

   if(direction == 1) { // Buy
      currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      if(currentPrice <= ma[0]) return;  // MAの上を維持
      pyramidTrigger = (currentPrice >= lastEntryPrice + pyramidDistance);
   } else { // Sell
      currentPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(currentPrice >= ma[0]) return;  // MAの下を維持
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

   double sl = 0;

   if(OpenOrder(sym, (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot, magic, sl)) {
      PrintFormat("[PyramidTrend][%s] ピラミッド #%d: %.2f lots", sym, pyramidCount + 1, lot);
   }
}

//+------------------------------------------------------------------+
// SL管理: PositionGetDouble(POSITION_PROFIT)で判定
// POSITION_PRICE_CURRENTを使い、ATR取得失敗時はフォールバック
//+------------------------------------------------------------------+
void ManageStopLoss(string sym, int magic, int idx)
{
   // ATR取得（失敗時はフォールバック値を使用）
   double atrValue = 0;
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR[idx], 0, 0, 1, atr) >= 1 && atr[0] > 0) {
      atrValue = atr[0];
   } else {
      // フォールバック: 直近20本の高値-安値の平均で代替
      double highs[], lows[];
      ArraySetAsSeries(highs, true);
      ArraySetAsSeries(lows, true);
      int copied = CopyHigh(sym, ATR_TF, 0, 20, highs);
      int copied2 = CopyLow(sym, ATR_TF, 0, 20, lows);
      if(copied >= 5 && copied2 >= 5) {
         double sum = 0;
         int cnt = MathMin(copied, copied2);
         for(int k = 0; k < cnt; k++) sum += highs[k] - lows[k];
         atrValue = sum / cnt;
      }
      if(atrValue <= 0) {
         // 最終フォールバック: ポジションの建値の1%
         for(int k = PositionsTotal() - 1; k >= 0; k--) {
            ulong t = PositionGetTicket(k);
            if(t == 0) continue;
            if(PositionGetString(POSITION_SYMBOL) != sym) continue;
            if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
            atrValue = PositionGetDouble(POSITION_PRICE_OPEN) * 0.01;
            break;
         }
         if(atrValue <= 0) return;
      }
   }

   double beEvenThreshold = atrValue * SL_BE_Even_ATR;
   double trailingDist    = atrValue * TrailingStop_ATR;
   double slDistance      = atrValue * SL_Initial_ATR;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      // POSITION_PRICE_CURRENTを使用（MT5内部で管理されるため確実）
      double curPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(curPrice <= 0) continue;

      // 価格差計算
      double currentPriceDiff = 0;
      if(posType == POSITION_TYPE_BUY)
         currentPriceDiff = curPrice - openPrice;
      else
         currentPriceDiff = openPrice - curPrice;

      // トラッキング
      int tIdx = GetTrackingIndex(ticket);
      if(tIdx < 0) {
         tIdx = AddTracking(ticket);
         if(tIdx < 0) continue;
      }

      // 最高利益更新
      if(currentPriceDiff > g_trackedHighProfit[tIdx])
         g_trackedHighProfit[tIdx] = currentPriceDiff;

      // 建値到達チェック
      if(!g_trackedBEReached[tIdx] && g_trackedHighProfit[tIdx] >= beEvenThreshold)
         g_trackedBEReached[tIdx] = true;

      // === 決済判定 ===
      bool doClose = false;
      string reason = "";

      // 条件1: 建値到達済み & 建値以下に戻った
      if(g_trackedBEReached[tIdx] && currentPriceDiff <= 0) {
         doClose = true;
         reason = "建値決済";
      }

      // 条件2: トレーリング
      if(!doClose && g_trackedHighProfit[tIdx] >= trailingDist) {
         if(currentPriceDiff <= g_trackedHighProfit[tIdx] - trailingDist) {
            doClose = true;
            reason = "トレーリング";
         }
      }

      // 条件3: 損切り
      if(!doClose && currentPriceDiff <= -slDistance) {
         doClose = true;
         reason = "損切り";
      }

      if(doClose) {
         PrintFormat("[PyramidTrend][%s] %s: ticket=%d, diff=%.5f, high=%.5f, atr=%.5f",
                    sym, reason, ticket, currentPriceDiff, g_trackedHighProfit[tIdx], atrValue);
         ClosePosition(ticket, sym, magic);
         RemoveTracking(tIdx);
         if(CountPositions(sym, magic) == 0)
            lastCloseTime[idx] = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
// 緊急安全装置: MT5のPOSITION_PROFITで直接判定
// ATR計算やシンボル情報取得に頼らない最終手段
//+------------------------------------------------------------------+
void EmergencyCheck()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // このEAのポジションか確認
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg < MagicBase || mg > MagicBase + pairCount - 1) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice  = PositionGetDouble(POSITION_PRICE_CURRENT);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      if(curPrice <= 0 || openPrice <= 0) continue;

      // 含み益/損を価格差で計算
      double priceDiff = 0;
      if(posType == POSITION_TYPE_BUY)
         priceDiff = curPrice - openPrice;
      else
         priceDiff = openPrice - curPrice;

      // 損失が建値の指定%を超えたら強制損切り（ATRに依存しないフォールバック）
      if(SL_Emergency_Pct > 0) {
         double maxLoss = openPrice * SL_Emergency_Pct / 100.0;
         if(priceDiff <= -maxLoss) {
            PrintFormat("[PyramidTrend EMERGENCY][%s] 強制損切り: ticket=%d, open=%.5f, cur=%.5f, loss=%.5f(limit=%.5f)",
                       sym, ticket, openPrice, curPrice, priceDiff, -maxLoss);
            ClosePosition(ticket, sym, (int)mg);
         }
      }
   }
}

//+------------------------------------------------------------------+
// 個別ポジション決済
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
            PrintFormat("[PyramidTrend ERROR] 個別決済失敗: %s ticket=%d err=%d", sym, ticket, res.retcode);
      }
   } else {
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      PrintFormat("[PyramidTrend][%s] トレーリング決済: ticket=%d, 損益=%.0f", sym, ticket, profit);
   }
}

//+------------------------------------------------------------------+
// トラッキング管理
//+------------------------------------------------------------------+
int GetTrackingIndex(ulong ticket)
{
   for(int i = 0; i < g_trackedCount; i++) {
      if(g_trackedTickets[i] == ticket) return i;
   }
   return -1;
}

int AddTracking(ulong ticket)
{
   if(g_trackedCount >= MAX_TRACKED_POS) {
      // 古いエントリーをクリーンアップ
      CleanupTracking();
      if(g_trackedCount >= MAX_TRACKED_POS) return -1;
   }
   int idx = g_trackedCount;
   g_trackedTickets[idx]    = ticket;
   g_trackedHighProfit[idx] = 0;
   g_trackedBEReached[idx]  = false;
   g_trackedCount++;
   return idx;
}

void RemoveTracking(int idx)
{
   if(idx < 0 || idx >= g_trackedCount) return;
   // 最後の要素と入れ替えて削除
   g_trackedCount--;
   if(idx < g_trackedCount) {
      g_trackedTickets[idx]    = g_trackedTickets[g_trackedCount];
      g_trackedHighProfit[idx] = g_trackedHighProfit[g_trackedCount];
      g_trackedBEReached[idx]  = g_trackedBEReached[g_trackedCount];
   }
}

void CleanupTracking()
{
   // 既に存在しないポジションのトラッキングを削除
   for(int i = g_trackedCount - 1; i >= 0; i--) {
      if(!PositionSelectByTicket(g_trackedTickets[i])) {
         RemoveTracking(i);
      }
   }
}

//+------------------------------------------------------------------+
void CheckTakeProfit(string sym, int magic, int idx)
{
   if(CountPositions(sym, magic) == 0) return;

   int direction = GetPositionDirection(sym, magic);
   if(direction == 0) return;

   // ATRベース利確（設定されている場合のみ）
   if(TP_ATR_Multi > 0) {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(handleATR[idx], 0, 0, 1, atr) >= 1) {
         double avgPrice = GetAveragePrice(sym, magic);
         if(direction == 1) {
            double currentBid = SymbolInfoDouble(sym, SYMBOL_BID);
            if(currentBid >= avgPrice + atr[0] * TP_ATR_Multi)
            { CloseAllPositions(sym, magic, idx); return; }
         } else {
            double currentAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
            if(currentAsk <= avgPrice - atr[0] * TP_ATR_Multi)
            { CloseAllPositions(sym, magic, idx); return; }
         }
      }
   }

   // BBバンド利確
   if(TP_UseBBBand) {
      double bb_upper[], bb_lower[];
      ArraySetAsSeries(bb_upper, true);
      ArraySetAsSeries(bb_lower, true);
      if(CopyBuffer(handleBB[idx], 1, 0, 1, bb_upper) >= 1 &&
         CopyBuffer(handleBB[idx], 2, 0, 1, bb_lower) >= 1) {
         double avgPrice = GetAveragePrice(sym, magic);
         if(direction == 1) {
            double currentBid = SymbolInfoDouble(sym, SYMBOL_BID);
            if(currentBid >= bb_upper[0] && currentBid > avgPrice)
            { CloseAllPositions(sym, magic, idx); return; }
         } else {
            double currentAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
            if(currentAsk <= bb_lower[0] && currentAsk < avgPrice)
            { CloseAllPositions(sym, magic, idx); return; }
         }
      }
   }
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
      if(!g_ddHalt) {  // 一度だけ実行
         PrintFormat("[PyramidTrend ALERT] DD=%.1f%% (上限%.1f%%) → 全決済＆取引停止", ddPct, MaxDrawdown_Pct);
         CloseEverything();
         g_ddHalt = true;  // 以降の取引を完全停止
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
      if(CountPositions(pairs[i], magic) > 0)
         CloseAllPositions(pairs[i], magic, i);
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
   req.comment      = MicroMode ? "PyramidTrend_Micro" : "PyramidTrend";
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         if(!OrderSend(req, res)) {
            PrintFormat("[PyramidTrend ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
            return false;
         }
      } else {
         PrintFormat("[PyramidTrend ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
         return false;
      }
   }

   PrintFormat("[PyramidTrend][%s] %s %.4f lots @ %.5f SL=%.5f",
              sym, (type == ORDER_TYPE_BUY) ? "BUY" : "SELL", lot, res.price, sl);
   return true;
}

//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double sl, double tp)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   string sym = PositionGetString(POSITION_SYMBOL);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   req.action    = TRADE_ACTION_SLTP;
   req.position  = ticket;
   req.symbol    = sym;
   req.sl        = NormalizeDouble(sl, digits);
   req.tp        = NormalizeDouble(tp, digits);

   if(!OrderSend(req, res)) {
      if(res.retcode != 10025)
         PrintFormat("[PyramidTrend WARN] SL修正失敗: ticket=%d, err=%d", ticket, res.retcode);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void CloseAllPositions(string sym, int magic, int idx)
{
   double totalProfit = 0;
   int closed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

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
               PrintFormat("[PyramidTrend ERROR] 決済失敗: %s ticket=%d err=%d", sym, ticket, res.retcode);
            else closed++;
         } else {
            PrintFormat("[PyramidTrend ERROR] 決済失敗: %s ticket=%d err=%d", sym, ticket, res.retcode);
         }
      } else {
         closed++;
      }
   }

   if(closed > 0) {
      PrintFormat("[PyramidTrend][%s] 全決済: %dポジション, 損益=%.0f", sym, closed, totalProfit);
      lastCloseTime[idx] = TimeCurrent();
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
double GetAveragePrice(string sym, int magic)
{
   double totalLots = 0, totalCost = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      double lot = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      totalLots += lot;
      totalCost += lot * price;
   }
   return (totalLots > 0) ? totalCost / totalLots : 0;
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
