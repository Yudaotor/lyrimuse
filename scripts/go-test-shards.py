#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把引擎测试分成几份、几个进程并行跑(commit-checks.sh 的 go test 那一步用)。

    python3 scripts/go-test-shards.py <引擎目录> [--run <正则>]

引擎是一个包、两千多个测试,没有一个用 t.Parallel(大多改包级全局状态),go test 只能单进程串行跑完,约 35 秒。
测试之间共享的是进程内的状态;每个进程的 TestMain 还会把 HOME 指到自己的临时目录,所以分到几个进程里各跑一份
是隔离的。做法:go test -c 编一次测试程序 → -test.list 列出全部测试 → 按上一次记下的各测试耗时贪心均分成
LYRIMUSE_GO_TEST_SHARDS(默认 4)份 → 同时跑。耗时记在 <树根>/.build/go-test/durations.json,每次跑完更新。

带 --run 时只跑名字匹配的那几个,单进程。有测试没过时,把没过的那几个放进一个进程单独再跑一次:单跑也没过才算
没过(打出它的输出);单跑过了照样算通过,打一行提醒 —— 那是测试之间争同一份进程外资源(端口、固定路径),不是
被测代码的问题,要修的是测试的隔离。单跑过了时把第一次没过的那段输出打到 stderr(shard-N.out 下次运行就被覆盖,
不打出来就再也看不到为什么没过);某份因 panic / 超时提前退出、后面的测试没跑到的,打那份输出的末尾。

带 -test.short 跑:按设计打真实网络的测试(skipLiveInShort)在这里跳过,CI 整套跑不带 -short,它们留在那里验。

不进 go 自己的测试缓存:要不要跑、跑哪几个由 commit-checks.sh 按「这个目录上一次通过的树」到这一棵的改动定。
"""
import json
import os
import re
import subprocess
import sys
import time

TOP = re.compile(r'^--- (PASS|FAIL|SKIP): (\S+) \(([\d.]+)s\)')


def run_shard(binary, engine, names, out_path, pattern=None):
    pat = pattern or '^(' + '|'.join(re.escape(n) for n in names) + ')$'
    out = open(out_path, 'w')
    return subprocess.Popen([binary, '-test.run', pat, '-test.count=1', '-test.short', '-test.v', '-test.timeout=10m'],
                            cwd=engine, stdout=out, stderr=subprocess.STDOUT)


def parse(out_path):
    """(每个顶层测试的结果和耗时, 输出全文)。"""
    res = {}
    text = open(out_path, encoding='utf-8', errors='replace').read()
    for line in text.splitlines():
        m = TOP.match(line)
        if m:
            res[m.group(2)] = (m.group(1), float(m.group(3)))
    return res, text


def failure_excerpt(text, limit=200):
    keep = [l for l in text.splitlines()
            if not l.startswith(('=== RUN', '=== PAUSE', '=== CONT', '--- PASS', '--- SKIP'))
            and not re.match(r'^\s+--- (PASS|SKIP)', l)]
    return '\n'.join(keep[-limit:])


def first_failure(texts, name, limit=60):
    """并行那一轮里 name 这个顶层测试的输出:从它的 === RUN 到下一个顶层 === RUN(panic 的堆栈打在 --- FAIL 之后,
    要一起带上);没截到返回 None。"""
    for text in texts:
        lines = text.splitlines()
        start = next((i for i, l in enumerate(lines) if l.rstrip() == '=== RUN   ' + name), None)
        if start is None:
            continue
        fail = next((i for i in range(start, len(lines)) if lines[i].startswith('--- FAIL: %s ' % name)), None)
        if fail is None:
            continue
        end = next((i for i in range(fail, len(lines)) if lines[i].startswith('=== RUN') and '/' not in lines[i]), len(lines))
        return failure_excerpt('\n'.join(lines[start:end]), limit)
    return None


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    engine = os.path.abspath(argv[0])
    pattern = argv[argv.index('--run') + 1] if '--run' in argv else None
    work = os.path.join(os.path.dirname(engine), '.build', 'go-test')
    os.makedirs(work, exist_ok=True)
    os.environ.setdefault('GOTOOLCHAIN', 'go1.24.4')
    binary = os.path.join(work, 'engine.test')
    durations_path = os.path.join(work, 'durations.json')

    t0 = time.time()
    # -trimpath:编出来的东西不带源码所在目录,同一份引擎在主工作树、各校验目录、build.sh 的源码快照里编,
    # go 的编译缓存共用一份(不带它时每个目录各存一份,换目录还得整包重编)。
    built = subprocess.run(['go', 'test', '-c', '-trimpath', '-tags', 'devtools', '-o', binary, '.'], cwd=engine)
    if built.returncode != 0:
        return built.returncode
    t1 = time.time()

    if pattern:
        shards = [None]
    else:
        listed = subprocess.run([binary, '-test.list', '.*'], cwd=engine, capture_output=True, text=True)
        if listed.returncode != 0:
            print(listed.stdout + listed.stderr, file=sys.stderr)
            return listed.returncode
        names = [n for n in listed.stdout.split() if n.startswith(('Test', 'Example', 'Fuzz'))]
        try:
            dur = json.load(open(durations_path))
        except (OSError, ValueError):
            dur = {}
        n = max(1, min(int(os.environ.get('LYRIMUSE_GO_TEST_SHARDS', '4')), len(names)))
        shards = [[] for _ in range(n)]
        load = [0.0] * n
        for name in sorted(names, key=lambda x: (-dur.get(x, 0.05), x)):
            i = load.index(min(load))
            shards[i].append(name)
            load[i] += dur.get(name, 0.05)

    procs = []
    for i, names in enumerate(shards):
        out_path = os.path.join(work, 'shard-%d.out' % i)
        procs.append((out_path, run_shard(binary, engine, names, out_path, pattern)))
    codes = [p.wait() for _, p in procs]
    t2 = time.time()

    results, failed, texts = {}, [], []
    for out_path, _ in procs:
        res, text = parse(out_path)
        results.update(res)
        texts.append(text)
    failed = sorted(k for k, (st, _) in results.items() if st == 'FAIL')
    # 一个测试 panic 或超时会让整份进程退出,这份里排在后面的测试根本没跑:也算进单独重跑的名单。
    unrun = sorted(n for names in shards if names for n in names if n not in results)
    if not pattern:
        dur = {k: d for k, (st, d) in results.items()}
        with open(durations_path + '.tmp', 'w') as f:
            json.dump(dur, f)
        os.replace(durations_path + '.tmp', durations_path)
    print('    %d 个测试分 %d 个进程跑,%.0f 秒(编译 %.0f 秒)' % (len(results), len(shards), t2 - t1, t1 - t0))

    if not any(codes):
        return 0
    if not failed and not unrun:
        # 退出码非零却认不出哪个测试没过(TestMain 出错之类)。整段打出来。
        for text, code in zip(texts, codes):
            if code:
                print(failure_excerpt(text), file=sys.stderr)
        return 1
    print('    没过:%s;%s放进一个进程单独再跑一次' % (' '.join(failed) or '无',
                                          '没跑到 %d 个,' % len(unrun) if unrun else ''))
    out_path = os.path.join(work, 'rerun.out')
    code = run_shard(binary, engine, failed + unrun, out_path).wait()
    _, text = parse(out_path)
    if code == 0:
        print('    !! 单独跑通过了:这几个只在并行时没过,多半是测试之间争同一份进程外资源(端口、固定路径),'
              '要修测试的隔离:%s' % ' '.join(failed))
        for name in failed:
            excerpt = first_failure(texts, name)
            print('    --- 并行那一轮 %s 没过时的输出 ---\n%s' % (name, excerpt or '(没截到,看 %s 下的 shard-*.out)' % work),
                  file=sys.stderr)
        if unrun:
            for text, c in zip(texts, codes):
                started = [l[len('=== RUN'):].strip() for l in text.splitlines() if l.startswith('=== RUN') and '/' not in l]
                if c and started and started[-1] not in results:
                    print('    --- 提前退出的那份(%s 没跑完,panic / 超时 / 退出)末尾 ---\n%s' % (started[-1], failure_excerpt(text, 40)),
                          file=sys.stderr)
        return 0
    print(failure_excerpt(text), file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
