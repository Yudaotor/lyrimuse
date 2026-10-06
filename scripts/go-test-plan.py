#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""引擎测试读了哪些模块外的文件,改了其中哪些要重跑哪几个测试。

    python3 scripts/go-test-plan.py [--engine <引擎目录>] <改动路径清单>   # 输出一行:none / all / -run 用的正则
    python3 scripts/go-test-plan.py [--engine <引擎目录>] --list          # 列出每个模块外路径由哪些测试读

--engine 默认是这个脚本旁边那棵树的 lyrimuse-engine/;commit-checks.sh 传的是正在校验的那棵树里的。

go 的测试缓存只核对模块目录(lyrimuse-engine/)里的文件,测试读的模块外文件(Swift 源码、README、shared/ …)变了,
缓存照样报通过。commit-checks.sh 拿「这个校验目录上一次 go test 通过时的树」到这次的树之间改过的路径来问这里:
  none            改的路径没有一个是引擎测试会读的,缓存照用
  all             有测试的读法这里认不出,整套带 -count=1 重跑
  ^(TestA|TestB)$ 只把这几个带 -count=1 重跑
清单里 lyrimuse-engine/ 下的路径不看,那些 go 自己认得出。

认的读法只有两种:字面量 "../<路径>",和 filepath.Join("..", "<段>", …)(后面跟着非字面量时按目录前缀算)。
测试源码里出现别的 ".." 写法,读到它的测试按「任何模块外文件变了都重跑」算。路径落在辅助函数或包级变量里时,
顺着名字找到调用它的测试;找不到任何测试、或者用到它的是 TestMain,就输出 all。
"""
import glob
import os
import re
import sys

ENGINE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'lyrimuse-engine')
DECL = re.compile(r'^(func|var|const|type)\b', re.M)
FUNC_NAME = re.compile(r'^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)')
SPEC_ONE = re.compile(r'^(?:var|const|type)\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)')
SPEC_LINE = re.compile(r'^\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\b[^=\n:]*=(?!=)', re.M)
TEST_FUNC = re.compile(r'^Test[A-Z0-9_]')
LITERAL = re.compile(r'"\.\./([^"]*)"')
JOIN = re.compile(r'filepath\.Join\(\s*"\.\."\s*,([^)]*)\)')
OTHER_DOTDOT = re.compile(r'"\.\."')
ANY = '*'


def decls():
    """测试文件里每一个顶层声明:(名字列表, 是不是函数, 正文)。"""
    out = []
    for path in sorted(glob.glob(os.path.join(ENGINE, '*_test.go'))):
        src = open(path, encoding='utf-8').read()
        starts = [m.start() for m in DECL.finditer(src)] + [len(src)]
        for a, b in zip(starts, starts[1:]):
            body = src[a:b]
            m = FUNC_NAME.match(body)
            if m:
                out.append(([m.group(1)], True, body))
            else:
                out.append((decl_names(body), False, body))
    return out


def decl_names(body):
    """包级 var / const / type 声明里定义的名字;括号块里逐行取等号左边的名字。"""
    if re.match(r'(?:var|const|type)\s*\(', body):
        found = SPEC_LINE.findall(body)
    else:
        m = SPEC_ONE.match(body)
        found = [m.group(1)] if m else []
    return [n for group in found for n in re.split(r'\s*,\s*', group)]


def refs_of(body):
    """正文里读到的模块外路径。以 / 结尾的是目录前缀;ANY 表示认不出,任何模块外路径都算。"""
    refs = set(LITERAL.findall(body))
    plain = LITERAL.sub('', body)
    for m in JOIN.finditer(plain):
        parts, prefix = [], False
        for arg in m.group(1).split(','):
            arg = arg.strip()
            lit = re.fullmatch(r'"([^"]*)"', arg)
            if not lit:
                prefix = True
                break
            parts.append(lit.group(1))
        refs.add('/'.join(parts) + ('/' if prefix else ''))
    if OTHER_DOTDOT.search(JOIN.sub('', plain)):
        refs.add(ANY)
    return refs


def matches(ref, path):
    if ref == ANY:
        return True
    if ref.endswith('/'):
        return path.startswith(ref)
    return path == ref or path.startswith(ref + '/')


def tests_reading(path, table):
    """读到 path 的测试名;顺着辅助函数 / 包级变量的名字往上找。找不到任何测试、或者碰到 TestMain 返回 None。"""
    names_of = [d[0] for d in table]
    hit = [i for i, d in enumerate(table) if any(matches(r, path) for r in refs_of(d[2]))]
    tests, seen, queue = set(), set(), list(hit)
    while queue:
        i = queue.pop()
        if i in seen:
            continue
        seen.add(i)
        names, is_func, _ = table[i]
        if is_func and names[0] == 'TestMain':
            return None
        if is_func and TEST_FUNC.match(names[0]):
            tests.add(names[0])
            continue
        if not names:
            return None
        pattern = re.compile(r'\b(?:%s)\b' % '|'.join(map(re.escape, names)))
        callers = [j for j, d in enumerate(table) if j != i and pattern.search(d[2])]
        if not callers:
            return None
        queue.extend(callers)
    return tests


def plan(paths):
    table = decls()
    outside = [p for p in paths if p and not p.startswith('lyrimuse-engine/')]
    tests = set()
    for p in outside:
        got = tests_reading(p, table)
        if got is None:
            return 'all'
        tests |= got
    if not tests:
        return 'none'
    return '^(%s)$' % '|'.join(sorted(tests))


def listing():
    table = decls()
    by_ref = {}
    for names, is_func, body in table:
        for r in refs_of(body):
            by_ref.setdefault(r, set()).update(names)
    for r in sorted(by_ref):
        got = tests_reading(r.rstrip('/') + ('/x' if r.endswith('/') else ''), table) if r != ANY else None
        print('%-70s %s' % (r, 'ALL' if got is None else ' '.join(sorted(got))))


if __name__ == '__main__':
    args = sys.argv[1:]
    if args[:1] == ['--engine'] and len(args) >= 2:
        ENGINE = os.path.abspath(args[1])
        args = args[2:]
    if args == ['--list']:
        listing()
    elif len(args) == 1:
        print(plan(open(args[0], encoding='utf-8').read().splitlines()))
    else:
        sys.exit(__doc__)
