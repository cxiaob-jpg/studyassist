# -*- coding: utf-8 -*-
"""Build recitation ("背诵") card decks from the quiz banks.

Sources (already bundled, so no network needed):
  * chinese  -- 「X」的下一句是哪一句？  -> poem-line cards
               《T》的作者是谁？        -> author cards
  * english  -- 词义选择题              -> word cards (word <-> meaning)
               读一读：...              -> sentence cards (sentence + 中文提示)

Output: data/recite/<subject>/g<grade>_<semester>.json

Usage:
    python tools/studyassist/build_recite.py [--plugin .] [--source ../../tax-src]
"""

import argparse
import glob
import json
import os
import re
import sys

CJK = re.compile(r"[\u4e00-\u9fff]")
LATIN = re.compile(r"[A-Za-z]")
QUOTED = re.compile(r"[「“\"]([^」”\"]{1,40})[」”\"]")

POEM_NEXT = re.compile(r"^「(.+?)」的下一句是哪一句？$")
POEM_PREV = re.compile(r"^「(.+?)」的上一句是哪一句？$")
AUTHOR = re.compile(r"^《(.+?)》的作者是谁？$")
PHRASE = re.compile(r"^([A-Za-z][A-Za-z\s'\-]{1,40}?)\s*(?:是|表示|意为|意思为)(.+?)[。．.]?$")


def load(path):
    with open(path, encoding="utf-8") as fp:
        return json.load(fp)


def is_word(text):
    """A single english word (letters, optional apostrophe/hyphen)."""
    return bool(text) and bool(re.fullmatch(r"[A-Za-z][A-Za-z'\- ]{0,24}", text.strip()))


def is_meaning(text):
    return bool(text) and bool(CJK.search(text)) and not LATIN.search(text)


def answer_text(q):
    if q.get("answer_mode") == "number":
        return None
    options = q.get("options") or []
    idx = q.get("answer")
    if not isinstance(idx, int) or not 1 <= idx <= len(options):
        return None
    return str(options[idx - 1]).strip()


def poem_cards(volume):
    cards = []
    for q in volume["questions"]:
        stem = q.get("stem", "").strip()
        m = POEM_NEXT.match(stem) or POEM_PREV.match(stem)
        if not m:
            continue
        answer = answer_text(q)
        if not answer:
            continue
        first = m.group(1).strip()
        mode = "next" if "下一句" in stem else "prev"
        if mode == "next":
            front, back = first, answer
        else:
            front, back = answer, first
        cards.append({
            "id": q["id"],
            "kind": "poem",
            "front": front,
            "back": back,
            "note": (q.get("explain") or "").strip(),
        })
    return cards


def author_cards(volume):
    cards = []
    for q in volume["questions"]:
        stem = q.get("stem", "").strip()
        m = AUTHOR.match(stem)
        if not m:
            continue
        answer = answer_text(q)
        if not answer:
            continue
        cards.append({
            "id": q["id"],
            "kind": "author",
            "front": "《%s》" % m.group(1).strip(),
            "back": "作者：" + answer,
            "note": (q.get("explain") or "").strip(),
        })
    return cards


def word_cards(volume):
    cards = []
    for q in volume["questions"]:
        stem = q.get("stem", "").strip()
        if "意思" not in stem and "表示" not in stem:
            continue
        answer = answer_text(q)
        if not answer:
            continue
        quoted = [tok.strip() for tok in QUOTED.findall(stem)]
        word, meaning = None, None
        for tok in quoted:
            if is_word(tok) and not word:
                word = tok
            elif is_meaning(tok) and not meaning:
                meaning = tok
        if is_word(answer) and not word:
            word = answer
        if is_meaning(answer) and not meaning:
            meaning = answer
        if not word or not meaning:
            continue
        if not LATIN.search(word):
            continue
        cards.append({
            "id": q["id"],
            "kind": "word",
            "front": word,
            "back": meaning,
            "note": (q.get("explain") or "").strip(),
        })
    return cards


def phrase_cards(volume):
    """Mine "X 是 Y" explanations into english-phrase / chinese-meaning cards."""
    cards = []
    for q in volume["questions"]:
        explain = (q.get("explain") or "").strip()
        m = PHRASE.match(explain)
        if not m:
            continue
        phrase = re.sub(r"\s+", " ", m.group(1)).strip(" .")
        meaning = m.group(2).strip(" 。，,.")
        if not is_meaning(meaning) or len(meaning) > 14:
            continue
        if not is_word(phrase) or len(phrase.split()) > 6 or len(phrase) < 3:
            continue
        cards.append({
            "id": "ph_" + q["id"],
            "kind": "phrase",
            "front": phrase,
            "back": meaning,
            "note": "",
        })
    return cards


def dedupe(cards):
    """Drop repeated cards; single-word phrases already covered by word cards."""
    word_fronts = {c["front"].lower() for c in cards if c["kind"] == "word"}
    seen, out = set(), []
    for card in cards:
        if card["kind"] == "phrase" and card["front"].lower() in word_fronts:
            continue
        key = (card["kind"], card["front"], card["back"])
        if key in seen:
            continue
        seen.add(key)
        out.append(card)
    return out


def volume_slots(path):
    m = re.search(r"g(\d+)_(upper|lower)\.json$", path)
    if not m:
        return None
    return int(m.group(1)), m.group(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plugin", default=".")
    ap.add_argument("--source", default=None, help="unused; kept for symmetry")
    args = ap.parse_args()
    plugin = os.path.abspath(args.plugin)
    data = os.path.join(plugin, "data")

    builders = {
        "chinese": [poem_cards, author_cards],
        "english": [word_cards, phrase_cards],
    }
    report = []
    for subject, fns in builders.items():
        out_dir = os.path.join(data, "recite", subject)
        for path in sorted(glob.glob(os.path.join(data, subject, "*", "g*.json"))):
            slot = volume_slots(path)
            if not slot:
                continue
            grade, semester = slot
            volume = load(path)
            cards = []
            for fn in fns:
                cards.extend(fn(volume))
            cards = dedupe(cards)
            os.makedirs(out_dir, exist_ok=True)
            out_path = os.path.join(out_dir, "g%d_%s.json" % (grade, semester))
            payload = {
                "subject": subject,
                "grade": grade,
                "semester": semester,
                "textbook": volume.get("textbook"),
                "cards": cards,
            }
            with open(out_path, "w", encoding="utf-8") as fp:
                json.dump(payload, fp, ensure_ascii=False, separators=(",", ":"))
            if cards:
                report.append((subject, grade, semester, len(cards)))

    print("=== 背诵卡片生成报告 ===")
    for subject, grade, semester, count in report:
        print("%-8s g%-2d %-5s %4d 张" % (subject, grade, semester, count))
    total = sum(item[3] for item in report)
    print("合计 %d 册 / %d 张卡片" % (len(report), total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
