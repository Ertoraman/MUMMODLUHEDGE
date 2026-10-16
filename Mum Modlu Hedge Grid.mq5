//+------------------------------------------------------------------+
//|                                         Mum Modlu Hedge Grid.mq5 |
//|         MUM KAPANISI YONUNDE ISLEM + MUM SAYACI TP/SL  (v10.10)  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Algorithmic Hedge Strategy"
#property link      "https://arena.ai"
#property version   "10.10"
#property description "GIRIS: Her mum kapanisinda TEK islem. Mum YUKARI kapandiysa SADECE BUY, ASAGI kapandiysa SADECE SELL (M1 ise her dakika)."
#property description "CIKIS: TP = giristen sonra 3 adet LEHINE mum kapanisi, SL = giristen sonra 10 adet ALEYHINE mum kapanisi."
#property description "Mumlarin ARDISIK olmasi gerekmez; araya ters yonlu mumlar girebilir, sayac birikerek ilerler."
#property description "Kapanis emirleri ters yonludur (BUY, SELL emriyle kapanir) ve 'CIKIS ...' yorumu tasir; yeni islem degildir."
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| KAPANIS EMRINE YORUM YAZAN CTrade                                |
//| MT5'te BUY pozisyonu SELL yonlu bir emirle, SELL pozisyonu BUY   |
//| yonlu bir emirle kapatilir. Standart CTrade::PositionClose bu    |
//| emre yorum yazmadigi icin gecmiste ve grafikte her kapanis "yeni |
//| ters islem" gibi gorunur. Bu metot CTrade::PositionClose ile     |
//| BIREBIR ayni emri gonderir (ayni FillingCheck, fiyat, sapma),    |
//| tek fark yorum alanini doldurmasidir: "CIKIS TP BUY #123".       |
//+------------------------------------------------------------------+
class CLabeledTrade : public CTrade
{
public:
   bool PositionCloseLabeled(const ulong ticket, const string comment)
   {
      if(IsStopped(__FUNCTION__))
         return(false);
      if(!PositionSelectByTicket(ticket))
         return(false);
      string symbol = PositionGetString(POSITION_SYMBOL);
      ClearStructures();
      if(!FillingCheck(symbol))
         return(false);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         m_request.type  = ORDER_TYPE_SELL;          // BUY pozisyonu kapatma emri
         m_request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
      }
      else
      {
         m_request.type  = ORDER_TYPE_BUY;           // SELL pozisyonu kapatma emri
         m_request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      }
      m_request.action    = TRADE_ACTION_DEAL;
      m_request.position  = ticket;
      m_request.symbol    = symbol;
      m_request.volume    = PositionGetDouble(POSITION_VOLUME);
      m_request.magic     = m_magic;
      m_request.deviation = m_deviation;
      m_request.comment   = comment;
      return(OrderSend(m_request, m_result));
   }
};

//+------------------------------------------------------------------+
//| ENUMLAR VE SECENEKLER                                            |
//+------------------------------------------------------------------+
enum ENUM_BASKET_TP_MODE
{
   BASKET_TP_EQUITY_GROWTH,      // 1. Net Varlik (Equity) Hedefi (Orn: 100 USD -> 102 USD)
   BASKET_TP_FLOATING_PNL        // 2. Acik Pozisyonlar Yuzen Kar (USD)
};

//+------------------------------------------------------------------+
//| MUM SAYACI ILE TAKIP EDILEN ISLEM KAYDI                          |
//+------------------------------------------------------------------+
struct SCandleTrade
{
   ulong    ticket;              // Pozisyon bileti
   bool     isBuy;               // true = BUY, false = SELL
   double   entryPrice;          // Giris fiyati
   datetime entryTime;           // Giris zamani
   datetime lastCountedBarTime;  // Sayaca islenen son KAPALI mumun acilis zamani
   int      tpCount;             // Giris sonrasi LEHINE kapanan mum sayisi
   int      slCount;             // Giris sonrasi ALEYHINE kapanan mum sayisi
   bool     isClosed;            // Pozisyon kapandi mi?
};

//+------------------------------------------------------------------+
//| INPUT PARAMETRELERI                                              |
//+------------------------------------------------------------------+
input group "=== 1. ISLEM VE LOT AYARLARI ==="
input ulong    InpMagicNumber         = 654321;   // Bot Magic Numarasi
input double   InpBaseLot             = 0.01;     // Islem Lot Boyutu
input int      InpSlippagePoints      = 15;       // Maksimum Kayma Toleransi (Puan)
input int      InpMaxOpenPositions    = 25;       // Ayni Anda Acik Tutulacak Maksimum Islem Sayisi

input group "=== 2. MUM SAYACI TP / SL AYARLARI ==="
input int      InpTPCandleCount       = 3;        // TP: Giris sonrasi kac adet LEHINE mum kapanisi (0 = TP kapali)
input int      InpSLCandleCount       = 10;       // SL: Giris sonrasi kac adet ALEYHINE mum kapanisi (0 = SL kapali)
input bool     InpUseSafetyPriceStop  = false;    // Ek Emniyet Fiyat Stopu (baglanti kopmasina karsi sigorta)
input double   InpSafetyStopPips      = 300.0;    // [Emniyet Stop] Mesafe (Pips)

input group "=== 3. SEPET VE NET VARLIK (EQUITY) KAR YONETIMI ==="
input bool                 InpUseBasketTP        = true;                    // Sepet Toplam Kar Kapanisi Aktif
input ENUM_BASKET_TP_MODE  InpBasketTPMode       = BASKET_TP_EQUITY_GROWTH; // Kar Hesaplama Modu
input double               InpTargetProfitUSD    = 2.0;                     // Hedef Kar Miktari (USD)
input bool                 InpUseEquityProtection= true;                    // Maksimum Zarar Kes Korumasi
input double               InpMaxDrawdownPercent = 20.0;                    // Maksimum Izin Verilen Hesap Drawdown (%)

input group "=== 4. GORSEL ==="
input bool     InpShowHUD             = true;     // Ekranda Bilgi Paneli Goster
input int      InpHudMaxRows          = 12;       // Panelde Listelenecek Maksimum Acik Islem Satiri

//+------------------------------------------------------------------+
//| GLOBAL DEGISKENLER                                               |
//+------------------------------------------------------------------+
CLabeledTrade  trade;
CPositionInfo  posInfo;
CAccountInfo   accountInfo;

double         pipValue = 0.0001;
datetime       lastBarProcessed = 0;
datetime       lastCandleProcessed = 0;   // Son islenen KAPALI mumun zamani
datetime       lastEntrySignalBar  = 0;   // Giris yapilan son sinyal mumu (mum basina TEK giris korumasi)
int            lastCandleDir       = 0;   // Son kapanan mumun yonu: 1 yukari, -1 asagi, 0 doji
string         lastEntryInfo       = "-"; // Son mum kapanisinda ne yapildi (panel icin)

// Bu sembolde bu EA'ya ait OLMAYAN pozisyonlar (baska EA / manuel / eski v9)
int            foreignSameMagic    = 0;   // Ayni magic ama yabanci yorum (or. v9 PAIR_B_/PAIR_S_)
int            foreignOtherMagic   = 0;   // Farkli magic veya manuel
string         foreignSample       = "";
int            lastForeignReported = -1;

// Net Varlik (Equity) Takip Degiskenleri
double         cycleStartEquity  = 0.0;
double         targetCycleEquity = 0.0;

// Mum sayaci ile takip edilen islemler
SCandleTrade   tradesTable[];

// Istatistikler
double         totalRealizedProfitUSD = 0.0;
int            totalTradesOpened = 0;
int            totalTPCloses     = 0;
int            totalSLCloses     = 0;
int            totalBasketCloses = 0;
datetime       lastHistoryCheck  = 0;

//+------------------------------------------------------------------+
//| YARDIMCI PIP VE LOT FONKSIYONLARI                                |
//+------------------------------------------------------------------+
void InitPipFactor()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      pipValue = 10.0 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   else
      pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pipValue <= 0) pipValue = 0.0001;
}

double PipsToPrice(double pips) { return pips * pipValue; }

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
//| POZISYON SAHIPLIGI                                               |
//| posInfo ile SECILI pozisyon bu EA'ya mi ait?                     |
//| Ayni magic numarasini kullanan baska bir EA'nin (or. eski v9'un  |
//| PAIR_B_/PAIR_S_ ciftleri) pozisyonlari sahiplenilmez/kapatilmaz. |
//| Yorumu BOS olan pozisyon bizim sayilir: bazi brokerlar yorumu    |
//| siler; aksi halde EA yeniden baslayinca kendi islemlerini sahip- |
//| siz birakirdi.                                                   |
//+------------------------------------------------------------------+
bool IsOwnSelectedPosition()
{
   if(posInfo.Symbol() != _Symbol)               return false;
   if(posInfo.Magic()  != (long)InpMagicNumber)  return false;
   string c = posInfo.Comment();
   if(c == "")                    return true;
   if(StringFind(c, "GIRIS ") == 0) return true; // v10.10+ giris yorumu
   if(StringFind(c, "CNDL_")  == 0) return true; // v10.00 giris yorumu
   return false;
}

//+------------------------------------------------------------------+
//| BU SEMBOLDE BU EA'YA AIT OLMAYAN POZISYONLARI SAY                |
//| Grafikte gorunen her ok bu EA'dan gelmeyebilir: ayni sembolde    |
//| calisan baska bir EA veya manuel islemler de cizilir.            |
//+------------------------------------------------------------------+
void ScanForeignPositions()
{
   foreignSameMagic  = 0;
   foreignOtherMagic = 0;
   foreignSample     = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))     continue;
      if(posInfo.Symbol() != _Symbol)   continue;
      if(IsOwnSelectedPosition())       continue;
      if(posInfo.Magic() == (long)InpMagicNumber) foreignSameMagic++;
      else                                        foreignOtherMagic++;
      if(foreignSample == "")
         foreignSample = StringFormat("%s magic=%I64d yorum='%s'",
                                      (posInfo.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                                      posInfo.Magic(), posInfo.Comment());
   }

   int total = foreignSameMagic + foreignOtherMagic;
   if(total != lastForeignReported)
   {
      if(total > 0)
         PrintFormat("!! [UYARI]: %s uzerinde bu EA'ya AIT OLMAYAN %d pozisyon var (ayni magic: %d, farkli magic/manuel: %d). Ornek: %s. "
                     "Bunlara dokunulmuyor; grafikteki BUY+SELL oklarinin bir kismi bunlardan geliyor olabilir. "
                     "Ayni sembolde baska EA (or. eski v9) calisiyorsa kaldirin veya farkli magic verin.",
                     _Symbol, total, foreignSameMagic, foreignOtherMagic, foreignSample);
      else if(lastForeignReported > 0)
         PrintFormat(">> [BILGI]: %s uzerinde artik bu EA disinda pozisyon yok.", _Symbol);
      lastForeignReported = total;
   }
}

//+------------------------------------------------------------------+
//| BIR POZISYONUN GECMIS MUM SAYACLARINI YENIDEN KUR (RESTART/GAP)  |
//| GIRIS MUMU DAHIL, o andaki son KAPALI muma kadar tum mumlar      |
//| sayilir. Boylece EA yeniden baslasa bile sayac dogru devam eder. |
//+------------------------------------------------------------------+
void RebuildCandleCounts(ulong ticket, datetime openTime, bool isBuy,
                         int &tpCount, int &slCount, datetime &lastCountedBar)
{
   tpCount = 0;
   slCount = 0;
   lastCountedBar = 0;

   int entryShift = iBarShift(_Symbol, _Period, openTime);
   if(entryShift < 0) entryShift = 0;

   // Giris mumunun acilis zamani = "son sayilan mum" baslangic noktasi
   datetime entryBarTime = iTime(_Symbol, _Period, entryShift);
   if(entryBarTime > 0) lastCountedBar = entryBarTime;

   // Sayilan mumlar: GIRIS MUMU DAHIL, o andaki son KAPALI muma kadar.
   // (Islem, giris mumunun basindan itibaren acik oldugu icin giris mumu da sayilir.
   //  Canli akista da boyledir: islem yeni mumun acilisinda acilir, o mum sayilir.)
   int barsToScan = entryShift;
   if(barsToScan < 1) return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(_Symbol, _Period, 1, barsToScan, r);
   if(copied < 1) return;

   for(int i = 0; i < copied; i++)
   {
      int dir = 0;
      if(r[i].close > r[i].open)      dir =  1;
      else if(r[i].close < r[i].open) dir = -1;
      if(dir == 0) continue;                       // Doji sayilmaz

      bool inFavor = (isBuy && dir ==  1) || (!isBuy && dir == -1);
      if(inFavor) tpCount++;
      else        slCount++;
   }
}

//+------------------------------------------------------------------+
//| TABLO YARDIMCILARI                                               |
//+------------------------------------------------------------------+
int FindTradeIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(tradesTable); i++)
      if(tradesTable[i].ticket == ticket) return i;
   return -1;
}

int AddTrackedTrade(ulong ticket, bool isBuy, double entryPrice, datetime entryTime,
                    datetime lastCountedBar, int tpCount, int slCount)
{
   int sz = ArraySize(tradesTable);
   ArrayResize(tradesTable, sz + 1);
   tradesTable[sz].ticket             = ticket;
   tradesTable[sz].isBuy              = isBuy;
   tradesTable[sz].entryPrice         = entryPrice;
   tradesTable[sz].entryTime          = entryTime;
   tradesTable[sz].lastCountedBarTime = lastCountedBar;
   tradesTable[sz].tpCount            = tpCount;
   tradesTable[sz].slCount            = slCount;
   tradesTable[sz].isClosed           = false;
   return sz;
}

void CompactTradesTable()
{
   if(ArraySize(tradesTable) < 300) return;
   SCandleTrade alive[];
   for(int i = 0; i < ArraySize(tradesTable); i++)
   {
      if(tradesTable[i].isClosed) continue;
      int sz = ArraySize(alive);
      ArrayResize(alive, sz + 1);
      alive[sz] = tradesTable[i];
   }
   ArrayResize(tradesTable, ArraySize(alive));
   for(int i = 0; i < ArraySize(alive); i++) tradesTable[i] = alive[i];
}

int CountActiveTrades()
{
   int n = 0;
   for(int i = 0; i < ArraySize(tradesTable); i++)
      if(!tradesTable[i].isClosed) n++;
   return n;
}

//+------------------------------------------------------------------+
//| SAYACLARA GORE TP/SL KONTROLU VE KAPATMA                         |
//| Hem her mum kapanisinda hem de tabloya yeni alinan (restart)     |
//| islemlerde kullanilir; boylece esik gecmiste asildiysa bile      |
//| islem bir mum beklemeden hemen kapatilir.                        |
//+------------------------------------------------------------------+
bool TryCloseByCandleCounts(int idx, datetime refBarTime)
{
   if(idx < 0 || idx >= ArraySize(tradesTable)) return false;
   if(tradesTable[idx].isClosed) return false;

   bool tpHit = (InpTPCandleCount > 0 && tradesTable[idx].tpCount >= InpTPCandleCount);
   bool slHit = (InpSLCandleCount > 0 && tradesTable[idx].slCount >= InpSLCandleCount);
   if(!tpHit && !slHit) return false;

   ulong  ticket = tradesTable[idx].ticket;
   string reason = tpHit ? "TP - LEHINE MUM SAYISI" : "SL - ALEYHINE MUM SAYISI";

   if(!CloseTicket(ticket, tradesTable[idx].isBuy, (tpHit ? "TP" : "SL")))
   {
      PrintFormat("!! [%s KAPATMA BASARISIZ]: #%I64u | Retcode: %d", reason, ticket, trade.ResultRetcode());
      return false;
   }

   tradesTable[idx].isClosed = true;
   if(tpHit) totalTPCloses++;
   else      totalSLCloses++;

   PrintFormat(">>>>> [%s]: #%I64u %s kapatildi | Giris: %.5f | Lehine mum: %d/%d | Aleyhine mum: %d/%d | Referans mum: %s",
               reason, ticket, (tradesTable[idx].isBuy ? "BUY" : "SELL"),
               tradesTable[idx].entryPrice,
               tradesTable[idx].tpCount, InpTPCandleCount,
               tradesTable[idx].slCount, InpSLCandleCount,
               TimeToString(refBarTime, TIME_DATE | TIME_MINUTES));
   return true;
}

//+------------------------------------------------------------------+
//| ACIK POZISYONLAR ILE TABLOYU SENKRONIZE ET                       |
//| (EA yeniden baslayinca veya pozisyon disaridan kapaninca)        |
//+------------------------------------------------------------------+
void SyncTradesTable()
{
   // 1) Tabloda olup artik acik olmayanlari "kapandi" isaretle
   for(int i = 0; i < ArraySize(tradesTable); i++)
   {
      if(tradesTable[i].isClosed) continue;
      if(!posInfo.SelectByTicket(tradesTable[i].ticket))
         tradesTable[i].isClosed = true;
   }

   // 2) Acik olup tabloda olmayanlari ekle ve sayaclari gecmisten kur
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(!IsOwnSelectedPosition())  continue;      // baska EA / manuel / eski v9 pozisyonlari sahiplenilmez

      ulong ticket = posInfo.Ticket();
      if(FindTradeIndex(ticket) >= 0) continue;

      bool     isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
      datetime oTime = posInfo.Time();          // POSITION_TIME (acilis zamani)
      int      tp = 0, sl = 0;
      datetime lastBar = 0;
      RebuildCandleCounts(ticket, oTime, isBuy, tp, sl, lastBar);

      int idx = AddTrackedTrade(ticket, isBuy, posInfo.PriceOpen(), oTime, lastBar, tp, sl);
      PrintFormat(">> [TABLOYA ALINDI]: #%I64u %s | Giris: %.5f | Gecmisten sayac -> Lehine:%d / Aleyhine:%d",
                  ticket, (isBuy ? "BUY" : "SELL"), posInfo.PriceOpen(), tp, sl);

      // Esik gecmiste zaten asildiysa bir mum beklemeden hemen kapat
      TryCloseByCandleCounts(idx, lastBar);
   }

   CompactTradesTable();
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
               totalRealizedProfitUSD += HistoryDealGetDouble(t, DEAL_PROFIT) +
                                         HistoryDealGetDouble(t, DEAL_SWAP) +
                                         HistoryDealGetDouble(t, DEAL_COMMISSION);
            }
         }
      }
   }
   lastHistoryCheck = to;
}

//+------------------------------------------------------------------+
//| YENI POZISYON AC (MUM YONUNE GORE)                               |
//+------------------------------------------------------------------+
bool OpenCandleTrade(bool isBuy, datetime signalBarTime)
{
   // MUM BASINA TEK GIRIS: ayni sinyal mumu icin ikinci kez (veya ters yonde) islem ACILMAZ.
   // Isaret, emir gonderilmeden ONCE konur; emir basarisiz olsa bile ayni mumda tekrar denenmez.
   if(signalBarTime <= lastEntrySignalBar)
   {
      PrintFormat("!! [KORUMA]: %s mumu icin giris zaten yapildi, ikinci islem acilmadi.",
                  TimeToString(signalBarTime, TIME_DATE | TIME_MINUTES));
      return false;
   }
   lastEntrySignalBar = signalBarTime;

   if(CountActiveTrades() >= InpMaxOpenPositions)
   {
      lastEntryInfo = StringFormat("%s -> limit dolu (%d), islem acilmadi", (isBuy ? "YUKARI" : "ASAGI"), InpMaxOpenPositions);
      Print(">> [UYARI]: Maksimum acik islem limitine ulasildi, yeni islem acilmadi.");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0) return false;

   double sl = 0.0;
   if(InpUseSafetyPriceStop && InpSafetyStopPips > 0)
   {
      double dist = PipsToPrice(InpSafetyStopPips);
      sl = isBuy ? (price - dist) : (price + dist);
   }

   // Giris yorumu: "GIRIS BUY 2026.10.16 10:05" (sahiplik kontrolu bu oneki kullanir)
   string cmt = StringFormat("GIRIS %s %s", (isBuy ? "BUY" : "SELL"),
                             TimeToString(signalBarTime, TIME_DATE | TIME_MINUTES));

   double lot = NormalizeLot(InpBaseLot);

   bool ok;
   if(isBuy) ok = trade.Buy (lot, _Symbol, price, sl, 0.0, cmt);
   else      ok = trade.Sell(lot, _Symbol, price, sl, 0.0, cmt);

   if(!ok)
   {
      lastEntryInfo = StringFormat("%s -> %s ACILAMADI (retcode %d)", (isBuy ? "YUKARI" : "ASAGI"),
                                   (isBuy ? "BUY" : "SELL"), trade.ResultRetcode());
      PrintFormat("!! [ISLEM ACILAMADI]: %s | Retcode: %d", (isBuy ? "BUY" : "SELL"), trade.ResultRetcode());
      return false;
   }
   lastEntryInfo = StringFormat("%s -> SADECE %s acildi", (isBuy ? "YUKARI" : "ASAGI"), (isBuy ? "BUY" : "SELL"));

   // Pozisyon biletini dogru sekilde yakala (hedging/exchange execution farki icin)
   ulong orderTicket  = trade.ResultOrder();
   ulong dealTicket   = trade.ResultDeal();
   ulong positionId   = 0;
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
      positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(positionId == 0) positionId = orderTicket;
   if(positionId == 0)
   {
      Print("!! [UYARI]: Islem acildi ama pozisyon bileti okunamadi, tablo bir sonraki tick'te senkronlanacak.");
      return false;
   }

   double entryPrice = price;
   datetime entryTime = TimeCurrent();
   if(posInfo.SelectByTicket(positionId))
   {
      entryPrice = posInfo.PriceOpen();
      entryTime  = posInfo.Time();              // POSITION_TIME (acilis zamani)
   }

   // ONEMLI: Sinyali ureten (az once kapanan) mum SAYILMAZ.
   // Sayac, giristen sonra kapanan ilk mumdan itibaren isler.
   AddTrackedTrade(positionId, isBuy, entryPrice, entryTime, signalBarTime, 0, 0);
   totalTradesOpened++;
   lastEntryInfo = StringFormat("%s -> SADECE %s acildi #%I64u", (isBuy ? "YUKARI" : "ASAGI"),
                                (isBuy ? "BUY" : "SELL"), positionId);

   PrintFormat(">> [YENI ISLEM]: #%I64u %s (bu mumda acilan TEK islem) | Giris: %.5f | Lot: %.2f | Mum: %s %s | TP hedefi: %d lehine mum, SL hedefi: %d aleyhine mum",
               positionId, (isBuy ? "BUY" : "SELL"), entryPrice, lot,
               TimeToString(signalBarTime, TIME_DATE | TIME_MINUTES), (isBuy ? "YUKARI" : "ASAGI"),
               InpTPCandleCount, InpSLCandleCount);
   return true;
}

//+------------------------------------------------------------------+
//| POZISYONU PIYASADAN KAPAT (YORUMLU)                              |
//| Kapanis emri pozisyonun TERSI yondedir (BUY -> SELL emri).       |
//| Gecmiste "yeni islem" sanilmasin diye yorum yazilir:             |
//|   "CIKIS TP BUY #123"  = 123 nolu BUY pozisyonu TP ile kapandi.  |
//+------------------------------------------------------------------+
bool CloseTicket(ulong ticket, bool isBuyPosition, string tag)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   string cmt = StringFormat("CIKIS %s %s #%I64u", tag, (isBuyPosition ? "BUY" : "SELL"), ticket);
   return trade.PositionCloseLabeled(ticket, cmt);
}

//+------------------------------------------------------------------+
//| KAPANAN TEK BIR MUMU ACIK ISLEMLERIN SAYACLARINA ISLE            |
//| Lehine mum  -> tpCount++   (BUY icin YUKARI, SELL icin ASAGI)    |
//| Aleyhine mum-> slCount++                                          |
//| Sayac ARDISIKLIK ARAMAZ; birikerek ilerler.                      |
//+------------------------------------------------------------------+
void ApplyClosedCandleToCounters(datetime closedBarTime, int dir)
{
   if(dir == 0) return;                        // Doji: hicbir sayaci ilerletmez, islem de acmaz

   for(int i = 0; i < ArraySize(tradesTable); i++)
   {
      if(tradesTable[i].isClosed) continue;

      ulong ticket = tradesTable[i].ticket;
      if(!posInfo.SelectByTicket(ticket))
      {
         tradesTable[i].isClosed = true;         // Harici kapatilmis (emniyet stop vb.)
         continue;
      }

      // Bu islem icin bu mum daha once sayildiysa atla (cift sayma olmasin)
      if(tradesTable[i].lastCountedBarTime >= closedBarTime) continue;

      bool inFavor = (tradesTable[i].isBuy && dir ==  1) ||
                     (!tradesTable[i].isBuy && dir == -1);
      if(inFavor) tradesTable[i].tpCount++;
      else        tradesTable[i].slCount++;

      tradesTable[i].lastCountedBarTime = closedBarTime;

      // Esige ulasildiysa kapat (TP: 3 lehine mum / SL: 10 aleyhine mum)
      TryCloseByCandleCounts(i, closedBarTime);
   }
}

//+------------------------------------------------------------------+
//| ANA MOTOR: SON ISLEMDEN BU YANA KAPANAN TUM MUMLARI ISLE         |
//| Normal akista tek mum kapanir; hafta sonu/bosluk gibi durumlarda |
//| aradaki TUM kapanmis mumlar sirayla sayilir (sayac kaybi olmaz). |
//| Yeni islem ise sadece EN SON kapanan mumun yonunde acilir.       |
//+------------------------------------------------------------------+
void ProcessClosedCandles(datetime prevBarTime)
{
   // prevBarTime = bir onceki tick'te ACIK olan (simdi kapanmis) mumun acilis zamani.
   // Normalde shift 1'dedir (tek mum). Baglanti kopmasi vb. durumda aradaki tum mumlar islenir.
   int prevShift = iBarShift(_Symbol, _Period, prevBarTime);
   if(prevShift < 1) prevShift = 1;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(_Symbol, _Period, 1, prevShift, r);
   if(copied < 1) return;

   if(copied > 1)
      PrintFormat(">> [BILGI]: %d adet kapanmis mum birikmis, hepsi sirayla sayiliyor.", copied);

   // Kronolojik sira: en eski kapanan mumdan (en yuksek shift) en yeniye dogru
   for(int i = copied - 1; i >= 0; i--)
   {
      datetime barTime = r[i].time;
      int dir = 0;
      if(r[i].close > r[i].open)      dir =  1;
      else if(r[i].close < r[i].open) dir = -1;

      ApplyClosedCandleToCounters(barTime, dir);

      // Yeni islem sadece EN SON kapanan mum icin (i == 0)
      if(i == 0)
      {
         lastCandleProcessed = barTime;
         lastCandleDir       = dir;
         if(dir == 0)
         {
            lastEntryInfo = "DOJI -> islem acilmadi";
            PrintFormat(">> [MUM KAPANDI]: %s -> DOJI (acilis=kapanis), yon sinyali yok, yeni islem acilmadi.",
                        TimeToString(barTime, TIME_DATE | TIME_MINUTES));
         }
         else
         {
            // Mum YUKARI kapandi -> BUY | Mum ASAGI kapandi -> SELL
            OpenCandleTrade((dir == 1), barTime);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SEPET KARINI VARLIK (EQUITY) UZERINDEN HESAPLAYIP SIFIRLAMA      |
//+------------------------------------------------------------------+
void CheckBasketTPAndProtection()
{
   double totalBasketPnL = 0.0;
   int    openCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && IsOwnSelectedPosition())
      {
         openCount++;
         totalBasketPnL += (posInfo.Profit() + posInfo.Swap() + posInfo.Commission());
      }
   }

   double currentEquity = accountInfo.Equity();

   if(cycleStartEquity <= 0)
   {
      cycleStartEquity  = currentEquity;
      targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
   }

   if(openCount == 0) return;

   bool targetReached = false;

   if(InpUseBasketTP)
   {
      if(InpBasketTPMode == BASKET_TP_EQUITY_GROWTH)
      {
         if(currentEquity >= targetCycleEquity) targetReached = true;
      }
      else if(InpBasketTPMode == BASKET_TP_FLOATING_PNL)
      {
         if(totalBasketPnL >= InpTargetProfitUSD) targetReached = true;
      }
   }

   if(targetReached)
   {
      CloseAllPositions("SEPET");
      ArrayResize(tradesTable, 0);
      totalBasketCloses++;

      cycleStartEquity  = accountInfo.Equity();
      targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;

      PrintFormat(">>>>> [HEDEF VARLIGA ULASTI!]: Net Varlik %.2f USD oldu! Tum pozisyonlar kapatildi, yeni hedef: %.2f USD",
                  cycleStartEquity, targetCycleEquity);
      return;
   }

   if(InpUseEquityProtection)
   {
      double balance = accountInfo.Balance();
      if(balance > 0)
      {
         double dd = ((balance - currentEquity) / balance) * 100.0;
         if(dd >= InpMaxDrawdownPercent)
         {
            CloseAllPositions("DD");
            ArrayResize(tradesTable, 0);
            cycleStartEquity  = accountInfo.Equity();
            targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;
            PrintFormat("!!!!! [RISK KORUMASI]: Drawdown (%%%.2f) asildi! Sepet guvenlik icin kapatildi.", dd);
            return;
         }
      }
   }
}

void CloseAllPositions(string tag)
{
   // Sadece bu EA'nin pozisyonlari kapatilir (ayni magic'li baska EA'larinkine dokunulmaz)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && IsOwnSelectedPosition())
         CloseTicket(posInfo.Ticket(), (posInfo.PositionType() == POSITION_TYPE_BUY), tag);
   }
}

//+------------------------------------------------------------------+
//| EKRAN GOSTERGE BILGI PANELI (HUD DASHBOARD)                      |
//+------------------------------------------------------------------+
void UpdateHUD()
{
   int    buyPositions = 0, sellPositions = 0;
   double floatingPnL = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && IsOwnSelectedPosition())
      {
         if(posInfo.PositionType() == POSITION_TYPE_BUY) buyPositions++;
         else                                           sellPositions++;
         floatingPnL += (posInfo.Profit() + posInfo.Swap() + posInfo.Commission());
      }
   }

   double currentEquity = accountInfo.Equity();
   double remainingToTarget = targetCycleEquity - currentEquity;
   if(remainingToTarget < 0) remainingToTarget = 0.0;

   string tpModeStr = (InpBasketTPMode == BASKET_TP_EQUITY_GROWTH) ? "NET VARLIK (EQUITY) ARTISI" : "ANLIK YUZEN KAR (FLOATING)";

   string dirStr = (lastCandleDir > 0) ? "YUKARI" : ((lastCandleDir < 0) ? "ASAGI" : "DOJI");
   string lastCandleStr = (lastCandleProcessed > 0)
                          ? StringFormat("%s %s | %s", TimeToString(lastCandleProcessed, TIME_DATE | TIME_MINUTES),
                                         dirStr, lastEntryInfo)
                          : "(EA baglandiktan sonra henuz mum kapanmadi)";

   string text = StringFormat(
      "==========================================================\n"
      "   MUM MODLU HEDGE v10.1 - MUM SAYACI TP/SL (GRID YOK)    \n"
      "==========================================================\n"
      "Giris Kurali : Her mum kapanisinda TEK islem\n"
      "               YUKARI mum -> SADECE BUY | ASAGI mum -> SADECE SELL\n"
      "TP Kurali    : Giris sonrasi %d adet LEHINE mum kapanisi\n"
      "SL Kurali    : Giris sonrasi %d adet ALEYHINE mum kapanisi\n"
      "Son Mum      : %s\n"
      "Not          : Kapanis emri ters yonludur (BUY'i SELL emri kapatir)\n"
      "               ve yorumu 'CIKIS ...' olur; yeni islem DEGILDIR.\n"
      "----------------------------------------------------------\n"
      "Acik Buy / Sell      : %d / %d  (Toplam: %d)\n"
      "Sepet Floating PnL   : %.2f USD\n"
      "Dongu Baslangic Varlik: %.2f USD\n"
      "Mevcut Net Varlik    : %.2f USD\n"
      "Hedef Net Varlik (%s) : %.2f USD | Kalan: %.2f USD\n"
      "----------------------------------------------------------\n"
      "Acilan Islem         : %d\n"
      "Mum TP ile Kapanan   : %d\n"
      "Mum SL ile Kapanan   : %d\n"
      "Sepet Sifirlama      : %d tur\n"
      "Kumulatif Realized   : %.2f USD\n"
      "==========================================================\n",
      InpTPCandleCount,
      InpSLCandleCount,
      lastCandleStr,
      buyPositions, sellPositions, buyPositions + sellPositions,
      floatingPnL,
      cycleStartEquity,
      currentEquity,
      tpModeStr, targetCycleEquity, remainingToTarget,
      totalTradesOpened,
      totalTPCloses,
      totalSLCloses,
      totalBasketCloses,
      totalRealizedProfitUSD
   );

   if(foreignSameMagic + foreignOtherMagic > 0)
      text += StringFormat("!! UYARI: Bu sembolde bu EA'ya AIT OLMAYAN %d pozisyon var (ayni magic: %d, diger: %d).\n"
                           "!! Grafikteki oklarin bir kismi onlardan geliyor. Ornek: %s\n"
                           "----------------------------------------------------------\n",
                           foreignSameMagic + foreignOtherMagic, foreignSameMagic, foreignOtherMagic, foreignSample);

   // Acik islemlerin mum sayaclari (en yeni olanlar ustte)
   text += "ACIK ISLEMLERIN MUM SAYACLARI (TP: " + IntegerToString(InpTPCandleCount) +
           " lehine / SL: " + IntegerToString(InpSLCandleCount) + " aleyhine)\n";

   // Comment() metni ~2045 karakterle sinirlidir; fazlasi sessizce kesilir.
   // Bu yuzden satirlar sinira gore eklenir ve gosterilemeyenlerin sayisi yazilir.
   int shown = 0, active = CountActiveTrades();
   for(int i = ArraySize(tradesTable) - 1; i >= 0 && shown < InpHudMaxRows; i--)
   {
      if(tradesTable[i].isClosed) continue;
      string row = StringFormat("#%I64u %s | Giris: %.5f | Lehine: %d/%d | Aleyhine: %d/%d\n",
                                tradesTable[i].ticket,
                                (tradesTable[i].isBuy ? "BUY " : "SELL"),
                                tradesTable[i].entryPrice,
                                tradesTable[i].tpCount, InpTPCandleCount,
                                tradesTable[i].slCount, InpSLCandleCount);
      if(StringLen(text) + StringLen(row) > 1990) break;
      text += row;
      shown++;
   }
   if(shown == 0 && active == 0) text += "(su an acik islem yok)\n";
   else if(shown < active)       text += StringFormat("... (+%d acik islem daha)\n", active - shown);

   Comment(text);
}

//+------------------------------------------------------------------+
//| EVENT HANDLERS                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   InitPipFactor();
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpTPCandleCount <= 0 && InpSLCandleCount <= 0)
   {
      Print("!! [HATA]: TP ve SL mum sayisi ayni anda 0 olamaz. En az biri pozitif olmali.");
      return INIT_PARAMETERS_INCORRECT;
   }

   ArrayResize(tradesTable, 0);

   // Ilk tick'te yanlis sinyal uretmemek icin mevcut mumu islenmis say
   lastBarProcessed  = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   lastCandleProcessed = 0;
   lastEntrySignalBar  = 0;
   lastCandleDir       = 0;
   lastEntryInfo       = "-";
   lastForeignReported = -1;

   cycleStartEquity  = accountInfo.Equity();
   targetCycleEquity = cycleStartEquity + InpTargetProfitUSD;

   PrintFormat(">> [MUM MODLU HEDGE v10.1] Baslatildi | Sembol: %s | Periyot: %s | Magic: %I64u | Giris: her mumda TEK islem (YUKARI=BUY, ASAGI=SELL) | TP: %d lehine mum | SL: %d aleyhine mum | Baslangic Varlik: %.2f USD",
               _Symbol, EnumToString(_Period), InpMagicNumber, InpTPCandleCount, InpSLCandleCount, cycleStartEquity);

   // Ayni sembolde baska EA / eski surum pozisyonlari varsa hemen uyar
   ScanForeignPositions();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   // Acik pozisyonlarla tabloyu esitle (harici kapananlar / yeniden baslatma)
   SyncTradesTable();

   // Yeni mum acildiysa = bir onceki mum KAPANDI
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(currentBarTime > 0 && currentBarTime != lastBarProcessed)
   {
      if(lastBarProcessed == 0)
      {
         // Grafige yeni baglandi: mevcut mumu baz al, geriye donuk sinyal uretme
         lastBarProcessed = currentBarTime;
      }
      else
      {
         // ONCEKI mum zamanini sakla: kac mumun kapandigi buna gore hesaplanir.
         // (v10.0'da lastBarProcessed once guncellendigi icin kacirilan mumlar hic sayilmiyordu.)
         datetime prevBarTime = lastBarProcessed;
         lastBarProcessed = currentBarTime;
         SyncRealizedProfits();
         ProcessClosedCandles(prevBarTime);
      }
   }

   // Sepet kar hedefi / drawdown korumasi
   CheckBasketTPAndProtection();

   // Bu sembolde baska EA / manuel pozisyon var mi? (sadece degisince gunluge yazar)
   ScanForeignPositions();

   if(InpShowHUD) UpdateHUD();
}
//+------------------------------------------------------------------+
