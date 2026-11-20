#!/usr/bin/env python3
"""生成人教版之外各物理版本的 TOC 知识点卷。

原理：
- 265 个知识点 + 1063 道题是通用概念数据（来自默认卷），不分出版社。
- 各版本差异只在"教材章节划分"。本脚本用关键词打分，把知识点归属到
  目标版本对应学段的章节，题目随知识点走，产出 data/toc/physics/<ed>/gX{u,l}.json。

目录来源：/tmp/phys_toc_group{A,B,C,D}.json（dzkbw 抓取，2026-11-20）。
用法：python3 tools/studyassist/build_physics_editions.py [--check]
"""
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

sys.path.insert(0, "/tmp")
import phys_topic_rules as R

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/physics"
OUT = ROOT / "data/toc/physics"
GROUPS = [Path(f"/tmp/phys_toc_group{g}.json") for g in "ABCDEF"]

# 版本 id -> 显示名（含高中版本；人教已单独生成，不在此列）
EDITION_LABEL = {
    "bsd": "北师大版（2024）",
    "bsd_bj": "北师大版·北京版",
    "skb": "苏科版",
    "jkb": "教科版",
    "hkb": "沪科版",
    "hkb_hy": "沪科粤教版",
    "hkb_ws": "沪科版（五四制）",
    "lkb_ws": "鲁科版（五四制）",
    "lkb": "鲁科版",
    "yjb": "粤教版",
    "hkjb": "沪科教版",
}

# 高中册的标准坑位（与人教 catalog 一致）：按册顺序映射到 gX{sem}
HS_SLOTS = [(10, "upper"), (10, "lower"), (11, "upper"),
            (11, "lower"), (12, "upper"), (12, "lower")]


def kws_of(text):
    out = set()
    for _, kws in R.TOPIC_RULES:
        for kw in kws:
            if kw in text:
                out.add(kw)
    for topic, words in R.EXACT_RULES.items():
        if text.strip() in words:
            out.add(text.strip())
    return out


def topic_keys(name, unit_name):
    """知识点的区分关键词：名称优先，章节兜底。"""
    nk = kws_of(name)
    ck = kws_of(unit_name)
    return nk, ck


def score_chapter(kp, chapter):
    """知识点归属到章节的打分。chapter 可为字符串或带 name 的 dict。

    主题一致是主键（物理概念跨版本主题稳定）；关键词交集用于同主题多章消歧
    （如"电-电路基础"下"简单电路/欧姆定律/电功率"多章）。
    """
    ch_name = chapter["name"] if isinstance(chapter, dict) else chapter
    nk, ck = topic_keys(kp["name"], kp.get("unit_name", ""))
    ch_kws = kws_of(ch_name)
    ch_topic = R.primary_topic(ch_name)
    kp_topic_name = R.primary_topic(kp["name"])
    kp_topic_ch = R.primary_topic(kp.get("unit_name", ""))
    s = 0
    # 主题一致（主键）：知识点名主题 > 人教章节主题
    if kp_topic_name and kp_topic_name == ch_topic:
        s += 100
    elif kp_topic_ch and kp_topic_ch == ch_topic:
        s += 60
    else:
        # 主题族回退：不同版本章节粒度不同（如透镜并入"光的世界"）
        kp_fam = R.family_of(kp_topic_name) or R.family_of(kp_topic_ch)
        ch_fam = R.family_of(ch_topic)
        if kp_fam and kp_fam == ch_fam:
            s += 20
    # 关键词交集（消歧）
    s += len(nk & ch_kws) * 10
    s += len(ck & ch_kws) * 2
    # 知识点名直接出现在章节名（强信号）
    if kp["name"] in ch_name:
        s += 30
    return s


def load_books():
    books = []
    for g in GROUPS:
        if g.exists():
            books += json.loads(g.read_text(encoding="utf-8"))
    # 高中册按册顺序重映射到标准坑位（必修一/二/三+选必一/二/三 -> g10u/g10l/g11u/g11l/g12u/g12l）
    # 与人教 catalog 一致，避免"必修三=g10 full"与必修一(g10u)文件冲突
    from collections import OrderedDict
    hs_by_ed = OrderedDict()
    for b in books:
        if "必修第" in b["book"] or "选择性必修" in b["book"]:
            hs_by_ed.setdefault(b["edition"], []).append(b)
    for ed, hs_books in hs_by_ed.items():
        # 按册名排序：必修第一/二/三 -> 选必第一/二/三
        def order_key(bk):
            name = bk["book"]
            if "选择性必修" in name:
                base = 10
            else:
                base = 0
            for cn, num in [("一", 1), ("二", 2), ("三", 3)]:
                if f"第{cn}册" in name:
                    return base + num
            return base + 9
        hs_books.sort(key=order_key)
        for i, b in enumerate(hs_books):
            if i < len(HS_SLOTS):
                b["grade"], b["semester"] = HS_SLOTS[i]
                b["hs_slot"] = i
    return books


def base_knowledge():
    """265 知识点 + 1063 题：按学段汇总。"""
    graph = json.loads((ROOT / "data/knowledge/physics_graph.json").read_text(encoding="utf-8"))
    nodes = {n["id"]: n for n in graph["nodes"]}
    questions = defaultdict(list)
    topics = defaultdict(list)
    for f in sorted(KNOW.glob("g*.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        for t in d["topics"]:
            topics[t["id"]] = t
        for q in d["questions"]:
            questions[q["topic"]].append(q)
    return nodes, topics, questions


def assign(nodes, chapters_all):
    """把知识点分配到章节（按学段限定，不限定具体年级）。

    物理知识点跨版本的年级分布与人教不同（如人教八下"杠杆"在别版可能在九年级），
    所以只按学段（初中/高中）分桶，在整个学段的章节里找主题最匹配者。
    返回 {kp_id: (chapter_dict, global_index, score)}。
    """
    result = {}
    for kid, node in nodes.items():
        grade = node.get("grade") or 0
        stage = "junior" if grade < 10 else "senior"
        cand = chapters_all[stage]
        if not cand:
            continue
        best, best_score, best_i = None, -1, 999
        for i, ch in enumerate(cand):
            s = score_chapter(node, ch)
            if s > best_score or (s == best_score and i < best_i):
                best, best_score, best_i = ch, s, i
        result[kid] = (best, best_i, best_score)
    return result


def build_volume(ed, grade, sem, book, assigned, nodes, topics, questions, out_dir):
    """生成一个册的 TOC 卷文件。assigned: {kp_id: (chapter_dict, idx, score)}。

    book: 该册的原始抓取对象（chapters 列表）。
    知识点归属到本册章节的，写入 topics/questions；unit 用册内编号 u1..uN。
    """
    # 本册章节 -> 册内 unit id（u1..uN）
    unit_ids = {ch: f"u{i+1}" for i, ch in enumerate(book["chapters"])}
    units = [{"id": uid, "name": ch} for ch, uid in unit_ids.items()]

    # 归属到本册章节的知识点
    kp_in_book = []
    for kid, (ch, idx, score) in assigned.items():
        if ch is None:
            continue
        if ch["book"] is book:
            kp_in_book.append(kid)

    out_topics = []
    for kid in sorted(kp_in_book):
        t = dict(topics[kid])
        ch = assigned[kid][0]
        uid = unit_ids[ch["name"]]
        t["unit"] = uid
        t["unit_name"] = ch["name"]
        out_topics.append(t)

    out_questions = []
    for kid in sorted(kp_in_book):
        ch = assigned[kid][0]
        uid = unit_ids[ch["name"]]
        for q in questions.get(kid, []):
            q = dict(q)
            q["edition"] = ed
            q["unit"] = uid
            q["unit_name"] = ch["name"]
            out_questions.append(q)

    label = EDITION_LABEL[ed]
    out = {
        "schema_version": 1,
        "generated_by": "build_physics_editions.py (keyword+family chapter alignment)",
        "source": {
            "site": f"dzkbw.com {label} 教材目录（2026-11-20 抓取）；知识点/题目复用通用物理题库",
            "fetched": "2026-11-20",
        },
        "subject": "physics",
        "grade": grade,
        "semester": sem,
        "edition": ed,
        "edition_label": label,
        "units": units,
        "topics": out_topics,
        "questions": out_questions,
    }
    suffix = "l" if sem == "lower" else "u"
    dest = out_dir / f"g{grade}{suffix}.json"
    dest.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return dest, len(units), len(out_topics), len(out_questions)


def main():
    check_only = "--check" in sys.argv
    books = load_books()
    nodes, topics, questions = base_knowledge()

    print("物理多版本 TOC 生成" + ("（预检）" if check_only else ""))
    report = {}
    for ed in EDITION_LABEL:
        label = EDITION_LABEL[ed]
        ed_books = [b for b in books if b["edition"] == ed]
        # 该版本所有章（带册信息），按册顺序
        chapter_list = []
        for b in ed_books:
            for j, ch in enumerate(b["chapters"]):
                chapter_list.append({
                    "name": ch, "book": b, "grade": b["grade"],
                    "idx": j, "semester": b["semester"],
                })
        # 按学段分桶（物理知识点跨版本年级不同，只限定学段）
        chapters_all = {"junior": [], "senior": []}
        for c in chapter_list:
            stage = "junior" if c["grade"] < 10 else "senior"
            chapters_all[stage].append(c)

        # 按该版本收录的学段做归属（初中版本只处理初中，高中版本处理高中）
        assigned = {}
        stage_counts = {}
        for stage in ("junior", "senior"):
            if not chapters_all[stage]:
                continue
            if stage == "junior":
                cand = {k: v for k, v in nodes.items() if (v.get("grade") or 0) < 10}
            else:
                cand = {k: v for k, v in nodes.items() if (v.get("grade") or 0) >= 10}
            part = assign(cand, chapters_all)
            assigned.update(part)
            stage_counts[stage] = (len(part), len(cand))
        low = [(kid, v) for kid, v in assigned.items() if v[2] < 4]
        report[ed] = {"label": label, "books": len(ed_books),
                      "chapters": len(chapter_list), "assigned": len(assigned),
                      "low_confidence": len(low)}
        stages = " ".join(f"{st}:{a}/{t}" for st, (a, t) in stage_counts.items())
        print(f"  [{ed:8}] {label:18} {len(ed_books)}册 {len(chapter_list)}章 "
              f"归属 {stages} 低置信 {len(low)}")
        if low and check_only:
            for kid, (ch, i, s) in low[:8]:
                print(f"      低分: {kid} {nodes[kid]['name']} -> "
                      f"{ch['name'] if isinstance(ch,dict) else ch} (s={s})")

        if check_only:
            continue
        out_dir = OUT / ed
        out_dir.mkdir(parents=True, exist_ok=True)
        for b in ed_books:
            # 全一册 -> 同时写 gXu 和 gXl（插件按 upper/lower 读取）
            sems = ["upper", "lower"] if b["semester"] == "full" else [b["semester"]]
            for sem in sems:
                dest, nu, nt, nq = build_volume(
                    ed, b["grade"], sem, b, assigned, nodes, topics, questions, out_dir)
                print(f"      {dest.relative_to(ROOT)}: {nu}章 {nt}知识点 {nq}题")
    return report


if __name__ == "__main__":
    main()
