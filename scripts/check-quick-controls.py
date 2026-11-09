#!/usr/bin/env python3
"""新加的设置项,要写明菜单栏面板和灵动岛要不要跟着加 / 改按钮。见 14 章决策 184。

台账 shared/quick-controls-ledger.json:
- baseline:台账建立时设置搜索目录里已有的设置,不逐条要求。
- reviewed:之后新加(或改名)的设置,每条写
    {"panel": [面板格子 id…], "panelQuick": [面板长按快捷设置的去处…], "notch": [灵动岛快捷按钮 id…], "note": "加了什么 / 为什么不加"}
  三个数组可以都空(不加按钮),note 必填。id 取 MenuBarPanelLayout.Tile、PanelQuickTarget、NotchQuickAction 的值。
设置的键是设置搜索目录(shared/settings-catalog.json)里一条的「路径 › 标题」。

用法(仓库根目录):
  python3 scripts/check-quick-controls.py            检查;有没登记的设置、登记了却已不在目录里的键、写错的 id 就以 1 退出
  python3 scripts/check-quick-controls.py --pending  把没登记的设置打成 reviewed 骨架(JSON),填好 note 和 id 贴进台账
"""
import json
import re
import sys

CATALOG = "shared/settings-catalog.json"
LEDGER = "shared/quick-controls-ledger.json"
TILES = "lyrimuse/Sources/LyrimuseCore/Util/MenuBarPanelLayout.swift"
NOTCH = "lyrimuse/Sources/LyrimuseCore/Models/NotchQuickAction.swift"
QUICK = "lyrimuse/Sources/lyrimuse/MenuBar/MenuBarPanelQuickSettings.swift"


def enum_values(path, enum):
    """`enum <名>` 里各 case 的原始值(写了 = "x" 取 x,没写取 case 名)。"""
    src = open(path, encoding="utf-8").read()
    start = src.index(f"enum {enum}")
    line_start = src.rfind("\n", 0, start) + 1
    indent = len(src[line_start:start]) - len(src[line_start:start].lstrip(" "))
    body = src[src.index("{", start) + 1:]
    depth, end = 1, 0
    for i, ch in enumerate(body):
        depth += ch == "{"
        depth -= ch == "}"
        if depth == 0:
            end = i
            break
    values = set()
    for m in re.finditer(r"^ {%d}case\s+([^\n/]+)" % (indent + 4), body[:end], re.M):
        for part in m.group(1).split(","):
            part = part.strip()
            mm = re.match(r"(\w+)(?:\([^)]*\))?(?:\s*=\s*\"([^\"]+)\")?", part)
            if mm:
                values.add(mm.group(2) or mm.group(1))
    return values


def catalog_keys():
    entries = json.load(open(CATALOG, encoding="utf-8"))["entries"]
    return [" › ".join(e["path"] + [e["title"]]) for e in entries]


def main(argv):
    keys = catalog_keys()
    ledger = json.load(open(LEDGER, encoding="utf-8"))
    baseline, reviewed = set(ledger["baseline"]), ledger["reviewed"]
    pending = [k for k in keys if k not in baseline and k not in reviewed]
    if "--pending" in argv:
        skeleton = {k: {"panel": [], "panelQuick": [], "notch": [], "note": ""} for k in pending}
        print(json.dumps(skeleton, ensure_ascii=False, indent=2))
        return 0
    problems = []
    for k in pending:
        problems.append(f"没登记: {k}")
    current = set(keys)
    for k in sorted((baseline | set(reviewed)) - current):
        problems.append(f"目录里已没有(删了或改名了,从台账里删掉): {k}")
    valid = {"panel": enum_values(TILES, "Tile"), "panelQuick": enum_values(QUICK, "PanelQuickTarget"),
             "notch": enum_values(NOTCH, "NotchQuickAction")}
    for k, v in reviewed.items():
        if not str(v.get("note", "")).strip():
            problems.append(f"note 没写: {k}")
        for field, ok in valid.items():
            for x in v.get(field, []):
                if x not in ok:
                    problems.append(f"{field} 里没有 {x!r}: {k}")
    if problems:
        print("菜单栏面板 / 灵动岛按钮台账(" + LEDGER + "):", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        if pending:
            print("新设置先想一下面板格子、面板长按快捷设置、灵动岛快捷按钮要不要加或改,再登记:"
                  "python3 scripts/check-quick-controls.py --pending 出骨架。", file=sys.stderr)
        return 1
    print(f"面板 / 灵动岛按钮台账:通过({len(baseline)} 条基线,{len(reviewed)} 条已登记)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
