#!/bin/zsh
#
# 卸载 Lyrimuse 留在系统里的东西。
#
#   ./uninstall.sh              # 只看：报告装了什么，不做任何改动
#   ./uninstall.sh --services   # 注销两个 launchd job（不碰数据，重装即可恢复）
#   ./uninstall.sh --purge      # 注销 + 删除配置/缓存/日志（要输入 yes 确认）
#
# 为什么需要它:把 Lyrimuse.app 拖进废纸篓**不等于卸载干净**。
# ~/Library/LaunchAgents/com.lyrimuse.collector.plist 挂的是 KeepAlive=true 的 job,
# app 删掉之后 launchd 仍然会不停地去启动一个已经不存在的二进制。
#
# 安全约定（这几条是刻意的，改脚本时别放松）:
#   - 默认什么都不做，只报告。
#   - 删除的每个路径都硬编码、逐个列出，**绝不使用通配符**。歌词缓存里有用户手工修正过
#     的内容，误删不可逆（这个项目已经因为脚本误操作丢过一次 833 条歌词）。
#   - --purge 必须手输 yes，回车/其它输入一律取消。
#   - 只删这个 App 自己写的东西，不碰 Music 库、不碰任何用户文档。
#
# 测试用: 设 LYRIMUSE_UNINSTALL_PREFIX 指向一个临时目录，可以在不碰真实文件的前提下
# 走完整个流程。
#
set -u

PREFIX="${LYRIMUSE_UNINSTALL_PREFIX:-$HOME}"
UID_="$(id -u)"

# label 也可覆盖，纯粹为了让 uninstall_test.sh 能对着一次性 probe job 走**完全相同的
# 代码路径**（而不是给测试开一条"跳过 launchctl"的旁路，那样测的就不是真东西了）。
COLLECTOR_LABEL="${LYRIMUSE_UNINSTALL_COLLECTOR_LABEL:-com.lyrimuse.collector}"
APP_LABEL="${LYRIMUSE_UNINSTALL_APP_LABEL:-me.yudaotor.lyrimuse}"

COLLECTOR_PLIST="$PREFIX/Library/LaunchAgents/$COLLECTOR_LABEL.plist"
APP_PLIST="$PREFIX/Library/LaunchAgents/$APP_LABEL.plist"
CONFIG_DIR="$PREFIX/.config/lyrimuse"
LOG_FILE="$PREFIX/Library/Logs/lyrimuse.log"

MODE="report"
case "${1:-}" in
  "")           MODE="report" ;;
  --services)   MODE="services" ;;
  --purge)      MODE="purge" ;;
  -h|--help)
    /usr/bin/sed -n '3,9p' "$0" | /usr/bin/sed 's|^# \{0,1\}||'
    exit 0 ;;
  *) echo "不认识的参数: $1（试试 --help）" >&2; exit 2 ;;
esac

is_registered() { /bin/launchctl print "gui/$UID_/$1" >/dev/null 2>&1 }

human_size() {
  [[ -e "$1" ]] || { echo "-"; return }
  /usr/bin/du -sh "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
}

echo "=== 当前状态 ==="
for label in "$COLLECTOR_LABEL" "$APP_LABEL"; do
  if is_registered "$label"; then
    state=$(/bin/launchctl print "gui/$UID_/$label" 2>/dev/null | /usr/bin/grep -E "^	state = " | /usr/bin/sed 's/^	state = //')
    echo "  launchd job  $label  [$state]"
  else
    echo "  launchd job  $label  [未注册]"
  fi
done
for p in "$COLLECTOR_PLIST" "$APP_PLIST" "$CONFIG_DIR" "$LOG_FILE"; do
  if [[ -e "$p" ]]; then
    echo "  存在  $p  ($(human_size "$p"))"
  else
    echo "  没有  $p"
  fi
done

if [[ "$MODE" == "report" ]]; then
  echo
  echo "只是看看，什么都没动。"
  echo "  停掉后台服务（保留数据，重装即可恢复）:  $0 --services"
  echo "  连同配置/缓存/日志一起删除:              $0 --purge"
  echo
  echo "另外还要手动做的:"
  echo "  - 把 /Applications/Lyrimuse.app 拖进废纸篓"
  echo "  - 偏好设置项: defaults delete $APP_LABEL"
  exit 0
fi

stop_services() {
  echo
  echo "=== 注销 launchd job ==="
  for label in "$COLLECTOR_LABEL" "$APP_LABEL"; do
    if is_registered "$label"; then
      # KeepAlive 的 job 必须 bootout，光 kill 会被 launchd 立刻拉起来。
      /bin/launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1
      if is_registered "$label"; then
        echo "  ❌ $label 仍然注册着"
      else
        echo "  ✅ $label 已注销"
      fi
    else
      echo "  —  $label 本来就没注册"
    fi
  done
  for p in "$COLLECTOR_PLIST" "$APP_PLIST"; do
    if [[ -f "$p" ]]; then
      /bin/rm -f "$p" && echo "  ✅ 已删除 $p"
    fi
  done
}

if [[ "$MODE" == "services" ]]; then
  stop_services
  echo
  echo "数据一个字节都没动（$CONFIG_DIR 还在）。重新装回 App 就会重建这两个 job。"
  exit 0
fi

# --- purge ---
echo
echo "=== 将要删除的数据（不可恢复）==="
TO_DELETE=()
[[ -e "$CONFIG_DIR" ]] && TO_DELETE+=("$CONFIG_DIR")
[[ -e "$LOG_FILE" ]] && TO_DELETE+=("$LOG_FILE")
if (( ${#TO_DELETE[@]} == 0 )); then
  echo "  （没有数据文件）"
else
  for p in "${TO_DELETE[@]}"; do
    echo "  $p  ($(human_size "$p"))"
  done
  # 歌词是这里面唯一"重建不回来"的东西：用户可能手工改过、也可能来自已经查不到的源。
  LYRICS_DIR="$CONFIG_DIR/lyrics"
  if [[ -d "$LYRICS_DIR" ]]; then
    n=$(/usr/bin/find "$LYRICS_DIR" -name '*.lrc' -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo
    echo "  ⚠️ 其中包含 $n 个已导出的 .lrc 歌词文件。里面可能有你手工修正过的内容，"
    echo "     删掉之后没有任何办法找回。想留着的话现在先把整个 lyrics/ 目录拷走。"
  fi
fi

echo
printf "确认删除？输入 yes 继续（其它任何输入都会取消）: "
read -r answer
if [[ "$answer" != "yes" ]]; then
  echo "已取消，什么都没动。"
  exit 0
fi

stop_services
echo
echo "=== 删除数据 ==="
for p in "${TO_DELETE[@]}"; do
  /bin/rm -rf "$p" && echo "  ✅ 已删除 $p"
done
echo
echo "偏好设置项还留着，需要的话手动执行: defaults delete $APP_LABEL"
echo "App 本体请自行拖进废纸篓: /Applications/Lyrimuse.app"
