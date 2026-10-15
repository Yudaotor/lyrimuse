#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""docs/features 决策日志的编号:分配新号 + 核对代码里的决策指针。

    python3 scripts/decision-number.py append <章> <正文文件|-> [--fill <文件…>]   # 记一条新决策,打印分到的号
    python3 scripts/decision-number.py check [文件…]              # 核对指针(不带参数 = 全仓)
    python3 scripts/decision-number.py show <章> <号…>            # 打印这几条决策的正文
    python3 scripts/decision-number.py which <章> <行号>          # 文档这一行属于哪条决策

# append

<章> 写章号(`07`)或文件路径。正文从 `**标题**` 开始写,不带编号;脚本在锁里读该章「设计决策与
已知坑」一节当前的最大号,用最大号 + 1 接在这一节末尾,原子写回,最后打印 `07 章决策 88`。

几个会话同时往同一章记决策时,「写之前现查最大号」挡不住撞号:查完到写入之间别的会话已经
落了同一个号。分号和写入必须在同一把锁里,所以新决策一律走这个脚本;代码里的「见 NN 章决策 MM」
只照它打印出来的号填,别在文档写成之前先写代码指针。

# 占位

代码要在分号之前写指针时,号写成两个问号:「见 NN 章决策 ??」,跟在已有号后面列也行
(「见 NN 章决策 246、??」)。`append` 带 `--fill <文件…>` 在同一把锁里把这些文件里同一章的占位换成
分到的号;列出的文件里有一个找不到这一章的占位就整条不写(文档也不动)。一次 `--fill` 只填一个号,
同一章要记两条新决策时,先 append 第一条再写第二条的占位。`check` 见到占位一律拒收,忘了填号提交不了。

# check

扫代码注释里的「NN 章决策 MM」(含「第 NN 章决策」「决策 #MM」「决策 MM、MM」「决策 MM/MM」),
逐个核对:那一章存在、该节里有编号为 MM 的条目、而且只有一条。只有号、没有章号的「见决策 MM」
定位不了章,不核对。

带章号却写成「已知坑」的指针(「NN 章已知坑 N」「docs/features/NN 已知坑 N」)一律拒收:它们不进上面的
核对,号指错、文档里重号都发现不了。改成「NN 章决策 MM」,号用 show 核对内容。没有章号的「docs 已知坑 N」
跟「见决策 MM」一样定位不了章,不拦。

`docs/features/` 在 .gitignore 里,干净 clone 上没有这些文档 —— 这时直接放行(退出码 0)。
命中问题时非零退出,逐条打印 `file:line`。

check 只核号在不在,指错了号照样通过。新写或改过的指针,用 show 把那条决策的正文打出来对一眼内容。

# show / which

show 打印该章里这几个号的决策全文:从这一条开头到下一条决策开头,夹在中间的小列表算这一条的。
号重了几条都打出来,并在 stderr 提示;没有这个号的退出码 1。

which 报文档第几行落在哪条决策里(号和标题行),给注释里的论证找指针用。别往上找最近的「数字. 」行,
那会落到嵌套的小列表上;这里跟 check 用同一套数号规则。不在这一节的决策里的行退出码 1。

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
import shutil
import subprocess
import sys

SELF = os.path.abspath(__file__)
ROOT = os.path.dirname(os.path.dirname(SELF))
DOCS = os.path.join(ROOT, 'docs', 'features')
LOCK = os.path.join(DOCS, '.decision-number.lock')
SECTION = re.compile(r'^## 设计决策与已知坑[ \t]*$', re.M)
NEXT_SECTION = re.compile(r'^## ', re.M)
ITEM = re.compile(r'^(\d{1,3})\. ', re.M)
CODE_EXT = ('.swift', '.go', '.py', '.sh', '.js', '.mjs', '.ts')
# 「09 章决策 69」「第 09 章决策 67」「02 章决策 #25」后面可跟「、49」「/82」继续列号。
REF = re.compile(r'(?:第\s*)?(\d{2})\s*章(?:的)?决策\s*#?(\d{1,3})((?:\s*[、/,]\s*#?\d{1,3})*)')
# 还没分到号的指针「15 章决策 ??」,也可以接在已有号后面列「15 章决策 39、??」:
# group(1) 是问号前的部分(连同前面列的号),group(2) 是章号。
PLACEHOLDER = re.compile(r'((?:第\s*)?(\d{2})\s*章(?:的)?决策\s*#?(?:\d{1,3}\s*[、/,]\s*#?)*)\?\?')
# check 用:不管带不带章号、前面列没列号,留下的 ?? 都算没填。
ANY_PLACEHOLDER = re.compile(r'决策\s*#?(?:\d{1,3}\s*[、/,]\s*#?)*\?\?')
# 带章号的「已知坑」写法:「09 章已知坑 12」「第 11 章的已知坑 7」「docs/features/09 的已知坑 12」
# 「docs/features/11-lyrics-manager.md 已知坑 7」。
KNOWN_ISSUE_REF = re.compile(r'(?:(?:第\s*)?\d{2}\s*章|docs/features/\d{2}[\w.-]*)\s*(?:的)?\s*已知坑\s*#?\d{1,3}')


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


def decision_entries(text, start, end):
    """[start, end) 里的决策条目 [(号, 行首偏移)](含重复),跳过小节里从 1 重新数起的小列表。"""
    runs = []
    for m in ITEM.finditer(text, start, end):
        n = int(m.group(1))
        if runs and n == runs[-1][-1][0] + 1:
            runs[-1].append((n, m.start()))
        else:
            runs.append([(n, m.start())])
    if not runs:
        return []
    top = max(n for r in runs for n, _ in r)
    keep = [r[0][0] != 1 or any(n == top for n, _ in r) for r in runs]
    # 每个不从 1 开始的段只认一个接着数的段。紧挨在它前面的小列表往往也在 10 个号以内,
    # 够得着的都算进来就会跟主列表撞号。
    for j, later in enumerate(runs):
        first = later[0][0]
        if first == 1:
            continue
        reach = [i for i in range(j) if runs[i][0][0] == 1 and first <= runs[i][-1][0] + 10]
        if reach:
            keep[min(reach, key=lambda i: (abs(first - runs[i][-1][0] - 1), i))] = True
    return [e for r, k in zip(runs, keep) if k for e in r]


def decision_numbers(text, start, end):
    """[start, end) 里的决策号(含重复),规则见 decision_entries。"""
    return [n for n, _ in decision_entries(text, start, end)]


def numbers(path):
    """该章决策一节里的决策号(含重复),没有这一节返回 None。"""
    text = open(path, encoding='utf-8').read()
    b = section_bounds(text)
    return None if b is None else decision_numbers(text, *b)


def write_atomic(path, text):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def fill_placeholders(text, chapter, num):
    """把 text 里第 chapter 章的占位换成 num,返回 (新文本, 换了几处)。"""
    count = 0

    def sub(m):
        nonlocal count
        if m.group(2) != chapter:
            return m.group(0)
        count += 1
        return m.group(1) + str(num)

    return PLACEHOLDER.sub(sub, text), count


def append(chapter, body_src, fill=()):
    path = chapter_file(chapter)
    if not path:
        sys.exit(f'找不到第 {chapter} 章的文档')
    chap = os.path.basename(path)[:2]
    body = (sys.stdin.read() if body_src == '-' else open(body_src, encoding='utf-8').read()).strip('\n')
    if not body.startswith('**'):
        sys.exit('正文要从 `**标题**` 开始写,不带编号')
    for f in fill:
        if not os.path.isfile(f):
            sys.exit(f'--fill 的文件不存在:{f}')
        if fill_placeholders(open(f, encoding='utf-8').read(), chap, 0)[1] == 0:
            sys.exit(f'{f} 里没有「{chap} 章决策 ??」占位,整条没写')
    with open(LOCK, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        text = open(path, encoding='utf-8').read()
        b = section_bounds(text)
        if b is None:
            sys.exit(f'{os.path.basename(path)} 里没有「## 设计决策与已知坑」一节')
        num = max(decision_numbers(text, *b), default=0) + 1
        head, tail = text[:b[1]].rstrip('\n'), text[b[1]:]
        write_atomic(path, head + '\n\n' + f'{num}. ' + body + '\n' + ('\n' + tail if tail else ''))
        filled = []
        for f in fill:
            new, count = fill_placeholders(open(f, encoding='utf-8').read(), chap, num)
            write_atomic(f, new)
            filled.append((f, count))
    print(f'{chap} 章决策 {num}')
    for f, count in filled:
        print(f'  填号 {os.path.relpath(f, ROOT)}: {count} 处')


def load_section(chapter):
    """(章号, 全文, 决策一节的边界);找不到章或这一节就退出。"""
    path = chapter_file(chapter)
    if not path:
        sys.exit(f'找不到第 {chapter} 章的文档')
    text = open(path, encoding='utf-8').read()
    b = section_bounds(text)
    if b is None:
        sys.exit(f'{os.path.basename(path)} 里没有「## 设计决策与已知坑」一节')
    return os.path.basename(path)[:2], text, b


def show(chapter, wanted):
    chap, text, (start, end) = load_section(chapter)
    entries = decision_entries(text, start, end)
    rc = 0
    for want in wanted:
        hits = [i for i, (n, _) in enumerate(entries) if n == want]
        if not hits:
            print(f'{chap} 章没有决策 {want}', file=sys.stderr)
            rc = 1
            continue
        if len(hits) > 1:
            print(f'{chap} 章决策 {want} 有 {len(hits)} 条,指针指不准', file=sys.stderr)
        for i in hits:
            stop = entries[i + 1][1] if i + 1 < len(entries) else end
            print(text[entries[i][1]:stop].rstrip('\n') + '\n')
    return rc


def which(chapter, lineno):
    chap, text, (start, end) = load_section(chapter)
    lines = text.split('\n')
    if not 1 <= lineno <= len(lines):
        sys.exit(f'没有第 {lineno} 行(全文 {len(lines)} 行)')
    offset = sum(len(l) + 1 for l in lines[:lineno - 1])
    owner = [(n, off) for n, off in decision_entries(text, start, end) if off <= offset]
    if not start <= offset < end or not owner:
        print(f'第 {lineno} 行不在「设计决策与已知坑」一节的决策里', file=sys.stderr)
        return 1
    n, off = owner[-1]
    title = text[off:].split('\n', 1)[0]
    print(f'{chap} 章决策 {n}: {title[:120]}')
    return 0


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
        rel = os.path.relpath(path, ROOT)
        for lineno, line in enumerate(lines, 1):
            # 本脚本的说明里要写出占位的样子,不算
            if os.path.abspath(path) != SELF and ANY_PLACEHOLDER.search(line):
                bad.append(f'{rel}:{lineno}: 决策号还是占位 ??,用 append <章> <正文文件> --fill <文件…> 分号并填上')
            if os.path.abspath(path) != SELF and KNOWN_ISSUE_REF.search(line):
                bad.append(f'{rel}:{lineno}: 指针写成了「已知坑」,核对不到;改成「NN 章决策 MM」,号用 show <章> <号> 对一眼内容')
            for m in REF.finditer(line):
                chapter = m.group(1)
                if chapter not in cache:
                    f = chapter_file(chapter)
                    cache[chapter] = numbers(f) if f else None
                nums = cache[chapter]
                for n in [m.group(2)] + re.findall(r'\d{1,3}', m.group(3)):
                    seen += 1
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
    if len(sys.argv) >= 4 and sys.argv[1] == 'show' and all(a.isdigit() for a in sys.argv[3:]):
        return show(sys.argv[2], [int(a) for a in sys.argv[3:]])
    if len(sys.argv) == 4 and sys.argv[1] == 'which' and sys.argv[3].isdigit():
        return which(sys.argv[2], int(sys.argv[3]))
    if len(sys.argv) == 4 and sys.argv[1] == 'append':
        append(sys.argv[2], sys.argv[3])
        return 0
    if len(sys.argv) >= 6 and sys.argv[1] == 'append' and sys.argv[4] == '--fill':
        append(sys.argv[2], sys.argv[3], sys.argv[5:])
        return 0
    print(__doc__.split('\n\n')[1], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
