#!/bin/bash
# 放歌实验的包装:要让播放器真放歌的验证 / 复现实验一律经它跑,收尾不靠记得暂停。
#
#   lyrimuse/scripts/play-experiment.sh [--max-seconds N] <命令> [参数…]
#
#   1. 开跑前记下谁在放:系统「正在播放」(media-control get,哪个播放器都认),以及 Music / Spotify / Kaset
#      自己报的播放状态(只问已经在跑的,不会把没开的拉起来)。
#   2. 跑 <命令>,最长 N 秒(默认 300),到点结束它。
#   3. 不论正常结束、出错、被 Ctrl-C / kill 还是超时,收尾都再看一遍:开跑前没在放、现在在放的,暂停掉;
#      开跑前用户自己就在放的那个不动。
#   4. 列出这段时间引擎记下的收听(~/Library/Logs/lyrimuse.log 里的 `listen recorded`),用来核对实验有没有放过头。
#
# 退出码 = <命令> 的退出码,超时是 142。
#
# 认不出的情况:QQ 音乐用链接开播后几十秒内不往系统报播放信息,这段时间收尾看不到它在放。测 QQ 音乐时
# <命令> 自己要在结束前暂停或退出它。
set -u

max=300
if [ "${1:-}" = "--max-seconds" ]; then
    max=${2:?--max-seconds 后面要跟秒数}
    shift 2
fi
if [ $# -eq 0 ]; then
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

MC=/Applications/Lyrimuse.app/Contents/Resources/media-control/bin/media-control
LOG="$HOME/Library/Logs/lyrimuse.log"
started=$(date -u +%Y-%m-%dT%H:%M:%S)

# 系统「正在播放」:输出「bundle id 空格 1/0」,什么都没有时是「- 0」。
now_playing() {
    "$MC" get --no-artwork 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin) or {}
except Exception:
    d = {}
print(d.get("bundleIdentifier") or "-", "1" if d.get("playing") else "0")'
}

# Music / Spotify / Kaset 里此刻在放的,每行一个名字。没在跑的不问。
apps_playing() {
    /usr/bin/osascript <<'OSA' 2>/dev/null
set out to {}
if application "Music" is running then
    tell application "Music" to if (player state as string) is "playing" then set end of out to "Music"
end if
if application "Spotify" is running then
    tell application "Spotify" to if (player state as string) is "playing" then set end of out to "Spotify"
end if
if application "Kaset" is running then
    tell application "Kaset" to set info to (get player info)
    if info contains "\"isPlaying\":true" or info contains "\"isPlaying\": true" then set end of out to "Kaset"
end if
set AppleScript's text item delimiters to linefeed
return out as text
OSA
}

before_np=$(now_playing)
before_apps=$(apps_playing)
echo "play-experiment: 开跑前 正在播放=${before_np} 在放的 App=[$(echo ${before_apps})]"

child=
finish() {
    rc=$?
    trap - EXIT INT TERM
    # 被中断时 <命令> 还在跑:先结束它,不然它会接着放、接着开播。
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null
        wait "$child" 2>/dev/null
    fi
    sleep 1
    for app in $(apps_playing); do
        if ! printf '%s\n' "$before_apps" | /usr/bin/grep -qx "$app"; then
            /usr/bin/osascript -e "tell application \"$app\" to pause" >/dev/null 2>&1
            echo "play-experiment: 暂停了 $app(开跑前没在放)"
        fi
    done
    after_np=$(now_playing)
    if [ "${after_np##* }" = 1 ] && [ "$after_np" != "$before_np" ]; then
        "$MC" pause >/dev/null 2>&1
        echo "play-experiment: 暂停了系统正在播放的 ${after_np% *}(开跑前不是它在放)"
    fi
    /usr/bin/python3 - "$LOG" "$started" <<'PY'
import re, sys
log, since = sys.argv[1], sys.argv[2]
rows = []
try:
    for line in open(log, encoding="utf-8", errors="replace"):
        m = re.match(r'time=(\S+) .*msg="(listen recorded: [^"]*)"', line)
        if m and m.group(1)[:19] >= since:
            rows.append("  %s  %s" % (m.group(1)[:19], m.group(2)))
except OSError:
    pass
if rows:
    print("play-experiment: 这段时间引擎记下了 %d 首收听(UTC):" % len(rows))
    print("\n".join(rows))
else:
    print("play-experiment: 这段时间没有记下收听")
PY
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT TERM

/usr/bin/perl -e 'alarm shift; exec @ARGV' "$max" "$@" &
child=$!
wait "$child"
