#!/usr/bin/env bash
# 重建并重启 now-playing 采集器。重建时务必用本脚本，别直接 `go build`。
#
# 为什么：系统 Go 是 1.21（工作项目锁定，别动），它的内部链接器在这台 macOS 27 上
# 产出的二进制缺 LC_UUID / 签名不被 AMFI 接受 → launchd 会静默拒启（报误导性的
# "dyld: missing LC_UUID" / 退出原因 OS_REASON_CODESIGNING），采集器起不来、网页停更。
# 解法：用 GOTOOLCHAIN 临时拉 go1.24 工具链重编，它原生就发 LC_UUID + 合规签名，
# 不用任何 -ldflags 花招、也不用手动 codesign。系统 Go 仍留 1.21、不受影响。
#
# 用法：
#   ./build.sh              构建 + 通过 launchd 重启
#   ./build.sh --no-restart 只构建，不动正在运行的进程
set -euo pipefail

cd "$(dirname "$0")" # collector/
BIN="../bin/collector"
LABEL="com.chenyuhao.applemusic-nowplaying"
TOOLCHAIN=go1.24.4 # 原生发 LC_UUID + 有效签名的工具链

echo "==> building with $TOOLCHAIN (native LC_UUID + valid signature)"
GOTOOLCHAIN="$TOOLCHAIN" go build -o "$BIN" .
codesign -v "$BIN" && echo "    signature valid"

if [ "${1:-}" = "--no-restart" ]; then
  echo "==> built (restart skipped)"
  exit 0
fi

echo "==> restarting via launchd"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 3
if pid=$(pgrep -f bin/collector); then
  echo "==> collector running, pid $pid"
else
  echo "!! collector not running — see ~/Library/Logs/applemusic-nowplaying.log" >&2
  exit 1
fi
