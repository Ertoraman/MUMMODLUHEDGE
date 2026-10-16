//+------------------------------------------------------------------+
//|                                        Hedge_Grid_Pro_EA.mq5     |
//|               Copyright 2026, Institutional Hybrid Algorithmic EA|
//|    KUSURSUZ ESLESMELI HEDGE GRID (PERPETUAL PAIRED HEDGE GRID)   |
//|    + NET VARLIK (EQUITY) ARTISI ILE OTOMATIK SIFIRLAMA MODU      |
//|    (100 USD Varlik -> 102 USD Oldugunda Sepeti Kapat ve Yeniden) |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Algorithmic Hedge Strategy"
#property link      "https://arena.ai"
#property version   "9.00"
#property description "Her Kademe 1 Buy + 1 Sell Acar, Biri TP Olunca Digeri Sifirda Cikar, Net Varlik Hedefe Ulasinca Sepeti Sifirlar"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMLAR VE SECENEKLER                                            |
//+------------------------------------------------------------------+
enum ENUM_SPACING_MODE
{
   SPACING_MANUAL_PIPS,          // 1. Manuel Sabit Grid Araligi (Pips)
   SPACING_AUTO_ATR,             // 2. Gecmis Mumlardan Otomatik (ATR Bazli)
   SPACING_AUTO_CANDLE_RANGE     // 3. Gecmis Mumlardan Otomatik (High-Low Mum Boyu Ortalamasi)
};

enum ENUM_BASKET_TP_MODE
{
   BASKET_TP_EQUITY_GROWTH,      // 1. Net Varlik (Equity) Hedefi (Orn: 100 USD -> 102 USD) [ONERILEN]
   BASKET_TP_FLOATING_PNL        // 2. Acik Pozisyonlar Yuzen Kar (USD)
};

//+------------------------------------------------------------------+
//| ESLESMELI HEDGE KADEME YAPISI                                    |
//+------------------------------------------------------------------+
struct SPairedLevel
{
   ulong    buyTicket;           // O kademedeki Buy pozisyon bileti
   ulong    sellTicket;          // O kademedeki Sell pozisyon bileti
   double   levelPrice;          // Kademenin acildigi referans fiyat
   bool     buyClosedTP;         // Buy TP oldu mu?
   bool     sellClosedTP;        // Sell TP oldu mu?
   bool     breakevenArmed;      // Diger bacak sifir noktasina (breakeven) kilitlendi mi?
   bool     isCompleted;         // Bu ciftin iki bacagi da kapandi mi?
   datetime openTime;
};

//+------------------------------------------------------------------+
//| INPUT PARAMETRELERI                                              |
//+------------------------------------------------------------------+
input group "=== 1. ESLESMELI HEDGE GRID TEMEL AYARLARI ==="
input ulong    InpMagicNumber        = 654321;          // Bot Magic Numarasi
input double   InpBaseLot            = 0.01;            // Baslangic Lot Boyutu
input int      InpMaxOpenPairs       = 10;              // Maksimum Ayni Anda Takip Edilecek Cift Sayisi
input int      InpSlippagePoints     = 15;              // Maksimum Kayma Toleransi (Puan)

input group "=== 2. GRID ARALIGI HESAPLAMA MODU ==="
input ENUM_SPACING_MODE InpSpacingMode = SPACING_MANUAL_PIPS; // Grid Araligi Belirleme Yontemi
input double   InpManualGridPips     = 5.0;             // [Manuel Mod] Sabit Grid Araligi (Pips)
input int      InpLookbackBars       = 24;              // [Otomatik Mod] Gecmis Mum Tarama Sayisi (Bar)
input double   InpAutoMultiplier     = 1.0;             // [Otomatik Mod] Hesaplanan Mum Araligi Carpani
input int      InpATRPeriod          = 14;              // [ATR Modu] ATR Periyodu

input group "=== 3. SIFIR NOKTASI (BREAKEVEN) VE EMNIYET KORUMASI ==="
input double   InpBreakevenBufferPips= 0.5;             // Basa Bas Cikista Spread Toleransi (Pips)
input bool     InpUseSafetySL        = true;            // Tek Yonlu Kacista Emniyet Stopu (SL)
input double   InpSafetySLMultiplier = 4.0;             // Emniyet Stop Carpani (Grid Adimi x Bu Carpan)

input group "=== 4. SEPET VE NET VARLIK (EQUITY) KAR YONETIMI ==="
input bool                 InpUseBasketTP        = true;                      // Sepet Toplam Kar Kapanisi Aktif
input ENUM_BASKET_TP_MODE  InpBasketTPMode       = BASKET_TP_EQUITY_GROWTH;   // Kar Hesaplama Modu (Varlik Bazli)
input double               InpTargetProfitUSD    = 2.0;                       // Hedef Kar Miktari (USD)
input bool                 InpUseEquityProtection= true;                      // Maksimum Zarar Kes Korumasi
input double               InpMaxDrawdownPercent = 20.0;                      // Maksimum Izin Verilen Hesap Drawdown (%)

//+------------------------------------------------------------------+
//| GLOBAL DEGISKENLER                                               |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accountInfo;

int            atrHandle = INVALID_HANDLE;
double         pipValue = 0.0001;
int            pipsToDigits = 4;

double         currentEffectiveStepPips = 5.0;
double         currentEffectiveStepPrice = 0.00050;
datetime       lastBarProcessed = 0;

// Net Varlık (Equity) Takip Değişkenleri
double         cycleStartEquity = 0.0;
double         targetCycleEquity = 0.0;

// Eslesmeli Kademe Tablosu
SPairedLevel   pairsTable[];

// Istatistikler
double         totalRealizedProfitUSD = 0.0;
int            totalPairsCreated = 0;
int            totalTPHits = 0;
int            totalBreakevenCloses = 0;
int            totalClosedCycles = 0;
datetime       lastHistoryCheck = 0;

//+------------------------------------------------------------------+
//| YARDIMCI PIP VE LOT FONKSIYONLARI                                |
//+------------------------------------------------------------------+
void InitPipFactor()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
   {
      pipValue = 10.0 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      pipsToDigits = digits - 1;
   }
   else
   {
      pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      pipsToDigits = digits;
   }
}

double PipsToPrice(double pips) { return pips * pipValue; }
double PriceToPips(double priceDiff) { return (pipValue > 0) ? MathAbs(priceDiff) / pipValue : 0; }

double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   double normalized = MathFloor(lot / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, normalized));
}

//+------------------------------------------------------------------+
//| GRID ARALIGI HESAPLAMA MOTORU (MANUEL & GECMIS MUMLARDAN OTO)   |
//+------------------------------------------------------------------+
void UpdateGridSpacing()
{
   if(InpSpacingMode == SPACING_MANUAL_PIPS)
   {
      currentEffectiveStepPips = InpManualGridPips;
      currentEffectiveStepPrice = PipsToPrice(currentEffectiveStepPips);
      return;
   }
   
   if(InpSpacingMode == SPACING_AUTO_ATR)
   {
      if(atrHandle != INVALID_HANDLE)
      {
         double b[1];
         if(CopyBuffer(atrHandle, 0, 0, 1, b) > 0 && b[0] > 0)
         {
            double atrPrice = b[0] * InpAutoMultiplier;
            currentEffectiveStepPips = PriceToPips(atrPrice);
            if(currentEffectiveStepPips < 3.0) currentEffectiveStepPips = 3.0;
            currentEffectiveStepPrice = PipsToPrice(currentEffectiveStepPips);
            return;
         }
      }
   }
   
   if(InpSpacingMode == SPACING_AUTO_CANDLE_RANGE)
   {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(_Symbol, _Period, 1, InpLookbackBars, rates);
      if(copied > 0)
      {
         double sumRangePrice = 0.0;
         for(int i = 0; i < copied; i++)
         {
            sumRangePrice += (rates[i].high - rates[i].low);
         }
         double avgCandleRange = (sumRangePrice / copied) * InpAutoMultiplier;
         currentEffectiveStepPips = PriceToPips(avgCandleRange);
         if(currentEffectiveStepPips < 3.0) currentEffectiveStepPips = 3.0;
         currentEffectiveStepPrice = PipsToPrice(currentEffectiveStepPips);
         return;
      }
   }
   
   currentEffectiveStepPips = InpManualGridPips;
   currentEffectiveStepPrice = PipsToPrice(currentEffectiveStepPips);
}

//+------------------------------------------------------------------+
//| GECMIS KAPANAN ISLEMLERDEN REALIZED KAR HAVUZUNU OKU             |
//+------------------------------------------------------------------+
void SyncRealizedProfits()
{
   datetime from = (lastHistoryCheck == 0) ? (TimeCurrent() - 86400 * 3) : lastHistoryCheck;
   datetime to   = TimeCurrent();
   
   if(!HistorySelect(from, to)) return;
   
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t > 0 && HistoryDealGetInteger(t, DEAL_MAGIC) == (long)InpMagicNumber)
      {
         if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            datetime dt = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
            if(dt > lastHistoryCheck)
            {
               double pnl = HistoryDealGetDouble(t, DEAL_PROFIT) + 
                            HistoryDealGetDouble(t, DEAL_SWAP) + 
                            HistoryDealGetDouble(t, DEAL_COMMISSION);
               totalRealizedProfitUSD += pnl;
            }
         }
      }
   }
   lastHistoryCheck = to;
}

//+------------------------------------------------------------------+
//| HER SEVIYEDE EKSIKSIZ 1 BUY + 1 SELL ACAN CEKIRDEK FONKSIYON     |
//+------------------------------------------------------------------+
bool OpenPairedLevel(double ask, double bid, double levelPrice)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   double tpDist = currentEffectiveStepPrice;
   double safetySLDist = InpUseSafetySL ? (currentEffectiveStepPrice * InpSafetySLMultiplier) : 0;
   
   // Buy Parametreleri (TP: 1 Kademe Yukari)
   double buyTP = ask + tpDist;
   double buySL = (safetySLDist > 0) ? (ask - safetySLDist) : 0;
   
   // Sell Parametreleri (TP: 1 Kademe Asagi)
   double sellTP = bid - tpDist;
   double sellSL = (safetySLDist > 0) ? (bid + safetySLDist) : 0;
   
   double lot = NormalizeLot(InpBaseLot);
   
   bool buyOk  = trade.Buy(lot, _Symbol, ask, buySL, buyTP, StringFormat("PAIR_B_%.5f", levelPrice));
   ulong bTicket = buyOk ? trade.ResultOrder() : 0;
   
   bool sellOk = trade.Sell(lot, _Symbol, bid, sellSL, sellTP, StringFormat("PAIR_S_%.5f", levelPrice));
   ulong sTicket = sellOk ? trade.ResultOrder() : 0;
   
   if(bTicket > 0 && sTicket > 0)
   {
      int sz = ArraySize(pairsTable);
      ArrayResize(pairsTable, sz + 1);
      pairsTable[sz].buyTicket      = bTicket;
      pairsTable[sz].sellTicket     = sTicket;
      pairsTable[sz].levelPrice     = levelPrice;
      pairsTable[sz].buyClosedTP    = false;
      pairsTable[sz].sellClosedTP   = false;
      pairsTable[sz].breakevenArmed = false;
      pairsTable[sz].isCompleted    = false;
      pairsTable[sz].openTime       = TimeCurrent();
      
      totalPairsCreated++;
      PrintFormat(">> [YENI KADEME ACILDI]: Seviye: %.5f | Buy: #%I64u | Sell: #%I64u", levelPrice, bTicket, sTicket);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BIRI TP OLUNCA DIGERININ STOPUNU SIFIRA CEKME MOTORU             |
//+------------------------------------------------------------------+
void ProcessPairedBreakevenLogic(double ask, double bid)
{
   int count = ArraySize(pairsTable);
   if(count == 0) return;
   
   double buffer = PipsToPrice(InpBreakevenBufferPips);
   
   for(int i = 0; i < count; i++)
   {
      if(pairsTable[i].isCompleted) continue;
      
      bool buyIsOpen  = posInfo.SelectByTicket(pairsTable[i].buyTicket);
      bool sellIsOpen = posInfo.SelectByTicket(pairsTable[i].sellTicket);
      
      // Iki bacak da kapandiysa bu cift tamamlanmistir
      if(!buyIsOpen && !sellIsOpen)
      {
         pairsTable[i].isCompleted = true;
         continue;
      }
      
      // 1. DURUM: BUY TP OLDU VE KAPANDI (FIYAT YUKARI GITTI)
      if(!buyIsOpen && !pairsTable[i].buyClosedTP && sellIsOpen)
      {
         pairsTable[i].buyClosedTP = true;
         pairsTable[i].breakevenArmed = true;
         totalTPHits++;
         PrintFormat(">> [KARA GECEN TP OLDU]: #%I64u Buy TP aldi! Eslesmis #%I64u Sell artik SIFIR NOKTASINA (%.5f) kilitlendi.",
                     pairsTable[i].buyTicket, pairsTable[i].sellTicket, pairsTable[i].levelPrice);
      }
      
      // 2. DURUM: SELL TP OLDU VE KAPANDI (FIYAT ASAGI GITTI)
      if(!sellIsOpen && !pairsTable[i].sellClosedTP && buyIsOpen)
      {
         pairsTable[i].sellClosedTP = true;
         pairsTable[i].breakevenArmed = true;
         totalTPHits++;
         PrintFormat(">> [KARA GECEN TP OLDU]: #%I64u Sell TP aldi! Eslesmis #%I64u Buy artik SIFIR NOKTASINA (%.5f) kilitlendi.",
                     pairsTable[i].sellTicket, pairsTable[i].buyTicket, pairsTable[i].levelPrice);
      }
      
      // 3. SIFIR NOKTASI (BREAKEVEN) CIKIS KONTROLU
      if(pairsTable[i].breakevenArmed)
      {
         // A) Buy TP olmustu, Sell acik bekliyor:
         // Fiyat baslangic seviyesine geri dustugunde Sell sifir zararla kapansin!
         if(pairsTable[i].buyClosedTP && sellIsOpen)
         {
            if(posInfo.SelectByTicket(pairsTable[i].sellTicket))
            {
               double entryP = pairsTable[i].levelPrice;
               if(ask <= entryP + buffer)
               {
                  trade.SetExpertMagicNumber(InpMagicNumber);
                  if(trade.PositionClose(pairsTable[i].sellTicket))
                  {
                     totalBreakevenCloses++;
                     pairsTable[i].isCompleted = true;
                     PrintFormat(">>>>> [SIFIR NOKTASINDA KAPANDI]: #%I64u Sell baslangic fiyati olan %.5f seviyesinde SIFIRLA kapatildi! (Buy kari cepte kaldi)",
                                 pairsTable[i].sellTicket, ask);
                  }
               }
            }
         }
         
         // B) Sell TP olmustu, Buy acik bekliyor:
         // Fiyat baslangic seviyesine geri ciktiginda Buy sifir zararla kapansin!
         if(pairsTable[i].sellClosedTP && buyIsOpen)
         {
            if(posInfo.SelectByTicket(pairsTable[i].buyTicket))
            {
               double entryP = pairsTable[i].levelPrice;
               if(bid >= entryP - buffer)
               {
                  trade.SetExpertMagicNumber(InpMagicNumber);
                  if(trade.PositionClose(pairsTable[i].buyTicket))
                  {
                     totalBreakevenCloses++;
                     pairsTable[i].isCompleted = true;
                     PrintFormat(">>>>> [SIFIR NOKTASINDA KAPANDI]: #%I64u Buy baslangic fiyati olan %.5f seviyesinde SIFIRLA kapatildi! (Sell kari cepte kaldi)",
                                 pairsTable[i].buyTicket, bid);
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SONRAKI KADEMEDE YINE 1 BUY + 1 SELL ACAN GRID MOTORU            |
//+------------------------------------------------------------------+
void ManagePerpetualPairedGrid(double ask, double bid)
{
   int activePairsCount = 0;
   int totalActivePairs = ArraySize(pairsTable);
   
   for(int i = 0; i < totalActivePairs; i++)
   {
      if(!pairsTable[i].isCompleted)
         activePairsCount++;
   }
   
   // 1. ILK BASLANGIC: HIC ISLEM YOKSA MERKEZDE 1 BUY + 1 SELL AC
   if(activePairsCount == 0)
   {
      // Varlık döngü başlangıcını kaydet
      cycleStartEquity = accountInfo.Equity();
      targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
      
      double mid = (ask + bid) / 2.0;
      OpenPairedLevel(ask, bid, mid);
      return;
   }
   
   if(activePairsCount >= InpMaxOpenPairs) return;
   
   // 2. EN YAKIN KADEME MESAFESINI BUL
   // Fiyat en yakin aktif kademeden 1 grid adimi (5 pip) uzaklasmissa yeni kademe ac!
   double currentMid = (ask + bid) / 2.0;
   double minDistance = 999999.0;
   
   for(int i = 0; i < totalActivePairs; i++)
   {
      if(!pairsTable[i].isCompleted)
      {
         double dist = MathAbs(currentMid - pairsTable[i].levelPrice);
         if(dist < minDistance)
            minDistance = dist;
      }
   }
   
   if(minDistance >= currentEffectiveStepPrice * 0.95)
   {
      OpenPairedLevel(ask, bid, currentMid);
      PrintFormat(">> [SONRAKI GRIDDE YINE 1 BUY + 1 SELL ACILDI]: Yeni Seviye: %.5f | Aktif Cift Sayisi: %d",
                  currentMid, activePairsCount + 1);
   }
}

//+------------------------------------------------------------------+
//| SEPET KARINI VARLIK (EQUITY) UZERINDEN HESAPLAYIP SIFIRLAMA      |
//+------------------------------------------------------------------+
void CheckBasketTPAndProtection()
{
   double totalBasketPnL = 0.0;
   int openCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
      {
         openCount++;
         totalBasketPnL += (posInfo.Profit() + posInfo.Swap() + posInfo.Commission());
      }
   }
   
   if(openCount == 0) return;
   
   double currentEquity = accountInfo.Equity();
   bool targetReached = false;
   
   // 1. MOD: NET VARLIK (EQUITY) HEDEFI (Orn: 100 USD -> 102 USD)
   if(InpUseBasketTP)
   {
      if(InpBasketTPMode == BASKET_TP_EQUITY_GROWTH)
      {
         if(cycleStartEquity <= 0)
         {
            cycleStartEquity = currentEquity;
            targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
         }
         
         // Varlık hedefe ulaştı mı? (Örn: 102 USD)
         if(currentEquity >= targetCycleEquity)
         {
            targetReached = true;
         }
      }
      // 2. MOD: YUZEN ANLIK KAR HEDEFI (Floating PnL >= InpTargetProfitUSD)
      else if(InpBasketTPMode == BASKET_TP_FLOATING_PNL)
      {
         if(totalBasketPnL >= InpTargetProfitUSD)
         {
            targetReached = true;
         }
      }
   }
   
   // HEDEF GERCEKLESTIGINDE: TUM POZISYONLARI KAPAT VE SIFIRDAN BASLA!
   if(targetReached)
   {
      CloseAllPositions();
      ArrayResize(pairsTable, 0);
      totalClosedCycles++;
      
      // Yeni döngünün başlangıç varlığını hemen güncelle
      cycleStartEquity = accountInfo.Equity();
      targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
      
      PrintFormat(">>>>> [HEDEF VARLIGA ULASTI!]: Net Varlık %.2f USD oldu! Tum pozisyonlar kapatildi, yeni hedef: %.2f USD",
                  cycleStartEquity, targetCycleEquity);
      return;
   }
   
   // Maksimum Drawdown Emniyeti
   if(InpUseEquityProtection)
   {
      double equity  = accountInfo.Equity();
      double balance = accountInfo.Balance();
      if(balance > 0)
      {
         double dd = ((balance - equity) / balance) * 100.0;
         if(dd >= InpMaxDrawdownPercent)
         {
            CloseAllPositions();
            ArrayResize(pairsTable, 0);
            cycleStartEquity = accountInfo.Equity();
            targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
            PrintFormat("!!!!! [RISK KORUMASI]: Drawdown (%%%.2f) asildi! Sepet guvenlik icin kapatildi.", dd);
            return;
         }
      }
   }
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
      {
         trade.PositionClose(posInfo.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| EKRAN GOSTERGE BILGI PANELI (HUD DASHBOARD)                      |
//+------------------------------------------------------------------+
void UpdateHUD()
{
   int buyPositions = 0, sellPositions = 0;
   double floatingPnL = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
      {
         if(posInfo.PositionType() == POSITION_TYPE_BUY) buyPositions++;
         if(posInfo.PositionType() == POSITION_TYPE_SELL) sellPositions++;
         floatingPnL += (posInfo.Profit() + posInfo.Swap() + posInfo.Commission());
      }
   }
   
   int activePairs = 0;
   for(int i = 0; i < ArraySize(pairsTable); i++)
   {
      if(!pairsTable[i].isCompleted) activePairs++;
   }
   
   double currentEquity = accountInfo.Equity();
   double remainingToTarget = targetCycleEquity - currentEquity;
   if(remainingToTarget < 0) remainingToTarget = 0.0;
   
   string tpModeStr = (InpBasketTPMode == BASKET_TP_EQUITY_GROWTH) ? "NET VARLIK (EQUITY) ARTISI" : "ANLIK YUZEN KAR (FLOATING)";
   
   string text = StringFormat(
      "==========================================================\n"
      "      HEDGE GRID PRO EA v9.0 - NET VARLIK HEDEFI MODU     \n"
      "==========================================================\n"
      "Sepet Kar Hesap Modu    : %s\n"
      "Dongu Baslangic Varligi : %.2f USD\n"
      "Mevcut Net Varlik       : %.2f USD\n"
      "Hedef Net Varlik        : %.2f USD (+%.2f USD)\n"
      "Hedefe Kalan            : %.2f USD\n"
      "----------------------------------------------------------\n"
      "Aktif Acik Buy / Sell   : %d Buy / %d Sell (Aktif Cift: %d)\n"
      "TP Alip Kapanan Islemler: %d Kez Kazandi\n"
      "Sifir Noktasinda Cikanlar: %d Kez Zararsiz Temizlendi\n"
      "Sepet Anlik Floating PnL : %.2f USD\n"
      "Tamamlanan Basarili Tur : %d Tur Sifirlandi ve Yenilendi\n"
      "==========================================================",
      tpModeStr,
      cycleStartEquity,
      currentEquity,
      targetCycleEquity, InpTargetProfitUSD,
      remainingToTarget,
      buyPositions, sellPositions, activePairs,
      totalTPHits,
      totalBreakevenCloses,
      floatingPnL,
      totalClosedCycles
   );
   Comment(text);
}

//+------------------------------------------------------------------+
//| EVENT HANDLERS                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   InitPipFactor();
   trade.SetDeviationInPoints(InpSlippagePoints);
   
   if(InpSpacingMode == SPACING_AUTO_ATR)
   {
      atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("Hata: ATR Gostergesi baslatilamadi!");
         return INIT_FAILED;
      }
   }
   
   UpdateGridSpacing();
   
   // Başlangıç Net Varlığını Kaydet
   cycleStartEquity = accountInfo.Equity();
   targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
   
   PrintFormat(">> [HEDGE GRID PRO EA v9.0] Basariyla Baslatildi. Baslangic Varligi: %.2f USD | Hedef Varlik: %.2f USD",
               cycleStartEquity, targetCycleEquity);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Comment("");
}

void OnTick()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;
   
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(currentBarTime != lastBarProcessed)
   {
      UpdateGridSpacing();
      lastBarProcessed = currentBarTime;
   }
   
   SyncRealizedProfits();
   
   // 1. ADIM: Kara geceni TP yap, kalan bacak sifir noktasina gelince zararsiz kapa
   ProcessPairedBreakevenLogic(ask, bid);
   
   // 2. ADIM: Sonraki grid kademesine ulasildiysa yine 1 Buy + 1 Sell ac
   ManagePerpetualPairedGrid(ask, bid);
   
   // 3. ADIM: Net Varlık (Equity) hedefe (ör. 102 USD) ulaştıysa hepsini kapat ve sıfırdan başla!
   CheckBasketTPAndProtection();
   
   // 4. ADIM: Bilgi panelini guncelle
   UpdateHUD();
}
//+------------------------------------------------------------------+
