#!/bin/zsh
#
# 用一次性的 launchd job 验证我们对 launchd 行为的假设，**全程不碰真实服务**。
#
#   lyrimuse/scripts/probe-launchd.sh            # 造三种状态，各打印 launchctl 的关键行
#   lyrimuse/scripts/probe-launchd.sh --parse    # 再用 LaunchdPrintParser 解析真实输出
#
# 为什么要有这个脚本:
#
# CollectorServiceManager.isRunning 曾经拿 `launchctl print` 的**退出码**当"进程在跑"用，
# 而那个退出码的真实含义是"这个 job 注册过"。后果是 collector 在 KeepAlive 下崩溃重启
# 循环时，设置页照样显示绿勾"运行中"。这类问题没法靠读代码发现 —— 只能真的造出那个状态
# 问一句 launchd。
#
# 直接拿 com.lyrimuse.collector 做实验是不行的:它是用户正在用的服务，停掉就没歌词了。
# 所以这里全部用自己的一次性 job（label 前缀 me.yudaotor.lyrimuse.probe-），跑完立刻
# bootout，并且用 trap 保证异常退出时也清理干净。
#
# 实测结论（2026-08-15，macOS 27.0）:
#
#   | 场景                | print 退出码 | state 字段            |
#   |---------------------|-------------|-----------------------|
#   | 已注册 + 进程在跑    | 0           | state = running       |
#   | 已注册 + 进程已退出  | 0           | state = not running   |
#   | 未注册              | 113         | (无输出)               |
#
# 还有两个解析陷阱，都在真实输出里:
#   - 同一份输出里同时有 `\tstate = running`、`\t\tstate = active`(嵌套) 和
#     `\tjob state = running`(另一个字段)，用 contains 匹配会读错。
#   - `last exit code` 的值是 `78: EX_CONFIG` 而不是 `78`，直接 Int() 会拿到 nil。
#
set -u

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
UID_="$(id -u)"
PREFIX="me.yudaotor.lyrimuse.probe"
TMPDIR_="$(/usr/bin/mktemp -d /tmp/lyrimuse-launchd-probe.XXXXXX)"
PARSE=0
[[ "${1:-}" == "--parse" ]] && PARSE=1

cleanup() {
  # 不管怎么退出，都要把 probe job 全部注销 —— 留一个在 launchd 里比什么都不测更糟。
  for label in "$PREFIX.running" "$PREFIX.exited" "$PREFIX.quick"; do
    /bin/launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1
  done
  /bin/rm -rf "$TMPDIR_"
}
trap cleanup EXIT INT TERM

# 安全闸:这个脚本只允许操作自己的 probe label，绝不碰真实服务。
assert_probe_label() {
  case "$1" in
    $PREFIX.*) ;;
    *) echo "!! 拒绝操作非 probe label: $1" >&2; exit 2 ;;
  esac
}

make_job() {
  local label="$1"; shift
  assert_probe_label "$label"
  local plist="$TMPDIR_/$label.plist"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>'
    echo "  <string>$*</string></array>"
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><false/>'
    echo '</dict></plist>'
  } > "$plist"
  /bin/launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1
  /bin/launchctl bootstrap "gui/$UID_" "$plist" 2>&1
}

show() {
  local label="$1" note="$2"
  /bin/launchctl print "gui/$UID_/$label" > "$TMPDIR_/$label.out" 2>&1
  local rc=$?
  echo "--- $note"
  echo "    print 退出码 = $rc"
  /usr/bin/grep -E "^	(state|pid|last exit code) = " "$TMPDIR_/$label.out" 2>/dev/null | /usr/bin/sed 's/^/    /'
  [[ $rc -ne 0 ]] && echo "    (无输出)"
  return 0
}

echo "=== 场景 1:注册 + 进程还活着 ==="
make_job "$PREFIX.running" "sleep 30" >/dev/null
/usr/bin/python3 -c 'import time; time.sleep(1.5)'
show "$PREFIX.running" "预期 state = running，带 pid"

echo
echo "=== 场景 2:注册 + 进程已退出（退出码 78）==="
# 必须 sleep 一下再退 —— 退得太快 launchd 来不及记录，会报 (never exited)。
make_job "$PREFIX.exited" "sleep 1; exit 78" >/dev/null
/usr/bin/python3 -c 'import time; time.sleep(4)'
show "$PREFIX.exited" "预期 state = not running，last exit code = 78: EX_CONFIG"

echo
echo "=== 场景 3:未注册 ==="
show "$PREFIX.never-created" "预期退出码 113"

if [[ $PARSE -eq 1 ]]; then
  echo
  echo "=== 用 LaunchdPrintParser 解析上面的真实输出 ==="
  CORE="$REPO_ROOT/lyrimuse/Sources/LyrimuseCore/Local/LaunchdJobState.swift"
  if [[ ! -f "$CORE" ]]; then
    echo "找不到 $CORE"; exit 1
  fi
  DRIVER="$TMPDIR_/parse.swift"
  /bin/cat "$CORE" > "$DRIVER"
  /bin/cat >> "$DRIVER" <<'SWIFT'

// 把上面几份真实输出喂给解析器，确认它对真机数据的判断跟 selftest 里的合成样本一致。
let args = Array(CommandLine.arguments.dropFirst())
for spec in args {
    let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
    let (label, path) = (parts[0], parts[1])
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    // 文件里存的是 print 的输出；退出码单独由调用方按"输出里有没有内容"还原不可靠，
    // 所以这里直接按有无 `= {` 开头判断是否注册（未注册时 launchctl 只打一行错误）。
    let exitCode: Int32 = text.contains(" = {") ? 0 : 113
    print("  \(label) -> \(LaunchdPrintParser.parse(printExitCode: exitCode, printOutput: text))")
}
SWIFT
  swift "$DRIVER" \
    "场景1(在跑)|$TMPDIR_/$PREFIX.running.out" \
    "场景2(已退出)|$TMPDIR_/$PREFIX.exited.out" \
    "场景3(未注册)|$TMPDIR_/$PREFIX.never-created.out"
fi

echo
echo "=== 清理 ==="
cleanup
trap - EXIT INT TERM
for label in "$PREFIX.running" "$PREFIX.exited"; do
  if /bin/launchctl print "gui/$UID_/$label" >/dev/null 2>&1; then
    echo "❌ 仍然注册着: $label"; exit 1
  fi
done
echo "✅ 所有 probe job 已注销"
echo
echo "真实服务未被触碰:"
for label in com.lyrimuse.collector me.yudaotor.lyrimuse; do
  printf "   %-26s " "$label"
  /bin/launchctl print "gui/$UID_/$label" 2>/dev/null | /usr/bin/grep -E "^	state = " || echo "(未注册)"
done
