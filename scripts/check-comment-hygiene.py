#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注释卫生检查:代码注释里不许出现过程性内容。

    python3 scripts/check-comment-hygiene.py            # 全仓
    python3 scripts/check-comment-hygiene.py <文件…>    # 只查指定文件(pre-commit 用)

# 规则

注释只写**现状与约束** —— 读代码的人现在需要知道什么;不写这段代码是怎么演变成这样的。
过程性内容归 git(`git log -S '<注释原文>'` 能定位到当时那次改动)和 `docs/`。

不允许出现(下面 RULES 逐条对应):

  - 日期戳         2026-08-22 / 09-07 起 / 08-16 之前
  - 迭代编号       第一版 / 初版 / 上一版 / 本次改动 / 这一轮的目标
  - 人物归因       用户要求 / 用户反馈 / 审阅指出 / 你说的 / 我让你
  - 工单清单引用   借鉴清单 #57 / issue #5 / discussions#6
  - 排查叙述       试了三种方案都不行 / 跑了 30+ 轮 / 实测推翻了…
  - 临时状态       TODO / 待定 / 先这样 / 回头再改;真要留就开 issue
  - (注释掉的旧代码:直接删,git 里有。这条机器判不了,靠评审。)

应该写:调用时序与并发约束、反直觉的取舍、量出来的常数及其出处、字段语义与外部系统的
实际行为。踩过的坑一律写成**护栏**「⚠️ 别写成 X:那样会…」,而不是「第一版写成 X,错了」。

拿不准时套三条:① 半年后的读者不知道这段历史,还需要这句话吗?② 它描述的是代码现在的
行为,还是它怎么变成这样的?③ 删掉它,会不会有人把这里改回错的样子?——会就写成 ⚠️ 护栏。

# 范围

只看**注释行**(整行以 // /// # * /* 开头);行尾注释和字符串字面量不扫 —— 误报的代价比
漏报大,规则宁可窄。命中任何一条即非零退出并打印 `file:line`。

易误伤:注释里的「用户」多数指 **App 的最终用户**(正当语义),「这一轮 / 上一轮」在本仓
多指**一轮歌词源查询**(领域词) —— 所以人物归因那条只匹配「用户+要求/反馈/拍板…」这类
搭配,不匹配「用户」本身;轮次也不在规则里。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCAN_DIRS = ['lyrimuse/Sources', 'lyrimuse/scripts', 'lyrimuse-collector', 'web', 'scripts', 'feishu-bot', '.githooks']
SKIP_DIRS = {'.build', '.git', 'node_modules', '__pycache__', 'vendor', 'DerivedData'}
# 本脚本自己必然写着每一类的**样例**,扫自己就是稳定误报(.githooks/commit-msg 同理,
# 它的说明里写着 `#123` 样例 —— selftest 里那条守卫也为此先剥注释再判)。
SKIP_FILES = {'scripts/check-comment-hygiene.py'}
EXTS = ('.swift', '.go', '.js', '.mjs', '.ts', '.py', '.sh')

# 整行注释才扫。行尾注释(`code // …`)与字符串里的同样文字一律放过。
COMMENT_LINE = re.compile(r'^\s*(//|///|#|\*|/\*)')

RULES = [
    (u'日期戳',
     re.compile(u'(?<!\\d)20\\d{2}[-/]\\d{1,2}[-/]\\d{1,2}(?!\\d)'),
     u'哪天改的归 git,注释只写现在是什么样'),
    (u'日期戳',
     re.compile(u'(?<!\\d)\\d{1,2}-\\d{1,2}\\s*(起|当天|那天|之前|以后)'),
     u'同上;「09-06 起」这种月日戳也算'),
    (u'迭代编号',
     re.compile(u'(第[一二三四五六七八九十0-9]+版|初版|首版|上一版|老版本里|本次改动|这次改动|此次改动|这轮改动|这一轮的目标)'),
     u'写成护栏「⚠️ 别写成 X:那样会…」,别写「第一版写成 X,错了」'),
    (u'人物归因',
     re.compile(u'(用户(要求|反馈|拍板|提出|指出|原话|报的|说的|自己说)|审阅(指出|提到|说)|你说的|按你说|我让你|老板说)'),
     u'谁提的不影响怎么读代码;注意「用户」指 App 最终用户时不算'),
    (u'工单清单引用',
     re.compile(u'(借鉴清单|审阅清单|清单\\s*#\\d|issue\\s*#\\d|discussions?\\s*#\\d)'),
     u'外部工单号归 docs/ 与 git;注释里写现象本身'),
    (u'排查叙述',
     re.compile(u'(实测推翻|试了[^,。]{0,8}都不行|跑了\\s*\\d+\\s*\\+?\\s*轮|第[二三四五]次复现|当时怎么试)'),
     u'留结论、删过程;结论写成「⚠️ 别…:那样会…」'),
    (u'临时状态',
     re.compile(u'(TODO|FIXME|XXX:|待定|回头再改|先这样|暂时先|临时方案)'),
     u'真要留就开 issue,别留在代码里'),
]


def wanted(path):
    """.githooks 下的 hook 没有扩展名,按 shebang 认。"""
    if os.path.relpath(path, ROOT) in SKIP_FILES:
        return False
    if path.endswith(EXTS):
        return True
    if os.sep + '.githooks' + os.sep not in path:
        return False
    try:
        with open(path, 'rb') as f:
            return f.read(2) == b'#!'
    except OSError:
        return False


def iter_files(argv):
    if argv:
        for a in argv:
            p = a if os.path.isabs(a) else os.path.join(ROOT, a)
            if os.path.isfile(p) and wanted(p):
                yield p
        return
    for d in SCAN_DIRS:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for dp, dns, fns in os.walk(base):
            dns[:] = [x for x in dns if x not in SKIP_DIRS]
            for fn in fns:
                fp = os.path.join(dp, fn)
                if wanted(fp):
                    yield fp


def main(argv):
    hits = []
    for fp in iter_files(argv):
        try:
            with open(fp, encoding='utf-8') as f:
                lines = f.read().split('\n')
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(lines, 1):
            if not COMMENT_LINE.match(line):
                continue
            for name, pat, hint in RULES:
                m = pat.search(line)
                if m:
                    hits.append((os.path.relpath(fp, ROOT), i, name, m.group(0), hint, line.strip()))

    if not hits:
        print(u'注释卫生检查:通过')
        return 0

    by_rule = {}
    for h in hits:
        by_rule.setdefault(h[2], []).append(h)
    for name in by_rule:
        print(u'\n[%s] %d 处 —— %s' % (name, len(by_rule[name]), by_rule[name][0][4]))
        for rel, ln, _, frag, _, text in by_rule[name]:
            print(u'  %s:%d  命中「%s」' % (rel, ln, frag))
            print(u'      %s' % text[:120])
    print(u'\n共 %d 处。规则见本脚本开头的文档字符串。' % len(hits))
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
