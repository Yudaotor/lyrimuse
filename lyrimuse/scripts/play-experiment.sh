#!/bin/bash
# 放歌实验的包装:要让播放器真放歌的验证 / 复现实验一律经它跑,收尾不靠记得暂停。
#
#   lyrimuse/scripts/play-experiment.sh [--max-seconds N] [--scrobble] <命令> [参数…]
#
#   0. 先打开 Lyrimuse 的测试期开关(深链 debug/scrobble-hold,带本次的 id,时长 N 秒再加 10 分钟、最多 2 小时):这段时间放的歌
#      不发 Last.fm / ListenBrainz、不记本地收听日志。开不上(App 没开调试深链)就不跑、退出码 146。实验本身要验打卡的加 --scrobble,
#      不开开关。收尾时只收掉本次这一条,别的实验开的不动。开关封顶 2 小时,不带 --scrobble 时 N 最多 6600 秒,超了不跑、退出码 2。
#      见 12 章决策 98、101。
#   1. 开跑前记下谁在放:系统「正在播放」(media-control get,哪个播放器都认),每个播放器各自那份会话
#      (App 里的 nowplaying-clients 探针),Music / Spotify / Kaset 自己报的播放状态(只问已经在跑的,
#      不会把没开的拉起来),再录 1 秒系统声音当基线(audio-level.swift,只算音量、不存声音)。
#   2. 跑 <命令>,最长 N 秒(默认 300),到点结束它。
#   3. 不论正常结束、出错、被 Ctrl-C / kill 还是超时,收尾都再看一遍:开跑前没在放、现在在放的,暂停掉;
#      开跑前用户自己就在放的那个不动。
#   4. 暂停完再核对两样,不对就用「!!」开头的行报出来:各播放器会话里还有没有开跑前没在放、现在报在放的;
#      再录 2 秒系统声音,开跑前安静、现在有声,就是还有东西在放(播放器自己报的状态跟不上时只有这一条能看出来)。
#   5. 列出这段时间引擎记下的收听(~/Library/Logs/Lyrimuse/lyrimuse.log 里的 `listen recorded`)和因测试跳过的(`listen skipped`),
#      用来核对实验有没有放过头、开关有没有挡住。
#
# 退出码 = <命令> 的退出码,超时是 142;收尾还听得到声音时一律是 145,优先于前两种;测试期开关没开上、没放歌是 146。
#
# 认不出的情况:QQ 音乐用链接开播后几十秒内不往系统报播放信息,弹出付费会员窗时菜单和媒体指令都不接,
# 这两种收尾都暂停不了它、只能靠第 4 步的声音核对报出来。测 QQ 音乐时 <命令> 自己要在结束前暂停或退出它。
# 录不了系统声音(终端没有屏幕录制权限)时第 4 步只核对会话,会打一行说明。
set -u

max=300
scrobble=0
while [ $# -gt 0 ]; do
    case "$1" in
        --max-seconds)
            max=${2:?--max-seconds 后面要跟秒数}
            shift 2
            ;;
        --scrobble)
            scrobble=1
            shift
            ;;
        *) break ;;
    esac
done
if [ $# -eq 0 ]; then
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi
case "$max" in
    ''|*[!0-9]*)
        echo "play-experiment: --max-seconds 要是正整数秒数:$max"
        exit 2
        ;;
esac
# 测试期开关最长 120 分钟、这里留 10 分钟余量:实验跑得比开关久,开关到期之后放的歌就会记进收听。
if [ "$scrobble" = 0 ] && [ "$max" -gt 6600 ]; then
    echo "play-experiment: --max-seconds 最多 6600(测试期开关封顶 2 小时);更长的实验拆成几次跑"
    exit 2
fi

MC=/Applications/Lyrimuse.app/Contents/Resources/media-control/bin/media-control
NPC=/Applications/Lyrimuse.app/Contents/Resources/nowplaying-clients
LOG="$HOME/Library/Logs/Lyrimuse/lyrimuse.log"
here=$(cd "$(dirname "$0")" && pwd)
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

# 各播放器会话里报在放的,每行「bundle id<Tab>歌名」。
clients_playing() {
    /usr/bin/perl "$NPC/nowplaying-clients.pl" "$NPC/libnowplaying-clients.dylib" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin) or []
except Exception:
    rows = []
for r in rows:
    if r.get("playing") and r.get("bundleIdentifier"):
        print("%s\t%s" % (r["bundleIdentifier"], r.get("title") or ""))'
}

# 录 <秒数> 秒系统声音,输出 audio-level.swift 那一行;录不了时什么都不输出。编好的程序按源码内容缓存在临时目录。
audio_level() {
    local src="$here/audio-level.swift" bin
    bin="${TMPDIR:-/tmp}/lyrimuse-audio-level-$(/usr/bin/shasum "$src" 2>/dev/null | cut -c1-12)"
    if [ ! -x "$bin" ]; then
        /usr/bin/xcrun swiftc -O "$src" -o "$bin.tmp" >/dev/null 2>&1 && mv "$bin.tmp" "$bin"
    fi
    [ -x "$bin" ] && "$bin" "$1" 2>/dev/null
}

# audio-level 那一行里有声的块超过三成才算在出声。
is_loud() {
    case "$1" in
        loud=*/*) ;;
        *) return 1 ;;
    esac
    local counts=${1%% *}
    counts=${counts#loud=}
    local loud=${counts%/*} total=${counts#*/}
    [ "$total" -gt 0 ] && [ $((loud * 10)) -gt $((total * 3)) ]
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

HOLD_REPORT="$HOME/Library/Caches/me.yudaotor.lyrimuse/debug/scrobble-hold.json"
hold_id="play-experiment-$$"

# 测试期开关的回执里有没有本次这一条、而且没到期。
hold_confirmed() {
    /usr/bin/python3 - "$HOLD_REPORT" "$hold_id" <<'PY'
import json, sys, time
try:
    holds = json.load(open(sys.argv[1], encoding="utf-8")).get("holds") or []
except Exception:
    sys.exit(1)
sys.exit(0 if any(h.get("id") == sys.argv[2] and h.get("until", 0) > time.time() for h in holds) else 1)
PY
}

if [ "$scrobble" = 0 ]; then
    hold_minutes=$(( (max + 59) / 60 + 10 ))
    /usr/bin/open -g "lyrimuse://debug/scrobble-hold?minutes=${hold_minutes}&id=${hold_id}"
    ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if hold_confirmed; then
            ok=1
            break
        fi
        sleep 0.5
    done
    if [ "$ok" = 0 ]; then
        echo "play-experiment: !! 测试期开关没开上(App 没在跑,或没开 defaults write me.yudaotor.lyrimuse debug:deepLinks -bool true),不放歌;实验要验打卡就加 --scrobble"
        exit 146
    fi
    echo "play-experiment: 测试期开关已开 ${hold_minutes} 分钟(id=${hold_id}),这段时间放的歌不记收听"
fi

before_np=$(now_playing)
before_apps=$(apps_playing)
before_clients=$(clients_playing | cut -f1)
before_audio=$(audio_level 1)
echo "play-experiment: 开跑前 正在播放=${before_np} 在放的 App=[$(echo ${before_apps})] 在放的会话=[$(echo ${before_clients})] 声音=${before_audio:-录不了}"

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
    sleep 1
    clients_playing | while IFS="$(printf '\t')" read -r bundle title; do
        printf '%s\n' "$before_clients" | /usr/bin/grep -qxF "$bundle" && continue
        echo "play-experiment: !! $bundle 的会话还报在放:$title(开跑前没在放)"
        if [ "$bundle" = com.tencent.QQMusicMac ]; then
            echo "play-experiment: !! QQ 音乐弹出付费会员窗时菜单和媒体指令都不接,先关掉那个窗再暂停"
        fi
    done
    after_audio=$(audio_level 2)
    if [ -z "$after_audio" ] || [ -z "$before_audio" ]; then
        echo "play-experiment: 录不了系统声音,收尾只核对了播放器会话"
    elif is_loud "$before_audio"; then
        echo "play-experiment: 开跑前就有声音($before_audio),收尾声音核对不作数:现在 $after_audio"
    elif is_loud "$after_audio"; then
        echo "play-experiment: !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "play-experiment: !! 收尾后扬声器还在出声($after_audio),开跑前是安静的($before_audio)。"
        echo "play-experiment: !! 有播放器没停下来,去看一眼屏幕。"
        echo "play-experiment: !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        rc=145
    else
        echo "play-experiment: 收尾声音核对:安静($after_audio)"
    fi
    if [ "$scrobble" = 0 ]; then
        # 开关收掉之前放的那几首在引擎里已经认成测试播放,收掉之后接着放也不记。
        /usr/bin/open -g "lyrimuse://debug/scrobble-hold?off=1&id=${hold_id}"
        echo "play-experiment: 收掉了测试期开关(id=${hold_id})"
    fi
    /usr/bin/python3 - "$LOG" "$started" <<'PY'
import re, sys
log, since = sys.argv[1], sys.argv[2]
rows = []
try:
    for line in open(log, encoding="utf-8", errors="replace"):
        m = re.match(r'time=(\S+) .*msg="(listen (?:recorded|skipped)[^"]*)"', line)
        if m and m.group(1)[:19] >= since:
            rows.append("  %s  %s" % (m.group(1)[:19], m.group(2)))
except OSError:
    pass
if rows:
    print("play-experiment: 这段时间引擎记下 / 跳过的收听 %d 条(UTC,skipped 是测试播放没记):" % len(rows))
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
