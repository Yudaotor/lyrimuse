#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""引擎(Go)变异测试:一批变异只编一次测试二进制,按环境变量逐个切换着跑。

    python3 scripts/go-mutate.py <变异清单.py> --work <工作目录> [--run <正则>] [--full-on-survive] [--keep]

变异清单是一个 Python 文件:
    RUN = "Amazon|SearchQuery"                       # 每个变异跑哪些测试(-test.run 的正则),也可以用 --run 给
    MUTANTS = [
        ("amazonlibrary.go", "原文片段", "换成的片段", "名字"),   # 原文在文件里必须恰好出现一次
        ...
    ]
文件路径相对引擎目录(默认 lyrimuse-engine/)。

做法:先把仓库克隆进 <工作目录>/clone(cp -c,跳过 .git 和 .build),工作区一个字节都不动。每个变异落在哪个函数体里,
就在那个函数体开头插一段「开关等于这个变异时,走改过的函数体副本」(scripts/go-mutate-ast.go 生成),经 go test -overlay
交给编译器,编一次。逐个变异跑的时候设环境变量打开它,同时把克隆里那个文件的磁盘内容换成变异后的原文(读源码原文的
测试也能看到变异),跑完换回;-test.run 选中的测试第一个失败就停。判定跟每个变异单独改文件、单独编译一致。

不在函数体里的变异(包级变量、类型、函数签名)整份文件替换、单独编译。改过的函数体副本编不过的(比如变量没用上)
报「编译不过」,不算抓到,换个写法再跑。基线(不开任何变异)先跑一遍,不绿就停。

--full-on-survive  没抓到的变异再拿整套测试跑一遍(不重编,同一份二进制),看是别的测试能抓到、还是真没盖住。
--classic          每个变异各编一次(慢,每个约 20 秒),核对开关做法的判定时用。
--keep             跑完留下克隆、编译缓存和二进制(接着改测试再跑时省掉冷编);默认跑完删掉,只留报告和日志。

退出码:0 全部抓到;1 有没抓到或编译不过的;2 清单、基线或工具本身出错。
"""
import argparse
import json
import os
import re
import runpy
import shutil
import signal
import subprocess
import sys
import time

GO_ENV = {'GOTOOLCHAIN': 'go1.24.4', 'GOFLAGS': ''}
SWITCH_VAR = 'goMutateActiveID'
SWITCH_ENV = 'GO_MUTATE_ID'
MARKER = '.go-mutate-work'
ERROR_LINE = re.compile(r'^(?:\./)?(?P<path>[^\s:]+\.go):(?P<line>\d+):(?:\d+:)? (?P<msg>.*)$')
FAIL_LINE = re.compile(r'^\s*--- FAIL: (\S+)', re.M)


def log(msg):
    print(msg, flush=True)


def die(msg):
    print('go-mutate: ' + msg, file=sys.stderr, flush=True)
    sys.exit(2)


def make_clone(repo, dest):
    """整个仓库按原相对位置克隆过来:引擎测试会读 ../lyrimuse、../shared、../docs、README 等,名单一直在变。"""
    os.makedirs(dest)
    for name in sorted(os.listdir(repo)):
        if name in ('.git', '.build'):
            continue
        src = os.path.join(repo, name)
        if name == 'lyrimuse' and os.path.isdir(src):
            os.makedirs(os.path.join(dest, name))
            for sub in sorted(os.listdir(src)):
                if sub != '.build':
                    subprocess.run(['cp', '-c', '-R', os.path.join(src, sub), os.path.join(dest, name, sub)], check=True)
            continue
        subprocess.run(['cp', '-c', '-R', src, os.path.join(dest, name)], check=True)


def load_spec(path, run_override):
    ns = runpy.run_path(path)
    raw = ns.get('MUTANTS')
    if not isinstance(raw, (list, tuple)) or not raw:
        die('清单里没有 MUTANTS,或者是空的')
    mutants = []
    for i, m in enumerate(raw, 1):
        if not (isinstance(m, (list, tuple)) and len(m) == 4 and all(isinstance(x, str) for x in m)):
            die('MUTANTS 第 %d 条要写成 (文件, 原文, 换成, 名字) 四个字符串' % i)
        f, old, new, name = m
        if '/' in f:
            die('MUTANTS 第 %d 条:文件 %s 要直接在引擎目录下(只支持一个包)' % (i, f))
        if old == new:
            die('MUTANTS 第 %d 条「%s」原文和换成的一样' % (i, name))
        mutants.append({'id': str(i), 'file': f, 'old': old, 'new': new, 'name': name})
    run = run_override or ns.get('RUN')
    if not run:
        die('没给要跑的测试:清单里写 RUN = "...",或者加 --run(要跑整套就明写 --run .)')
    return mutants, run


class Runner:
    def __init__(self, args, engine, work):
        self.args = args
        self.engine = engine
        self.work = work
        self.gen = os.path.join(work, 'gen')
        self.bin = os.path.join(work, 'bin')
        self.logs = os.path.join(work, 'logs')
        for d in (self.gen, self.bin, self.logs):
            os.makedirs(d, exist_ok=True)
        self.env = dict(os.environ, GOCACHE=os.path.join(work, 'gocache'), **GO_ENV)
        self.env.pop(SWITCH_ENV, None)
        self.originals = {}
        self.build_count, self.build_secs, self.run_count, self.run_secs = 0, 0.0, 0, 0.0

    def go(self, argv, log_name, cache=None):
        env = dict(self.env, GOCACHE=cache) if cache else self.env
        t0 = time.time()
        r = subprocess.run(['nice', '-n', '10', 'go'] + argv, cwd=self.engine, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode('utf-8', 'replace')
        with open(os.path.join(self.logs, log_name), 'w', encoding='utf-8') as fh:
            fh.write(out)
        secs = time.time() - t0
        self.build_count += 1
        self.build_secs += secs
        return r.returncode, out, secs

    def build(self, overlay, binary, log_name, throwaway_cache=False):
        """throwaway_cache:在编译缓存的 APFS 克隆上编、编完删掉,单独编译的变异每个约 80 MB 产物不留进缓存。"""
        path = os.path.join(self.gen, log_name + '.overlay.json')
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump({'Replace': overlay}, fh, ensure_ascii=False, indent=1)
        argv = ['test', '-c', '-o', binary, '-vet=off', '-gcflags=-e', '-overlay', path]
        if self.args.tags:
            argv += ['-tags', self.args.tags]
        if not throwaway_cache:
            return self.go(argv + ['.'], log_name + '.build.log')
        cache = self.env['GOCACHE'] + '-' + log_name
        if os.path.exists(self.env['GOCACHE']):
            subprocess.run(['cp', '-c', '-R', self.env['GOCACHE'], cache], check=True)
        try:
            return self.go(argv + ['.'], log_name + '.build.log', cache=cache)
        finally:
            if os.path.exists(cache):
                shutil.rmtree(cache)

    def run(self, binary, m, run_regex, timeout, log_name, failfast=True, switch=True):
        """m 不是 None 时:磁盘上那个文件换成变异后的原文再跑,跑完换回;switch 为真时同时打开二进制里的开关。"""
        env = dict(self.env)
        path = None
        if m is not None:
            if switch:
                env[SWITCH_ENV] = m['id']
            path = os.path.join(self.engine, m['file'])
            orig = self.originals.setdefault(path, open(path, 'rb').read())
            old, new = m['old'].encode('utf-8'), m['new'].encode('utf-8')
            if orig.count(old) != 1:
                die('#%s 的原文在 %s 里不是恰好一次' % (m['id'], path))
            with open(path, 'wb') as fh:
                fh.write(orig.replace(old, new, 1))
        argv = ['nice', '-n', '10', binary, '-test.run', run_regex, '-test.timeout', '%ds' % timeout]
        if failfast:
            argv.append('-test.failfast')
        t0 = time.time()
        try:
            r = subprocess.run(argv, cwd=self.engine, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=timeout + 60)
            rc, out = r.returncode, r.stdout.decode('utf-8', 'replace')
        except subprocess.TimeoutExpired as e:
            rc, out = -1, (e.stdout or b'').decode('utf-8', 'replace') + '\n(go-mutate: 进程没在时限内退出,已杀掉)'
        finally:
            if path:
                with open(path, 'wb') as fh:
                    fh.write(self.originals[path])
        with open(os.path.join(self.logs, log_name), 'w', encoding='utf-8') as fh:
            fh.write(out)
        secs = time.time() - t0
        self.run_count += 1
        self.run_secs += secs
        return rc, out, secs

    def check_restored(self):
        for path, orig in self.originals.items():
            if open(path, 'rb').read() != orig:
                die('%s 没还原成原文' % path)

    def schemata(self, mutants, classic_ids):
        req = {'dir': self.engine, 'out': self.gen, 'switch_var': SWITCH_VAR, 'env': SWITCH_ENV,
               'mutants': [{k: m[k] for k in ('id', 'file', 'old', 'new')} for m in mutants],
               'classic': sorted(classic_ids)}
        helper = self.args.helper
        r = subprocess.run(['go', 'run', helper], cwd=os.path.dirname(helper), env=self.env,
                           input=json.dumps(req, ensure_ascii=False).encode('utf-8'),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            die('生成变异源码失败:\n' + r.stderr.decode('utf-8', 'replace'))
        gen = json.loads(r.stdout.decode('utf-8'))
        for k in ('guards', 'classic', 'errors', 'notes'):
            gen[k] = gen.get(k) or []
        gen['overlay'] = gen.get('overlay') or {}
        return gen


def first_failure(out):
    if 'panic: test timed out after' in out:
        m = re.search(r'running tests:\s*\n\s*(\S+)', out)
        return '超时' + (' ' + m.group(1) if m else '')
    m = FAIL_LINE.search(out)
    if m:
        return m.group(1)
    if 'panic:' in out:
        return 'panic'
    return '退出码非零'


def compile_errors(out):
    rows = []
    for line in out.splitlines():
        m = ERROR_LINE.match(line.strip())
        if m:
            rows.append((os.path.basename(m.group('path')), int(m.group('line')), m.group('msg')))
    return rows


def main():
    ap = argparse.ArgumentParser(description='引擎变异测试:一批变异编一次,逐个切换着跑')
    ap.add_argument('spec')
    ap.add_argument('--work', required=True, help='工作目录(放克隆、生成的源码、二进制、日志、报告),不存在会新建')
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help='从哪棵工作区克隆,默认这个脚本所在的仓库')
    ap.add_argument('--clone', help='用现成的克隆(不新建、跑完也不删)')
    ap.add_argument('--pkg', default='lyrimuse-engine', help='包目录,相对克隆根目录')
    ap.add_argument('--run', help='覆盖清单里的 RUN')
    ap.add_argument('--tags', default='devtools', help='构建标签,跟提交校验一致默认 devtools;传空串不带')
    ap.add_argument('--full-on-survive', action='store_true')
    ap.add_argument('--classic', action='store_true')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--helper', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'go-mutate-ast.go'))
    args = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(2))

    t_start = time.time()
    mutants, run_regex = load_spec(args.spec, args.run)
    work = os.path.abspath(args.work)
    repo = os.path.realpath(args.repo)
    if os.path.exists(work) and os.listdir(work) and not os.path.exists(os.path.join(work, MARKER)):
        die('%s 已经有别的东西,换一个空目录' % work)
    os.makedirs(work, exist_ok=True)
    open(os.path.join(work, MARKER), 'w').close()

    made_clone = None
    if args.clone:
        root = os.path.realpath(args.clone)
    else:
        root = os.path.join(work, 'clone')
        if os.path.exists(root):
            shutil.rmtree(root)
        t0 = time.time()
        make_clone(repo, root)
        made_clone = root
        log('克隆 %s → %s(%.1f 秒)' % (repo, root, time.time() - t0))
    if root == repo or root.startswith(repo + os.sep):
        die('不能直接在工作区里跑变异(别的会话随时可能开编),给 --clone 一份克隆或者别传 --clone')
    engine = os.path.join(root, args.pkg)
    if not os.path.isdir(engine):
        die('包目录不存在: ' + engine)

    rn = Runner(args, engine, work)
    by_id = {m['id']: m for m in mutants}
    order = {m['id']: i for i, m in enumerate(mutants)}
    verdict = {}
    classic_ids = set(by_id) if args.classic else set()
    invalid = {}

    # 生成 + 编译;函数体副本编不过的变异剔掉再编,直到编过。
    binary = os.path.join(rn.bin, 'schemata.test')
    builds = 0
    while True:
        live = [m for m in mutants if m['id'] not in invalid]
        gen = rn.schemata(live, classic_ids & {m['id'] for m in live})
        if gen['errors']:
            die('清单有问题:\n' + '\n'.join('  #%s「%s」%s' % (e['id'], by_id[e['id']]['name'], e['msg']) for e in gen['errors']))
        notes = {n['id']: n['msg'] for n in gen['notes']}
        classic = sorted(gen['classic'], key=lambda c: order[c['id']])
        guards = sorted(gen['guards'], key=lambda g: order[g['id']])
        if not guards:
            break
        rc, out, secs = rn.build(gen['overlay'], binary, 'schemata-%d' % builds)
        builds += 1
        log('编译(%d 个变异编进同一份二进制)%s,%.1f 秒' % (len(guards), '通过' if rc == 0 else '没过', secs))
        if rc == 0:
            break
        hit = {}
        unmapped = []
        for base, line, msg in compile_errors(out):
            owner = [g['id'] for g in guards if os.path.basename(g['file']) == base and g['start_line'] <= line <= g['end_line']]
            if owner:
                hit.setdefault(owner[0], msg)
            else:
                unmapped.append('%s:%d: %s' % (base, line, msg))
        if unmapped or not hit:
            die('编译错误不在任何变异副本里(多半是工具没处理到的写法),日志 %s:\n%s' %
                (os.path.join(rn.logs, 'schemata-%d.build.log' % (builds - 1)), '\n'.join(unmapped[:20]) or out[-3000:]))
        for mid in sorted(hit, key=lambda x: order[x]):
            invalid[mid] = hit[mid]
            log('  #%s「%s」编译不过: %s' % (mid, by_id[mid]['name'], hit[mid]))

    # 基线:同一份二进制不开任何变异,选中的测试必须全绿、而且真的选中了测试。
    if guards:
        base_bin = binary
    else:
        base_bin = os.path.join(rn.bin, 'baseline.test')
        rc, out, secs = rn.build({}, base_bin, 'baseline')
        if rc != 0:
            die('克隆里的原始代码就编不过,日志 ' + os.path.join(rn.logs, 'baseline.build.log'))
    rc, out, base_secs = rn.run(base_bin, None, run_regex, 600, 'baseline.log', failfast=False)
    if rc != 0:
        die('基线(不开变异)就没过: %s,日志 %s' % (first_failure(out), os.path.join(rn.logs, 'baseline.log')))
    if 'no tests to run' in out:
        die('-test.run %r 一个测试都没选中' % run_regex)
    timeout = max(30, int(base_secs * 10))
    log('基线通过(%.1f 秒),每个变异限时 %d 秒' % (base_secs, timeout))

    def judge(mid, rc, out, secs, how):
        verdict[mid] = ('没抓到', '') if rc == 0 else ('抓到', first_failure(out))
        r, why = verdict[mid]
        note = '\n       注:' + notes[mid] if mid in notes and mid not in classic_bins else ''
        log('  #%-3s %-4s %s%s(%.1f 秒%s)%s' % (mid, r, by_id[mid]['name'], ' — ' + why if why else '', secs, how, note))

    for mid, msg in invalid.items():
        verdict[mid] = ('编译不过', msg)
    classic_bins = {}

    for g in guards:
        m = by_id[g['id']]
        rc, out, secs = rn.run(binary, m, run_regex, timeout, 'm%s.log' % m['id'])
        judge(m['id'], rc, out, secs, '')
    for c in classic:
        m = by_id[c['id']]
        cbin = os.path.join(rn.bin, 'classic-%s.test' % m['id'])
        rc, out, bsecs = rn.build({c['file']: c['overlay_file']}, cbin, 'classic-%s' % m['id'], throwaway_cache=True)
        if rc != 0:
            errs = compile_errors(out)
            verdict[m['id']] = ('编译不过', errs[0][2] if errs else '见日志')
            log('  #%-3s 编译不过 %s — %s(单独编译 %.1f 秒)' % (m['id'], m['name'], verdict[m['id']][1], bsecs))
            continue
        classic_bins[m['id']] = cbin
        rc, out, secs = rn.run(cbin, m, run_regex, timeout, 'm%s.log' % m['id'], switch=False)
        judge(m['id'], rc, out, secs, ',%s,单独编译 %.1f 秒' % (c['reason'], bsecs))

    survivors = [m for m in mutants if verdict.get(m['id'], ('',))[0] == '没抓到']
    if survivors and args.full_on_survive:
        rc, out, full_secs = rn.run(base_bin, None, '.', 3600, 'baseline-full.log', failfast=False)
        if rc != 0:
            log('整套测试的基线就没过(%s),没法补跑,日志 %s' % (first_failure(out), os.path.join(rn.logs, 'baseline-full.log')))
        else:
            log('没抓到的 %d 个拿整套测试再跑(整套基线 %.1f 秒)' % (len(survivors), full_secs))
            ftimeout = max(300, int(full_secs * 5))
            for m in survivors:
                cbin = classic_bins.get(m['id'])
                rc, out, secs = rn.run(cbin or binary, m, '.', ftimeout, 'm%s-full.log' % m['id'], switch=not cbin)
                if rc != 0:
                    verdict[m['id']] = ('抓到', '整套里的 ' + first_failure(out))
                log('  #%-3s %s(整套 %.1f 秒)' % (m['id'], '整套里抓到 — ' + first_failure(out) if rc != 0 else '整套也没抓到', secs))
    rn.check_restored()

    counts = {}
    lines = []
    for m in mutants:
        r, why = verdict.get(m['id'], ('未跑', ''))
        counts[r] = counts.get(r, 0) + 1
        note = '(注:%s)' % notes[m['id']] if m['id'] in notes and r != '编译不过' and m['id'] not in classic_bins else ''
        lines.append('#%-3s %-4s %s%s%s' % (m['id'], r, m['name'], ' — ' + why if why else '', note))
    summary = ','.join('%s %d' % (k, v) for k, v in sorted(counts.items()))
    total = time.time() - t_start
    report = '\n'.join(lines) + '\n\n%d 个变异:%s。编译 %d 次共 %.1f 秒,跑测试 %d 次共 %.1f 秒,总计 %.1f 秒。\n' % (
        len(mutants), summary, rn.build_count, rn.build_secs, rn.run_count, rn.run_secs, total)
    with open(os.path.join(work, 'report.txt'), 'w', encoding='utf-8') as fh:
        fh.write(report)
    log('\n' + report + '报告 %s,日志 %s' % (os.path.join(work, 'report.txt'), rn.logs))

    if not args.keep:
        for path in (made_clone, os.path.join(work, 'gocache'), rn.bin, rn.gen):
            if path and os.path.exists(path):
                shutil.rmtree(path)
        log('已删掉克隆、编译缓存和二进制(加 --keep 保留)')
    bad = counts.get('没抓到', 0) + counts.get('编译不过', 0)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
