#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Wiktionary 泰语词条的皇家学术院转写(RTGS)生成成 LyrimuseCore 的 Swift 表。

用法:
    python3 scripts/gen-thai-rtgs.py <kaikki.org-dictionary-Thai.jsonl>

输入是 kaikki.org 从英文 Wiktionary 导出的泰语词条(https://kaikki.org/dictionary/Thai/,
整份 JSONL,约 50 MB,不进仓库)。每个词条的 sounds 里 raw_tags 含 "Royal Institute" 的
那一项就是 RTGS 写法,音节之间用连字符隔开(sa-at、wan-thi)。
产物(连同本脚本一起提交):
    lyrimuse/Sources/LyrimuseCore/Lyrics/ThaiRTGSTable.swift

取舍规则:
  - 同一个词出现多个词条或多种写法时取最先出现的那一个(Wiktionary 页面上排在前面的读法)。
  - 以连字符结尾的写法是只在复合词里出现的连接形(ไทย → thai-ya-),跳过。
  - en dash 当连字符;含省略号、空格以外的非字母字符的写法(…-dai-…)跳过。
  - 词本身只收泰文字符(U+0E00–U+0E7F),带空格的短语也收,读音里的空格保留。
  - 单个字母的词条不收:Wiktionary 给的是字母名(ง ngo、ก ko kai),拼进别的词会读错;
    单个字母当词用时(ณ)交给规则补 a。
数据许可:CC BY-SA 4.0(Wiktionary),见 THIRD_PARTY_LICENSES。
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "lyrimuse", "Sources", "LyrimuseCore", "Lyrics", "ThaiRTGSTable.swift")

THAI_WORD = re.compile(r"^[฀-๿]+( [฀-๿]+)*$")
READING = re.compile(r"^[a-z]+(-[a-z]+)*( [a-z]+(-[a-z]+)*)*$")


def load(path):
    table = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            entry = json.loads(raw)
            word = entry.get("word", "")
            if not THAI_WORD.match(word) or len(word) < 2 or word in table:
                continue
            for sound in entry.get("sounds", []):
                if "Royal Institute" not in sound.get("raw_tags", []):
                    continue
                reading = sound.get("roman", "").replace("–", "-").strip().lower()
                if READING.match(reading):
                    table[word] = reading
                    break
    return table


def render(table):
    for k, v in table.items():
        if "\t" in k + v or "\n" in k + v or '"""' in k + v:
            raise SystemExit("词条里有生成器没法原样写进字符串字面量的字符: %r" % k)
    body = "\n".join("%s\t%s" % (k, table[k]) for k in sorted(table))
    return (
        "// 由 scripts/gen-thai-rtgs.py 生成 —— **不要手改这个文件**。\n"
        "//\n"
        "// 数据是英文 Wiktionary 泰语词条里的皇家学术院转写(RTGS,音节之间用连字符隔开),\n"
        "// 经 kaikki.org 导出,许可 CC BY-SA 4.0,下载日期和出处见 THIRD_PARTY_LICENSES。\n"
        "//\n"
        "// 表用「词<TAB>读音」逐行拼接的字符串存、首次使用时解析:上万条的字典字面量会让\n"
        "// Swift 的类型检查变得很慢。\n"
        "enum ThaiRTGSTable {\n"
        "    /// %d 条\n"
        "    static let entries = #\"\"\"\n%s\n\"\"\"#\n"
        "}\n"
    ) % (len(table), body)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    table = load(sys.argv[1])
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(render(table))
    print("wrote", os.path.relpath(OUT, ROOT), len(table), "entries")


if __name__ == "__main__":
    main()
