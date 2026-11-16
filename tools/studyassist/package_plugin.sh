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
cp -R "$ROOT/main.lua" "$ROOT/_meta.lua" "$ROOT/core" "$ROOT/ui" "$ROOT/data" "$ROOT/README.md" "$ROOT/docs" "$DEST"
find "$DEST" \( -name '*.orig' -o -name '*.swp' -o -name '.DS_Store' \) -delete
( cd "$OUT" && zip -qr studyassist.koplugin.zip studyassist.koplugin )
echo "wrote $OUT/studyassist.koplugin.zip"
