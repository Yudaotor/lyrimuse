#!/usr/bin/env bash
# 重建桌面歌词悬浮窗 App。跟 collector/build.sh 不同:这是用户随时可能主动 Cmd-Q 退出
# 的前台 GUI 工具,不是 KeepAlive 常驻服务——"重启"这一步只是"如果当前有实例在跑就杀掉
# 旧的、拉起新构建的",不碰开机启动的 LaunchAgent 配置(那是用户在 App 菜单里自己控制
# 的开关,见 Settings/LoginItemManager.swift)。
#
# 用法:
#   ./build.sh              构建 + 重启(如果当前有实例在跑)
#   ./build.sh --no-restart 只构建
set -euo pipefail

cd "$(dirname "$0")" # desktop-lyrics/
BIN="$(cd .. && pwd)/bin/desktop-lyrics"

echo "==> building (release)"
swift build -c release
mkdir -p "$(dirname "$BIN")"
cp ".build/release/desktop-lyrics" "$BIN"
codesign -v "$BIN" && echo "    signature valid"

if [ "${1:-}" = "--no-restart" ]; then
  echo "==> built (restart skipped)"
  exit 0
fi

if pid=$(pgrep -f "$BIN" 2>/dev/null); then
  echo "==> stopping running instance (pid $pid)"
  kill "$pid"
  sleep 1
fi

echo "==> launching"
"$BIN" &
disown
sleep 2
if pid=$(pgrep -f "$BIN"); then
  echo "==> desktop-lyrics running, pid $pid"
else
  echo "!! desktop-lyrics not running — check ~/Library/Logs/desktop-lyrics.log" >&2
  exit 1
fi
