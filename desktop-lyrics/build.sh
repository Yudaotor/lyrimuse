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

LABEL="com.chenyuhao.applemusic-desktop-lyrics"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if launchctl list "$LABEL" >/dev/null 2>&1; then
  # 开机启动开关已经在菜单里打开过、这份 job 归 launchd 管——用 kickstart 让 launchd
  # 用新构建的二进制重启同一个受管进程,不要另外手动 kill+起一个游离进程,否则会变成
  # "launchd 记录里的进程死了、外面又跑着一个 launchd 不认识的新进程"这种双实例混乱
  # (实测踩过这个坑)。
  echo "==> restarting via launchd (kickstart)"
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  sleep 2
  if ! pgrep -f "$BIN" >/dev/null 2>&1; then
    # kickstart 有时会静默失败——launchd 给这个 job 缓存了上一次运行遗留的 LWCR
    # (Lightweight Code Requirement)codesigning 约束,绑定的是旧二进制的 cdhash;
    # release 每次重新 ad-hoc 签名,cdhash 必然变化,kickstart 本身不会刷新这个约束,
    # 新二进制会被 OS 直接拒绝启动。只有完整卸载再重新加载这个 job,才会让 launchd
    # 丢掉旧约束、重新从 plist/二进制读起(实测坐实过这个失败模式和这个修法)。
    echo "==> kickstart produced no running process, retrying via bootout+bootstrap"
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
  fi
else
  if pid=$(pgrep -f "$BIN" 2>/dev/null); then
    echo "==> stopping running instance (pid $pid)"
    kill "$pid"
    sleep 1
  fi
  echo "==> launching"
  "$BIN" &
  disown
fi
sleep 2
if pid=$(pgrep -f "$BIN"); then
  echo "==> desktop-lyrics running, pid $pid"
else
  echo "!! desktop-lyrics not running — check ~/Library/Logs/desktop-lyrics.log" >&2
  exit 1
fi
