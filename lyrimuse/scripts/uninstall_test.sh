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
PROBE_A="me.yudaotor.lyrimuse.probe-uninstall-engine"
PROBE_B="me.yudaotor.lyrimuse.probe-uninstall-app"
FAKE_HOME="$(/usr/bin/mktemp -d /tmp/lyrimuse-uninstall-test.XXXXXX)"
KEYCHAIN_DIR="$(/usr/bin/mktemp -d /tmp/lyrimuse-uninstall-keychain.XXXXXX)"
TEST_KEYCHAIN="$KEYCHAIN_DIR/vault.keychain-db"
FAILURES=0
# 数据目录名取 App 的 label,测试把 label 换成 probe,所以假数据目录也按 probe 命名;旧目录名是固定的。
FAKE_DATA="$FAKE_HOME/Library/Application Support/$PROBE_B"
FAKE_LEGACY="$FAKE_HOME/.config/lyrimuse"

cleanup() {
  for l in "$PROBE_A" "$PROBE_B"; do
    /bin/launchctl bootout "gui/$UID_/$l" >/dev/null 2>&1
  done
  # probe 偏好域写在真实 cfprefs 里（domain 不受 FAKE_HOME 管），必须自己收干净。
  /usr/bin/defaults delete "$PROBE_B" >/dev/null 2>&1
  /usr/bin/security delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1
  /bin/rm -rf "$FAKE_HOME" "$KEYCHAIN_DIR"
}
trap cleanup EXIT INT TERM

ok()   { echo "  ok   - $1" }
fail() { echo "  FAIL - $1"; FAILURES=$((FAILURES + 1)) }

# 真实的东西在测试前后都必须原样不动。
real_data_count() {
  /usr/bin/find "$HOME/Library/Application Support/me.yudaotor.lyrimuse" "$HOME/.config/lyrimuse" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '
}
REAL_CONFIG_BEFORE=$(real_data_count)
REAL_ENGINE_BEFORE=$(/bin/launchctl print "gui/$UID_/com.lyrimuse.collector" >/dev/null 2>&1 && echo yes || echo no)
# 加：--purge 开始真的 `defaults delete` 之后，这条对账就不再是形式主义 ——
# 脚本删的 domain 取自 $APP_LABEL，测试把它覆盖成一次性 probe label；万一哪天有人把
# domain 写死成真实 bundle id，这一行会当场把"测试把我自己的全部设置删了"抓出来。
# 数 key 的条数而不是只看 domain 在不在：真实域几乎必然存在，条数才对得出差异。
real_defaults_count() {
  /usr/bin/defaults read me.yudaotor.lyrimuse 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '
}
REAL_DEFAULTS_BEFORE=$(real_defaults_count)

setup_fake_home() {
  /bin/rm -rf "$FAKE_HOME"
  /bin/mkdir -p "$FAKE_HOME/Library/LaunchAgents" "$FAKE_DATA/lyrics" "$FAKE_LEGACY" "$FAKE_HOME/Library/Logs"
  echo '{}' > "$FAKE_DATA/config.json"
  echo '{}' > "$FAKE_DATA/lyrimuse-enrich-cache.json"
  echo '[00:01.00]假歌词' > "$FAKE_DATA/lyrics/测试 - 歌.lrc"
  # 旧版本留下的旧目录(降级后又升级时会出现)
  echo '{}' > "$FAKE_LEGACY/config.json"
  /bin/mkdir -p "$FAKE_HOME/Library/Caches/$PROBE_B/motion-covers"
  echo 'mp4' > "$FAKE_HOME/Library/Caches/$PROBE_B/motion-covers/a.mp4"
  echo 'log line' > "$FAKE_HOME/Library/Logs/lyrimuse.log"
  for a in lyrimuse.log.old lyrimuse.log.old.1 lyrimuse.log.old.2; do
    echo 'archived log line' > "$FAKE_HOME/Library/Logs/$a"
  done
  echo 'Sampling process' > "$FAKE_HOME/Library/Logs/lyrimuse-main-thread-stall.txt"
  echo 'app stderr' > "$FAKE_HOME/Library/Logs/lyrimuse-app.log"
  echo 'archived app stderr' > "$FAKE_HOME/Library/Logs/lyrimuse-app.log.old"
  # probe 偏好域：--purge 会对 $APP_LABEL(= $PROBE_B) 跑 defaults delete，先种一个进去，
  # 否则 HAS_DEFAULTS 恒为 no、那条分支根本走不到，等于没测。
  # defaults 的 domain 不受 LYRIMUSE_UNINSTALL_PREFIX 管辖（它写的是真实用户的
  # cfprefs），所以这里种的必须是 probe label 而不是真实 bundle id，cleanup 里也要删掉。
  /usr/bin/defaults write "$PROBE_B" probeKey -string probeValue 2>/dev/null
  # 凭据保险箱种在一份临时钥匙串里(不进搜索列表),--purge 删的是它,碰不到登录钥匙串。
  # 数据目录账号上一条,旧目录账号(以前的账号,App 没搬走的)上一条,两条都该删。
  /usr/bin/security delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1
  /usr/bin/security create-keychain -p test "$TEST_KEYCHAIN" >/dev/null 2>&1
  for account in "$FAKE_DATA" "$FAKE_LEGACY"; do
    printf 'add-generic-password -U -s "%s" -a "%s" -w e30= "%s"\n' \
      "$PROBE_B.credentials" "$account" "$TEST_KEYCHAIN" | /usr/bin/security -i >/dev/null 2>&1
  done
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

# 两条都在才算「在」,任何一条还在都算「没删」。
has_test_vault() {
  /usr/bin/security find-generic-password -s "$PROBE_B.credentials" -a "$FAKE_DATA" "$TEST_KEYCHAIN" >/dev/null 2>&1 &&
    /usr/bin/security find-generic-password -s "$PROBE_B.credentials" -a "$FAKE_LEGACY" "$TEST_KEYCHAIN" >/dev/null 2>&1
}
any_test_vault() {
  /usr/bin/security find-generic-password -s "$PROBE_B.credentials" -a "$FAKE_DATA" "$TEST_KEYCHAIN" >/dev/null 2>&1 ||
    /usr/bin/security find-generic-password -s "$PROBE_B.credentials" -a "$FAKE_LEGACY" "$TEST_KEYCHAIN" >/dev/null 2>&1
}

run_uninstall() {
  LYRIMUSE_UNINSTALL_KEYCHAIN="$TEST_KEYCHAIN" \
  LYRIMUSE_UNINSTALL_PREFIX="$FAKE_HOME" \
  LYRIMUSE_UNINSTALL_ENGINE_LABEL="$PROBE_A" \
  LYRIMUSE_UNINSTALL_APP_LABEL="$PROBE_B" \
    "$UNINSTALL" "$@"
}

echo "=== 1. 只读模式什么都不该动 ==="
setup_fake_home
run_uninstall >/dev/null 2>&1
[[ -f "$FAKE_DATA/config.json" ]] && ok "配置还在" || fail "只读模式删了配置"
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && ok "probe job 还注册着" || fail "只读模式注销了 job"

echo
echo "=== 2. --purge 输入 no 应当取消 ==="
echo "no" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_DATA/config.json" ]] && ok "取消后配置还在" || fail "输入 no 却把数据删了"
has_test_vault && ok "取消后钥匙串凭据还在" || fail "输入 no 却删了钥匙串凭据"
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && ok "取消后 job 还在" || fail "输入 no 却注销了 job"

echo
echo "=== 3. --purge 输入回车（空）应当取消 ==="
echo "" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_DATA/config.json" ]] && ok "空输入按取消处理" || fail "空输入却把数据删了"

echo
echo "=== 4. --services 停服务但保留数据 ==="
run_uninstall --services >/dev/null 2>&1
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && fail "job 没被注销" || ok "job 已注销"
[[ -f "$FAKE_HOME/Library/LaunchAgents/$PROBE_A.plist" ]] && fail "plist 没删" || ok "plist 已删"
[[ -f "$FAKE_DATA/config.json" ]] && ok "数据完好保留" || fail "--services 不该碰数据"
[[ -f "$FAKE_DATA/lyrics/测试 - 歌.lrc" ]] && ok "歌词文件完好" || fail "--services 删了歌词"
[[ -f "$FAKE_LEGACY/config.json" ]] && ok "旧目录完好" || fail "--services 删了旧目录"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse.log.old.2" ]] && ok "日志归档完好" || fail "--services 删了日志归档"
[[ -f "$FAKE_HOME/Library/Caches/$PROBE_B/motion-covers/a.mp4" ]] && ok "缓存目录完好" || fail "--services 删了缓存目录"
has_test_vault && ok "钥匙串凭据完好" || fail "--services 删了钥匙串凭据"

echo
echo "=== 5. --purge 输入 yes 才真的删 ==="
setup_fake_home
echo "yes" | run_uninstall --purge >/dev/null 2>&1
[[ -d "$FAKE_DATA" ]] && fail "数据目录没删" || ok "数据目录已删"
[[ -d "$FAKE_LEGACY" ]] && fail "旧数据目录没删" || ok "旧数据目录已删"
[[ -d "$FAKE_HOME/Library/Caches/$PROBE_B" ]] && fail "缓存目录没删" || ok "缓存目录已删"
any_test_vault && fail "钥匙串凭据没删" || ok "钥匙串凭据已删"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse.log" ]] && fail "日志没删" || ok "日志已删"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse-main-thread-stall.txt" ]] && fail "主线程卡顿采样没删" || ok "主线程卡顿采样已删"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse-app.log" ]] && fail "App 日志没删" || ok "App 日志已删"
[[ -f "$FAKE_HOME/Library/Logs/lyrimuse-app.log.old" ]] && fail "App 日志归档没删" || ok "App 日志归档已删"
for a in lyrimuse.log.old lyrimuse.log.old.1 lyrimuse.log.old.2; do
  [[ -f "$FAKE_HOME/Library/Logs/$a" ]] && fail "日志归档 $a 没删" || ok "日志归档 $a 已删"
done
/bin/launchctl print "gui/$UID_/$PROBE_A" >/dev/null 2>&1 && fail "job 没注销" || ok "job 已注销"
# purge 必须连偏好设置项一起删 —— 不删的话重装会走进"引导不弹 + 服务没装"的死路
# （见 uninstall.sh 里那段注释）。
# 同一个坑：`defaults read` 对已删的 domain 照样退出 0（打印空字典），判据只能看内容。
probe_defaults_left=$(/usr/bin/defaults read "$PROBE_B" 2>/dev/null | /usr/bin/tr -d '[:space:]')
[[ -z "$probe_defaults_left" || "$probe_defaults_left" == "{}" ]] \
  && ok "偏好设置项已删" || fail "偏好设置项没删（残留: $probe_defaults_left）"

echo
echo "=== 6. 旧目录是软链接时 --purge 只删链接,不动它指向的目录 ==="
setup_fake_home
/bin/rm -rf "$FAKE_LEGACY"
/bin/mkdir -p "$FAKE_HOME/elsewhere"
echo '{}' > "$FAKE_HOME/elsewhere/config.json"
/bin/ln -s "$FAKE_HOME/elsewhere" "$FAKE_LEGACY"
echo "yes" | run_uninstall --purge >/dev/null 2>&1
[[ -L "$FAKE_LEGACY" ]] && fail "软链接没删" || ok "软链接已删"
[[ -f "$FAKE_HOME/elsewhere/config.json" ]] && ok "链接指向的目录完好" || fail "删到了软链接指向的目录"

echo
echo "=== 7. 搬迁留下的旧目录只报不删 ==="
setup_fake_home
/bin/mkdir -p "$FAKE_HOME/.config/lyrimuse.leftover-20261023-120000"
echo '{}' > "$FAKE_HOME/.config/lyrimuse.leftover-20261023-120000/config.json"
run_uninstall 2>&1 | /usr/bin/grep -q "lyrimuse.leftover-20261023-120000" && ok "报出了留下的旧目录" || fail "没报留下的旧目录"
echo "yes" | run_uninstall --purge >/dev/null 2>&1
[[ -f "$FAKE_HOME/.config/lyrimuse.leftover-20261023-120000/config.json" ]] && ok "留下的旧目录不自动删" || fail "删了留下的旧目录"

echo
echo "=== 8. 全程没碰真实环境 ==="
REAL_CONFIG_AFTER=$(real_data_count)
REAL_ENGINE_AFTER=$(/bin/launchctl print "gui/$UID_/com.lyrimuse.collector" >/dev/null 2>&1 && echo yes || echo no)
[[ "$REAL_CONFIG_BEFORE" == "$REAL_CONFIG_AFTER" ]] \
  && ok "真实配置文件数不变（$REAL_CONFIG_BEFORE）" \
  || fail "真实配置被动了：$REAL_CONFIG_BEFORE -> $REAL_CONFIG_AFTER"
[[ "$REAL_ENGINE_BEFORE" == "$REAL_ENGINE_AFTER" ]] \
  && ok "真实引擎服务状态不变（$REAL_ENGINE_BEFORE）" \
  || fail "真实引擎被动了：$REAL_ENGINE_BEFORE -> $REAL_ENGINE_AFTER"
REAL_DEFAULTS_AFTER=$(real_defaults_count)
[[ "$REAL_DEFAULTS_BEFORE" == "$REAL_DEFAULTS_AFTER" ]] \
  && ok "真实偏好设置项不变（$REAL_DEFAULTS_BEFORE 行）" \
  || fail "真实偏好被动了：$REAL_DEFAULTS_BEFORE -> $REAL_DEFAULTS_AFTER 行"

echo
if (( FAILURES == 0 )); then
  echo "ALL PASS"
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
