#!/usr/bin/env python3
"""把上游带图形的题目整题渲染成一张 PNG，供 KOReader 答题页显示。

用户选择「整道题做成一张图」：题干文字 + 原 SVG 图形 + 选项文字/图形
全部拼进一张 SVG，用 resvg-js 转成 PNG。答案保持固定（沿用上游 answer），
题目仍走现有 choice / number 判定，只是题干区改看图、选项区按原答案点按钮。

用法（需先备好上游三个 json 到 <source>/data/）：
  python3 build_figure_questions.py --source /tmp/taxsrc           # 生成
  python3 build_figure_questions.py --source /tmp/taxsrc --check   # 只演练

输出：
  data/figures/<subject>/<qid>.png     整题图片
  /tmp/figure_patch/<subject>/<slot>.json   待合并的题目（由调用方写回卷）
"""
import argparse
import collections
import html
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent.parent
KNOW = PLUGIN / "data" / "knowledge"
FIGS = PLUGIN / "data" / "figures"

# 只处理用户点名的 8 个图题知识点（3 个多空题先不管）
FIGURE_TOPICS = [
    "cnm_050", "cnm_051", "cnm_258", "cnm_283",
    "cnk_j004", "cnk_j009", "cnh_j103", "cng_j003",
]
SLOT = {  # topic -> (subject, grade, semester)
    "cnm_050": ("math", 7, "upper"), "cnm_051": ("math", 7, "upper"),
    "cnm_258": ("math", 9, "upper"), "cnm_283": ("math", 9, "lower"),
    "cnk_j004": ("chemistry", 9, "upper"), "cnk_j009": ("chemistry", 9, "upper"),
    "cnh_j103": ("history", 9, "upper"), "cng_j003": ("geography", 7, "upper"),
}
EDITION = {"math": "renjiao", "chemistry": "renjiao", "history": "renjiao", "geography": "renjiao"}
DIFF = {"basic": 1, "intermediate": 2, "advanced": 3}
FONT = "/System/Library/Fonts/PingFang.ttc"


def load_source(src):
    d = Path(src) / "data"
    topics = {t["id"]: t for t in json.loads((d / "topics.json").read_text(encoding="utf-8"))}
    questions = json.loads((d / "questions.json").read_text(encoding="utf-8"))
    return topics, questions


def usable(q):
    """图题专用：接受 figure / 多空，只排掉无法渲染的类型。"""
    return q.get("type") in ("choice", "numeric")


def inner_svg(svg):
    """取 SVG 内部内容，剥掉外层 <svg ...> 和结尾。"""
    s = re.sub(r'^\s*<svg[^>]*>', "", svg.strip(), flags=re.S)
    s = re.sub(r'</svg>\s*$', "", s, flags=re.S)
    return s.strip()


def svg_viewbox(svg):
    m = re.search(r'viewBox="([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)"', svg)
    if m:
        return [float(x) for x in m.groups()]
    m = re.search(r'width="([\d.]+)"[^>]*height="([\d.]+)"', svg)
    if m:
        return [0, 0, float(m.group(1)), float(m.group(2))]
    return [0, 0, 220, 170]


def esc(t):
    return html.escape(str(t or ""), quote=True)


def wrap_cjk(text, per_line):
    """按字符数断行，中文题面够用。"""
    out, line = [], ""
    for ch in str(text):
        line += ch
        if len(line) >= per_line:
            out.append(line)
            line = ""
    if line:
        out.append(line)
    return out or [""]


def render_question_svg(q, width=760):
    """把一整道题拼成 SVG 字符串。返回 (svg_text, height)。

    布局：题干 → 顶层图形（居中，最高 340）→ 选项两列网格。
    选项图只显示字母 + 短标签（上游给读屏用的长描述省略），压低整图高度。
    """
    pad = 32
    inner_w = width - 2 * pad
    y = pad
    parts = []

    # 题干
    for ln in wrap_cjk(q.get("prompt", ""), 32):
        parts.append(f'<text x="{pad}" y="{y+30}" font-size="27" fill="#111" '
                     f'font-family="PingFang SC, Heiti SC, sans-serif">{esc(ln)}</text>')
        y += 38
    y += 12

    # 顶层图形：等比缩放进 inner_w，最高 340
    if q.get("figure"):
        vb = svg_viewbox(q["figure"])
        vw, vh = vb[2], vb[3]
        scale = min(inner_w / vw, 340 / vh, 1.5)
        w, h = vw * scale, vh * scale
        ox = (width - w) / 2 - vb[0] * scale
        oy = y - vb[1] * scale
        parts.append(f'<g transform="translate({ox:.1f},{oy:.1f}) scale({scale:.3f},{scale:.3f})">'
                     f'{inner_svg(q["figure"])}</g>')
        y += h + 18

    # 选项：两列网格
    choices = q.get("choices") or []
    if choices:
        gap = 20
        colw = (inner_w - gap) / 2
        rows = [choices[i:i + 2] for i in range(0, len(choices), 2)]
        for row in rows:
            row_top, row_h = y, 0
            for idx, c in enumerate(row):
                cx = pad + idx * (colw + gap)
                key = c.get("key", "?")
                raw = (c.get("text") or "").strip()
                label = raw if len(raw) <= 14 else ""  # 长描述是读屏用，图里省略
                parts.append(f'<text x="{cx+8:.1f}" y="{row_top+30}" font-size="26" font-weight="bold" fill="#111" '
                             f'font-family="PingFang SC, Heiti SC, sans-serif">{esc(key)}. {esc(label)}</text>')
                ch = 38
                if c.get("figure"):
                    vb = svg_viewbox(c["figure"])
                    scale = min((colw - 16) / vb[2], 150 / vb[3], 1.2)
                    w, h = vb[2] * scale, vb[3] * scale
                    ox = cx + 8 - vb[0] * scale
                    oy = row_top + 36 - vb[1] * scale
                    parts.append(f'<g transform="translate({ox:.1f},{oy:.1f}) scale({scale:.3f},{scale:.3f})">'
                                 f'{inner_svg(c["figure"])}</g>')
                    ch += h
                row_h = max(row_h, ch + 12)
            y = row_top + row_h + 6
    y += pad
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{int(y)}" '
           f'viewBox="0 0 {width} {int(y)}">'
           f'<rect x="0" y="0" width="{width}" height="{int(y)}" fill="#fff"/>'
           + "".join(parts) + "</svg>")
    return svg, int(y)


def convert(svg_text, out_png):
    """单张转换（试转用）。批量走 main() 里的 Node 一次性渲染。"""
    out_png = Path(out_png)
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False, encoding="utf-8") as f:
        f.write(svg_text)
        tmp = f.name
    try:
        r = subprocess.run(
            ["npx", "-y", "@resvg/resvg-js-cli", "--font-file", FONT, tmp, str(out_png)],
            capture_output=True, text=True, timeout=120,
        )
        if r.returncode != 0 or not out_png.exists():
            raise RuntimeError(f"resvg 失败: {r.stderr.strip()[:200]}")
    finally:
        os.unlink(tmp)


NODE_BATCH = r"""
const fs = require('fs');
const path = require('path');
const { Resvg } = require(process.env.RESVG_MODULE);
const sharp = require(process.env.SHARP_MODULE);
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
(async () => {
  for (const job of manifest) {
    const svg = fs.readFileSync(job.svg, 'utf8');
    const r = new Resvg(svg, {
      font: { loadSystemFonts: true, fontFiles: [process.env.RESVG_FONT], defaultFontFamily: 'PingFang SC' },
      fitTo: { mode: 'original' },
    });
    // 灰度调色板 PNG：墨水屏只需灰度，体积从 ~32KB 压到 ~9KB
    const buf = await sharp(r.render().asPng())
      .greyscale().png({ palette: true, colours: 8, compressionLevel: 9 })
      .toBuffer();
    fs.writeFileSync(job.png, buf);
  }
  console.log('converted ' + manifest.length + ' images');
})().catch(e => { console.error(e); process.exit(1); });
"""


def find_npx_module(name):
    """定位 npx 缓存里的 npm 包（含原生二进制）。"""
    import glob as _glob
    cands = _glob.glob(os.path.expanduser(f"~/.npm/_npx/*/node_modules/{name}"))
    if not cands:
        raise RuntimeError(f"找不到 {name}，请先运行一次 npx -y {name}")
    return cands[0]


def convert_batch(jobs):
    """jobs: [(svg_text, out_png), ...]，一次 Node 进程转完。"""
    batch_dir = Path(tempfile.mkdtemp(prefix="figure_batch_"))
    manifest = []
    for i, (svg_text, out_png) in enumerate(jobs):
        svg_file = batch_dir / f"{i:03d}.svg"
        svg_file.write_text(svg_text, encoding="utf-8")
        manifest.append({"svg": str(svg_file), "png": str(out_png)})
    man_file = batch_dir / "manifest.json"
    man_file.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    node_script = batch_dir / "batch.js"
    node_script.write_text(NODE_BATCH, encoding="utf-8")
    env = dict(os.environ)
    env["RESVG_MODULE"] = find_npx_module("@resvg/resvg-js")
    env["SHARP_MODULE"] = find_npx_module("sharp")
    env["RESVG_FONT"] = FONT
    r = subprocess.run(["node", str(node_script), str(man_file)],
                       capture_output=True, text=True, timeout=300, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"批量转换失败: {r.stderr.strip()[:300]}")
    missing = [j for _s, j in jobs if not Path(j).exists()]
    if missing:
        raise RuntimeError(f"{len(missing)} 张图片未生成，如 {missing[0]}")
    return len(jobs)


def norm_question(q, topic, unit_id, subject, image_rel):
    """沿用 build_knowledge_all 的题目字段，额外带 figure_image。"""
    out = {
        "id": q["id"], "topic": q["topicId"], "subject": subject,
        "grade": topic["grade"],
        "semester": "upper" if topic["semester"] == "上" else "lower",
        "edition": EDITION[subject], "unit": unit_id, "unit_name": topic["name"],
        "type": "knowledge", "skill": topic["domain"],
        "difficulty": DIFF.get(q.get("difficulty"), 2),
        "stem": q.get("prompt", "").strip(),
        "explain": q.get("explanation", "").strip(),
        "figure_image": image_rel,  # 相对插件根，如 data/figures/math/cnm_050_q1.png
    }
    if q["type"] == "choice":
        keys = [c.get("key") for c in q.get("choices", [])]
        if not 3 <= len(keys) <= 4 or keys != list("ABCD"[:len(keys)]):
            return None, "bad-choices"
        out["answer_mode"] = "choice"
        out["options"] = [(c.get("text") or "").strip() for c in q["choices"]]
        out["answer"] = keys.index(q["answer"]) + 1
    else:
        ans = str(q["answer"]).strip()
        if re.fullmatch(r'\d+', ans):
            out.update(answer_mode="number", answer_format="integer", answer=int(ans))
        elif re.fullmatch(r'\d+\.\d+', ans):
            out.update(answer_mode="number", answer_format="decimal", answer=float(ans))
        else:
            return None, "bad-number"
    return out, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="上游数据根目录（含 data/）")
    ap.add_argument("--check", action="store_true", help="只演练，不写文件")
    args = ap.parse_args()

    topics, questions = load_source(args.source)
    by_topic = collections.defaultdict(list)
    for q in questions:
        if q.get("topicId") in FIGURE_TOPICS and usable(q):
            by_topic[q["topicId"]].append(q)

    total = sum(len(v) for v in by_topic.values())
    print(f"图题知识点 {len(FIGURE_TOPICS)} 个，可渲染题目 {total} 道")
    if args.check:
        for tid in FIGURE_TOPICS:
            print(f"  {tid:12s} {len(by_topic[tid])} 题")
        return

    patch = collections.defaultdict(list)
    jobs = []  # (svg_text, out_png)
    planned = []  # (slot, norm) 待题目字段，转换成功后再写入 patch
    for tid in FIGURE_TOPICS:
        subject, grade, sem = SLOT[tid]
        topic = topics[tid]
        # 找该题在卷里的 unit（用同步后的卷）
        vol_path = KNOW / subject / f"g{grade}{'u' if sem=='upper' else 'l'}.json"
        if not vol_path.exists():
            print(f"[跳过] {vol_path.relative_to(PLUGIN)} 不存在")
            continue
        vol = json.loads(vol_path.read_text(encoding="utf-8"))
        unit_id = "u1"
        for t in vol["topics"]:
            if t["id"] == tid:
                unit_id = t["unit"]
                break
        (FIGS / subject).mkdir(parents=True, exist_ok=True)
        for q in by_topic[tid]:
            svg, _h = render_question_svg(q)
            rel = f"data/figures/{subject}/{q['id']}.png"
            norm, err = norm_question(q, topic, unit_id, subject, rel)
            if not norm:
                print(f"[跳过] {q['id']}: {err}")
                continue
            jobs.append((svg, PLUGIN / rel))
            planned.append(((subject, grade, "upper" if sem == "upper" else "lower"), norm))
        print(f"[待转] {tid}: {len(by_topic[tid])} 题")

    print(f"\n批量渲染 {len(jobs)} 张图片 ...")
    made = convert_batch(jobs)
    for slot, norm in planned:
        patch[slot].append(norm)

    outroot = Path("/tmp/figure_patch")
    for (subject, grade, sem), qs in patch.items():
        p = outroot / subject / f"g{grade}{'u' if sem=='upper' else 'l'}.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(qs, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[补丁] {p} ({len(qs)} 题)")
    print(f"\n共生成 {made} 张图片")


if __name__ == "__main__":
    main()
