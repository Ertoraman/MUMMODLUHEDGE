#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""'Mum Modlu Hedge Grid.mq5' icindeki mum-sayaci motorunun davranis testi.

BU BIR DERLEYICI DEGILDIR. MQL5 dosyasi burada derlenmez; dosyadaki
algoritma (ProcessClosedCandles + ApplyClosedCandleToCounters + OpenCandleTrade)
satir satir ayni semantikle Python'a aktarilir ve BAGIMSIZ bir "oracle"
(islem basi ileriye dogru tarama) ile karsilastirilir.

Esik degerler (TP=3 / SL=10) sabit yazilmaz, .mq5 icindeki input
varsayilanlarindan OKUNUR; boylece test dosyaya bagli kalir.
"""
import random
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "Mum Modlu Hedge Grid.mq5"


def read_defaults():
    raw = SRC.read_bytes()                      # MetaEditor UTF-8 ya da UTF-16 kaydedebilir
    txt = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8-sig")
    tp = int(re.search(r"InpTPCandleCount\s*=\s*(\d+)", txt).group(1))
    sl = int(re.search(r"InpSLCandleCount\s*=\s*(\d+)", txt).group(1))
    mx = int(re.search(r"InpMaxOpenPositions\s*=\s*(\d+)", txt).group(1))
    return tp, sl, mx


TP_N, SL_N, MAX_OPEN = read_defaults()


def direction(o, c):
    """Mum yonu: +1 yukari, -1 asagi, 0 doji (acilis == kapanis)."""
    if c > o:
        return 1
    if c < o:
        return -1
    return 0


# --------------------------------------------------------------------------
# EA MOTORUNUN AYNASI (MQL5 akisi: her yeni mumda once sayac, sonra giris)
# --------------------------------------------------------------------------
def run_engine(bars, tp_n=TP_N, sl_n=SL_N, max_open=10**9, restarts=()):
    """bars: [(open, close)] -> (trades, events)

    trade: dict(bar_open, is_buy, entry, close_bar, reason, tp, sl)
    """
    table = []          # acik/takipli islemler
    closed_trades = []
    events = []
    next_ticket = 1
    last_bar_processed = 0          # OnInit: mevcut mum islenmis sayilir
    n = len(bars)

    def try_close(t, sink, ev, ref_bar):
        """TryCloseByCandleCounts aynasi."""
        if t["closed"]:
            return False
        tp_hit = tp_n > 0 and t["tp"] >= tp_n
        sl_hit = sl_n > 0 and t["sl"] >= sl_n
        if not (tp_hit or sl_hit):
            return False
        t["closed"] = True
        t["close_bar"] = ref_bar
        t["reason"] = "TP" if tp_hit else "SL"
        sink.append(t)
        ev.append((ref_bar, "CLOSE", t["ticket"], t["reason"], t["tp"], t["sl"]))
        return True

    def apply_closed_candle(k):
        d = direction(*bars[k])
        for t in table:
            if t["closed"] or d == 0:
                continue
            if t["last_counted"] >= k:      # cift sayma korumasi
                continue
            in_favor = (t["is_buy"] and d == 1) or ((not t["is_buy"]) and d == -1)
            if in_favor:
                t["tp"] += 1
            else:
                t["sl"] += 1
            t["last_counted"] = k
            try_close(t, closed_trades, events, k)

    def open_trade(k, d):
        nonlocal next_ticket
        active = sum(1 for t in table if not t["closed"])
        if active >= max_open:
            return None
        t = {
            "ticket": next_ticket,
            "is_buy": d == 1,
            "entry_bar": k + 1,           # islem (k+1). mumun acilisinda acilir
            "entry": bars[k + 1][0],
            "last_counted": k,            # sinyal mumu SAYILMAZ
            "tp": 0,
            "sl": 0,
            "closed": False,
            "close_bar": None,
            "reason": None,
        }
        table.append(t)
        events.append((k, "OPEN", t["ticket"], "BUY" if t["is_buy"] else "SELL", 0, 0))
        next_ticket += 1
        return t

    for i in range(1, n):                 # i = yeni acilan mum
        if i in restarts:                 # EA yeniden baslatildi: sayaclari gecmisten kur
            for t in table:
                if t["closed"]:
                    continue
                t["tp"], t["sl"] = rebuild_counts(bars, t["entry_bar"], t["is_buy"], i)
                t["last_counted"] = i - 1
                try_close(t, closed_trades, events, i - 1)   # esik asildiysa beklemeden kapat
        last_bar_processed = i
        apply_closed_candle(i - 1)        # az once kapanan mum
        d = direction(*bars[i - 1])
        if d != 0:
            open_trade(i - 1, d)

    return table, closed_trades, events


def rebuild_counts(bars, entry_bar, is_buy, upto):
    """RebuildCandleCounts aynasi: giris mumu DAHIL, son kapanan muma kadar tum mumlar."""
    tp = sl = 0
    for k in range(entry_bar, upto):      # entry_bar .. upto-1 (upto-1 son kapanan mum)
        d = direction(*bars[k])
        if d == 0:
            continue
        if (is_buy and d == 1) or ((not is_buy) and d == -1):
            tp += 1
        else:
            sl += 1
    return tp, sl


# --------------------------------------------------------------------------
# BAGIMSIZ ORACLE: her islem icin giris sonrasini bastan tara
# --------------------------------------------------------------------------
def oracle(bars, entry_bar, is_buy, tp_n=TP_N, sl_n=SL_N):
    """Bagimsiz kontrol: islem basi ileriye dogru tarama.
    Son mum (len-1) simülasyon boyunca HENUZ KAPANMADIGI icin sayilmaz."""
    tp = sl = 0
    for k in range(entry_bar, len(bars) - 1):
        d = direction(*bars[k])
        if d == 0:
            continue
        if (is_buy and d == 1) or ((not is_buy) and d == -1):
            tp += 1
        else:
            sl += 1
        if tp_n > 0 and tp >= tp_n:
            return ("TP", k, tp, sl)
        if sl_n > 0 and sl >= sl_n:
            return ("SL", k, tp, sl)
    return (None, None, tp, sl)


# --------------------------------------------------------------------------
# TESTLER
# --------------------------------------------------------------------------
failures = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else "  -> " + detail))
    if not cond:
        failures.append(name)


def t_defaults():
    check("dosyadaki varsayilanlar TP=3 / SL=10", (TP_N, SL_N) == (3, 10),
          f"okunan degerler TP={TP_N} SL={SL_N}")


def t_buy_tp_non_consecutive():
    """Giris sonrasi: +,-,+,-,+  -> 3. YUKARI mumda TP (ardisiklik sart degil)."""
    bars = [(100, 101)]            # bar0: yukari -> bar1 acilisinda BUY
    bars += [(101, 102),           # bar1 (+) tp=1
             (102, 101.5),         # bar2 (-) sl=1
             (101.5, 102.5),       # bar3 (+) tp=2
             (102.5, 102.0),       # bar4 (-) sl=2
             (102.0, 103.0),       # bar5 (+) tp=3 -> TP
             (103.0, 104.0),
             (104.0, 105.0)]
    _, closed, _ = run_engine(bars)
    first = [t for t in closed if t["ticket"] == 1][0]
    check("BUY: 3. lehine mumda TP (araya dususler girdi)",
          first["reason"] == "TP" and first["close_bar"] == 5 and first["tp"] == 3 and first["sl"] == 2,
          f"reason={first['reason']} bar={first['close_bar']} tp={first['tp']} sl={first['sl']}")


def t_buy_sl_ten_bears():
    """BUY icin 10 ASAGI mum kapanisi -> SL (araya yukselisler girebilir)."""
    bars = [(100, 101)]            # bar0 yukari -> BUY
    seq = [-1, -1, 1, -1, -1, -1, 1, -1, -1, -1, -1, -1]   # 10 asagi, sadece 2 yukari
    for d in seq:
        last = bars[-1][1]
        bars.append((last, last + (1 if d == 1 else -1)))
    bars.append((bars[-1][1], bars[-1][1]))   # sondaki doji: son mumun da kapanmasini saglar
    _, closed, _ = run_engine(bars)
    first = [t for t in closed if t["ticket"] == 1][0]
    # bagimsiz sayim: 10. '-' hangi barda?
    cnt, expect_bar = 0, None
    for k in range(1, len(bars)):
        if direction(*bars[k]) == -1:
            cnt += 1
            if cnt == 10:
                expect_bar = k
                break
    check("BUY: 10. aleyhine mumda SL", first["reason"] == "SL" and first["sl"] == 10 and first["tp"] == 2,
          f"reason={first['reason']} sl={first['sl']} tp={first['tp']}")
    check("BUY: SL barda bagimsiz sayimla ayni", first["close_bar"] == expect_bar,
          f"motor={first['close_bar']} bagimsiz={expect_bar}")


def t_sell_mirror():
    """SELL: bar0 asagi -> SELL; 3 asagi mumda TP, 10 yukari mumda SL."""
    bars = [(100, 99)]
    for d in [-1, 1, -1, 1, -1, 1, 1, 1, 1, 1, 1, 1]:
        last = bars[-1][1]
        bars.append((last, last + d))
    _, closed, _ = run_engine(bars)
    first = [t for t in closed if t["ticket"] == 1][0]
    check("SELL: 3. asagi mumda TP", first["reason"] == "TP" and first["tp"] == 3 and first["sl"] == 2,
          f"reason={first['reason']} tp={first['tp']} sl={first['sl']}")

    bars2 = [(100, 99)]
    seq = [1, 1, -1, 1, 1, 1, -1, 1, 1, 1, 1, 1]   # 10 yukari, sadece 2 asagi
    for d in seq:
        last = bars2[-1][1]
        bars2.append((last, last + d))
    bars2.append((bars2[-1][1], bars2[-1][1]))   # sondaki doji: son mumun da kapanmasini saglar
    _, closed2, _ = run_engine(bars2)
    first2 = [t for t in closed2 if t["ticket"] == 1][0]
    check("SELL: 10. yukari mumda SL", first2["reason"] == "SL" and first2["sl"] == 10,
          f"reason={first2['reason']} sl={first2['sl']}")


def t_entry_every_bar():
    """Giris kurali: doji olmayan her mum kapanisi bir islem acmali."""
    rng = random.Random(7)
    bars = []
    price = 1.1000
    for _ in range(400):
        o = price
        step = rng.choice([-0.0004, -0.0002, 0.0, 0.0002, 0.0005])
        c = round(o + step, 5)
        bars.append((o, c))
        price = c
    table, closed, events = run_engine(bars, max_open=10**9)
    opens = [e for e in events if e[1] == "OPEN"]
    expected = sum(1 for k in range(0, len(bars) - 1) if direction(*bars[k]) != 0)
    check("her doji-olmayan mum kapanisi 1 islem acar", len(opens) == expected,
          f"acilan={len(opens)} beklenen={expected}")

    # yon dogrulugu
    bad = 0
    for (k, _, ticket, side, _tp, _sl) in opens:
        d = direction(*bars[k])
        if (d == 1) != (side == "BUY"):
            bad += 1
    check("yon: yukari kapanis=BUY, asagi kapanis=SELL", bad == 0, f"{bad} hatali yon")

    # doji mumu islem acmadi mi
    doji_bars = [k for k in range(len(bars) - 1) if direction(*bars[k]) == 0]
    check(f"doji mumlari islem acmadi ({len(doji_bars)} adet doji)",
          all(e[0] not in doji_bars for e in opens))

    # oracle ile karsilastir
    all_trades = table
    mismatch = 0
    for t in all_trades:
        reason, k, tp, sl = oracle(bars, t["entry_bar"], t["is_buy"])
        if reason is None:
            if t["closed"]:
                mismatch += 1
            continue
        if (not t["closed"]) or t["reason"] != reason or t["close_bar"] != k or t["tp"] != tp or t["sl"] != sl:
            mismatch += 1
    check(f"motor == bagimsiz oracle ({len(all_trades)} islem)", mismatch == 0, f"{mismatch} uyusmazlik")

    # TP her zaman 3. lehine mumda, SL her zaman 10. aleyhine mumda
    bad_tp = [t["ticket"] for t in closed if t["reason"] == "TP" and t["tp"] != 3]
    bad_sl = [t["ticket"] for t in closed if t["reason"] == "SL" and t["sl"] != 10]
    check("kapanan her TP islemi tam 3 lehine mumda kapandi", not bad_tp, str(bad_tp[:5]))
    check("kapanan her SL islemi tam 10 aleyhine mumda kapandi", not bad_sl, str(bad_sl[:5]))


def t_restart_rebuild():
    """EA ortada yeniden baslarsa sayaclar gecmisten dogru kurulmali."""
    rng = random.Random(99)
    bars = []
    price = 1.2000
    for _ in range(300):
        o = price
        c = round(o + rng.choice([-0.0005, -0.0001, 0.0001, 0.0006]), 5)
        bars.append((o, c))
        price = c
    restarts = tuple(range(20, 300, 25))
    t1, c1, _ = run_engine(bars, max_open=10**9)
    t2, c2, _ = run_engine(bars, max_open=10**9, restarts=restarts)
    sig1 = [(t["ticket"], t["is_buy"], t["tp"], t["sl"], t["close_bar"], t["reason"]) for t in t1]
    sig2 = [(t["ticket"], t["is_buy"], t["tp"], t["sl"], t["close_bar"], t["reason"]) for t in t2]
    check(f"restart sonrasi ayni sonuc ({len(restarts)} kez yeniden baslatma)", sig1 == sig2,
          "sayaclar farkli")
    check("restart testi bos degil", len(t1) > 50, f"{len(t1)} islem")


def t_max_open_cap():
    """InpMaxOpenPositions limiti girisi sinirlamali."""
    rng = random.Random(5)
    bars = []
    price = 1.3000
    for _ in range(200):
        o = price
        c = round(o + rng.choice([-0.0004, 0.0004, 0.0002, -0.0002]), 5)
        bars.append((o, c))
        price = c
    table, _, _ = run_engine(bars, max_open=MAX_OPEN)
    peak, cur = 0, 0
    for i in range(1, len(bars)):
        cur = sum(1 for t in table if t["entry_bar"] <= i and (t["close_bar"] is None or t["close_bar"] >= i))
        peak = max(peak, cur)
    check(f"maksimum acik islem limiti ({MAX_OPEN}) asilmadi", peak <= MAX_OPEN, f"tepe={peak}")


def t_deal_view():
    """MT5 'Islemler (Deals)' gorunumu.

    Her mumda en fazla 1 GIRIS deal'i olmali ve yonu mumun yonu olmali. Ayni anda gorunen
    ters yonlu deal'ler eski pozisyonlarin KAPANIS emirleridir (BUY, SELL emriyle kapanir).
    """
    rng = random.Random(11)
    bars, price = [], 1.1000
    for _ in range(3000):
        o = price
        c = round(o + rng.gauss(0, 0.0006), 5)
        bars.append((o, c))
        price = c
    table, _closed, events = run_engine(bars, max_open=MAX_OPEN)
    side = {t["ticket"]: ("buy" if t["is_buy"] else "sell") for t in table}
    ticks = {}                                   # k: (k+1). mumun ilk tick'i, yani mum k'nin kapanisi
    for (k, kind, ticket, _x, _tp, _sl) in events:
        d = ticks.setdefault(k, {"giris": [], "cikis": []})
        if kind == "OPEN":
            d["giris"].append(side[ticket])
        else:                                    # kapanis emri pozisyonun TERSI yondedir
            d["cikis"].append("sell" if side[ticket] == "buy" else "buy")
    max_entries = max(len(d["giris"]) for d in ticks.values())
    wrong_dir = sum(1 for k, d in ticks.items() for s in d["giris"]
                    if (s == "buy") != (direction(*bars[k]) == 1))
    both_sides = [k for k, d in ticks.items() if {"buy", "sell"} <= set(d["giris"] + d["cikis"])]
    both_in_entries = [k for k, d in ticks.items() if {"buy", "sell"} <= set(d["giris"])]
    check("deal gorunumu: her mumda en fazla 1 GIRIS, yonu = mumun yonu",
          max_entries <= 1 and wrong_dir == 0, f"max giris/mum={max_entries} yanlis yon={wrong_dir}")
    check("deal gorunumu: hicbir mumda ayni anda BUY ve SELL GIRISI yok",
          not both_in_entries, f"{len(both_in_entries)} mum")
    pct = 100.0 * len(both_sides) / len(ticks)
    print(f"INFO  {len(ticks)} mum kapanisinin %{pct:.0f}'inde giris + TERS yonlu KAPANIS emri ayni anda "
          f"gerceklesiyor -> grafikte/gecmiste 'hem buy hem sell' gibi gorunur (v10.1'de 'CIKIS ...' yorumlu)")


def t_deterministic_walk():
    """Uzun rastgele yuruyus: motor ile oracle her islemde ayni olmali."""
    for seed in (1, 2, 3):
        rng = random.Random(seed)
        bars = []
        price = 1.0000
        for _ in range(2000):
            o = price
            c = round(o + rng.gauss(0, 0.0006), 5)
            bars.append((o, c))
            price = c
        table, closed, _ = run_engine(bars, max_open=10**9)
        mismatch = 0
        for t in table:
            reason, k, tp, sl = oracle(bars, t["entry_bar"], t["is_buy"])
            if reason is None:
                if t["closed"]:
                    mismatch += 1
                continue
            if (not t["closed"]) or t["reason"] != reason or t["close_bar"] != k:
                mismatch += 1
        tp_c = sum(1 for t in closed if t["reason"] == "TP")
        sl_c = sum(1 for t in closed if t["reason"] == "SL")
        check(f"seed={seed}: 2000 mum, {len(table)} islem, motor==oracle, TP={tp_c} SL={sl_c}",
              mismatch == 0, f"{mismatch} uyusmazlik")


if __name__ == "__main__":
    print(f"Kaynaktan okunan esikler: TP={TP_N} lehine mum, SL={SL_N} aleyhine mum, maxAcik={MAX_OPEN}\n")
    t_defaults()
    t_buy_tp_non_consecutive()
    t_buy_sl_ten_bears()
    t_sell_mirror()
    t_entry_every_bar()
    t_restart_rebuild()
    t_max_open_cap()
    t_deal_view()
    t_deterministic_walk()
    print()
    if failures:
        print(f"{len(failures)} TEST BASARISIZ: {failures}")
        sys.exit(1)
    print("TUM TESTLER GECTI")
