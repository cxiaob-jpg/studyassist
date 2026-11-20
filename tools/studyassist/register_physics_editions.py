#!/usr/bin/env python3
"""把 8 个新物理版本注册进 catalog.json。

- editions[<id>] = {name, grades:{g:{sem:{file, units}}}}
- units 从 data/toc/physics/<id>/gX{u,l}.json 读取（与 TOC 卷一致）
- file 指向 data/physics/<id>/gX_<sem>.json（通用题目，unit 已对齐）
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "data/catalog.json"
TOC = ROOT / "data/toc/physics"

EDITIONS = {
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


def main():
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    phys = cat["subjects"]["physics"]
    eds = phys["editions"]

    for eid, name in EDITIONS.items():
        entry = {"name": name, "grades": {}}
        for toc in sorted((TOC / eid).glob("g*.json")):
            m = re.match(r"g(\d+)([ul])", toc.name)
            g, sfx = m.group(1), m.group(2)
            sem = "upper" if sfx == "u" else "lower"
            d = json.loads(toc.read_text(encoding="utf-8"))
            entry["grades"].setdefault(g, {})[sem] = {
                "file": f"physics/{eid}/g{g}_{sem}.json",
                "units": d["units"],
            }
        eds[eid] = entry
        print(f"注册 {eid:8} {name}: {len(entry['grades'])} 个年级")

    # 保持 order 里的顺序（physics order 目前只列 renjiao）
    order = phys.get("order", [])
    for eid in EDITIONS:
        if eid not in order:
            order.append(eid)
    phys["order"] = order

    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"catalog 已更新，physics editions: {list(eds.keys())}")


if __name__ == "__main__":
    main()
