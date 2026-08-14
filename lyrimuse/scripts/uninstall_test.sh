#!/bin/zsh
#
# 给 uninstall.sh 的端到端测试：搭一套假的家目录 + 一次性 probe launchd job，
# 让 uninstall.sh 走**完全相同的代码路径**，然后核对该删的删了、不该碰的没碰。
#
#   ./uninstall_test.sh
#
# 这个测试之所以必要：uninstall.sh 是这个仓库里唯一会 rm -rf 用户数据的东西，而它天然
# 不能拿真实数据试。靠"读一遍代码觉得没问题"来发布一个删数据的脚本是不负责任的。
#
set -u

SCRIPT_DIR="${0:A:h}"
UNINSTALL="$SCRIPT_DIR/uninstall.sh"
UID_="$(id -u)"
PROBE_A="me.yudaotor.lyrimuse.probe-uninstall-collector"
PROBE_B="me.yudaotor.lyrimuse.probe-uninstall-app"
FAKE_HOME="$(/usr/bin/mktemp -d /tmp/lyrimuse-uninstall-test.XXXXXX)"
FAILURES=0

cleanup() {
  for l in "$PROBE_A" "$PROBE_B"; do
    /bin/launchctl bootout "gui/$UID_/$l" >/dev/null 2>&1
  done
  /bin/rm -rf "$FAKE_HOME"
}
trap cleanup EXIT INT TERM

ok()   { echo "  ok   - $1" }
fail() { echo "  FAIL - $1"; FAILURES=$((FAILURES + 1)) }

# 真实的东西在测试前后都必须原样不动。
REAL_CONFIG_BEFORE=$(/usr/bin/find "$HOME/.config/lyrimuse" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
REAL_COLLECTOR_BEFORE=$(/bin/launchctl print "gui/$UID_/com.lyrimuse.collector" >/dev/null 2>&1 && echo yes || echo no)

setup_fake_home() {
  /bin/rm -rf "$FAKE_HOME"
  /bin/mkdir -p "$FAKE_HOME/Library/LaunchAgents" "$FAKE_HOME/.config/lyrimuse/lyrics" "$FAKE_HOME/Library/Logs"
  echo '{}' > "$FAKE_HOME/.config/lyrimuse/config.json"
  echo '{}' > "$FAKE_HOME/.config/lyrimuse/lyrimuse-enrich-cache.json"
  echo '[00:01.00]假歌词' > "$FAKE_HOME/.config/lyrimuse/lyrics/测试 - 歌.lrc"
  echo 'log line' > "$FAKE_HOME/Library/Logs/lyrimuse.log"
  for l in "$PROBE_A" "$PROBE_B"; do
    p="$FAKE_HOME/Library/LaunchAgents/$l.plist"
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
      echo '<plist version="1.0"><dict>'
      echo "  <key>Label</key><string>$l</string>"
      echo '  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>sleep 300</string></array>'
      echo '  <key>RunAtLoad</key><true/><key>KeepAlive</key><false/>'
      echo '</dict></plist>'
    } > "$p"
    /bin/launchctl bootout "gui/$UID_/$l" >/dev/null 2>&1
    /bin/launchctl bootstrap "gui/$UID_" "$p" 2>/dev/null
  done
}

run_uninstall() {
  LYRIMUSE_UNINSTALL_PREFIX="$FAKE_HOME" \
  LYRIMUSE_UNINSTALL_COLLECTOR_LABEL="$PROBE_A" \
  LYRIMUSE_UNINSTALL_APP_LABEL="$PROBE_B" \
    "$UNINSTALL" "$@"
}

echo "=== 1. 只读模式什么都不该动 ==="
setup_fake_home
run_uninstall >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "配置还在" || fail "只读模式删了配置"
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && ok "probe job 还注册着" || fail "只读模式注销了 job"

echo
echo "=== 2. --purge 输入 no 应当取消 ==="
echo "no" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "取消后配置还在" || fail "输入 no 却把数据删了"
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && ok "取消后 job 还在" || fail "输入 no 却注销了 job"

echo
echo "=== 3. --purge 输入回车（空）应当取消 ==="
echo "" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "空输入按取消处理" || fail "空输入却把数据删了"

echo
echo "=== 4. --services 停服务但保留数据 ==="
run_uninstall --services >/dev/null 2>&1
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && fail "job 没被注销" || ok "job 已注销"
[[ -f "$FAKE_HOME/Library/LaunchAgents/$PROBE_A.plist" ]] && fail "plist 没删" || ok "plist 已删"
[[ -f "$FAKE_HOME/.config/lyrimuse/config.json" ]] && ok "数据完好保留" || fail "--services 不该碰数据"
[[ -f "$FAKE_HOME/.config/lyrimuse/lyrics/测试 - 歌.lrc" ]] && ok "歌词文件完好" || fail "--services 删了歌词"

echo
echo "=== 5. --purge 输入 yes 才真的删 ==="
setup_fake_home
echo "yes" | run_uninstall --purge >/dev/null 2>&1
[[ -d "$FAKE_HOME/.config/lyrimuse" ]] && fail "配置目录没删" || ok "配置目录已删"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse.log" ]] && fail "日志没删" || ok "日志已删"
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && fail "job 没注销" || ok "job 已注销"

echo
echo "=== 6. 全程没碰真实环境 ==="
REAL_CONFIG_AFTER=$(/usr/bin/find "$HOME/.config/lyrimuse" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
REAL_COLLECTOR_AFTER=$(/bin/launchctl print "gui/$UID_/com.lyrimuse.collector" >/dev/null 2>&1 && echo yes || echo no)
[[ "$REAL_CONFIG_BEFORE" == "$REAL_CONFIG_AFTER" ]] \
  && ok "真实配置文件数不变（$REAL_CONFIG_BEFORE）" \
  || fail "真实配置被动了：$REAL_CONFIG_BEFORE -> $REAL_CONFIG_AFTER"
[[ "$REAL_COLLECTOR_BEFORE" == "$REAL_COLLECTOR_AFTER" ]] \
  && ok "真实 collector 服务状态不变（$REAL_COLLECTOR_BEFORE）" \
  || fail "真实 collector 被动了：$REAL_COLLECTOR_BEFORE -> $REAL_COLLECTOR_AFTER"

echo
if (( FAILURES == 0 )); then
  echo "ALL PASS"
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
