#!/usr/bin/env python3
"""生成人教版物理版本专属 TOC 卷：data/toc/physics/renjiao/gX{u,l}.json

默认知识卷 data/knowledge/physics/gX{u,l}.json 的 topics 已按人教版真实章节
归属（unit_name = "第一章 机械运动" ...），但 units 数组被写成了「一个知识点
一个伪单元」(u1..uN)。本脚本把 unit_name 的中文章节号解析出来，映射到
catalog.json 里该册的真实章节 id/name，重建 units、重写 topic 与 question 的
unit/unit_name，产出与译林三上同结构的 TOC 卷，让知识点菜单按真实教材章节分组。

用法: python3 tools/studyassist/build_physics_toc.py [--check]
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "data/catalog.json"
KNOW_DIR = ROOT / "data/knowledge/physics"
OUT_DIR = ROOT / "data/toc/physics/renjiao"

CN_DIGITS = {"零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
             "六": 6, "七": 7, "八": 8, "九": 9}
CHAPTER_RE = re.compile(r"第([一二三四五六七八九十百零]+)章")


def cn_to_int(s: str) -> int:
    """中文数字转整数，支持到几十（物理教材最多第22章）。"""
    s = s.strip()
    if not s:
        raise ValueError("empty")
    if s in CN_DIGITS:
        return CN_DIGITS[s]
    if "十" in s:
        parts = s.split("十")
        tens = CN_DIGITS.get(parts[0], 1) if parts[0] else 1
        ones = CN_DIGITS.get(parts[1], 0) if len(parts) > 1 and parts[1] else 0
        return tens * 10 + ones
    # "百" 暂不需要，留兜底
    total = 0
    for ch in s:
        if ch in CN_DIGITS:
            total = total * 10 + CN_DIGITS[ch]
    return total


def chapter_no(unit_name: str) -> int | None:
    m = CHAPTER_RE.search(unit_name or "")
    return cn_to_int(m.group(1)) if m else None


def catalog_unit_by_no(units: list) -> dict:
    # catalog unit id 形如 u1..u22，数字即章节号
    return {int(u["id"][1:]): u for u in units if re.fullmatch(r"u\d+", u["id"])}


def build_one(grade: int, sem: str, edition_units: list, check_only: bool):
    vol_file = KNOW_DIR / f"g{grade}{'l' if sem == 'lower' else 'u'}.json"
    data = json.loads(vol_file.read_text(encoding="utf-8"))

    by_no = catalog_unit_by_no(edition_units)
    problems = []

    # topic 章节号 → 真实 catalog 单元
    topic_to_unit = {}
    for t in data["topics"]:
        no = chapter_no(t.get("unit_name", ""))
        if no is None or no not in by_no:
            problems.append(f"topic {t['id']} 章节号解析失败: {t.get('unit_name')!r} -> {no}")
            continue
        topic_to_unit[t["id"]] = by_no[no]

    # 题目必须都能通过 topic 找到章节
    for q in data["questions"]:
        if q.get("topic") not in topic_to_unit:
            problems.append(f"question {q['id']} topic={q.get('topic')} 无对应章节")

    if problems:
        for p in problems[:20]:
            print(f"  ✗ {p}")
        raise SystemExit(f"g{grade}{sem[0]} 预检失败: {len(problems)} 处")

    if check_only:
        print(f"  ✓ g{grade}{sem[0]}: {len(data['topics'])} 知识点 / "
              f"{len(data['questions'])} 题 → {len(by_no)} 真实章节，映射齐全")
        return None

    # 真实章节列表（只保留本册 catalog 声明的单元，按章节号排序）
    units = [by_no[n] for n in sorted(by_no)]

    topics = []
    for t in data["topics"]:
        t = dict(t)
        real = topic_to_unit[t["id"]]
        t["unit"] = real["id"]
        t["unit_name"] = real["name"]
        topics.append(t)

    questions = []
    for q in data["questions"]:
        q = dict(q)
        real = topic_to_unit[q["topic"]]
        q["unit"] = real["id"]
        q["unit_name"] = real["name"]
        questions.append(q)

    out = {
        "schema_version": 1,
        "generated_by": "build_physics_toc.py (renjiao chapter alignment)",
        "source": {
            "site": "人教版物理教材目录（catalog.json units，经知识点 unit_name 章节号对齐）",
            "fetched": "2026-11-20",
        },
        "subject": "physics",
        "grade": grade,
        "semester": sem,
        "edition": "renjiao",
        "edition_label": "人教版",
        "units": units,
        "topics": topics,
        "questions": questions,
    }
    dest = OUT_DIR / f"g{grade}{'l' if sem == 'lower' else 'u'}.json"
    dest.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"  ✓ 写出 {dest.relative_to(ROOT)}: {len(units)} 章 / "
          f"{len(topics)} 知识点 / {len(questions)} 题")
    return dest


def main():
    check_only = "--check" in sys.argv
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    grades = catalog["subjects"]["physics"]["editions"]["renjiao"]["grades"]
    if not check_only:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("人教版物理 TOC 卷" + ("（预检）" if check_only else ""))
    for g in sorted(grades, key=int):
        for sem in ("upper", "lower"):
            if sem not in grades[g]:
                continue
            units = grades[g][sem]["units"]
            build_one(int(g), sem, units, check_only)


if __name__ == "__main__":
    main()
