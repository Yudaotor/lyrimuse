#!/bin/bash
# 在全机重活闸(heavy-gate.sh)里跑一条命令:heavy-run.sh <说明> <命令字符串>,命令交给 zsh(会话里 Bash 工具的 shell)。
# 会话里随手跑的整套 swift build / selftest / go test 由钩子 ~/.claude/hooks/gate-heavy-lyrimuse-commands.py 自动套上这一层,
# 跟 build.sh 的编译段、提交校验排同一个队;排在装机后面。退出码是那条命令的;排队超过上限没轮到时是 75。
# 命令里再跑 build.sh、commit-checks.sh、heavy-run.sh 的,用这里拿到的令牌,不再排第二次(heavy-gate.sh 头注「可重入」)。
set -u
# 命令要整条作为第二个参数;参数个数不对直接报错,免得拆开的命令只跑第一个词还报成功
[ $# -eq 2 ] || { echo "用法: heavy-run.sh <说明> <命令字符串>(命令整条作为一个参数)" >&2; exit 2; }
. "$(dirname "$0")/heavy-gate.sh"
trap heavy_gate_release EXIT
# 收到 SIGTERM / SIGHUP 时照常走 EXIT trap 放令牌(bash 3.2 没设 trap 时直接退出、令牌要等别人判陈旧才回收)。
trap 'exit 143' TERM
trap 'exit 129' HUP
heavy_gate_acquire "$1" check || exit $?
/bin/zsh -c "$2"
