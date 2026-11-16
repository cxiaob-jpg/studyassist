#!/usr/bin/env python3
"""Validate generated question banks against bank.lua's load rules."""
import json
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
DATA = PLUGIN / "data"
CAT = json.loads((DATA / "catalog.json").read_text(encoding="utf-8"))

errors = []


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
            if not isinstance(q.get("answer"), (int, float)) or \
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
            errors.append(f"{subject}/{edition_id}/g{grade}/{semester}/{u['id']}: unit has no questions")


def main():
    for subject, sdata in CAT["subjects"].items():
        if subject == "math":
            continue  # math banks are validated elsewhere
        for eid, edition in sdata["editions"].items():
            for grade, semesters in edition["grades"].items():
                for semester in semesters:
                    check_bank(subject, eid, edition, grade, semester)
    if errors:
        print(f"BANK ERRORS ({len(errors)}):")
        for e in errors[:60]:
            print(" -", e)
        sys.exit(1)
    print("BANK VALIDATION OK")


if __name__ == "__main__":
    main()
