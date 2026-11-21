#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/install/studyassist"
DEST="$OUT/studyassist.koplugin"

if [[ ! -f "$ROOT/main.lua" ]]; then
    echo "missing $ROOT/main.lua" >&2
    exit 1
fi

rm -rf "$DEST" "$OUT/studyassist.koplugin.zip"
mkdir -p "$DEST"
# 只装设备端真正会读的东西：docs/ 是给人看的、tools/ 是开发脚本（生成器/校验/模拟器），
# 都不进包；data/**/*.json 里的 "tools/studyassist/xxx.py" 只是 provenance 标注，不是路径。
cp -R "$ROOT/main.lua" "$ROOT/_meta.lua" "$ROOT/core" "$ROOT/ui" "$ROOT/data" "$ROOT/README.md" "$DEST"
find "$DEST" \( -name '*.orig' -o -name '*.swp' -o -name '.DS_Store' \
    -o -name '*.bak*' -o -name '*.old' -o -name '.luarc.json' \) -delete >/dev/null
( cd "$OUT" && zip -qr studyassist.koplugin.zip studyassist.koplugin )
echo "wrote $OUT/studyassist.koplugin.zip"
echo "   $(stat -f%z "$OUT/studyassist.koplugin.zip" 2>/dev/null || stat -c%s "$OUT/studyassist.koplugin.zip") 字节, \
$(unzip -l "$OUT/studyassist.koplugin.zip" | tail -1 | awk '{print $2}') 个文件"
