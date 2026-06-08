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
input int      BB_Expand_Lookback = 8;          // エクスパンション判定の過去本数
input double   BB_Body_Ratio     = 0.5;         // バンドタッチ足の実体/バンド幅比率(0=無効)

//--- 安定エクスパンションフィルター（バンド幅が安定拡大中のみエントリー）
input bool     StableExpand_Enabled  = true;    // 安定エクスパンションフィルター(有効/無効)
input int      StableExpand_Bars     = 3;       // バンド幅が連続拡大している必要がある本数
input double   StableExpand_MinGrowth = 0.0;    // 各バーの最小成長率(0=前バーより広ければOK)

//--- ピラミッティング設定
input double   Pyramid_Sigma     = 0.3;         // 追加エントリー間隔(σ単位) +1σ超えてさらに+0.3σごとに追加
input double   LotHalving        = 0.5;         // ロット減少率
input int      MaxPyramid        = 5;           // 最大追加回数(0=無制限)

//--- 利確設定
input double   TakeProfit_Equity_Pct = 5.0;    // エクイティが残高のこの%上回ったら全決済(0=無効)
input double   TakeProfit_Pair_Pct   = 0;     // 通貨ペア単位の含み益が残高のこの%超えたらそのペア利確(0=無効)
input double   StopLoss_Equity_Pct   = 0;       // エクイティが残高のこの%下回ったら全決済(0=無効)
input double   StopLoss_Pair_Pct     = 0;       // 通貨ペア単位の含み損が残高のこの%超えたらそのペア決済(0=無効)

//--- 適応型利確設定（BBバンド幅=トレンド強度に応じて利確%を動的に変更）
input bool     AdaptiveTP_Enabled       = true;     // 適応型利確(有効/無効)
input double   AdaptiveTP_Max_Pct       = 30.0;     // 強トレンド時の利確%(バンド幅が広い時)
input double   AdaptiveTP_Min_Pct       = 5.0;      // 弱トレンド時の利確%(バンド幅が狭い時)
input int      AdaptiveTP_Lookback      = 50;       // バンド幅の平均を計算する過去バー数
input double   AdaptiveTP_Expand_Mult   = 1.2;      // 平均の何倍以上で強トレンド判定
input double   AdaptiveTP_Squeeze_Mult  = 0.9;      // 平均の何倍以下で弱トレンド判定
input bool     Bouge_Close           = false;   // ボージ（トレンド終了）で決済する
input bool     OriginBase_SL         = false;   // 起点ベース損切り（含み損起点から残高10%で利確/起点に戻ったら損切り）

//--- Equity傾き損切り設定
input bool     EquitySlope_Enabled   = true;   // Equity傾き損切り（Equityが連続下降で全決済）
input int      EquitySlope_Hours     = 4;       // 判定間隔（時間）- この間隔でEquityを記録
input int      EquitySlope_Count     = 4;       // 連続下降回数 - この回数連続で下がったら損切り
input int      EquitySlope_Cooldown_Days = 20;   // 損切り後の新規エントリー禁止日数（0=無効）

//--- 異常相場フィルター設定
input bool     AbnormalMarket_Enabled = true;   // 異常相場フィルター（ATR急騰時にエントリー停止）
input int      AbnormalMarket_ATR_Period = 14;  // ATR期間
input double   AbnormalMarket_Mult   = 2.5;     // 直近ATRが平均ATRの何倍以上で異常と判定
input int      AbnormalMarket_Avg_Bars = 50;    // 平均ATR計算に使うバー数

//--- リスク管理
input double   MaxSpread_Pips    = 4.0;
input int      TradingStartHour  = 0;
input int      TradingEndHour    = 0;
input int      ReentryCooldown   = 8;           // 決済後の再エントリー抑制(時間)

//--- 通貨エクスポージャー制限
input bool     Exposure_Enabled  = true;        // 通貨エクスポージャー制限（同一通貨への偏り防止）
input int      Exposure_MaxSameCcy = 1;         // 同じ通貨に同方向で持てる最大ペア数

//--- 週末/月末決済設定
enum ENUM_CLOSE_MODE {
   CLOSE_MODE_OFF      = 0,   // Off（無効）
   CLOSE_MODE_WEEKLY   = 1,   // Weekly（毎週金曜）
   CLOSE_MODE_MONTHLY  = 2    // Monthly（月末最終金曜のみ）
};
input ENUM_CLOSE_MODE  CloseMode_Friday     = CLOSE_MODE_OFF;  // 金曜決済モード(Weekly/Monthly/Off)
input int              Friday_EOD_Hour      = 23;                 // 金曜強制決済の時刻(サーバー時間)

//--- 損失制限
input double   MaxDailyLoss_Pct  = 0;
input double   MaxDrawdown_Pct   = 0;

//--- 連敗停止（Balance下降検知）
input bool     BalanceSlope_Enabled  = false;    // Balance下降時の新規エントリー停止
input double   BalanceSlope_Stop_Pct = 5.0;     // 直近高値からこの%下がったら停止
input double   BalanceSlope_Resume_Pct = 2.0;   // 直近高値からこの%以内に回復したら再開(0=高値復帰で再開)

//--- Equityトレーリング決済
input bool     EquityTrail_Enabled   = false;    // Equityトレーリング決済(有効/無効)
input double   EquityTrail_Drop_Pct  = 3.0;     // Equityピークからこの%下落で全決済

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

// Balance下降検知用
double g_balanceHWM = 0;   // Balance高値（確定残高のHighWaterMark）
bool   g_balanceHalt = false;  // Balance下降による新規エントリー停止中

// Equityトレーリング決済用
double g_equityPeak = 0;       // ポジション保有中のEquity最高値

// Equity傾き損切り用
double g_equitySlopeHistory[];   // Equity記録用配列
datetime g_equitySlopeLastTime = 0;  // 最後に記録した時刻
datetime g_equitySlopeCutTime = 0;   // Equity傾き損切りが発動した時刻

// 異常相場フィルター用
int    handleATR[];  // ATRインジケータハンドル

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
   ArrayResize(handleATR, pairCount);
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
         PrintFormat("[BBSigma WARN] BBインジケータ作成失敗（スキップ）: %s", pairs[i]);
         pairEnabled[i] = false;
         continue;
      }

      // ATRハンドル作成
      if(AbnormalMarket_Enabled) {
         handleATR[i] = iATR(pairs[i], BB_TF, AbnormalMarket_ATR_Period);
         if(handleATR[i] == INVALID_HANDLE) {
            PrintFormat("[BBSigma WARN] ATRインジケータ作成失敗（スキップ）: %s", pairs[i]);
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
      Print("[BBSigma ERROR] 有効な通貨ペアがありません");
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

   // Equity傾き損切り用初期化
   ArrayResize(g_equitySlopeHistory, 0);
   g_equitySlopeLastTime = 0;
   g_equitySlopeCutTime = 0;

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
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
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
   // 適応型利確が有効な場合、直近勝率に応じて利確%を動的に算出
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
            PrintFormat("[BBSigma] エクイティ利確: equity=%.0f, balance=%.0f, gain=+%.1f%% (TP=%.1f%%)",
                       equity, balance, gainPct, effectiveTP_Pct);
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

   // === Equityトレーリング決済 ===
   // ポジション保有中のEquityピークを常に追跡し、ピークから一定%下落で全決済
   if(EquityTrail_Enabled && CountAllPositions() > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

      // ピーク初期値はBalance（ポジション取得直後のベースライン）
      if(g_equityPeak == 0)
         g_equityPeak = balance;

      // Equityピーク更新
      if(equity > g_equityPeak)
         g_equityPeak = equity;

      // ピークからの下落で全決済（利益方向でも損失方向でも発動）
      if(g_equityPeak > 0) {
         double dropPct = (g_equityPeak - equity) / g_equityPeak * 100.0;
         if(dropPct >= EquityTrail_Drop_Pct) {
            PrintFormat("[BBSigma] Equityトレーリング決済: equity=%.0f, peak=%.0f, drop=%.1f%%",
                       equity, g_equityPeak, dropPct);
            CloseEverything();
            g_equityPeak = 0;
            g_equityBottom = 0;
            g_equityRecovered = false;
            // Balance HWMをリセットして新規エントリー停止を防ぐ
            g_balanceHWM = AccountInfoDouble(ACCOUNT_BALANCE);
            g_balanceHalt = false;
            return;
         }
      }
   } else if(CountAllPositions() == 0) {
      // ポジションなし → リセット
      g_equityPeak = 0;
   }

   // === Equity傾き損切り ===
   // 一定時間間隔でEquityを記録し、連続下降が続いたら全決済
   if(EquitySlope_Enabled && CountAllPositions() > 0) {
      datetime now = TimeCurrent();
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);

      // 初回または間隔経過で記録
      if(g_equitySlopeLastTime == 0 || (now - g_equitySlopeLastTime) >= EquitySlope_Hours * 3600) {
         int size = ArraySize(g_equitySlopeHistory);
         ArrayResize(g_equitySlopeHistory, size + 1);
         g_equitySlopeHistory[size] = equity;
         g_equitySlopeLastTime = now;

         // 必要な記録数を超えたら古いものを削除
         int maxKeep = EquitySlope_Count + 1;
         if(ArraySize(g_equitySlopeHistory) > maxKeep) {
            int removeCount = ArraySize(g_equitySlopeHistory) - maxKeep;
            for(int s = 0; s < maxKeep; s++)
               g_equitySlopeHistory[s] = g_equitySlopeHistory[s + removeCount];
            ArrayResize(g_equitySlopeHistory, maxKeep);
         }

         // 連続下降チェック
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
               PrintFormat("[BBSigma] Equity傾き損切り: %d回連続下降 (%.0f → %.0f)",
                          EquitySlope_Count,
                          g_equitySlopeHistory[0],
                          g_equitySlopeHistory[histSize - 1]);
               CloseEverything();
               ArrayResize(g_equitySlopeHistory, 0);
               g_equitySlopeLastTime = 0;
               g_equitySlopeCutTime = TimeCurrent();  // クールダウン開始
               g_equityPeak = 0;
               g_equityBottom = 0;
               g_equityRecovered = false;
               g_balanceHWM = AccountInfoDouble(ACCOUNT_BALANCE);
               g_balanceHalt = false;
               return;
            }
         }
      }
   } else if(CountAllPositions() == 0 && ArraySize(g_equitySlopeHistory) > 0) {
      // ポジションなし → 記録リセット
      ArrayResize(g_equitySlopeHistory, 0);
      g_equitySlopeLastTime = 0;
   }

   // === Balance下降検知（新規エントリー停止） ===
   if(BalanceSlope_Enabled) {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      if(bal > g_balanceHWM)
         g_balanceHWM = bal;

      if(g_balanceHWM > 0) {
         double balDropPct = (g_balanceHWM - bal) / g_balanceHWM * 100.0;
         double resumeThreshold = (BalanceSlope_Resume_Pct > 0) ? BalanceSlope_Resume_Pct : 0;

         if(!g_balanceHalt && balDropPct >= BalanceSlope_Stop_Pct) {
            g_balanceHalt = true;
            PrintFormat("[BBSigma] Balance下降停止: balance=%.0f, HWM=%.0f, drop=%.1f%%",
                       bal, g_balanceHWM, balDropPct);
         }
         if(g_balanceHalt && balDropPct <= resumeThreshold) {
            g_balanceHalt = false;
            PrintFormat("[BBSigma] Balance回復再開: balance=%.0f, HWM=%.0f, drop=%.1f%%",
                       bal, g_balanceHWM, balDropPct);
         }
      }
   }

   // === 金曜決済ロジック ===
   bool isFridayActive = IsFridayCloseActive();
   if(isFridayActive && CountAllPositions() > 0) {
      // 金曜日: 残高全体で利益が出ていればすべて決済
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > bal) {
         PrintFormat("[BBSigma] 金曜利確: equity=%.0f > balance=%.0f (mode=%s)",
                    eq, bal, EnumToString(CloseMode_Friday));
         CloseEverything();
         g_equityBottom = 0;
         g_equityRecovered = false;
         return;
      }
      // 金曜日: サーバー時間指定時刻以降にポジションが残っていれば全決済
      MqlDateTime dtFri;
      TimeToStruct(TimeCurrent(), dtFri);
      if(dtFri.hour >= Friday_EOD_Hour) {
         PrintFormat("[BBSigma] 金曜EOD決済: hour=%d >= %d (mode=%s)",
                    dtFri.hour, Friday_EOD_Hour, EnumToString(CloseMode_Friday));
         CloseEverything();
         g_equityBottom = 0;
         g_equityRecovered = false;
         return;
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

      // 既存ポジション → ピラミッディング（金曜日も追加は許可）
      int posCount = CountPositions(sym, magic);
      if(posCount > 0) {
         CheckPyramid(sym, magic, i, posCount);
         continue;
      }

      // 金曜日は新規エントリー禁止
      if(isFridayActive) continue;

      // Balance下降中は新規エントリー禁止
      if(g_balanceHalt) continue;

      // Equity傾き損切り後のクールダウン中は新規エントリー禁止
      if(EquitySlope_Cooldown_Days > 0 && g_equitySlopeCutTime > 0) {
         if(TimeCurrent() - g_equitySlopeCutTime < EquitySlope_Cooldown_Days * 86400) continue;
      }

      // 異常相場フィルター（ATRが通常の何倍も大きい場合はスキップ）
      if(AbnormalMarket_Enabled && IsAbnormalMarket(sym, i)) continue;

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

      // 通貨エクスポージャー制限（CheckEntry内で方向判定前にシンボル単位でチェック）
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

   int needBars = BB_Expand_Lookback + StableExpand_Bars + 3;
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

   // 安定エクスパンションフィルター: バンド幅が連続して拡大中であることを確認
   // フェイクアウト防止 — 拡大→縮小→拡大を繰り返す不安定なボラ環境を回避
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
      if(!stable) return;  // バンド幅が安定拡大していない → スキップ
   }

   // 実体サイズフィルター
   double bodySize = MathAbs(close1 - open1);
   if(BB_Body_Ratio > 0) {
      if(bodySize < bandWidth1 * BB_Body_Ratio) return;  // 実体が小さい → スキップ
   }

   double lot = CalcInitialLot(sym);

   // Buy条件: 陽線 + 終値が+2σにタッチ（以上）
   if(close1 > open1 && close1 >= bb_upper[1]) {
      if(Exposure_Enabled && IsExposureExceeded(sym, 1)) return;
      OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, 0);
      return;
   }

   // Sell条件: 陰線 + 終値が-2σにタッチ（以下）
   if(close1 < open1 && close1 <= bb_lower[1]) {
      if(Exposure_Enabled && IsExposureExceeded(sym, -1)) return;
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
            CloseAllPairPositions(sym, magic);
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

   // ペア単位の利確判定
   if(TakeProfit_Pair_Pct > 0 && pairProfit > 0) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > 0) {
         double gainPct = pairProfit / balance * 100.0;
         if(gainPct >= TakeProfit_Pair_Pct) {
            PrintFormat("[BBSigma][%s] ペア利確: profit=%.0f (+%.1f%%)", sym, pairProfit, gainPct);
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
         PrintFormat("[BBSigma][%s] ボージ利確: profit=%.0f", sym, pairProfit);
      } else {
         PrintFormat("[BBSigma][%s] ボージ損切り: profit=%.0f", sym, pairProfit);
      }
      CloseAllPairPositions(sym, magic);
      lastCloseTime[idx] = TimeCurrent();
   }
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
// 金曜決済が有効かどうか判定
// CLOSE_MODE_WEEKLY: 毎週金曜日
// CLOSE_MODE_MONTHLY: その月の最終金曜日のみ
// CLOSE_MODE_OFF: 常にfalse
//+------------------------------------------------------------------+
bool IsFridayCloseActive()
{
   if(CloseMode_Friday == CLOSE_MODE_OFF) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week != 5) return false;  // 金曜日でなければfalse

   if(CloseMode_Friday == CLOSE_MODE_WEEKLY) return true;

   // CLOSE_MODE_MONTHLY: 月末最終金曜日かチェック
   // 今日が月の最終金曜日 = 今日+7日が翌月になる
   if(CloseMode_Friday == CLOSE_MODE_MONTHLY) {
      MqlDateTime dtNext;
      datetime nextWeek = TimeCurrent() + 7 * 24 * 60 * 60;
      TimeToStruct(nextWeek, dtNext);
      // 7日後の月が今日の月と異なれば、今日が最終金曜日
      if(dtNext.mon != dt.mon) return true;
      return false;
   }

   return false;
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// 異常相場判定: 直近ATRが平均ATRの指定倍数を超えたら異常
//+------------------------------------------------------------------+
bool IsAbnormalMarket(string sym, int idx)
{
   if(handleATR[idx] == INVALID_HANDLE) return false;

   int needBars = AbnormalMarket_Avg_Bars + 1;
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(handleATR[idx], 0, 0, needBars, atr) < needBars) return false;

   // 直近ATR（1本前の確定足）
   double currentATR = atr[1];

   // 過去の平均ATR（2本前〜Avg_Bars+1本前）
   double avgATR = 0;
   for(int k = 2; k < needBars; k++) {
      avgATR += atr[k];
   }
   avgATR /= (needBars - 2);

   if(avgATR <= 0) return false;

   double ratio = currentATR / avgATR;
   if(ratio >= AbnormalMarket_Mult) {
      PrintFormat("[BBSigma][%s] 異常相場検知: ATR=%.5f, 平均ATR=%.5f, 倍率=%.1f",
                 sym, currentATR, avgATR, ratio);
      return true;
   }

   return false;
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// 通貨エクスポージャー判定
// 新規エントリーしようとしているペアの各通貨について、
// 既存ポジションで同方向のエクスポージャーが最大数を超えていたらtrue
//
// 例: USDJPY BUY → USD買い・JPY売り
//     既にEURJPY SELL(JPY買い方向ではない→JPY売り方向)を持っている場合は
//     JPY売り方向がカウントされる
//+------------------------------------------------------------------+
bool IsExposureExceeded(string sym, int direction)
{
   // シンボルからベース通貨とクオート通貨を抽出（6文字ペア前提）
   string base = StringSubstr(sym, 0, 3);
   string quote = StringSubstr(sym, 3, 3);

   // この新規エントリーが各通貨にどの方向のエクスポージャーを与えるか
   // BUY: base買い(+1), quote売り(-1)
   // SELL: base売り(-1), quote買い(+1)
   // baseExposure: +1=買い, -1=売り
   int baseExp = direction;      // BUY(+1)ならbase買い、SELL(-1)ならbase売り
   int quoteExp = -direction;    // BUY(+1)ならquote売り、SELL(-1)ならquote買い

   // 既存ポジションから各通貨のエクスポージャーをカウント
   // カウント方法: 同じ通貨が同じ方向に何ペア分使われているか
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

      // そのポジションがbase通貨に与える方向
      // posBase方向: posDir, posQuote方向: -posDir
      
      // baseのチェック: 既存ポジションがbase通貨を同方向で使っている
      if(posBase == base && posDir == baseExp) baseCount++;
      if(posQuote == base && (-posDir) == baseExp) baseCount++;

      // quoteのチェック: 既存ポジションがquote通貨を同方向で使っている
      if(posBase == quote && posDir == quoteExp) quoteCount++;
      if(posQuote == quote && (-posDir) == quoteExp) quoteCount++;
   }

   if(baseCount >= Exposure_MaxSameCcy) {
      PrintFormat("[BBSigma][%s] エクスポージャー制限: %s方向が%d/%d超過",
                 sym, base, baseCount, Exposure_MaxSameCcy);
      return true;
   }
   if(quoteCount >= Exposure_MaxSameCcy) {
      PrintFormat("[BBSigma][%s] エクスポージャー制限: %s方向が%d/%d超過",
                 sym, quote, quoteCount, Exposure_MaxSameCcy);
      return true;
   }

   return false;
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// 適応型利確: BBバンド幅（トレンド強度）に応じて利確%を動的に計算
// ポジション保有中のペアについて、現在のバンド幅とエントリー時のバンド幅を比較
// バンドが維持/拡大 → トレンド継続 → 利確%を大きく
// バンドが収縮 → トレンド減衰 → 利確%を小さく（早めに利確）
//+------------------------------------------------------------------+
double CalcAdaptiveTP()
{
   // ポジションを持っているペアのバンド幅の「変化率」を見る
   // 直近のバンド幅が、過去平均のピーク時と比べてどれだけ維持されているか
   double totalRatio = 0;
   int activePairCount = 0;

   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;
      if(handleBB[i] == INVALID_HANDLE) continue;

      int magic = MagicBase + i;
      if(CountPositions(pairs[i], magic) == 0) continue;

      // 過去のバンド幅を取得
      double bb_upper[], bb_lower[];
      ArraySetAsSeries(bb_upper, true);
      ArraySetAsSeries(bb_lower, true);

      int needBars = AdaptiveTP_Lookback + 2;
      if(CopyBuffer(handleBB[i], 1, 0, needBars, bb_upper) < needBars) continue;
      if(CopyBuffer(handleBB[i], 2, 0, needBars, bb_lower) < needBars) continue;

      // 現在のバンド幅（直近確定足）
      double currentBW = bb_upper[1] - bb_lower[1];

      // 過去バー数の中での最大バンド幅（エクスパンションのピーク）
      double maxBW = 0;
      double avgBW = 0;
      for(int k = 2; k < needBars; k++) {
         double bw = bb_upper[k] - bb_lower[k];
         avgBW += bw;
         if(bw > maxBW) maxBW = bw;
      }
      avgBW /= AdaptiveTP_Lookback;

      if(maxBW <= 0) continue;

      // 現在のバンド幅がピーク時に対してどの程度維持されているか
      // 1.0 = ピーク維持 → トレンド継続中
      // 0.5 = ピークの半分 → トレンド減衰
      double ratio = currentBW / maxBW;
      totalRatio += ratio;
      activePairCount++;
   }

   // ポジションを持つペアがない場合はデフォルト
   if(activePairCount == 0) return TakeProfit_Equity_Pct;

   double avgRatio = totalRatio / activePairCount;

   // バンド幅維持率に応じて線形補間でTP%を算出
   // Expand_Mult以上 → バンドがピーク近く維持 → 強トレンド継続 → 大きく利確
   // Squeeze_Mult以下 → バンドがピークから大きく縮小 → トレンド終了 → 早め利確
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
