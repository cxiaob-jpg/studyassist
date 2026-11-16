#!/usr/bin/env python3
"""Build knowledge-point volumes + prerequisite graphs for all subjects.

Extends tools/studyassist/sync_taxonomy.py (which is primary-school math/chinese
only) to every subject and grade in cn-math-taxonomy:

    chinese   1-9        math      1-12      english  3-12
    physics   8-12       chemistry 9-12      biology  7-8
    history   7-9        geography 7-8

Output (same schema as sync_taxonomy.py, so Knowledge.load just works):
    data/knowledge/<subject>/g{grade}{u,l}.json
    data/knowledge/<subject>_graph.json

Existing volume files are never overwritten (primary-school chinese/math stay
exactly as synced before); graphs are rebuilt as a superset of every topic.

Usage:
  python tools/studyassist/build_knowledge_all.py --source <taxonomy checkout>
"""
import argparse
import collections
import json
import re
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
OUT = PLUGIN / "data" / "knowledge"

LICENSE = "CC BY-NC 4.0"
ATTRIBUTION = ("Data adapted from cn-math-taxonomy "
               "(https://github.com/xiaoyang111222/cn-math-taxonomy), "
               "licensed CC BY-NC 4.0.")
GENERATED_BY = "tools/studyassist/build_knowledge_all.py"

SUBJECTS = ("chinese", "math", "english", "physics", "chemistry",
            "biology", "history", "geography")
SUBJECT_EDITION = {
    "chinese": "tongbian", "math": "renjiao", "english": "pep",
    "physics": "renjiao", "chemistry": "renjiao", "biology": "renjiao",
    "history": "tongbian", "geography": "renjiao",
}
SEM = {"上": "upper", "下": "lower"}
DIFF = {"basic": 1, "standard": 2, "challenge": 3, "advanced": 3}
INT_RE = re.compile(r"^\d+$")
DEC_RE = re.compile(r"^\d+\.\d+$")
FRAC_RE = re.compile(r"^(\d+)/(\d+)$")

ELEM_PREFIX = re.compile(r"^[一二三四五六七八九]年级[上下]册\s*")
JUNIOR_MATH_PREFIX = re.compile(r"^[七八九][上下全]\s*")
SECTION_TAIL = re.compile(r"\s+\d+(?:\.\d+)*(?:/\d+(?:\.\d+)*)?$")
SENIOR_PREFIX = re.compile(
    r"^(必修[一二三]|选必[一二三]|必修第[一二三]册|选择性必修第[一二三四]册|高一|高二)\s+")

# Senior books → (grade, semester) slot, mirroring build_junior.py.
BOOK_SLOT = {
    ("math", "高一"): (10, "upper"), ("math", "高二"): (10, "lower"),
    ("math", "选必一"): (11, "upper"), ("math", "选必二"): (11, "lower"),
    ("math", "选必三"): (12, "upper"),
    ("english", "必修第一册"): (10, "upper"), ("english", "必修第二册"): (10, "lower"),
    ("english", "必修第三册"): (11, "upper"),
    ("english", "选择性必修第一册"): (11, "lower"),
    ("english", "选择性必修第二册"): (12, "upper"),
    ("english", "选择性必修第三册"): (12, "lower"),
    ("english", "选择性必修第四册"): (12, "lower"),
    ("physics", "必修一"): (10, "upper"), ("physics", "必修二"): (10, "lower"),
    ("physics", "必修三"): (11, "upper"), ("physics", "选必一"): (11, "lower"),
    ("physics", "选必二"): (12, "upper"), ("physics", "选必三"): (12, "lower"),
    ("chemistry", "必修一"): (10, "upper"), ("chemistry", "必修二"): (10, "lower"),
    ("chemistry", "选必一"): (11, "upper"), ("chemistry", "选必二"): (11, "lower"),
    ("chemistry", "选必三"): (12, "upper"),
}


def usable(q):
    """Same e-ink exclusions as sync_taxonomy.py; returns reason or None."""
    if q.get("figure") or any(c.get("figure") for c in q.get("choices", [])):
        return "figure"
    if q.get("type") == "numeric":
        ans = str(q.get("answer", ""))
        if "，" in ans or "," in ans:
            return "multi-answer"
        if ans.startswith("-"):
            return "negative"
        if not (INT_RE.match(ans) or DEC_RE.match(ans) or FRAC_RE.match(ans)):
            return "bad-number"
    if q.get("type") not in ("choice", "numeric"):
        return "bad-type"
    return None


def norm_question(q, topic, unit_id, subject, edition):
    out = {
        "id": q["id"], "topic": q["topicId"], "subject": subject,
        "grade": topic["grade"], "semester": SEM.get(topic["semester"], "upper"),
        "edition": edition, "unit": unit_id, "unit_name": topic["name"],
        "type": "knowledge", "skill": topic["domain"],
        "difficulty": DIFF.get(q.get("difficulty"), 2),
        "stem": q.get("prompt", "").strip(),
        "explain": q.get("explanation", "").strip(),
    }
    if q["type"] == "choice":
        choices = q.get("choices") or []
        keys = [c.get("key") for c in choices]
        if not 3 <= len(choices) <= 4 or keys != list("ABCD"[:len(choices)]):
            return None, "bad-choices"
        texts = [(c.get("text") or "").strip() for c in choices]
        if any(not t for t in texts) or len(set(texts)) != len(texts):
            return None, "bad-options"
        if q.get("answer") not in keys:
            return None, "bad-answer"
        out["answer_mode"] = "choice"
        out["options"] = texts
        out["answer"] = keys.index(q["answer"]) + 1
    else:
        ans = str(q.get("answer", "")).strip()
        out["answer_mode"] = "number"
        if INT_RE.match(ans):
            out["answer_format"] = "integer"
            out["answer"] = int(ans)
        elif DEC_RE.match(ans):
            out["answer_format"] = "decimal"
            out["answer"] = float(ans)
        elif FRAC_RE.match(ans):
            n, d = FRAC_RE.match(ans).groups()
            if int(d) == 0:
                return None, "zero-denominator"
            # Store as reduced-free string; Knowledge.judge parses a/b.
            out["answer_format"] = "fraction"
            out["answer"] = f"{n}/{d}"
        else:
            return None, "bad-number"
    return out, None


def unit_name_for(subject, chapter):
    """Human unit name: drop the grade/book prefix and trailing 1.2 markers."""
    name = ELEM_PREFIX.sub("", chapter)
    name = SENIOR_PREFIX.sub("", name)
    name = JUNIOR_MATH_PREFIX.sub("", name)
    name = SECTION_TAIL.sub("", name)
    return name or chapter


def slot_for(subject, topic):
    """List of (grade, semester) slots; 全一册 books land in both semesters."""
    g = topic.get("grade")
    if not isinstance(g, int):
        return []
    if g <= 9:
        raw = topic.get("semester")
        if raw == "全":
            return [(g, "upper"), (g, "lower")]
        sem = SEM.get(raw)
        return [(g, sem)] if sem else []
    m = SENIOR_PREFIX.match(topic.get("chapter", ""))
    if not m:
        return []
    slot = BOOK_SLOT.get((subject, m.group(1)))
    return [slot] if slot else []


def build_subject(src, subject):
    topics_all = json.loads((src / "topics.json").read_text(encoding="utf-8"))
    for t in topics_all:
        if "subject" not in t:
            t["subject"] = "math"
    questions_all = json.loads((src / "questions.json").read_text(encoding="utf-8"))
    deps_all = json.loads((src / "dependencies.json").read_text(encoding="utf-8"))

    topics = []
    skipped_topic = collections.Counter()
    for t in topics_all:
        if t["subject"] != subject:
            continue
        slots = slot_for(subject, t)
        if not slots:
            skipped_topic["no-slot"] += 1
            continue
        t["_slots"] = slots
        topics.append(t)
    by_id = {t["id"]: t for t in topics}

    edition = SUBJECT_EDITION[subject]
    kept, skipped_q = [], collections.Counter()
    for q in questions_all:
        t = by_id.get(q.get("topicId"))
        if not t:
            continue
        reason = usable(q)
        if reason:
            skipped_q[reason] += 1
            continue
        norm, err = norm_question(q, t, None, subject, edition)
        if not norm:
            skipped_q[err] += 1
            continue
        kept.append(norm)

    # Volume/unit assembly (unit = chapter, preserved order of appearance).
    volumes = collections.OrderedDict()
    for t in topics:
        chapter = t.get("chapter", "")
        for slot in t["_slots"]:
            vol = volumes.setdefault(slot,
                                     {"units": collections.OrderedDict(), "topics": []})
            if chapter not in vol["units"]:
                vol["units"][chapter] = {
                    "id": "u%d" % (len(vol["units"]) + 1),
                    "name": unit_name_for(subject, chapter),
                }
            vol["topics"].append(t)

    # Attach unit ids to questions (one copy per volume the topic lives in).
    q_by_vol = collections.defaultdict(list)
    q_count = collections.Counter()
    for q in kept:
        t = by_id[q["topic"]]
        for slot in t["_slots"]:
            g, sem = slot
            unit_id = volumes[slot]["units"][t["chapter"]]["id"]
            copy = dict(q)
            copy["unit"] = unit_id
            copy["grade"] = g
            copy["semester"] = sem
            q_by_vol[slot].append(copy)
        q_count[q["topic"]] += 1

    meta = {
        "schema_version": 1, "generated_by": GENERATED_BY,
        "source": {"repo": "cn-math-taxonomy", "commit": "unknown"},
        "license": LICENSE, "attribution": ATTRIBUTION,
    }
    written, skipped_files = [], []
    for (g, sem), vol in sorted(volumes.items()):
        suffix = "u" if sem == "upper" else "l"
        path = OUT / subject / f"g{g}{suffix}.json"
        vol_topics = []
        for t in vol["topics"]:
            if q_count[t["id"]] == 0:
                continue  # no usable question → skip this knowledge point
            unit = vol["units"][t["chapter"]]
            vol_topics.append({
                "id": t["id"], "name": t["name"], "domain": t["domain"],
                "kp_type": t.get("type", ""),
                "unit": unit["id"], "unit_name": unit["name"],
                "description": t.get("description", ""),
                "mastery_criteria": t.get("mastery_criteria", []),
                "example": {
                    "question": (t.get("diagnostic_question") or {}).get("question", ""),
                    "answer": (t.get("diagnostic_question") or {}).get("answer", ""),
                },
            })
        if not vol_topics:
            continue
        if path.exists():
            skipped_files.append(str(path.relative_to(PLUGIN)))
            continue
        payload = dict(meta)
        payload.update({
            "subject": subject, "grade": g, "semester": sem,
            "units": list(vol["units"].values()),
            "topics": vol_topics,
            "questions": q_by_vol[(g, sem)],
        })
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
        written.append(f"{subject}/g{g}{suffix}")

    # Graph: every topic that has at least one usable question, for the subject.
    node_ids = {t["id"] for t in topics if q_count[t["id"]] > 0}
    nodes = [{
        "id": t["id"], "name": t["name"],
        "grade": t["_slots"][0][0], "semester": t["_slots"][0][1],
        "unit": "u1", "unit_name": t["name"], "domain": t["domain"],
    } for t in topics if t["id"] in node_ids]
    # Re-derive unit ids per volume for the nodes.
    node_units = {}
    for slot, vol in volumes.items():
        for chapter, unit in vol["units"].items():
            node_units[(slot[0], slot[1], chapter)] = unit["id"]
    for node in nodes:
        t = by_id[node["id"]]
        slot = t["_slots"][0]
        node["unit"] = node_units.get((slot[0], slot[1], t["chapter"]), "u1")
        node["unit_name"] = unit_name_for(subject, t.get("chapter", ""))
    edges = [{"from": d["topicId"], "to": d["prerequisiteId"],
              "strength": d.get("strength", "hard"), "reason": d.get("reason", "")}
             for d in deps_all
             if d["topicId"] in node_ids and d["prerequisiteId"] in node_ids
             and d["topicId"] in by_id and d["prerequisiteId"] in by_id]
    graph = dict(meta)
    graph.update({"subject": subject, "nodes": nodes, "edges": edges})
    (OUT / f"{subject}_graph.json").write_text(
        json.dumps(graph, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"[{subject}] 新增{len(written)}册 节点{len(nodes)} 边{len(edges)} "
          f"保留已有{len(skipped_files)}册 跳过题{dict(skipped_q)} 跳过知识点{dict(skipped_topic)}")
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--subject", default="all")
    args = ap.parse_args()
    src = Path(args.source) / "data"
    subjects = SUBJECTS if args.subject == "all" else (args.subject,)
    total = 0
    for subject in subjects:
        total += len(build_subject(src, subject))
    print(f"\n共生成 {total} 个知识点分册")


if __name__ == "__main__":
    sys.exit(main())
