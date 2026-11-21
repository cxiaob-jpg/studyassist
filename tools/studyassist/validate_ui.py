#!/usr/bin/env python3
"""Validate the ui/mainview.lua + ui/pages/*.lua split.

The page split relies on three invariants that Lua cannot check at compile time:

1. every module listed in mainview's PAGE_MODULES exists, and nothing in
   ui/pages/ is left unregistered (a forgotten module = screen silently gone);
2. no method name is mounted twice (mainview's mount_page() errors at runtime,
   but we want to catch it in CI, not on a Kindle);
3. every `self:method()` call resolves to a defined method (the split removed
   the old file-local scope, so a typo is now a nil call at runtime).

Also verifies that internal require() paths resolve, and lua-compiles every
file with a Lua 5.1 VM when lupa is available.
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
MAINVIEW = PLUGIN / "ui" / "mainview.lua"
PAGES = PLUGIN / "ui" / "pages"
# 页面模块只依赖 common.lua（纯常量/纯函数），它本身不挂到 MainView 上
SHARED = "common.lua"

errors = []
warnings = []


def strip_comments(src):
    """Remove -- comments and --[[ ]]-- blocks so keyword scanning sees code only."""
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    src = re.sub(r"--[^\n]*", "", src)
    return src


def page_files():
    return sorted(p for p in PAGES.glob("*.lua") if p.name != SHARED)


def check_registry():
    src = strip_comments(MAINVIEW.read_text(encoding="utf-8"))
    m = re.search(r"local PAGE_MODULES = \{(.*?)\}", src, re.S)
    if not m:
        errors.append("ui/mainview.lua: PAGE_MODULES table not found")
        return []
    registered = re.findall(r'"([^"]+)"', m.group(1))
    on_disk = [p.stem for p in page_files()]

    for name in registered:
        if name not in on_disk:
            errors.append(f"ui/mainview.lua: PAGE_MODULES lists '{name}' but ui/pages/{name}.lua is missing")
    for name in on_disk:
        if name not in registered:
            errors.append(f"ui/pages/{name}.lua exists but is not in PAGE_MODULES (screen would never mount)")

    dupes = sorted({n for n in registered if registered.count(n) > 1})
    for name in dupes:
        errors.append(f"ui/mainview.lua: PAGE_MODULES lists '{name}' more than once")
    return registered


def collect_methods():
    """Return {method_name: [defining files]} for mainview + every page."""
    owners = defaultdict(list)
    src = strip_comments(MAINVIEW.read_text(encoding="utf-8"))
    for name in re.findall(r"function\s+MainView[.:](\w+)", src):
        owners[name].append("ui/mainview.lua")
    for path in page_files():
        src = strip_comments(path.read_text(encoding="utf-8"))
        for name in re.findall(r"function\s+M[.:](\w+)", src):
            owners[name].append(f"ui/pages/{path.name}")
    return owners


def check_duplicates(owners):
    for name, files in sorted(owners.items()):
        if len(files) > 1:
            errors.append(f"method '{name}' defined in multiple files: {', '.join(files)} "
                          f"(mount_page() would abort at load time)")


def check_calls(owners):
    """Every self:foo() call must have a definition somewhere."""
    callers = defaultdict(list)
    for path in [MAINVIEW] + page_files():
        src = strip_comments(path.read_text(encoding="utf-8"))
        label = "ui/mainview.lua" if path == MAINVIEW else f"ui/pages/{path.name}"
        for name in set(re.findall(r"\bself:(\w+)\s*\(", src)):
            callers[name].append(label)

    for name, files in sorted(callers.items()):
        if name not in owners:
            errors.append(f"self:{name}() called from {', '.join(sorted(set(files)))} but never defined "
                          f"(runtime nil call)")

    # 定义但从未被 self: 调用 → 可能是死代码，也可能是留给外部调用的入口，只提示
    unset = sorted(set(owners) - set(callers))
    if unset:
        warnings.append(f"{len(unset)} 个方法没有 self: 调用点（可能是外部入口或死代码）: " + ", ".join(unset[:10]))


def check_requires():
    known = set()
    for p in PLUGIN.rglob("*.lua"):
        if ".git" in p.parts:
            continue
        rel = p.relative_to(PLUGIN).with_suffix("")
        # require("x/init") 与 require("x") 都可能出现，两种写法都登记
        known.add(str(rel))
        if rel.name == "init":
            known.add(str(rel.parent))

    # 插件自己的 ui/ 命名空间：ui/ 下直接的文件 + pages/ 子目录。
    # 其余 ui/xxx 都是 KOReader 框架模块（ui/widget/...、ui/size、ui/uimanager...），
    # 本机没有框架源码，无法也不该校验，直接放过。
    own_ui = {p.stem for p in (PLUGIN / "ui").glob("*.lua")}
    own_ui.add("pages")

    targets = [MAINVIEW] + page_files()
    for path in targets:
        src = strip_comments(path.read_text(encoding="utf-8"))
        label = "ui/mainview.lua" if path == MAINVIEW else f"ui/pages/{path.name}"
        for mod in re.findall(r'require\("([^"]+)"\)', src):
            if mod.startswith("core."):
                pass  # 插件内部模块，必须能解析
            elif mod.startswith("ui/"):
                if mod.split("/")[1] not in own_ui:
                    continue  # KOReader 框架模块
            else:
                continue  # util / gettext / device / ffi/...
            if mod.replace(".", "/") not in known and mod not in known:
                errors.append(f"{label}: require(\"{mod}\") does not resolve to a file in the plugin")


def check_syntax():
    try:
        from lupa import lua51
    except Exception:
        warnings.append("跳过 Lua 语法检查（未安装 lupa：pip3 install lupa）")
        return
    runtime = lua51.LuaRuntime()
    loadstring = runtime.eval(
        "function(s, n) local f, e = loadstring(s, n); if f then return true else return tostring(e) end end"
    )
    bad = 0
    for path in sorted(PLUGIN.rglob("*.lua")):
        if ".git" in path.parts:
            continue
        ok = loadstring(path.read_text(encoding="utf-8", errors="replace"), str(path))
        if ok is not True:
            errors.append(f"{path.relative_to(PLUGIN)}: {ok}")
            bad += 1
    print(f"lua 语法检查: {sum(1 for _ in PLUGIN.rglob('*.lua'))} 个文件, {bad} 个失败")


def main():
    check_registry()
    owners = collect_methods()
    check_duplicates(owners)
    check_calls(owners)
    check_requires()
    check_syntax()

    pages = len(page_files())
    print(f"UI SPLIT: mainview {len(MAINVIEW.read_text(encoding='utf-8').splitlines())} 行, "
          f"{pages} 个页面模块, {len(owners)} 个挂载方法")

    if warnings:
        print(f"WARN ({len(warnings)}):")
        for w in warnings:
            print("   .", w)
    if errors:
        print(f"UI ERRORS ({len(errors)}):")
        for e in errors[:60]:
            print(" -", e)
        sys.exit(1)
    print("UI VALIDATION OK")


if __name__ == "__main__":
    main()
