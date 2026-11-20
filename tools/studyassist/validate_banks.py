#!/usr/bin/env python3
"""Validate generated question banks against bank.lua's load rules."""
import json
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
DATA = PLUGIN / "data"
CAT = json.loads((DATA / "catalog.json").read_text(encoding="utf-8"))

errors = []
# 「某单元没有题」不是错误：通用知识点池比部分版本的章更粗（人教 4 个单元
# vs 苏科 21 章），细分的章里天然会有 1 个落不到知识点。界面对这种单元
# 直接跳过渲染，不影响使用，所以只提示不阻塞。
warnings = []


def check_bank(subject, edition_id, edition, grade, semester):
    info = edition["grades"][str(grade)][semester]
    unit_ids = {u["id"] for u in info["units"]}
    path = DATA / info["file"]
    if not path.exists():
        errors.append(f"{path}: missing file")
        return
    data = json.loads(path.read_text(encoding="utf-8"))
    qs = data.get("questions", [])
    if not qs:
        errors.append(f"{subject}/{edition_id}/g{grade}/{semester}: no questions")
    seen = set()
    for q in qs:
        qid = q.get("id")
        if not qid or qid in seen:
            errors.append(f"{path}: bad/duplicate id {qid}")
        seen.add(qid)
        if q.get("unit") not in unit_ids:
            errors.append(f"{path}: {qid} unknown unit {q.get('unit')}")
        if not q.get("stem") or not q.get("explain"):
            errors.append(f"{path}: {qid} missing stem/explain")
        if q.get("answer_mode") == "number":
            if q.get("answer_format") == "fraction":
                # 分数题答案按 "分子/分母" 字符串存（core/knowledge.lua 校验）
                import re as _re
                if not _re.match(r"^\d+/\d+$", str(q.get("answer"))):
                    errors.append(f"{path}: {qid} bad fraction answer {q.get('answer')!r}")
            elif not isinstance(q.get("answer"), (int, float)) or \
                    isinstance(q.get("answer"), bool):
                errors.append(f"{path}: {qid} number answer not numeric")
        else:
            opts = q.get("options")
            if not isinstance(opts, list) or len(opts) != 4 \
                    or any(not isinstance(o, str) or not o for o in opts) \
                    or len(set(opts)) != 4:
                errors.append(f"{path}: {qid} bad options")
            a = q.get("answer")
            if not isinstance(a, int) or not (1 <= a <= 4):
                errors.append(f"{path}: {qid} bad answer index")
    # 反向：每个单元至少有题
    covered = {q.get("unit") for q in qs}
    for u in info["units"]:
        if u["id"] not in covered:
            warnings.append(f"{subject}/{edition_id}/g{grade}/{semester}/{u['id']}: unit has no questions")


def main():
    for subject, sdata in CAT["subjects"].items():
        if subject == "math":
            continue  # math banks are validated elsewhere
        for eid, edition in sdata["editions"].items():
            for grade, semesters in edition["grades"].items():
                for semester in semesters:
                    check_bank(subject, eid, edition, grade, semester)
    if warnings:
        print(f"WARN: {len(warnings)} 个单元暂无知识点（界面会跳过）")
        for w in warnings[:8]:
            print("   .", w)
    if errors:
        print(f"BANK ERRORS ({len(errors)}):")
        for e in errors[:60]:
            print(" -", e)
        sys.exit(1)
    print("BANK VALIDATION OK")


if __name__ == "__main__":
    main()
