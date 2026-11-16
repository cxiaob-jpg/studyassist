#!/usr/bin/env python3
"""Build junior-high (grades 7-9) StudyAssist banks from cn-math-taxonomy.

Subjects added (junior high, science/morality excluded per user request):
  chinese    统编版（延续 1-6 年级同 edition, grades 7-9）   ~756 题
  math       初中通用版（新 edition "junior", grades 7-9）  ~1300 题
  english    人教版新目标（新 edition "renjiao", 7-9）      ~1000 题
  physics    人教版（新科目, grades 8-9）                    ~360 题
  chemistry  人教版（新科目, grade 9）                       ~180 题
  biology    人教版（新科目, grades 7-8）                    ~260 题
  history    统编版（新科目, grades 7-9）                    ~530 题
  geography  人教版（新科目, grades 7-8）                    ~230 题

Also:
  - removes science/morality subjects from catalog.json
  - sets catalog top-level grades to 1..9

Usage:
  python tools/studyassist/build_junior.py --source <path-to-taxonomy-repo>
"""
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
DATA = PLUGIN / "data"

SUBJECTS = {
    "chinese": {
        "edition": "tongbian", "name": "统编版", "pat": "A",
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "2022课标初中目录",
    },
    "english": {
        "edition": "renjiao", "name": "人教版（新目标）", "pat": "A",
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "初中新目标目录",
    },
    "math": {
        "edition": "junior", "name": "初中通用版", "pat": "B",
        "fmt": "第{n}章·{title}", "recycle_fmt": "复习·{title}",
        "note": "2022课标初中目录",
    },
    "physics": {
        "edition": "renjiao", "name": "人教版", "pat": "B",
        "fmt": "第{n}章·{title}", "recycle_fmt": "复习·{title}",
        "note": "初中物理",
    },
    "chemistry": {
        "edition": "renjiao", "name": "人教版", "pat": "A",
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "九年级化学",
    },
    "biology": {
        "edition": "renjiao", "name": "人教版", "pat": "A",
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "初中生物",
    },
    "history": {
        "edition": "tongbian", "name": "统编版", "pat": "A",
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "初中历史",
    },
    "geography": {
        "edition": "renjiao", "name": "人教版", "pat": "A",
        "fmt": "第{n}单元·{title}", "recycle_fmt": "复习·{title}",
        "note": "初中地理",
    },
}

DIFF = {"basic": 1, "standard": 2, "challenge": 3}
CN_NUM = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
          "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}

# Pattern A: "七年级上册 第1单元 四季美景"
PAT_A = re.compile(r"^[七八九]年级(上册|下册)\s+第(\d+)单元\s+(.+)$")
# Pattern A prep (english starter units): "七年级上册 预备单元1 Hello!"
PAT_A_PREP = re.compile(r"^[七八九]年级(上册|下册)\s+预备单元(\d+)\s*(.*)$")
# Pattern A loose (english 待核): "七年级上册 待核"
PAT_A_LOOSE = re.compile(r"^[七八九]年级(上册|下册)\s+(待核.*)?$")
# Pattern B: "七上 第一章 有理数 1.1" / "八全 第N章 电与磁 2.2.1"
PAT_B = re.compile(r"^([七八九])(上|下|全)\s+第([一二三四五六七八九十]+)章\s+(.+?)\s*[\d./]*$")
SEM_A = {"上册": "upper", "下册": "lower"}
SEM_B = {"上": ["upper"], "下": ["lower"], "全": ["upper", "lower"]}


def cn_to_int(s):
    """Convert Chinese numerals up to 99 (十, 十一, 二十, 二十一...)."""
    if s in CN_NUM:
        return CN_NUM[s]
    if "十" in s:
        a, _, b = s.partition("十")
        return (CN_NUM.get(a, 1) * 10) + CN_NUM.get(b, 0)
    return None


def parse_chapter(subject, cfg, chapter):
    """Returns (semester_list, unit_no, title, is_loose)."""
    if cfg["pat"] == "A":
        m = PAT_A.match(chapter)
        if m:
            return [SEM_A[m.group(1)]], int(m.group(2)), m.group(3).strip(), False
        m = PAT_A_PREP.match(chapter)
        if m:
            title = (m.group(3) or "").strip()
            name = f"预备单元{m.group(2)}" + (f"·{title}" if title else "")
            return [SEM_A[m.group(1)]], 0, name, False
        m = PAT_A_LOOSE.match(chapter)
        if m:
            # Un-parsed chapters (e.g. "待核") go into one 综合 unit per semester.
            return [SEM_A[m.group(1)]], 99, None, True
        return None, None, None, None
    # Pattern B
    m = PAT_B.match(chapter)
    if m:
        uno = cn_to_int(m.group(3))
        if uno is None:
            return None, None, None, None
        title = m.group(4).strip()
        return SEM_B[m.group(2)], uno, title, False
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
        ans = str(raw["answer"]).strip()
        try:
            q["answer"] = int(ans)
        except ValueError:
            try:
                q["answer"] = float(ans)
            except ValueError:
                return None, "non-numeric answer"
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


# ------------------------- senior high (grades 10-12) -------------------------
# Senior-high books have no grade/semester of their own in the dataset; we map
# each textbook to a (grade, semester) slot in study order.
BOOK_SLOT = {
    ("math", "高一"): (10, "upper"), ("math", "高二"): (10, "lower"),
    ("math", "选必一"): (11, "upper"), ("math", "选必二"): (11, "lower"),
    ("math", "选必三"): (12, "upper"),
    ("english", "必修第一册"): (10, "upper"), ("english", "必修第二册"): (10, "lower"),
    ("english", "必修第三册"): (11, "upper"),
    ("english", "选择性必修第一册"): (11, "lower"),
    ("english", "选择性必修第二册"): (12, "upper"),
    ("english", "选择性必修第三册"): (12, "lower"),
    ("english", "选择性必修第四册"): (12, "lower"),  # merged into 高三下, b4u* ids
    ("physics", "必修一"): (10, "upper"), ("physics", "必修二"): (10, "lower"),
    ("physics", "必修三"): (11, "upper"), ("physics", "选必一"): (11, "lower"),
    ("physics", "选必二"): (12, "upper"), ("physics", "选必三"): (12, "lower"),
    ("chemistry", "必修一"): (10, "upper"), ("chemistry", "必修二"): (10, "lower"),
    ("chemistry", "选必一"): (11, "upper"), ("chemistry", "选必二"): (11, "lower"),
    ("chemistry", "选必三"): (12, "upper"),
}
# 高中数学无独立学期，数据集高一/高二即上下学期；"全"不出现。
BOOK_PREFIX = re.compile(
    r"^(必修[一二三]|选必[一二三]|必修第[一二三]册|选择性必修第[一二三四]册|高一|高二)\s+(.+)$")
SEN_BOOK = {"math": "senior", "english": "renjiao-senior"}
SENIOR_SUBJECTS = {
    "math": {"edition": "senior", "name": "人教A版", "note": "高中新教材"},
    "english": {"edition": "renjiao-senior", "name": "人教版（高中）", "note": "高中新教材"},
    "physics": {"edition": "renjiao", "name": "人教版", "note": "高中物理"},
    "chemistry": {"edition": "renjiao", "name": "人教版", "note": "高中化学"},
}
SENIOR_CH = re.compile(r"^第([一二三四五六七八九十]+)章\s+(.+?)\s*[\d./]*$")
SENIOR_UNIT = re.compile(r"^(欢迎单元|第(\d+)单元)\s*(.*)$")


def parse_senior_chapter(subject, chapter):
    """Returns (grade, sems, unit_id, unit_no, unit_name) or None.

    english 选必四 shares the 高三下 slot with 选必三; its units get b4u*
    ids and a 选必四· name prefix to avoid collisions.
    """
    m = BOOK_PREFIX.match(chapter)
    if not m:
        return None
    book, rest = m.group(1), m.group(2)
    slot = BOOK_SLOT.get((subject, book))
    if not slot:
        return None
    grade, sem = slot
    if subject == "english":
        um = SENIOR_UNIT.match(rest)
        if not um:
            return None
        if um.group(1) == "欢迎单元":
            return grade, [sem], "u0", 0, "Welcome Unit"
        n = int(um.group(2))
        title = (um.group(3) or "").strip()
        name = f"第{n}单元" + (f"·{title}" if title else "")
        if book == "选择性必修第四册":
            return grade, [sem], f"b4u{n}", 100 + n, f"选必四·{name}"
        return grade, [sem], f"u{n}", n, name
    if rest.startswith(("数学建模", "数学探究")):
        return grade, [sem], "u99", 99, rest.split()[0]
    if rest.startswith(("绪言", "引言")):
        return grade, [sem], "u0", 0, "绪言与引言"
    um = SENIOR_CH.match(rest)
    if not um:
        return None
    uno = cn_to_int(um.group(1))
    if uno is None:
        return None
    return grade, [sem], f"u{uno}", uno, f"第{uno}章·{um.group(2).strip()}"


def update_catalog_senior(subject, cfg, units, n_files):
    cat_path = DATA / "catalog.json"
    cat = json.loads(cat_path.read_text(encoding="utf-8"))
    grades = {}
    for (g, sem) in sorted(units):
        reg = units[(g, sem)]
        ordered = sorted(reg.values(), key=lambda u: u["no"])
        grades[str(g)] = grades.get(str(g), {})
        grades[str(g)][sem] = {
            "file": f"{subject}/{cfg['edition']}/g{g}_{sem}.json",
            "units": [{"id": u["id"], "name": u["name"]} for u in ordered],
        }
    full_name = cfg["name"] + "（" + cfg["note"] + "）"
    entry = cat["subjects"][subject]
    if cfg["edition"] in entry["editions"]:
        # shared edition across stages (e.g. physics renjiao 8-12): keep name
        existing = entry["editions"][cfg["edition"]]
        merged = dict(existing.get("grades") or {})
        merged.update(grades)
        entry["editions"][cfg["edition"]] = {"name": existing.get("name") or full_name,
                                             "grades": merged}
    else:
        entry["editions"][cfg["edition"]] = {"name": full_name, "grades": grades}
    if cfg["edition"] not in (entry.get("order") or []):
        entry.setdefault("order", []).append(cfg["edition"])
    cat["grades"] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    cat_path.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[{subject}/{cfg['edition']}] catalog 已更新（{n_files} 个分册文件）")


def build_senior(src):
    topics = json.loads((src / "topics.json").read_text(encoding="utf-8"))
    questions = json.loads((src / "questions.json").read_text(encoding="utf-8"))
    for t in topics:
        if "subject" not in t:
            t["subject"] = "math"
    topic_by_id = {t["id"]: t for t in topics}
    report = []
    for subject, cfg in SENIOR_SUBJECTS.items():
        nodes = [t for t in topics
                 if t["subject"] == subject and (t.get("grade") or 0) >= 10]
        units = defaultdict(dict)
        q_by_unit = defaultdict(list)
        skipped = defaultdict(int)
        for t in sorted(nodes, key=lambda x: x["id"]):
            p = parse_senior_chapter(subject, t["chapter"])
            if not p:
                skipped["unparsed-chapter"] += 1
                continue
            g, sems, uid, uno, name = p
            for sem in sems:
                reg = units[(g, sem)]
                if uid not in reg:
                    reg[uid] = {"id": uid, "no": uno, "name": name, "node_ids": []}
                reg[uid]["node_ids"].append(t["id"])
        for q in questions:
            t = topic_by_id.get(q["topicId"])
            if not t or t["subject"] != subject or (t.get("grade") or 0) < 10:
                continue
            p = parse_senior_chapter(subject, t["chapter"])
            if not p:
                skipped["q-unparsed-chapter"] += 1
                continue
            g, sems, uid, uno, _ = p
            for sem in sems:
                reg = units.get((g, sem))
                if not reg or uid not in reg:
                    skipped["q-orphan-unit"] += 1
                    continue
                conv, err = convert_question(q, t, uid)
                if not conv:
                    skipped[f"q-{err}"] += 1
                    continue
                q_by_unit[(g, sem, uid)].append(conv)
        edition_dir = DATA / subject / cfg["edition"]
        edition_dir.mkdir(parents=True, exist_ok=True)
        n_files = 0
        has_q = {(g, sem) for (g, sem, _) in q_by_unit}
        for (g, sem) in sorted(units):
            if (g, sem) not in has_q:
                continue
            reg = units[(g, sem)]
            qs = []
            for key in sorted(reg, key=lambda k: (reg[k]["no"], k)):
                qs.extend(sorted(q_by_unit.get((g, sem, key), []),
                                 key=lambda x: (x["difficulty"], x["id"])))
            if not qs:
                continue
            out = {
                "schema_version": 1, "subject": subject, "grade": g,
                "semester": sem,
                "textbook": cfg["name"] + "（" + cfg["note"] + "）",
                "questions": qs,
            }
            (edition_dir / f"g{g}_{sem}.json").write_text(
                json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
            n_files += 1
            report.append((subject, g, sem, len(reg), len(qs)))
        update_catalog_senior(subject, cfg,
                              {k: v for k, v in units.items() if k in has_q}, n_files)
        if skipped:
            print(f"[{subject}] skipped:", dict(skipped))
    print("\n=== 高中题库生成报告 ===")
    for subject, g, sem, n_units, n_q in report:
        print(f"{subject:10s} 高{'一' if g == 10 else '二' if g == 11 else '三'}"
              f"{'上' if sem == 'upper' else '下'} {n_units:2d}单元 {n_q:4d}题")
    total = sum(r[4] for r in report)
    print(f"\n合计 {len(report)} 个分册, {total} 题")


def slot_grade(subject, chapter):
    """Resolve the (grade, semester) slot for a senior chapter's book."""
    m = BOOK_PREFIX.match(chapter)
    if not m:
        return None
    slot = BOOK_SLOT.get((subject, m.group(1)))
    return slot[0] if slot else None


def update_catalog(subject, cfg, units, n_files):
    cat_path = DATA / "catalog.json"
    cat = json.loads(cat_path.read_text(encoding="utf-8"))
    grades = {}
    for (g, sem) in sorted(units):
        reg = units[(g, sem)]
        ordered = sorted(reg.values(), key=lambda u: u["no"])
        grades[str(g)] = grades.get(str(g), {})
        grades[str(g)][sem] = {
            "file": f"{subject}/{cfg['edition']}/g{g}_{sem}.json",
            "units": [{"id": u["id"], "name": u["name"]} for u in ordered],
        }
    full_name = cfg["name"] + "（" + cfg["note"] + "）"
    if subject in ("chinese", "math", "english"):
        # merge into existing subject entry, overlaying junior-high grades
        entry = cat["subjects"][subject]
        existing = entry["editions"].get(cfg["edition"])
        if existing:
            merged = dict(existing.get("grades") or {})
            merged.update(grades)
            entry["editions"][cfg["edition"]] = {"name": full_name, "grades": merged}
        else:
            entry["editions"][cfg["edition"]] = {"name": full_name, "grades": grades}
        if cfg["edition"] not in (entry.get("order") or []):
            entry.setdefault("order", []).append(cfg["edition"])
    else:
        cat["subjects"][subject] = {
            "order": [cfg["edition"]],
            "editions": {cfg["edition"]: {"name": full_name, "grades": grades}},
        }
    # drop removed subjects + refresh grade range
    for gone in ("science", "morality"):
        cat["subjects"].pop(gone, None)
    cat["grades"] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    cat_path.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[{subject}] catalog 已更新（{n_files} 个分册文件）")



    cat_path = DATA / "catalog.json"
    cat = json.loads(cat_path.read_text(encoding="utf-8"))
    grades = {}
    for (g, sem) in sorted(units):
        reg = units[(g, sem)]
        ordered = sorted(reg.values(), key=lambda u: u["no"])
        grades[str(g)] = grades.get(str(g), {})
        grades[str(g)][sem] = {
            "file": f"{subject}/{cfg['edition']}/g{g}_{sem}.json",
            "units": [{"id": u["id"], "name": u["name"]} for u in ordered],
        }
    full_name = cfg["name"] + "（" + cfg["note"] + "）"
    if subject in ("chinese", "math", "english"):
        # merge into existing subject entry, overlaying junior-high grades
        entry = cat["subjects"][subject]
        existing = entry["editions"].get(cfg["edition"])
        if existing:
            merged = dict(existing.get("grades") or {})
            merged.update(grades)
            entry["editions"][cfg["edition"]] = {"name": full_name, "grades": merged}
        else:
            entry["editions"][cfg["edition"]] = {"name": full_name, "grades": grades}
        if cfg["edition"] not in (entry.get("order") or []):
            entry.setdefault("order", []).append(cfg["edition"])
    else:
        cat["subjects"][subject] = {
            "order": [cfg["edition"]],
            "editions": {cfg["edition"]: {"name": full_name, "grades": grades}},
        }
    # drop removed subjects + refresh grade range
    for gone in ("science", "morality"):
        cat["subjects"].pop(gone, None)
    cat["grades"] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    cat_path.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[{subject}] catalog 已更新（{n_files} 个分册文件）")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    args = ap.parse_args()
    src = Path(args.source) / "data"
    topics = json.loads((src / "topics.json").read_text(encoding="utf-8"))
    questions = json.loads((src / "questions.json").read_text(encoding="utf-8"))
    for t in topics:
        if "subject" not in t:
            t["subject"] = "math"
    topic_by_id = {t["id"]: t for t in topics}

    report = []
    for subject, cfg in SUBJECTS.items():
        nodes = [t for t in topics
                 if t["subject"] == subject and 7 <= (t.get("grade") or 0) <= 9]
        units = defaultdict(dict)
        q_by_unit = defaultdict(list)
        skipped = defaultdict(int)
        for t in sorted(nodes, key=lambda x: x["id"]):
            sems, uno, title, is_loose = parse_chapter(subject, cfg, t["chapter"])
            if sems is None:
                skipped["unparsed-chapter"] += 1
                continue
            key = "u99" if is_loose else f"u{uno}"
            for sem in sems:
                reg = units[(t["grade"], sem)]
                if key not in reg:
                    if is_loose:
                        name = "综合练习"
                    else:
                        name = cfg["fmt"].format(n=uno, title=title)
                    reg[key] = {"id": key, "no": uno, "name": name, "node_ids": []}
                reg[key]["node_ids"].append(t["id"])
        for q in questions:
            t = topic_by_id.get(q["topicId"])
            if not t or t["subject"] != subject:
                continue
            g = t.get("grade") or 0
            if not (7 <= g <= 9):
                continue
            sems, uno, title, is_loose = parse_chapter(subject, cfg, t["chapter"])
            if sems is None:
                skipped["q-unparsed-chapter"] += 1
                continue
            key = "u99" if is_loose else f"u{uno}"
            for sem in sems:
                reg = units.get((g, sem))
                if not reg or key not in reg:
                    skipped["q-orphan-unit"] += 1
                    continue
                conv, err = convert_question(q, t, key)
                if not conv:
                    skipped[f"q-{err}"] += 1
                    continue
                q_by_unit[(g, sem, key)].append(conv)

        edition_dir = DATA / subject / cfg["edition"]
        edition_dir.mkdir(parents=True, exist_ok=True)
        n_files = 0
        has_q = {(g, sem) for (g, sem, _) in q_by_unit}
        for (g, sem) in sorted(units):
            if (g, sem) not in has_q:
                continue  # no questions for this volume: don't ship/catalog it
            reg = units[(g, sem)]
            qs = []
            for key in sorted(reg, key=lambda k: (reg[k]["no"], k)):
                qs.extend(sorted(q_by_unit.get((g, sem, key), []),
                                 key=lambda x: (x["difficulty"], x["id"])))
            if not qs:
                continue
            out = {
                "schema_version": 1, "subject": subject, "grade": g,
                "semester": sem,
                "textbook": cfg["name"] + "（" + cfg["note"] + "）",
                "questions": qs,
            }
            (edition_dir / f"g{g}_{sem}.json").write_text(
                json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
            n_files += 1
            report.append((subject, g, sem, len(reg), len(qs)))
        update_catalog(subject, cfg,
                       {k: v for k, v in units.items() if k in has_q}, n_files)
        if skipped:
            print(f"[{subject}] skipped:", dict(skipped))

    build_senior(src)

    print("\n=== 初中题库生成报告 ===")
    for subject, g, sem, n_units, n_q in report:
        print(f"{subject:10s} {g}年级{'上' if sem == 'upper' else '下'} "
              f"{n_units:2d}单元 {n_q:4d}题")
    total = sum(r[4] for r in report)
    print(f"\n合计 {len(report)} 个分册, {total} 题")


if __name__ == "__main__":
    sys.exit(main())
