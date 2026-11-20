#!/usr/bin/env python3
"""给数学除 sujiao2024 之外的 7 个版本生成按各版目录展示的 TOC 知识点卷。

物理方法论的数学落地：
- knowledge/math/gX{u,l}.json 是课标通用知识点 + 题目池（题目带 topic 字段），
  目前按人教版 2024 目录组织（topic.unit_name 是人教单元名）。
- 各版本差异只在"教材章节划分"：catalog.json 的每版 units 是该版目录
  （也是 MathGen 出题时 unit_name 的数据源，故 TOC 锚定它可与练习保持一致）。
- 人教 / 初中通用 / 人教高中：topic.unit_name 与 catalog 单元同名度高，直接匹配。
- 北师大 / 苏教(老) / 青岛 / 沪教：目录名不同，用关键词族打分把知识点挂到
  最相近的单元（与 build_physics_editions.py 同一思路）。
- sujiao2024 已有 dzkbw 抓取的真实 TOC（cnm_p400+ 新点），本脚本不覆盖，直接跳过。

产出 data/toc/shuxue/<edition>/gX{u,l}.json：units 用 catalog 原文，
topics 重挂 unit/unit_name，questions 随 topic 走并写回 edition。

用法：python3 tools/studyassist/build_math_toc.py [--check]
"""
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
KNOW = ROOT / "data/knowledge/math"
OUT = ROOT / "data/toc/shuxue"
CATALOG = ROOT / "data/catalog.json"

# 版本 id -> 显示名。sujiao2024 已有真实 TOC，不在此列。
EDITION_LABEL = {
    "renjiao": "人教版（2024）",
    "beishida": "北师大版（2024）",
    "sujiao": "苏教版",
    "qingdao": "青岛版（2024）",
    "hujiao": "沪教版（2024）",
    "junior": "初中通用",
    "senior": "人教A版（高中）",
}

# 概念关键词族：同一族内的词视为同一主题，用于跨版本目录打分。
# 顺序无关；一个词可归入多族。
CONCEPT_FAMILIES = [
    ("number", ["数的认识", "数的意义", "认识", "数位", "数数", "以内数的认识",
                "万以内数", "大数", "多位数", "整数", "小数", "分数", "百分数",
                "负数", "因数", "倍数", "质数", "合数", "倒数"]),
    ("addsub", ["加法", "减法", "加减法", "进位加", "退位减", "混合运算", "四则运算",
                "运算定律", "运算律", "简便运算", "同级运算", "两级运算", "小括号",
                "加与减", "加减", "等量代换", "代换"]),
    ("muldiv", ["乘法", "除法", "乘除法", "表内乘", "表内除", "有余数的除法",
                "两三位数乘", "两位数乘", "三位数乘", "除数", "乘与除", "倍的认识",
                "乘除关系", "数量间"]),
    ("geometry", ["图形", "观察物体", "长方体", "正方体", "立方体", "展开", "立体",
                  "平面图形", "三角形", "平行四边形", "梯形", "长方形", "正方形",
                  "圆", "圆柱", "圆锥", "角", "线与角", "线段", "射线", "直线",
                  "面积", "周长", "公顷", "平方千米"]),
    ("position", ["位置", "方向", "轴对称", "平移", "旋转", "图形的运动",
                  "上下", "前后", "左右", "运动现象", "剪纸", "认位置"]),
    ("measure", ["测量", "厘米", "米", "毫米", "分米", "千米", "克", "千克", "吨",
                 "质量单位", "长度单位", "面积单位", "度量"]),
    ("time", ["时间", "钟表", "时分秒", "年月日", "认识钟表", "认识时间", "24时"]),
    ("money", ["人民币", "元角分", "钱币"]),
    ("data", ["统计", "数据", "统计表", "统计图", "条形统计图", "折线统计图",
              "扇形统计图", "平均数", "可能性", "概率", "收集与整理", "分类与整理",
              "分类", "逐层分类", "分一分"]),
    ("equation", ["方程", "等式", "代数式", "一元一次", "未知数", "等量代换",
                  "用字母表示数", "字母表示"]),
    ("ratio", ["比", "比例", "比例尺", "正反比例"]),
    ("func", ["函数", "一次函数", "二次函数", "指数", "对数", "幂", "集合", "逻辑"]),
    ("practical", ["数学广角", "综合与实践", "综合", "数学好玩", "找规律", "推理",
                   "优化", "鸡兔同笼", "植树问题", "找次品", "数与形", "编码",
                   "复习与关联", "整理和复习", "数学思考", "数学探究",
                   "搭配", "集合图", "重叠"]),
]

# 高区分度关键词：命中即给强分（避免"认识"这类泛词主导）
STRONG_KW = ["分数", "小数", "百分数", "负数", "因数", "倍数", "方程", "比例",
             "比例尺", "三角形", "平行四边形", "梯形", "长方体", "正方体", "圆柱",
             "圆锥", "观察物体", "混合运算", "运算定律", "有余数的除法", "平均数",
             "可能性", "概率", "条形统计图", "折线统计图", "扇形统计图", "鸡兔同笼",
             "植树问题", "找次品", "轴对称", "平移", "旋转", "公顷", "平方千米",
             "24时", "年月日", "一元一次", "函数", "指数", "对数", "集合"]


def core_key(name):
    """归一化单元名用于直接匹配：去章/单元序号、标点、序号词。"""
    s = (name or "").strip()
    s = re.sub(r"^第[一二三四五六七八九十百零〇\d]+[单元章][·:：]?\s*", "", s)
    s = re.sub(r"^综合与实践[·:：]?\s*", "", s)
    s = re.sub(r"[\s·:：（）()——、,，～~]", "", s)
    return s.lower()


def families_of(text):
    s = (text or "").strip()
    out = set()
    for fam, kws in CONCEPT_FAMILIES:
        if any(k in s for k in kws):
            out.add(fam)
    return out


def strong_of(text):
    s = (text or "").strip()
    return {k for k in STRONG_KW if k in s}


def bigrams(s):
    s = core_key(s)
    return {s[i:i + 2] for i in range(len(s) - 1)} if len(s) > 1 else ({s} if s else set())


def score_unit(topic, unit_name):
    """知识点对 catalog 单元的匹配打分。"""
    tcore = core_key(topic.get("unit_name", ""))
    ucore = core_key(unit_name)
    # 1) 直接单元名一致（最强）
    if tcore and tcore == ucore:
        return 1000
    # 2) 强关键词交集
    ts = strong_of(topic["name"]) | strong_of(topic.get("unit_name", ""))
    us = strong_of(unit_name)
    s = len(ts & us) * 100
    # 3) 概念族交集
    tf = families_of(topic["name"]) | families_of(topic.get("unit_name", ""))
    uf = families_of(unit_name)
    s += len(tf & uf) * 20
    # 4) 二元组重叠（弱信号，消歧）
    tb = bigrams(topic["name"]) | bigrams(topic.get("unit_name", ""))
    ub = bigrams(unit_name)
    s += len(tb & ub) * 2
    # 5) 知识点名直接出现在单元名
    if core_key(topic["name"]) and core_key(topic["name"]) in ucore:
        s += 30
    return s


def build_volume(ed, grade, sem, know, cat_units, label):
    if not cat_units:
        return None, [], 0
    units = [{"id": u["id"], "name": u["name"]} for u in cat_units]

    assign = {}       # topic id -> (unit id, unit name)
    weak = []         # 低置信知识点
    for t in know["topics"]:
        best, best_score, best_i = None, -1, 999
        for i, u in enumerate(cat_units):
            sc = score_unit(t, u["name"])
            if sc > best_score or (sc == best_score and i < best_i):
                best, best_score, best_i = u, sc, i
        assign[t["id"]] = (best["id"], best["name"])
        if best_score < 20:
            weak.append((t["id"], t["name"], best["name"], best_score))

    topics = []
    for t in know["topics"]:
        uid, uname = assign[t["id"]]
        topics.append({
            "id": t["id"], "name": t["name"],
            "domain": t.get("domain"), "kp_type": t.get("kp_type"),
            "unit": uid, "unit_name": uname,
            "description": t.get("description"),
            "mastery_criteria": t.get("mastery_criteria"),
            "example": t.get("example"),
        })

    questions = []
    skipped = 0
    seen_q = set()
    for q in know["questions"]:
        tid = q.get("topic")
        if tid not in assign or q.get("id") in seen_q:
            skipped += 1
            continue
        seen_q.add(q["id"])
        uid, uname = assign[tid]
        nq = dict(q)
        nq["edition"] = ed
        nq["unit"] = uid
        nq["unit_name"] = uname
        questions.append(nq)

    data = {
        "schema_version": 1,
        "generated_by": "build_math_toc.py (catalog unit re-anchor + keyword-family scoring)",
        "source": {
            "site": f"catalog.json {label} 单元目录；知识点/题目复用 knowledge/math 课标通用池",
            "units_from": "catalog.json",
        },
        "subject": "math",
        "grade": grade,
        "semester": sem,
        "edition": ed,
        "edition_label": label,
        "units": units,
        "topics": topics,
        "questions": questions,
    }
    return data, weak, skipped


def main():
    check_only = "--check" in sys.argv
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    eds = cat["subjects"]["math"]["editions"]
    print("数学多版本 TOC 重挂" + ("（预检）" if check_only else ""))

    total_vols = total_topics = total_q = 0
    total_weak = 0
    for ed, label in EDITION_LABEL.items():
        edvols = 0
        for grade in range(1, 13):
            for sem in ("upper", "lower"):
                node = eds[ed]["grades"].get(str(grade), {}).get(sem)
                if not node or not node.get("units"):
                    continue
                vol = f"g{grade}{'u' if sem == 'upper' else 'l'}"
                kp = KNOW / f"{vol}.json"
                if not kp.exists():
                    print(f"  WARN {ed} {vol}: 缺通用知识点卷 {kp.name}")
                    continue
                know = json.loads(kp.read_text(encoding="utf-8"))
                data, weak, skipped = build_volume(
                    ed, grade, sem, know, node["units"], label)
                if data is None:
                    continue
                edvols += 1
                total_vols += 1
                total_topics += len(data["topics"])
                total_q += len(data["questions"])
                total_weak += len(weak)
                print(f"  {ed:12} {vol}: {len(data['units'])}单元 "
                      f"{len(data['topics'])}知识点 {len(data['questions'])}题 "
                      f"低置信{len(weak)} 跳过{skipped}")
                if check_only:
                    if weak:
                        for tid, tn, un, sc in weak[:3]:
                            print(f"      low: {tid} {tn[:16]} -> {un} (s={sc})")
                    continue
                out_dir = OUT / ed
                out_dir.mkdir(parents=True, exist_ok=True)
                (out_dir / f"{vol}.json").write_text(
                    json.dumps(data, ensure_ascii=False, indent=1) + "\n",
                    encoding="utf-8")
        print(f"  => {ed} 共 {edvols} 卷")
    print(f"合计 {total_vols} 卷 / {total_topics} 知识点 / {total_q} 题，低置信 {total_weak}")


if __name__ == "__main__":
    main()
