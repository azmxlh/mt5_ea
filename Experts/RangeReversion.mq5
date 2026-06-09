//+------------------------------------------------------------------+
//| RangeReversion.mq5 - ボリンジャーバンド逆張りレンジEA           |
//| エントリー: スクイーズ(レンジ)検出 + ±2σタッチで逆張り        |
//| 利確(TP): 中央線（ミドルバンド）                                |
//| 損切(SL): レンジ帯の外側（±3σ = レンジブレイクで撤退）        |
//| 複利対応 / マルチペア / RSIフィルター                            |
//+------------------------------------------------------------------+
#property copyright "RangeReversion EA"
#property version   "1.00"
#property strict

//--- 通貨ペア設定
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY,AUDJPY";
input int      MagicBase         = 79000;

//--- 複利設定
input bool     CompoundMode      = true;
input double   BalancePerLot     = 100000;
input double   BaseLots          = 0.1;
input double   FixedLot          = 0.1;
input bool     MicroMode         = false;

//--- BB設定
input int      BB_Period         = 20;          // BB期間
input double   BB_Deviation      = 2.0;         // エントリー用BB偏差（±2σ）
input ENUM_TIMEFRAMES BB_TF      = PERIOD_H1;   // BB時間足（レンジはH1が適切）

//--- レンジ（スクイーズ）判定設定
input int      Squeeze_Lookback  = 20;          // バンド幅の平均を計算する過去バー数
input double   Squeeze_Mult     = 0.9;          // バンド幅がこの倍率以下でスクイーズ（レンジ）判定
input int      Squeeze_MinBars  = 3;            // スクイーズが最低何バー継続しているか

//--- SL/TP設定
input double   SL_Sigma         = 2.5;          // 損切りラインのσ（レンジ帯の外側）
input double   TP_Sigma         = 0.5;          // 利確ラインのσ（0=中央線、正の値=中央から反対側へのσ）
input double   SL_Extra_Pips    = 3.0;          // SLに追加するバッファ(pips)

//--- RSIフィルター（逆張り確認）
input bool     RSI_Enabled      = true;         // RSIフィルター(有効/無効)
input int      RSI_Period       = 14;           // RSI期間
input double   RSI_Oversold     = 35.0;         // 買い:RSIがこの値以下で買い許可
input double   RSI_Overbought   = 65.0;         // 売り:RSIがこの値以上で売り許可

//--- ADXフィルター（レンジ確認: ADXが低い=レンジ）
input bool     ADXFilter_Enabled = true;        // ADXフィルター(有効/無効)
input int      ADXFilter_Period  = 14;          // ADX期間
input double   ADXFilter_Max    = 20.0;         // ADXがこの値以下ならレンジと判定（逆張りOK）
input ENUM_TIMEFRAMES ADXFilter_TF = PERIOD_H4; // ADX判定の時間足

//--- エントリー条件
input double   BB_Touch_Margin  = 0.0;          // バンドタッチ判定のマージン（pips, 0=厳密にタッチ）
input bool     RequireReversal  = true;         // 反転足確認（ヒゲでタッチ→実体が戻る足）
input bool     AllowNearTouch   = true;         // ニアタッチ許可（バンドに近づいた足も反転判定対象）
input double   NearTouch_Sigma  = 1.8;          // ニアタッチ判定のσ閾値（2.0σ未満でもこの値以上ならOK）

//--- リスク管理
input double   MaxSpread_Pips   = 3.0;
input int      TradingStartHour = 0;
input int      TradingEndHour   = 0;
input int      ReentryCooldown  = 8;            // 決済後の再エントリー抑制(時間)
input int      MaxTotalPositions = 10;
input int      MaxPosPerPair    = 1;            // 1ペアあたりの最大ポジション数

//--- 許可口座
input string   AllowedAccounts  = "";           // 空=全口座許可

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
int    handleRSI[];
int    handleADX[];
bool   pairEnabled[];
datetime lastCloseTime[];
datetime lastBarTime[];

//+------------------------------------------------------------------+
double GetMinLot()
{
   return MicroMode ? 0.1 : 0.01;
}

//+------------------------------------------------------------------+
int OnInit()
{
   // 口座チェック
   if(StringLen(AllowedAccounts) > 0 && !IsAccountAllowed()) {
      Print("[RangeReversion ERROR] この口座では使用できません: ", AccountInfoInteger(ACCOUNT_LOGIN));
      return INIT_FAILED;
   }

   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) {
      Print("[RangeReversion ERROR] 通貨ペアが指定されていません");
      return INIT_FAILED;
   }

   ArrayResize(handleBB, pairCount);
   ArrayResize(handleRSI, pairCount);
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
         PrintFormat("[RangeReversion WARN] シンボル選択失敗（スキップ）: %s", pairs[i]);
         handleBB[i] = INVALID_HANDLE;
         pairEnabled[i] = false;
         continue;
      }

      // BBハンドル（エントリー判定用はBB_Deviation、SL計算はコード内で行う）
      handleBB[i] = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(handleBB[i] == INVALID_HANDLE) {
         PrintFormat("[RangeReversion WARN] BBインジケータ作成失敗（スキップ）: %s", pairs[i]);
         pairEnabled[i] = false;
         continue;
      }

      // RSIハンドル
      if(RSI_Enabled) {
         handleRSI[i] = iRSI(pairs[i], BB_TF, RSI_Period, PRICE_CLOSE);
         if(handleRSI[i] == INVALID_HANDLE) {
            PrintFormat("[RangeReversion WARN] RSIインジケータ作成失敗（スキップ）: %s", pairs[i]);
            pairEnabled[i] = false;
            continue;
         }
      } else {
         handleRSI[i] = INVALID_HANDLE;
      }

      // ADXハンドル
      if(ADXFilter_Enabled) {
         handleADX[i] = iADX(pairs[i], ADXFilter_TF, ADXFilter_Period);
         if(handleADX[i] == INVALID_HANDLE) {
            PrintFormat("[RangeReversion WARN] ADXインジケータ作成失敗（スキップ）: %s", pairs[i]);
            pairEnabled[i] = false;
            continue;
         }
      } else {
         handleADX[i] = INVALID_HANDLE;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) {
      Print("[RangeReversion ERROR] 有効な通貨ペアがありません");
      return INIT_FAILED;
   }

   PrintFormat("[RangeReversion] 初期化完了: ペア=%d/%d, 複利=%s, BB(%d,%.1f) on %s, SL=%.1fσ",
              enabledCount, pairCount,
              CompoundMode ? "ON" : "OFF",
              BB_Period, BB_Deviation,
              EnumToString(BB_TF), SL_Sigma);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleRSI[i] != INVALID_HANDLE) IndicatorRelease(handleRSI[i]);
      if(handleADX[i] != INVALID_HANDLE) IndicatorRelease(handleADX[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;

      int magic = MagicBase + i;
      string sym = pairs[i];

      // 新規エントリー（バー確定ベース）
      if(!IsNewBar(sym, i)) continue;
      if(!IsTradingHour()) continue;
      if(!IsSpreadOK(sym)) continue;

      // 既にポジションがある場合はスキップ（SL/TPで決済されるため管理不要）
      if(CountPositions(sym, magic) >= MaxPosPerPair) continue;
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;

      // クールダウン
      if(ReentryCooldown > 0 && lastCloseTime[i] > 0) {
         if(TimeCurrent() - lastCloseTime[i] < ReentryCooldown * 3600) continue;
      }

      // エントリーチェック
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
// エントリー判定:
// 1. スクイーズ（レンジ）を検出
// 2. 価格が±2σにタッチ
// 3. RSIが売られすぎ/買われすぎ
// 4. ADXが低い（トレンドなし）
// → 逆張りエントリー（SL/TP注文付き）
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double bb_mid[], bb_upper[], bb_lower[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);

   int needBars = Squeeze_Lookback + Squeeze_MinBars + 3;
   if(CopyBuffer(handleBB[idx], 0, 0, needBars, bb_mid) < needBars) return;
   if(CopyBuffer(handleBB[idx], 1, 0, needBars, bb_upper) < needBars) return;
   if(CopyBuffer(handleBB[idx], 2, 0, needBars, bb_lower) < needBars) return;

   // === スクイーズ（レンジ）判定 ===
   // 直近のバンド幅が、過去平均に対して一定倍率以下ならレンジ
   double currentBW = bb_upper[1] - bb_lower[1];
   double avgBW = 0;
   for(int k = 2; k < Squeeze_Lookback + 2; k++) {
      avgBW += bb_upper[k] - bb_lower[k];
   }
   avgBW /= Squeeze_Lookback;

   if(avgBW <= 0) return;
   if(currentBW > avgBW * Squeeze_Mult) return;  // バンドが広い=トレンド中=逆張りNG

   // スクイーズ継続チェック
   if(Squeeze_MinBars > 1) {
      for(int s = 1; s < Squeeze_MinBars; s++) {
         double bw = bb_upper[s + 1] - bb_lower[s + 1];
         if(bw > avgBW * Squeeze_Mult) return;  // 過去にバンドが広い足があればNG
      }
   }

   // === ADXフィルター（低ADX=レンジ確認）===
   if(ADXFilter_Enabled && !IsADXBelowMax(sym, idx)) return;

   // === エントリーシグナル判定 ===
   double close1 = iClose(sym, BB_TF, 1);
   double open1  = iOpen(sym, BB_TF, 1);
   double high1  = iHigh(sym, BB_TF, 1);
   double low1   = iLow(sym, BB_TF, 1);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double touchMargin = BB_Touch_Margin * point * 10;  // pips → price

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // σ1単位の幅を計算（SL/TP計算に使用）
   double sigmaWidth = (bb_upper[1] - bb_mid[1]) / BB_Deviation;
   if(sigmaWidth <= 0) return;

   // === Buy条件: 下限バンドにタッチ + 反転 ===
   bool buyTouch = false;
   if(RequireReversal) {
      // ヒゲが-2σ以下にタッチし、実体は-2σの上で引ける（反転足）
      buyTouch = (low1 <= bb_lower[1] + touchMargin) && (close1 > bb_lower[1]);
      // ニアタッチ: ヒゲが-1.7σ以下まで到達し、実体が戻った足もOK
      if(!buyTouch && AllowNearTouch) {
         double nearLevel = bb_mid[1] - sigmaWidth * NearTouch_Sigma;
         buyTouch = (low1 <= nearLevel + touchMargin) && (close1 > nearLevel) && (close1 > open1);
      }
   } else {
      // 終値が-2σ以下にタッチ
      buyTouch = (close1 <= bb_lower[1] + touchMargin);
   }

   if(buyTouch) {
      // RSIフィルター
      if(RSI_Enabled && !IsRSIOversold(idx)) return;

      // SL/TP計算
      double entryPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double slPrice = bb_mid[1] - sigmaWidth * SL_Sigma - SL_Extra_Pips * point * 10;
      double tpPrice;
      if(TP_Sigma == 0)
         tpPrice = bb_mid[1];  // 中央線で利確
      else
         tpPrice = bb_mid[1] + sigmaWidth * TP_Sigma;  // 中央線より上

      slPrice = NormalizeDouble(slPrice, digits);
      tpPrice = NormalizeDouble(tpPrice, digits);

      // SLが有効か確認（エントリー価格よりSLが下にある）
      if(slPrice >= entryPrice) return;
      // TPが有効か確認（エントリー価格よりTPが上にある）
      if(tpPrice <= entryPrice) return;

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_BUY, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeReversion][%s] BUY @ %.5f, SL=%.5f (%.1fpips), TP=%.5f (%.1fpips)",
                    sym, entryPrice, slPrice,
                    (entryPrice - slPrice) / point / 10,
                    tpPrice,
                    (tpPrice - entryPrice) / point / 10);
      }
      return;
   }

   // === Sell条件: 上限バンドにタッチ + 反転 ===
   bool sellTouch = false;
   if(RequireReversal) {
      // ヒゲが+2σ以上にタッチし、実体は+2σの下で引ける（反転足）
      sellTouch = (high1 >= bb_upper[1] - touchMargin) && (close1 < bb_upper[1]);
      // ニアタッチ: ヒゲが+1.7σ以上まで到達し、実体が戻った足もOK
      if(!sellTouch && AllowNearTouch) {
         double nearLevel = bb_mid[1] + sigmaWidth * NearTouch_Sigma;
         sellTouch = (high1 >= nearLevel - touchMargin) && (close1 < nearLevel) && (close1 < open1);
      }
   } else {
      // 終値が+2σ以上にタッチ
      sellTouch = (close1 >= bb_upper[1] - touchMargin);
   }

   if(sellTouch) {
      // RSIフィルター
      if(RSI_Enabled && !IsRSIOverbought(idx)) return;

      // SL/TP計算
      double entryPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      double slPrice = bb_mid[1] + sigmaWidth * SL_Sigma + SL_Extra_Pips * point * 10;
      double tpPrice;
      if(TP_Sigma == 0)
         tpPrice = bb_mid[1];  // 中央線で利確
      else
         tpPrice = bb_mid[1] - sigmaWidth * TP_Sigma;  // 中央線より下

      slPrice = NormalizeDouble(slPrice, digits);
      tpPrice = NormalizeDouble(tpPrice, digits);

      // SLが有効か確認（エントリー価格よりSLが上にある）
      if(slPrice <= entryPrice) return;
      // TPが有効か確認（エントリー価格よりTPが下にある）
      if(tpPrice >= entryPrice) return;

      double lot = CalcLot(sym);
      if(OpenOrder(sym, ORDER_TYPE_SELL, lot, magic, slPrice, tpPrice)) {
         PrintFormat("[RangeReversion][%s] SELL @ %.5f, SL=%.5f (%.1fpips), TP=%.5f (%.1fpips)",
                    sym, entryPrice, slPrice,
                    (slPrice - entryPrice) / point / 10,
                    tpPrice,
                    (entryPrice - tpPrice) / point / 10);
      }
      return;
   }
}

//+------------------------------------------------------------------+
// ADXフィルター: ADXが指定値以下ならレンジ（逆張りOK）
//+------------------------------------------------------------------+
bool IsADXBelowMax(string sym, int idx)
{
   if(handleADX[idx] == INVALID_HANDLE) return true;

   double adx[];
   ArraySetAsSeries(adx, true);
   if(CopyBuffer(handleADX[idx], 0, 0, 2, adx) < 2) return true;

   double currentADX = adx[1];
   if(currentADX > ADXFilter_Max) {
      return false;  // ADXが高い = トレンド中 = 逆張りNG
   }
   return true;
}

//+------------------------------------------------------------------+
// RSIフィルター: 売られすぎ確認（買い用）
//+------------------------------------------------------------------+
bool IsRSIOversold(int idx)
{
   if(handleRSI[idx] == INVALID_HANDLE) return true;

   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleRSI[idx], 0, 0, 2, rsi) < 2) return true;

   return (rsi[1] <= RSI_Oversold);
}

//+------------------------------------------------------------------+
// RSIフィルター: 買われすぎ確認（売り用）
//+------------------------------------------------------------------+
bool IsRSIOverbought(int idx)
{
   if(handleRSI[idx] == INVALID_HANDLE) return true;

   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handleRSI[idx], 0, 0, 2, rsi) < 2) return true;

   return (rsi[1] >= RSI_Overbought);
}

//+------------------------------------------------------------------+
// ロット計算
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
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

//+------------------------------------------------------------------+
// 注文発行（SL/TP付き成行注文）
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
   req.deviation    = 30;
   req.magic        = magic;
   req.comment      = "RangeRev";
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      if(res.retcode == 10030) {
         req.type_filling = (req.type_filling == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC : ORDER_FILLING_FOK;
         if(!OrderSend(req, res)) {
            PrintFormat("[RangeReversion ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
            return false;
         }
      } else {
         PrintFormat("[RangeReversion ERROR] 注文失敗: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
         return false;
      }
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
