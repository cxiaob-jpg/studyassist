#!/usr/bin/env python3
"""补齐译林版缺口册：五下(g5l) / 六下(g6l)。

沿用物理方法论：知识点/题目是通用池（knowledge/english/g5l.json、g6l.json，
题目带 topic），只有「单元划分」按版本不同。译林 5B/6B 真实单元名取自 dzkbw，
把通用知识点按序均匀重挂到译林单元，题目随知识点走。

产出：
- data/toc/yingyu/yilin/g5l.json / g6l.json    （TOC 知识点卷）
- data/english/yilin/g5_lower.json / g6_lower.json（Bank 题库）
- catalog.json 的 yilin.grades 补 5.lower / 6.lower

说明：译林 5B/6B 无独立专项题库（其余 5 册有），这里复用通用池，
属预期降级；单元名是译林真实目录，知识点落位按序兜底。

目录来源：http://m.dzkbw.com/books/yilin/yingyu/5b 与 /6b（2026-11-20 抓取）
用法：python3 tools/studyassist/build_yilin_gaps.py [--check]
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/english"
TOC_OUT = ROOT / "data/toc/yingyu/yilin"
BANK_OUT = ROOT / "data/english/yilin"
CATALOG = ROOT / "data/catalog.json"

# 译林 5B/6B 真实单元（dzkbw 目录，Project 不计入练习单元，与现有 8 单元制一致）
UNITS = {
    "g5l": [
        "U1·Cinderella", "U2·How do you come to school?", "U3·Asking the way",
        "U4·Seeing the doctor", "U5·Helping our parents", "U6·In the kitchen",
        "U7·Chinese festivals", "U8·Birthdays",
    ],
    "g6l": [
        "U1·The lion and the mouse", "U2·Good habits", "U3·A healthy diet",
        "U4·Road safety", "U5·A party", "U6·An interesting country",
        "U7·Summer holiday plans", "U8·Our dreams",
    ],
}
LABEL = "译林版"
SOURCE = "译林版 5B/6B 目录（dzkbw 2026-11-20）；知识点/题目复用 knowledge/english 通用池"


def build(vol, sem, grade, bank_name):
    know = json.loads((KNOW / f"{vol}.json").read_text(encoding="utf-8"))
    unit_names = UNITS[vol]
    n = len(unit_names)
    units = [{"id": f"u{i+1}", "name": name} for i, name in enumerate(unit_names)]

    # 通用知识点按序均匀落到译林单元
    assign = {}
    for i, t in enumerate(know["topics"]):
        uid = f"u{i % n + 1}"
        assign[t["id"]] = uid

    topics = []
    for t in know["topics"]:
        uid = assign[t["id"]]
        uname = unit_names[int(uid[1:]) - 1]
        topics.append({
            "id": t["id"], "name": t["name"],
            "domain": t.get("domain"), "kp_type": t.get("kp_type"),
            "unit": uid, "unit_name": uname,
            "description": t.get("description"),
            "mastery_criteria": t.get("mastery_criteria"),
            "example": t.get("example"),
        })

    questions = []
    skipped = 0
    for q in know["questions"]:
        tid = q.get("topic")
        if tid not in assign:
            skipped += 1
            continue
        uid = assign[tid]
        uname = unit_names[int(uid[1:]) - 1]
        nq = dict(q)
        nq["edition"] = "yilin"
        nq["unit"] = uid
        nq["unit_name"] = uname
        questions.append(nq)

    toc = {
        "schema_version": 1,
        "generated_by": "build_yilin_gaps.py (universal pool re-anchor)",
        "source": SOURCE,
        "subject": "english", "grade": grade, "semester": sem,
        "edition": "yilin", "edition_label": LABEL,
        "units": units, "topics": topics, "questions": questions,
    }
    bank = {
        "schema_version": 2,
        "subject": "english", "grade": grade, "semester": sem,
        "textbook": LABEL,
        "questions": questions,
    }
    return toc, bank, skipped


def update_catalog(results):
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    yl = cat["subjects"]["english"]["editions"]["yilin"]
    for vol, (grade, sem, bank_name, toc) in results.items():
        units = toc["units"]
        yl["grades"].setdefault(str(grade), {})[sem] = {
            "file": f"english/yilin/{bank_name}.json",
            "units": units,
        }
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")


def main():
    check_only = "--check" in sys.argv
    print("译林缺口册生成" + ("（预检）" if check_only else ""))
    results = {}
    for vol, grade, sem, bank_name in [
        ("g5l", 5, "lower", "g5_lower"),
        ("g6l", 6, "lower", "g6_lower"),
    ]:
        toc, bank, skipped = build(vol, sem, grade, bank_name)
        results[vol] = (grade, sem, bank_name, toc)
        print(f"  {vol}: {len(toc['units'])}单元 {len(toc['topics'])}知识点 "
              f"{len(toc['questions'])}题 跳过{skipped}")
        if check_only:
            continue
        TOC_OUT.mkdir(parents=True, exist_ok=True)
        BANK_OUT.mkdir(parents=True, exist_ok=True)
        (TOC_OUT / f"{vol}.json").write_text(
            json.dumps(toc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        (BANK_OUT / f"{bank_name}.json").write_text(
            json.dumps(bank, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if not check_only:
        update_catalog(results)
        print("catalog yilin 已补 5.lower / 6.lower")


if __name__ == "__main__":
    main()
