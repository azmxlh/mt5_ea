//+------------------------------------------------------------------+
//| TrendNanpinEA_Micro.mq5 - 繝医Ξ繝ｳ繝会ｼ九リ繝ｳ繝斐Φ EA                    |
//| 繝代ち繝ｼ繝ｳA縲廛 隍・焚蜷梧凾遞ｼ蜒榊ｯｾ蠢懃沿・医・繧､繧ｯ繝ｭ蜿｣蠎ｧ迚茨ｼ・                  |
//+------------------------------------------------------------------+
#property copyright "Trend Nanpin EA (Micro)"
#property version   "3.00"
#property strict
#include <Trade/Trade.mqh>

// --- 險ｱ蜿ｯ蜿｣蠎ｧ繝ｪ繧ｹ繝・---
#define ALLOWED_ACCOUNT_COUNT 1
const long g_allowedAccounts[ALLOWED_ACCOUNT_COUNT] = {370394526};

#define PAIR_COUNT     4
#define PATTERN_COUNT  4
#define MAX_PAIRS      (PATTERN_COUNT * PAIR_COUNT)  // 譛螟ｧ16繝壹い

// 繝代ち繝ｼ繝ｳ蛻･繧ｷ繝ｳ繝懊Ν螳夂ｾｩ
const string g_patternSymbols[PATTERN_COUNT][PAIR_COUNT] = {
   {"USDJPYmicro", "GBPJPYmicro", "AUDJPYmicro", "EURAUDmicro"},  // A: 蜀・｣ｲ繧・繝ｦ繝ｼ繝ｭ螢ｲ繧・
   {"NZDJPYmicro", "CADJPYmicro", "CHFJPYmicro", "GBPAUDmicro"},  // B: 蜀・｣ｲ繧雁挨繝壹い+繝昴Φ繝芽ｲｷ縺・
   {"EURUSDmicro", "GBPUSDmicro", "AUDUSDmicro", "USDCHFmicro"},  // C: 繝峨Ν雋ｷ縺・ｸｭ蠢・
   {"EURJPYmicro", "USDJPYmicro", "GBPCHFmicro", "AUDNZDmicro"}   // D: 鬮倬≡蛻ｩ騾夊ｲｨ雋ｷ縺・
};

// 繝代ち繝ｼ繝ｳ蛻･繧ｹ繝ｯ繝・・譁ｹ蜷・
const int g_patternSwapDir[PATTERN_COUNT][PAIR_COUNT] = {
   { 1,  1,  1, -1},  // A: Buy, Buy, Buy, Sell
   { 1,  1,  1, -1},  // B: Buy, Buy, Buy, Sell
   {-1, -1, -1,  1},  // C: Sell, Sell, Sell, Buy
   { 1,  1,  1,  1}   // D: Buy, Buy, Buy, Buy
};

// 繝代ち繝ｼ繝ｳ蜷搾ｼ医Ο繧ｰ逕ｨ・・
const string g_patternNames[PATTERN_COUNT] = {"A", "B", "C", "D"};

// --- 蝓ｺ譛ｬ險ｭ螳・---
input int    Magic_Number       = 563718;
input double Lots               = 0.1;
input bool   SinglePairMode     = false;

// --- 繝代ち繝ｼ繝ｳ譛牙柑/辟｡蜉ｹ・郁､・焚蜷梧凾ON蜿ｯ閭ｽ・・---
input bool   EnablePattern_A    = true;     // 繝代ち繝ｼ繝ｳA (USDJPY,GBPJPY,AUDJPY,EURAUD)
input bool   EnablePattern_B    = false;    // 繝代ち繝ｼ繝ｳB (NZDJPY,CADJPY,CHFJPY,GBPAUD)
input bool   EnablePattern_C    = false;    // 繝代ち繝ｼ繝ｳC (EURUSD,GBPUSD,AUDUSD,USDCHF)
input bool   EnablePattern_D    = false;    // 繝代ち繝ｼ繝ｳD (EURJPY,USDJPY,GBPCHF,AUDNZD)

// --- MA險ｭ螳・---
input int    MA_Period           = 100;
input ENUM_TIMEFRAMES MA_Timeframe = PERIOD_H4;

// --- 繝翫Φ繝斐Φ險ｭ螳・---
input int    Nanpin_Pips         = 50;
input int    Max_Nanpin          = 0;      // 0=辟｡蛻ｶ髯・
input double Lot_Multiplier      = 2.0;

// --- 豎ｺ貂郁ｨｭ螳・---
input int    Profit_Pips         = 30;

// --- 繝ｪ繧ｹ繧ｯ邂｡逅・---
input double MaxSpread           = 5.0;
input int    TradingStartHour    = 0;
input int    TradingEndHour      = 0;

struct PairState {
   string   symbol;
   bool     enabled;
   bool     windingDown;     // true=繝代ち繝ｼ繝ｳOFF縲∵里蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ豎ｺ貂亥ｾ・■
   int      magicNumber;
   int      patternIndex;    // 縺ｩ縺ｮ繝代ち繝ｼ繝ｳ縺ｫ螻槭☆繧九° (0=A,1=B,2=C,3=D)
   int      pairIndex;       // 繝代ち繝ｼ繝ｳ蜀・・繝壹い逡ｪ蜿ｷ (0-3)
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

//--- 繝代ち繝ｼ繝ｳ譛牙柑繝輔Λ繧ｰ蜿門ｾ・---
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
// 謖・ｮ壹・繧ｸ繝・け・・す繝ｳ繝懊Ν縺ｮ繝昴ず繧ｷ繝ｧ繝ｳ縺悟ｭ伜惠縺吶ｋ縺・
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
   // --- 蜿｣蠎ｧ逡ｪ蜿ｷ繝√ぉ繝・け ---
   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   bool accountAllowed = false;
   for(int i = 0; i < ALLOWED_ACCOUNT_COUNT; i++)
   {
      if(accountNumber == g_allowedAccounts[i]) { accountAllowed = true; break; }
   }
   if(!accountAllowed)
   {
      PrintFormat("[TrendNanpin ERROR] 縺薙・蜿｣蠎ｧ(%d)縺ｧ縺ｯ蛻ｩ逕ｨ縺ｧ縺阪∪縺帙ｓ縲りｨｱ蜿ｯ縺輔ｌ縺溷哨蠎ｧ縺ｧ螳溯｡後＠縺ｦ縺上□縺輔＞縲・, accountNumber);
      return(INIT_FAILED);
   }

   // 繝代Λ繝｡繝ｼ繧ｿ讀懆ｨｼ
   if(Lots <= 0)
   { Print("[TrendNanpin ERROR] Lots 縺ｯ豁｣縺ｮ蛟､縺悟ｿ・ｦ・); return(INIT_PARAMETERS_INCORRECT); }
   if(Nanpin_Pips <= 0)
   { Print("[TrendNanpin ERROR] Nanpin_Pips 縺ｯ豁｣縺ｮ蛟､縺悟ｿ・ｦ・); return(INIT_PARAMETERS_INCORRECT); }
   if(Profit_Pips <= 0)
   { Print("[TrendNanpin ERROR] Profit_Pips 縺ｯ豁｣縺ｮ蛟､縺悟ｿ・ｦ・); return(INIT_PARAMETERS_INCORRECT); }
   if(Max_Nanpin < 0)
   { Print("[TrendNanpin ERROR] Max_Nanpin 縺ｯ0莉･荳翫′蠢・ｦ・(0=辟｡蛻ｶ髯・"); return(INIT_PARAMETERS_INCORRECT); }
   if(MA_Period <= 0)
   { Print("[TrendNanpin ERROR] MA_Period 縺ｯ豁｣縺ｮ蛟､縺悟ｿ・ｦ・); return(INIT_PARAMETERS_INCORRECT); }

   // 蟆代↑縺上→繧・縺､縺ｮ繝代ち繝ｼ繝ｳ縺梧怏蜉ｹ縺狗｢ｺ隱搾ｼ・indingDown縺ｮ縺ｿ縺ｧ繧りｵｷ蜍募庄閭ｽ縺ｫ縺吶ｋ縺溘ａ蠕後〒繝√ぉ繝・け・・

   // 繝壹い險ｭ螳壼・譛溷喧・域怏蜉ｹ繝代ち繝ｼ繝ｳ縺ｮ繝壹い繧帝・↓逋ｻ骭ｲ・・
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
            // 譛牙柑繝代ち繝ｼ繝ｳ: 騾壼ｸｸ逋ｻ骭ｲ
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
            // 辟｡蜉ｹ繝代ち繝ｼ繝ｳ: 譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺後≠繧後・windingDown縺ｨ縺励※逋ｻ骭ｲ
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
               PrintFormat("[TrendNanpin INFO][Pat%s][%s] 繝代ち繝ｼ繝ｳOFF - 譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ豎ｺ貂亥ｾ・■繝｢繝ｼ繝・,
                          g_patternNames[pat], sym);
            }
         }
      }
   }

   // 譛牙柑繝壹い縺・縺､繧ゅ↑縺代ｌ縺ｰ繧ｨ繝ｩ繝ｼ
   if(g_activePairCount == 0)
   { Print("[TrendNanpin ERROR] 譛牙柑縺ｪ繝壹い縺後≠繧翫∪縺帙ｓ・医ヱ繧ｿ繝ｼ繝ｳON縺ｾ縺溘・譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺悟ｿ・ｦ・ｼ・); return(INIT_PARAMETERS_INCORRECT); }

   // 繧ｷ繝ｳ繧ｰ繝ｫ繝壹い繝｢繝ｼ繝・
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
         PrintFormat("[TrendNanpin ERROR] 繧ｷ繝ｳ繧ｰ繝ｫ繝壹い繝｢繝ｼ繝・ %s 縺ｯ譛牙柑繝代ち繝ｼ繝ｳ縺ｮ邂｡逅・ｯｾ雎｡螟・, chartSymbol);
         return(INIT_FAILED);
      }
      // 隕九▽縺九▲縺溘・繧｢繧貞・鬆ｭ縺ｫ繧ｳ繝斐・縺励※1繝壹い縺縺醍ｨｼ蜒・
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
      PrintFormat("[TrendNanpin INFO] 繧ｷ繝ｳ繧ｰ繝ｫ繝壹い繝｢繝ｼ繝・ %s 縺ｮ縺ｿ遞ｼ蜒・(繝代ち繝ｼ繝ｳ%s)",
                 chartSymbol, g_patternNames[g_pairs[0].patternIndex]);
   }
   else
   {
      // 繧ｷ繝ｳ繝懊Ν蟄伜惠繝√ぉ繝・け
      for(int i = 0; i < g_activePairCount; i++)
      {
         if(!g_pairs[i].enabled) continue;
         if(!SymbolInfoInteger(g_pairs[i].symbol, SYMBOL_EXIST))
         {
            PrintFormat("[TrendNanpin ERROR] 繧ｷ繝ｳ繝懊Ν蛻ｩ逕ｨ荳榊庄: %s (繝代ち繝ｼ繝ｳ%s)",
                       g_pairs[i].symbol, g_patternNames[g_pairs[i].patternIndex]);
            return(INIT_FAILED);
         }
      }
      PrintFormat("[TrendNanpin INFO] 繝槭Ν繝√・繧｢繝｢繝ｼ繝臥ｨｼ蜒・ %d繝壹い", g_activePairCount);
   }

   // MA繧､繝ｳ繧ｸ繧ｱ繝ｼ繧ｿ繝上Φ繝峨Ν菴懈・ + 繧ｹ繝ｯ繝・・譁ｹ蜷題ｧ｣豎ｺ
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      g_pairs[i].maHandle = iMA(g_pairs[i].symbol, MA_Timeframe, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_pairs[i].maHandle == INVALID_HANDLE)
      {
         PrintFormat("[TrendNanpin ERROR] MA菴懈・螟ｱ謨・ %s, err=%d", g_pairs[i].symbol, GetLastError());
         return(INIT_FAILED);
      }
      GetSwapDirection(i);
   }

   // CTrade蛻晄悄蛹・
   g_trade.SetDeviationInPoints(10);

   // 譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺九ｉ繝翫Φ繝斐Φ迥ｶ諷九ｒ蠕ｩ蜈・
   RestoreStateFromPositions();

   // 襍ｷ蜍輔Ο繧ｰ
   for(int i = 0; i < g_activePairCount; i++)
   {
      if(!g_pairs[i].enabled) continue;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] Magic=%d, SwapDir=%s",
                 g_patternNames[g_pairs[i].patternIndex],
                 g_pairs[i].symbol, g_pairs[i].magicNumber,
                 (g_pairs[i].swapDirection == 1) ? "BUY" : "SELL");
   }

   // 譛牙柑繝代ち繝ｼ繝ｳ荳隕ｧ繝ｭ繧ｰ
   string enabledPatterns = "";
   for(int pat = 0; pat < PATTERN_COUNT; pat++)
   {
      if(IsPatternEnabled(pat))
      {
         if(enabledPatterns != "") enabledPatterns += ",";
         enabledPatterns += g_patternNames[pat];
      }
   }
   PrintFormat("[TrendNanpin INFO] 蛻晄悄蛹門ｮ御ｺ・ 繝代ち繝ｼ繝ｳ=[%s], MA=%d(%s), Nanpin=%dpips, Max=%d, Profit=%dpips",
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
   PrintFormat("[TrendNanpin INFO] EA蛛懈ｭ｢: reason=%d", reason);
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

   // windingDown: 繝代ち繝ｼ繝ｳOFF縺縺梧里蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ豎ｺ貂亥ｾ・■
   if(g_pairs[idx].windingDown)
   {
      // 繝昴ず繧ｷ繝ｧ繝ｳ縺悟・驛ｨ縺ｪ縺上↑縺｣縺溘ｉ辟｡蜉ｹ蛹・
      if(CountPositions(idx) == 0)
      {
         g_pairs[idx].enabled = false;
         PrintFormat("[TrendNanpin INFO][Pat%s][%s] 蜈ｨ繝昴ず繧ｷ繝ｧ繝ｳ豎ｺ貂亥ｮ御ｺ・- 蛛懈ｭ｢",
                    g_patternNames[g_pairs[idx].patternIndex], g_pairs[idx].symbol);
      }
      else
      {
         // 繝翫Φ繝斐Φ縺ｯ邯咏ｶ夲ｼ域ｱｺ貂医ｒ蜉ｩ縺代ｋ・・
         if(IsNewBar(idx))
            CheckNanpin(idx);
      }
      return;
   }

   if(!IsNewBar(idx)) return;

   // 繝ｭ繝・ヨ螟画峩讀懷・: 譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺後≠繧句ｴ蜷医・蜑阪・繝ｭ繝・ヨ縺ｧ邯咏ｶ・
   int posCount = CountPositions(idx);
   double existingLot = GetExistingLot(idx);
   if(existingLot > 0)
   {
      // 譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺ゅｊ・・Ο繝・ヨ荳堺ｸ閾ｴ 竊・蜑阪・繝ｭ繝・ヨ縺ｧ繝翫Φ繝斐Φ邯咏ｶ壹∵眠隕上お繝ｳ繝医Μ繝ｼ縺ｯ縺励↑縺・
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
// 譌｢蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺ｮ蛻晏屓繝ｭ繝・ヨ縺檎樟蝨ｨ縺ｮLots險ｭ螳壹→逡ｰ縺ｪ繧九°蛻､螳・
// 逡ｰ縺ｪ繧句ｴ蜷医∵里蟄倥・繧ｸ繧ｷ繝ｧ繝ｳ縺ｮ繝ｭ繝・ヨ繧定ｿ斐☆・医リ繝ｳ繝斐Φ邯咏ｶ夂畑・・
// 荳閾ｴ or 繝昴ず繧ｷ繝ｧ繝ｳ縺ｪ縺励・蝣ｴ蜷医・0繧定ｿ斐☆
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

   // 蛻晏屓繧ｨ繝ｳ繝医Μ繝ｼ縺ｮ繝ｭ繝・ヨ縺ｨ迴ｾ蝨ｨ險ｭ螳壹ｒ豈碑ｼ・ｼ域ｵｮ蜍募ｰ乗焚轤ｹ隱､蟾ｮ閠・・・・
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

   PrintFormat("[TrendNanpin INFO][%s] 繧ｹ繝ｯ繝・・閾ｪ蜍墓､懷・: Long=%.2f, Short=%.2f 竊・%s",
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
      PrintFormat("[TrendNanpin ERROR][%s] MA蜿門ｾ怜､ｱ謨・ err=%d", g_pairs[idx].symbol, GetLastError());
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
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] 蛻晏屓繧ｨ繝ｳ繝医Μ繝ｼ: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 Lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] 豕ｨ譁・､ｱ謨・ err=%d", symbol, GetLastError());
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

   // 蜷ｫ縺ｿ謳阪メ繧ｧ繝・け・・astEntryPrice縺九ｉ縺ｮ霍晞屬・・
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

   // 繝翫Φ繝斐Φ逋ｺ豕ｨ
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
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] 繝翫Φ繝斐Φ #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] 繝翫Φ繝斐Φ豕ｨ譁・､ｱ謨・ err=%d", symbol, GetLastError());
}

//--- CheckNanpinWithLot ---
// 繝ｭ繝・ヨ螟画峩譎ゅ↓蜑阪・繝ｭ繝・ヨ繝吶・繧ｹ縺ｧ繝翫Φ繝斐Φ邯咏ｶ・
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

   // 蜑阪・繝ｭ繝・ヨ繝吶・繧ｹ縺ｧ繝翫Φ繝斐Φ繝ｭ繝・ヨ險育ｮ暦ｼ・1縺ｧ蛻晏屓繝翫Φ繝斐Φ縺九ｉ蛟咲紫驕ｩ逕ｨ・・
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
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] 繝翫Φ繝斐Φ(譌ｧ繝ｭ繝・ヨ) #%d: %s %.2f lots @ %s",
                 g_patternNames[g_pairs[idx].patternIndex],
                 symbol, g_pairs[idx].nanpinCount,
                 (g_pairs[idx].swapDirection == 1) ? "BUY" : "SELL",
                 lots, DoubleToString(entryPrice, g_pairs[idx].digits));
   }
   else
      PrintFormat("[TrendNanpin ERROR][%s] 繝翫Φ繝斐Φ豕ｨ譁・､ｱ謨・ err=%d", symbol, GetLastError());
}

//--- CalcNanpinLots ---
double CalcNanpinLots(int count)
{
   // count=0(繝翫Φ繝斐Φ1蝗樒岼)縺九ｉ蛟咲紫繧帝←逕ｨ縺吶ｋ・・1縺ｧ蛻晏屓縺九ｉ蛟搾ｼ・
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
         PrintFormat("[TrendNanpin ERROR][%s] 豎ｺ貂亥､ｱ謨・ ticket=%d, err=%d", symbol, ticket, GetLastError());
   }

   if(closed > 0)
   {
      g_pairs[idx].nanpinCount    = 0;
      g_pairs[idx].lastEntryPrice = 0;
      PrintFormat("[TrendNanpin INFO][Pat%s][%s] 荳諡ｬ豎ｺ貂・ %d繝昴ず繧ｷ繝ｧ繝ｳ, 蛻ｩ逶・%.0f",
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
         g_pairs[idx].nanpinCount    = posCount - 1;  // 蛻晏屓繧ｨ繝ｳ繝医Μ繝ｼ蛻・ｒ髯､縺・
         g_pairs[idx].lastEntryPrice = latestPrice;
         PrintFormat("[TrendNanpin INFO][Pat%s][%s] 迥ｶ諷句ｾｩ蜈・ 繝昴ず繧ｷ繝ｧ繝ｳ謨ｰ=%d, 繝翫Φ繝斐Φ蝗樊焚=%d, 逶ｴ霑台ｾ｡譬ｼ=%s",
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
