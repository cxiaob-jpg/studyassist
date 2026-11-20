#!/usr/bin/env python3
"""给英语三大通用版本（pep / 人教新目标 renjiao / 人教高中 renjiao-senior）
生成按各版真实目录展示的 TOC 知识点卷。

物理方法论的英语落地：
- knowledge/english/gX{u,l}.json 是通用知识点 + 题目池（题目带 topic 字段），
  且已按学段对齐：g3~g6=PEP、g7~g9=人教新目标、g10~g12=人教高中。
  英语与物理不同点：catalog 里三版每册的 units 已是真实教材目录，
  不用再抓 dzkbw，直接把知识点按「英文单元名」重挂到 catalog 单元即可。
- 译林（yilin）用独立专项题库（cne_p292~355），其 TOC 不在本脚本范围，
  由 build_yilin_gaps.py 处理缺口册。

产出 data/toc/yingyu/<edition>/gX{u,l}.json：units 用 catalog 原文，
topics 重挂 unit/unit_name，questions 随 topic 走并写回 edition。

用法：python3 tools/studyassist/build_english_toc.py [--check]
"""
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/english"
OUT = ROOT / "data/toc/yingyu"
CATALOG = ROOT / "data/catalog.json"

# 版本 id -> (显示名, 覆盖的年级)
EDITIONS = {
    "pep": ("人教版PEP", [3, 4, 5, 6]),
    "renjiao": ("人教新目标", [7, 8, 9]),
    "renjiao-senior": ("人教版高中", [10, 11, 12]),
}

# 单元名归一化时剥离的前缀（catalog 与 knowledge 两侧都做同样处理）
_PREFIXES = [
    r"^第\d+单元[·:：]?", r"^第[一二三四五六七八九十]+单元[·:：]?",
    r"^U\d+[·:：]?", r"^u\d+[·:：]?",
    r"^预备单元\d+[·:：]?", r"^欢迎单元[·:：]?",
    r"^选必[一二三四][·:：]?", r"^复习[·:：]?",
]


def core_key(name):
    """把单元名抽成可比较的核心（英文标题），忽略中文序号与标点。"""
    s = (name or "").strip()
    changed = True
    while changed:
        changed = False
        for p in _PREFIXES:
            ns = re.sub(p, "", s).strip()
            if ns != s:
                s = ns
                changed = True
    s = re.sub(r"[·:：\s!！?？,，.。'\"`“”]+", "", s).lower()
    return s


def catalog_unit_map(units):
    """core_key -> unit dict；重复 core 保留第一个。"""
    m = {}
    for u in units:
        k = core_key(u["name"])
        if k and k not in m:
            m[k] = u
    return m


def map_topic_unit(topic, cat_map, fallback_unit):
    """把知识点按 unit_name 核心名映射到 catalog 单元。返回 unit dict。"""
    k = core_key(topic.get("unit_name", ""))
    if k and k in cat_map:
        return cat_map[k]
    return fallback_unit


def build_volume(ed, grade, sem, know, cat_units, label):
    cat_map = catalog_unit_map(cat_units)
    # 兜底单元：优先「综合练习」（人教新目标 u99），否则第一个单元
    fallback = next((u for u in cat_units if "综合" in u["name"]), cat_units[0])

    units = [{"id": u["id"], "name": u["name"]} for u in cat_units]
    unit_by_id = {u["id"]: u for u in cat_units}

    topics = []
    unmatched = []
    assign = {}  # topic id -> (unit id, unit name)
    for t in know["topics"]:
        u = map_topic_unit(t, cat_map, fallback)
        if core_key(t.get("unit_name", "")) not in cat_map:
            unmatched.append((t["id"], t.get("unit_name", "")))
        assign[t["id"]] = (u["id"], u["name"])
        topics.append({
            "id": t["id"], "name": t["name"],
            "domain": t.get("domain"), "kp_type": t.get("kp_type"),
            "unit": u["id"], "unit_name": u["name"],
            "description": t.get("description"),
            "mastery_criteria": t.get("mastery_criteria"),
            "example": t.get("example"),
        })

    questions = []
    skipped = 0
    for q in know["questions"]:
        tid = q.get("topic")
        if tid not in assign:
            skipped += 1
            continue
        uid, uname = assign[tid]
        nq = dict(q)
        nq["edition"] = ed
        nq["unit"] = uid
        nq["unit_name"] = uname
        questions.append(nq)

    data = {
        "schema_version": 1,
        "generated_by": "build_english_toc.py (catalog unit re-anchor)",
        "source": {
            "site": f"catalog.json {label} 真实单元目录；知识点/题目复用 knowledge/english 通用池",
            "units_from": "catalog.json",
        },
        "subject": "english",
        "grade": grade,
        "semester": sem,
        "edition": ed,
        "edition_label": label,
        "units": units,
        "topics": topics,
        "questions": questions,
    }
    return data, unmatched, skipped


def main():
    check_only = "--check" in sys.argv
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    eds = cat["subjects"]["english"]["editions"]
    print("英语三版 TOC 重挂" + ("（预检）" if check_only else ""))

    total_vols = total_topics = total_q = 0
    all_unmatched = 0
    for ed, (label, grades) in EDITIONS.items():
        for grade in grades:
            for sem in ("upper", "lower"):
                node = eds[ed]["grades"].get(str(grade), {}).get(sem)
                if not node:
                    continue
                vol = f"g{grade}{'u' if sem == 'upper' else 'l'}"
                kp = KNOW / f"{vol}.json"
                if not kp.exists():
                    print(f"  WARN {ed} {vol}: 缺通用知识点卷 {kp.name}")
                    continue
                know = json.loads(kp.read_text(encoding="utf-8"))
                data, unmatched, skipped = build_volume(
                    ed, grade, sem, know, node["units"], label)
                uniq = len(set(u[0] for u in unmatched))
                all_unmatched += uniq
                total_vols += 1
                total_topics += len(data["topics"])
                total_q += len(data["questions"])
                print(f"  {ed:16} {vol}: {len(data['units'])}单元 "
                      f"{len(data['topics'])}知识点 {len(data['questions'])}题 "
                      f"未匹配{uniq} 跳过{skipped}")
                if check_only:
                    continue
                out_dir = OUT / ed
                out_dir.mkdir(parents=True, exist_ok=True)
                (out_dir / f"{vol}.json").write_text(
                    json.dumps(data, ensure_ascii=False, indent=1) + "\n",
                    encoding="utf-8")

    print(f"合计 {total_vols} 卷 / {total_topics} 知识点 / {total_q} 题，"
          f"未匹配知识点(去重) {all_unmatched}")


if __name__ == "__main__":
    main()
