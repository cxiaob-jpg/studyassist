#!/usr/bin/env python3
"""历史 TOC 生成（统编单版本，恒等重挂）。

历史是特殊情况：全国统编一家，`data/knowledge/history/gX{u,l}.json` 里的
units/topics/questions 本来就是按 2024 统编目录组织的，单元 id 与
catalog 完全一致（u1..uN）。所以这里不做关键词匹配，只做两件事：

1. 用 catalog 的单元名（带「第N单元·」分隔符）覆盖 knowledge 的写法，
   让知识点页显示的章节名与设置页/报告里的版本名完全一致；
2. 落一份 `data/toc/history/tongbian/gX{u,l}.json`，让 Knowledge.load
   优先走版本 TOC（与物理/化学/地理同构），而不是回退到通用知识卷。

题库 `data/history/tongbian/gX_*.json` 不动：Bank.load 的单元名取自
catalog 本身，出题侧已经是对的。

用法：python3 tools/studyassist/build_history_toc.py [--check]
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/history"
TOC_OUT = ROOT / "data/toc/history/tongbian"
CATALOG = ROOT / "data/catalog.json"


def main():
    check_only = "--check" in sys.argv
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    node = cat["subjects"]["history"]["editions"]["tongbian"]

    print("历史 TOC" + ("（预检）" if check_only else ""))
    total_t = total_q = 0
    problems = 0

    for g in sorted(node["grades"], key=lambda x: int(x)):
        for sem in ("upper", "lower"):
            vol_data = node["grades"][g].get(sem)
            if not vol_data:
                continue
            vol = f"g{g}{'u' if sem == 'upper' else 'l'}"
            src = KNOW / f"{vol}.json"
            if not src.exists():
                print(f"  !! {vol} 缺知识点卷 {src}")
                problems += 1
                continue
            kb = json.loads(src.read_text(encoding="utf-8"))

            units = [{"id": u["id"], "name": u["name"]} for u in vol_data["units"]]
            name_of = {u["id"]: u["name"] for u in units}
            unit_ids = [u["id"] for u in units]

            # 对齐校验：知识点/题目不能挂到不存在的单元上
            kid = [u["id"] for u in kb.get("units") or []]
            if kid != unit_ids:
                print(f"  !! {vol} 单元 id 不一致：knowledge {kid} vs catalog {unit_ids}")
                problems += 1
                continue
            stray_t = sorted({t["unit"] for t in kb["topics"]} - set(unit_ids))
            stray_q = sorted({q.get("unit") for q in kb["questions"]} - set(unit_ids))
            if stray_t or stray_q:
                print(f"  !! {vol} 越界单元 topics={stray_t} questions={stray_q}")
                problems += 1
                continue

            topics = []
            for t in kb["topics"]:
                nt = dict(t)
                nt["unit_name"] = name_of[t["unit"]]
                topics.append(nt)
            questions = []
            for q in kb["questions"]:
                nq = dict(q)
                nq["edition"] = "tongbian"
                nq["unit_name"] = name_of.get(q.get("unit"))
                questions.append(nq)
            topics.sort(key=lambda x: (unit_ids.index(x["unit"]), x["id"]))
            questions.sort(key=lambda x: (unit_ids.index(x["unit"]), x["id"]))

            total_t += len(topics)
            total_q += len(questions)
            print(f"  {vol}: {len(units)}单元 {len(topics)}点 {len(questions)}题")
            if check_only:
                continue

            toc = {
                "schema_version": 1,
                "generated_by": "build_history_toc.py (identity remap onto catalog units)",
                "source": {"site": "统编版（2024）目录取自 data/catalog.json；"
                                   "知识点/题目复用通用历史卷",
                           "path": vol_data.get("file"), "fetched": "2026-11-20"},
                "subject": "history", "grade": int(g), "semester": sem,
                "edition": "tongbian", "edition_label": "统编版",
                "units": units, "topics": topics, "questions": questions,
            }
            TOC_OUT.mkdir(parents=True, exist_ok=True)
            (TOC_OUT / f"{vol}.json").write_text(
                json.dumps(toc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    print(f"合计 {total_t} 知识点 / {total_q} 题，问题 {problems}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
