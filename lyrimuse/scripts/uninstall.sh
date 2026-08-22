#!/bin/zsh
#
# 卸载 Lyrimuse 留在系统里的东西。
#
#   ./uninstall.sh              # 只看：报告装了什么，不做任何改动
#   ./uninstall.sh --services   # 注销两个 launchd job（不碰数据，重装即可恢复）
#   ./uninstall.sh --purge      # 注销 + 删除配置/缓存/日志 + 偏好设置项（要输入 yes 确认）
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

# 这个 domain 里还有没有东西。
#
# ⚠️ 不能用 `defaults read "$1" >/dev/null 2>&1` 的退出码当判据 —— 2026-08-22 实测：
# `defaults delete <domain>` 成功之后，`defaults read <domain>` **仍然退出 0**，只是打印
# 一个空字典 `{}`（cfprefsd 里那个 domain 的空壳还挂着）。拿退出码判等于恒为真，表现是
# 删干净了却报"❌ 仍然存在"。判据只能看读出来有没有内容。
has_defaults() {
  local out
  out=$(/usr/bin/defaults read "$1" 2>/dev/null) || return 1
  local squeezed="${out//[[:space:]]/}"
  [[ -n "$squeezed" && "$squeezed" != "{}" ]]
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
  echo "（--purge 会连偏好设置项一起删，不需要再手动 defaults delete）"
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
# 偏好设置项(UserDefaults)单独列，不进 TO_DELETE —— 那个数组喂给 rm -rf，而这一项要走
# `defaults delete`。两者混在一起的话，路径和 domain 就分不清了。
HAS_DEFAULTS=no
has_defaults "$APP_LABEL" && HAS_DEFAULTS=yes
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
    # 四个后缀一起数：*.lrc 这个 glob 能盖住 .lrc/.tr.lrc/.roma.lrc，但盖不住 .yrc(逐字
    # 时间轴)，而逐字那份恰恰是最难重新抓到的。只报一半的数字会让人低估损失。
    n=$(/usr/bin/find "$LYRICS_DIR" -type f \( -name '*.lrc' -o -name '*.yrc' \) 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    echo
    echo "  ⚠️ 其中包含 $n 个已导出的歌词文件(.lrc/.tr.lrc/.roma.lrc/.yrc)。里面可能有你"
    echo "     手工修正过的内容，删掉之后没有任何办法找回。想留着的话现在先把整个"
    echo "     lyrics/ 目录拷走。"
  fi
fi
if [[ "$HAS_DEFAULTS" == "yes" ]]; then
  echo
  echo "  偏好设置项(UserDefaults 域 $APP_LABEL)：外观/快捷键/歌词时间轴校正值等全部设置"
  echo "  ⚠️ 其中包含你为单曲手调出来的歌词时间轴校正值 —— 那是一句句听出来的，删掉不可恢复。"
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

# 偏好设置项必须一起删，不能像以前那样只打一行"需要的话手动执行"。
#
# 2026-08-22 补。留着它会把重装引向一条**不可自愈的死路**：purge 删掉了 LaunchAgent
# (collector 没装)，而 np:hasCompletedOnboarding 还是 true —— 重装之后首启引导永不出现，
# 而那扇引导页是把 collector 服务装回去的主要入口。用户看到的是桌面永久停在
# 「搜索歌词中…」，界面上没有任何线索指向"后台服务没装"。OnboardingView 顶部注释记的
# 就是这条死路(2026-08-13 为此改过 onDisappear 的置位时机)，只是这次从卸载路径绕了回来。
#
# 整个 domain 一起删而不是挑几个 key：purge 的语义就是"这台机器上当它没装过"，挑 key
# 删既不完整(np:* 之外还有 KeyboardShortcuts_*)，又要跟着代码里的 key 表走样。
#
# ⚠️ domain 用 $APP_LABEL 而不是硬编码：uninstall_test.sh 把它覆盖成一次性的 probe
# label，于是测试跑 --purge 时删的是那个不存在的 domain，碰不到真实偏好——跟两个
# launchd label 可覆盖是同一个理由(测试要走完全相同的代码路径，不开旁路)。
echo
echo "=== 删除偏好设置项 ==="
if [[ "$HAS_DEFAULTS" == "yes" ]]; then
  /usr/bin/defaults delete "$APP_LABEL" >/dev/null 2>&1
  if has_defaults "$APP_LABEL"; then
    echo "  ❌ $APP_LABEL 仍然存在，手动执行: defaults delete $APP_LABEL"
  else
    echo "  ✅ 已删除偏好设置项 $APP_LABEL"
  fi
  # cfprefsd 的写回窗口单独提醒，**不能**做成"App 在跑就跳过删除"的前置闸：
  #   - 跑卸载脚本的人多半 App 还开着（他刚决定不要它了），做成前置闸等于永远不删；
  #   - 这个判据看的是全局有没有 lyrimuse 进程，跟 $APP_LABEL 这个 domain 没有对应关系
  #     （uninstall_test.sh 把 label 覆盖成 probe 域，却会被真实 App 的运行状态挡住 ——
  #     2026-08-22 加这段时被那条测试当场抓出来）。
  # 先删、再核实、最后如实提醒，三件事各归各的。
  if /usr/bin/pgrep -x "lyrimuse" >/dev/null 2>&1; then
    echo "  ⚠️ Lyrimuse 还在运行，它退出时 cfprefsd 可能把内存里那份设置写回来。"
    echo "     退出 App 之后再跑一次 --purge 就能确认干净了。"
  fi
else
  echo "  —  本来就没有 $APP_LABEL"
fi
echo
echo "App 本体请自行拖进废纸篓: /Applications/Lyrimuse.app"
