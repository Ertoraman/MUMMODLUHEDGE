# tools/ — doğrulama yardımcıları

Bu klasördeki script'ler **MQL5 derleyicisi değildir**. MetaEditor / `mql5` bu
ortamda bulunmadığı için `Mum Modlu Hedge Grid.mq5` burada derlenemez; gerçek
derleme MetaEditor'da (F7) yapılmalıdır.

Script'ler iki şeyi kontrol eder:

| Script | Ne yapar | Ne yapmaz |
|---|---|---|
| `lint_mq5.py` | `.mq5` üzerinde yapısal lint: parantez/küme/köşeli denge, kapanmamış string/yorum, dosyada tanımsız ve MQL5 built-in listesinde olmayan fonksiyon çağrıları (typo yakalama), `PrintFormat`/`StringFormat` format belirteci ↔ argüman sayısı uyumu | Tip kontrolü, MQL5 sözdizimi semantiği |
| `test_candle_engine.py` | `.mq5` içindeki mum-sayacı motorunu (`ProcessClosedCandles` → `ApplyClosedCandleToCounters` → `TryCloseByCandleCounts`) aynı semantikle Python'a aktarır ve **bağımsız bir oracle** (işlem başı ileriye tarama) ile karşılaştırır. Eşikler (TP=3 / SL=10) sabit yazılmaz, `.mq5` içindeki input varsayılanlarından okunur | `.mq5` dosyasının kendisini çalıştırmaz |

Çalıştırma:

```bash
python3 tools/lint_mq5.py
python3 tools/test_candle_engine.py
```

Kapsanan davranışlar: girişin her mum kapanışında yön bazlı açılması, doji
(açılış = kapanış) mumlarının ne giriş açması ne de sayaç ilerletmesi, TP'nin
3. lehine mumda (ardışıklık aranmadan) ve SL'nin 10. aleyhine mumda tetiklenmesi,
BUY/SELL simetrisi, EA yeniden başlatıldığında sayaçların geçmişten doğru
kurulması, `InpMaxOpenPositions` limiti ve uzun rastgele serilerde motor↔oracle
eşitliği.
