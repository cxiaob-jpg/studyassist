# -*- coding: utf-8 -*-
"""构建语文默写词表：data/dictation/chinese/gX_Y.json
词只取本册写字表内字组成的词（孩子会写才默写），拼音用 pypinyin 按词标注（多音字按词读音）。
"""
import json, re, html, os
from pypinyin import pinyin, Style

DATA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data"))
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dict_src")
OUT = f"{DATA}/dictation/chinese"
os.makedirs(OUT, exist_ok=True)

CJK = r"[\u4e00-\u9fff]"
PY = r"[a-züāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜêɡńňǹḿ]+"

def parse_paren(text):
    text = text.replace("（", "(").replace("）", ")").replace("\xa0", " ").replace("\u3000", " ")
    chars, order = {}, []
    for m in re.finditer(r"(" + CJK + r")\s*(" + PY + r")?\s*((?:\([^()]{1,30}\))+)", text):
        ch, groups = m.group(1), m.group(3)
        words = []
        for g in re.findall(r"\(([^()]{1,30})\)", groups):
            for w in re.split(r"[\s、，,]+", g.strip()):
                if w and re.fullmatch(CJK + "{1,4}", w):
                    words.append(w)
        chars.setdefault(ch, {"words": []})["words"].extend(words)
        if ch not in order:
            order.append(ch)
    return chars, order

def parse_lines(text):
    text = text.replace("\xa0", " ").replace("\u3000", " ")
    chars, order, last_ch = {}, [], None
    for line in text.split("\n"):
        line = line.strip()
        m = re.match(r"^(" + CJK + r")\s*(" + PY + r")\s+(.+)$", line)
        m2 = re.match(r"^(" + PY + r")\s+(.+)$", line)
        if m:
            ch, rest = m.group(1), m.group(3)
            last_ch = ch
        elif m2 and last_ch:
            ch, rest = last_ch, m2.group(2)
        else:
            continue
        words = [w for w in re.split(r"[\s、，,]+", rest) if w and re.fullmatch(CJK + "{2,4}", w)]
        chars.setdefault(ch, {"words": []})["words"].extend(words)
        if ch not in order:
            order.append(ch)
    return chars, order

def tone_py(word):
    out = []
    for item in pinyin(word, style=Style.TONE, heteronym=False, errors="ignore"):
        if not item:
            return None
        out.append(item[0].replace("ɡ", "g"))
    return " ".join(out) if len(out) == len(word) else None

CHARSETS = {}

def build(grade, semester, chars, order, source, cap=2):
    CHARSETS[(grade, semester)] = set(order)
    learned = set(order)
    other = "lower" if semester == "upper" else "upper"
    learned |= CHARSETS.get((grade, other), set())
    words, seen, covered = [], set(), set()
    for ch in order:
        n = 0
        for w in chars[ch]["words"]:
            if w in seen or not all(c in learned for c in w):
                continue
            py = tone_py(w)
            if not py:
                continue
            words.append({"w": w, "py": py})
            seen.add(w)
            covered.update(w)
            n += 1
            if n >= cap:
                break
    singles = 0
    for ch in order:
        if ch not in covered:
            py = tone_py(ch)
            if py:
                words.append({"w": ch, "py": py})
                singles += 1
    out = {"grade": grade, "semester": semester, "subject": "chinese",
           "source": source, "words": words}
    json.dump(out, open(f"{OUT}/g{grade}_{semester}.json", "w"), ensure_ascii=False, indent=1)
    multi = sum(1 for w in words if len(w["w"]) > 1)
    print(f"g{grade}_{semester}: {len(order)} 字 | {len(words)} 项（词 {multi} + 单字 {singles}）| 覆盖 {len(covered)} 字")
    return words

build(1, "upper", *parse_paren(open(f"{SRC}/dict_raw_g1u.txt").read()),
      source="统编一上写字表（2024秋版）")
build(2, "upper", *parse_paren(open(f"{SRC}/dict_raw_g2u.txt").read()),
      source="统编二上写字表（2025秋版）")
build(1, "lower", *parse_paren(open(f"{SRC}/dict_raw_g1l.txt").read()),
      source="统编一下写字表（2025春新版）")
build(2, "lower", *parse_paren(open(f"{SRC}/dict_raw_g2l.txt").read()),
      source="统编二下写字表（2026春新版）")
raw = open(f"{SRC}/g3l_5156.html", "rb").read().decode("gb18030", "ignore")
txt = html.unescape(re.sub(r"<[^>]+>", "\n", raw))
i = txt.find("融róng")
seg = txt[i:txt.find("版权所有") if "版权所有" in txt[i:] else len(txt)]
build(3, "lower", *parse_lines(seg), source="统编三下写字表（拼音组词）")
