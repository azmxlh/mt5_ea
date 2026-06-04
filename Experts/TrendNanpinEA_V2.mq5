//+------------------------------------------------------------------+
//| TrendNanpinEA_V2.mq5 - トレンド＋ナンピン EA（複利対応+上位足判定版）|
//| パターンA〜D 複数同時稼働対応版（通常口座版）                       |
//| トレンド判定: 短期MA/長期MAクロス + N本確認                         |
//+------------------------------------------------------------------+
#property copyright "Trend Nanpin EA V2"
#property version   "4.20"
#property strict
#include <Trade/Trade.mqh>

// --- 許可口座リスト ---
#define ALLOWED_ACCOUNT_COUNT 3
const long g_allowedAccounts[ALLOWED_ACCOUNT_COUNT] = {75545335, 70643523, 75548484};

#define PAIR_COUNT     4
#define PATTERN_COUNT  4
#define MAX_PAIRS      (PATTERN_COUNT * PAIR_COUNT)

// パターン別シンボル定義（通常口座）
const string g_patternSymbols[PATTERN_COUNT][PAIR_COUNT] = {
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

// --- 基本設定 ---
input int    Magic_Number       = 847291;
input double Lots               = 0.01;
input bool   SinglePairMode     = false;

// --- 複利設定 ---
input bool   CompoundMode       = false;   // 複利モード (true=有効)
input double BalancePerLot      = 100000;  // 1ロット単位あたりの必要残高 (円)
input double BaseLots           = 0.01;    // 複利計算の基準ロット

// --- パターン有効/無効 ---
input bool   EnablePattern_A    = true;
input bool   EnablePattern_B    = true;
input bool   EnablePattern_C    = true;
input bool   EnablePattern_D    = true;

// --- 上位足トレンド設定（MAクロス + N本確認） ---
input ENUM_TIMEFRAMES TrendMA_Timeframe = PERIOD_W1;  // 上位足時間軸
input int    TrendMA_Short_Period = 5;     // 短期MA期間
input int    TrendMA_Long_Period  = 20;    // 長期MA期間
input int    TrendConfirmBars    = 2;      // クロス維持確認本数

// --- エントリー用MA設定 ---
input int    MA_Period           = 100;
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H4;

// --- ナンピン設定 ---
input int    Nanpin_Pips         = 50;
input int    Max_Nanpin          = 0;      // 0=無制限
input double Lot_Multiplier      = 1.0;

// --- 決済設定 ---
input int    Profit_Pips         = 30;

// --- リスク管理 ---
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
   int      swapDirection;      // +1=BUY, -1=SELL
   int      nanpinCount;
   double   lastEntryPrice;
   datetime lastBarTime;
   datetime lastTrendBarTime;
};

PairState g_pairs[MAX_PAIRS];
CTrade    g_trade;
int       g_activePairCount;

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

   // 既存ポジションがあれば損切り
   int posCount = CountPositions(idx);
   if(posCount > 0)
   {
      PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] トレンド転換による損切り: %dポジション",
                 g_patternNames[g_pairs[idx].patternIndex],
                 g_pairs[idx].symbol, posCount);
      CloseAllPositions(idx);
   }

   // 損切り後に即エントリー
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
   }

   // 初期トレンド方向を設定
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      g_pairs[i].lastTrendBarTime = iTime(g_pairs[i].symbol, TrendMA_Timeframe, 0);

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
         // 確認本数不足時はクロス方向だけで判定
         int crossDir = GetCrossDirection(i, 1);
         if(crossDir != 0)
            g_pairs[i].swapDirection = crossDir;
         PrintFormat("[TrendNanpinV2 INFO][Pat%s][%s] 初期トレンド: %s (確認本数不足→クロス方向で開始)",
                    g_patternNames[g_pairs[i].patternIndex],
                    g_pairs[i].symbol,
                    (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
      }
   }

   g_trade.SetDeviationInPoints(10);
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
   PrintFormat("[TrendNanpinV2 INFO] 初期化完了: パターン=[%s], TrendMA=%d/%d(%s)確認%d本, EntryMA=%d(%s), Nanpin=%dpips, Profit=%dpips, 複利=%s",
              enabledPatterns, TrendMA_Short_Period, TrendMA_Long_Period,
              EnumToString(TrendMA_Timeframe), TrendConfirmBars,
              MA_Period, EnumToString(MA_Timeframe), Nanpin_Pips, Profit_Pips,
              CompoundMode ? StringFormat("ON(%.0f円/%.2fLot)", BalancePerLot, BaseLots) : "OFF");
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
   }
   PrintFormat("[TrendNanpinV2 INFO] EA停止: reason=%d", reason);
}

//--- OnTick ---
void OnTick()
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;

      if(!g_pairs[i].windingDown)
         CheckTrendReversal(i);

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
bool IsTrendAligned(int idx)
{
   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   if(CopyBuffer(g_pairs[idx].maHandle, 0, 0, 1, maBuffer) <= 0)
      return false;

   double ma = maBuffer[0];
   string symbol = g_pairs[idx].symbol;
   double currentPrice = (SymbolInfoDouble(symbol, SYMBOL_ASK) + SymbolInfoDouble(symbol, SYMBOL_BID)) / 2.0;

   if(g_pairs[idx].swapDirection == 1)
      return (currentPrice > ma);
   else
      return (currentPrice < ma);
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

//--- CheckNanpin ---
void CheckNanpin(int idx)
{
   if(Max_Nanpin > 0 && g_pairs[idx].nanpinCount >= Max_Nanpin) return;
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   double lastPrice = g_pairs[idx].lastEntryPrice;

   bool nanpinTrigger = false;
   if(g_pairs[idx].swapDirection == 1)
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      nanpinTrigger = (lastPrice - currentAsk >= Nanpin_Pips * pip);
   }
   else
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      nanpinTrigger = (currentBid - lastPrice >= Nanpin_Pips * pip);
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
   if(!IsTradingHour()) return;
   if(!IsSpreadOK(idx)) return;
   if(!IsTrendAligned(idx)) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   double lastPrice = g_pairs[idx].lastEntryPrice;

   bool nanpinTrigger = false;
   if(g_pairs[idx].swapDirection == 1)
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      nanpinTrigger = (lastPrice - currentAsk >= Nanpin_Pips * pip);
   }
   else
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      nanpinTrigger = (currentBid - lastPrice >= Nanpin_Pips * pip);
   }
   if(!nanpinTrigger) return;

   double lots = baseLot * MathPow(Lot_Multiplier, g_pairs[idx].nanpinCount + 1);
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
   double rawLots = MathFloor(balance / BalancePerLot) * BaseLots;

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
   return baseLot * MathPow(Lot_Multiplier, count + 1);
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

   double avgPrice = CalcAveragePrice(idx);
   if(avgPrice <= 0) return;

   string symbol = g_pairs[idx].symbol;
   double pip = g_pairs[idx].pip;
   bool closeCondition = false;

   if(g_pairs[idx].swapDirection == 1)
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      closeCondition = (currentBid >= avgPrice + Profit_Pips * pip);
   }
   else
   {
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      closeCondition = (currentAsk <= avgPrice - Profit_Pips * pip);
   }

   if(closeCondition)
      CloseAllPositions(idx);
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
