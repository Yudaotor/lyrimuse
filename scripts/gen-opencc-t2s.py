#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 collector 内嵌的 OpenCC 繁转简词典生成成 App 侧的 Swift 表。

用法:
    python3 scripts/gen-opencc-t2s.py            # 重新生成产物
    python3 scripts/gen-opencc-t2s.py --check    # 只校验产物是不是最新

输入(collector 用 //go:embed 读的同一份,见 lyrimuse-collector/t2s.go):
    lyrimuse-collector/dictionary/TSCharacters.txt
    lyrimuse-collector/dictionary/TSPhrases.txt
产物(连同本脚本一起提交):
    lyrimuse/Sources/LyrimuseCore/Lyrics/OpenCCT2STable.swift

解析规则逐条照 t2s.go 的 loadT2SDict:整行去首尾空白、空行跳过、按第一个 Tab 切两列、
第二列按空白切开取第一个候选、同一个 key 出现多次时后出现的覆盖先出现的。App 侧的
OpenCCT2S 用这份表跑跟 toSimplifiedT2S 同一套最长匹配,两侧的宽松 key 才会逐字一致。
改了解析规则必须两边一起改。
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DICT_DIR = os.path.join(ROOT, "lyrimuse-collector", "dictionary")
OUT = os.path.join(ROOT, "lyrimuse", "Sources", "LyrimuseCore", "Lyrics", "OpenCCT2STable.swift")


def load(name):
    entries = {}
    with open(os.path.join(DICT_DIR, name), encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            items = line.split("\t", 1)
            if len(items) < 2:
                continue
            fields = items[1].split()
            if not fields:
                continue
            entries[items[0]] = fields[0]
    return entries


def render():
    chars = load("TSCharacters.txt")
    phrases = load("TSPhrases.txt")
    for table in (chars, phrases):
        for k, v in table.items():
            if "\t" in k + v or "\n" in k + v or '"""' in k + v:
                raise SystemExit("词典里有生成器没法原样写进字符串字面量的字符: %r" % k)

    def body(table):
        return "\n".join("%s\t%s" % (k, table[k]) for k in sorted(table))

    return (
        "// 由 scripts/gen-opencc-t2s.py 生成 —— **不要手改这个文件**。\n"
        "//\n"
        "// 数据是 lyrimuse-collector/dictionary 下的 OpenCC TSCharacters / TSPhrases(Apache-2.0),\n"
        "// 每个 key 只留第一个候选,规则同 collector t2s.go 的 loadT2SDict。selftest 有一条断言按那两份\n"
        "// .txt 逐条核对这里的表(漏跑生成器会当场红)。\n"
        "//\n"
        "// 表用两条「key<TAB>value」逐行拼接的字符串存、首次使用时解析:几千条的字典字面量会让\n"
        "// Swift 的类型检查变得很慢。\n"
        "enum OpenCCT2STable {\n"
        "    /// 单字表(%d 条)\n"
        "    static let characters = #\"\"\"\n%s\n\"\"\"#\n\n"
        "    /// 词组表(%d 条)\n"
        "    static let phrases = #\"\"\"\n%s\n\"\"\"#\n"
        "}\n"
    ) % (len(chars), body(chars), len(phrases), body(phrases))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--check", action="store_true", help="只校验产物是否最新,不写文件")
    args = p.parse_args()
    text = render()
    if args.check:
        try:
            current = open(OUT, encoding="utf-8").read()
        except FileNotFoundError:
            current = ""
        if current != text:
            print("OpenCCT2STable.swift 不是最新,跑一次 python3 scripts/gen-opencc-t2s.py", file=sys.stderr)
            sys.exit(1)
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote", os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
