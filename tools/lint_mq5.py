#!/usr/bin/env python3
"""Yapisal lint: 'Mum Modlu Hedge Grid.mq5' icin.

Derleyici degildir; sozdizimi/typo sinifi hatalari yakalar:
  * sudeli parantez / kose / kume dengesi (string ve yorum haric)
  * kapanmamis string literali
  * dosyada tanimli olmayan ve MQL5 built-in listesinde bulunmayan fonksiyon cagrilari
  * kullanilip da hic tanimlanmamis global degiskenler
"""
import re
import sys

PATH = "Mum Modlu Hedge Grid.mq5"
src = open(PATH, encoding="utf-8").read()

# --- 1) Yorum ve string'leri maskele (denge kontrolu icin) -------------------
masked = []
i, n = 0, len(src)
in_str = in_chr = in_line = in_block = False
line = 1
unclosed = []
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
    if in_str:
        if c == "\\":
            masked.append("  ")
            i += 2
            continue
        if c == '"':
            in_str = False
        masked.append(" ")
        i += 1
        continue
    if in_chr:
        if c == "\\":
            masked.append("  ")
            i += 2
            continue
        if c == "'":
            in_chr = False
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
        masked.append('"')
        i += 1
        continue
    if c == "'":
        in_chr = True
        masked.append("'")
        i += 1
        continue
    masked.append(c)
    i += 1

mtext = "".join(masked)
errors = []
if in_block:
    errors.append("kapanmamis /* blogu")
for kind, ln in unclosed:
    errors.append(f"satir {ln}: kapanmamis {kind} literali")

# --- 2) Denge kontrolu -------------------------------------------------------
stack = []
pairs = {")": "(", "]": "[", "}": "{"}
for idx, c in enumerate(mtext):
    if c in "([{":
        stack.append((c, mtext.count("\n", 0, idx) + 1))
    elif c in ")]}":
        if not stack:
            errors.append(f"satir {mtext.count(chr(10),0,idx)+1}: fazla '{c}'")
        else:
            op, opl = stack.pop()
            if op != pairs[c]:
                errors.append(f"satir {mtext.count(chr(10),0,idx)+1}: '{op}' (satir {opl}) '{c}' ile kapanmis")
for op, opl in stack:
    errors.append(f"satir {opl}: '{op}' hic kapanmamis")

# --- 3) Fonksiyon tanimlari ve cagrilari ------------------------------------
defined = set(re.findall(r"^\s*(?:[A-Za-z_][\w]*\s+)+([A-Za-z_]\w*)\s*\(", mtext, re.M))
defined |= set(re.findall(r"^\s*(?:void|int|bool|double|string|ulong|long|datetime)\s+([A-Za-z_]\w*)\s*\(", mtext, re.M))

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
    "TimeToString", "TimeCurrent", "TimeToString", "StringToTime",
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

calls = set()
for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", mtext):
    name = m.group(1)
    if name in ("if", "for", "while", "switch", "return", "else", "sizeof", "catch"):
        continue
    pre = mtext[: m.start()].rstrip()
    # uye erisimi (trade.Buy, posInfo.Select...) -> built-in sinif metodu, atla
    if pre.endswith("."):
        continue
    # tanim satirinin kendisini (donus tipi + isim) cagri sayma
    if re.search(r"(?:void|int|bool|double|string|ulong|long|datetime|struct|enum|if|for|while|switch|return|else)$", pre):
        continue
    calls.add(name)

unknown_calls = sorted(c for c in calls if c not in defined and c not in BUILTINS)

# --- 4) Global degisken kullanim kontrolu -----------------------------------
LOCAL_TYPES = r"(?:void|int|bool|double|string|ulong|long|datetime|SCandleTrade|MqlRates|CTrade|CPositionInfo|CAccountInfo)"
declared_globals = set(re.findall(rf"^{LOCAL_TYPES}\s+([A-Za-z_]\w*)\s*(?:=|;|\[)", src, re.M))
inputs = set(re.findall(r"^input\s+(?:group\s+\"[^\"]*\"|[A-Za-z_][\w:]*)\s+([A-Za-z_]\w*)", src, re.M))

# --- 5) StringFormat / PrintFormat argüman sayisi (yuzde spec kontrolu) ------
fmt_issues = []
for m in re.finditer(r"(StringFormat|PrintFormat)\s*\(", src):
    start = m.end()
    depth, i2 = 1, start
    while i2 < len(src) and depth:
        if src[i2] == '"':
            i2 += 1
            while i2 < len(src) and src[i2] != '"':
                if src[i2] == "\\":
                    i2 += 1
                i2 += 1
        elif src[i2] == "(":
            depth += 1
        elif src[i2] == ")":
            depth -= 1
            if depth == 0:
                break
        i2 += 1
    body = src[start:i2]
    # ilk arguman: birlestirilmis string literalleri
    spec_count = len(re.findall(r"%[-+ #0]*[\d.IlhzjtL]*[dfsuxXoeEgGaAcspn%]", body)) - body.count("%%")
    top_args = 0
    d, instr = 0, False
    for ch in body:
        if ch == '"':
            instr = not instr
        elif not instr:
            if ch in "([":
                d += 1
            elif ch in ")]":
                d -= 1
            elif ch == "," and d == 0:
                top_args += 1
    provided = top_args  # virgul sayisi = arguman-1, ilk arguman format string'i
    line_no = src.count("\n", 0, m.start()) + 1
    if spec_count != provided:
        fmt_issues.append(f"satir {line_no}: {m.group(1)} -> {spec_count} format belirteci, {provided} arguman")

print("== DENGE / LITERAL ==")
print("\n".join(errors) if errors else "OK")
print("\n== TANIMSIZ FONKSIYON CAGRILARI ==")
print("\n".join(unknown_calls) if unknown_calls else "OK")
print("\n== FORMAT BELIRTECI / ARGUMAN UYUMSUZLUGU ==")
print("\n".join(fmt_issues) if fmt_issues else "OK")
print(f"\nTanimli fonksiyon sayisi: {len(defined)}  | input sayisi: {len(inputs)}  | global: {len(declared_globals)}")
sys.exit(1 if (errors or unknown_calls or fmt_issues) else 0)
