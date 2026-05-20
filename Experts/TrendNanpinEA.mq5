//+------------------------------------------------------------------+
//| TrendNanpinEA.mq5 - トレンド＋ナンピン EA            |
//| パターンA〜D 複数同時稼働対応版（通常口座版）                       |
//+------------------------------------------------------------------+
#property copyright "Trend Nanpin EA"
#property version   "3.00"
#property strict
#include <Trade/Trade.mqh>

// --- 許可口座リスト ---
#define ALLOWED_ACCOUNT_COUNT 2
const long g_allowedAccounts[ALLOWED_ACCOUNT_COUNT] = {75545335, 70643523};

#define PAIR_COUNT     4
#define PATTERN_COUNT  4
#define MAX_PAIRS      (PATTERN_COUNT * PAIR_COUNT)  // 最大16ペア

// パターン別シンボル定義（通常口座）
const string g_patternSymbols[PATTERN_COUNT][PAIR_COUNT] = {
   {"USDJPY", "GBPJPY", "AUDJPY", "EURAUD"},  // A: 円売り+ユーロ売り
   {"NZDJPY", "CADJPY", "CHFJPY", "GBPAUD"},  // B: 円売り別ペア+ポンド買い
   {"EURUSD", "GBPUSD", "AUDUSD", "USDCHF"},  // C: ドル買い中心
   {"EURJPY", "USDJPY", "GBPCHF", "AUDNZD"}   // D: 高金利通貨買い
};

// パターン別スワップ方向
const int g_patternSwapDir[PATTERN_COUNT][PAIR_COUNT] = {
   { 1,  1,  1, -1},  // A: Buy, Buy, Buy, Sell
   { 1,  1,  1, -1},  // B: Buy, Buy, Buy, Sell
   {-1, -1, -1,  1},  // C: Sell, Sell, Sell, Buy
   { 1,  1,  1,  1}   // D: Buy, Buy, Buy, Buy
};

// パターン名（ログ用）
const string g_patternNames[PATTERN_COUNT] = {"A", "B", "C", "D"};

// --- 基本設定 ---
input int    Magic_Number       = 847291;
input double Lots               = 0.01;
input bool   SinglePairMode     = false;

// --- パターン有効/無効（複数同時ON可能） ---
input bool   EnablePattern_A    = true;     // パターンA (USDJPY,GBPJPY,AUDJPY,EURAUD)
input bool   EnablePattern_B    = false;    // パターンB (NZDJPY,CADJPY,CHFJPY,GBPAUD)
input bool   EnablePattern_C    = false;    // パターンC (EURUSD,GBPUSD,AUDUSD,USDCHF)
input bool   EnablePattern_D    = false;    // パターンD (EURJPY,USDJPY,GBPCHF,AUDNZD)

// --- MA設定 ---
input int    MA_Period           = 100;
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H4;

// --- ナンピン設定 ---
input int    Nanpin_Pips         = 50;
input int    Max_Nanpin          = 0;      // 0=無制限
input double Lot_Multiplier      = 2.0;

// --- 決済設定 ---
input int    Profit_Pips         = 30;

// --- リスク管理 ---
input double MaxSpread           = 5.0;
input int    TradingStartHour    = 0;
input int    TradingEndHour      = 0;

struct PairState {
   string   symbol;
   bool     enabled;
   bool     windingDown;     // true=パターンOFF、既存ポジション決済待ち
   int      magicNumber;
   int      patternIndex;    // どのパターンに属するか (0=A,1=B,2=C,3=D)
   int      pairIndex;       // パターン内のペア番号 (0-3)
   double   pip;
   int      digits;
   int      maHandle;
   int      swapDirection;   // +1=BUY, -1=SELL
   int      nanpinCount;
   double   lastEntryPrice;
   datetime lastBarTime;
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
// 指定マジック＆シンボルのポジションが存在するか
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

//--- OnInit ---
int OnInit()
{
   // --- 口座番号チェック ---
   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   bool accountAllowed = false;
   for(int i = 0; i < ALLOWED_ACCOUNT_COUNT; i++)
   {
      if(accountNumber == g_allowedAccounts[i]) { accountAllowed = true; break; }
   }
   if(!accountAllowed)
   {
      PrintFormat("[TrendNanpin ERROR] この口座(%d)では利用できません。許可された口座で実行してください。", accountNumber);
      return(INIT_FAILED);
   }

   // パラメータ検証
   if(Lots <= 0)
   { Print("[TrendNanpin ERROR] Lots は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Nanpin_Pips <= 0)
   { Print("[TrendNanpin ERROR] Nanpin_Pips は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Profit_Pips <= 0)
   { Print("[TrendNanpin ERROR] Profit_Pips は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }
   if(Max_Nanpin < 0)
   { Print("[TrendNanpin ERROR] Max_Nanpin は0以上が必要 (0=無制限)"); return(INIT_PARAMETERS_INCORRECT); }
   if(MA_Period <= 0)
   { Print("[TrendNanpin ERROR] MA_Period は正の値が必要"); return(INIT_PARAMETERS_INCORRECT); }

   // ペア設定初期化（有効パターンのペアを順に登録）
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
            // 有効パターン: 通常登録
            int idx = g_activePairCount;
            g_pairs[idx].symbol         = sym;
            g_pairs[idx].enabled        = true;
            g_pairs[idx].windingDown    = false;
            g_pairs[idx].patternIndex   = pat;
            g_pairs[idx].pairIndex      = p;
            g_pairs[idx].magicNumber    = magic;
            g_pairs[idx].pip            = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
            g_pairs[idx].digits         = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
            g_pairs[idx].swapDirection  = g_patternSwapDir[pat][p];
            g_pairs[idx].maHandle       = INVALID_HANDLE;
            g_pairs[idx].nanpinCount    = 0;
            g_pairs[idx].lastEntryPrice = 0;
            g_pairs[idx].lastBarTime    = 0;
            g_activePairCount++;
         }
         else
         {
            // 無効パターン: 既存ポジションがあればwindingDownとして登録
            if(HasPositionsForMagic(magic, sym))
            {
               int idx = g_activePairCount;
               g_pairs[idx].symbol         = sym;
               g_pairs[idx].enabled        = true;
               g_pairs[idx].windingDown    = true;
               g_pairs[idx].patternIndex   = pat;
               g_pairs[idx].pairIndex      = p;
               g_pairs[idx].magicNumber    = magic;
               g_pairs[idx].pip            = SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
               g_pairs[idx].digits         = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
               g_pairs[idx].swapDirection  = g_patternSwapDir[pat][p];
               g_pairs[idx].maHandle       = INVALID_HANDLE;
               g_pairs[idx].nanpinCount    = 0;
               g_pairs[idx].lastEntryPrice = 0;
               g_pairs[idx].lastBarTime    = 0;
               g_activePairCount++;
               PrintFormat("[TrendNanpin INFO][Pat%s][%s] パターンOFF - 既存ポジション決済待ちモード",
                          g_patternNames[pat], sym);
            }
         }
      }
   }

   // 有効ペアが1つもなければエラー
   if(g_activePairCount == 0)
   { Print("[TrendNanpin ERROR] 有効なペアがありません（パターンONまたは既存ポジションが必要）"); return(INIT_PARAMETERS_INCORRECT); }

   // シングルペアモード
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
         PrintFormat("[TrendNanpin ERROR] シングルペアモード: %s は有効パターンの管理対象外", chartSymbol);
         return(INIT_FAILED);
      }
      // 見つかったペアを先頭にコピーして1ペアだけ稼働
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
      g_pairs[0].magicNumber    = Magic_Number;
      g_pairs[0].windingDown    = false;
      g_pairs[0].maHandle       = INVALID_HANDLE;
      g_pairs[0].nanpinCount    = 0;
      g_pairs[0].lastEntryPrice = 0;
      g_pairs[0].lastBarTime    = 0;
      g_activePairCount = 1;
      PrintFormat("[TrendNanpin INFO] シングルペアモード: %s のみ稼働 (パターン%s)",
                 chartSymbol, g_patternNames[g_pairs[0].patternIndex]);
   }
   else
   {
      // シンボル存在チェック＆気配値表示に自動追加
      for(int i = 0; i < g_activePairCount; i++)
      {
         if(!g_pairs[i].enabled) continue;
         if(!SymbolInfoInteger(g_pairs[i].symbol, SYMBOL_EXIST))
         {
            PrintFormat("[TrendNanpin ERROR] シンボル利用不可: %s (パターン%s)",
                       g_pairs[i].symbol, g_patternNames[g_pairs[i].patternIndex]);
            return(INIT_FAILED);
         }
         // 気配値表示（Market Watch）に追加
         if(!SymbolSelect(g_pairs[i].symbol, true))
         {
            PrintFormat("[TrendNanpin WARN][%s] 気配値への追加に失敗", g_pairs[i].symbol);
         }
      }
      PrintFormat("[TrendNanpin INFO] マルチペアモード稼働: %dペア", g_activePairCount);
   }

   // MAインジケータハンドル作成 + スワップ方向解決
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      g_pairs[i].maHandle = iMA(g_pairs[i].symbol, MA_Timeframe, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].maHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendNanpin ERROR] MA作成失敗: %s, err=%d", g_pairs[i].symbol, GetLastError());
         return(INIT_FAILED);
      }
      GetSwapDirection(i);
   }

   // CTrade初期化
   g_trade.SetDeviationInPoints(10);

   // 既存ポジションからナンピン状態を復元
   RestoreStateFromPositions();

   // 起動ログ
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] Magic=%d, SwapDir=%s",
                 g_patternNames[g_pairs[i].patternIndex],
                 g_pairs[i].symbol, g_pairs[i].magicNumber,
                 (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
   }

   // 有効パターン一覧ログ
   string enabledPatterns = "";
   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      if(IsPatternEnabled(pat))
      {
         if(enabledPatterns != "") enabledPatterns += ",";
         enabledPatterns += g_patternNames[pat];
      }
   }
   PrintFormat("[TrendNanpin INFO] 初期化完了: パターン=[%s], MA=%d(%s), Nanpin=%dpips, Max=%d, Profit=%dpips",
              enabledPatterns, MA_Period, EnumToString(MA_Timeframe), Nanpin_Pips, Max_Nanpin, Profit_Pips);
   return(INIT_SUCCEEDED);
}

//--- OnDeinit ---
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(g_pairs[i].maHandle != INVALID_HANDLE)
      {
         IndicatorRelease(g_pairs[i].maHandle);
         g_pairs[i].maHandle = INVALID_HANDLE;
      }
   }
   PrintFormat("[TrendNanpin INFO] EA停止: reason=%d", reason);
}

//--- OnTick ---
void OnTick()
{
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      ProcessPair(i);
   }
}

//--- ProcessPair ---
void ProcessPair(int idx)
{
   CheckBatchClose(idx);

   // windingDown: パターンOFFだが既存ポジション決済待ち
   if(g_pairs[idx].windingDown)
   {
      // ポジションが全部なくなったら無効化
      if(CountPositions(idx) == 0)
      {
         g_pairs[idx].enabled = false;
         PrintFormat("[TrendNanpin INFO][Pat%s][%s] 全ポジション決済完了 - 停止",
                    g_patternNames[g_pairs[idx].patternIndex], g_pairs[idx].symbol);
      }
      else
      {
         // ナンピンは継続（決済を助ける）
         if(IsNewBar(idx))
            CheckNanpin(idx);
      }
      return;
   }

   if(!IsNewBar(idx)) return;

   // ロット変更検出: 既存ポジションがある場合は前のロットで継続
   int posCount = CountPositions(idx);
   double existingLot = GetExistingLot(idx);
   if(existingLot > 0)
   {
      // 既存ポジションあり＆ロット不一致 → 前のロットでナンピン継続、新規エントリーはしない
      if(posCount > 0)
         CheckNanpinWithLot(idx, existingLot);
      return;
   }

   if(posCount == 0)
      CheckEntry(idx);
   else
      CheckNanpin(idx);
}

//--- IsLotMismatch ---
// 既存ポジションの初回ロットが現在のLots設定と異なるか判定
// 異なる場合、既存ポジションのロットを返す（ナンピン継続用）
// 一致 or ポジションなしの場合は0を返す
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

   // 初回エントリーのロットと現在設定を比較（浮動小数点誤差考慮）
   if(MathAbs(oldestLot - Lots) > 0.0001)
      return oldestLot;

   return 0;
}

//--- GetSwapDirection ---
void GetSwapDirection(int idx)
{
   if(g_pairs[idx].swapDirection == 1 || g_pairs[idx].swapDirection == -1)
      return;

   // Auto-detect
   string symbol = g_pairs[idx].symbol;
   double swapLong  = SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG);
   double swapShort = SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT);

   if(swapLong >= swapShort)
      g_pairs[idx].swapDirection = 1;
   else
      g_pairs[idx].swapDirection = -1;

   PrintFormat("[TrendNanpin INFO][%s] スワップ自動検出: Long=%.2f, Short=%.2f → %s",
              symbol, swapLong, swapShort,
              (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL");
}

//--- IsTrendAligned ---
bool IsTrendAligned(int idx)
{
   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   if(CopyBuffer(g_pairs[idx].maHandle, 0, 0, 1, maBuffer) <= 0)
   {
      PrintFormat("[TrendNanpin ERROR][%s] MA取得失敗: err=%d", g_pairs[idx].symbol, GetLastError());
      return false;
   }

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
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(Lots, symbol, 0, 0, 0, "TrendNanpin");
   else
      result = g_trade.Sell(Lots, symbol, 0, 0, 0, "TrendNanpin");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] 初回エントリー: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 Lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] 注文失敗: err=%d", symbol, GetLastError());
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

   // 含み損チェック（lastEntryPriceからの距離）
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

   // ナンピン発注
   double lots = CalcNanpinLots(g_pairs[idx].nanpinCount);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpin");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpin");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount++;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] ナンピン #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] ナンピン注文失敗: err=%d", symbol, GetLastError());
}

//--- CheckNanpinWithLot ---
// ロット変更時に前のロットベースでナンピン継続
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

   // 前のロットベースでナンピンロット計算（+1で初回ナンピンから倍率適用）
   double lots = baseLot * MathPow(Lot_Multiplier, g_pairs[idx].nanpinCount + 1);
   g_trade.SetExpertMagicNumber(g_pairs[idx].magicNumber);

   bool result = false;
   if(g_pairs[idx].swapDirection == 1)
      result = g_trade.Buy(lots, symbol, 0, 0, 0, "TrendNanpin");
   else
      result = g_trade.Sell(lots, symbol, 0, 0, 0, "TrendNanpin");

   if(result)
   {
      double entryPrice = g_trade.ResultPrice();
      g_pairs[idx].nanpinCount++;
      g_pairs[idx].lastEntryPrice = entryPrice;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] ナンピン(旧ロット) #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] ナンピン注文失敗: err=%d", symbol, GetLastError());
}

//--- CalcNanpinLots ---
double CalcNanpinLots(int count)
{
   // count=0(ナンピン1回目)から倍率を適用する（+1で初回から倍）
   return Lots * MathPow(Lot_Multiplier, count + 1);
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
         PrintFormat("[TrendNanpin ERROR][%s] 決済失敗: ticket=%d, err=%d", symbol, ticket, GetLastError());
   }

   if(closed > 0)
   {
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = 0;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] 一括決済: %dポジション, 利益 %.0f",
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
         g_pairs[idx].nanpinCount    = posCount - 1;  // 初回エントリー分を除く
         g_pairs[idx].lastEntryPrice = latestPrice;
         PrintFormat("[TrendNanpin INFO][Pat%s][%s] 状態復元: ポジション数=%d, ナンピン回数=%d, 直近価格=%s",
                    g_patternNames[g_pairs[idx].patternIndex],
                    symbol, posCount, g_pairs[idx].nanpinCount,
                    DoubleToString(latestPrice, g_pairs[idx].digits));
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
