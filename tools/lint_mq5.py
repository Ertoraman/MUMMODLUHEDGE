#!/usr/bin/env python3
"""Yapisal lint: 'Mum Modlu Hedge Grid.mq5' icin.

DERLEYICI DEGILDIR. Asil dogrulama MetaEditor'da (F7) yapilir. Bu arac
derlemeden once su sinif hatalari yakalar:
  * parantez / kose / kume dengesi (string ve yorum haric), kapanmamis literal
  * dosyada tanimli olmayan ve asagidaki MQL5 built-in listesinde bulunmayan
    serbest fonksiyon cagrilari (BUILTINS elle tutulur; eksik olabilir)
  * standart kutuphane nesnelerinde (CTrade, CPositionInfo, CAccountInfo)
    OLMAYAN metot cagrilari. Ornek: posInfo.OpenTime() -> dogrusu Time()
  * PrintFormat / StringFormat format belirteci <-> arguman sayisi uyumu

Kullanim:
  python3 tools/lint_mq5.py [dosya.mq5] [--include-dir "C:/.../MQL5/Include"]

--include-dir verilirse metot listeleri kendi MT5 kurulumunuzdaki
Include/Object.mqh ve Include/Trade/*.mqh dosyalarindan okunur (en guvenilir
kaynak budur). Verilmezse asagidaki gomulu liste kullanilir.
"""
import argparse
import difflib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_EA = REPO / "Mum Modlu Hedge Grid.mq5"

# Kaynak: MetaQuotes MQL5 Standard Library public metotlari
#   Include/Object.mqh, Include/Trade/Trade.mqh, PositionInfo.mqh, AccountInfo.mqh
# Iki farkli MT5 kurulum kopyasindan (telif satiri 2000-2024 ve 2000-2025)
# public_methods() ile cikarildi; iki surumde liste birebir ayni.
STDLIB_METHODS = {
    "CObject": [
        "Compare", "Load", "Next", "Prev", "Save", "Type"
    ],
    "CTrade": [
        "Buy", "BuyLimit", "BuyStop", "CheckResult", "CheckResultBalance", "CheckResultComment",
        "CheckResultEquity", "CheckResultMargin", "CheckResultMarginFree", "CheckResultMarginLevel",
        "CheckResultProfit", "CheckResultRetcode", "CheckResultRetcodeDescription", "CheckVolume",
        "FormatOrderPrice", "FormatOrderStatus", "FormatOrderType", "FormatOrderTypeFilling",
        "FormatOrderTypeTime", "FormatPositionType", "FormatRequest", "FormatRequestResult",
        "LogLevel", "OrderCheck", "OrderDelete", "OrderModify", "OrderOpen", "OrderSend",
        "PositionClose", "PositionCloseBy", "PositionClosePartial", "PositionModify",
        "PositionOpen", "PrintRequest", "PrintResult", "Request", "RequestAction",
        "RequestActionDescription", "RequestComment", "RequestDeviation", "RequestExpiration",
        "RequestMagic", "RequestOrder", "RequestPosition", "RequestPositionBy", "RequestPrice",
        "RequestSL", "RequestStopLimit", "RequestSymbol", "RequestTP", "RequestType",
        "RequestTypeDescription", "RequestTypeFilling", "RequestTypeFillingDescription",
        "RequestTypeTime", "RequestTypeTimeDescription", "RequestVolume", "Result", "ResultAsk",
        "ResultBid", "ResultComment", "ResultDeal", "ResultOrder", "ResultPrice", "ResultRetcode",
        "ResultRetcodeDescription", "ResultRetcodeExternal", "ResultVolume", "Sell", "SellLimit",
        "SellStop", "SetAsyncMode", "SetDeviationInPoints", "SetExpertMagicNumber", "SetMarginMode",
        "SetTypeFilling", "SetTypeFillingBySymbol"
    ],
    "CPositionInfo": [
        "CheckState", "Comment", "Commission", "FormatPosition", "FormatType", "Identifier",
        "InfoDouble", "InfoInteger", "InfoString", "Magic", "PositionType", "PriceCurrent",
        "PriceOpen", "Profit", "Select", "SelectByIndex", "SelectByMagic", "SelectByTicket",
        "StopLoss", "StoreState", "Swap", "Symbol", "TakeProfit", "Ticket", "Time", "TimeMsc",
        "TimeUpdate", "TimeUpdateMsc", "TypeDescription", "Volume"
    ],
    "CAccountInfo": [
        "Balance", "Company", "Credit", "Currency", "Equity", "FreeMargin", "FreeMarginCheck",
        "InfoDouble", "InfoInteger", "InfoString", "Leverage", "LimitOrders", "Login", "Margin",
        "MarginCall", "MarginCheck", "MarginLevel", "MarginMode", "MarginModeDescription",
        "MarginStopOut", "MaxLotCheck", "Name", "OrderProfitCheck", "Profit", "Server",
        "StopoutMode", "StopoutModeDescription", "TradeAllowed", "TradeExpert", "TradeMode",
        "TradeModeDescription"
    ],
}

STDLIB_FILES = {
    "CObject": "Object.mqh",
    "CTrade": "Trade/Trade.mqh",
    "CPositionInfo": "Trade/PositionInfo.mqh",
    "CAccountInfo": "Trade/AccountInfo.mqh",
}
STDLIB_CLASSES = ("CTrade", "CPositionInfo", "CAccountInfo")   # hepsi CObject'ten turer

BUILTINS = {
    # dizi / seri
    "ArraySize", "ArrayResize", "ArraySetAsSeries", "ArrayFree", "ArrayCopy", "ArrayMaximum", "ArrayMinimum",
    "CopyRates", "CopyBuffer", "CopyClose", "CopyOpen", "CopyTime",
    "iTime", "iOpen", "iClose", "iHigh", "iLow", "iBarShift", "iATR", "IndicatorRelease",
    # sembol / hesap
    "SymbolInfoDouble", "SymbolInfoInteger", "SymbolInfoString", "SeriesInfoInteger",
    "AccountInfoDouble", "AccountInfoInteger",
    # matematik
    "MathAbs", "MathFloor", "MathMax", "MathMin", "MathPow", "MathSqrt", "MathRound", "MathCeil",
    # string / zaman
    "StringFormat", "StringLen", "StringFind", "StringSubstr", "IntegerToString", "DoubleToString",
    "TimeToString", "TimeCurrent", "StringToTime",
    # trade
    "PositionsTotal", "PositionGetTicket", "PositionSelectByTicket", "PositionGetDouble", "PositionGetInteger",
    "HistorySelect", "HistoryDealsTotal", "HistoryDealGetTicket", "HistoryDealGetDouble",
    "HistoryDealGetInteger", "HistoryDealGetString", "HistoryDealSelect",
    "OrderGetTicket", "OrdersTotal",
    # sistem
    "Print", "PrintFormat", "Comment", "Alert", "MessageBox", "GetLastError", "Sleep",
    "EnumToString", "StringToDouble", "IsStopped", "UninitializeReason", "TerminalInfoInteger",
    "MathIsValidNumber", "ZeroMemory", "ArrayInitialize", "ExpertRemove",
}

KEYWORDS = {"if", "for", "while", "switch", "return", "else", "sizeof", "catch", "do"}


def read_text(path):
    """MetaEditor dosyalari UTF-8 (BOM'lu/BOM'suz) veya UTF-16 olabilir."""
    raw = Path(path).read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    return raw.decode("utf-8-sig", errors="replace")


def public_methods(text, cls):
    """Bir .mqh icindeki 'class cls' bildiriminin public metot adlari."""
    m = re.search(r"class\s+%s\b[^{]*\{(.*?)\n\s*\};" % re.escape(cls), text, re.S)
    if not m:
        raise ValueError(f"'{cls}' sinif bildirimi bulunamadi")
    body = re.sub(r"//[^\n]*", "", m.group(1))
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    prev = None
    while prev != body:                                   # satir ici govdeleri { ... } sok
        prev = body
        body = re.sub(r"\{[^{}]*\}", ";", body)
    body = re.sub(r"\)\s*:\s*[^;]*", ");", body)          # kurucu ilklendirme listeleri
    public, mode = [], "private"
    for stmt in body.split(";"):
        while True:
            a = re.search(r"\b(public|protected|private)\s*:", stmt)
            if not a:
                break
            if mode == "public":
                public.append(stmt[:a.start()])
            mode, stmt = a.group(1), stmt[a.end():]
        if mode == "public":
            public.append(stmt)
    names = set()
    for stmt in public:
        n = re.search(r"\b([A-Za-z_]\w*)\s*\(", stmt)    # bildirimdeki ilk 'isim(' = metot adi
        if n:
            names.add(n.group(1))
    return names - {cls, "virtual", "operator"}


def load_methods(include_dir):
    if include_dir:
        base = Path(include_dir)
        raw = {cls: public_methods(read_text(base / rel), cls) for cls, rel in STDLIB_FILES.items()}
        source = f"yerel kurulum: {base}"
    else:
        raw = {cls: set(v) for cls, v in STDLIB_METHODS.items()}
        source = "gomulu liste (MQL5 std lib 2024/2025)"
    return {cls: raw[cls] | raw["CObject"] for cls in STDLIB_CLASSES}, source


def mask_comments_and_strings(src):
    """Yorum ve string iceriklerini bosluga cevirir (satir/sutun korunur)."""
    masked, unclosed = [], []
    i, n = 0, len(src)
    in_str = in_chr = in_line = in_block = False
    line = 1
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "\n":
            line += 1
            if in_str:
                unclosed.append(("string", line - 1))
            if in_chr:
                unclosed.append(("char", line - 1))
            in_str = in_chr = in_line = False
            masked.append(c)
            i += 1
            continue
        if in_line:
            masked.append(" ")
            i += 1
            continue
        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                masked.append("  ")
                i += 2
                continue
            masked.append(" ")
            i += 1
            continue
        if in_str or in_chr:
            quote = '"' if in_str else "'"
            if c == "\\":
                masked.append("  ")
                i += 2
                continue
            if c == quote:
                in_str = in_chr = False
            masked.append(" ")
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            masked.append("  ")
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block = True
            masked.append("  ")
            i += 2
            continue
        if c == '"':
            in_str = True
        elif c == "'":
            in_chr = True
        masked.append(c)
        i += 1
    return "".join(masked), unclosed, in_block


def line_of(text, idx):
    return text.count("\n", 0, idx) + 1


def check_balance(mtext, unclosed, open_block):
    errors = []
    if open_block:
        errors.append("kapanmamis /* blogu")
    for kind, ln in unclosed:
        errors.append(f"satir {ln}: kapanmamis {kind} literali")
    stack, pairs = [], {")": "(", "]": "[", "}": "{"}
    for idx, c in enumerate(mtext):
        if c in "([{":
            stack.append((c, line_of(mtext, idx)))
        elif c in ")]}":
            if not stack:
                errors.append(f"satir {line_of(mtext, idx)}: fazla '{c}'")
            else:
                op, opl = stack.pop()
                if op != pairs[c]:
                    errors.append(f"satir {line_of(mtext, idx)}: '{op}' (satir {opl}) '{c}' ile kapanmis")
    for op, opl in stack:
        errors.append(f"satir {opl}: '{op}' hic kapanmamis")
    return errors


def check_free_calls(mtext):
    defined = set(re.findall(r"^\s*(?:[A-Za-z_]\w*\s+)+([A-Za-z_]\w*)\s*\(", mtext, re.M))
    calls = {}
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", mtext):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        pre = mtext[: m.start()].rstrip()
        if pre.endswith("."):                 # uye cagrisi -> check_member_calls() denetler
            continue
        if re.search(r"(?:void|int|bool|double|string|ulong|long|datetime|struct|enum|"
                     r"if|for|while|switch|return|else)$", pre):
            continue                          # tanim satirinin kendisi
        calls.setdefault(name, line_of(mtext, m.start()))
    unknown = [f"satir {ln}: {name}()" for name, ln in sorted(calls.items(), key=lambda x: x[1])
               if name not in defined and name not in BUILTINS]
    return unknown, defined


def check_member_calls(mtext, methods):
    """CTrade/CPositionInfo/CAccountInfo nesnelerinde olmayan metot cagrilarini bulur."""
    obj_class = {}
    decl = r"\b(%s)\s*[*&]?\s*([A-Za-z_]\w*)\s*[;=\[,)]" % "|".join(STDLIB_CLASSES)
    for m in re.finditer(decl, mtext):
        obj_class[m.group(2)] = m.group(1)
    issues, checked = [], 0
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\.\s*([A-Za-z_]\w*)\s*\(", mtext):
        obj, meth = m.group(1), m.group(2)
        cls = obj_class.get(obj)
        if cls is None:
            continue
        checked += 1
        if meth not in methods[cls]:
            hint = difflib.get_close_matches(meth, sorted(methods[cls]), n=3, cutoff=0.5)
            issues.append(f"satir {line_of(mtext, m.start())}: {obj}.{meth}() -> {cls} sinifinda "
                          f"'{meth}' metodu yok" + (f" (benzerleri: {', '.join(hint)})" if hint else ""))
    return issues, checked, obj_class


def check_format_args(src):
    issues = []
    for m in re.finditer(r"\b(StringFormat|PrintFormat)\s*\(", src):
        start = m.end()
        depth, j = 1, start
        while j < len(src) and depth:
            if src[j] == '"':
                j += 1
                while j < len(src) and src[j] != '"':
                    if src[j] == "\\":
                        j += 1
                    j += 1
            elif src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = src[start:j]
        literals = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', body))
        spec_count = len(re.findall(r"%[-+ #0]*[\d.IlhzjtL]*[dfsuxXoeEgGaAcspn]", literals.replace("%%", "")))
        top_commas, d, instr, k = 0, 0, False, 0
        while k < len(body):
            ch = body[k]
            if instr:
                if ch == "\\":
                    k += 1
                elif ch == '"':
                    instr = False
            elif ch == '"':
                instr = True
            elif ch in "([":
                d += 1
            elif ch in ")]":
                d -= 1
            elif ch == "," and d == 0:
                top_commas += 1
            k += 1
        if spec_count != top_commas:
            issues.append(f"satir {line_of(src, m.start())}: {m.group(1)} -> {spec_count} format belirteci, "
                          f"{top_commas} arguman")
    return issues


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", default=str(DEFAULT_EA))
    ap.add_argument("--include-dir", help="MT5 kurulumundaki MQL5/Include klasoru (opsiyonel)")
    args = ap.parse_args()

    src = read_text(args.file)
    mtext, unclosed, open_block = mask_comments_and_strings(src)
    methods, method_source = load_methods(args.include_dir)

    balance = check_balance(mtext, unclosed, open_block)
    unknown_calls, defined = check_free_calls(mtext)
    member_issues, member_checked, objects = check_member_calls(mtext, methods)
    fmt_issues = check_format_args(src)
    inputs = re.findall(r"^input\s+(?!group\b)[A-Za-z_][\w:]*\s+([A-Za-z_]\w*)", src, re.M)

    sections = [
        ("DENGE / LITERAL", balance),
        ("TANIMSIZ FONKSIYON CAGRILARI", unknown_calls),
        ("STANDART KUTUPHANE METOT CAGRILARI", member_issues),
        ("FORMAT BELIRTECI / ARGUMAN UYUMSUZLUGU", fmt_issues),
    ]
    print(f"Dosya: {args.file}")
    for title, items in sections:
        print(f"\n== {title} ==")
        print("\n".join(items) if items else "OK")
    print(f"\nTanimli fonksiyon: {len(defined)} | input: {len(inputs)} | "
          f"std-lib nesneleri: {', '.join(f'{o}:{c}' for o, c in sorted(objects.items()))}")
    print(f"Denetlenen std-lib metot cagrisi: {member_checked}  (kaynak: {method_source})")
    sys.exit(1 if any(items for _, items in sections) else 0)


if __name__ == "__main__":
    main()
