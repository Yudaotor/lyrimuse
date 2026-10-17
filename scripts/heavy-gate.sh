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
# 不生效的情况:LYRIMUSE_HEAVY_GATE=0、包管理器构建(设了 LYRIMUSE_SPM_SCRATCH_PATH)、建不了令牌目录。
# 用法:heavy_gate_acquire <说明> install|check;退出前 heavy_gate_release(放进调用方自己的 EXIT trap)。

HEAVY_GATE_DIR="${LYRIMUSE_HEAVY_GATE_DIR:-$HOME/Library/Caches/lyrimuse-heavy-gate}"
HEAVY_GATE_SLOTS="${LYRIMUSE_HEAVY_SLOTS:-2}"
HEAVY_GATE_HELD=""
HEAVY_GATE_WANT=""

# 取不到(owner 还没写、目录已经没了)时输出空串、返回 0:调用方开着 set -e,赋值里的非零会让整个脚本退出。
heavy_gate_owner_pid() { sed -n 1p "$1/owner" 2>/dev/null || true; }

# heavy_gate_stale <令牌目录>:持有进程不在了;或者 owner 一直没写上(建了目录就被杀)、目录超过一分钟。
heavy_gate_stale() {
  local pid
  pid="$(heavy_gate_owner_pid "$1")"
  if [ -n "$pid" ]; then
    ! kill -0 "$pid" 2>/dev/null
  else
    [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
  fi
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

heavy_gate_holders() {
  local tok out=""
  for tok in "$HEAVY_GATE_DIR"/token-*; do
    [ -d "$tok" ] || continue
    out="$out $(sed -n 2p "$tok/owner" 2>/dev/null || true)(pid $(heavy_gate_owner_pid "$tok"))"
  done
  echo "${out:- 无}"
}

heavy_gate_acquire() {
  local label="$1" prio="$2" waited=0 start i tok pid
  if [ "${LYRIMUSE_HEAVY_GATE:-1}" = 0 ] || [ -n "${LYRIMUSE_SPM_SCRATCH_PATH:-}" ] || [ -n "$HEAVY_GATE_HELD" ]; then
    return 0
  fi
  mkdir -p "$HEAVY_GATE_DIR" 2>/dev/null || return 0
  if [ "$prio" = install ]; then
    HEAVY_GATE_WANT="$HEAVY_GATE_DIR/want-install.$$"
    : > "$HEAVY_GATE_WANT" 2>/dev/null || HEAVY_GATE_WANT=""
  fi
  start="$(date +%s)"
  while :; do
    if [ "$prio" = install ] || ! heavy_gate_install_waiting; then
      i=1
      while [ "$i" -le "$HEAVY_GATE_SLOTS" ]; do
        tok="$HEAVY_GATE_DIR/token-$i"
        if mkdir "$tok" 2>/dev/null; then
          printf '%s\n%s\n%s\n' "$$" "$label" "$(date +%s)" > "$tok/owner"
          HEAVY_GATE_HELD="$tok"
          if [ -n "$HEAVY_GATE_WANT" ]; then rm -f "$HEAVY_GATE_WANT"; HEAVY_GATE_WANT=""; fi
          if [ "$waited" = 1 ]; then
            echo "==> 全机重活闸:排了 $(( $(date +%s) - start )) 秒,轮到 $label"
          fi
          return 0
        fi
        if heavy_gate_stale "$tok"; then
          # 回收前再核对一次持有者:别的排队者可能刚回收、写进了自己的 pid。
          pid="$(heavy_gate_owner_pid "$tok")"
          if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$tok"
            continue
          fi
        fi
        i=$((i + 1))
      done
    fi
    if [ "$waited" = 0 ]; then
      echo "==> 全机重活闸满了(同时最多 $HEAVY_GATE_SLOTS 份),$label 排队。正在跑:$(heavy_gate_holders)"
      waited=1
    fi
    sleep 2
  done
}

heavy_gate_release() {
  if [ -n "$HEAVY_GATE_WANT" ]; then rm -f "$HEAVY_GATE_WANT"; HEAVY_GATE_WANT=""; fi
  if [ -n "$HEAVY_GATE_HELD" ] && [ "$(heavy_gate_owner_pid "$HEAVY_GATE_HELD")" = "$$" ]; then
    rm -rf "$HEAVY_GATE_HELD"
  fi
  HEAVY_GATE_HELD=""
}
