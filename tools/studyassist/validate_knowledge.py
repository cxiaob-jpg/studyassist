#!/usr/bin/env python3
"""Validate the generated knowledge graphs and banks under data/knowledge/.

Checks schema fields, question validity (3-4 unique options, valid answers,
non-negative numeric answers), topic references, graph acyclicity, at least one
question per topic, and volume/graph consistency.  Standard library only.

版本专属知识点（data/toc/<学科>/<版本>/gXu.json）只挂在该版本卷里、不进通用池，
所以要额外扫一遍版本卷，否则「译林英语四上」「苏教版2024 四上」「统编语文四上」
这些节点会被误判成「图谱有节点、卷里没内容」。
"""

import collections
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "data", "knowledge")
TOC = os.path.join(ROOT, "data", "toc")
SUBJECTS = ("math", "chinese", "english", "physics", "chemistry",
            "biology", "history", "geography")
# data/toc 的目录名沿用抓取时的学科键（yuwen/shuxue/yingyu），内部学科名不同。
TOC_SUBJECT = {"chinese": "yuwen", "math": "shuxue", "english": "yingyu"}
FRACTION_RE = re.compile(r"^(\d+)/(\d+)$")
VOLUME_RE = re.compile(r"^g(\d+)([ul])\.json$")
STATUSES = {"learning", "mastered", "weak"}

errors = []


def err(msg):
    errors.append(msg)


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def check_header(data, label):
    for key in ("schema_version", "generated_by", "source", "license", "attribution"):
        if key not in data:
            err("%s: missing header field %s" % (label, key))
    if data.get("license") != "CC BY-NC 4.0":
        err("%s: unexpected license %r" % (label, data.get("license")))


def check_graph(subject):
    path = os.path.join(DATA, "%s_graph.json" % subject)
    graph = load(path)
    check_header(graph, path)
    nodes = graph.get("nodes", [])
    ids = [n["id"] for n in nodes]
    if len(set(ids)) != len(ids):
        err("%s: duplicate node ids" % path)
    idset = set(ids)
    for n in nodes:
        if not 1 <= n.get("grade", 0) <= 12:
            err("%s: node %s bad grade" % (path, n["id"]))
        if n.get("semester") not in ("upper", "lower"):
            err("%s: node %s bad semester" % (path, n["id"]))
        for key in ("name", "unit", "unit_name", "domain"):
            if not n.get(key):
                err("%s: node %s missing %s" % (path, n["id"], key))
    adj = collections.defaultdict(list)
    indeg = collections.Counter({i: 0 for i in ids})
    seen_edges = set()
    for e in graph.get("edges", []):
        a, b = e.get("from"), e.get("to")
        if a not in idset or b not in idset:
            err("%s: edge references unknown node %s->%s" % (path, a, b))
            continue
        if (a, b) in seen_edges:
            err("%s: duplicate edge %s->%s" % (path, a, b))
        seen_edges.add((a, b))
        if e.get("strength") not in ("hard", "soft"):
            err("%s: edge %s->%s bad strength" % (path, a, b))
        adj[a].append(b)
        indeg[b] += 1
    # Kahn topological sort: the prerequisite graph must be a DAG.
    queue = [i for i in ids if indeg[i] == 0]
    visited = 0
    while queue:
        cur = queue.pop()
        visited += 1
        for nxt in adj[cur]:
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                queue.append(nxt)
    if visited != len(ids):
        err("%s: prerequisite graph has a cycle" % path)
    return {n["id"]: n for n in nodes}


def check_question(q, label, topic_ids):
    qid = q.get("id", "?")
    for key in ("id", "topic", "subject", "unit", "unit_name", "skill", "stem", "explain"):
        if not q.get(key):
            err("%s: question %s missing %s" % (label, qid, key))
    if q.get("topic") not in topic_ids:
        err("%s: question %s references unknown topic" % (label, qid))
    if q.get("difficulty") not in (1, 2, 3):
        err("%s: question %s bad difficulty" % (label, qid))
    mode = q.get("answer_mode")
    if mode == "choice":
        options = q.get("options") or []
        if not 3 <= len(options) <= 4:
            err("%s: question %s needs 3-4 options" % (label, qid))
        if any(not isinstance(o, str) or not o for o in options):
            err("%s: question %s has empty option" % (label, qid))
        if len(set(options)) != len(options):
            err("%s: question %s has duplicate options" % (label, qid))
        ans = q.get("answer")
        if not isinstance(ans, int) or not 1 <= ans <= len(options):
            err("%s: question %s bad choice answer" % (label, qid))
    elif mode == "number":
        fmt = q.get("answer_format")
        ans = q.get("answer")
        if fmt in ("integer", "decimal"):
            if not isinstance(ans, (int, float)) or isinstance(ans, bool) or ans < 0:
                err("%s: question %s bad numeric answer" % (label, qid))
        elif fmt == "fraction":
            m = FRACTION_RE.match(ans) if isinstance(ans, str) else None
            if not m or int(m.group(2)) == 0:
                err("%s: question %s bad fraction answer" % (label, qid))
        else:
            err("%s: question %s bad answer_format %r" % (label, qid, fmt))
    else:
        err("%s: question %s bad answer_mode %r" % (label, qid, mode))


def scan_toc_volumes(subject, nodes, seen_topics):
    """登记只挂在教材版本卷里的知识点，返回 {topic_id: 该版本卷里的题数}。

    版本专属知识点（译林英语、苏教版2024 数学、统编语文六上等）不进 data/knowledge
    通用池，只出现在 data/toc/<版本>/gXu.json 里。版本卷会按自己的目录把知识点重挂
    到别的单元，所以这里只登记 id 与题数，不比对 unit。
    """
    counts = collections.Counter()
    base = os.path.join(TOC, TOC_SUBJECT.get(subject, subject))
    if not os.path.isdir(base):
        return counts
    for edition in sorted(os.listdir(base)):
        edir = os.path.join(base, edition)
        if not os.path.isdir(edir):
            continue
        for filename in sorted(os.listdir(edir)):
            m = VOLUME_RE.match(filename)
            if not m:
                continue
            grade = int(m.group(1))
            semester = "upper" if m.group(2) == "u" else "lower"
            path = os.path.join(edir, filename)
            data = load(path)
            for t in data.get("topics", []):
                tid = t.get("id")
                if not tid:
                    continue
                if tid not in nodes:
                    err("%s: topic %s missing from graph" % (path, tid))
                    continue
                seen_topics.setdefault(tid, (grade, semester))
            for q in data.get("questions", []):
                tid = q.get("topic")
                if tid in nodes:
                    counts[tid] += 1
    return counts


def check_subject(subject):
    nodes = check_graph(subject)
    folders = sorted(f for f in os.listdir(os.path.join(DATA, subject))
                     if VOLUME_RE.match(f)) if os.path.isdir(os.path.join(DATA, subject)) else []
    seen_topics = {}
    seen_questions = set()
    question_count = collections.Counter()
    for filename in folders:
        m = VOLUME_RE.match(filename)
        grade = int(m.group(1))
        semester = "upper" if m.group(2) == "u" else "lower"
        rel = "%s/%s" % (subject, filename)
        path = os.path.join(DATA, rel)
        data = load(path)
        check_header(data, path)
        if data.get("subject") != subject or data.get("grade") != grade or data.get("semester") != semester:
            err("%s: header subject/grade/semester mismatch" % path)
        units = {u["id"]: u for u in data.get("units", [])}
        if list(units) != ["u%d" % i for i in range(1, len(units) + 1)]:
            err("%s: unit ids not sequential" % path)
        topic_ids = set()
        for t in data.get("topics", []):
            tid = t["id"]
            # 全一册 books legitimately appear in both semesters of one grade.
            prev = seen_topics.get(tid)
            if prev is not None and prev[0] != grade:
                err("%s: topic %s appears in two grades" % (path, tid))
            seen_topics[tid] = (grade, semester)
            topic_ids.add(tid)
            node = nodes.get(tid)
            if node is None:
                err("%s: topic %s missing from graph" % (path, tid))
            elif node["grade"] != grade or t.get("unit") != node["unit"]:
                err("%s: topic %s inconsistent with graph node" % (path, tid))
            if t.get("unit") not in units:
                err("%s: topic %s references unknown unit" % (path, tid))
            for key in ("name", "domain", "description"):
                if not t.get(key):
                    err("%s: topic %s missing %s" % (path, tid, key))
            if not t.get("mastery_criteria"):
                err("%s: topic %s missing mastery_criteria" % (path, tid))
            if not (t.get("example") or {}).get("question"):
                err("%s: topic %s missing example question" % (path, tid))
        vol_qids = set()
        for q in data.get("questions", []):
            if q["id"] in vol_qids:
                err("%s: duplicate question id %s in volume" % (path, q["id"]))
            vol_qids.add(q["id"])
            seen_questions.add(q["id"])
            if q.get("topic") not in topic_ids:
                err("%s: question %s topic not in this volume" % (path, q["id"]))
            check_question(q, path, topic_ids)
            question_count[q.get("topic")] += 1
    toc_counts = scan_toc_volumes(subject, nodes, seen_topics)
    for tid in nodes:
        if tid not in seen_topics:
            err("%s: graph node %s has no volume topic" % (subject, tid))
        if question_count[tid] == 0 and toc_counts[tid] == 0:
            err("%s: topic %s has no questions" % (subject, tid))
    print("[%s] nodes=%d topics=%d questions=%d" % (subject, len(nodes), len(seen_topics), len(seen_questions)))


def main():
    for subject in SUBJECTS:
        check_subject(subject)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print("FAILED: %d error(s)" % len(errors), file=sys.stderr)
        sys.exit(1)
    print("knowledge validation OK")


if __name__ == "__main__":
    main()
