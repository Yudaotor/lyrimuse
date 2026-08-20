#!/usr/bin/env python3
"""导出 Last.fm 全部听过的歌曲成 markdown,带同曲变体归并。

归并规则(2026-08-18 与用户逐对核定,口径与 export-lastfm-albums.py 一致):
  基础: 简繁折叠(外部 t2s 映射)+字形变体折叠表(日文兼容字,如 晩→晚)/NFKC/大小写/标点、
        歌手别名统一(与 collector artistAliasTable 同步)。
  T1 (feat. …)/(with …) 客串标记剥除——客串不改变是哪首歌。
  T2 再版标签: 括号内 Remaster/Explicit/Bonus Track 剥除;无括号尾缀 "- <年份> Remaster(ed)"
      同剥(重制=同一录音;Bad - 2012 Remaster = Bad)。
  T3 词形归一: Inst./Inst → Instrumental(Love Outrolude (Inst.) = … - Instrumental)。
  R1 双语拼接名、R3 歌手名剥除:同专辑脚本。
  手工对: 陈奕迅 愛情轉移(國) = 爱情转移(《爱情转移》本身就是国语版,(國) 是冗余标记)。
  刻意不做: Live/演唱会版、钢琴版/獨唱版/伴奏/Karaoke、Remix/Club Mix/Sped Up、
      英日双语版本、(Alternate)、(original version)(Xscape 原始版是另一套制作)、
      (single version)/(7" Single Edit)(用户未拍板,保留独立)、Medley: 前缀、前缀/子集归并。

用法: python3 export-lastfm-tracks.py <t2s合并映射.tsv> <tracks-raw.json> <输出.md>
  t2s 映射 TSV: 每行 "原文\t简体",由 ICU CFStringTransform 生成。
"""
import json, re, sys, unicodedata
from datetime import date

ALIAS = {'david tao':'陶喆','jason chan':'陈柏宇','kun':'蔡徐坤','dean ting':'丁世光','crowd lu':'卢广仲',
'leah dou':'窦靖童','soft lipa':'蛋堡','diana wang':'王诗安','a si':'阿肆','eve ai':'艾怡良',
'nicky lee':'李玖哲','utada':'宇多田ヒカル','hikaru utada':'宇多田ヒカル','宇多田光':'宇多田ヒカル',
'wanting':'曲婉婷','ronghao li':'李荣浩','matt lv':'吕彦良',
'pei-yu hung':'洪佩瑜','lexie liu':'刘柏辛','sodagreen':'苏打绿','zhang yu sheng':'张雨生',
'khalil fong':'方大同','jay chou':'周杰伦'}
VARIANTS = str.maketrans({'晩': '晚'})  # 日文兼容字→中文正字,按实际撞到的补
FEAT = re.compile(r'\s*[\(\[（]\s*(feat\.?|featuring|with)\s[^)\]）]*[\)\]）]', re.I)
EDITION = re.compile(r'\s*[\(\[（【](?=[^)\]）】]*(remaster|explicit|bonus track))[^)\]）】]*[\)\]）】]', re.I)
REMASTER_SUFFIX = re.compile(r'\s*[-–]\s*(\d{4}\s*)?remaster(ed)?(\s*\d{4})?\s*$', re.I)
INST = re.compile(r'\binst\.?(?=\W|$)', re.I)
# 手工对的歌手键用**折叠后的简体键**匹配(显示名可能是繁体「陳奕迅」,直接比显示名会漏)
HAND = {('陈奕迅', '愛情轉移(國)'): '爱情转移'}

def main(t2s_tsv, raw_json, out_md):
    t2s = {}
    for line in open(t2s_tsv):
        parts = line.rstrip('\n').split('\t')
        if len(parts) == 2: t2s[parts[0]] = parts[1]
    rows = json.load(open(raw_json))

    def fold(s):
        s = unicodedata.normalize('NFKC', s).casefold().translate(VARIANTS)
        return re.sub(r'[\s\W_]+', '', s)
    def artdisp(a): return ALIAS.get(a.strip().lower(), ALIAS.get(a.strip(), a))
    def artkey(a): return fold(t2s.get(artdisp(a), artdisp(a)))

    writings = {}
    for r in rows:
        writings.setdefault(artkey(r['artist']), set()).add(r['artist'].strip())
    for roman, canon in ALIAS.items():
        writings.setdefault(fold(t2s.get(canon, canon)), set()).update({roman, canon})

    def trkeys(track, ak, adisp):
        for (ha, hv), canon in HAND.items():
            if fold(t2s.get(ha, ha)) == ak and track == hv:
                track = canon
        s = t2s.get(track, track)
        s = FEAT.sub('', s); s = EDITION.sub('', s); s = REMASTER_SUFFIX.sub('', s)
        s = INST.sub('instrumental', s)
        low = unicodedata.normalize('NFKC', s).casefold()
        for w in sorted(writings.get(ak, ()), key=len, reverse=True):
            w2 = unicodedata.normalize('NFKC', t2s.get(w, w)).casefold()
            if w2 and w2 in low:
                stripped = low.replace(w2, ' ')
                if fold(stripped): low = stripped
        base = fold(low)
        keys = {base} if base else {fold(track)}
        runs, cur = [], None
        for ch in base:
            kind = 'h' if '一' <= ch <= '鿿' else ('l' if ch.isascii() else 'x')
            if kind == 'x': continue
            if cur and cur[0] == kind: cur[1] += ch
            else: cur = [kind, ch]; runs.append(cur)
        if len(runs) == 2 and {runs[0][0], runs[1][0]} == {'h', 'l'}:
            for _, seg in runs:
                if len(seg) >= 2: keys.add(seg)
        return keys

    n = len(rows); parent = list(range(n))
    def find(x):
        while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb: parent[ra] = rb
    groups = {}
    for i, r in enumerate(rows):
        ak = artkey(r['artist'])
        for k in trkeys(r['track'], ak, artdisp(r['artist'])):
            groups.setdefault((ak, k), []).append(i)
    for idxs in groups.values():
        for j in idxs[1:]: union(idxs[0], j)

    buckets, order = {}, []
    for i, r in enumerate(rows):
        root = find(i); b = buckets.get(root)
        if b is None:
            b = {'track': r['track'], 'artist': artdisp(r['artist']), 'plays': 0, 'members': []}
            buckets[root] = b; order.append(root)
        b['plays'] += r['plays']; b['members'].append((r['track'], r['artist'], r['plays']))
    out = sorted(buckets.values(), key=lambda m: (-m['plays'], m['artist'], m['track']))

    total = sum(m['plays'] for m in out)
    today = date.today().isoformat()
    lines = ['# Last.fm 全部听过的歌曲', '',
      f'> 生成于 {today} · 历史累计(overall) · 归并规则见附录 C',
      f'> 共 {len(out)} 首 · 合计播放 {total:,} 次', '',
      '| # | 歌曲 | 歌手 | 播放次数 |', '|---:|---|---|---:|']
    for i, m in enumerate(out, 1):
        lines.append(f"| {i} | {m['track']} | {m['artist']} | {m['plays']:,} |")
    mergedRows = [m for m in out if len(m['members']) > 1 or {a for _, a, _ in m['members']} != {m['artist']}]
    lines += ['', '---', '', f'## 附录 A · 发生过归并的条目(共 {len(mergedRows)} 条)', '',
      '| 归并后 | 歌手 | 合计 | 由哪些原始条目合成(各自次数) |', '|---|---|---:|---|']
    for m in mergedRows:
        variants = ' + '.join(f'{a}({p})' for a, _, p in m['members'])
        lines.append(f"| {m['track']} | {m['artist']} | {m['plays']:,} | {variants} |")
    lines += ['', '## 附录 B · 刻意保留独立的类别(不同录音/未拍板,勿并)', '',
      '- Live/演唱会版、钢琴版/獨唱版/伴奏/Karaoke、Remix/Club Mix/Sped Up',
      '- 英日双语版本(Face My Fears EN/JP)、(Alternate)、COLORS Show',
      '- Xscape 的 (original version)(与当代化版是两套制作)',
      '- (single version)/(7" Single Edit) 单曲剪辑(未拍板,保留)',
      '- Medley: 前缀、世界未末日/世界末日(未拍板,保留)', '',
      '## 附录 C · 归并规则', '',
      '1. 简繁折叠+字形变体表(晩→晚)/NFKC/大小写/标点;歌手别名统一',
      '2. (feat./with …) 客串标记剥除',
      '3. 再版标签剥除: 括号 Remaster/Explicit/Bonus Track + 尾缀 "- <年份> Remaster(ed)"',
      '4. Inst./Inst → Instrumental 词形归一',
      '5. R1 双语拼接名、R3 歌手名剥除(同专辑导出)',
      '6. 手工对: 愛情轉移(國) = 爱情转移']
    open(out_md, 'w').write('\n'.join(lines) + '\n')
    print(f'merged: {len(out)} buckets (raw {n}), total {total}, merged-buckets {len(mergedRows)}')
    return out

if __name__ == '__main__':
    main(*sys.argv[1:4])
