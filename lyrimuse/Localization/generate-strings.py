#!/usr/bin/env python3
"""把 Localizable.xcstrings(唯一真源)生成两份 Localizable.strings(入库的编译产物)。

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
# 缺翻译时允许回退到源语言(简体)的语言。**当前为空**:2026-09-03 用户定的规则是「新加文案必须把
# 当前支持的语言都写全」(见 AGENTS.md「容易踩的具体坑 → 本地化」),所以 zh-Hant 跟 en 一样缺译就
# 失败并列出缺的键。加繁体那天曾短暂开过回退,让 1196 条译文写入前树不红;译文齐了就关掉。
FALLBACK_TO_SOURCE = set()
OUT_DIR = os.path.join(ROOT, "..", "Sources", "lyrimuse", "Resources")

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
    """catalog 的序列化风格必须跟 Xcode 一致 —— 这不是洁癖,是防一颗静默的 diff 炸弹。

    2026-09-12 实测:用 Python 的**默认**写法回写这个文件 ——

        d["strings"] = dict(sorted(d["strings"].items()))
        json.dump(d, f, ensure_ascii=False, indent=2)      # 少了 separators

    —— 会把冒号前的空格去掉、并把一千多个键全部重排。**内容一个字没变**,
    `git diff` 却是 **4 万行**,当天真实新增的那几十条彻底淹没在里面。

    最要命的是它**全程静默**:三语齐、check_strings_parity.py 绿、selftest 全过,
    只有 review 的人看到 4 万行才会发现。那次是两个会话各自用了同一个默认写法,
    其中一个自己都没察觉 —— 文件当时已经是错格式,他写回去恰好一致、零额外 diff。
    这正是口头约定拦不住的形状:默认写法就是"看起来最正常"的那个,写的人不觉得
    自己在做特殊的事;后果要等到 git diff 才显现,而多数人加完键只跑生成脚本和 parity。
    所以闸门放在**人人必跑的这一步**,而不是文档里的一行提醒。

    两道判据,都不做字符串启发式:
      ① 排版:按 Xcode 的分隔符重新吐一遍、跟盘上**逐字节**比;
      ② 键序:跟 `git show HEAD:` 那份比两边共有键的**相对次序**。
    缺一不可 —— 只带 separators 却把键重排的写法能过①(它的往返结果跟自己一致),
    得靠②抓;而②在拿不到 HEAD 时会失效,那时只剩①。

    ⚠️ 真正的盲区只有一个:**拿不到 HEAD 时②整个跳过**(新仓 / 文件没入库 / 不在 git 里,
    `head_key_order` 返回 None → `not None` 为真 → 直接放行),此时重排查不出来。
    这是有意的取舍:键序不影响任何行为、只影响 diff 可读性,不该让脚本在新仓里失败。
    (2026-09-12 这段注释一度写反,说①的盲区是"重排查不出来" —— 那条盲区其实早被②堵上了,
    是先有①、后加②时注释没跟着更新。ls-911 读代码时指出来的,已实测确认②确实会红。)
    """
    reordered = reordered_against_head(catalog)
    want = canonical_text(catalog)
    if want == raw and not reordered:
        return 0
    if normalize:
        if reordered:
            # 把两边都有的键放回 HEAD 的次序,新增键按字典序追加到末尾 —— 这样 diff
            # 只剩真实增删。⚠️ 只动次序,一个键一个值都不改(下面的等价断言兜着)。
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
    for lang, lproj in TARGETS.items():
        lines = [HEADER]
        fallback_count = 0
        missing = []
        for key in sorted(strings):
            entry = strings[key] or {}
            unit = ((entry.get("localizations") or {}).get(lang) or {}).get("stringUnit") or {}
            value = unit.get("value")
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
        suffix = f"(其中 {fallback_count} 条暂回退简体)" if fallback_count else ""
        # 打完整相对路径,不要只打 `zh-hans.lproj` —— 产物不在 Localization/ 下面,而在
        # Sources/lyrimuse/Resources/ 下,只报 lproj 名会让人以为它跟 catalog 同目录。
        # 2026-09-12 实测两个会话**各自独立**把路径记成 Localization/*.lproj/,都是被这行误导的。
        print(f"{os.path.relpath(out, os.path.join(ROOT, '..'))}: {len(strings)} 键{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
