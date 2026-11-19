# -*- coding: utf-8 -*-
"""引擎用哪一版 Go 工具链:只读 lyrimuse-engine/go.mod 的 toolchain 行,脚本里不另写版本号。

    toolchain()       -> 'go1.27.4' 这样的字符串
    gofmt_exe()       -> 那一版工具链自带的 gofmt 路径;本机没装 go 时退回 PATH 上的 gofmt,都没有返回 None

gofmt 必须跟 CI 用同一版:不同版本对齐结果不一样(含 CJK 键的 map 字面量),PATH 上的旧版 gofmt 格式化过的
生成物在 CI 的 gofmt 检查里会红。见 15 章决策 126。
"""
import os
import re
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GO_MOD = os.path.join(ROOT, 'lyrimuse-engine', 'go.mod')


def toolchain(go_mod=GO_MOD):
    with open(go_mod, encoding='utf-8') as f:
        m = re.search(r'^toolchain (go\S+)$', f.read(), re.M)
    if not m:
        raise SystemExit('%s 里没有 toolchain 行' % go_mod)
    return m.group(1)


def gofmt_exe():
    go = shutil.which('go')
    if go:
        done = subprocess.run([go, 'env', 'GOROOT'], capture_output=True, text=True,
                              cwd=os.path.dirname(GO_MOD), env=dict(os.environ, GOTOOLCHAIN=toolchain()))
        exe = os.path.join(done.stdout.strip(), 'bin', 'gofmt')
        if done.returncode == 0 and os.access(exe, os.X_OK):
            return exe
    return shutil.which('gofmt')
