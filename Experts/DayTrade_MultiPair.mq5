//+------------------------------------------------------------------+
//|                                      DayTrade_MultiPair.mq5       |
//|              デイトレード（スイング）型 多通貨ペアEA               |
//|              BB逆張り + マーチンゲールナンピン + 複利              |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property version   "5.00"
#property strict

//--- 入力パラメータ
input string   SymbolList        = "USDJPY,EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY,AUDJPY,NZDJPY,CADJPY,CHFJPY,EURGBP,EURAUD,EURNZD,EURCAD,EURCHF,GBPAUD,GBPNZD,GBPCAD,GBPCHF,AUDNZD,AUDCAD,AUDCHF,NZDCAD,NZDCHF,CADCHF";
input int      MagicBase         = 55000;

//--- 複利設定
input bool     CompoundMode      = true;        // 複利モード (true=有効)
input double   BalancePerLot     = 100000;      // 1ロット単位あたりの必要残高 (円)
input double   BaseLots          = 0.01;        // 複利計算の基準ロット
input double   BaseLot           = 0.01;        // 固定ロット（複利OFF時）
input bool     MicroMode         = false;

//--- ロットスケール設定（残高に応じてBalancePerLotに倍率適用）
input bool     Decay_Enabled     = true;         // 複利逓減を有効化
input double   Decay_Step        = 5000000;      // この金額増えるごとに倍率を下げる（例:500万）
input double   Decay_Reduce      = 0.2;          // 1段階ごとに下げる倍率（例:0.2→1.0,0.8,0.6...）
input double   Decay_MinMulti    = 0.4;          // 最低倍率（これ以下にはならない）
input double   Decay_BaseBalance = 10000000.0;   // 基準残高（0=起動時の残高を自動使用）

//--- BB設定
input int      BB_Period         = 20;
input double   BB_Deviation      = 2.0;
input ENUM_TIMEFRAMES BB_TF      = PERIOD_M15;

//--- RSI設定
input int      RSI_Period        = 14;
input int      RSI_OB           = 60;
input int      RSI_OS           = 30;
input ENUM_TIMEFRAMES RSI_TF     = PERIOD_M15;

//--- ATR設定
input int      ATR_Period        = 14;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H1;

//--- ナンピン設定
input double   Nanpin_ATR_Multi  = 20.0;         // ナンピン間隔（ATR倍率）※広めに
input double   Nanpin_LotMulti   = 20.0;         // ロット倍率
input int      Nanpin_MaxCount   = 1;           // 最大ナンピン回数

//--- 利確設定
input double   TP_Pips           = 3.0;         // 平均建値+N pips
input bool     TP_UseMidBand     = true;        // ミドルバンド利確

//--- 日次決済設定
input bool     ForceClose_Enabled = false;
input int      ForceClose_Hour   = 23;
input int      ForceClose_Minute = 30;

//--- 損失制限
input double   MaxDailyLoss_Percent = 0;        // 0=無効

//--- 最大保有日数（安全装置）
input int      MaxHoldDays       = 0;           // 0=無制限

//--- 許可口座
input string   AllowedAccounts   = "75545335,70643523,75548484,370394526";

//--- ポジション数制限・再エントリー抑制
input int      MaxTotalPositions  = 0;           // 全ペア合計の最大同時ポジション数 (0=無制限)
input int      ReentryCooldown    = 60;          // 決済後の再エントリー抑制時間（分）(0=無効)

//--- 内部変数
string pairs[];
int    pairCount;
int    handleBB[];
int    handleRSI[];
int    handleATR[];
bool   pairEnabled[];       // ペアが有効かどうか
double initialBalance = 0;  // 初回残高記録用
datetime lastCloseTime[];   // 各ペアの直近決済時刻

//+------------------------------------------------------------------+
int OnInit()
{
   // 口座チェック
   if(!IsAccountAllowed()) {
      Print("この口座では使用できません: ", AccountInfoInteger(ACCOUNT_LOGIN));
      return INIT_FAILED;
   }

   // ペアリスト分割
   pairCount = StringSplit(SymbolList, ',', pairs);
   if(pairCount <= 0) {
      Print("通貨ペアが指定されていません");
      return INIT_FAILED;
   }

   ArrayResize(handleBB, pairCount);
   ArrayResize(handleRSI, pairCount);
   ArrayResize(handleATR, pairCount);
   ArrayResize(pairEnabled, pairCount);
   ArrayResize(lastCloseTime, pairCount);
   ArrayInitialize(lastCloseTime, 0);

   int enabledCount = 0;
   for(int i = 0; i < pairCount; i++) {
      StringTrimRight(pairs[i]);
      StringTrimLeft(pairs[i]);

      // シンボルが利用可能か確認
      if(!SymbolSelect(pairs[i], true)) {
         PrintFormat("[警告] シンボル選択失敗（スキップ）: %s", pairs[i]);
         handleBB[i] = INVALID_HANDLE;
         handleRSI[i] = INVALID_HANDLE;
         handleATR[i] = INVALID_HANDLE;
         pairEnabled[i] = false;
         continue;
      }

      handleBB[i] = iBands(pairs[i], BB_TF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      handleRSI[i] = iRSI(pairs[i], RSI_TF, RSI_Period, PRICE_CLOSE);
      handleATR[i] = iATR(pairs[i], ATR_TF, ATR_Period);

      if(handleBB[i] == INVALID_HANDLE || handleRSI[i] == INVALID_HANDLE || handleATR[i] == INVALID_HANDLE) {
         PrintFormat("[警告] インジケータ作成失敗（スキップ）: %s", pairs[i]);
         // 作成済みハンドルを解放
         if(handleBB[i] != INVALID_HANDLE) { IndicatorRelease(handleBB[i]); handleBB[i] = INVALID_HANDLE; }
         if(handleRSI[i] != INVALID_HANDLE) { IndicatorRelease(handleRSI[i]); handleRSI[i] = INVALID_HANDLE; }
         if(handleATR[i] != INVALID_HANDLE) { IndicatorRelease(handleATR[i]); handleATR[i] = INVALID_HANDLE; }
         pairEnabled[i] = false;
         continue;
      }

      pairEnabled[i] = true;
      enabledCount++;
   }

   if(enabledCount == 0) {
      Print("有効な通貨ペアがありません。すべてのインジケータ作成に失敗しました。");
      return INIT_FAILED;
   }

   PrintFormat("DayTrade_MultiPair V5 初期化完了 有効ペア数=%d/%d 複利=%s", enabledCount, pairCount, CompoundMode ? "ON" : "OFF");

   // 基準残高の設定
   if(Decay_BaseBalance > 0)
      initialBalance = Decay_BaseBalance;
   else
      initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(Decay_Enabled && CompoundMode)
      PrintFormat("複利逓減: 基準残高=%.0f ステップ=%.0f 減少幅=%.2f 最低倍率=%.2f",
                  initialBalance, Decay_Step, Decay_Reduce, Decay_MinMulti);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < pairCount; i++) {
      if(handleBB[i] != INVALID_HANDLE) IndicatorRelease(handleBB[i]);
      if(handleRSI[i] != INVALID_HANDLE) IndicatorRelease(handleRSI[i]);
      if(handleATR[i] != INVALID_HANDLE) IndicatorRelease(handleATR[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < pairCount; i++) {
      if(!pairEnabled[i]) continue;  // 無効ペアはスキップ

      int magic = MagicBase + i;
      string sym = pairs[i];

      // 日次強制決済
      if(ForceClose_Enabled) CheckForceClose(sym, magic, i);

      // 日次損失チェック
      if(MaxDailyLoss_Percent > 0 && IsDailyLossExceeded()) continue;

      // 最大保有日数チェック
      if(MaxHoldDays > 0) CheckMaxHoldDays(sym, magic, i);

      // 利確チェック
      CheckTakeProfit(sym, magic, i);

      // 既存ポジション → ナンピンチェック
      if(CountPositions(sym, magic) > 0) {
         CheckNanpin(sym, magic, i);
         continue;
      }

      // 最大同時ポジション数チェック（全ペア合計）
      if(MaxTotalPositions > 0 && CountAllPositions() >= MaxTotalPositions) continue;

      // 決済後クールダウンチェック
      if(ReentryCooldown > 0 && lastCloseTime[i] > 0) {
         if(TimeCurrent() - lastCloseTime[i] < ReentryCooldown * 60) continue;
      }

      // 新規エントリー
      CheckEntry(sym, magic, i);
   }
}

//+------------------------------------------------------------------+
// 複利ロット計算（BalancePerLot方式）
//+------------------------------------------------------------------+
double CalcLot(string sym)
{
   if(!CompoundMode) {
      return BaseLot;
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // 基本ロット = 残高 ÷ BalancePerLot × BaseLots
   // 例: 残高500万、100万あたり0.01ロット → 5 × 0.01 = 0.05ロット
   double lot = (balance / BalancePerLot) * BaseLots;

   // 複利逓減: 残高が基準からステップ分増えるごとに倍率を一定値ずつ下げる
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

   // ロットステップ調整
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

//+------------------------------------------------------------------+
int GetPairIndex(string sym)
{
   for(int i = 0; i < pairCount; i++)
      if(pairs[i] == sym) return i;
   return -1;
}

//+------------------------------------------------------------------+
// 新規エントリー
//+------------------------------------------------------------------+
void CheckEntry(string sym, int magic, int idx)
{
   double bb_upper[], bb_lower[], bb_mid[], rsi[], atr[];

   if(CopyBuffer(handleBB[idx], 1, 1, 1, bb_upper) <= 0) return;  // Upper
   if(CopyBuffer(handleBB[idx], 2, 1, 1, bb_lower) <= 0) return;  // Lower
   if(CopyBuffer(handleBB[idx], 0, 1, 1, bb_mid) <= 0) return;    // Middle
   if(CopyBuffer(handleRSI[idx], 0, 1, 1, rsi) <= 0) return;
   if(CopyBuffer(handleATR[idx], 0, 0, 1, atr) <= 0) return;

   double close = iClose(sym, BB_TF, 1);
   double lot = CalcLot(sym);

   // 売りシグナル: 上バンド超え + RSI > OB
   if(close > bb_upper[0] && rsi[0] > RSI_OB) {
      OpenOrder(sym, ORDER_TYPE_SELL, lot, magic);
      return;
   }

   // 買いシグナル: 下バンド割れ + RSI < OS
   if(close < bb_lower[0] && rsi[0] < RSI_OS) {
      OpenOrder(sym, ORDER_TYPE_BUY, lot, magic);
      return;
   }
}

//+------------------------------------------------------------------+
// ナンピンチェック
//+------------------------------------------------------------------+
void CheckNanpin(string sym, int magic, int idx)
{
   int posCount = CountPositions(sym, magic);
   if(posCount >= Nanpin_MaxCount + 1) return; // 初期+ナンピン回数

   double atr[];
   if(CopyBuffer(handleATR[idx], 0, 0, 1, atr) <= 0) return;

   double nanpinDistance = atr[0] * Nanpin_ATR_Multi;
   double avgPrice = GetAveragePrice(sym, magic);
   double currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
   int direction = GetPositionDirection(sym, magic);

   if(direction == 0) return;

   double baseLot = GetFirstLot(sym, magic);
   double nextLot = baseLot * MathPow(Nanpin_LotMulti, posCount);

   // ロットステップ調整
   double stepLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   nextLot = MathFloor(nextLot / stepLot) * stepLot;
   nextLot = MathMax(nextLot, minLot);
   nextLot = MathMin(nextLot, maxLot);

   if(direction == 1) { // Buy
      double lastEntry = GetLastEntryPrice(sym, magic);
      if(currentPrice <= lastEntry - nanpinDistance) {
         OpenOrder(sym, ORDER_TYPE_BUY, nextLot, magic);
      }
   } else { // Sell
      currentPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      double lastEntry = GetLastEntryPrice(sym, magic);
      if(currentPrice >= lastEntry + nanpinDistance) {
         OpenOrder(sym, ORDER_TYPE_SELL, nextLot, magic);
      }
   }
}

//+------------------------------------------------------------------+
// 利確チェック
//+------------------------------------------------------------------+
void CheckTakeProfit(string sym, int magic, int idx)
{
   if(CountPositions(sym, magic) == 0) return;

   double avgPrice = GetAveragePrice(sym, magic);
   int direction = GetPositionDirection(sym, magic);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double currentBid = SymbolInfoDouble(sym, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(sym, SYMBOL_ASK);

   bool doClose = false;

   if(direction == 1) { // Buy
      // 平均建値+Npips
      if(currentBid >= avgPrice + TP_Pips * 10 * point)
         doClose = true;

      // ミドルバンド利確
      if(TP_UseMidBand) {
         double bb_mid[];
         if(CopyBuffer(handleBB[idx], 0, 0, 1, bb_mid) > 0) {
            if(currentBid >= bb_mid[0] && currentBid >= avgPrice)
               doClose = true;
         }
      }
   } else if(direction == -1) { // Sell
      if(currentAsk <= avgPrice - TP_Pips * 10 * point)
         doClose = true;

      if(TP_UseMidBand) {
         double bb_mid[];
         if(CopyBuffer(handleBB[idx], 0, 0, 1, bb_mid) > 0) {
            if(currentAsk <= bb_mid[0] && currentAsk <= avgPrice)
               doClose = true;
         }
      }
   }

   if(doClose) {
      CloseAllPositions(sym, magic);
      lastCloseTime[idx] = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
// 最大保有日数チェック
//+------------------------------------------------------------------+
void CheckMaxHoldDays(string sym, int magic, int idx)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int holdDays = (int)((TimeCurrent() - openTime) / 86400);

      if(holdDays >= MaxHoldDays) {
         CloseAllPositions(sym, magic);
         lastCloseTime[idx] = TimeCurrent();
         PrintFormat("[MaxHold] %s %d日経過 → 全決済", sym, holdDays);
         break;
      }
   }
}

//+------------------------------------------------------------------+
// 日次強制決済
//+------------------------------------------------------------------+
void CheckForceClose(string sym, int magic, int idx)
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour == ForceClose_Hour && dt.min >= ForceClose_Minute) {
      if(CountPositions(sym, magic) > 0) {
         CloseAllPositions(sym, magic);
         lastCloseTime[idx] = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
// 日次損失チェック
//+------------------------------------------------------------------+
bool IsDailyLossExceeded()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (balance - equity) / balance * 100.0;
   return (lossPercent >= MaxDailyLoss_Percent);
}

//+------------------------------------------------------------------+
// ポジション数取得（特定ペア）
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
// ポジション数取得（全ペア合計・このEAのマジックナンバー範囲のみ）
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
// 平均建値計算
//+------------------------------------------------------------------+
double GetAveragePrice(string sym, int magic)
{
   double totalLots = 0;
   double totalCost = 0;

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
// ポジション方向取得
//+------------------------------------------------------------------+
int GetPositionDirection(string sym, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      return (type == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
// 最初のロット取得
//+------------------------------------------------------------------+
double GetFirstLot(string sym, int magic)
{
   datetime oldest = D'2099.01.01';
   double lot = 0.01;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t < oldest) {
         oldest = t;
         lot = PositionGetDouble(POSITION_VOLUME);
      }
   }
   return lot;
}

//+------------------------------------------------------------------+
// 最後のエントリー価格取得
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
      if(t > newest) {
         newest = t;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return price;
}

//+------------------------------------------------------------------+
// 注文発行
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
   req.comment      = "DT_MP_V5";
   req.type_filling = GetFillingMode(sym);

   if(!OrderSend(req, res)) {
      // フィリングモードエラーの場合、別のモードで再試行
      if(res.retcode == 10030) {
         if(req.type_filling == ORDER_FILLING_FOK)
            req.type_filling = ORDER_FILLING_IOC;
         else
            req.type_filling = ORDER_FILLING_FOK;

         if(!OrderSend(req, res)) {
            PrintFormat("[Error] OrderSend failed: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
            return false;
         }
      } else {
         PrintFormat("[Error] OrderSend failed: %s, lot=%.2f, err=%d", sym, lot, res.retcode);
         return false;
      }
   }

   PrintFormat("[Open] %s %s lot=%.4f price=%.5f", sym, (type==ORDER_TYPE_BUY)?"BUY":"SELL", lot, res.price);
   return true;
}

//+------------------------------------------------------------------+
// 全ポジション決済
//+------------------------------------------------------------------+
void CloseAllPositions(string sym, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

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
         // フィリングモードエラーの場合、別のモードで再試行
         if(res.retcode == 10030) {
            if(req.type_filling == ORDER_FILLING_FOK)
               req.type_filling = ORDER_FILLING_IOC;
            else
               req.type_filling = ORDER_FILLING_FOK;

            if(!OrderSend(req, res))
               PrintFormat("[Error] Close failed: %s ticket=%d err=%d", sym, ticket, res.retcode);
         } else {
            PrintFormat("[Error] Close failed: %s ticket=%d err=%d", sym, ticket, res.retcode);
         }
      }
   }
}

//+------------------------------------------------------------------+
// 口座チェック
//+------------------------------------------------------------------+
bool IsAccountAllowed()
{
   string accounts[];
   int cnt = StringSplit(AllowedAccounts, ',', accounts);
   long login = AccountInfoInteger(ACCOUNT_LOGIN);

   for(int i = 0; i < cnt; i++) {
      if(StringToInteger(accounts[i]) == login)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// フィリングモード自動判定
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode(string sym)
{
   long fillMode = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   // FOKが使えればFOK
   if((fillMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;

   // IOCが使えればIOC
   if((fillMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   // どちらも明示的に対応していない場合でもRETURNを試す
   // ※バックテスト環境ではfillModeが0を返すことがある
   // その場合はFOKを使用（バックテストではFOKが通常動作する）
   if(fillMode == 0)
      return ORDER_FILLING_FOK;

   return ORDER_FILLING_RETURN;
}
//+------------------------------------------------------------------+
