#!/usr/bin/env python3
"""化学多版本 TOC 与题库生成（按物理方法）。

与物理完全同构的做法：
- knowledge/chemistry/gX{u,l}.json 是课标通用知识点 + 题目池（按人教目录组织）。
- **按学段统一分配**：初中（9 年级）把所有版本的章合起来做候选池；
  同理。因为不同版本把"溶液""金属"等主题放在不同册（如鲁教把溶液放九上，
  人教放九下），按册各自映射必然错位。
- 打分：同章名 1000；同年级 +60（必修/选必进程跨版本稳定）；强关键词 100；
  概念族 20；二元组 2。
- 章节来源：/tmp/chemistry_toc.json（dzkbw 手机版官方目录，2026-11-20 抓取）。

产出：
- data/toc/chemistry/<ed>/gX{u,l}.json（units + topics + questions）
- data/chemistry/<ed>/gX_{upper,lower}.json（题库，新版本；renjiao 已有不覆盖）
- catalog.json 注册新版本 units/file

用法：python3 tools/studyassist/build_chemistry_toc.py [--check]
"""
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/chemistry"
TOC_OUT = ROOT / "data/toc/chemistry"
BANK_OUT = ROOT / "data/chemistry"
CATALOG = ROOT / "data/catalog.json"
BOOKS = Path("/tmp/chemistry_toc.json")

EDITION_LABEL = {
    "renjiao": "人教版",
    "ljb": "鲁教版",
    "hjb": "沪教版",
    "kyyb": "科粤版",
    "sjb": "苏教版",
    "lkb": "鲁科版",
}

FAMILIES = [
    ("basics", ["物质的分类", "物质及其变化", "分散系", "胶体", "离子反应",
                "氧化还原", "物质的量", "计量", "化学计量", "研究物质的基本方法",
                "物质的性质与转化", "元素与物质世界", "认识化学科学"]),
    ("structure", ["物质的构成", "微观粒子", "分子", "原子", "元素", "离子",
                   "化学式", "化合价", "相对原子质量", "核外电子", "原子结构",
                   "元素周期", "微粒", "物质构成的奥秘", "认识物质的构成",
                   "组成物质的化学元素", "物质组成的表示", "元素与物质"]),
    ("air", ["空气", "氧气", "燃烧", "灭火", "燃料", "能源", "碳达峰", "碳中和",
             "化石燃料", "我们周围的空气", "空气和氧气", "空气与水资源",
             "合理利用与开发", "控制燃烧"]),
    ("water", ["水", "溶液", "溶解", "溶质", "溶剂", "浓度", "质量分数", "结晶",
               "乳化", "净化", "自然界的水", "探秘水世界", "水资源", "溶解现象",
               "溶解度"]),
    ("reaction", ["化学方程式", "质量守恒", "化学反应", "反应类型", "化合反应",
                  "分解反应", "置换反应", "复分解", "催化剂", "反应速率",
                  "氧化还原", "定量研究", "认识化学反应", "化学反应的定量关系"]),
    ("nonmetal", ["硫", "氮", "硅", "氯", "无机非金属", "非金属", "卤素",
                  "硫与环境保护", "氮与社会", "海水中的重要元素", "性质与转化"]),
    ("metal", ["金属", "合金", "冶炼", "锈蚀", "金属材料", "金属资源",
               "金属活动性", "铁", "铝", "钠", "镁", "铜"]),
    ("acidbase", ["酸", "碱", "盐", "中和", "pH", "酸碱", "指示剂", "碳酸盐",
                  "肥料", "常见的酸", "溶液的酸碱性"]),
    ("carbon", ["碳", "二氧化碳", "一氧化碳", "碳酸", "碳循环", "碳和碳的氧化物",
                "碳单质", "控制燃烧", "碳中和", "碳达峰"]),
    ("organic", ["有机", "烃", "烷", "烯", "炔", "苯", "醇", "醛", "酮", "羧酸",
                 "酯", "糖", "油脂", "蛋白质", "高分子", "聚合物", "同分异构",
                 "官能团", "有机化合物", "合成高分子", "生命活动的物质基础"]),
    ("bond", ["化学键", "晶体", "晶胞", "分子间作用力", "氢键", "杂化", "配合物",
              "空间结构", "电离能", "电负性", "原子轨道", "微粒间", "聚集状态",
              "物质结构", "结构与性质", "物质结构研究"]),
    ("energy", ["能量", "热效应", "焓", "熵", "电池", "原电池", "电解", "电化学",
                "能量转化", "化学反应与电能", "电能的转化"]),
    ("equilibrium", ["速率", "平衡", "转化率", "平衡常数", "电离平衡", "水解",
                     "沉淀溶解", "方向与限度", "水溶液中的离子", "离子反应",
                     "电离", "溶度积"]),
    ("experiment", ["实验", "探究", "检验", "制备", "分离", "提纯", "仪器", "操作",
                    "研究物质的基本方法", "化学实验", "科学探究"]),
    ("society", ["健康", "环境", "可持续发展", "化学与社会", "化学与健康",
                 "社会与发展", "环境保护", "社会可持续发展", "新型材料",
                 "化学与材料", "化学与能源"]),
]

STRONG = ["化学方程式", "质量守恒", "氧化还原", "离子反应", "元素周期", "化学键",
          "晶体", "晶胞", "杂化", "配合物", "电离能", "电负性", "平衡常数",
          "沉淀溶解", "盐类水解", "原电池", "电解", "同分异构", "官能团",
          "二氧化碳", "一氧化碳", "酸碱中和", "金属材料", "化合价", "相对原子质量",
          "物质的量", "溶解度", "金属活动性", "硫及其化合物", "氮及其化合物",
          "化学平衡", "化学反应速率", "离子方程式", "硫", "氮", "氯"]


def core_key(name):
    s = (name or "").strip()
    s = re.sub(r"^第[一二三四五六七八九十百零〇\d]+[单元章]\s*", "", s)
    s = re.sub(r"^专题[一二三四五六七八九十\d]+\s*", "", s)
    s = re.sub(r"[\s·:：（）()——、,，～~]", "", s)
    return s.lower()


def fams(text):
    s = text or ""
    return {f for f, kws in FAMILIES if any(k in s for k in kws)}


def strongs(text):
    s = text or ""
    return {k for k in STRONG if k in s}


def bigrams(s):
    c = core_key(s)
    return {c[i:i + 2] for i in range(len(c) - 1)} if len(c) > 1 else ({c} if c else set())


def score(topic, chapter, topic_grade, chapter_grade):
    tc, cc = core_key(topic.get("unit_name", "")), core_key(chapter)
    if tc and tc == cc:
        return 1000
    s = 0
    if topic_grade == chapter_grade:
        s += 60
    s += len(strongs(topic["name"]) & strongs(chapter)) * 100
    s += len(fams(topic["name"]) & fams(chapter)) * 20
    s += len(fams(topic.get("unit_name", "")) & fams(chapter)) * 10
    s += len(bigrams(topic["name"]) & bigrams(chapter)) * 2
    if core_key(topic["name"]) and core_key(topic["name"]) in cc:
        s += 30
    return s


def load_pool(volumes):
    """收集某学段所有通用卷的 topic（带 grade），并按 id 去重。"""
    pool = {}
    for vol, grade in volumes:
        d = json.loads((KNOW / f"{vol}.json").read_text(encoding="utf-8"))
        for t in d["topics"]:
            pool[t["id"]] = (t, grade)
        for q in d["questions"]:
            if q.get("topic") in pool:
                pool[q["topic"]][0].setdefault("_questions", []).append(q)
    return pool


def main():
    check_only = "--check" in sys.argv
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    books = json.loads(BOOKS.read_text(encoding="utf-8"))

    by_ed = defaultdict(list)
    for b in books:
        by_ed[b["edition"]].append(b)

    # renjiao 用 catalog 真实单元
    renjiao_vols = []
    node = cat["subjects"]["chemistry"]["editions"]["renjiao"]
    for g in sorted(node["grades"], key=lambda x: int(x)):
        for sem in ("upper", "lower"):
            v = node["grades"][g].get(sem)
            if not v:
                continue
            renjiao_vols.append({"edition": "renjiao", "label": "人教版",
                                 "grade": int(g), "semester": sem,
                                 "book": "人教版（catalog 目录）", "path": "renjiao",
                                 "chapters": [u["name"] for u in v["units"]],
                                 "unit_ids": [u["id"] for u in v["units"]]})
    targets = {"renjiao": renjiao_vols}
    for ed in EDITION_LABEL:
        if ed != "renjiao":
            targets[ed] = by_ed.get(ed, [])

    print("化学多版本 TOC" + ("（预检）" if check_only else ""))
    total_t = total_q = total_weak = 0
    new_catalog = json.loads(json.dumps(cat))
    chem_cat = new_catalog["subjects"]["chemistry"]

    for ed, vols in targets.items():
        label = EDITION_LABEL[ed]
        # 只处理初中册
        stages = {"junior": [b for b in vols if b["grade"] <= 9]}
        for stage, sbooks in stages.items():
            if not sbooks:
                continue
            # 学段章节池
            chap_pool = []
            book_chaps = {}
            own_book = {}
            for b in sbooks:
                book_chaps[id(b)] = []
                for i, ch in enumerate(b["chapters"]):
                    node_ch = {"name": ch, "grade": b["grade"], "book": b, "idx": i}
                    chap_pool.append(node_ch)
                    book_chaps[id(b)].append(node_ch)
                vol = f"g{b['grade']}{'u' if b['semester'] == 'upper' else 'l'}"
                own_book[vol] = b
            # 学段通用知识点池（按该学段年级取卷）
            pool = {}
            for b in sbooks:
                vol = f"g{b['grade']}{'u' if b['semester'] == 'upper' else 'l'}"
                kp = KNOW / f"{vol}.json"
                if not kp.exists():
                    continue
                d = json.loads(kp.read_text(encoding="utf-8"))
                for t in d["topics"]:
                    pool.setdefault(t["id"], {"topic": t, "grade": b["grade"],
                                              "vol": vol, "questions": []})
                for q in d["questions"]:
                    if q.get("topic") in pool:
                        pool[q["topic"]]["questions"].append(q)

            # 分配：先本册前缀命中，其余按「置信度降序」贪心，
            # 同分时选当前挂载最少的章，避免歧义知识点全堆到第一章。
            assign = {}      # tid -> (chapter_obj, score)
            weak = []
            pending = []     # (max_score, tid, item, own_book)
            load = {id(ch): 0 for ch in chap_pool}
            for tid, item in pool.items():
                t = item["topic"]
                own = own_book.get(item["vol"])
                hit = None
                if own is not None:
                    tk = core_key(t.get("unit_name", ""))
                    if tk:
                        best_len = -1
                        for ch in book_chaps[id(own)]:
                            ck = core_key(ch["name"])
                            if not ck:
                                continue
                            if tk == ck:
                                hit = ch
                                break
                            if tk.startswith(ck) and len(ck) > best_len:
                                hit, best_len = ch, len(ck)
                if hit is not None:
                    assign[tid] = (hit, 1000)
                    load[id(hit)] = load.get(id(hit), 0) + 1
                    continue
                pending.append((tid, item, own))

            # 预计算每个待定知识点的打分
            scored = []
            for tid, item, own in pending:
                t, tg = item["topic"], item["grade"]
                row = []
                for ch in chap_pool:
                    sc = score(t, ch["name"], tg, ch["grade"])
                    if own is not None and ch["book"] is own:
                        sc += 5
                    row.append((sc, ch))
                mx = max(s for s, _ in row)
                scored.append((mx, tid, item, row))
            scored.sort(key=lambda x: -x[0])

            for mx, tid, item, row in scored:
                # 同分候选中选已挂载最少的章
                cands = [(load[id(ch)], ch) for sc, ch in row if sc == mx]
                cands.sort(key=lambda c: (c[0], chap_pool.index(c[1])))
                ch = cands[0][1]
                assign[tid] = (ch, mx)
                load[id(ch)] = load.get(id(ch), 0) + 1
                if mx < 20:
                    weak.append((tid, item["topic"]["name"], ch["name"], mx))

            # 按册落地
            for b in sbooks:
                g, sem = b["grade"], b["semester"]
                vol = f"g{g}{'u' if sem == 'upper' else 'l'}"
                ids = b.get("unit_ids") or [f"u{i+1}" for i in range(len(b["chapters"]))]
                units = [{"id": ids[i], "name": ch}
                         for i, ch in enumerate(b["chapters"])]
                my_chaps = set(id(ch) for ch in [])  # placeholder
                topics, questions = [], []
                for tid, (ch, sc) in assign.items():
                    if ch["book"] is not b:
                        continue
                    t = pool[tid]["topic"]
                    topics.append({
                        "id": t["id"], "name": t["name"],
                        "domain": t.get("domain"), "kp_type": t.get("kp_type"),
                        "unit": ids[ch["idx"]], "unit_name": ch["name"],
                        "description": t.get("description"),
                        "mastery_criteria": t.get("mastery_criteria"),
                        "example": t.get("example"),
                    })
                    for q in pool[tid]["questions"]:
                        nq = dict(q)
                        nq["edition"] = ed
                        nq["unit"] = ids[ch["idx"]]
                        nq["unit_name"] = ch["name"]
                        questions.append(nq)
                topics.sort(key=lambda x: (x["unit"], x["id"]))
                questions.sort(key=lambda x: (x["unit"], x["id"]))

                total_t += len(topics)
                total_q += len(questions)
                if check_only:
                    print(f"  {ed:8} {vol}: {len(units)}章 {len(topics)}点 {len(questions)}题")
                    continue

                toc = {
                    "schema_version": 1,
                    "generated_by": "build_chemistry_toc.py (stage-wide chapter alignment)",
                    "source": {"site": f"dzkbw.com {label} {b['book']}；知识点/题目复用通用化学池",
                               "path": b.get("path"), "fetched": "2026-11-20"},
                    "subject": "chemistry", "grade": g, "semester": sem,
                    "edition": ed, "edition_label": label,
                    "units": units, "topics": topics, "questions": questions,
                }
                td = TOC_OUT / ed
                td.mkdir(parents=True, exist_ok=True)
                (td / f"{vol}.json").write_text(
                    json.dumps(toc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

                if ed != "renjiao":
                    bd = BANK_OUT / ed
                    bd.mkdir(parents=True, exist_ok=True)
                    bank = {"schema_version": 1, "subject": "chemistry",
                            "grade": g, "semester": sem,
                            "textbook": f"{label} {b['book']}",
                            "questions": questions}
                    (bd / f"g{g}_{sem}.json").write_text(
                        json.dumps(bank, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

                    et = chem_cat["editions"].setdefault(
                        ed, {"name": label, "publisher": label, "grades": {}})
                    et.setdefault("grades", {}).setdefault(str(g), {})[sem] = {
                        "file": f"chemistry/{ed}/g{g}_{sem}.json", "units": units}
            total_weak += len(weak)
            if check_only and weak:
                print(f"  [{ed} {stage}] 低置信 {len(weak)}:")
                for tid, tn, ch, sc in weak[:5]:
                    print(f"      {tid} {tn[:14]} -> {ch} (s={sc})")

    if not check_only:
        order = chem_cat.setdefault("order", [])
        for ed in EDITION_LABEL:
            if ed not in order:
                order.append(ed)
        CATALOG.write_text(json.dumps(new_catalog, ensure_ascii=False, indent=1) + "\n",
                           encoding="utf-8")

    print(f"合计 {total_t} 知识点 / {total_q} 题，低置信 {total_weak}")


if __name__ == "__main__":
    main()
