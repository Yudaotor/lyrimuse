#!/usr/bin/env python3
"""把 Localizable.xcstrings(唯一真源)生成各语言包的 Localizable.strings 与 InfoPlist.strings(入库的编译产物)。

用法:改完 Localizable.xcstrings 后跑一次:
    python3 Localization/generate-strings.py
然后把 catalog 和生成的 .strings 一起提交。selftest 有守卫:两边不一致会红。

为什么生成物也入库,而不是构建时现编译:
 - `swift build` 不编译 .xcstrings;能编译它的 xcstringstool 只在完整 Xcode 里、
   CLT 没有 —— 塞进 build.sh 会逼着从源码构建的用户装十几 GB 的 Xcode。
 - 运行时(L10n.swift)读的就是 .lproj/Localizable.strings 明文文件(手动查找,
   绕 SwiftPM 的 zh-Hans→zh-hans 小写化 bug,见 L10n.swift 注释),生成物入库后
   构建流程一个字节都不用改。
只有改翻译的人需要跑这个脚本 —— 它是纯标准库 python,连 Xcode 都不用。

catalog 格式即 Xcode 15 String Catalog 的 JSON:sourceLanguage zh-Hans(这个项目
以中文原文作键),每键 extractionState="manual" —— 我们的取词函数是自定义的
L10n.t(),Xcode 的自动提取扫不到调用点,不标 manual 的话它会把所有键当成"代码里
没人用"给标记成 stale。
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(ROOT, "Localizable.xcstrings")
TARGETS = {
    # catalog 语言码 → 仓库里 .lproj 目录名(小写是既有布局,别"修"它:L10n.swift 和
    # build.sh 都按这个名字找)
    "zh-Hans": "zh-hans.lproj",
    "en": "en.lproj",
    "zh-Hant": "zh-hant.lproj",
}
# 缺翻译时允许回退到源语言(简体)的语言。**当前为空**:规则是「新加文案必须把
# 当前支持的语言都写全」(见 AGENTS.md「容易踩的具体坑 → 本地化」),所以 zh-Hant 跟 en 一样缺译就
# 失败并列出缺的键。加繁体那天曾短暂开过回退,让 1196 条译文写入前树不红;译文齐了就关掉。
FALLBACK_TO_SOURCE = set()
OUT_DIR = os.path.join(ROOT, "..", "Sources", "lyrimuse", "Resources")
# Info.plist 里按界面语言显示的键 → catalog 里那一条的键(简体原文)。每个语言包生成一份 InfoPlist.strings,
# 系统弹权限框时按它取用途说明。英文原文同时写在 build.sh 的 Info.plist 里(没有对应语言包时系统用那份),
# 两处必须一致,selftest 本地化守卫对着查。
INFO_PLIST_KEYS = {
    "NSAppleEventsUsageDescription": "Lyrimuse 需要读取播放器和浏览器中正在播放的歌曲，才能显示同步歌词。",
}
# 按数量分单复数:某语言写成 Xcode 的 plural 变体(variations.plural 下 one / other 两条)时,other 写进这个键,
# one 写进「键 + PLURAL_ONE_SUFFIX」。L10n.plural(_:count:) 数量为 1 时先查后者,查不到(这个语言没分单复数)
# 用前者。.strings 不带复数规则,所以只认 one / other 两档(英文的规则),数量由调用方传,不看格式参数。
# 后缀跟 L10n.swift、selftest 本地化守卫、scripts/check_strings_parity.py 三处必须一致。
PLURAL_ONE_SUFFIX = "#one"
FORMAT_SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfeEgGcCsSpaA%]")
# 跨语言格式参数:各语言的值(含 plural 的 one / other)要跟键(简体原文)用同一组参数 —— 第几个参数、什么类型。
# 调用方按键的参数表传值、String(format:) 却按译文里的格式符取:译文把 %d 写成 %@ 会把整数当对象指针解引用(崩溃),
# 少写、多写或类型写错会错位、读到垃圾。%% 是字面百分号,不算参数。不认空格标志(`% d`):译文里「25% of」这种
# 字面百分号会被它当成参数。长度修饰(%d / %ld / %lld)只影响取多宽,同属整数,不区分。
# 同一份规则在 scripts/check_strings_parity.py(导入本函数)和 selftest 本地化守卫(Swift 实现)里各跑一遍。
ARG_SPEC = re.compile(r"%(?:(\d+)\$)?[-+0#]*\d*(?:\.\d+)?(?:hh|ll|h|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])")
ARG_KIND = {"@": "对象"}
ARG_KIND.update({c: "整数" for c in "dDiuUxXoO"})
ARG_KIND.update({c: "浮点" for c in "feEgGaA"})
ARG_KIND.update({c: "字符" for c in "cC"})
ARG_KIND.update({c: "C 字符串" for c in "sS"})
ARG_KIND["p"] = "指针"

INFO_PLIST_HEADER = """\
/* 由 Localization/Localizable.xcstrings 生成(键表见 generate-strings.py 的 INFO_PLIST_KEYS)—— 不要手改这个文件。 */

"""

HEADER = """\
/* 由 Localization/Localizable.xcstrings 生成 —— 不要手改这个文件。
   改词条:编辑 catalog(可用 Xcode 的 String Catalog 编辑器或直接改 JSON),
   然后跑 python3 Localization/generate-strings.py 重新生成,两个文件一起提交。
   selftest 会校验 catalog 与生成物一致。 */

"""


# catalog 的**序列化风格**:Xcode 写出来就是 `"key" : value`(冒号前有空格),键按插入序。
XCODE_SEPARATORS = (",", " : ")


def head_key_order():
    """HEAD 里那份 catalog 的键序。拿不到(新仓/没入库/不在 git 里)返回 None。

    只用于**判断有没有被整体重排**和 --normalize 时把键序放回去 —— 键序本身不影响
    任何行为,影响的只有 diff 可读性,所以拿不到就跳过这一项,不让脚本因此失败。
    """
    try:
        r = subprocess.run(["git", "-C", ROOT, "show", "HEAD:./Localizable.xcstrings"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return list(json.loads(r.stdout).get("strings", {}).keys())
    except Exception:
        return None


def reordered_against_head(catalog):
    """当前键序跟 HEAD 相比是不是被整体重排过。None = 无从判断。

    只比**两边都有**的那些键的相对次序;新增键排在哪儿不算重排。
    """
    order = head_key_order()
    if not order:
        return None
    cur = list(catalog.get("strings", {}).keys())
    common = set(order) & set(cur)
    return [k for k in order if k in common] != [k for k in cur if k in common]


def canonical_text(catalog) -> str:
    """按 Xcode 的写法把 catalog 吐成文本。键序沿用传进来的 dict 顺序(Python 3.7+ 保序)。"""
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=XCODE_SEPARATORS) + "\n"


def check_canonical_form(raw: str, catalog, normalize: bool) -> int:
    """catalog 的序列化风格必须跟 Xcode 一致。用 Python 的默认写法回写这个文件 ——

        d["strings"] = dict(sorted(d["strings"].items()))
        json.dump(d, f, ensure_ascii=False, indent=2)      # 少了 separators

    —— 会把冒号前的空格去掉、并把一千多个键全部重排:内容一个字没变,git diff 却是几万行,真正新增的词条淹没在里面;
    而且全程静默(三语齐、check_strings_parity.py 绿、selftest 全过)。默认写法就是"看起来最正常"的那个,口头约定
    拦不住,所以闸门放在人人必跑的这一步。

    两道判据,都不做字符串启发式:
      ① 排版:按 Xcode 的分隔符重新吐一遍、跟盘上逐字节比;
      ② 键序:跟 `git show HEAD:` 那份比两边共有键的相对次序。
    缺一不可 —— 只带 separators 却把键重排的写法能过①(它的往返结果跟自己一致),得靠②抓。

    拿不到 HEAD 时②整个跳过(新仓 / 文件没入库 / 不在 git 里,`head_key_order` 返回 None → 直接放行),
    此时重排查不出来。这是有意的取舍:键序不影响任何行为、只影响 diff 可读性,不该让脚本在新仓里失败。
    """
    reordered = reordered_against_head(catalog)
    want = canonical_text(catalog)
    if want == raw and not reordered:
        return 0
    if normalize:
        if reordered:
            # 把两边都有的键放回 HEAD 的次序,新增键按字典序追加到末尾 —— 这样 diff
            # 只剩真实增删。 只动次序,一个键一个值都不改(下面的等价断言兜着)。
            order = head_key_order() or []
            cur = catalog["strings"]
            fixed = {k: cur[k] for k in order if k in cur}
            for k in sorted(set(cur) - set(fixed)):
                fixed[k] = cur[k]
            catalog["strings"] = fixed
            want = canonical_text(catalog)
        # 只改排版,内容必须完全等价,不等价就宁可不写。
        assert json.loads(want) == json.loads(raw), "规范化前后内容不等价 —— 拒绝写入"
        with open(CATALOG, "w", encoding="utf-8") as f:
            f.write(want)
        print("\u2713 catalog 已就地规范化成 Xcode 风格" +
              ("、键序已放回 HEAD 的次序" if reordered else "") + "(内容未变)")
        return 0
    # 只列**真的**出问题的那几项:两种毛病会各自单独出现,混着说会把人引到错的地方去查。
    problems = []
    if want != raw:
        problems.append(
            "排版不是 Xcode 的写法 —— 应为 `\"key\" : value`(冒号前有空格),"
            "而 json.dump(..., indent=2) 的默认写法是 `\"key\": value`")
    if reordered:
        problems.append(
            "键序被整体重排过(跟 HEAD 比)—— 每个键都会显示成「删一行 + 加一行」,"
            "多半是 sorted(d[\"strings\"].items()) 干的")
    print(
        "\u2717 Localizable.xcstrings 的序列化不规范 —— 它会让 git diff 从几十行炸成几万行:",
        file=sys.stderr)
    for p in problems:
        print("  \u2022 " + p, file=sys.stderr)
    print(
        "  就地修正(只改排版和次序、内容一个字不动):\n"
        "      python3 Localization/generate-strings.py --normalize\n"
        "  以后用 Python 改这个文件,记得带 separators=(',', ' : ') 且别排序。",
        file=sys.stderr,
    )
    return 1


def unit_value(node):
    return ((node or {}).get("stringUnit") or {}).get("value")


def forms(entry, lang):
    """某语言的 (值, 单数值)。写成 plural 变体时值取 other、单数值取 one;没写成变体时单数值是 None。"""
    loc = ((entry or {}).get("localizations") or {}).get(lang) or {}
    plural = (loc.get("variations") or {}).get("plural")
    if plural is None:
        return unit_value(loc), None
    return unit_value(plural.get("other")), unit_value(plural.get("one"))


def plural_problems(strings, source_lang):
    """plural 变体写错的地方:源语言不分单复数(值就是键);只认 one / other 两条且都要有;两条的格式符要一样
    (同一组参数填进哪一条都对得上);派生出来的键不能跟已有的键撞。"""
    out = []
    for key, entry in strings.items():
        if key.endswith(PLURAL_ONE_SUFFIX):
            out.append(f"{key[:60]}:键不能以 {PLURAL_ONE_SUFFIX} 结尾(那是单数变体的派生键)")
        for lang, loc in ((entry or {}).get("localizations") or {}).items():
            plural = ((loc or {}).get("variations") or {}).get("plural")
            if plural is None:
                continue
            other, one = unit_value(plural.get("other")), unit_value(plural.get("one"))
            if lang == source_lang:
                out.append(f"{key[:60]}:{lang} 是源语言,值就是键,不写 plural 变体")
            elif set(plural) != {"one", "other"} or not other or not one:
                out.append(f"{key[:60]}:{lang} 的 plural 变体要有且只有 one / other 两条")
            elif sorted(FORMAT_SPEC.findall(one)) != sorted(FORMAT_SPEC.findall(other)):
                out.append(f"{key[:60]}:{lang} 的 one / other 格式符不一样")
    return out


def arg_signature(s):
    """格式串的参数表 {第几个参数: 类型}。不带序号的格式符按出现次序编号。同一个序号写成两种类型时返回 None。"""
    sig, nxt = {}, 1
    for m in ARG_SPEC.finditer(s):
        pos, conv = m.group(1), m.group(2)
        if conv == "%":
            continue
        if pos:
            idx = int(pos)
        else:
            idx, nxt = nxt, nxt + 1
        kind = ARG_KIND[conv]
        if sig.get(idx, kind) != kind:
            return None
        sig[idx] = kind
    return sig


def describe_signature(sig):
    if sig is None:
        return "同一个参数写了两种类型"
    if not sig:
        return "无参数"
    return "、".join(f"第 {i} 个{sig[i]}" for i in sorted(sig))


def format_arg_problems(strings, source_lang):
    """各语言值的参数表跟键不一样的地方。源语言的值就是键(另有一道检查),不比。"""
    out = []
    for key, entry in strings.items():
        want = arg_signature(key)
        for lang, loc in sorted(((entry or {}).get("localizations") or {}).items()):
            if lang == source_lang:
                continue
            plural = ((loc or {}).get("variations") or {}).get("plural")
            if plural is None:
                values = [("", unit_value(loc))]
            else:
                values = [(f" {form}", unit_value(plural.get(form))) for form in ("one", "other")]
            for form, value in values:
                if value is None:
                    continue
                got = arg_signature(value)
                if want is None or got != want:
                    out.append(f"{key[:60]}:{lang}{form} 是「{describe_signature(got)}」,键是「{describe_signature(want)}」")
    return out


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def main() -> int:
    normalize = "--normalize" in sys.argv[1:]
    with open(CATALOG, encoding="utf-8") as f:
        raw = f.read()
    catalog = json.loads(raw)
    if check_canonical_form(raw, catalog, normalize) != 0:
        return 1
    if catalog.get("sourceLanguage") != "zh-Hans":
        print(f"sourceLanguage 应为 zh-Hans,实际是 {catalog.get('sourceLanguage')!r}", file=sys.stderr)
        return 1
    strings = catalog.get("strings") or {}
    if not strings:
        print("catalog 里一个键都没有 —— 拒绝生成空文件覆盖现有翻译", file=sys.stderr)
        return 1
    # 简体就是键本身:显式 zh-Hans 值和键不一致时,界面显示的是这个值而不是键,
    # 改键(源码字面量)之后界面照旧显示旧文案。改简体文案要连键一起改,这里直接失败。
    stale = [k for k, e in strings.items()
             if (((e or {}).get("localizations") or {}).get("zh-Hans") or {}).get("stringUnit", {}).get("value", k) != k]
    if stale:
        print(f"\u2717 zh-Hans 有 {len(stale)} 条显式值和键不一致(简体就是键本身,值要等于键):", file=sys.stderr)
        for key in sorted(stale)[:20]:
            print(f"    {key[:80]}", file=sys.stderr)
        if len(stale) > 20:
            print(f"    …还有 {len(stale) - 20} 条", file=sys.stderr)
        return 1
    unknown = [k for k in INFO_PLIST_KEYS.values() if k not in strings]
    if unknown:
        print(f"\u2717 INFO_PLIST_KEYS 指向的键 catalog 里没有:", file=sys.stderr)
        for key in unknown:
            print(f"    {key[:80]}", file=sys.stderr)
        return 1
    problems = plural_problems(strings, catalog["sourceLanguage"])
    if problems:
        print(f"\u2717 plural 变体有 {len(problems)} 处写得不对:", file=sys.stderr)
        for p in problems[:20]:
            print(f"    {p}", file=sys.stderr)
        return 1
    arg_problems = format_arg_problems(strings, catalog["sourceLanguage"])
    if arg_problems:
        print(f"✗ {len(arg_problems)} 处译文的格式参数跟键对不上(String(format:) 按译文取参数,类型错会崩溃或乱码):",
              file=sys.stderr)
        for p in arg_problems[:20]:
            print(f"    {p}", file=sys.stderr)
        if len(arg_problems) > 20:
            print(f"    …还有 {len(arg_problems) - 20} 处", file=sys.stderr)
        return 1
    for lang, lproj in TARGETS.items():
        lines = [HEADER]
        fallback_count = 0
        missing = []
        for key in sorted(strings):
            entry = strings[key] or {}
            value, one = forms(entry, lang)
            if value is None:
                # 源语言允许省略(值即键,Xcode 的惯例);其它语言缺翻译就大声失败,
                # 别静默生成一个回退键 —— 那会让"缺翻译"从可见问题变成隐形问题。
                if lang == catalog["sourceLanguage"]:
                    value = key
                elif lang in FALLBACK_TO_SOURCE:
                    src = ((entry.get("localizations") or {}).get(catalog["sourceLanguage"]) or {}).get("stringUnit") or {}
                    value = src.get("value") or key
                    fallback_count += 1
                else:
                    missing.append(key)
                    continue
            lines.append(f'"{escape(key)}" = "{escape(value)}";\n')
            if one is not None:
                lines.append(f'"{escape(key + PLURAL_ONE_SUFFIX)}" = "{escape(one)}";\n')
        out = os.path.join(OUT_DIR, lproj, "Localizable.strings")
        with open(out, "w", encoding="utf-8") as f:
            f.writelines(lines)
        if missing:
            print(f"\u2717 {lang} 缺 {len(missing)} 条翻译(新加文案必须把 en / zh-Hant 都写全,繁体规范见 Localization/zh-Hant-STYLE.md):", file=sys.stderr)
            for key in missing[:20]:
                print(f"    {key[:80]}", file=sys.stderr)
            if len(missing) > 20:
                print(f"    …还有 {len(missing) - 20} 条", file=sys.stderr)
            return 1
        info_lines = [INFO_PLIST_HEADER]
        for plist_key, catalog_key in INFO_PLIST_KEYS.items():
            value, _ = forms(strings[catalog_key], lang)
            info_lines.append(f'"{plist_key}" = "{escape(value if value is not None else catalog_key)}";\n')
        info_out = os.path.join(OUT_DIR, lproj, "InfoPlist.strings")
        with open(info_out, "w", encoding="utf-8") as f:
            f.writelines(info_lines)
        suffix = f"(其中 {fallback_count} 条暂回退简体)" if fallback_count else ""
        # 打完整相对路径,不要只打 `zh-hans.lproj` —— 产物不在 Localization/ 下面,而在
        # Sources/lyrimuse/Resources/ 下,只报 lproj 名会让人以为它跟 catalog 同目录。
        # 实测两个会话**各自独立**把路径记成 Localization/*.lproj/,都是被这行误导的。
        print(f"{os.path.relpath(out, os.path.join(ROOT, '..'))}: {len(strings)} 键{suffix}")
        print(f"{os.path.relpath(info_out, os.path.join(ROOT, '..'))}: {len(INFO_PLIST_KEYS)} 键")
    return 0


if __name__ == "__main__":
    sys.exit(main())
