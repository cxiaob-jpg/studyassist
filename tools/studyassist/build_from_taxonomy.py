#!/usr/bin/env python3
"""Build StudyAssist question banks from the cn-math-taxonomy dataset.

Subjects covered (primary school, grades 1-6 unless noted):
  chinese   统编版（2022课标修订目录）  1976 题
  english   人教版PEP（2022课标修订）   1100 题, grades 3-6
  science   教科版                     1076 题
  morality  统编版                      636 题

Usage:
  python tools/studyassist/build_from_taxonomy.py --source <path-to-taxonomy-repo>

Outputs:
  data/<subject>/<edition>/g<grade>_<semester>.json
  data/catalog.json  (chinese units replaced; english/science/morality added)
  data/chinese/tongbian-legacy/  (previous chinese banks moved here)
"""
import argparse
import json
import re
import shutil
import sys
from collections import defaultdict
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
DATA = PLUGIN / "data"

SUBJECTS = {
    "chinese": {
        "edition": "tongbian", "name": "统编版", "max_grade": 6,
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "2022课标修订目录，逐课覆盖",
    },
    "english": {
        "edition": "pep", "name": "人教版PEP", "max_grade": 6, "min_grade": 3,
        "fmt": "U{n}·{title}", "recycle_fmt": "复习·{title}",
        "note": "2022课标修订版，三年级起点",
    },
    "science": {
        "edition": "jiaoke", "name": "教科版", "max_grade": 6,
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "2022课标修订目录",
    },
    "morality": {
        "edition": "tongbian", "name": "统编版", "max_grade": 6,
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "2022课标修订目录",
    },
}

DIFF = {"basic": 1, "standard": 2, "challenge": 3}
CH = re.compile(r"^(\S+?)(上册|下册)\s+第(\d+)单元\s+(.+)$")
CH_LOOSE = re.compile(r"^(\S+?)(上册|下册)\s+(.+)$")
SEM = {"上册": "upper", "下册": "lower"}


def parse_chapter(subject, chapter):
    m = CH.match(chapter)
    if m:
        return SEM[m.group(2)], int(m.group(3)), m.group(4), False
    m = CH_LOOSE.match(chapter)
    if m:
        return SEM[m.group(2)], None, m.group(3), True
    return None, None, None, None


def convert_question(raw, topic, unit_id):
    qtype = raw.get("type")
    q = {
        "id": raw["id"],
        "unit": unit_id,
        "type": qtype if qtype in ("choice", "numeric") else "choice",
        "skill": "number" if qtype == "numeric" else "choice",
        "difficulty": DIFF.get(raw.get("difficulty"), 2),
        "answer_mode": "number" if qtype == "numeric" else "choice",
        "stem": raw["prompt"].strip(),
        "explain": raw["explanation"].strip(),
    }
    if qtype == "numeric":
        try:
            q["answer"] = int(str(raw["answer"]).strip())
        except ValueError:
            return None, "non-integer numeric answer"
        return q, None
    choices = raw.get("choices") or []
    if len(choices) != 4:
        return None, "choices != 4"
    options, seen = [], set()
    for c in choices:
        text = (c.get("text") or "").strip()
        if not text or text in seen:
            return None, "empty/duplicate option"
        seen.add(text)
        options.append(text)
    answer = raw.get("answer")
    key_to_idx = {"A": 1, "B": 2, "C": 3, "D": 4}
    idx = key_to_idx.get(str(answer).strip().upper())
    if not idx:
        return None, "bad answer key"
    q["options"], q["answer"] = options, idx
    return q, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="path to cn-math-taxonomy checkout containing data/")
    args = ap.parse_args()
    src = Path(args.source) / "data"
    topics = json.loads((src / "topics.json").read_text(encoding="utf-8"))
    questions = json.loads((src / "questions.json").read_text(encoding="utf-8"))
    for t in topics:
        if t.get("subject") is None:
            t["subject"] = "math"
    topic_by_id = {t["id"]: t for t in topics}

    report = []
    for subject, cfg in SUBJECTS.items():
        nodes = [t for t in topics if t["subject"] == subject
                 and t.get("grade") is not None and t["grade"] <= cfg["max_grade"]
                 and t["grade"] >= cfg.get("min_grade", 1)]
        # units[(grade, semester)][unit_key] = {no, title, name, id}
        units = defaultdict(dict)
        q_by_unit = defaultdict(list)
        skipped = defaultdict(int)
        for t in sorted(nodes, key=lambda x: x["id"]):
            sem, uno, title, is_recycle = parse_chapter(subject, t["chapter"])
            if sem is None:
                skipped["unparsed-chapter"] += 1
                continue
            key = f"ur{uno}" if is_recycle else f"u{uno}"
            reg = units[(t["grade"], sem)]
            if key not in reg:
                if is_recycle:
                    name = cfg["recycle_fmt"].format(title=title)
                else:
                    name = cfg["fmt"].format(n=uno, title=title)
                reg[key] = {"id": key, "no": uno if uno is not None else 99,
                            "name": name, "node_ids": []}
            reg[key]["node_ids"].append(t["id"])
        for q in questions:
            t = topic_by_id.get(q["topicId"])
            if not t or t["subject"] != subject:
                continue
            g = t.get("grade") or 0
            if g > cfg["max_grade"] or g < cfg.get("min_grade", 1):
                continue
            sem, uno, title, is_recycle = parse_chapter(subject, t["chapter"])
            if sem is None:
                skipped["q-unparsed-chapter"] += 1
                continue
            key = f"ur{uno}" if is_recycle else f"u{uno}"
            reg = units.get((g, sem))
            if not reg or key not in reg:
                skipped["q-orphan-unit"] += 1
                continue
            conv, err = convert_question(q, t, key)
            if not conv:
                skipped[f"q-{err}"] += 1
                continue
            q_by_unit[(g, sem, key)].append(conv)

        edition_dir = DATA / cfg_dir(subject, cfg["edition"])
        edition_dir.mkdir(parents=True, exist_ok=True)
        if subject == "chinese":
            legacy = DATA / "chinese" / "tongbian-legacy"
            if not legacy.exists():
                legacy.mkdir()
                for f in edition_dir.glob("g*_*.json"):
                    shutil.move(str(f), str(legacy / f.name))
        n_files = 0
        for (g, sem) in sorted(units):
            reg = units[(g, sem)]
            qs = []
            for key in sorted(reg, key=lambda k: (reg[k]["no"], k)):
                qs.extend(sorted(q_by_unit.get((g, sem, key), []),
                                 key=lambda x: (x["difficulty"], x["id"])))
            out = {
                "schema_version": 1, "subject": subject, "grade": g,
                "semester": sem, "textbook": cfg["name"] + "（" + cfg["note"] + "）",
                "questions": qs,
            }
            path = edition_dir / f"g{g}_{sem}.json"
            path.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
            n_files += 1
            report.append((subject, g, sem, len(reg), len(qs),
                           [reg[k]["name"] for k in sorted(reg, key=lambda k: (reg[k]["no"], k))]))
        # catalog snippet
        update_catalog(subject, cfg, units, n_files)
        if skipped:
            print(f"[{subject}] skipped:", dict(skipped))

    print("\n=== 生成报告 ===")
    for subject, g, sem, n_units, n_q, names in report:
        print(f"{subject:9s} {g}年级{'上' if sem=='upper' else '下'} "
              f"{n_units}单元 {n_q:4d}题")
    total = sum(r[4] for r in report)
    print(f"\n合计 {len(report)} 个分册, {total} 题")


def cfg_dir(subject, edition):
    return f"{subject}/{edition}"


def update_catalog(subject, cfg, units, n_files):
    cat_path = DATA / "catalog.json"
    cat = json.loads(cat_path.read_text(encoding="utf-8"))
    if subject == "chinese" and not (DATA / "catalog.json.pre-taxonomy.bak").exists():
        shutil.copy(cat_path, DATA / "catalog.json.pre-taxonomy.bak")
    grades = {}
    for (g, sem) in sorted(units):
        reg = units[(g, sem)]
        ordered = sorted(reg.values(), key=lambda u: u["no"])
        grades[str(g)] = grades.get(str(g), {})
        grades[str(g)][sem] = {
            "file": f"{cfg_dir(subject, cfg['edition'])}/g{g}_{sem}.json",
            "units": [{"id": u["id"], "name": u["name"]} for u in ordered],
        }
    entry = {"order": [cfg["edition"]],
             "editions": {cfg["edition"]: {"name": cfg["name"] + "（" + cfg["note"] + "）",
                                           "grades": grades}}}
    cat["subjects"][subject] = entry
    cat_path.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[{subject}] catalog 已更新（{n_files} 个分册文件）")


if __name__ == "__main__":
    sys.exit(main())
