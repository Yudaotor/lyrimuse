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
  - emoji 标记     ⚠️;要提醒就直接写约束句「别写成 X」「必须…」
  - 不可见字符     源码任何位置(不只注释)出现真的不换行空格 / 全角空格 / 零宽字符 / BOM / 行分隔符 /
                   控制字符;写成转义(反斜杠 u 加码点),真字符看不见,grep / diff / 评审都发现不了
  - (注释掉的旧代码:直接删,git 里有。这条机器判不了,靠评审。)

应该写:调用时序与并发约束、反直觉的取舍、量出来的常数及其出处、字段语义与外部系统的
实际行为。踩过的坑一律写成**护栏**「别写成 X:那样会…」,而不是「第一版写成 X,错了」。

拿不准时套三条:① 半年后的读者不知道这段历史,还需要这句话吗?② 它描述的是代码现在的
行为,还是它怎么变成这样的?③ 删掉它,会不会有人把这里改回错的样子?——会就写成护栏。

# 范围

只看注释:整行注释(以 // /// # * /* 开头)、行尾注释(`code // …`、`code /* … */`,Python 与 shell 是
`code # …`)和 Python 的文档字符串(模块 / 类 / 函数开头那一段,按语法树认)。行尾注释先去掉字符串和
rune 字面量(含跨行的三引号字符串、Go / JS 反引号字符串、Swift 原始字符串和 shell 的 heredoc),再取
注释标记之后的部分;shell heredoc 正文里的 XML 注释 `<!-- … -->`(build.sh 写 Info.plist 用)也算注释,所以字符串里的同样文字不算;shell 的 # 只在词首才算注释(`$#`、`${#x}` 不算)。
别的字符串字面量一律不扫 —— 误报的代价比漏报大,规则宁可窄。不可见字符那一条例外:扫整行,字符串和
rune 字面量里的同样算(这类字符最常藏在那里);允许的空白只有普通空格、tab、回车。命中任何一条即
非零退出并打印 `file:line`。

易误伤:注释里的「用户」多数指 **App 的最终用户**(正当语义),「这一轮 / 上一轮」在本仓
多指**一轮歌词源查询**(领域词) —— 所以人物归因那条只匹配「用户+要求/反馈/拍板…」这类
搭配,不匹配「用户」本身;轮次也不在规则里。`TODO` / `FIXME` / `XXX:` 前面紧挨着字母、数字或
下划线时是标识符的一部分(ID3 的 `TXXX` 帧名),不算。
"""

import ast
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCAN_DIRS = ['lyrimuse/Sources', 'lyrimuse/scripts', 'lyrimuse/Localization', 'lyrimuse-engine', 'web', 'scripts',
             'feishu-bot', '.githooks', '.github/scripts']
# 不在上面这些目录里、但同样有注释的单个文件。
SCAN_FILES = ['lyrimuse/Package.swift', 'lyrimuse/build.sh']
SKIP_DIRS = {'.build', '.git', 'node_modules', '__pycache__', 'vendor', 'DerivedData'}
# 本脚本自己必然写着每一类的**样例**,扫自己就是稳定误报(.githooks/commit-msg 同理,
# 它的说明里写着 `#123` 样例 —— selftest 里那条守卫也为此先剥注释再判)。
SKIP_FILES = {'scripts/check-comment-hygiene.py'}
EXTS = ('.swift', '.go', '.js', '.mjs', '.ts', '.py', '.sh')

# 整行注释。行尾注释由 trailing_comments() 先去掉字符串再取。
COMMENT_LINE = re.compile(r'^\s*(//|///|#|\*|/\*)')
C_LIKE_EXTS = ('.swift', '.go', '.js', '.mjs', '.ts')
SWIFT_RAW_OPEN = re.compile(r'(#+)("""|")')
SH_HEREDOC = re.compile(r'(?<!<)<<(-?)\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\2')
SH_WORD_START = set(' \t;&|()')

RULES = [
    (u'日期戳',
     re.compile(u'(?<!\\d)20\\d{2}[-/]\\d{1,2}[-/]\\d{1,2}(?!\\d)'),
     u'哪天改的归 git,注释只写现在是什么样'),
    (u'日期戳',
     re.compile(u'(?<!\\d)\\d{1,2}-\\d{1,2}\\s*(起|当天|那天|之前|以后)'),
     u'同上;「09-06 起」这种月日戳也算'),
    (u'迭代编号',
     re.compile(u'(第[一二三四五六七八九十0-9]+版|初版|首版|上一版|老版本里|本次改动|这次改动|此次改动|这轮改动|这一轮的目标)'),
     u'写成护栏「别写成 X:那样会…」,别写「第一版写成 X,错了」'),
    (u'人物归因',
     re.compile(u'(用户(要求|反馈|拍板|提出|指出|原话|报的|说的|自己说)|审阅(指出|提到|说)|你说的|按你说|我让你|老板说)'),
     u'谁提的不影响怎么读代码;注意「用户」指 App 最终用户时不算'),
    (u'工单清单引用',
     re.compile(u'(借鉴清单|审阅清单|清单\\s*#\\d|issue\\s*#\\d|discussions?\\s*#\\d)'),
     u'外部工单号归 docs/ 与 git;注释里写现象本身'),
    (u'迭代叙事',
     re.compile(u'(曾一度|(?<![0-9零一二三四五六七八九十百千第每])一度(?![音数分])|改前的(样子|行为)|跟改前|(?<!功能)简史)'),
     u'「一度写成 X」「改前是 Y」是过程,归 git 和 docs/;代码里只留约束「别写成 X:那样会…」'),
    (u'排查叙述',
     re.compile(u'(实测推翻|试了[^,。]{0,8}都不行|跑了\\s*\\d+\\s*\\+?\\s*轮|第[二三四五]次复现|当时怎么试)'),
     u'留结论、删过程;结论写成「别…:那样会…」'),
    (u'临时状态',
     re.compile(u'((?<![A-Za-z0-9_])(?:TODO|FIXME|XXX:)|待定|回头再改|先这样|暂时先|临时方案)'),
     u'真要留就开 issue,别留在代码里'),
    (u'emoji 标记',
     re.compile(u'\u26a0'),
     u'删掉 ⚠️,要提醒就直接写约束句「别写成 X」「必须…」'),
]

# 不可见字符:整行都扫。允许的空白只有普通空格、tab、回车。
INVISIBLE_OK = {chr(32), chr(9), chr(13)}
INVISIBLE_CATEGORIES = ('Zs', 'Zl', 'Zp', 'Cf', 'Cc')
INVISIBLE_HINT = u'写成转义(反斜杠 u 加码点),真字符看不见,grep / diff / 评审都发现不了'


def invisible_char(line):
    for ch in line:
        if ch not in INVISIBLE_OK and unicodedata.category(ch) in INVISIBLE_CATEGORIES:
            return ch
    return None


def _skip_quoted(line, i, quote):
    """line[i] 是开引号:返回配对的闭引号之后的位置,这一行里没闭合返回 None。反斜杠转义下一个字符。"""
    j = i + 1
    while j < len(line):
        if line[j] == '\\':
            j += 2
            continue
        if line[j] == quote:
            return j + 1
        j += 1
    return None


def _c_like_comments(lines, swift):
    """Swift / Go / JS 的行尾注释 {行号: 注释正文}。跨行的块注释、三引号字符串、反引号字符串、
    Swift 原始字符串都带着状态往下走,字符串里的 // 不算。"""
    out = {}
    close = None
    for no, line in enumerate(lines, 1):
        i, code, n = 0, False, len(line)
        if close is not None:
            end = line.find(close)
            if end < 0:
                continue
            i, close, code = end + len(close), None, True
        elif not any(t in line for t in ('//', '/*', '`', '"""')):
            continue
        while i < n:
            c = line[i]
            if line.startswith('//', i):
                if code:
                    out[no] = line[i + 2:]
                break
            if line.startswith('/*', i):
                end = line.find('*/', i + 2)
                if code:
                    out[no] = line[i + 2:end if end >= 0 else n]
                if end < 0:
                    close = '*/'
                    break
                i = end + 2
                continue
            m = SWIFT_RAW_OPEN.match(line, i) if swift and c == '#' else None
            if m:
                term = m.group(2) + m.group(1)
                end = line.find(term, m.end())
                code = True
                if end < 0:
                    close = term if m.group(2) == '"""' else None
                    break
                i = end + len(term)
                continue
            if line.startswith('"""', i):
                end = line.find('"""', i + 3)
                code = True
                if end < 0:
                    close = '"""'
                    break
                i = end + 3
                continue
            if c == '`':
                end = line.find('`', i + 1)
                code = True
                if end < 0:
                    close = None if swift else '`'
                    break
                i = end + 1
                continue
            if c in '"\'':
                end = _skip_quoted(line, i, c)
                code = True
                if end is None:
                    break
                i = end
                continue
            code = code or not c.isspace()
            i += 1
    return out


def _py_comments(lines):
    """Python 的行尾注释 {行号: 注释正文}。三引号字符串跨行带状态,字符串里的 # 不算。"""
    out = {}
    close = None
    for no, line in enumerate(lines, 1):
        i, code, n = 0, False, len(line)
        if close is not None:
            end = line.find(close)
            if end < 0:
                continue
            i, close, code = end + 3, None, True
        elif '#' not in line and '"""' not in line and "'''" not in line:
            continue
        while i < n:
            c = line[i]
            if c == '#':
                if code:
                    out[no] = line[i + 1:]
                break
            if c in '"\'':
                if line.startswith(c * 3, i):
                    end = line.find(c * 3, i + 3)
                    code = True
                    if end < 0:
                        close = c * 3
                        break
                    i = end + 3
                    continue
                end = _skip_quoted(line, i, c)
                code = True
                if end is None:
                    break
                i = end
                continue
            code = code or not c.isspace()
            i += 1
    return out


def _sh_comments(lines):
    """shell 的行尾注释 {行号: 注释正文}。# 在词首才算注释;引号跨行带状态跳过。heredoc 正文不按 shell 切,
    只取里面的 XML 注释 <!-- … -->(跨行带状态):build.sh 用 heredoc 写 Info.plist,那里的注释同样是给读代码的人看的。"""
    out = {}
    quote = None
    heredoc = None
    xml = False
    for no, line in enumerate(lines, 1):
        if heredoc is not None:
            word, dash = heredoc
            if (line.lstrip('\t') if dash else line) == word:
                heredoc, xml = None, False
                continue
            body, rest = [], line
            while True:
                if xml:
                    end = rest.find('-->')
                    body.append(rest if end < 0 else rest[:end])
                    if end < 0:
                        break
                    xml, rest = False, rest[end + 3:]
                else:
                    start = rest.find('<!--')
                    if start < 0:
                        break
                    xml, rest = True, rest[start + 4:]
            if body:
                out[no] = ' '.join(body)
            continue
        i, code, n = 0, False, len(line)
        if quote is not None:
            end = line.find("'") + 1 if quote == "'" else (_skip_quoted(' ' + line, 0, '"') or 0) - 1
            if end <= 0:
                continue
            i, quote, code = end, None, True
        cut = n
        while i < n:
            c = line[i]
            if c == '#' and (i == 0 or line[i - 1] in SH_WORD_START):
                if code:
                    out[no] = line[i + 1:]
                cut = i
                break
            if c == '\\':
                code = True
                i += 2
                continue
            if c == "'":
                end = line.find("'", i + 1)
                code = True
                if end < 0:
                    quote = "'"
                    break
                i = end + 1
                continue
            if c == '"':
                end = _skip_quoted(line, i, '"')
                code = True
                if end is None:
                    quote = '"'
                    break
                i = end
                continue
            code = code or not c.isspace()
            i += 1
        m = SH_HEREDOC.search(line[:cut])
        if m and quote is None:
            heredoc = (m.group(3), m.group(1) == '-')
    return out


# 行尾注释切分的自检样例:(扩展名, 源码, 期望的 {行号: 注释正文})。全仓扫描前先跑一遍,切错了直接退出码 2,不拿错的切分去扫。
TRAILING_SAMPLES = [
    ('.go', u'x := 1 // 是\ns := "http://a // 不是"\nq := `\n// 不是\n` // 是\n', {1: u' 是', 5: u' 是'}),
    ('.swift', u'let a = "x" /* 是 */ + "y"\nlet r = #"a "// 不是" b"#\nlet m = """\n  // 不是\n  """ // 是\n',
     {1: u' 是 ', 5: u' 是'}),
    ('.js', u'const t = `a\n// 不是\n`; // 是\n', {3: u' 是'}),
    ('.py', u's = "# 不是"  # 是\nt = """\n# 不是\n"""  # 是\n', {1: u' 是', 4: u' 是'}),
    ('.sh', u'n=${#arr[@]} # 是\necho "$#"\ncat <<EOF\nx # 不是\nEOF\nk=1#不是\nv="a\n# 不是" # 是\n',
     {1: u' 是', 8: u' 是'}),
    ('.sh', u'cat > p <<P\n<a/> <!-- 是 --> <b/>\n<!-- 是\n  也是 -->\n<c>不是</c>\nP\n<!-- 不是 -->\n',
     {2: u' 是 ', 3: u' 是', 4: u'  也是 '}),
]


def trailing_selftest():
    """行尾注释切分跑一遍样例,返回出错的样例说明(空列表 = 全对)。"""
    bad = []
    for ext, src, want in TRAILING_SAMPLES:
        got = trailing_comments('sample' + ext, src.split('\n'))
        if got != want:
            bad.append(u'%s 样例:期望 %r,实际 %r' % (ext, want, got))
    got = [(h[1], h[2]) for h in scan_text(os.path.join(ROOT, 'sample.go'),
                                           u'x := 1 // 09-02 起改\ns := "// 2026-09-02"\n')]
    if got != [(1, u'日期戳')]:
        bad.append(u'行尾注释没套词表:期望 [(1, 日期戳)],实际 %r' % (got,))
    return bad


def trailing_comments(fp, lines):
    """这个文件里每一行的行尾注释正文 {行号: 文本}(整行注释不在里面,照旧按整行扫)。"""
    if fp.endswith(C_LIKE_EXTS):
        return _c_like_comments(lines, fp.endswith('.swift'))
    if fp.endswith('.py') or (lines and 'python' in lines[0]):
        return _py_comments(lines)
    return _sh_comments(lines)


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
    for rel in SCAN_FILES:
        fp = os.path.join(ROOT, rel)
        if os.path.isfile(fp) and wanted(fp):
            yield fp


def docstring_lines(fp, text):
    """Python 文件里模块 / 类 / 函数文档字符串占的行号;别的文件、解析不了的文件都是空集。"""
    if not fp.endswith('.py'):
        return set()
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return set()
    out = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) or not node.body:
            continue
        first = node.body[0]
        if isinstance(first, ast.Expr) and isinstance(getattr(first, 'value', None), ast.Constant) \
                and isinstance(first.value.value, str):
            out.update(range(first.lineno, first.end_lineno + 1))
    return out


def scan_text(fp, text):
    """一个文件的全部命中:[(相对路径, 行号, 规则名, 命中片段, 提示, 整行)]。"""
    hits = []
    rel = os.path.relpath(fp, ROOT)
    lines = text.split('\n')
    docs = docstring_lines(fp, text)
    trailing = trailing_comments(fp, lines)
    for i, line in enumerate(lines, 1):
        ch = invisible_char(line)
        if ch is not None:
            frag = u'U+%04X %s' % (ord(ch), unicodedata.name(ch, ''))
            hits.append((rel, i, u'不可见字符', frag, INVISIBLE_HINT, line.strip()))
        if COMMENT_LINE.match(line) or i in docs:
            target = line
        elif i in trailing:
            target = trailing[i]
        else:
            continue
        for name, pat, hint in RULES:
            m = pat.search(target)
            if m:
                hits.append((rel, i, name, m.group(0), hint, line.strip()))
    return hits


def main(argv):
    if argv == ['--selftest'] or not argv:
        bad = trailing_selftest()
        if bad:
            print(u'注释卫生检查:行尾注释切分自检没过,检查器自己坏了')
            for b in bad:
                print(u'  ' + b)
            return 2
        if argv:
            print(u'行尾注释切分自检:通过')
            return 0
    hits = []
    for fp in iter_files(argv):
        try:
            with open(fp, encoding='utf-8') as f:
                text = f.read()
        except (UnicodeDecodeError, OSError):
            continue
        hits.extend(scan_text(fp, text))

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
