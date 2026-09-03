#!/usr/bin/env python3
"""校验本地化词条:两份 Localizable.strings 的 key 一致,且源码用到的串都登记过。

为什么需要它:这个项目的本地化是**两份手写 .strings**,加词条要同时改两个文件,全靠人眼
守着。漏改一边的后果不是编译错误,而是运行时静默 fallback 到 key 本身 —— 中文界面突然
冒出一句英文、或者英文界面里出现一句中文,只有真的切到那个语言才会发现。

对方仓库(lycrics_notch)用单文件 .xcstrings(自带每 key 翻译状态),那套要完整 Xcode 工具链
才能编译,这个项目只有 CLT。所以保留 .strings 格式,改用这个检查做机制守卫。

# 两道检查,以及第二道为什么是后来补的

1. **两份表之间**:key 集合一致、各自无重复 key。
2. **源码 → 表**:源码里每个 `L10n.t("字面量")` 都在表里登记过。

第 2 道 2026-08-17 补。在那之前只有第 1 道,而它有个盲区:**两边一起漏**的词条它一条都
查不出来 —— 两份表都没有,key 集合当然还是"完全一致",检查照样绿。真实后果是英文界面
原样显示中文。补这道检查时当场翻出 4 条一直躺着的历史遗留(「跟随播放器启动」那一组和
状态中继那条 help),而同一批新写的三条也是靠手工才发现的,不是靠这个脚本。

反方向(**表里有、源码没直接引用**)刻意不查:那些 key 大多是经变量、String(format:) 或
别处的 API 用掉的,还有一批是改过文案后留下的旧 key —— 报出来几十条噪声,会把真正致命的
第 2 道淹掉。多一条死 key 只是浪费几十字节,少一条翻译是用户能看见的 bug,两者不对等。
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
# L10n.t("字面量") —— 跟 ENTRY 用同一套转义感知,提取出来的形态才跟表里的 key 可比。
# 参数不是字面量的写法(L10n.t(someVar))匹配不上,自然跳过:那种的 key 只有运行时才知道,
# 静态查不了。\s* 让跨行写法也能命中。
CALL = re.compile(r'L10n\.t\(\s*"((?:[^"\\]|\\.)*)"')


def keys_of(path):
    return [m.group(1) for m in ENTRY.finditer(path.read_text(encoding="utf-8"))]


def source_literals():
    """源码里所有 L10n.t 的字面量 → {串: 第一处出现的位置}(位置用来报错时指路)。

    ⚠️ 只扫 `Sources/lyrimuse`,跟 selftest 里那条同款守卫**同一个范围**(见
    `Sources/lyrimuse-selftest/main.swift` 里「源码里每一个 L10n.t 都必须在 catalog 里」
    那一段的注释)。两条理由是那边原有的:全部调用点都在这个 target;LyrimuseCore 是纯
    逻辑库、不碰 UI 文案。

    收窄的第三条理由是这次(2026-09-02)补的:原来扫整个 `Sources/` 会把 **selftest 自己**
    也扫进来,而那个文件的注释里为了说明这条守卫,把一次调用整句写了出来
    (`// … 源码里每一个 L10n.t("字面量") 都必须在 catalog 里 …`,提交 e8de49a2)。
    这是**纯文本扫描**、不区分代码和注释,于是这个脚本会永久报一条红,点名一个叫
    「字面量」的键 —— 而这条红**修不掉**:往 catalog 里补「字面量」才是错的。
    一个永远失败、且只能靠无视来应付的检查,比没有检查更糟:它会训练人跳过这个脚本的
    输出,下次真有漏键混在里面就看不出来了。selftest 内置那条守卫早就把本文件排除在外
    (理由写在那边:"下面那条正则的模式串本身长得就像一次调用"),这个脚本漏了同一条。

    实测收窄不丢任何真实覆盖:`Sources/lyrimuse` 里 936 个字面量,跟 selftest 报的数字
    逐个对上;整个 `Sources/` 只多出一个,就是上面那个注释里的「字面量」。
    """
    found = {}
    for path in sorted((ROOT / "Sources/lyrimuse").rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in CALL.finditer(text):
            found.setdefault(
                m.group(1),
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
    # 第 0 道(2026-09-03):catalog 里每个键都必须有 en 和 zh-Hant —— 用户定的规则是新加文案必须把当前
    # 支持的语言都写全。生成物对拍看不出这个(缺译时生成脚本已经拒绝生成),这里直接查真源。
    import json
    catalog = json.loads((ROOT / "Localization/Localizable.xcstrings").read_text(encoding="utf-8"))
    for lang in ("en", "zh-Hant"):
        lacking = sorted(k for k, v in (catalog.get("strings") or {}).items()
                         if not ((((v or {}).get("localizations") or {}).get(lang) or {}).get("stringUnit") or {}).get("value"))
        if lacking:
            ok = False
            print(f"\n\u2717 catalog 里 {len(lacking)} 个键缺 {lang} 翻译(新加文案必须三语齐全,繁体规范见 Localization/zh-Hant-STYLE.md):")
            for k in lacking[:20]:
                print(f"    {k[:80]}")

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
