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
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(ROOT, "Localizable.xcstrings")
TARGETS = {
    # catalog 语言码 → 仓库里 .lproj 目录名(小写是既有布局,别"修"它:L10n.swift 和
    # build.sh 都按这个名字找)
    "zh-Hans": "zh-hans.lproj",
    "en": "en.lproj",
}
OUT_DIR = os.path.join(ROOT, "..", "Sources", "lyrimuse", "Resources")

HEADER = """\
/* 由 Localization/Localizable.xcstrings 生成 —— 不要手改这个文件。
   改词条:编辑 catalog(可用 Xcode 的 String Catalog 编辑器或直接改 JSON),
   然后跑 python3 Localization/generate-strings.py 重新生成,两个文件一起提交。
   selftest 会校验 catalog 与生成物一致。 */

"""


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def main() -> int:
    with open(CATALOG, encoding="utf-8") as f:
        catalog = json.load(f)
    if catalog.get("sourceLanguage") != "zh-Hans":
        print(f"sourceLanguage 应为 zh-Hans,实际是 {catalog.get('sourceLanguage')!r}", file=sys.stderr)
        return 1
    strings = catalog.get("strings") or {}
    if not strings:
        print("catalog 里一个键都没有 —— 拒绝生成空文件覆盖现有翻译", file=sys.stderr)
        return 1
    for lang, lproj in TARGETS.items():
        lines = [HEADER]
        for key in sorted(strings):
            entry = strings[key] or {}
            unit = ((entry.get("localizations") or {}).get(lang) or {}).get("stringUnit") or {}
            value = unit.get("value")
            if value is None:
                # 源语言允许省略(值即键,Xcode 的惯例);其它语言缺翻译就大声失败,
                # 别静默生成一个回退键 —— 那会让"缺翻译"从可见问题变成隐形问题。
                if lang == catalog["sourceLanguage"]:
                    value = key
                else:
                    print(f"键 {key!r} 缺 {lang} 翻译", file=sys.stderr)
                    return 1
            lines.append(f'"{escape(key)}" = "{escape(value)}";\n')
        out = os.path.join(OUT_DIR, lproj, "Localizable.strings")
        with open(out, "w", encoding="utf-8") as f:
            f.writelines(lines)
        print(f"{lproj}: {len(strings)} 键")
    return 0


if __name__ == "__main__":
    sys.exit(main())
