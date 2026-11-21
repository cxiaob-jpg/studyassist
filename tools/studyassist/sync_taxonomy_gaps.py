#!/usr/bin/env python3
"""Incrementally merge upstream knowledge points missing from data/knowledge/.

build_knowledge_all.py never overwrites an existing volume file, so any knowledge
point added upstream *after* a volume was first generated is silently missing
here. This tool closes exactly those gaps:

    * topics present in the taxonomy source but absent from every volume file
    * their usable questions (same e-ink filters as build_knowledge_all.py)
    * graph nodes and prerequisite edges for those topics

Only the missing entries are appended. Existing topics, questions, unit ids and
graph entries stay byte-identical (volume files use indent=2, graphs indent=1,
matching what build_knowledge_all.py wrote), so the git diff is just the
additions. Re-running is a no-op once everything is merged.

Primary + junior high only (grade <= 9); senior volumes were retired in v1.25.0,
use --include-senior if that ever changes.

Usage:
    python3 tools/studyassist/sync_taxonomy_gaps.py --source <taxonomy checkout>
    python3 tools/studyassist/sync_taxonomy_gaps.py --source <checkout> --check
"""
import argparse
import collections
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_knowledge_all as B  # noqa: E402  (reuse the original normalisation)

PLUGIN = Path(__file__).resolve().parents[2]
KNOW = PLUGIN / "data" / "knowledge"

PREFIX_SUBJECT = {
    "cnm": "math", "cnc": "chinese", "cne": "english", "cnp": "physics",
    "cnk": "chemistry", "cnb": "biology", "cnh": "history", "cng": "geography",
    # cns (science) / cnd (morality) have no volume here yet; skip them loudly
}


def vol_path(subject, grade, semester):
    """Volume file for (subject, grade, semester)."""
    return KNOW / subject / f"g{grade}{'u' if semester == 'upper' else 'l'}.json"


def load_volumes():
    """Scan every volume file once: ids seen, and per-volume topic->unit map."""
    seen = set()
    volumes = {}
    for path in sorted(KNOW.glob("*/g*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        subject = payload.get("subject")
        key = (subject, payload["grade"], payload["semester"])
        volumes[key] = (path, payload)
        seen.update(t["id"] for t in payload["topics"])
    return seen, volumes


def unit_for_topic(payload, source_topic, subject, unit_chapters):
    """Pick the unit a new topic belongs to; append one when nothing matches."""
    chapter = source_topic.get("chapter", "")
    name = B.unit_name_for(subject, chapter)

    # 1) a unit already built from this exact chapter (math splits by section)
    for unit_id, chapters in unit_chapters.items():
        if chapters.get(chapter):
            return unit_id, False

    # 2) an existing unit with the same display name that has no topic yet
    #    (upstream dropped its topics earlier, e.g. math 6.1.1)
    used = {t["unit"] for t in payload["topics"]}
    for unit in payload["units"]:
        if unit["name"] == name and unit["id"] not in used:
            return unit["id"], False

    # 3) same display name, already occupied — join it rather than duplicate
    for unit in payload["units"]:
        if unit["name"] == name:
            return unit["id"], False

    unit_id = "u%d" % (len(payload["units"]) + 1)
    payload["units"].append({"id": unit_id, "name": name})
    return unit_id, True


def merge_volume(path, payload, subject, slot, topics, questions_by_topic, by_id):
    """Append topics + questions for one volume; returns a change summary."""
    grade, semester = slot
    unit_chapters = collections.defaultdict(collections.Counter)
    for t in payload["topics"]:
        src = by_id.get(t["id"])
        if src:
            unit_chapters[t["unit"]][src["chapter"]] += 1

    added_topics = added_questions = 0
    new_units, skipped, merged_ids = [], [], []
    for topic in topics:
        # 一个知识点至少要有一道能上墨水屏的题，否则 validate_knowledge.py 会判
        # 「topic has no questions」，界面上点进去也无题可练。与
        # build_knowledge_all.build_subject 的 q_count == 0 拦截保持一致。
        norm_qs = []
        for q in questions_by_topic.get(topic["id"], []):
            norm, _err = B.norm_question(q, topic, None, subject,
                                         B.SUBJECT_EDITION[subject])
            if norm:
                norm_qs.append(norm)
        if not norm_qs:
            skipped.append(topic["id"])
            continue

        unit_id, created = unit_for_topic(payload, topic, subject, unit_chapters)
        if created:
            new_units.append(unit_id)
        unit = next(u for u in payload["units"] if u["id"] == unit_id)

        payload["topics"].append({
            "id": topic["id"], "name": topic["name"], "domain": topic["domain"],
            "kp_type": topic.get("type", ""),
            "unit": unit["id"], "unit_name": unit["name"],
            "description": topic.get("description", ""),
            "mastery_criteria": topic.get("mastery_criteria", []),
            "example": {
                "question": (topic.get("diagnostic_question") or {}).get("question", ""),
                "answer": (topic.get("diagnostic_question") or {}).get("answer", ""),
            },
        })
        added_topics += 1
        merged_ids.append(topic["id"])

        for norm in norm_qs:
            norm["grade"] = grade
            norm["semester"] = semester
            norm["unit"] = unit["id"]
            payload["questions"].append(norm)
            added_questions += 1

    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
    return added_topics, added_questions, new_units, skipped, merged_ids


def merge_graph(subject, merged_ids, edges):
    """Append nodes for merged topics and edges that touch them.

    Only topics that actually landed in a volume get a node — a node without a
    volume topic would be a dead link in the knowledge graph. Edges are limited
    to those touching a new node so an upstream edge that both older ends already
    had (possibly pruned on purpose here) is not resurrected.
    """
    if not merged_ids:
        return 0, 0
    path = KNOW / f"{subject}_graph.json"
    graph = json.loads(path.read_text(encoding="utf-8"))
    have = {n["id"] for n in graph["nodes"]}

    merged = [t for t in merged_ids if t["id"] not in have]
    for t in merged:
        slot = B.slot_for(subject, t)[0]
        graph["nodes"].append({
            "id": t["id"], "name": t["name"],
            "grade": slot[0], "semester": slot[1],
            "unit": "u1",  # 真正的 unit id 在卷文件里；图谱只用 unit_name 展示
            "unit_name": B.unit_name_for(subject, t.get("chapter", "")),
            "domain": t["domain"],
        })
        have.add(t["id"])

    new_ids = {t["id"] for t in merged}
    existing_edges = {(e["from"], e["to"]) for e in graph["edges"]}
    added_edges = 0
    for d in edges:
        key = (d["topicId"], d["prerequisiteId"])
        if key in existing_edges:
            continue
        if not (d["topicId"] in new_ids or d["prerequisiteId"] in new_ids):
            continue
        if d["topicId"] in have and d["prerequisiteId"] in have:
            graph["edges"].append({
                "from": d["topicId"], "to": d["prerequisiteId"],
                "strength": d.get("strength", "hard"),
                "reason": d.get("reason", ""),
            })
            existing_edges.add(key)
            added_edges += 1

    path.write_text(json.dumps(graph, ensure_ascii=False, indent=1) + "\n",
                    encoding="utf-8")
    return len(merged), added_edges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="cn-math-taxonomy checkout")
    ap.add_argument("--check", action="store_true", help="report only, write nothing")
    ap.add_argument("--include-senior", action="store_true",
                    help="also merge grade >= 10 (retired in v1.25.0)")
    args = ap.parse_args()

    src = Path(args.source) / "data"
    topics_all = json.loads((src / "topics.json").read_text(encoding="utf-8"))
    questions_all = json.loads((src / "questions.json").read_text(encoding="utf-8"))
    deps_all = json.loads((src / "dependencies.json").read_text(encoding="utf-8"))

    by_id = {t["id"]: t for t in topics_all}
    questions_by_topic = collections.defaultdict(list)
    for q in questions_all:
        if B.usable(q) is None:  # 与 build_knowledge_all 一致的墨水屏过滤
            questions_by_topic[q.get("topicId")].append(q)

    seen, volumes = load_volumes()
    todo = collections.defaultdict(list)
    unmapped = collections.Counter()
    for t in topics_all:
        prefix = t["id"][:3]
        subject = PREFIX_SUBJECT.get(prefix)
        if not subject:
            unmapped[prefix] += 1
            continue
        if t["id"] in seen:
            continue
        if t.get("grade", 99) >= 10 and not args.include_senior:
            continue
        slots = B.slot_for(subject, t)
        if not slots:
            continue
        for slot in slots:
            todo[(subject, slot)].append(t)

    total_t = total_q = total_n = total_e = 0
    all_skipped = []
    merged_by_subject = collections.defaultdict(list)
    for (subject, slot), topics in sorted(todo.items()):
        volume = volumes.get((subject, slot[0], slot[1]))
        if volume is None:
            print(f"[跳过] {subject} g{slot[0]} {'上' if slot[1] == 'upper' else '下'}: "
                  f"没有对应卷文件（{len(topics)} 点）")
            continue
        path, payload = volume
        if args.check:
            usable = [t for t in topics
                      if any(B.norm_question(q, t, None, subject,
                                             B.SUBJECT_EDITION[subject])[0]
                             for q in questions_by_topic.get(t["id"], []))]
            dead = [t["id"] for t in topics if t not in usable]
            all_skipped += dead
            if usable:
                qn = sum(1 for t in usable
                         for q in questions_by_topic.get(t["id"], [])
                         if B.norm_question(q, t, None, subject,
                                            B.SUBJECT_EDITION[subject])[0])
                print(f"[待补] {path.relative_to(PLUGIN)}: {len(usable)} 点 / {qn} 题")
            if dead:
                print(f"        无可用题跳过 {len(dead)}: {', '.join(dead)}")
            total_t += len(usable)
            continue
        at, aq, new_units, skipped, merged_ids = merge_volume(
            path, payload, subject, slot, topics, questions_by_topic, by_id)
        merged_by_subject[subject].extend(by_id[i] for i in merged_ids)
        all_skipped += skipped
        total_t += at
        total_q += aq
        extra = f" 新建单元 {new_units}" if new_units else ""
        if at or skipped:
            print(f"[合并] {path.relative_to(PLUGIN)}: +{at} 点 +{aq} 题{extra}")
        if skipped:
            print(f"        无可用题跳过 {len(skipped)}: {', '.join(skipped)}")

    for subject, topics in sorted(merged_by_subject.items()):
        if args.check:
            continue
        an, ae = merge_graph(subject, topics, deps_all)
        total_n += an
        total_e += ae
        print(f"[图谱] {subject}: +{an} 节点 +{ae} 边")

    if unmapped:
        print("跳过无对应学科的条目:", dict(unmapped))
    if args.check:
        if total_t:
            print(f"\n共 {total_t} 个知识点 / {total_q} 道题待补")
            return 1
        print("\n无缺口：data/knowledge 已与源数据对齐")
        return 0
    print(f"\n合并完成：+{total_t} 点 / +{total_q} 题 / +{total_n} 节点 / +{total_e} 边")
    return 0


if __name__ == "__main__":
    sys.exit(main())
