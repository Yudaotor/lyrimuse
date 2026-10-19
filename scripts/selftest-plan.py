#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""开发中改了哪些文件,selftest 该跑哪几组:打出要给 lyrimuse-selftest 的 --filter 参数。

    python3 scripts/selftest-plan.py <改过的路径…>        路径相对仓库根
    python3 scripts/selftest-plan.py --git                取工作区相对 HEAD 改过的(含未跟踪的;只留本地的文档在场就算)
    python3 scripts/selftest-plan.py --explain <路径…>    另打每个路径选中了哪几组、为什么

输出一行:`all`(整套跑)、`none`(selftest 不读这些文件)、或 `-f <组> -f <组> …`。

只给开发时缩小范围用,提交校验照旧整套跑。判法是静态的:
- 改到 LyrimuseCore、selftest 自己、Package.swift / Package.resolved:selftest 要重编,整套跑。
- 其余文件只能经源码契约被读到(App target 不编进 selftest):按 main.swift 注册表找到每组的 run 函数,顺着它调用的
  同目录顶层函数,收集这些函数里的字符串字面量;能解析成仓库里的文件的(写全路径、只写文件名都算)就算这一组读它;
  函数里遍历了目录的,它写的目录(含 `"UI/\\(name)"` 这种插值前面那段)也算。改动落在某组读的文件上、或读的目录底下,选这一组。
- 认不出来的(脚本自己出错、注册表解析不了)一律 all。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELFTEST = os.path.join(ROOT, 'lyrimuse', 'Sources', 'lyrimuse-selftest')
# 字面量里的相对路径可能相对于这几处(#filePath 往上数到哪一层的写法都有)。
BASES = ['', 'lyrimuse', 'lyrimuse/Sources', 'lyrimuse/Sources/lyrimuse', 'lyrimuse/Sources/LyrimuseCore']
ALL_TRIGGERS = ('lyrimuse/Sources/LyrimuseCore/', 'lyrimuse/Sources/lyrimuse-selftest/',
                'lyrimuse/Package.swift', 'lyrimuse/Package.resolved')
SKIP_DIRS = {'.git', '.build', 'node_modules', '.gocache'}
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# 遍历目录的写法:函数里有这些,它写的目录字面量才算「读这个目录底下的文件」;否则目录只是拼路径用的。
WALKS = re.compile(r'enumerator\(at|contentsOfDirectory\(|subpathsOfDirectory\(|swiftFiles\(under|files\(under')
# 拼出来的文件名不是字面量(`dir.appendingPathComponent(name + ".json")`):它写的目录里没有子目录的(样例目录)也算读,
# 读的是底下哪一个看不出来。有子目录的(源码树)不算,那多半只是拼路径的前缀。
JOINS = re.compile(r'appendingPathComponent\((?!")')
# 只留本地、被 .gitignore 挡掉的文档(docs-local 组读它们):git status 列不出改没改,--git 时在场的一律当改过。
LOCAL_ONLY = ['docs/features', 'docs/releasing.md', 'AGENTS.md', 'CLAUDE.md', '.claude/skills']
TOP_FUNC = re.compile(r'^(?:@MainActor\s+)?(?:private |fileprivate )?func (\w+)', re.M)


def repo_files():
    out = []
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for f in fns:
            out.append(os.path.relpath(os.path.join(dp, f), ROOT))
    return out


def registry():
    src = open(os.path.join(SELFTEST, 'main.swift'), encoding='utf-8').read()
    pairs = re.findall(r'TestGroup\(name: "([\w-]+)",.*?run: (\w+)\)', src)
    if not pairs:
        raise RuntimeError('注册表解析不了')
    return pairs


def top_functions():
    """顶层函数名 → 函数体文本(到下一个顶层 func 为止)。"""
    funcs = {}
    for name in sorted(os.listdir(SELFTEST)):
        if not name.endswith('.swift'):
            continue
        text = open(os.path.join(SELFTEST, name), encoding='utf-8').read()
        starts = [(m.start(), m.group(1)) for m in TOP_FUNC.finditer(text)]
        for i, (pos, fn) in enumerate(starts):
            end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
            funcs[fn] = funcs.get(fn, '') + text[pos:end]
    return funcs


def closure(entry, funcs):
    seen, todo = set(), [entry]
    while todo:
        fn = todo.pop()
        if fn in seen or fn not in funcs:
            continue
        seen.add(fn)
        for callee in re.findall(r'\b(\w+)\(', funcs[fn]):
            if callee in funcs and callee not in seen:
                todo.append(callee)
    return seen


def resolve(literal, files, file_set, dir_set, by_base):
    """字面量能指到的仓库文件和目录(相对仓库根)。"""
    static = literal.split('\\(')[0]
    if not static or len(static) < 3 or ' ' in static or not re.fullmatch(r'[\w./+-]+', static):
        return set(), set()
    if static != literal and not static.endswith('/'):
        return set(), set()
    cand = static.strip('/')
    if cand.startswith('./'):
        cand = cand[2:]
    hit_files, hit_dirs = set(), set()
    for base in BASES:
        p = os.path.normpath(os.path.join(base, cand)) if base else os.path.normpath(cand)
        if p in file_set:
            hit_files.add(p)
        elif p in dir_set:
            hit_dirs.add(p)
    if not hit_files and not hit_dirs and '/' not in cand and '.' in cand:
        hit_files |= by_base.get(cand, set())
    return hit_files, hit_dirs


def group_reads():
    files = repo_files()
    file_set = set(files)
    dir_set = {os.path.dirname(f) for f in files}
    for d in list(dir_set):
        while d:
            d = os.path.dirname(d)
            dir_set.add(d)
    dir_set.discard('')
    parents = {os.path.dirname(d) for d in dir_set}
    by_base = {}
    for f in files:
        by_base.setdefault(os.path.basename(f), set()).add(f)
    funcs = top_functions()
    reads = {}
    for group, entry in registry():
        fs, ds = set(), set()
        for fn in closure(entry, funcs):
            walks = WALKS.search(funcs[fn]) is not None
            joins = JOINS.search(funcs[fn]) is not None
            for lit in LITERAL.findall(funcs[fn]):
                a, b = resolve(lit, files, file_set, dir_set, by_base)
                fs |= a
                if walks:
                    ds |= b
                elif joins:
                    ds |= {d for d in b if d not in parents}
        reads[group] = (fs, ds)
    return reads


def plan(paths, explain=False):
    if any(p.startswith(ALL_TRIGGERS) for p in paths):
        return 'all', ['改到了 Core / selftest / Package,整套跑']
    reads = group_reads()
    chosen, why = [], []
    for group, (fs, ds) in reads.items():
        for p in paths:
            if p in fs:
                reason = '读 %s' % p
            else:
                d = next((d for d in sorted(ds, key=len, reverse=True) if p.startswith(d + '/')), None)
                if d is None:
                    continue
                reason = '读 %s/ 下的文件(%s)' % (d, p)
            chosen.append(group)
            why.append('%s: %s' % (group, reason))
            break
    if not chosen:
        return 'none', why
    return ' '.join('-f ' + g for g in chosen), why


def git_changed():
    out = subprocess.run(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=all'],
                         capture_output=True, text=True, check=True).stdout
    ignored = subprocess.run(['git', '-C', ROOT, 'status', '--porcelain', '--ignored', '--untracked-files=all', '--']
                             + LOCAL_ONLY, capture_output=True, text=True, check=True).stdout
    paths = []
    for line in out.splitlines() + [l for l in ignored.splitlines() if l.startswith('!! ')]:
        p = line[3:]
        if ' -> ' in p:
            p = p.split(' -> ', 1)[1]
        p = p.strip('"')
        if p not in paths:
            paths.append(p)
    return paths


def main():
    args = sys.argv[1:]
    explain = '--explain' in args
    args = [a for a in args if a != '--explain']
    if args == ['--git']:
        args = git_changed()
    if not args:
        print(__doc__.strip().splitlines()[2])
        return 2
    try:
        result, why = plan([os.path.normpath(a) for a in args], explain)
    except Exception as e:  # 认不出来就整套跑
        print('all')
        print('selftest-plan: %s,整套跑' % e, file=sys.stderr)
        return 0
    print(result)
    if explain:
        for w in why:
            print('  ' + w, file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
