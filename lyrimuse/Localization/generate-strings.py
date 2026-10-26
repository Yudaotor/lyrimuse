#!/usr/bin/env python3
"""把 Localizable.xcstrings(唯一真源)生成各语言包的 Localizable.strings 与 InfoPlist.strings(入库的编译产物)。

用法:改完 Localizable.xcstrings 后跑一次:
    python3 Localization/generate-strings.py
然后把 catalog 和生成的 .strings 一起提交。selftest 有守卫:两边不一致会红。

加新文案别手写 Python 读写整个 catalog(默认 json.dump 会把上万行重排),用加键子命令:
    python3 Localization/generate-strings.py --add 新键.json
新键.json 形如 {"简体原文": {"en": "...", "zh-Hant": "..."}};要分单复数的语言写成 {"one": "...", "other": "..."}。
新键按文件里的次序追加到 catalog 末尾、已有的键拒绝覆盖,写回用 Xcode 的排版,然后照常生成三份 .strings。

改已有文案(简体原文就是键,改简体 = 换键)用换键子命令:
    python3 Localization/generate-strings.py --rename 映射.json
映射.json 形如 {"旧键": {"new": "新简体文案", "en": "...", "zh-Hant": "..."}},en / zh-Hant 不写就保留原译文。
条目留在原位、其余字段不动,显式的 zh-Hans 值跟着改成新键;旧键不存在、新键已存在、新旧文案的格式参数不一样
都拒绝且不写盘。写完列出源码里还写着旧键的地方 —— 调用处要自己改,脚本不动源码。

其它参数一律拒绝(-h / --help 打用法),不会落到默认的全量生成上。--selftest 只跑脚本自己的样例,不读写任何文件。

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


def localization(value):
    unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
    if isinstance(value, dict):
        return {"variations": {"plural": {form: unit(value[form]) for form in ("one", "other")}}}
    return unit(value)


def add_keys(catalog, path) -> int:
    """--add:把新键文件里的键按次序追加到 catalog 末尾,写回 Xcode 排版。已有的键、缺语言、格式参数不对都拒绝,不写盘。"""
    with open(path, encoding="utf-8") as f:
        new = json.load(f)
    if not isinstance(new, dict) or not new:
        print(f"✗ {path} 应是非空对象 {{简体原文: {{\"en\": …, \"zh-Hant\": …}}}}", file=sys.stderr)
        return 1
    strings = catalog["strings"]
    errors = []
    for key, langs in new.items():
        if key in strings:
            errors.append(f"{key[:60]}:catalog 里已有这个键(改已有文案用 --rename)")
            continue
        want = set(TARGETS) - {catalog["sourceLanguage"]}
        if not isinstance(langs, dict) or set(langs) != want:
            errors.append(f"{key[:60]}:要写且只写 {'、'.join(sorted(want))}")
            continue
        for lang, value in langs.items():
            ok = isinstance(value, str) and value or (isinstance(value, dict) and set(value) == {"one", "other"}
                                                      and all(isinstance(v, str) and v for v in value.values()))
            if not ok:
                errors.append(f"{key[:60]}:{lang} 要么是非空字符串,要么是 {{\"one\": …, \"other\": …}}")
    if not errors:
        added = {key: {"extractionState": "manual",
                       "localizations": {**{lang: localization(v) for lang, v in langs.items()},
                                         catalog["sourceLanguage"]: localization(key)}}
                 for key, langs in new.items()}
        errors = plural_problems(added, catalog["sourceLanguage"]) + format_arg_problems(added, catalog["sourceLanguage"])
    if errors:
        print(f"✗ --add 没有写入,{len(errors)} 处问题:", file=sys.stderr)
        for e in errors:
            print(f"    {e}", file=sys.stderr)
        return 1
    before = json.loads(json.dumps(catalog))
    for key, entry in added.items():
        strings[key] = {"extractionState": entry["extractionState"],
                        "localizations": dict(sorted(entry["localizations"].items()))}
    text = canonical_text(catalog)
    after = json.loads(text)
    assert {k: v for k, v in after["strings"].items() if k not in added} == before["strings"], "已有键被改动 —— 拒绝写入"
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"✓ 新增 {len(added)} 键(追加在末尾,已有的键一个没动)")
    return 0


RENAME_LANGS = ("en", "zh-Hant")


def renamed_strings(catalog, mapping):
    """--rename 的换键:返回 (换好的 strings, 问题列表),有问题时前者是 None。不改传进来的 catalog。

    条目留在旧键的位置、整份拷过来再改(extractionState 等字段跟着走),显式的源语言值改成新键,
    映射里写了的译文整条换成 localization(新值)、没写的留着。
    """
    if not isinstance(mapping, dict) or not mapping:
        return None, ["映射应是非空对象 {旧键: {\"new\": 新简体文案, \"en\": …, \"zh-Hant\": …}}"]
    strings = catalog["strings"]
    source = catalog["sourceLanguage"]
    errors, targets = [], {}
    for old, spec in mapping.items():
        if not isinstance(spec, dict) or not isinstance(spec.get("new"), str) or not spec["new"] \
                or not set(spec) <= {"new", *RENAME_LANGS}:
            errors.append(f"{old[:60]}:要写 \"new\"(新简体文案),可选 {'、'.join(RENAME_LANGS)}")
            continue
        new = spec["new"]
        if old not in strings:
            errors.append(f"{old[:60]}:catalog 里没有这个键")
        if new in strings:
            errors.append(f"{new[:60]}:catalog 里已有这个键,不能换成它")
        if new in targets:
            errors.append(f"{new[:60]}:映射里「{targets[new][:30]}」和「{old[:30]}」都换成了它")
        targets[new] = old
        if arg_signature(new) != arg_signature(old):
            errors.append(f"{old[:60]}:新文案的格式参数是「{describe_signature(arg_signature(new))}」,"
                          f"旧文案是「{describe_signature(arg_signature(old))}」—— 调用方按旧参数传值")
        for lang in RENAME_LANGS:
            value = spec.get(lang)
            if lang in spec and not (isinstance(value, str) and value or (
                    isinstance(value, dict) and set(value) == {"one", "other"}
                    and all(isinstance(v, str) and v for v in value.values()))):
                errors.append(f"{old[:60]}:{lang} 要么是非空字符串,要么是 {{\"one\": …, \"other\": …}}")
    if errors:
        return None, errors
    out, renamed = {}, {}
    for key, entry in strings.items():
        spec = mapping.get(key)
        if spec is None:
            out[key] = entry
            continue
        entry = json.loads(json.dumps(entry))
        locs = entry.setdefault("localizations", {})
        if source in locs:
            locs[source] = localization(spec["new"])
        for lang in RENAME_LANGS:
            if lang in spec:
                locs[lang] = localization(spec[lang])
        out[spec["new"]] = renamed[spec["new"]] = entry
    errors = plural_problems(renamed, source) + format_arg_problems(renamed, source)
    return (None, errors) if errors else (out, [])


SOURCE_ROOT = os.path.join(ROOT, "..")
SKIP_DIRS = {".build", ".git", "node_modules"}


def swift_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def source_references(keys, root=SOURCE_ROOT):
    """root 下 .swift 里还写着这些键的地方 [(相对路径, 行号, 键)]。认 Swift 字面量 "键",
    以及字符串里再转义一层的 \\"键\\"(selftest 的源码契约就这么写)。"""
    patterns = [(k, ('"' + swift_escape(k) + '"', '\\"' + swift_escape(swift_escape(k)) + '\\"')) for k in keys]
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8", errors="replace") as f:
                for no, line in enumerate(f, 1):
                    for key, pats in patterns:
                        if any(p in line for p in pats):
                            hits.append((os.path.relpath(path, root), no, key))
    return hits


def rename_keys(catalog, path) -> int:
    """--rename:按映射文件换键,写回 Xcode 排版,再列出源码里还引用旧键的地方。有问题一律不写盘。"""
    with open(path, encoding="utf-8") as f:
        mapping = json.load(f)
    strings, errors = renamed_strings(catalog, mapping)
    if errors:
        print(f"✗ --rename 没有写入,{len(errors)} 处问题:", file=sys.stderr)
        for e in errors:
            print(f"    {e}", file=sys.stderr)
        return 1
    before = catalog["strings"]
    news = {spec["new"] for spec in mapping.values()}
    assert [mapping[k]["new"] if k in mapping else k for k in before] == list(strings), "键序变了 —— 拒绝写入"
    assert {k: v for k, v in strings.items() if k not in news} == \
        {k: v for k, v in before.items() if k not in mapping}, "映射外的条目被改动 —— 拒绝写入"
    catalog["strings"] = strings
    text = canonical_text(catalog)
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"✓ 换了 {len(mapping)} 个键(条目留在原位,其余条目一个没动)")
    hits = source_references(list(mapping))
    if hits:
        print(f"  源码里还写着旧键的 {len(hits)} 处(脚本不改源码,调用处换成新键):")
        for rel, no, key in hits:
            print(f"    {rel}:{no}  {key[:60]} → {mapping[key]['new'][:60]}")
    else:
        print("  源码里没有旧键的字面量(键是拼出来的调用处要自己找)")
    return 0


def selftest() -> int:
    """--rename 和参数解析的样例,不碰仓库里的文件。返回失败条数。"""
    import tempfile
    unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
    full = lambda zh, en, hant: {"extractionState": "manual",
                                 "localizations": {"en": unit(en), "zh-Hans": unit(zh), "zh-Hant": unit(hant)}}
    # 回归样例:逐字歌词格式的 7 条换键,旧条目和映射照搬真实数据 (旧键: 旧 en, 旧 zh-Hant, 新键, 新 en, 新 zh-Hant)。
    word_format = {
        "网易云音乐的逐字格式": ("NetEase Cloud Music's word-by-word format", "網易雲音樂的逐字格式",
                         "网易云音乐的格式", "NetEase Cloud Music's format", "網易雲音樂的格式"),
        "Apple Music 使用的标准格式，可存背景人声": (
            "The standard format Apple Music uses, with room for background vocals", "Apple Music 使用的標準格式，可存背景人聲",
            "Apple Music 等使用的标准格式，可带背景人声和译文",
            "The standard format used by Apple Music and others, can carry background vocals and translations",
            "Apple Music 等使用的標準格式，可帶背景人聲和譯文"),
        "QQ 音乐客户端的本地格式": ("The local file format of the QQ Music app", "QQ 音樂用戶端的本機格式",
                             "QQ 音乐的加密格式", "QQ Music's encrypted format", "QQ 音樂的加密格式"),
        "酷狗音乐客户端的本地格式": ("The local file format of the Kugou Music app", "酷狗音樂用戶端的本機格式",
                             "酷狗音乐的加密格式，可带译文", "Kugou Music's encrypted format, can carry translations",
                             "酷狗音樂的加密格式，可帶譯文"),
        "在逐行 LRC 里给每个字加上时间": ("Line-by-line LRC with a timestamp on every word", "在逐行 LRC 裡為每個字加上時間",
                               "每个字带时间的 LRC，另存为 .enhanced.lrc", "LRC with a time on every word, saved as .enhanced.lrc",
                               "每個字帶時間的 LRC，另存為 .enhanced.lrc"),
        "把逐字歌词改存为 %@？": ("Save Word-by-Word Lyrics as %@?", "把逐字歌詞改存為 %@？",
                           "逐字歌词改存为「%@」？", "Save Word-by-Word Lyrics as %@?", "逐字歌詞改存為「%@」？"),
        "另存副本：%@": ("Also saved as: %@", "另存副本：%@", "同时存为：%@", "Also saved as: %@", "同時存為：%@"),
    }
    strings = {"前一条": {"extractionState": "manual",
                       "localizations": {"en": unit("Before"), "zh-Hant": unit("前一條")}}}
    for old, (en, hant, *_rest) in word_format.items():
        strings[old] = full(old, en, hant)
    strings["%lld 首"] = {"extractionState": "manual", "localizations": {
        "en": {"variations": {"plural": {"one": unit("%lld song"), "other": unit("%lld songs")}}},
        "zh-Hant": unit("%lld 首")}}
    strings["后一条"] = {"extractionState": "manual",
                      "localizations": {"en": unit("After"), "zh-Hant": unit("後一條")}}
    catalog = {"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"}
    pristine = canonical_text(catalog)
    failures = []

    def check(name, cond, detail=""):
        if not cond:
            failures.append(f"{name}{':' + detail if detail else ''}")

    def rename(mapping):
        out, errors = renamed_strings(catalog, mapping)
        check("输入的 catalog 不被改动", canonical_text(catalog) == pristine)
        return out, errors

    mapping = {old: {"new": new, "en": en, "zh-Hant": hant} for old, (_, _, new, en, hant) in word_format.items()}
    out, errors = rename(mapping)
    check("逐字歌词格式 7 条", out is not None, "; ".join(errors))
    if out is not None:
        want_order = ["前一条"] + [m["new"] for m in mapping.values()] + ["%lld 首", "后一条"]
        check("逐字歌词格式 7 条:条目留在原位", list(out) == want_order, repr(list(out)))
        for spec in mapping.values():
            check(f"逐字歌词格式 7 条:{spec['new']}",
                  out[spec["new"]] == full(spec["new"], spec["en"], spec["zh-Hant"]), repr(out.get(spec["new"])))
        check("逐字歌词格式 7 条:其余条目不动", all(out[k] is strings[k] for k in ("前一条", "%lld 首", "后一条")))
        before_lines = pristine.count("\n")
        after_lines = canonical_text({**catalog, "strings": out}).count("\n")
        check("逐字歌词格式 7 条:纯换文案行数不变", before_lines == after_lines, f"{before_lines} → {after_lines}")

    out, errors = rename({"前一条": {"new": "上一条"}})
    check("不写译文就留着原译文、没有 zh-Hans 的条目不补",
          out is not None and out["上一条"] == strings["前一条"] and list(out)[0] == "上一条", "; ".join(errors))
    out, errors = rename({"%lld 首": {"new": "%lld 首歌", "en": {"one": "%lld track", "other": "%lld tracks"}}})
    check("分单复数的译文", out is not None and out["%lld 首歌"]["localizations"]["en"] ==
          {"variations": {"plural": {"one": unit("%lld track"), "other": unit("%lld tracks")}}}, "; ".join(errors))

    rejects = {
        "格式参数个数不一样": {"另存副本：%@": {"new": "另存了副本", "en": "Saved a copy", "zh-Hant": "另存了副本"}},
        "格式参数类型不一样": {"把逐字歌词改存为 %@？": {"new": "改存为第 %lld 种格式？", "en": "Save as format %lld?",
                                                   "zh-Hant": "改存為第 %lld 種格式？"}},
        "译文格式参数不对": {"另存副本：%@": {"new": "同时存为：%@", "en": "Also saved"}},
        "新键已存在": {"前一条": {"new": "后一条"}},
        "旧键不存在": {"没有这条": {"new": "随便"}},
        "两个旧键换成同一个": {"前一条": {"new": "同一条"}, "后一条": {"new": "同一条"}},
        "缺 new": {"前一条": {"en": "Before"}},
        "多写了语言": {"前一条": {"new": "上一条", "zh-Hans": "上一条"}},
    }
    for name, bad in rejects.items():
        out, errors = rename(bad)
        check(f"拒绝:{name}", out is None and errors, "没有拒绝")

    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "Sources", "a"))
        os.makedirs(os.path.join(tmp, ".build", "b"))
        with open(os.path.join(tmp, "Sources", "a", "V.swift"), "w", encoding="utf-8") as f:
            f.write('Text(L10n.t("另存副本：%@"))\nlet x = "另存副本：%@ 以外"\nsourceHas(s, "L10n.t(\\"另存副本：%@\\")")\n')
        with open(os.path.join(tmp, ".build", "b", "G.swift"), "w", encoding="utf-8") as f:
            f.write('L10n.t("另存副本：%@")\n')
        hits = source_references(["另存副本：%@"], tmp)
        want = [(os.path.join("Sources", "a", "V.swift"), 1, "另存副本：%@"),
                (os.path.join("Sources", "a", "V.swift"), 3, "另存副本：%@")]
        check("源码引用:认字面量和转义形式、跳过 .build", hits == want, repr(hits))

    for argv, want in ((["--rename"], None), (["--help"], "help"), (["--add", "a.json", "--rename", "b.json"], None),
                       (["--bogus"], None), (["--rename", "m.json"], {"rename": "m.json"}), ([], {})):
        got = parse_args(argv)
        if isinstance(want, dict):
            check(f"参数 {argv}", isinstance(got, dict) and all(got[k] == v for k, v in want.items()), repr(got))
        else:
            check(f"参数 {argv}", got == want, repr(got))

    for f in failures:
        print(f"✗ {f}", file=sys.stderr)
    print(f"generate-strings 自检:{'通过' if not failures else f'{len(failures)} 条没过'}")
    return len(failures)


USAGE = """用法:
    python3 Localization/generate-strings.py                     从 catalog 生成三份 .strings
    python3 Localization/generate-strings.py --normalize         把 catalog 排版和键序就地规范化,再生成
    python3 Localization/generate-strings.py --add 新键.json      追加新键,再生成
    python3 Localization/generate-strings.py --rename 映射.json   换键(改已有简体文案),再生成
    python3 Localization/generate-strings.py --selftest          只跑脚本自检"""


def parse_args(argv):
    """解析参数:返回选项 dict;-h / --help 返回 "help";不认识的参数、缺文件名、--add 和 --rename 同时给返回 None。"""
    opts = {"normalize": False, "add": None, "rename": None, "selftest": False}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            return "help"
        if arg == "--normalize":
            opts["normalize"] = True
        elif arg == "--selftest":
            opts["selftest"] = True
        elif arg in ("--add", "--rename") and i + 1 < len(argv) and not argv[i + 1].startswith("-"):
            opts[arg[2:]] = argv[i + 1]
            i += 1
        else:
            return None
        i += 1
    if opts["add"] and opts["rename"]:
        return None
    return opts


def main() -> int:
    opts = parse_args(sys.argv[1:])
    if opts == "help":
        print(USAGE)
        return 0
    if opts is None:
        print(USAGE, file=sys.stderr)
        return 2
    if opts["selftest"]:
        return 1 if selftest() else 0
    with open(CATALOG, encoding="utf-8") as f:
        raw = f.read()
    catalog = json.loads(raw)
    if check_canonical_form(raw, catalog, opts["normalize"]) != 0:
        return 1
    if opts["add"]:
        if add_keys(catalog, opts["add"]) != 0:
            return 1
    if opts["rename"]:
        if rename_keys(catalog, opts["rename"]) != 0:
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
