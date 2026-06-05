//+------------------------------------------------------------------+
//| TrendNanpinEA_V2.mq5 - トレンド＋ナンピン EA（複利対応+上位足判定版）|
//| パターンA〜D 複数同時稼働対応版（通常/マイクロ統合版）              |
//| トレンド判定: 短期MA/長期MAクロス + N本確認                         |
//+------------------------------------------------------------------+
#property copyright "Trend Nanpin EA V2"
#property version   "5.00"
#property strict
#include <Trade/Trade.mqh>

// --- 許可口座リスト ---
#define ALLOWED_ACCOUNT_COUNT 4
const long g_allowedAccounts[ALLOWED_ACCOUNT_COUNT] = {75545335, 70643523, 75548484, 370394526};

#define PAIR_COUNT     4
#define PATTERN_COUNT  4
#define MAX_PAIRS      (PATTERN_COUNT * PAIR_COUNT)

// パターン別シンボル定義（通常口座用、Microモード時は"micro"サフィックスを自動付加）
const string g_patternSymbolsBase[PATTERN_COUNT][PAIR_COUNT] = {
   {"USDJPY", "GBPJPY", "AUDJPY", "EURAUD"},
   {"NZDJPY", "CADJPY", "CHFJPY", "GBPAUD"},
   {"EURUSD", "GBPUSD", "AUDUSD", "USDCHF"},
   {"EURJPY", "USDJPY", "GBPCHF", "AUDNZD"}
};

// パターン別スワップ方向（初期値、上位足トレンドで上書きされる）
const int g_patternSwapDir[PATTERN_COUNT][PAIR_COUNT] = {
   { 1,  1,  1, -1},
   { 1,  1,  1, -1},
   {-1, -1, -1,  1},
   { 1,  1,  1,  1}
};

const string g_patternNames[PATTERN_COUNT] = {"A", "B", "C", "D"};

// パターン別シンボル（実行時にMicroMode判定で設定）
string g_patternSymbols[PATTERN_COUNT][PAIR_COUNT];

// --- 口座モード ---
input bool   MicroMode          = false;   // マイクロ口座モード (true=シンボルに"micro"付加)

// --- 基本設定 ---
input int    Magic_Number       = 847291;
input double Lots               = 0.01;
input bool   SinglePairMode     = false;

// --- 複利設定 ---
input bool   CompoundMode       = true;    // 複利モード (true=有効)
input double BalancePerLot      = 100000;  // 1ロット単位あたりの必要残高 (円)
input double BaseLots           = 0.01;    // 複利計算の基準ロット

// --- ロットスケール設定（残高に応じてBalancePerLotに倍率適用） ---
input double LotScale_Balance1  = 0;       // 段階1: 残高閾値 (0=無効)
input double LotScale_Rate1     = 1.0;     // 段階1: BalancePerLot倍率
input double LotScale_Balance2  = 0;       // 段階2: 残高閾値 (0=無効)
input double LotScale_Rate2     = 1.0;     // 段階2: BalancePerLot倍率
input double LotScale_Balance3  = 0;       // 段階3: 残高閾値 (0=無効)
input double LotScale_Rate3     = 1.0;     // 段階3: BalancePerLot倍率
input double LotScale_Balance4  = 0;       // 段階4: 残高閾値 (0=無効)
input double LotScale_Rate4     = 1.0;     // 段階4: BalancePerLot倍率
input double LotScale_Balance5  = 0;       // 段階5: 残高閾値 (0=無効)
input double LotScale_Rate5     = 1.0;     // 段階5: BalancePerLot倍率

// --- 複利逓減設定（利益が出るほどロットを抑える） ---
input bool   Decay_Enabled      = false;   // 複利逓減 (true=有効)
input double Decay_Step         = 500000;  // この金額増えるごとに倍率を下げる (円)
input double Decay_Reduce       = 0.2;     // 1段階ごとに下げる倍率 (例:0.2→1.0,0.8,0.6...)
input double Decay_MinMulti     = 0.4;     // 最低倍率（これ以下にはならない）
input double Decay_BaseBalance  = 3000000;       // 基準残高 (0=起動時の残高を自動使用)

// --- パターン有効/無効 ---
input bool   EnablePattern_A    = true;
input bool   EnablePattern_B    = true;
input bool   EnablePattern_C    = true;
input bool   EnablePattern_D    = true;

// --- 上位足トレンド設定（MAクロス + N本確認） ---
input bool   TrendFollow_Enabled  = false; // トレンド追従モード (false=パターン固定方向)
input ENUM_TIMEFRAMES TrendMA_Timeframe = PERIOD_W1;  // 上位足時間軸
input int    TrendMA_Short_Period = 5;     // 短期MA期間
input int    TrendMA_Long_Period  = 20;    // 長期MA期間
input int    TrendConfirmBars    = 2;      // クロス維持確認本数

// --- エントリー用MA設定 ---
input int    MA_Period           = 50;
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H4;

// --- エントリー品質向上設定 ---
input bool   PullbackEntry_Enabled = true;  // プルバックエントリー (true=MA回帰時のみエントリー)
input int    PullbackLookback      = 5;     // プルバック判定: 過去N本以内にMAの逆側にいたか
input bool   TrendStrength_Enabled = true;  // トレンド強度フィルター (true=MA傾き判定)
input double TrendSlope_MinPips    = 3.0;   // MA傾き最低pips (過去N本での変化量)
input int    TrendSlope_Bars       = 10;    // MA傾き計算期間 (本数)

// --- ナンピン設定 ---
input int    Nanpin_Pips            = 50;
input double Nanpin_Pips_Multiplier = 15.0;   // ナンピン幅倍率 (1.0=固定幅, 2.0=2倍ずつ拡大)
input int    Max_Nanpin             = 0;      // 0=無制限
input double NanpinLot_Multiplier   = 15.0;   // ナンピン初回ロット倍率 (例: 5.0=初回5倍ロット)
input double Lot_Multiplier         = 1.0;   // ナンピンロット増加倍率 (例: 2.0=毎回2倍)
input bool   AdaptiveNanpin_Enabled = true;  // ATRベース適応ナンピン幅
input int    ATR_Period             = 14;     // ATR計算期間
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_D1; // ATR計算時間軸

// --- 決済設定 ---
input int    Profit_Pips         = 30;

// --- 適応型利確設定（ATRベース） ---
input bool   AdaptiveTP_Enabled    = true;   // ATR適応利確 (true=有効, false=Profit_Pips固定)
input double AdaptiveTP_Multiplier = 1.5;    // ATR × 倍率 = 利確幅
input int    AdaptiveTP_MinPips    = 10;     // 最低利確pips（下限）
input int    AdaptiveTP_MaxPips    = 100;    // 最大利確pips（上限）

// --- 日次決済設定 ---
input bool   DailyClose_Enabled  = true;   // 日次利確決済 (true=有効)
input int    DailyClose_Hour     = 23;     // 決済判定時刻（時）サーバー時間
input int    DailyClose_Minute   = 50;     // 決済判定時刻（分）サーバー時間
input int    DailyClose_MinPips  = 5;      // 決済に必要な最低利益 (pips)
input bool   EarlyClose_Enabled  = true;   // 早期利確 (true=ポジション数条件で時間外も利確)
input int    EarlyClose_MinPositions = 3;  // 早期利確に必要な最低ポジション数

// --- リスク管理 ---
input double MaxDrawdownPercent  = 0;      // 最大含み損率で損切り (残高の%, 0=無効)
input double NanpinPause_Percent = 0;      // 全体含み損率でナンピン停止 (残高の%, 0=無効)
input bool   HedgeMode           = false;  // 両建てモード (true=転換時損切りせず両建て)
input double MaxSpread           = 5.0;
input int    TradingStartHour    = 0;
input int    TradingEndHour      = 0;

struct PairState {
   string   symbol;
   bool     enabled;
   bool     windingDown;
   int      magicNumber;
   int      patternIndex;
   int      pairIndex;
   double   pip;
   int      digits;
   int      maHandle;           // エントリー用MA
   int      trendMaShortHandle; // 上位足短期MA
   int      trendMaLongHandle;  // 上位足長期MA
   int      atrHandle;          // ATRハンドル
   int      swapDirection;      // +1=BUY, -1=SELL
   int      oldDirection;       // 両建てモード: 旧ポジション方向 (0=なし)
   int      nanpinCount;
   double   lastEntryPrice;
   datetime lastBarTime;
   datetime lastTrendBarTime;
   datetime lastDailyCloseDate; // 日次決済実行済み日付
};

PairState g_pairs[MAX_PAIRS];
CTrade    g_trade;
int       g_activePairCount;
double    g_initialBalance;  // 複利逓減用: 基準残高

//--- パターン有効フラグ取得 ---
bool IsPatternEnabled(int patIdx)
{
   switch(patIdx)
   {
      case 0: return EnablePattern_A;
      case 1: return EnablePattern_B;
      case 2: return EnablePattern_C;
      case 3: return EnablePattern_D;
   }
   return false;
}

//--- HasPositionsForMagic ---
bool HasPositionsForMagic(int magic, string symbol)
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      return true;
   }
   return false;
}

//--- GetCrossDirection ---
// 指定シフトの確定足で短期MA vs 長期MAの関係を返す
// 戻り値: +1=短期>長期(BUY方向), -1=短期<長期(SELL方向), 0=判定不能
int GetCrossDirection(int idx, int shift)
{
   double shortMA[], longMA[];
   ArraySetAsSeries(shortMA, true);
   ArraySetAsSeries(longMA, true);

   if(CopyBuffer(g_pairs[idx].trendMaShortHandle, 0, shift, 1, shortMA) <= 0)
      return 0;
   if(CopyBuffer(g_pairs[idx].trendMaLongHandle, 0, shift, 1, longMA) <= 0)
      return 0;

   if(shortMA[0] > longMA[0]) return  1;
   if(shortMA[0] < longMA[0]) return -1;
   return 0;
}

//--- GetConfirmedTrendDirection ---
// 過去TrendConfirmBars本が全て同じ方向であれば、その方向を返す
// そうでなければ0（未確定）
int GetConfirmedTrendDirection(int idx)
{
   if(TrendConfirmBars <= 0) return GetCrossDirection(idx, 1);

   int firstDir = GetCrossDirection(idx, 1);
   if(firstDir == 0) return 0;

   // shift=1からTrendConfirmBars本分チェック
   for(int i = 2; i <= TrendConfirmBars; i++)
   {
      int dir = GetCrossDirection(idx, i);
      if(dir != firstDir) return 0;  // 一貫していない
   }

   return firstDir;
}

//--- IsNewTrendBar ---
bool IsNewTrendBar(int idx)
{
   datetime barTime = iTime(g_pairs[idx].symbol, TrendMA_Timeframe, 0);
   if(barTime == 0) return false;
   if(barTime != g_pairs[idx].lastTrendBarTime)
   {
      g_pairs[idx].lastTrendBarTime = barTime;
      return true;
   }
   return false;
}

//--- CheckTrendReversal ---
void CheckTrendReversal(int idx)
{
   if(!IsNewTrendBar(idx)) return;

   int confirmedDir = GetConfirmedTrendDirection(idx);
   if(confirmedDir == 0) return;  // 未確定

   int oldDirection = g_pairs[idx].swapDirection;
   if(confirmedDir == oldDirection) return;  // 方向変わらず

   // --- トレンド転換確定 ---
   PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] ★トレンド転換確定: %s → %s (MA%d/MA%d クロス %d本確認)",
              g_patternNames[g_pairs[idx].patternIndex],
              g_pairs[idx].symbol,
              (oldDirection == 1) ? "BUY" : "SELL",
              (confirmedDir == 1) ? "BUY" : "SELL",
              TrendMA_Short_Period, TrendMA_Long_Period, TrendConfirmBars);

   g_pairs[idx].swapDirection = confirmedDir;

   // 既存ポジションの処理
   int posCount = CountPositions(idx);
   if(posCount > 0)
   {
      if(HedgeMode)
      {
         // 両建てモード: 損切りせず旧方向を記録
         g_pairs[idx].oldDirection = oldDirection;
         PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 両建てモード: 旧%sポジション保持、新%s方向開始",
                    g_patternNames[g_pairs[idx].patternIndex],
                    g_pairs[idx].symbol,
                    (oldDirection == 1) ? "BUY" : "SELL",
                    (confirmedDir == 1) ? "BUY" : "SELL");
      }
      else
      {
         // 通常モード: 損切り
         PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] トレンド転換による損切り: %dポジション",
                    g_patternNames[g_pairs[idx].patternIndex],
                    g_pairs[idx].symbol, posCount);
         CloseAllPositions(idx);
      }
   }

   // 新方向にエントリー
   if(!IsSpreadOK(idx))
   {
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] スプレッド超過のため即エントリー見送り",
                 g_patternNames[g_pairs[idx].patternIndex], g_pairs[idx].symbol);
      return;
   }

   string symbol = g_pairs[idx].symbol;
   double lots = CalcCompoundLots(symbol);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(confirmedDir == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpinV2");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpinV2");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] トレンド転換後エントリー: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, (confirmedDir == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpinV2 ERROR][%s] トレンド転換後エントリー失敗: err=%d", symbol, GetLastError());
}

//--- OnInit ---
int OnInit()
{
   // シンボル配列を初期化（MicroMode時は"micro"サフィックス付加）
   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      for(int p = 0; p < PAIR_COUNT; p++)
      {
         if(MicroMode)
            g_patternSymbols[pat][p] = g_patternSymbolsBase[pat][p] + "micro";
         else
            g_patternSymbols[pat][p] = g_patternSymbolsBase[pat][p];
      }
   }

   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   bool accountAllowed = false;
   for(int i = 0; i < ALLOWED_ACCOUNT_COUNT; i++)
   {
      if(accountNumber == g_allowedAccounts[i]) { accountAllowed = true; break; }
   }
   if(!accountAllowed)
   {
      PrintFormat("[TrendNanpinV2 ERROR] この口座(%d)では利用できません。", accountNumber);
      return(INIT_FAILED);
   }

   if(Lots <= 0)
   { Print("[TrendNanpinV2 ERROR] Lots は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Nanpin_Pips <= 0)
   { Print("[TrendNanpinV2 ERROR] Nanpin_Pips は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Nanpin_Pips_Multiplier <= 0)
   { Print("[TrendNanpinV2 ERROR] Nanpin_Pips_Multiplier は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(NanpinLot_Multiplier <= 0)
   { Print("[TrendNanpinV2 ERROR] NanpinLot_Multiplier は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Profit_Pips <= 0)
   { Print("[TrendNanpinV2 ERROR] Profit_Pips は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Max_Nanpin < 0)
   { Print("[TrendNanpinV2 ERROR] Max_Nanpin は0以上が必要 (0=無制限)"); return(INIT_PARAMETERS_INCORRECT); }
   if(MA_Period <= 0)
   { Print("[TrendNanpinV2 ERROR] MA_Period は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(TrendMA_Short_Period <= 0 || TrendMA_Long_Period <= 0)
   { Print("[TrendNanpinV2 ERROR] TrendMA期間は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(TrendMA_Short_Period >= TrendMA_Long_Period)
   { Print("[TrendNanpinV2 ERROR] TrendMA_Short_Period < TrendMA_Long_Period が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(TrendConfirmBars < 1)
   { Print("[TrendNanpinV2 ERROR] TrendConfirmBars は1以上が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(CompoundMode && BalancePerLot <= 0)
   { Print("[TrendNanpinV2 ERROR] BalancePerLot は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(CompoundMode && BaseLots <= 0)
   { Print("[TrendNanpinV2 ERROR] BaseLots は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(AdaptiveTP_Enabled && AdaptiveTP_Multiplier <= 0)
   { Print("[TrendNanpinV2 ERROR] AdaptiveTP_Multiplier は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(AdaptiveTP_Enabled && AdaptiveTP_MinPips <= 0)
   { Print("[TrendNanpinV2 ERROR] AdaptiveTP_MinPips は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(AdaptiveTP_Enabled && AdaptiveTP_MaxPips < AdaptiveTP_MinPips)
   { Print("[TrendNanpinV2 ERROR] AdaptiveTP_MaxPips >= AdaptiveTP_MinPips が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(PullbackEntry_Enabled && PullbackLookback <= 0)
   { Print("[TrendNanpinV2 ERROR] PullbackLookback は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(TrendStrength_Enabled && TrendSlope_Bars <= 0)
   { Print("[TrendNanpinV2 ERROR] TrendSlope_Bars は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(TrendStrength_Enabled && TrendSlope_MinPips <= 0)
   { Print("[TrendNanpinV2 ERROR] TrendSlope_MinPips は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }

   g_activePairCount = 0;

   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      bool patEnabled = IsPatternEnabled(pat);

      for(int p = 0; p < PAIR_COUNT; p++)
      {
         int magic = Magic_Number + pat * 10 + p;
         string sym = g_patternSymbols[pat][p];

         if(patEnabled)
         {
            int idx = g_activePairCount;
            g_pairs[idx].symbol           = sym;
            g_pairs[idx].enabled          = true;
            g_pairs[idx].windingDown      = false;
            g_pairs[idx].patternIndex     = pat;
            g_pairs[idx].pairIndex        = p;
            g_pairs[idx].magicNumber      = magic;
            g_pairs[idx].pip              = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
            g_pairs[idx].digits           = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
            g_pairs[idx].swapDirection    = g_patternSwapDir[pat][p];
            g_pairs[idx].maHandle         = INVALID_HANDLE;
            g_pairs[idx].trendMaShortHandle = INVALID_HANDLE;
            g_pairs[idx].trendMaLongHandle  = INVALID_HANDLE;
            g_pairs[idx].nanpinCount      = 0;
            g_pairs[idx].lastEntryPrice   = 0;
            g_pairs[idx].lastBarTime      = 0;
            g_pairs[idx].lastTrendBarTime = 0;
            g_pairs[idx].lastDailyCloseDate = 0;
            g_activePairCount++;
         }
         else
         {
            if(HasPositionsForMagic(magic, sym))
            {
               int idx = g_activePairCount;
               g_pairs[idx].symbol           = sym;
               g_pairs[idx].enabled          = true;
               g_pairs[idx].windingDown      = true;
               g_pairs[idx].patternIndex     = pat;
               g_pairs[idx].pairIndex        = p;
               g_pairs[idx].magicNumber      = magic;
               g_pairs[idx].pip              = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
               g_pairs[idx].digits           = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
               g_pairs[idx].swapDirection    = g_patternSwapDir[pat][p];
               g_pairs[idx].maHandle         = INVALID_HANDLE;
               g_pairs[idx].trendMaShortHandle = INVALID_HANDLE;
               g_pairs[idx].trendMaLongHandle  = INVALID_HANDLE;
               g_pairs[idx].nanpinCount      = 0;
               g_pairs[idx].lastEntryPrice   = 0;
               g_pairs[idx].lastBarTime      = 0;
               g_pairs[idx].lastTrendBarTime = 0;
               g_pairs[idx].lastDailyCloseDate = 0;
               g_activePairCount++;
               PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] パターンOFF - 既存ポジション決済待ち",
                          g_patternNames[pat], sym);
            }
         }
      }
   }

   if(g_activePairCount == 0)
   { Print("[TrendNanpinV2 ERROR] 有効なペアがありません"); return(INIT_PARAMETERS_INCORRECT); }

   if(SinglePairMode)
   {
      string chartSymbol = _Symbol;
      int foundIdx = -1;
      for(int i = 0; i < g_activePairCount; i++)
      {
         if(g_pairs[i].symbol == chartSymbol) { foundIdx = i; break; }
      }
      if(foundIdx == -1)
      {
         PrintFormat("[TrendNanpinV2 ERROR] シングルペアモード: %s は管理対象外", chartSymbol);
         return(INIT_FAILED);
      }
      if(foundIdx != 0)
      {
         g_pairs[0].symbol        = g_pairs[foundIdx].symbol;
         g_pairs[0].enabled       = true;
         g_pairs[0].patternIndex  = g_pairs[foundIdx].patternIndex;
         g_pairs[0].pairIndex     = g_pairs[foundIdx].pairIndex;
         g_pairs[0].pip           = g_pairs[foundIdx].pip;
         g_pairs[0].digits        = g_pairs[foundIdx].digits;
         g_pairs[0].swapDirection = g_pairs[foundIdx].swapDirection;
      }
      g_pairs[0].magicNumber        = Magic_Number;
      g_pairs[0].windingDown        = false;
      g_pairs[0].maHandle           = INVALID_HANDLE;
      g_pairs[0].trendMaShortHandle = INVALID_HANDLE;
      g_pairs[0].trendMaLongHandle  = INVALID_HANDLE;
      g_pairs[0].nanpinCount        = 0;
      g_pairs[0].lastEntryPrice     = 0;
      g_pairs[0].lastBarTime        = 0;
      g_pairs[0].lastTrendBarTime   = 0;
      g_pairs[0].lastDailyCloseDate = 0;
      g_activePairCount = 1;
      PrintFormat("[TrendNanpinV2 INFO] シングルペアモード: %s (パターン%s)",
                 chartSymbol, g_patternNames[g_pairs[0].patternIndex]);
   }
   else
   {
      for(int i = 0; i < g_activePairCount; i++)
      {
         if(!g_pairs[i].enabled) continue;
         if(!SymbolInfoInteger(g_pairs[i].symbol, SYMBOL_EXIST))
         {
            PrintFormat("[TrendNanpinV2 ERROR] シンボル利用不可: %s", g_pairs[i].symbol);
            return(INIT_FAILED);
         }
         if(!SymbolSelect(g_pairs[i].symbol, true))
            PrintFormat("[TrendNanpinV2 WARN][%s] 気配値への追加に失敗", g_pairs[i].symbol);
      }
      PrintFormat("[TrendNanpinV2 INFO] マルチペアモード: %dペア", g_activePairCount);
   }

   // MAインジケータハンドル作成
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      // エントリー用MA
      g_pairs[i].maHandle = iMA(g_pairs[i].symbol, MA_Timeframe, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].maHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendNanpinV2 ERROR] エントリーMA作成失敗: %s", g_pairs[i].symbol);
         return(INIT_FAILED);
      }

      // 上位足短期MA
      g_pairs[i].trendMaShortHandle = iMA(g_pairs[i].symbol, TrendMA_Timeframe, TrendMA_Short_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].trendMaShortHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendNanpinV2 ERROR] トレンド短期MA作成失敗: %s", g_pairs[i].symbol);
         return(INIT_FAILED);
      }

      // 上位足長期MA
      g_pairs[i].trendMaLongHandle = iMA(g_pairs[i].symbol, TrendMA_Timeframe, TrendMA_Long_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].trendMaLongHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendNanpinV2 ERROR] トレンド長期MA作成失敗: %s", g_pairs[i].symbol);
         return(INIT_FAILED);
      }

      // ATRハンドル作成（適応ナンピン幅 or 適応利確で使用）
      g_pairs[i].atrHandle = INVALID_HANDLE;
      if(AdaptiveNanpin_Enabled || AdaptiveTP_Enabled)
      {
         g_pairs[i].atrHandle = iATR(g_pairs[i].symbol, ATR_Timeframe, ATR_Period);
         if(g_pairs[i].atrHandle == INVALID_HANDLE)
         {
            PrintFormat("[TrendNanpinV2 ERROR] ATR作成失敗: %s", g_pairs[i].symbol);
            return(INIT_FAILED);
         }
      }
   }

   // 初期トレンド方向を設定
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      g_pairs[i].lastTrendBarTime = iTime(g_pairs[i].symbol, TrendMA_Timeframe, 0);
      g_pairs[i].oldDirection = 0;

      if(TrendFollow_Enabled)
      {
         int trendDir = GetConfirmedTrendDirection(i);
         if(trendDir != 0)
         {
            g_pairs[i].swapDirection = trendDir;
            PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 初期トレンド: %s (MA%d/MA%d クロス確認済)",
                       g_patternNames[g_pairs[i].patternIndex],
                       g_pairs[i].symbol,
                       (trendDir == 1) ? "BUY" : "SELL",
                       TrendMA_Short_Period, TrendMA_Long_Period);
         }
         else
         {
            int crossDir = GetCrossDirection(i, 1);
            if(crossDir != 0)
               g_pairs[i].swapDirection = crossDir;
            PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 初期トレンド: %s (確認本数不足→クロス方向で開始)",
                       g_patternNames[g_pairs[i].patternIndex],
                       g_pairs[i].symbol,
                       (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
         }
      }
      else
      {
         // 固定方向モード: パターン定義のswapDirectionをそのまま使用
         PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 固定方向モード: %s",
                    g_patternNames[g_pairs[i].patternIndex],
                    g_pairs[i].symbol,
                    (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
      }
   }

   g_trade.SetDeviationInPoints(10);

   // 複利逓減: 基準残高を設定
   if(Decay_BaseBalance > 0)
      g_initialBalance = Decay_BaseBalance;
   else
      g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   RestoreStateFromPositions();

   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] Magic=%d, Direction=%s",
                 g_patternNames[g_pairs[i].patternIndex],
                 g_pairs[i].symbol, g_pairs[i].magicNumber,
                 (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
   }

   string enabledPatterns = "";
   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      if(IsPatternEnabled(pat))
      {
         if(enabledPatterns != "") enabledPatterns += ",";
         enabledPatterns += g_patternNames[pat];
      }
   }
   PrintFormat("[TrendNanpinV2 INFO] 初期化完了: パターン=[%s], TrendMA=%d/%d(%s)確認%d本, EntryMA=%d(%s), Nanpin=%s, Lot=%s, Profit=%s, 複利=%s",
              enabledPatterns, TrendMA_Short_Period, TrendMA_Long_Period,
              EnumToString(TrendMA_Timeframe), TrendConfirmBars,
              MA_Period, EnumToString(MA_Timeframe),
              AdaptiveNanpin_Enabled
                 ? StringFormat("ATR適応(基準%dpips×%.1f倍)", Nanpin_Pips, Nanpin_Pips_Multiplier)
                 : StringFormat("%dpips×%.1f倍", Nanpin_Pips, Nanpin_Pips_Multiplier),
              StringFormat("初回%.1f倍→×%.1f倍", NanpinLot_Multiplier, Lot_Multiplier),
              AdaptiveTP_Enabled ? StringFormat("ATR×%.1f(%d-%dpips)", AdaptiveTP_Multiplier, AdaptiveTP_MinPips, AdaptiveTP_MaxPips)
                                : StringFormat("%dpips固定", Profit_Pips),
              CompoundMode ? StringFormat("ON(%.0f円/%.2fLot)", BalancePerLot, BaseLots) : "OFF");
   PrintFormat("[TrendNanpinV2 INFO] エントリー品質: Pullback=%s(過去%d本), TrendStrength=%s(傾き%.1fpips/%d本)",
              PullbackEntry_Enabled ? "ON" : "OFF", PullbackLookback,
              TrendStrength_Enabled ? "ON" : "OFF", TrendSlope_MinPips, TrendSlope_Bars);
   if(Decay_Enabled && CompoundMode)
      PrintFormat("[TrendNanpinV2 INFO] 複利逓減: 基準残高=%.0f ステップ=%.0f 減少幅=%.2f 最低倍率=%.2f",
                 g_initialBalance, Decay_Step, Decay_Reduce, Decay_MinMulti);
   return(INIT_SUCCEEDED);
}

//--- OnDeinit ---
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(g_pairs[i].maHandle != INVALID_HANDLE)
         IndicatorRelease(g_pairs[i].maHandle);
      if(g_pairs[i].trendMaShortHandle != INVALID_HANDLE)
         IndicatorRelease(g_pairs[i].trendMaShortHandle);
      if(g_pairs[i].trendMaLongHandle != INVALID_HANDLE)
         IndicatorRelease(g_pairs[i].trendMaLongHandle);
      if(g_pairs[i].atrHandle != INVALID_HANDLE)
         IndicatorRelease(g_pairs[i].atrHandle);
   }
   PrintFormat("[TrendNanpinV2 INFO] EA停止: reason=%d", reason);
}

//--- OnTick ---
void OnTick()
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      // 最大含み損チェック（トレンド転換より優先）
      if(MaxDrawdownPercent > 0)
         if(CheckMaxDrawdown(i)) continue;  // 損切り実行した場合は次のペアへ

      if(TrendFollow_Enabled && !g_pairs[i].windingDown)
         CheckTrendReversal(i);

      // 日次利確チェック
      if(DailyClose_Enabled)
         CheckDailyClose(i);

      // 早期利確チェック（ポジション数条件）
      if(EarlyClose_Enabled)
         CheckEarlyClose(i);

      ProcessPair(i);
   }
}

//--- ProcessPair ---
void ProcessPair(int idx)
{
   CheckBatchClose(idx);

   if(g_pairs[idx].windingDown)
   {
      if(CountPositions(idx) == 0)
      {
         g_pairs[idx].enabled = false;
         PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 全ポジション決済完了 - 停止",
                    g_patternNames[g_pairs[idx].patternIndex], g_pairs[idx].symbol);
      }
      else
      {
         if(IsNewBar(idx))
            CheckNanpin(idx);
      }
      return;
   }

   if(!IsNewBar(idx)) return;

   int posCount = CountPositions(idx);
   double existingLot = GetExistingLot(idx);
   if(existingLot > 0)
   {
      if(posCount > 0)
         CheckNanpinWithLot(idx, existingLot);
      return;
   }

   if(posCount == 0)
      CheckEntry(idx);
   else
      CheckNanpin(idx);
}

//--- GetExistingLot ---
double GetExistingLot(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   datetime oldestTime = D'2099.01.01';
   double oldestLot = 0;
   bool hasPosition = false;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      hasPosition = true;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime < oldestTime)
      {
         oldestTime = openTime;
         oldestLot  = PositionGetDouble(POSITION_VOLUME);
      }
   }

   if(!hasPosition) return 0;

   double currentLots = CalcCompoundLots(symbol);
   if(MathAbs(oldestLot - currentLots) > 0.0001)
      return oldestLot;

   return 0;
}

//--- IsTrendAligned ---
// エントリー条件: (1)価格がMAの正しい側, (2)プルバック確認, (3)トレンド強度
bool IsTrendAligned(int idx)
{
   int barsNeeded = MathMax(PullbackLookback + 1, TrendSlope_Bars + 1);
   barsNeeded = MathMax(barsNeeded, 2);

   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   if(CopyBuffer(g_pairs[idx].maHandle, 0, 0, barsNeeded, maBuffer) <= 0)
      return false;

   double ma = maBuffer[0];
   string symbol = g_pairs[idx].symbol;
   double currentPrice = (SymbolInfoDouble(symbol, SYMBOL_ASK) + SymbolInfoDouble(symbol, SYMBOL_BID)) / 2.0;

   // (1) 基本条件: 価格がMAの正しい側にあるか
   if(g_pairs[idx].swapDirection == 1)
   {
      if(currentPrice <= ma) return false;
   }
   else
   {
      if(currentPrice >= ma) return false;
   }

   // (2) プルバックエントリー: 過去N本以内にMAの逆側にいた（＝MAをクロスしてきた）
   if(PullbackEntry_Enabled)
   {
      bool hadPullback = false;
      for(int i = 1; i <= PullbackLookback && i < barsNeeded; i++)
      {
         double pastClose = iClose(symbol, MA_Timeframe, i);
         if(pastClose == 0) continue;

         if(g_pairs[idx].swapDirection == 1)
         {
            // BUY: 過去にMAより下にいた = プルバックがあった
            if(pastClose < maBuffer[i])
            {
               hadPullback = true;
               break;
            }
         }
         else
         {
            // SELL: 過去にMAより上にいた = プルバックがあった
            if(pastClose > maBuffer[i])
            {
               hadPullback = true;
               break;
            }
         }
      }
      if(!hadPullback) return false;
   }

   // (3) トレンド強度フィルター: MAの傾きが最低pips以上
   if(TrendStrength_Enabled)
   {
      if(TrendSlope_Bars >= barsNeeded) return true; // データ不足の場合はスキップ

      double maSlope = (maBuffer[0] - maBuffer[TrendSlope_Bars]) / g_pairs[idx].pip;

      if(g_pairs[idx].swapDirection == 1)
      {
         // BUY: MAが上昇している必要あり
         if(maSlope < TrendSlope_MinPips) return false;
      }
      else
      {
         // SELL: MAが下降している必要あり (slopeが負)
         if(maSlope > -TrendSlope_MinPips) return false;
      }
   }

   return true;
}

//--- IsNewBar ---
bool IsNewBar(int idx)
{
   datetime barTime = iTime(g_pairs[idx].symbol, MA_Timeframe, 0);
   if(barTime == 0) return false;
   if(barTime != g_pairs[idx].lastBarTime)
   {
      g_pairs[idx].lastBarTime = barTime;
      return true;
   }
   return false;
}

//--- CheckEntry ---
void CheckEntry(int idx)
{
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double lots = CalcCompoundLots(symbol);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpinV2");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpinV2");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 初回エントリー: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpinV2 ERROR][%s] 注文失敗: err=%d", symbol, GetLastError());
}

//--- GetAdaptiveNanpinPips ---
// ATRに基づくナンピン幅(pips)を返す。無効時はNanpin_Pipsをそのまま返す
// nanpinCount: 現在のナンピン回数（0=これから1回目のナンピン）
double GetAdaptiveNanpinPips(int idx, int nanpinCount = 0)
{
   // 基本幅: Nanpin_Pips × Nanpin_Pips_Multiplier ^ nanpinCount
   double basePips = Nanpin_Pips * MathPow(MathMax(Nanpin_Pips_Multiplier, 0.01), nanpinCount);

   if(!AdaptiveNanpin_Enabled || g_pairs[idx].atrHandle == INVALID_HANDLE)
      return basePips;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(g_pairs[idx].atrHandle, 0, 1, 1, atrBuffer) <= 0)
      return basePips;

   // ATRをpipsに変換
   double atrPips = atrBuffer[0] / g_pairs[idx].pip;

   // ATRがbasePipsより大きければATRを使い、小さければbasePipsをそのまま使う
   if(atrPips > basePips)
      return atrPips;

   return basePips;
}

//--- GetAdaptiveProfitPips ---
// ATRに基づく利確幅(pips)を返す。無効時はProfit_Pipsをそのまま返す
double GetAdaptiveProfitPips(int idx)
{
   if(!AdaptiveTP_Enabled || g_pairs[idx].atrHandle == INVALID_HANDLE)
      return Profit_Pips;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(g_pairs[idx].atrHandle, 0, 1, 1, atrBuffer) <= 0)
      return Profit_Pips;

   // ATRをpipsに変換し倍率を適用
   double atrPips = atrBuffer[0] / g_pairs[idx].pip;
   double tpPips = atrPips * AdaptiveTP_Multiplier;

   // 上下限でクランプ
   if(tpPips < AdaptiveTP_MinPips) tpPips = AdaptiveTP_MinPips;
   if(tpPips > AdaptiveTP_MaxPips) tpPips = AdaptiveTP_MaxPips;

   return tpPips;
}

//--- CheckNanpin ---
void CheckNanpin(int idx)
{
   if(Max_Nanpin > 0 && g_pairs[idx].nanpinCount >= Max_Nanpin) return;
   if(IsNanpinPaused()) return;
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   double lastPrice = g_pairs[idx].lastEntryPrice;
   double nanpinPips = GetAdaptiveNanpinPips(idx, g_pairs[idx].nanpinCount);

   bool nanpinTrigger = false;
   if(g_pairs[idx].swapDirection == 1)
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      nanpinTrigger = (lastPrice - currentAsk >= nanpinPips * pip);
   }
   else
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      nanpinTrigger = (currentBid - lastPrice >= nanpinPips * pip);
   }
   if(!nanpinTrigger) return;

   double lots = CalcNanpinLots(g_pairs[idx].nanpinCount, symbol);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpinV2");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpinV2");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount++;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] ナンピン #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpinV2 ERROR][%s] ナンピン注文失敗: err=%d", symbol, GetLastError());
}

//--- CheckNanpinWithLot ---
void CheckNanpinWithLot(int idx, double baseLot)
{
   if(Max_Nanpin > 0 && g_pairs[idx].nanpinCount >= Max_Nanpin) return;
   if(IsNanpinPaused()) return;
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   double lastPrice = g_pairs[idx].lastEntryPrice;
   double nanpinPips = GetAdaptiveNanpinPips(idx, g_pairs[idx].nanpinCount);

   bool nanpinTrigger = false;
   if(g_pairs[idx].swapDirection == 1)
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      nanpinTrigger = (lastPrice - currentAsk >= nanpinPips * pip);
   }
   else
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      nanpinTrigger = (currentBid - lastPrice >= nanpinPips * pip);
   }
   if(!nanpinTrigger) return;

   double lots = baseLot * NanpinLot_Multiplier * MathPow(MathMax(Lot_Multiplier, 0.01), g_pairs[idx].nanpinCount);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpinV2");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpinV2");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount++;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] ナンピン(旧ロット) #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpinV2 ERROR][%s] ナンピン注文失敗: err=%d", symbol, GetLastError());
}

//--- CalcCompoundLots ---
double CalcCompoundLots(string symbol)
{
   if(!CompoundMode)
      return Lots;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // ロットスケール: 残高に応じてBalancePerLotに倍率を適用
   double scaledBalancePerLot = BalancePerLot;
   double scaleBalances[5] = {LotScale_Balance1, LotScale_Balance2, LotScale_Balance3, LotScale_Balance4, LotScale_Balance5};
   double scaleRates[5]    = {LotScale_Rate1, LotScale_Rate2, LotScale_Rate3, LotScale_Rate4, LotScale_Rate5};

   for(int i = 0; i < 5; i++)
   {
      if(scaleBalances[i] <= 0) continue;       // 無効な段階はスキップ
      if(balance >= scaleBalances[i])
         scaledBalancePerLot = BalancePerLot * scaleRates[i];
   }

   double rawLots = MathFloor(balance / scaledBalancePerLot) * BaseLots;

   // 複利逓減: 残高が基準からステップ分増えるごとに倍率を下げる
   if(Decay_Enabled && Decay_Step > 0)
   {
      double baseBalance = (g_initialBalance > 0) ? g_initialBalance : balance;
      double growth = balance - baseBalance;

      if(growth > 0)
      {
         int steps = (int)MathFloor(growth / Decay_Step);
         double multiplier = 1.0 - (steps * Decay_Reduce);
         multiplier = MathMax(multiplier, Decay_MinMulti);
         rawLots = rawLots * multiplier;
      }
   }

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(rawLots < minLot) rawLots = minLot;
   if(rawLots > maxLot) rawLots = maxLot;

   if(lotStep > 0)
      rawLots = MathFloor(rawLots / lotStep) * lotStep;

   return NormalizeDouble(rawLots, 8);
}

//--- CalcNanpinLots ---
double CalcNanpinLots(int count, string symbol)
{
   double baseLot = CalcCompoundLots(symbol);
   // NanpinLot_Multiplier で初回ナンピンのロット倍率を指定し、
   // 以降 Lot_Multiplier で累乗していく
   // 例: NanpinLot_Multiplier=5, Lot_Multiplier=2, count=0(1回目) → 5倍
   //     count=1(2回目) → 5×2=10倍, count=2(3回目) → 5×2²=20倍
   return baseLot * NanpinLot_Multiplier * MathPow(MathMax(Lot_Multiplier, 0.01), count);
}

//--- IsNanpinPaused ---
// 全ポジション合計の含み損率がNanpinPause_Percentを超えていたらtrue
bool IsNanpinPaused()
{
   if(NanpinPause_Percent <= 0) return false;

   double totalProfit = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      // このEAのマジックナンバー範囲のポジションだけ集計
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic < Magic_Number || magic > Magic_Number + PATTERN_COUNT * 10 + PAIR_COUNT) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
   }

   if(totalProfit >= 0) return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdownPercent = MathAbs(totalProfit) / balance * 100.0;

   return (drawdownPercent >= NanpinPause_Percent);
}

//--- CheckMaxDrawdown ---
// 含み損が残高のMaxDrawdownPercent%を超えたら損切り
// 戻り値: true=損切り実行, false=何もしない
bool CheckMaxDrawdown(int idx)
{
   if(CountPositions(idx) == 0) return false;

   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double totalProfit = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
   }

   // 含み益なら何もしない
   if(totalProfit >= 0) return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdownPercent = MathAbs(totalProfit) / balance * 100.0;

   if(drawdownPercent >= MaxDrawdownPercent)
   {
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] ★最大含み損損切り: 含み損 %.0f (残高%.0fの%.1f%%)",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, totalProfit, balance, drawdownPercent);
      CloseAllPositions(idx);
      return true;
   }

   return false;
}

//--- CheckEarlyClose ---
// ポジション数が閾値以上で合計プラスなら時間に関係なく利確
void CheckEarlyClose(int idx)
{
   int posCount = CountPositions(idx);
   if(posCount < EarlyClose_MinPositions) return;

   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double totalProfit = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
   }

   double minProfitAmount = DailyClose_MinPips * g_pairs[idx].pip * CalcTotalLots(idx) * SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE) / SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   if(totalProfit >= minProfitAmount)
   {
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 早期利確: %dポジション, 合計損益 %.0f",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, posCount, totalProfit);
      CloseAllPositions(idx);
   }
}

//--- CheckDailyClose ---
// 日次利確: サーバー時間の指定時刻以降に、合計損益がプラスなら決済
void CheckDailyClose(int idx)
{
   if(CountPositions(idx) == 0) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // 指定時刻に達していなければスキップ
   if(dt.hour < DailyClose_Hour) return;
   if(dt.hour == DailyClose_Hour && dt.min < DailyClose_Minute) return;

   // 同日に既に実行済みならスキップ
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(g_pairs[idx].lastDailyCloseDate == today) return;

   // 全ポジションの合計損益を計算（利益+スワップ+手数料）
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double totalProfit = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
      // 手数料は取引履歴からしか取得できないため、
      // POSITION_PROFITに含まれないブローカーの場合は別途考慮が必要
   }

   // 最低利益pips相当の金額を計算（概算）
   double minProfitAmount = DailyClose_MinPips * g_pairs[idx].pip * CalcTotalLots(idx) * SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE) / SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   // 合計損益が最低利益以上ならば決済
   if(totalProfit >= minProfitAmount)
   {
      g_pairs[idx].lastDailyCloseDate = today;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 日次利確決済: 合計損益 %.0f (最低基準 %.0f)",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, totalProfit, minProfitAmount);
      CloseAllPositions(idx);
   }
   else
   {
      // 基準未達でもフラグを立てて再チェック防止（次ティックで再判定可能にするため立てない）
      // → 時刻内は毎ティックチェックし続ける（価格変動で条件達成する可能性）
   }
}

//--- CalcTotalLots ---
// 指定ペアの全ポジション合計ロット数
double CalcTotalLots(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double total_lots = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      total_lots += PositionGetDouble(POSITION_VOLUME);
   }
   return total_lots;
}

//--- CalcAveragePrice ---
double CalcAveragePrice(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double totalLots = 0, totalWeighted = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      double posLots  = PositionGetDouble(POSITION_VOLUME);
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      totalLots     += posLots;
      totalWeighted += posPrice * posLots;
   }
   if(totalLots <= 0) return 0.0;
   return totalWeighted / totalLots;
}

//--- CheckBatchClose ---
void CheckBatchClose(int idx)
{
   if(CountPositions(idx) == 0) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   int magic = g_pairs[idx].magicNumber;
   double profitPips = GetAdaptiveProfitPips(idx);

   // 現在方向のポジション利確チェック
   double avgPrice = CalcAveragePriceByDir(idx, g_pairs[idx].swapDirection);
   if(avgPrice > 0)
   {
      bool closeCondition = false;
      if(g_pairs[idx].swapDirection == 1)
      {
         double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
         closeCondition = (currentBid >= avgPrice + profitPips * pip);
      }
      else
      {
         double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
         closeCondition = (currentAsk <= avgPrice - profitPips * pip);
      }
      if(closeCondition)
         ClosePositionsByDir(idx, g_pairs[idx].swapDirection);
   }

   // 両建てモード: 旧方向ポジションの利確チェック
   if(HedgeMode && g_pairs[idx].oldDirection != 0)
   {
      double oldAvgPrice = CalcAveragePriceByDir(idx, g_pairs[idx].oldDirection);
      if(oldAvgPrice > 0)
      {
         bool oldCloseCondition = false;
         if(g_pairs[idx].oldDirection == 1)
         {
            double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
            oldCloseCondition = (currentBid >= oldAvgPrice + profitPips * pip);
         }
         else
         {
            double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
            oldCloseCondition = (currentAsk <= oldAvgPrice - profitPips * pip);
         }
         if(oldCloseCondition)
         {
            ClosePositionsByDir(idx, g_pairs[idx].oldDirection);
            g_pairs[idx].oldDirection = 0;  // 旧方向クリア
            PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 旧方向ポジション利確完了",
                       g_patternNames[g_pairs[idx].patternIndex], symbol);
         }
      }
      else
      {
         // 旧方向ポジションが全てなくなった
         g_pairs[idx].oldDirection = 0;
      }
   }
}

//--- CalcAveragePriceByDir ---
// 指定方向のポジションのみの平均価格を計算
double CalcAveragePriceByDir(int idx, int direction)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   double totalLots = 0, totalWeighted = 0;
   ENUM_POSITION_TYPE targetType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != targetType) continue;

      double posLots  = PositionGetDouble(POSITION_VOLUME);
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      totalLots     += posLots;
      totalWeighted += posPrice * posLots;
   }
   if(totalLots <= 0) return 0.0;
   return totalWeighted / totalLots;
}

//--- ClosePositionsByDir ---
// 指定方向のポジションのみ決済
void ClosePositionsByDir(int idx, int direction)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   int closed = 0;
   double totalProfit = 0;
   ENUM_POSITION_TYPE targetType = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   g_trade.SetExpertMagicNumber(magic);

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != targetType) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_trade.PositionClose(ticket))
         closed++;
   }

   if(closed > 0)
   {
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] %s方向決済: %dポジション, 損益 %.0f",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, (direction == 1) ? "BUY" : "SELL", closed, totalProfit);
   }
}

//--- CloseAllPositions ---
void CloseAllPositions(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   int closed = 0;
   double totalProfit = 0;

   g_trade.SetExpertMagicNumber(magic);

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_trade.PositionClose(ticket))
         closed++;
      else
         PrintFormat("[TrendNanpinV2 ERROR][%s] 決済失敗: ticket=%d, err=%d", symbol, ticket, GetLastError());
   }

   if(closed > 0)
   {
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = 0;
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 一括決済: %dポジション, 損益 %.0f",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, closed, totalProfit);
   }
}

//--- RestoreStateFromPositions ---
void RestoreStateFromPositions()
{
   for(int idx = 0; idx < g_activePairCount; idx++)
   {
      if(!g_pairs[idx].enabled) continue;

      int magic = g_pairs[idx].magicNumber;
      string symbol = g_pairs[idx].symbol;
      int posCount = 0;
      double latestPrice = 0;
      datetime latestTime = 0;

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

         posCount++;
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime > latestTime)
         {
            latestTime  = openTime;
            latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }

      if(posCount > 0)
      {
         g_pairs[idx].nanpinCount    = posCount - 1;
         g_pairs[idx].lastEntryPrice = latestPrice;
         PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 状態復元: ポジション数=%d, ナンピン=%d",
                    g_patternNames[g_pairs[idx].patternIndex],
                    symbol, posCount, g_pairs[idx].nanpinCount);
      }
   }
}

//--- CountPositions ---
int CountPositions(int idx)
{
   int magic = g_pairs[idx].magicNumber;
   string symbol = g_pairs[idx].symbol;
   int count = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      count++;
   }
   return count;
}

//--- IsTradingHour ---
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

//--- IsSpreadOK ---
bool IsSpreadOK(int idx)
{
   if(MaxSpread <= 0) return true;

   double ask = SymbolInfoDouble(g_pairs[idx].symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_pairs[idx].symbol, SYMBOL_BID);
   double spreadPips = (ask - bid) / g_pairs[idx].pip;
   return (spreadPips <= MaxSpread);
}
