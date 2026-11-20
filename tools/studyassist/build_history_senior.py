#!/usr/bin/env python3
"""生成高中历史（统编版）的题库 / 知识点 / TOC，并注册进 catalog。

初中历史的知识点卷（data/knowledge/history/g7u.json 等）是按初中课标建的，
不能直接往上挂高中内容 —— 高中是另一套体系（纲要体 + 选择性必修专题体），
所以这里单独建 5 册：

    10 上  中外历史纲要（上）      中国史通史
    10 下  中外历史纲要（下）      世界史通史
    11 上  选择性必修1 国家制度与社会治理
    11 下  选择性必修2 经济与社会生活
    12 上  选择性必修3 文化交流与传播

教材章节、知识点、题目都在 tools/studyassist/history_senior/<册>.json 里维护，
本脚本负责：

  data/history/tongbian/gNN_{upper,lower}.json   题库（练习用）
  data/knowledge/history/gNN{u,l}.json           通用知识点卷
  data/toc/history/tongbian/gNN{u,l}.json        版本知识点卷（带 catalog 单元名）
  data/catalog.json                              history.editions.tongbian.grades 10~12

用法:
    python3 tools/studyassist/build_history_senior.py [--check]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = ROOT / "tools/studyassist/history_senior"
CATALOG = ROOT / "data/catalog.json"
GRAPH = ROOT / "data/knowledge/history_graph.json"

EDITION = "tongbian"
EDITION_LABEL = "统编版"
TEXTBOOK = "统编版（高中历史）"
ID_PREFIX = "cnh_s"

# 册 -> (年级, 学期)；顺序决定 id 编号顺序
VOLUMES = [
    ("g10u", 10, "upper"),
    ("g10l", 10, "lower"),
    ("g11u", 11, "upper"),
    ("g11l", 11, "lower"),
    ("g12u", 12, "upper"),
]

LICENSE = "CC BY-NC 4.0"
ATTRIBUTION = ("教材章节取自统编版高中历史教科书目录；知识点与题目由本项目编写，"
               "参考《普通高中历史课程标准（2017年版2020年修订）》。")


def catalog_unit_name(index: int, name: str) -> str:
    """catalog 里单元名的写法：第N单元·正文（与初中历史一致）。"""
    return f"第{index}单元·{name}"


def knowledge_unit_name(index: int, name: str) -> str:
    return f"第{index}单元 {name}"


def load_sources() -> list[dict]:
    out = []
    for key, grade, semester in VOLUMES:
        path = SRC_DIR / f"{key}.json"
        if not path.exists():
            raise SystemExit(f"缺少素材文件: {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        out.append({
            "key": key,
            "grade": grade,
            "semester": semester,
            "label": data["label"],
            "units": data["units"],
            "topics": data["topics"],
            "questions": data["questions"],
        })
    return out


def check(volumes: list[dict]) -> None:
    problems = []
    for vol in volumes:
        units = vol["units"]
        topics = vol["topics"]
        questions = vol["questions"]
        if not units:
            problems.append(f"{vol['key']}: 没有单元")
        for i, topic in enumerate(topics):
            u = topic.get("unit")
            if not isinstance(u, int) or not (1 <= u <= len(units)):
                problems.append(f"{vol['key']} topic#{i} {topic.get('name')}: unit={u} 越界")
            if not topic.get("description"):
                problems.append(f"{vol['key']} topic#{i} {topic.get('name')}: 缺 description")
            ex = topic.get("example") or []
            if len(ex) != 2:
                problems.append(f"{vol['key']} topic#{i} {topic.get('name')}: example 需 [问, 答]")
        by_topic = {}
        for j, q in enumerate(questions):
            t = q.get("topic")
            if not isinstance(t, int) or not (0 <= t < len(topics)):
                problems.append(f"{vol['key']} q#{j}: topic={t} 越界")
                continue
            by_topic[t] = by_topic.get(t, 0) + 1
            opts = q.get("options") or []
            if len(opts) != 4:
                problems.append(f"{vol['key']} q#{j} {q.get('stem','')[:12]}: 选项需 4 个")
            ans = q.get("answer")
            if not isinstance(ans, int) or not (1 <= ans <= len(opts or [1])):
                problems.append(f"{vol['key']} q#{j}: answer={ans} 越界（1 起）")
            if len(set(opts)) != len(opts):
                problems.append(f"{vol['key']} q#{j}: 选项有重复")
            if not q.get("explain"):
                problems.append(f"{vol['key']} q#{j}: 缺 explain")
        for i, topic in enumerate(topics):
            if by_topic.get(i, 0) == 0:
                problems.append(f"{vol['key']} topic#{i} {topic.get('name')}: 没有题目")
        if len(questions) < len(topics) * 2:
            problems.append(f"{vol['key']}: 题量偏少（{len(questions)} 题 / {len(topics)} 知识点）")
    if problems:
        print(f"❌ 素材校验失败 {len(problems)} 处：")
        for p in problems[:40]:
            print("  -", p)
        raise SystemExit(1)
    print("✅ 素材校验通过")


def build_volume(vol: dict, start_id: int) -> tuple[int, list[dict]]:
    """生成四份文件，返回下一个可用的知识点编号和本册的图谱节点。"""
    grade, semester, key = vol["grade"], vol["semester"], vol["key"]
    suf = "u" if semester == "upper" else "l"
    catalog_units = []
    knowledge_units = []
    for i, name in enumerate(vol["units"], start=1):
        catalog_units.append({"id": f"u{i}", "name": catalog_unit_name(i, name)})
        knowledge_units.append({"id": f"u{i}", "name": knowledge_unit_name(i, name)})

    topics, questions, bank_questions, nodes = [], [], [], []
    next_id = start_id
    for t_index, topic in enumerate(vol["topics"]):
        tid = f"{ID_PREFIX}{next_id:03d}"
        next_id += 1
        uid = f"u{topic['unit']}"
        unit_name = knowledge_units[topic["unit"] - 1]["name"]
        catalog_unit = catalog_units[topic["unit"] - 1]["name"]
        example_q, example_a = topic["example"]
        topics.append({
            "id": tid,
            "name": topic["name"],
            "domain": topic.get("domain") or vol["label"],
            "kp_type": topic.get("kp_type") or "conceptual",
            "unit": uid,
            "unit_name": catalog_unit,
            "description": topic["description"],
            "mastery_criteria": topic.get("criteria")
                or ["能说出本课的关键史实、时间与人物", "能判断与教材表述相符的史实"],
            "example": {"question": example_q, "answer": example_a},
        })
        nodes.append({
            "id": tid,
            "name": topic["name"],
            "grade": grade,
            "semester": semester,
            "unit": uid,
            "unit_name": catalog_unit,
            "domain": topic.get("domain") or vol["label"],
            "edition": EDITION,
        })
        n = 0
        for q in vol["questions"]:
            if q["topic"] != t_index:
                continue
            n += 1
            qid = f"{tid}_q{n}"
            base = {
                "topic": tid,
                "subject": "history",
                "grade": grade,
                "semester": semester,
                "edition": EDITION,
                "unit": uid,
                "unit_name": catalog_unit,
                "difficulty": q.get("d", 1),
                "stem": q["stem"],
                "explain": q["explain"],
                "answer_mode": "choice",
                "options": q["options"],
                "answer": q["answer"],
            }
            questions.append(dict({"id": qid, "type": "knowledge",
                                   "skill": topic.get("domain") or "历史"}, **base))
            bank_questions.append(dict({"id": qid, "type": "choice", "skill": "choice"}, **base))

    bank = {
        "schema_version": 1,
        "subject": "history",
        "grade": grade,
        "semester": semester,
        "textbook": TEXTBOOK,
        "questions": bank_questions,
    }
    knowledge = {
        "schema_version": 1,
        "generated_by": "tools/studyassist/build_history_senior.py",
        "source": {"textbook": vol["label"], "standard": "普通高中历史课程标准（2017年版2020年修订）"},
        "license": LICENSE,
        "attribution": ATTRIBUTION,
        "subject": "history",
        "grade": grade,
        "semester": semester,
        "units": knowledge_units,
        "topics": topics,
        "questions": questions,
    }
    toc = {
        "schema_version": 1,
        "generated_by": "build_history_senior.py",
        "source": {"path": f"history/{EDITION}/g{grade}_{semester}.json"},
        "subject": "history",
        "grade": grade,
        "semester": semester,
        "edition": EDITION,
        "edition_label": EDITION_LABEL,
        "units": catalog_units,
        "topics": topics,
        "questions": questions,
    }

    def dump(path: Path, data) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    dump(ROOT / f"data/history/{EDITION}/g{grade}_{semester}.json", bank)
    dump(ROOT / f"data/knowledge/history/g{grade}{suf}.json", knowledge)
    dump(ROOT / f"data/toc/history/{EDITION}/g{grade}{suf}.json", toc)
    print(f"  {vol['label']}（{grade} 年级{'上' if suf == 'u' else '下'}册）"
          f"{len(catalog_units)} 单元 / {len(topics)} 知识点 / {len(bank_questions)} 题")
    return next_id, nodes


def update_catalog(volumes: list[dict]) -> None:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    edition = data["subjects"]["history"]["editions"][EDITION]
    for vol in volumes:
        grade = str(vol["grade"])
        semester = vol["semester"]
        entry = edition["grades"].setdefault(grade, {})
        entry[semester] = {
            "file": f"history/{EDITION}/g{vol['grade']}_{semester}.json",
            "units": [{"id": f"u{i}", "name": catalog_unit_name(i, name)}
                      for i, name in enumerate(vol["units"], start=1)],
        }
    CATALOG.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    grades = sorted(edition["grades"], key=int)
    print(f"  catalog: history/{EDITION} 年级 {grades}")


def update_graph(volumes: list[dict], nodes: list[dict]) -> None:
    """把本册知识点节点写进图谱，并清掉不再存在的旧节点/边。

    知识点详情页走 Knowledge.topic()，它靠图谱节点定位年级/学期；
    节点缺失时会报「没有找到这个知识点」，所以必须一起维护。
    """
    data = json.loads(GRAPH.read_text(encoding="utf-8"))
    grades = {vol["grade"] for vol in volumes}
    keep = [n for n in data["nodes"]
            if not (str(n.get("id", "")).startswith(ID_PREFIX)
                    or (n.get("edition") == EDITION and n.get("grade") in grades))]
    new_ids = {n["id"] for n in nodes}
    keep = [n for n in keep if n["id"] not in new_ids]
    data["nodes"] = keep + nodes
    ids = {n["id"] for n in data["nodes"]}
    data["edges"] = [e for e in data["edges"]
                     if e.get("from") in ids and e.get("to") in ids]
    GRAPH.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"  graph: history 节点 {len(data['nodes'])}（本册新增 {len(nodes)}）")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验素材，不写文件")
    args = ap.parse_args()

    volumes = load_sources()
    check(volumes)
    total_t = sum(len(v["topics"]) for v in volumes)
    total_q = sum(len(v["questions"]) for v in volumes)
    print(f"素材合计：{len(volumes)} 册 / {total_t} 知识点 / {total_q} 题")
    if args.check:
        return
    print("生成：")
    next_id = 1
    nodes: list[dict] = []
    for vol in volumes:
        next_id, vol_nodes = build_volume(vol, next_id)
        nodes.extend(vol_nodes)
    update_catalog(volumes)
    update_graph(volumes, nodes)
    print("✅ 完成")


if __name__ == "__main__":
    main()
