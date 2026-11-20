#!/usr/bin/env python3
"""地理多版本 TOC 与题库生成（按物理方法）。

与物理/化学同构的做法：
- knowledge/geography/g7u~g8l.json 是课标通用知识点 + 题目池（按人教目录组织）。
- **按学段统一分配**：初中（6~8 年级）把所有版本的章合起来做候选池。地理必须
  这样做的原因更硬：各版本把「中国地理 / 世界地理」放在不同年级（人教 7 世界、
  8 中国；中图 7 中国、8 世界；鲁教五四制 6 世界、7 中国），按年级对齐必然错位。
- 因此**不打年级分**，改用地缘归属（世界/中国）做硬闸门，再叠加章名匹配。
- 打分：同章名 1000；互相包含 600；知识点名命中章名 200；概念族 20/30；
  二元组 2；地缘冲突 -300。

章节来源：/tmp/geography_toc.json（dzkbw 手机版官方目录，2026-11-20 抓取）。
晋教版 2024 版新版仅七上可抓（主题式目录），七下/八上/八下目录页为空，暂缺。

产出：
- data/toc/geography/<ed>/gX{u,l}.json（units + topics + questions）
- data/geography/<ed>/gX_{upper,lower}.json（题库，新版本；renjiao 已有不覆盖）
- catalog.json 注册新版本 units/file

用法：python3 tools/studyassist/build_geography_toc.py [--check]
"""
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/geography"
TOC_OUT = ROOT / "data/toc/geography"
BANK_OUT = ROOT / "data/geography"
CATALOG = ROOT / "data/catalog.json"
BOOKS = Path("/tmp/geography_toc.json")

EDITION_LABEL = {
    "renjiao": "人教版",
    "xjb": "湘教版",
    "ljb": "鲁教版",
    "ztb": "中图版",
    "swb": "商务版",
}

# 概念族：(族名, 关键词)。用于「章名没直接命中」时判断主题归属。
FAMILIES = [
    ("earth", ["地球", "地球仪", "经纬", "太阳", "月球", "火星", "宇宙", "太空",
               "自转", "公转", "昼夜", "季节", "五带", "天体", "宜居带"]),
    ("map", ["地图", "地形图", "等高线", "比例尺", "图例", "地理信息", "判读",
             "阅读", "选择和应用", "走进地理"]),
    ("landsea", ["陆地", "海洋", "大洲", "大洋", "海陆", "板块", "火山", "地震",
                 "地形类型", "地形", "面貌"]),
    ("climate", ["气候", "天气", "气温", "降水", "温度带", "干湿"]),
    ("people", ["人口", "人种", "民族", "语言", "宗教", "居民", "聚落", "城镇",
                "乡村", "城乡", "文化", "景观"]),
    ("develop", ["发展与合作", "合作", "全球化", "命运共同体", "发展差异", "差异"]),
    ("world", ["亚洲", "东南亚", "西亚", "欧洲", "非洲", "极地", "地区", "国家",
               "世界", "大洲", "邻近"]),
    ("china", ["中国", "疆域", "行政区划", "民族", "地势", "河流", "湖泊",
               "自然灾害", "基础自然要素", "人文环境要素"]),
    ("resource", ["自然资源", "土地资源", "水资源", "矿产", "海洋资源", "产业",
                  "农业", "工业", "交通", "经济"]),
    ("region", ["区域", "地域差异", "北方", "南方", "西北", "青藏", "北京",
                "台湾", "香港", "澳门", "黄土高原", "东北三省", "长江三角洲",
                "塔里木", "三江源", "美丽中国", "奋进", "永续"]),
    # 城市/城市群案例（京津冀、长三角、港澳台、北京）——新版教材常单独成章讲
    # 「区域内外联系与协同发展」，靠这条族把案例区域与自然区域分开
    ("urban", ["北京", "香港", "澳门", "台湾", "长江三角洲", "珠江三角洲",
               "京津冀", "粤港澳", "城市", "城乡", "都市", "分布", "联系", "协同"]),
]

# 地缘归属：世界地理 vs 中国地理。
# 知识点侧不需要猜——通用知识点是按人教目录组织的，g7u/g7l 即世界地理、
# g8u/g8l 即中国地理；章侧按书册显式声明（各版本世界/中国分册年级不同），
# 个别册内部混排（如中图七上）按章覆写。分配时强制同区，跨区不参与竞争。
BOOK_REGION = {
    ("xjb", 7, "upper"): "world", ("xjb", 7, "lower"): "world",
    ("xjb", 8, "upper"): "china", ("xjb", 8, "lower"): "china",
    ("ljb", 6, "upper"): "world", ("ljb", 6, "lower"): "world",
    ("ljb", 7, "upper"): "china", ("ljb", 7, "lower"): "china",
    ("ztb", 7, "lower"): "china",
    ("ztb", 8, "upper"): "world", ("ztb", 8, "lower"): "world",
    ("swb", 7, "upper"): "world", ("swb", 7, "lower"): "world",
}
# 册内混排：逐章覆写（键 = edition/年级/学期）
CHAPTER_REGION = {
    ("ztb", 7, "upper"): ["world", "world", "china", "china"],
}

# 高辨识度词：命中即强信号（章名里出现说明讲的就是这块）
STRONG = ["地球的宇宙环境", "地球与地球仪", "地图的阅读", "地形图的判读",
          "地图的选择", "大洲和大洋", "世界的地形", "海陆的变迁", "多变的天气",
          "气温", "降水", "世界的气候", "人口与人种", "城镇与乡村", "多样的文化",
          "亚洲的自然环境", "亚洲的人文环境", "日本", "东南亚", "印度", "俄罗斯",
          "西亚", "欧洲西部", "撒哈拉以南非洲", "澳大利亚", "美国", "巴西",
          "极地地区", "疆域", "民族", "河流与湖泊", "土地资源", "水资源",
          "矿产资源", "海洋资源", "农业", "工业", "交通运输", "自然灾害",
          "环境保护", "中国的地理差异", "北方地区", "东北三省", "黄土高原",
          "北京", "南方地区", "长江三角洲", "香港和澳门", "台湾省", "西北地区",
          "塔里木盆地", "青藏地区", "三江源地区", "奋进中的中国"]


def core_key(name):
    s = (name or "").strip()
    s = re.sub(r"^第[一二三四五六七八九十百零〇\d]+[单元章]\s*", "", s)
    s = re.sub(r"^专题[一二三四五六七八九十\d]+\s*", "", s)
    s = re.sub(r"^主题[一二三四五六七八九十\d]+\s*", "", s)
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


# 世界地理第二层：有的版本按「大洲 → 地区 → 国家」重组（湘教、中图），
# 人教则按半球分组（邻近的地区和国家 / 东半球 / 西半球），只靠章名匹配会把
# 「美国」「印度」扔进「世界的发展差异」。这里按知识点自身的层级归类，
# 与章的层级对齐；同时含「地区和国家」的混合章保持中立。
COUNTRY_TOPICS = ["日本", "印度", "俄罗斯", "美国", "巴西", "澳大利亚"]
REGION_TOPICS = ["东南亚", "西亚", "欧洲西部", "撒哈拉以南非洲", "极地地区"]
CONTINENT_TOPICS = ["亚洲", "大洲和大洋", "世界的地形", "认识大洲"]


def bucket_bonus(tname, chapter):
    t, c = tname or "", chapter or ""
    has_country = "国家" in c
    has_region = "地区" in c
    if any(k in t for k in COUNTRY_TOPICS):
        if has_country:
            return 120
        if has_region:
            return -80
    elif any(k in t for k in REGION_TOPICS):
        if has_region and not has_country:
            return 120
        if has_country and not has_region:
            return -80
    elif any(k in t for k in CONTINENT_TOPICS):
        if "大洲" in c:
            return 120
    return 0


def book_region(ed, grade, sem):
    if (ed, grade, sem) in BOOK_REGION:
        return BOOK_REGION[(ed, grade, sem)]
    return "world" if grade <= 7 else "china"   # 人教口径兜底


def score(topic, chapter):
    tk = core_key(topic.get("unit_name", ""))
    tname = topic.get("name", "")
    cc = core_key(chapter)
    if tk and tk == cc:
        return 1000
    if tk and cc and (tk in cc or cc in tk):
        return 600
    s = 0
    if tname and cc and core_key(tname) and core_key(tname) in cc:
        s += 200
    s += len(strongs(tname) & strongs(chapter)) * 100
    s += len(fams(tk) & fams(chapter)) * 30
    s += len(fams(tname) & fams(chapter)) * 20
    s += len(bigrams(tname) & bigrams(chapter)) * 2
    s += bucket_bonus(tname, chapter)
    return s


def main():
    check_only = "--check" in sys.argv
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    books = json.loads(BOOKS.read_text(encoding="utf-8"))

    by_ed = defaultdict(list)
    for b in books:
        by_ed[b["edition"]].append(b)

    # renjiao 用 catalog 真实单元（保持既有 unit id 不变）
    renjiao_vols = []
    node = cat["subjects"]["geography"]["editions"]["renjiao"]
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

    print("地理多版本 TOC" + ("（预检）" if check_only else ""))
    total_t = total_q = total_weak = 0
    new_catalog = json.loads(json.dumps(cat))
    geo_cat = new_catalog["subjects"]["geography"]

    # 全科知识点池：各版本世界/中国分册年级不同，不能按册取知识点，
    # 只能全科共用一池，再由内容匹配决定落在哪一册。
    # 地缘直接按人教卷归属：g7u/g7l = 世界地理，g8u/g8l = 中国地理。
    pool = {}
    for v in sorted(KNOW.glob("g*.json"), key=lambda p: p.stem):
        d = json.loads(v.read_text(encoding="utf-8"))
        g = int(re.sub(r"\D", "", v.stem)[0])
        region = "world" if v.stem in ("g7u", "g7l") else "china"
        for t in d["topics"]:
            pool.setdefault(t["id"], {"topic": t, "grade": g, "vol": v.stem,
                                      "region": region, "questions": []})
        for q in d["questions"]:
            if q.get("topic") in pool:
                pool[q["topic"]]["questions"].append(q)
    world_n = sum(1 for i in pool.values() if i["region"] == "world")
    print(f"  知识点池 {len(pool)} 个（世界 {world_n} / 中国 {len(pool) - world_n}）")

    for ed, vols in targets.items():
        if not vols:
            continue
        label = EDITION_LABEL[ed]

        # 整学段章节池（地理初中 6~8 年级共用一池），逐章带地缘标记
        chap_pool = []
        for b in vols:
            override = CHAPTER_REGION.get((ed, b["grade"], b["semester"]))
            base = book_region(ed, b["grade"], b["semester"])
            for i, ch in enumerate(b["chapters"]):
                chap_pool.append({"name": ch, "grade": b["grade"], "book": b, "idx": i,
                                  "region": (override[i] if override and i < len(override)
                                             else base)})
        have = {ch["region"] for ch in chap_pool}
        lack = sorted({"world", "china"} - have)
        if lack:
            # 缺册导致半个学科无处落地（如商务版只有七上/七下），整版跳过，
            # 不生成残缺 TOC——否则另一个半区的知识点会挤爆个别章。
            print(f"  -- {ed} 跳过：缺少 {'/'.join(lack)} 章节（该校版本册次不全）")
            continue

        # 分配：按置信度降序贪心，只在与知识点同地缘的章里竞争；
        # 同分选当前挂载最少的章。
        assign = {}
        weak = []
        load = {id(ch): 0 for ch in chap_pool}
        scored = []
        for tid, item in pool.items():
            t = item["topic"]
            row = [(score(t, ch["name"]), ch) for ch in chap_pool
                   if ch["region"] == item["region"]]
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
            topics.sort(key=lambda x: (x["unit"], x["id"]))
            questions.sort(key=lambda x: (x["unit"], x["id"]))

            total_t += len(topics)
            total_q += len(questions)
            if check_only:
                print(f"  {ed:8} {vol}: {len(units)}章 {len(topics)}点 {len(questions)}题")
                for u in units:
                    n = sum(1 for t in topics if t["unit"] == u["id"])
                    print(f"      {u['id']:>4} {u['name'][:26]:<28} {n}")
                continue

            toc = {
                "schema_version": 1,
                "generated_by": "build_geography_toc.py (stage-wide chapter alignment)",
                "source": {"site": f"dzkbw.com {label} {b['book']}；知识点/题目复用通用地理池",
                           "path": b.get("path"), "fetched": "2026-11-20"},
                "subject": "geography", "grade": g, "semester": sem,
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
                bank = {"schema_version": 1, "subject": "geography",
                        "grade": g, "semester": sem,
                        "textbook": f"{label} {b['book']}",
                        "questions": questions}
                (bd / f"g{g}_{sem}.json").write_text(
                    json.dumps(bank, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

                et = geo_cat["editions"].setdefault(
                    ed, {"name": label, "publisher": label, "grades": {}})
                et.setdefault("grades", {}).setdefault(str(g), {})[sem] = {
                    "file": f"geography/{ed}/g{g}_{sem}.json", "units": units}
        total_weak += len(weak)
        if weak:
            print(f"  [{ed}] 低置信 {len(weak)}:")
            for tid, tn, ch, sc in weak[:8]:
                print(f"      {tid} {tn[:16]} -> {ch} (s={sc})")

    if not check_only:
        order = geo_cat.setdefault("order", [])
        for ed in EDITION_LABEL:
            if ed in geo_cat["editions"] and ed not in order:
                order.append(ed)
        CATALOG.write_text(json.dumps(new_catalog, ensure_ascii=False, indent=1) + "\n",
                           encoding="utf-8")

    print(f"合计 {total_t} 知识点 / {total_q} 题，低置信 {total_weak}")


if __name__ == "__main__":
    main()
