#!/bin/bash
# 全机重活闸(heavy-gate.sh / heavy-run.sh)自测:改了这两个脚本就跑一遍,几十秒,不编译任何东西、不碰真的闸目录。
# 用法:scripts/test-heavy-gate.sh [放着 heavy-gate.sh 和 heavy-run.sh 的目录,默认本脚本所在目录]
# 每项打 ok / FAIL,最后一行 all ok 或 N failure(s),退出码对应。
# 测的是 15 章决策 43、120、121 的约定:同时持有不超过份数、持有者被 SIGKILL 后令牌回收、先来先到、装机优先、
# 排队上限退出码 75、套着排(heavy-run 里再 heavy-run)不死等、拿到 / 放回 / 超时留痕。
set -u
SRC="$(cd "${1:-$(dirname "$0")}" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/heavy-gate-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+
     $2}"; fails=$((fails + 1)); }
export LYRIMUSE_HEAVY_POLL=0.05

# 后台跑一条命令,最多等 $1 秒;超时就杀掉并返回 124(macOS 没有 timeout 命令)。
bounded() {
  local secs="$1" pid i=0 rc
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 10)) ]; then
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid"
  rc=$?
  return $rc
}

# 1. 同时持有不超过份数:2 份,6 个排队者各持有 0.3 秒,在里面登记、出来注销,数最多同时几个。
G="$T/g1"; mkdir -p "$G/inside"
for k in 1 2 3 4 5 6; do
  LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=2 bash "$SRC/heavy-run.sh" "c$k" \
    "touch '$G/inside/$k'; ls '$G/inside' | wc -l >> '$G/counts'; sleep 0.3; rm -f '$G/inside/$k'" > /dev/null 2>&1 &
done
wait
max="$(sort -n "$G/counts" | tail -1 | tr -d ' ')"
if [ "${max:-9}" -le 2 ] && [ "$(wc -l < "$G/counts" | tr -d ' ')" = 6 ]; then ok "同时持有不超过份数(最多 $max 份)"; else fail "同时持有不超过份数" "最多 ${max:-?} 份"; fi

# 2. 持有者被 SIGKILL:令牌回收,下一个马上拿到。
G="$T/g2"; mkdir -p "$G"
sleep 300 & dead=$!; kill -9 $dead; wait $dead 2>/dev/null
mkdir "$G/token-1"; printf '%s\nx\n%s\n' "$dead" "$(date +%s)" > "$G/token-1/owner"
if bounded 5 env LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" t2 true > /dev/null 2>&1; then
  ok "持有者被 SIGKILL 后令牌回收"
else fail "持有者被 SIGKILL 后令牌回收"; fi

# 3. 排队上限:1 份被占着,上限 2 秒,退出码 75,报错里有持有者的说明。
G="$T/g3"; mkdir -p "$G"
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" "占着的那个" "sleep 8" > /dev/null 2>&1 &
holder=$!
for i in $(seq 50); do [ -d "$G/token-1" ] && break; sleep 0.1; done
out="$(LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 LYRIMUSE_HEAVY_WAIT_MAX=2 bounded 6 bash "$SRC/heavy-run.sh" t3 true 2>&1)"
rc=$?
if [ "$rc" = 75 ] && printf '%s' "$out" | grep -q '占着的那个'; then ok "排队超过上限退出码 75,说清谁占着"; else fail "排队超过上限退出码 75" "退出码 $rc:$out"; fi
if grep -q "	timeout	" "$G/events.log" 2>/dev/null; then ok "超时记进 events.log"; else fail "超时记进 events.log"; fi
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 4. 套着排:1 份,heavy-run 里再跑 heavy-run,内层用外层的令牌,不死等。
G="$T/g4"; mkdir -p "$G"
if bounded 8 env LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" outer \
    "bash '$SRC/heavy-run.sh' inner 'echo inner-ran' > '$G/inner.out'" > /dev/null 2>&1 \
    && grep -q inner-ran "$G/inner.out"; then
  ok "heavy-run 里再 heavy-run 用外层的令牌,不死等"
else fail "heavy-run 里再 heavy-run 用外层的令牌,不死等" "8 秒内没跑完"; fi
if [ -z "$(ls "$G" | grep token-)" ]; then ok "套着排跑完令牌放回"; else fail "套着排跑完令牌放回" "$(ls "$G")"; fi

# 5. 先来先到:1 份被占 1.5 秒,5 个校验每隔 0.45 秒来一个(第 5 个在令牌空出来之后才到,前面 4 个还在两轮轮询之间),
#    拿到的顺序跟来的顺序一样。不排先后的写法里第 5 个一到就拿走。
G="$T/g5"; mkdir -p "$G"
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" head "sleep 1.5" > /dev/null 2>&1 &
for i in $(seq 50); do [ -d "$G/token-1" ] && break; sleep 0.05; done
for k in 1 2 3 4 5; do
  LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" "w$k" "echo $k >> '$G/order'; sleep 0.2" > /dev/null 2>&1 &
  sleep 0.45
done
wait
order="$(tr '\n' ' ' < "$G/order")"
if [ "$order" = "1 2 3 4 5 " ]; then ok "先来先到(顺序 $order)"; else fail "先来先到" "拿到的顺序 $order"; fi

# 6. 装机优先:1 份被占,先来一个校验、后来一个装机,装机先拿到。
G="$T/g6"; mkdir -p "$G"
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" head "sleep 1" > /dev/null 2>&1 &
for i in $(seq 50); do [ -d "$G/token-1" ] && break; sleep 0.05; done
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" check "echo check >> '$G/order'" > /dev/null 2>&1 &
sleep 0.3
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash -c ". '$SRC/heavy-gate.sh'; trap heavy_gate_release EXIT; heavy_gate_acquire inst install && echo install >> '$G/order'" > /dev/null 2>&1 &
wait
order="$(tr '\n' ' ' < "$G/order")"
if [ "$order" = "install check " ]; then ok "装机优先($order)"; else fail "装机优先" "顺序 $order"; fi

# 7. 留痕:拿到、放回各一行。
if grep -q "	acquire	" "$T/g6/events.log" 2>/dev/null && grep -q "	release	" "$T/g6/events.log" 2>/dev/null; then
  ok "拿到 / 放回记进 events.log"
else fail "拿到 / 放回记进 events.log"; fi

if [ "$fails" = 0 ]; then echo "all ok"; else echo "$fails failure(s)"; fi
[ "$fails" = 0 ]
