#!/usr/bin/env python3
"""校验本地化词条:三份生成的 Localizable.strings(zh-hans / en / zh-hant)key 一致,Localizable.xcstrings 里每个键
都有 en 和 zh-Hant,源码用到的串也都登记过。

漏一边的后果不是编译错误,而是运行时静默 fallback 到 key 本身 —— 英文界面里冒出一句中文,只有切到那个语言才会发现。
.strings 只能由 Localization/generate-strings.py 从 Localizable.xcstrings 生成,别手改。

# 两道主要检查

1. 表之间:key 集合一致、各自无重复 key。
2. 源码 → 表:源码里每个 `L10n.t("字面量")` 都在表里登记过。第 1 道查不出两边一起漏的词条(两份表都没有,
   key 集合照样"完全一致"),得靠这一道。

另查 catalog 里各语言值的格式参数跟键一致(规则在 generate-strings.py 的 format_arg_problems,这里导入它)。

反方向(表里有、源码没直接引用)刻意不查:那些 key 大多是经变量、String(format:) 或别处的 API 用掉的,还有改过
文案后留下的旧 key —— 报出来几十条噪声,会把真正致命的第 2 道淹掉。多一条死 key 只是浪费几十字节,少一条翻译是
用户能看见的 bug,两者不对等。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "Sources/lyrimuse/Resources"
FILES = {
    "zh-hans": BASE / "zh-hans.lproj/Localizable.strings",
    "en": BASE / "en.lproj/Localizable.strings",
    "zh-hant": BASE / "zh-hant.lproj/Localizable.strings",
}
# "key" = "value";  key/value 里都可能有转义引号,所以要感知反斜杠转义。
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
# L10n.t("字面量") / L10n.plural("字面量", …) —— 跟 ENTRY 用同一套转义感知,提取出来的形态才跟表里的 key 可比。
# 参数不是字面量的写法(L10n.t(someVar))匹配不上,自然跳过:那种的 key 只有运行时才知道,
# 静态查不了。字面量后面要紧跟 `)`(t)或 `,`(plural):`L10n.t("前缀" + name)` 的键是运行时拼出来的,
# 只取前半截去比会报一条修不掉的红。\s* 让跨行写法也能命中。两条正则跟 selftest 本地化守卫
# (Sources/lyrimuse-selftest/SourceContractTests.swift 的 callPattern / pluralPattern)逐字同款,改一边要改另一边。
CALL = re.compile(r'L10n\.t\(\s*"((?:[^"\\]|\\.)*)"\s*\)|L10n\.plural\(\s*"((?:[^"\\]|\\.)*)"\s*,')
# 单数变体的派生键(见 Localization/generate-strings.py 的 PLURAL_ONE_SUFFIX):只出现在写了 plural 变体的那种语言里,
# 对拍 key 集时不算,另查它的本键在同一张表里。
PLURAL_ONE_SUFFIX = "#one"


def keys_of(path):
    return [m.group(1) for m in ENTRY.finditer(path.read_text(encoding="utf-8"))]


def source_literals():
    """源码里所有 L10n.t 的字面量 → {串: 第一处出现的位置}(位置用来报错时指路)。

    只扫 `Sources/lyrimuse`,跟 selftest 里那条同款守卫同一个范围(见 `Sources/lyrimuse-selftest/SourceContractTests.swift`
    里「源码里每一个 L10n.t」那一段的注释):全部调用点都在这个 target;LyrimuseCore 是纯逻辑库、
    不碰 UI 文案。也不能扫整个 `Sources/`:这是纯文本扫描、不区分代码和注释,selftest 的注释里为了说明那条守卫
    整句写着一次调用,会永久报一条修不掉的红(点名一个叫「字面量」的键),一个只能靠无视来应付的检查比没有更糟。
    """
    found = {}
    for path in sorted((ROOT / "Sources/lyrimuse").rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in CALL.finditer(text):
            found.setdefault(
                m.group(1) if m.group(1) is not None else m.group(2),
                f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, m.start()) + 1}",
            )
    return found


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
    for lang in list(tables):
        derived = {k for k in tables[lang] if k.endswith(PLURAL_ONE_SUFFIX)}
        orphans = sorted(k for k in derived if k[:-len(PLURAL_ONE_SUFFIX)] not in tables[lang])
        if orphans:
            ok = False
            print(f"\n\u2717 {lang} 有单数变体的派生键却没有本键({len(orphans)} 条) —— 生成物只能由 generate-strings.py 生成:")
            for k in orphans[:20]:
                print(f"    {k}")
        tables[lang] = tables[lang] - derived
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
    # 第 0 道:catalog 里每个键都必须有 en 和 zh-Hant —— 规则是新加文案必须把当前
    # 支持的语言都写全。生成物对拍看不出这个(缺译时生成脚本已经拒绝生成),这里直接查真源。
    import json
    catalog = json.loads((ROOT / "Localization/Localizable.xcstrings").read_text(encoding="utf-8"))
    def has_value(entry, lang):
        loc = ((entry or {}).get("localizations") or {}).get(lang) or {}
        node = ((loc.get("variations") or {}).get("plural") or {}).get("other") or loc
        return bool((node.get("stringUnit") or {}).get("value"))

    for lang in ("en", "zh-Hant"):
        lacking = sorted(k for k, v in (catalog.get("strings") or {}).items() if not has_value(v, lang))
        if lacking:
            ok = False
            print(f"\n\u2717 catalog 里 {len(lacking)} 个键缺 {lang} 翻译(新加文案必须三语齐全,繁体规范见 Localization/zh-Hant-STYLE.md):")
            for k in lacking[:20]:
                print(f"    {k[:80]}")

    # 格式参数:各语言值的参数表(第几个参数、什么类型)要跟键一样。规则只写在 generate-strings.py 一处,这里导入它。
    import importlib.util
    spec = importlib.util.spec_from_file_location("generate_strings", ROOT / "Localization/generate-strings.py")
    generate_strings = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generate_strings)
    arg_problems = generate_strings.format_arg_problems(catalog.get("strings") or {}, catalog.get("sourceLanguage"))
    if arg_problems:
        ok = False
        print(f"\n✗ {len(arg_problems)} 处译文的格式参数跟键对不上 —— String(format:) 按译文取参数,类型错会崩溃或乱码:")
        for p in arg_problems[:20]:
            print(f"    {p}")
        if len(arg_problems) > 20:
            print(f"    …还有 {len(arg_problems) - 20} 处")

    # zh-hant 是跟 zh-hans 同一次生成的,key 集必须逐个相同;不同 = 有人手改了生成物。
    hant_mismatch = sorted(tables["zh-hant"] ^ tables["zh-hans"])
    if hant_mismatch:
        ok = False
        print(f"\n\u2717 zh-hant 与 zh-hans 的 key 集不一致({len(hant_mismatch)} 条) —— 生成物只能由 generate-strings.py 生成:")
        for k in hant_mismatch[:20]:
            print(f"    {k}")
    for lang, ks in dupes.items():
        ok = False
        print(f"\n\u2717 {lang} 有重复 key({len(ks)} 条) —— .strings 只保留最后一条,前面的静默失效:")
        for k in ks[:20]:
            print(f"    {k}")

    # 第 2 道:源码用到的串必须登记过。拿两份表的**并集**去比 —— 只在一份表里的
    # 那些,上面第 1 道已经单独报过,这里再报一遍只是同一个问题刷两次屏。
    registered = tables["zh-hans"] | tables["en"]
    literals = source_literals()
    unregistered = sorted(set(literals) - registered)
    print(f"  源码 L10n.t 字面量: {len(literals)} 条")
    if unregistered:
        ok = False
        print(f"\n\u2717 源码用了、两份表都没登记({len(unregistered)} 条) —— 英文界面会原样显示中文:")
        for k in unregistered[:20]:
            print(f"    {k[:70]}")
            print(f"      \u21b3 {literals[k]}")
        if len(unregistered) > 20:
            print(f"    …还有 {len(unregistered) - 20} 条")

    print("\n\u2713 三份 .strings 的 key 一致,源码用到的串也都登记过" if ok
          else "\n上面的差异会造成运行时静默 fallback,请补齐")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
