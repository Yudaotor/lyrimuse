#!/usr/bin/env python3
"""校验两份 Localizable.strings 的 key 集合完全一致。

为什么需要它:这个项目的本地化是**两份手写 .strings**,加词条要同时改两个文件,全靠人眼
守着。漏改一边的后果不是编译错误,而是运行时静默 fallback 到 key 本身 —— 中文界面突然
冒出一句英文、或者英文界面里出现一句中文,只有真的切到那个语言才会发现。

对方仓库(lycrics_notch)用单文件 .xcstrings(自带每 key 翻译状态),那套要完整 Xcode 工具链
才能编译,这个项目只有 CLT。所以保留 .strings 格式,改用这个检查做机制守卫。
"""
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent / "Sources/lyrimuse/Resources"
FILES = {
    "zh-hans": BASE / "zh-hans.lproj/Localizable.strings",
    "en": BASE / "en.lproj/Localizable.strings",
}
# "key" = "value";  key/value 里都可能有转义引号,所以要感知反斜杠转义。
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)


def keys_of(path):
    return [m.group(1) for m in ENTRY.finditer(path.read_text(encoding="utf-8"))]


def main():
    tables, dupes = {}, {}
    for lang, path in FILES.items():
        if not path.exists():
            print(f"\u2717 缺文件: {path}")
            return 1
        ks = keys_of(path)
        print(f"  {lang}: {len(ks)} 条")
        seen, dup = set(), set()
        for k in ks:
            (dup if k in seen else seen).add(k)
        if dup:
            dupes[lang] = sorted(dup)
        tables[lang] = seen

    ok = True
    only_zh = sorted(tables["zh-hans"] - tables["en"])
    only_en = sorted(tables["en"] - tables["zh-hans"])
    if only_zh:
        ok = False
        print(f"\n\u2717 只在 zh-hans 有、en 缺失({len(only_zh)} 条) —— 英文界面会显示中文原文:")
        for k in only_zh[:20]:
            print(f"    {k}")
        if len(only_zh) > 20:
            print(f"    …还有 {len(only_zh) - 20} 条")
    if only_en:
        ok = False
        print(f"\n\u2717 只在 en 有、zh-hans 缺失({len(only_en)} 条):")
        for k in only_en[:20]:
            print(f"    {k}")
    for lang, ks in dupes.items():
        ok = False
        print(f"\n\u2717 {lang} 有重复 key({len(ks)} 条) —— .strings 只保留最后一条,前面的静默失效:")
        for k in ks[:20]:
            print(f"    {k}")

    print("\n\u2713 两份 .strings 的 key 完全一致" if ok else "\n上面的差异会造成运行时静默 fallback,请补齐")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
