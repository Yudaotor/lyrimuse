# 全机重活闸:build.sh(装机、打包)和 commit-checks.sh(提交校验)source 它,同一台机器上同时最多
# LYRIMUSE_HEAVY_SLOTS(默认 2)份 Swift / Go 整套编译和测试在跑,后到的原地排队。
#
# 为什么要有:多个会话共用这台机器,build.sh 只管装机之间互斥,提交校验另有几个常驻目录各跑各的,两边互不知道;
# 每份 swift build 都按核数开满并行,四五份挤在一起时内存压进交换区、安全扫描跟着吃满一个核,每份都更慢、
# 界面也卡。限住份数,单份反而跑得快。
#
# 令牌是 $LYRIMUSE_HEAVY_GATE_DIR(默认 ~/Library/Caches/lyrimuse-heavy-gate)下的 token-<n> 目录(mkdir 原子),
# 里面 owner 文件三行:pid、说明、开始时刻。持有进程已经不在的令牌直接回收,不用等超时。装机优先:有装机在等
# (want-install.<pid>)时,校验不去抢空出来的令牌。
# 排队(15 章决策 121):
# - 先来先到:排队的登记 wait.<pid>(开始时刻、优先级、说明,排队时每轮刷新修改时间),同优先级里有更早来、还在排的,
#   就不去拿空出来的令牌。以前谁轮询赶上谁拿,后来的能一直插到前面。
# - 有上限:排了 LYRIMUSE_HEAVY_WAIT_MAX 秒(默认 3600,0 = 不限)还没轮到就报错退出(返回 75),打出谁占着、各跑了
#   多久;每 60 秒打一行还在排、前面几个、谁占着,跑过 LYRIMUSE_HEAVY_HOLD_WARN 秒(默认 1800)的持有者标出来。
# - 可重入:拿到令牌后导出 LYRIMUSE_HEAVY_GATE_TOKEN=<令牌>:<pid>,子进程里再来排(heavy-run.sh 里的脚本又调
#   commit-checks.sh、build.sh)时令牌还在这个 pid 手里就直接用,不再占第二个:以前两个这样套着的各拿一个、
#   都等第二个,就永远等下去。跟 GNU make jobserver 把令牌传给子 make 一个道理。
# - 留痕:拿到、放回、超时各记一行到 events.log(超过 1MB 换到 events.log.1),排查「时间都去哪了」看它。
# 不生效的情况:LYRIMUSE_HEAVY_GATE=0、建不了令牌目录。
# 用法:heavy_gate_acquire <说明> install|check || exit $?;退出前 heavy_gate_release(放进调用方自己的 EXIT trap)。

HEAVY_GATE_DIR="${LYRIMUSE_HEAVY_GATE_DIR:-$HOME/Library/Caches/lyrimuse-heavy-gate}"
HEAVY_GATE_SLOTS="${LYRIMUSE_HEAVY_SLOTS:-2}"
HEAVY_GATE_WAIT_MAX="${LYRIMUSE_HEAVY_WAIT_MAX:-3600}"
HEAVY_GATE_HOLD_WARN="${LYRIMUSE_HEAVY_HOLD_WARN:-1800}"
HEAVY_GATE_POLL="${LYRIMUSE_HEAVY_POLL:-2}"
HEAVY_GATE_HELD=""
HEAVY_GATE_WANT=""
HEAVY_GATE_WAITFILE=""
HEAVY_GATE_T0=""

# 取不到(owner 还没写、目录已经没了)时输出空串、返回 0:调用方开着 set -e,赋值里的非零会让整个脚本退出。
heavy_gate_owner_pid() { sed -n 1p "$1/owner" 2>/dev/null || true; }

heavy_gate_log() {
  local log="$HEAVY_GATE_DIR/events.log" size
  [ -d "$HEAVY_GATE_DIR" ] || return 0
  size="$(stat -f %z "$log" 2>/dev/null || echo 0)"
  if [ "${size:-0}" -gt 1048576 ] 2>/dev/null; then mv -f "$log" "$log.1" 2>/dev/null || true; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$$" "$2" "${3:-}" >> "$log" 2>/dev/null || true
}

# heavy_gate_stale <令牌目录> <读到的 pid>:持有进程不在了;或者 owner 一直没写上(建了目录就被杀)、目录超过一分钟。
heavy_gate_stale() {
  local pid="$2"
  if [ -n "$pid" ]; then
    ! kill -0 "$pid" 2>/dev/null
  else
    [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
  fi
}

# heavy_gate_take_over_stale <令牌目录> <判陈旧时读到的 pid>:删陈旧令牌。先进接管闸($HEAVY_GATE_DIR/takeover,mkdir 原子),
# 闸里再读一遍 owner,还是判定时那一个才删(没写 pid 的,目录仍是一分钟前建的);别的排队者刚回收重建过的令牌 pid 变了
# 或还没写上,不删。闸被占着时返回 1。同 build.sh 的接管闸,见 15 章决策 120。
heavy_gate_take_over_stale() {
  local tok="$1" holder="$2" gate="$HEAVY_GATE_DIR/takeover" now
  if ! mkdir "$gate" 2>/dev/null; then
    # 闸只拿几毫秒,一分钟前建的是拿着它的进程被 SIGKILL 留下的。
    if [ -n "$(find "$gate" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$gate" 2>/dev/null || true; fi
    return 1
  fi
  now="$(heavy_gate_owner_pid "$tok")"
  if [ "$now" = "$holder" ] && heavy_gate_stale "$tok" "$now"; then
    rm -rf "$tok"
  fi
  rmdir "$gate" 2>/dev/null || true
}

# heavy_gate_install_waiting:有还活着的装机在排队(顺手清掉进程已经不在的登记)。
heavy_gate_install_waiting() {
  local f pid found=1
  for f in "$HEAVY_GATE_DIR"/want-install.*; do
    [ -e "$f" ] || continue
    pid="${f##*.}"
    if kill -0 "$pid" 2>/dev/null; then found=0; else rm -f "$f"; fi
  done
  return $found
}

# heavy_gate_ahead <自己的开始时刻> <优先级>:输出同优先级里比自己先来、还在排的个数(先来先到用),顺手清掉进程已经
# 不在的登记。30 秒没刷新的(进程被停住)不算,免得一个挂起的排队者堵住后面所有人。
heavy_gate_ahead() {
  local me_t="$1" me_prio="$2" f pid t prio now n=0 mtime
  now="$(date +%s)"
  for f in "$HEAVY_GATE_DIR"/wait.*; do
    [ -e "$f" ] || continue
    pid="${f##*.}"
    [ "$pid" = "$$" ] && continue
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$f"; continue; fi
    mtime="$(stat -f %m "$f" 2>/dev/null || echo 0)"
    [ $((now - ${mtime:-0})) -le 30 ] || continue
    t=""; prio=""
    { read -r t prio _ < "$f"; } 2>/dev/null || true
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ "$prio" = "$me_prio" ] || continue
    if [ "$t" -lt "$me_t" ] || { [ "$t" = "$me_t" ] && [ "$pid" -lt "$$" ]; }; then n=$((n + 1)); fi
  done
  echo "$n"
}

# 正在跑的:说明(pid、已跑多久),超过 HOLD_WARN 的标出来。
heavy_gate_holders() {
  local tok out="" now pid label t0 age mark
  now="$(date +%s)"
  for tok in "$HEAVY_GATE_DIR"/token-*; do
    [ -d "$tok" ] || continue
    pid="$(heavy_gate_owner_pid "$tok")"
    label="$(sed -n 2p "$tok/owner" 2>/dev/null || true)"
    t0="$(sed -n 3p "$tok/owner" 2>/dev/null || true)"
    case "$t0" in ''|*[!0-9]*) t0="$now" ;; esac
    age=$((now - t0))
    mark=""
    if [ "$age" -ge "$HEAVY_GATE_HOLD_WARN" ]; then mark=",超过 $((HEAVY_GATE_HOLD_WARN / 60)) 分钟,可能卡住"; fi
    out="$out ${label:-?}(pid ${pid:-?},已跑 $((age / 60)) 分 $((age % 60)) 秒$mark)"
  done
  echo "${out:- 无}"
}

# 祖先进程已经拿着令牌(见头注「可重入」):令牌还在记下的那个 pid 手里、它也还活着。
heavy_gate_inherited() {
  local v="${LYRIMUSE_HEAVY_GATE_TOKEN:-}" tok pid
  [ -n "$v" ] || return 1
  tok="${v%:*}"
  pid="${v##*:}"
  [ -n "$pid" ] && [ "$(heavy_gate_owner_pid "$tok")" = "$pid" ] && kill -0 "$pid" 2>/dev/null
}

heavy_gate_acquire() {
  local label="$1" prio="$2" waited=0 start now i tok pid ahead last_note
  if [ "${LYRIMUSE_HEAVY_GATE:-1}" = 0 ] || [ -n "$HEAVY_GATE_HELD" ]; then
    return 0
  fi
  if heavy_gate_inherited; then
    heavy_gate_log inherit "$label" "$LYRIMUSE_HEAVY_GATE_TOKEN"
    return 0
  fi
  mkdir -p "$HEAVY_GATE_DIR" 2>/dev/null || return 0
  start="$(date +%s)"
  last_note="$start"
  if [ "$prio" = install ]; then
    HEAVY_GATE_WANT="$HEAVY_GATE_DIR/want-install.$$"
    : > "$HEAVY_GATE_WANT" 2>/dev/null || HEAVY_GATE_WANT=""
  fi
  HEAVY_GATE_WAITFILE="$HEAVY_GATE_DIR/wait.$$"
  printf '%s %s %s\n' "$start" "$prio" "$label" > "$HEAVY_GATE_WAITFILE" 2>/dev/null || HEAVY_GATE_WAITFILE=""
  while :; do
    if [ -n "$HEAVY_GATE_WAITFILE" ]; then touch "$HEAVY_GATE_WAITFILE" 2>/dev/null || true; fi
    ahead="$(heavy_gate_ahead "$start" "$prio")"
    if [ "$ahead" = 0 ] && { [ "$prio" = install ] || ! heavy_gate_install_waiting; }; then
      i=1
      while [ "$i" -le "$HEAVY_GATE_SLOTS" ]; do
        tok="$HEAVY_GATE_DIR/token-$i"
        if mkdir "$tok" 2>/dev/null; then
          printf '%s\n%s\n%s\n' "$$" "$label" "$(date +%s)" > "$tok/owner"
          HEAVY_GATE_HELD="$tok"
          HEAVY_GATE_T0="$(date +%s)"
          export LYRIMUSE_HEAVY_GATE_TOKEN="$tok:$$"
          heavy_gate_drop_wait
          heavy_gate_log acquire "$label" "waited=$((HEAVY_GATE_T0 - start))"
          if [ "$waited" = 1 ]; then
            echo "==> 全机重活闸:排了 $((HEAVY_GATE_T0 - start)) 秒,轮到 $label"
          fi
          return 0
        fi
        # 陈旧令牌交给接管函数删,这里不直接删:几个排队者同时判定同一个令牌陈旧时,不加闸会后一个把前一个刚重建的令牌删掉。
        pid="$(heavy_gate_owner_pid "$tok")"
        if heavy_gate_stale "$tok" "$pid"; then
          heavy_gate_take_over_stale "$tok" "$pid" || sleep 0.2
          continue
        fi
        i=$((i + 1))
      done
    fi
    now="$(date +%s)"
    if [ "$waited" = 0 ]; then
      echo "==> 全机重活闸满了(同时最多 $HEAVY_GATE_SLOTS 份),$label 排队(前面还有 $ahead 个)。正在跑:$(heavy_gate_holders)"
      waited=1
    elif [ $((now - last_note)) -ge 60 ]; then
      echo "==> 全机重活闸还在排(已等 $((now - start)) 秒,前面还有 $ahead 个)。正在跑:$(heavy_gate_holders)"
      last_note="$now"
    fi
    if [ "$HEAVY_GATE_WAIT_MAX" -gt 0 ] 2>/dev/null && [ $((now - start)) -ge "$HEAVY_GATE_WAIT_MAX" ]; then
      echo "!! 全机重活闸排了 $((now - start)) 秒还没轮到 $label(上限 LYRIMUSE_HEAVY_WAIT_MAX=$HEAVY_GATE_WAIT_MAX 秒),不等了。" \
        "正在跑:$(heavy_gate_holders)。持有者跑了很久、CPU 时间不涨(ps -o pid,etime,time,command -p <pid>)多半是卡住了;" \
        "等得起就调大上限重跑" >&2
      heavy_gate_log timeout "$label" "waited=$((now - start))"
      heavy_gate_drop_wait
      return 75
    fi
    sleep "$HEAVY_GATE_POLL"
  done
}

heavy_gate_drop_wait() {
  if [ -n "$HEAVY_GATE_WANT" ]; then rm -f "$HEAVY_GATE_WANT"; HEAVY_GATE_WANT=""; fi
  if [ -n "$HEAVY_GATE_WAITFILE" ]; then rm -f "$HEAVY_GATE_WAITFILE"; HEAVY_GATE_WAITFILE=""; fi
}

heavy_gate_release() {
  heavy_gate_drop_wait
  if [ -n "$HEAVY_GATE_HELD" ] && [ "$(heavy_gate_owner_pid "$HEAVY_GATE_HELD")" = "$$" ]; then
    heavy_gate_log release "$(sed -n 2p "$HEAVY_GATE_HELD/owner" 2>/dev/null || true)" "held=$(( $(date +%s) - ${HEAVY_GATE_T0:-0} ))"
    rm -rf "$HEAVY_GATE_HELD"
  fi
  if [ "${LYRIMUSE_HEAVY_GATE_TOKEN:-}" = "$HEAVY_GATE_HELD:$$" ]; then unset LYRIMUSE_HEAVY_GATE_TOKEN; fi
  HEAVY_GATE_HELD=""
}
