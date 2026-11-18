#!/bin/bash
# 全机重活闸(heavy-gate.sh / heavy-run.sh)自测:改了这两个脚本就跑一遍,几十秒,不编译任何东西、不碰真的闸目录。
# 用法:scripts/test-heavy-gate.sh [放着 heavy-gate.sh 和 heavy-run.sh 的目录,默认本脚本所在目录]
# 每项打 ok / FAIL,最后一行 all ok 或 N failure(s),退出码对应。
# 测的是 15 章决策 43、120、121 的约定:同时持有不超过份数、持有者被 SIGKILL 后令牌回收、先来先到、装机优先、
# 排队上限退出码 75、套着排(heavy-run 里再 heavy-run)不死等、拿到 / 放回 / 超时留痕、别的闸目录的令牌不继承、
# 停住不刷新的装机登记不再让、持有者的 pid 被后起的进程复用时照样回收、命令里有 build.sh 的不拿令牌。
set -u
# 从外面带进来的闸设置一律清掉:在拿着令牌的进程里跑(heavy-run 里起的校验)时,继承来的令牌、上限会改掉每一项的结果。
unset LYRIMUSE_HEAVY_GATE_TOKEN LYRIMUSE_HEAVY_GATE LYRIMUSE_HEAVY_GATE_DIR LYRIMUSE_HEAVY_SLOTS \
  LYRIMUSE_HEAVY_WAIT_MAX LYRIMUSE_HEAVY_HOLD_WARN
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

# 8. 别的闸目录的令牌不继承:令牌在另一个目录、持有者还活着,这边 1 份被占着、上限 1 秒,照样排队到 75。
G="$T/g8"; O="$T/g8-outer"; mkdir -p "$G" "$O/token-1"
printf '%s\nouter\n%s\n' "$$" "$(date +%s)" > "$O/token-1/owner"
sleep 30 & h8=$!
mkdir "$G/token-1"; printf '%s\nheld\n%s\n' "$h8" "$(date +%s)" > "$G/token-1/owner"
LYRIMUSE_HEAVY_GATE_TOKEN="$O/token-1:$$" LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 LYRIMUSE_HEAVY_WAIT_MAX=1 \
  bounded 5 bash "$SRC/heavy-run.sh" t8 true > /dev/null 2>&1
rc=$?
if [ "$rc" = 75 ]; then ok "别的闸目录的令牌不继承"; else fail "别的闸目录的令牌不继承" "退出码 $rc(0 = 被当成祖先拿着令牌直接放行)"; fi
kill "$h8" 2>/dev/null; wait "$h8" 2>/dev/null

# 9. 装机登记要刷新:排着的装机每轮刷新 want-install.<pid>;进程还在、30 秒没刷新的(被 SIGSTOP 停住)校验不再让。
G="$T/g9"; mkdir -p "$G"
old="$(date -v-40S +%Y%m%d%H%M.%S)"
# 占着令牌的一直拿着,直到读完刷新时间放行:负载高时固定睡几秒会先放掉令牌,装机拿到令牌删了登记,下面的 touch 再建出一个旧文件。
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" head "for i in \$(seq 200); do [ -e '$G/release' ] && break; sleep 0.05; done" > /dev/null 2>&1 &
h9=$!
for i in $(seq 50); do [ -d "$G/token-1" ] && break; sleep 0.05; done
LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash -c ". '$SRC/heavy-gate.sh'; trap heavy_gate_release EXIT; heavy_gate_acquire inst install" > /dev/null 2>&1 &
inst=$!
for i in $(seq 50); do [ -e "$G/want-install.$inst" ] && break; sleep 0.05; done
touch -c -t "$old" "$G/want-install.$inst" 2>/dev/null
for i in $(seq 60); do
  sleep 0.05
  age=$(( $(date +%s) - $(stat -f %m "$G/want-install.$inst" 2>/dev/null || echo 0) ))
  [ "$age" -le 5 ] && break
done
touch "$G/release"
if [ "$age" -le 5 ]; then ok "排着的装机每轮刷新 want-install"; else fail "排着的装机每轮刷新 want-install" "登记 $age 秒没刷新"; fi
wait "$h9" "$inst" 2>/dev/null
sleep 30 & stopped=$!
kill -STOP "$stopped"
touch "$G/want-install.$stopped"
out="$(LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 LYRIMUSE_HEAVY_WAIT_MAX=1 bounded 5 bash "$SRC/heavy-run.sh" fresh true 2>&1)"
rc=$?
if [ "$rc" = 75 ]; then ok "刚刷新过的装机登记照样让"; else fail "刚刷新过的装机登记照样让" "退出码 $rc:$out"; fi
touch -t "$old" "$G/want-install.$stopped"
out="$(LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 LYRIMUSE_HEAVY_WAIT_MAX=2 bounded 5 bash "$SRC/heavy-run.sh" stale true 2>&1)"
rc=$?
if [ "$rc" = 0 ]; then ok "停住 30 秒没刷新的装机登记不再让"; else fail "停住 30 秒没刷新的装机登记不再让" "退出码 $rc:$out"; fi
kill -CONT "$stopped" 2>/dev/null; kill "$stopped" 2>/dev/null; wait "$stopped" 2>/dev/null

# 10. pid 被复用:令牌记的开始时刻在那个 pid 的进程起来之前十分钟,当作 SIGKILL 留下的令牌回收;开始时刻在它起来之后的照样等。
G="$T/g10"; mkdir -p "$G"
sleep 30 & reused=$!
mkdir "$G/token-1"; printf '%s\nx\n%s\n' "$reused" "$(( $(date +%s) - 600 ))" > "$G/token-1/owner"
if bounded 5 env LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 bash "$SRC/heavy-run.sh" t10 true > /dev/null 2>&1; then
  ok "持有者 pid 被后起的进程复用时令牌回收"
else fail "持有者 pid 被后起的进程复用时令牌回收"; fi
rm -rf "$G/token-1"; mkdir "$G/token-1"; printf '%s\nx\n%s\n' "$reused" "$(date +%s)" > "$G/token-1/owner"
out="$(LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 LYRIMUSE_HEAVY_WAIT_MAX=1 bounded 5 bash "$SRC/heavy-run.sh" t10b true 2>&1)"
rc=$?
if [ "$rc" = 75 ]; then ok "持有者在开始时刻之前就起来了照样等"; else fail "持有者在开始时刻之前就起来了照样等" "退出码 $rc:$out"; fi

# 11. 命令里有 build.sh 的不拿令牌:1 份被占着,照样当场跑完。
rm -rf "$G/token-1"; mkdir "$G/token-1"; printf '%s\nx\n%s\n' "$reused" "$(date +%s)" > "$G/token-1/owner"
out="$(LYRIMUSE_HEAVY_GATE_DIR="$G" LYRIMUSE_HEAVY_SLOTS=1 LYRIMUSE_HEAVY_WAIT_MAX=1 bounded 5 bash "$SRC/heavy-run.sh" t11 "echo ./build.sh" 2>&1)"
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q build.sh; then ok "命令里有 build.sh 的不拿令牌"; else fail "命令里有 build.sh 的不拿令牌" "退出码 $rc:$out"; fi
kill "$reused" 2>/dev/null; wait "$reused" 2>/dev/null

if [ "$fails" = 0 ]; then echo "all ok"; else echo "$fails failure(s)"; fi
[ "$fails" = 0 ]
