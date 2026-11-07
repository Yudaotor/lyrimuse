#!/usr/bin/env python3
"""拦 Swift 里用 + 连起来的可选数组长链:`(a.map { [...] } ?? []) + (b.map { [...] } ?? []) + ...` 三段及以上。

这种表达式本机 swift build 编得过,CI 的 macOS runner 上会报「the compiler is unable to type-check this
expression in reasonable time」,本地的提交校验拦不住。逐项 append 写(`if let x { items.append(...) }`)。

用法:python3 scripts/check-swift-plus-chains.py [文件…](不带参数扫 lyrimuse/Sources 下全部 .swift)。
有命中打印 文件:行号 并以 1 退出。
"""
import glob
import re
import sys

LIMIT = 3
CONT = re.compile(r"\s*\+\s*\(")
JOIN = re.compile(r"\?\? \[\]\)\s*\+\s*\(")


def segments(line):
    """这一行里用 + 连着的可选数组段数:行内每个 `?? []) + (` 接上一段,再加上行里最后那一段。注释行、没有 `?? [])` 的行算 0。"""
    if line.lstrip().startswith("//") or "?? [])" not in line:
        return 0
    return len(JOIN.findall(line)) + 1


def scan(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    hits, i = [], 0
    while i < len(lines):
        n = segments(lines[i])
        if not n:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and CONT.match(lines[j]) and segments(lines[j]):
            n += segments(lines[j])
            j += 1
        if n >= LIMIT:
            hits.append((i + 1, n))
        i = j
    return hits


def main(argv):
    files = argv or sorted(glob.glob("lyrimuse/Sources/**/*.swift", recursive=True))
    bad = 0
    for f in files:
        if not f.endswith(".swift"):
            continue
        for line, n in scan(f):
            print(f"{f}:{line}: {n} 段可选数组用 + 连在一起,CI 上会类型检查超时;改成逐项 append")
            bad += 1
    if bad:
        return 1
    print("Swift 可选数组 + 链检查:通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
