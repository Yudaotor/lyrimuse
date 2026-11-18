#!/bin/bash
# 在全机重活闸(heavy-gate.sh)里跑一条命令:heavy-run.sh <说明> <命令字符串>,命令交给 zsh(会话里 Bash 工具的 shell)。
# 会话里随手跑的整套 swift build / selftest / go test 由钩子 ~/.claude/hooks/gate-heavy-lyrimuse-commands.py 自动套上这一层,
# 跟 build.sh 的编译段、提交校验排同一个队;排在装机后面。退出码是那条命令的;排队超过上限没轮到时是 75。
# 命令里再跑 commit-checks.sh、heavy-run.sh 的,用这里拿到的令牌,不再排第二次(heavy-gate.sh 头注「可重入」)。
# 命令里有 build.sh / package.sh 的不拿令牌、直接跑:build.sh 先拿排队锁再拿令牌,这里先拿令牌的话顺序相反,两份这样的
# heavy-run 加一个拿着锁在等令牌的 build.sh 会互等到排队上限。它们自己会排队(同钩子的 SELF_QUEUED)。见 15 章决策 124。
set -u
# 命令要整条作为第二个参数;参数个数不对直接报错,免得拆开的命令只跑第一个词还报成功
[ $# -eq 2 ] || { echo "用法: heavy-run.sh <说明> <命令字符串>(命令整条作为一个参数)" >&2; exit 2; }
. "$(dirname "$0")/heavy-gate.sh"
trap heavy_gate_release EXIT
# 收到 SIGTERM / SIGHUP 时等那条命令结束再退出、走 EXIT trap 放令牌(没设 trap 时 bash 当场退出,命令成了孤儿、不持令牌接着跑)。
trap 'exit 143' TERM
trap 'exit 129' HUP
case "$2" in
  *build.sh*|*package.sh*) ;;
  *) heavy_gate_acquire "$1" check || exit $? ;;
esac
/bin/zsh -c "$2"
