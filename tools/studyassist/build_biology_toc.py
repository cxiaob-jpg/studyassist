#!/usr/bin/env python3
"""生物多版本 TOC 与题库生成（按物理方法）。

与物理/化学/地理同构，但生物学有个更麻烦的地方：各版本把同一块内容放在
不同年级——人教版七下讲植物、八上讲人体（二）；苏教版七下就讲植物、八上
讲人体；北师大版七上讲植物、七下讲人体；苏科版七上讲生物与环境。按年级
对齐必然错位，因此和地理一样走「整学段章节池 + 内容匹配」，不打年级分。

粒度说明：人教版 catalog 用「单元」（第1单元 生物和细胞…）作为单元，因为
历史数据（题库 unit=u1..u6）已按单元打标；其余版本用「章」作为单元，因为
北师大七下只有一个单元却含 6 章、苏教八上只有一个单元却含 5 章，用单元会
把十几个知识点堆成一坨。

章节来源：/tmp/biology_toc.json（dzkbw 手机版官方目录，2026-11-20 抓取）。
册次不全的版本整版跳过，不生成残缺 TOC。

产出：
- data/toc/biology/<ed>/gX{u,l}.json（units + topics + questions）
- data/biology/<ed>/gX_{upper,lower}.json（题库，新版本；renjiao 已有不覆盖）
- catalog.json 注册新版本 units/file

用法：python3 tools/studyassist/build_biology_toc.py [--check]
"""
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/biology"
TOC_OUT = ROOT / "data/toc/biology"
BANK_OUT = ROOT / "data/biology"
CATALOG = ROOT / "data/catalog.json"
BOOKS = Path("/tmp/biology_toc.json")

EDITION_LABEL = {
    "renjiao": "人教版",
    "sjb": "苏教版",
    "bsd": "北师大版",
    "skb": "苏科版",
    "jinan": "济南版",
    "jsb": "冀少版",
    "lkb": "鲁科版",
}

FAMILIES = [
    ("cell", ["细胞", "显微镜", "分裂", "分化", "组织", "器官", "系统", "结构层次",
              "单细胞", "细胞膜", "细胞核", "细胞质"]),
    ("diversity", ["藻类", "苔藓", "蕨类", "种子植物", "无脊椎", "脊椎", "鱼",
                   "两栖", "爬行", "鸟", "哺乳", "细菌", "真菌", "病毒", "微生物",
                   "分类", "从种到界", "命名", "类群", "生物多样性", "动物", "保护"]),
    ("plant", ["种子", "萌发", "植株", "生长", "开花", "结果", "光合", "呼吸",
               "蒸腾", "水", "运输", "导管", "筛管", "植物", "生产者", "碳氧",
               "水循环"]),
    ("human", ["人的生殖", "青春期", "营养", "消化", "吸收", "膳食", "呼吸道",
               "人体", "调节", "内分泌", "神经系统", "代谢",
               "肺", "气体交换", "血液", "血管", "心脏", "循环", "排泄", "泌尿",
               "肾", "尿", "皮肤", "汗液", "神经", "感觉", "激素", "运动",
               "骨骼", "肌肉", "能量供应"]),
    ("health", ["传染病", "免疫", "用药", "急救", "健康", "生活方式", "癌症",
                "心血管", "疾病"]),
    ("reproduce", ["生殖", "繁殖", "基因", "性状", "遗传", "变异", "性别决定",
                   "育种", "转基因", "显性", "隐性", "亲子代"]),
    ("evolution", ["生命起源", "进化", "人类的起源", "自然选择", "证据",
                   "发生和发展", "资源保护"]),
    ("ecology", ["环境", "生态", "生物圈", "食物链", "食物网", "消费者",
                 "分解者", "生态安全", "入侵", "稳定性", "和谐共生"]),
    ("method", ["观察", "调查", "探究", "实验", "科学方法", "测量", "研究",
                "生物学", "认识生物", "生物的特征", "走进生命世界", "周边环境"]),
]

# 高辨识度词：命中即为强信号
STRONG = ["光合作用", "呼吸作用", "蒸腾作用", "显微镜", "单细胞生物", "无脊椎动物",
          "脊椎动物", "种子植物", "藻类", "苔藓", "蕨类", "细菌", "真菌", "病毒",
          "生物分类", "从种到界", "食物链", "食物网", "生态系统", "生物圈",
          "无性生殖", "有性生殖", "显性", "隐性", "性别决定", "转基因",
          "微生物", "生物多样性", "类群", "资源保护",
          "生命起源", "自然选择", "免疫", "传染病", "青春期", "激素调节",
          "神经调节", "血液循环", "气体交换", "消化和吸收", "排泄", "骨骼肌"]


def core_key(name):
    s = (name or "").strip()
    s = re.sub(r"^第[一二三四五六七八九十百零〇\d]+[单元章]\s*", "", s)
    s = re.sub(r"^专题[一二三四五六七八九十\d]+\s*", "", s)
    s = re.sub(r"[\s·:：（）()——、,，～~\-—]", "", s)
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


def score(topic, chapter):
    tk = core_key(topic.get("unit_name", ""))
    tname = topic.get("name", "")
    cc = core_key(chapter)
    if tk and tk == cc:
        return 1000
    # 互相包含：必须长度接近才算「同一块内容」。否则「细胞」会被判成
    # 「生物和细胞」的子串，把整个单元的知识点全吸到「第2章 细胞」上。
    if tk and cc:
        short, long_ = (tk, cc) if len(tk) <= len(cc) else (cc, tk)
        if short in long_ and len(short) >= 4 and len(short) / len(long_) >= 0.6:
            return 600
    s = 0
    if tname and cc and core_key(tname) and core_key(tname) in cc:
        s += 200
    # 反向：章名出现在知识点名里（「细胞」⊂「植物细胞」）也算强命中，
    # 否则「第2章 细胞」会和「第3章 生物体的结构层次」平票，靠分摊随机归属。
    if cc and len(cc) >= 2 and core_key(tname) and cc in core_key(tname):
        s += 150
    s += len(strongs(tname) & strongs(chapter)) * 100
    # 知识点自身的语义比「它属于人教哪个单元」更能说明该落在哪一章
    s += len(fams(tk) & fams(chapter)) * 15
    s += len(fams(tname) & fams(chapter)) * 25
    s += len(bigrams(tname) & bigrams(chapter)) * 2
    return s


def main():
    check_only = "--check" in sys.argv
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    books = json.loads(BOOKS.read_text(encoding="utf-8")) if BOOKS.exists() else []

    by_ed = defaultdict(list)
    for b in books:
        by_ed[b["edition"]].append(b)

    # renjiao 用 catalog 真实单元（保持既有 unit id 不变）
    renjiao_vols = []
    node = cat["subjects"]["biology"]["editions"]["renjiao"]
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

    # 全科知识点池（各版本年级排布不同，不能按册取）
    pool = {}
    for v in sorted(KNOW.glob("g*.json"), key=lambda p: p.stem):
        d = json.loads(v.read_text(encoding="utf-8"))
        g = int(re.sub(r"\D", "", v.stem)[0])
        for t in d["topics"]:
            pool.setdefault(t["id"], {"topic": t, "grade": g, "vol": v.stem,
                                      "questions": []})
        for q in d["questions"]:
            if q.get("topic") in pool:
                pool[q["topic"]]["questions"].append(q)
    print("生物多版本 TOC" + ("（预检）" if check_only else ""))
    print(f"  知识点池 {len(pool)} 个")

    total_t = total_q = total_weak = 0
    new_catalog = json.loads(json.dumps(cat))
    bio_cat = new_catalog["subjects"]["biology"]

    for ed, vols in targets.items():
        if not vols:
            continue
        label = EDITION_LABEL[ed]

        # 册次完整性：初中生物每个版本都该有 7上/7下/8上/8下（鲁科五四制 6~8）
        need = {(b["grade"], b["semester"]) for b in vols}
        if ed == "lkb":
            want = {(g, s) for g in (6, 7, 8) for s in ("upper", "lower")}
        elif ed != "renjiao":
            want = {(g, s) for g in (7, 8) for s in ("upper", "lower")}
        else:
            want = {(7, "upper"), (7, "lower"), (8, "upper"), (8, "lower")}
        missing = sorted(want - need)
        if missing:
            print(f"  -- {ed} 跳过：缺册 {missing}（目录不全，生成残卷会挤爆个别章）")
            continue

        chap_pool = []
        for b in vols:
            for i, ch in enumerate(b["chapters"]):
                chap_pool.append({"name": ch, "grade": b["grade"],
                                  "book": b, "idx": i})

        assign = {}
        weak = []
        load = {id(ch): 0 for ch in chap_pool}
        scored = []
        for tid, item in pool.items():
            t = item["topic"]
            row = [(score(t, ch["name"]), ch) for ch in chap_pool]
            scored.append((max(s for s, _ in row), tid, item, row))
        scored.sort(key=lambda x: -x[0])

        for mx, tid, item, row in scored:
            cands = [(load[id(ch)], chap_pool.index(ch)) for sc, ch in row if sc == mx]
            cands.sort()
            ch = next(c for sc, c in row if sc == mx and chap_pool.index(c) == cands[0][1])
            assign[tid] = (ch, mx)
            load[id(ch)] = load.get(id(ch), 0) + 1
            if mx < 20:
                weak.append((tid, item["topic"]["name"], ch["name"], mx))

        for b in vols:
            g, sem = b["grade"], b["semester"]
            vol = f"g{g}{'u' if sem == 'upper' else 'l'}"
            ids = b.get("unit_ids") or [f"u{i+1}" for i in range(len(b["chapters"]))]
            units = [{"id": ids[i], "name": ch} for i, ch in enumerate(b["chapters"])]
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
            topics.sort(key=lambda x: (ids.index(x["unit"]), x["id"]))
            questions.sort(key=lambda x: (ids.index(x["unit"]), x["id"]))

            total_t += len(topics)
            total_q += len(questions)
            if check_only:
                print(f"  {ed:8} {vol}: {len(units)}单元 {len(topics)}点 {len(questions)}题")
                for u in units:
                    n = sum(1 for t in topics if t["unit"] == u["id"])
                    print(f"      {u['id']:>4} {u['name'][:26]:<28} {n}")
                continue

            toc = {
                "schema_version": 1,
                "generated_by": "build_biology_toc.py (stage-wide chapter alignment)",
                "source": {"site": f"dzkbw.com {label} {b['book']}；知识点/题目复用通用生物池",
                           "path": b.get("path"), "fetched": "2026-11-20"},
                "subject": "biology", "grade": g, "semester": sem,
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
                bank = {"schema_version": 1, "subject": "biology",
                        "grade": g, "semester": sem,
                        "textbook": f"{label} {b['book']}",
                        "questions": questions}
                (bd / f"g{g}_{sem}.json").write_text(
                    json.dumps(bank, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

                et = bio_cat["editions"].setdefault(
                    ed, {"name": label, "publisher": label, "grades": {}})
                et.setdefault("grades", {}).setdefault(str(g), {})[sem] = {
                    "file": f"biology/{ed}/g{g}_{sem}.json", "units": units}
        total_weak += len(weak)
        if weak:
            print(f"  [{ed}] 低置信 {len(weak)}:")
            for tid, tn, ch, sc in weak[:8]:
                print(f"      {tid} {tn[:16]} -> {ch} (s={sc})")

    if not check_only:
        order = bio_cat.setdefault("order", [])
        for ed in EDITION_LABEL:
            if ed in bio_cat["editions"] and ed not in order:
                order.append(ed)
        CATALOG.write_text(json.dumps(new_catalog, ensure_ascii=False, indent=1) + "\n",
                           encoding="utf-8")

    print(f"合计 {total_t} 知识点 / {total_q} 题，低置信 {total_weak}")


if __name__ == "__main__":
    main()
