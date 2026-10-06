#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""docs/features 决策日志的编号:分配新号 + 核对代码里的决策指针。

    python3 scripts/decision-number.py append <章> <正文文件|->   # 记一条新决策,打印分到的号
    python3 scripts/decision-number.py check [文件…]              # 核对指针(不带参数 = 全仓)

# append

<章> 写章号(`07`)或文件路径。正文从 `**标题**` 开始写,不带编号;脚本在锁里读该章「设计决策与
已知坑」一节当前的最大号,用最大号 + 1 接在这一节末尾,原子写回,最后打印 `07 章决策 88`。

几个会话同时往同一章记决策时,「写之前现查最大号」挡不住撞号:查完到写入之间别的会话已经
落了同一个号。分号和写入必须在同一把锁里,所以新决策一律走这个脚本;代码里的「见 NN 章决策 MM」
只照它打印出来的号填,别在文档写成之前先写代码指针。

# check

扫代码注释里的「NN 章决策 MM」(含「第 NN 章决策」「决策 #MM」「决策 MM、MM」「决策 MM/MM」),
逐个核对:那一章存在、该节里有编号为 MM 的条目、而且只有一条。只有号、没有章号的「见决策 MM」
定位不了章,不核对。

`docs/features/` 在 .gitignore 里,干净 clone 上没有这些文档 —— 这时直接放行(退出码 0)。
命中问题时非零退出,逐条打印 `file:line`。

决策条目是这一节里顶格的「数字. 」开头的行(早期的条目没有加粗标题,同样算)。小节里嵌着的
1. 2. 3. 小列表不算:按出现顺序切成连续编号的段,不从 1 开始的段一律算决策;从 1 开始的段只有
在两种情况下算决策,否则当小列表跳过:
  - 它自己含全节最大号;
  - 后面有不从 1 开始的段接着它数。一段接着谁数:它前面从 1 开始、末尾往后 10 个号以内(容得下
    删掉的旧条目和撞号)够得着它开头的段里,末尾离它开头最近的那一个,中间隔着别的小列表也算
    (新决策追加在节末,跟主列表之间常隔着带小列表的小节)。
"""
import fcntl
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, 'docs', 'features')
LOCK = os.path.join(DOCS, '.decision-number.lock')
SECTION = re.compile(r'^## 设计决策与已知坑[ \t]*$', re.M)
NEXT_SECTION = re.compile(r'^## ', re.M)
ITEM = re.compile(r'^(\d{1,3})\. ', re.M)
CODE_EXT = ('.swift', '.go', '.py', '.sh', '.js', '.mjs', '.ts')
# 「09 章决策 69」「第 09 章决策 67」「02 章决策 #25」后面可跟「、49」「/82」继续列号。
REF = re.compile(r'(?:第\s*)?(\d{2})\s*章(?:的)?决策\s*#?(\d{1,3})((?:\s*[、/,]\s*#?\d{1,3})*)')


def chapter_file(chapter):
    if os.path.isfile(chapter):
        return chapter
    for name in sorted(os.listdir(DOCS)):
        if name.startswith(chapter.zfill(2) + '-') and name.endswith('.md'):
            return os.path.join(DOCS, name)
    return None


def section_bounds(text):
    m = SECTION.search(text)
    if not m:
        return None
    nxt = NEXT_SECTION.search(text, m.end())
    return m.end(), (nxt.start() if nxt else len(text))


def decision_numbers(text, start, end):
    """[start, end) 里的决策号(含重复),跳过小节里从 1 重新数起的小列表。"""
    runs = []
    for n in (int(x) for x in ITEM.findall(text, start, end)):
        if runs and n == runs[-1][-1] + 1:
            runs[-1].append(n)
        else:
            runs.append([n])
    if not runs:
        return []
    top = max(max(r) for r in runs)
    keep = [r[0] != 1 or top in r for r in runs]
    # 每个不从 1 开始的段只认一个接着数的段。紧挨在它前面的小列表往往也在 10 个号以内,
    # 够得着的都算进来就会跟主列表撞号。
    for j, later in enumerate(runs):
        if later[0] == 1:
            continue
        reach = [i for i in range(j) if runs[i][0] == 1 and later[0] <= runs[i][-1] + 10]
        if reach:
            keep[min(reach, key=lambda i: (abs(later[0] - runs[i][-1] - 1), i))] = True
    return [n for r, k in zip(runs, keep) if k for n in r]


def numbers(path):
    """该章决策一节里的决策号(含重复),没有这一节返回 None。"""
    text = open(path, encoding='utf-8').read()
    b = section_bounds(text)
    return None if b is None else decision_numbers(text, *b)


def append(chapter, body_src):
    path = chapter_file(chapter)
    if not path:
        sys.exit(f'找不到第 {chapter} 章的文档')
    body = (sys.stdin.read() if body_src == '-' else open(body_src, encoding='utf-8').read()).strip('\n')
    if not body.startswith('**'):
        sys.exit('正文要从 `**标题**` 开始写,不带编号')
    with open(LOCK, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        text = open(path, encoding='utf-8').read()
        b = section_bounds(text)
        if b is None:
            sys.exit(f'{os.path.basename(path)} 里没有「## 设计决策与已知坑」一节')
        num = max(decision_numbers(text, *b), default=0) + 1
        head, tail = text[:b[1]].rstrip('\n'), text[b[1]:]
        new = head + '\n\n' + f'{num}. ' + body + '\n' + ('\n' + tail if tail else '')
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(new)
        os.replace(tmp, path)
    print(f'{os.path.basename(path)[:2]} 章决策 {num}')


def code_files(args):
    if args:
        return [a for a in args if a.endswith(CODE_EXT) and os.path.isfile(a)]
    out = subprocess.run(['git', '-C', ROOT, 'ls-files'], capture_output=True, text=True).stdout.split('\n')
    return [os.path.join(ROOT, f) for f in out if f.endswith(CODE_EXT)]


def check(args):
    if not os.path.isdir(DOCS):
        print('docs/features 不在(干净 clone),跳过决策指针核对')
        return 0
    cache, bad, seen = {}, [], 0
    for path in code_files(args):
        try:
            lines = open(path, encoding='utf-8').read().split('\n')
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(lines, 1):
            for m in REF.finditer(line):
                chapter = m.group(1)
                if chapter not in cache:
                    f = chapter_file(chapter)
                    cache[chapter] = numbers(f) if f else None
                nums = cache[chapter]
                for n in [m.group(2)] + re.findall(r'\d{1,3}', m.group(3)):
                    seen += 1
                    rel = os.path.relpath(path, ROOT)
                    if nums is None:
                        bad.append(f'{rel}:{lineno}: 第 {chapter} 章不存在或没有「设计决策与已知坑」一节')
                    elif nums.count(int(n)) == 0:
                        bad.append(f'{rel}:{lineno}: {chapter} 章没有决策 {n}')
                    elif nums.count(int(n)) > 1:
                        bad.append(f'{rel}:{lineno}: {chapter} 章决策 {n} 有 {nums.count(int(n))} 条,指针指不准')
    for row in bad:
        print(row)
    if bad:
        print(f'\n{len(bad)} 处决策指针对不上(共核对 {seen} 处)。修文档编号或改指针;新决策走 append 分号。')
        return 1
    return 0


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == 'check':
        return check(sys.argv[2:])
    if len(sys.argv) == 4 and sys.argv[1] == 'append':
        append(sys.argv[2], sys.argv[3])
        return 0
    print(__doc__.split('\n\n')[1], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
