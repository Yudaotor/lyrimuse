package main

import (
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"
)

// 纯空白的逐字词条不该独立存在(2026-08-19 用户报"有些单词没有读条直接填满"):
// Musixmatch richsync 把空格作为独立计时条目,空格占走了前一个词的绝大部分演唱时长
// (实测《Ocho Rios》"In" 23ms + 空格 165ms),悬浮窗按 23ms 填完一个词,观感就是
// "瞬间填满"。richsyncToYRC 已在源头归并(见 musixmatch.go);这里是对**存量**缓存的
// 一次性清洗 —— 空白词条自带的时间信息就在数据里,原地归并即可,不需要重新联网解析。
//
// 变换对任何源的 YRC 都无损:
//   - 只把空白词条的文本并入前一个词、并把前词时长**延到空白词条的终点**,不重算其它
//     任何词的时间(网易云词间的真实空隙保持原样 —— 那些空隙没有词条,不受影响);
//   - 行首就是空白词条的,文本并给下一个词当前缀,时间不动;
//   - 没有空白词条的行逐字节原样保留(netease/kugou/QQ 归一化产物本来就把空格并在
//     词文本里,整份不变)。
var yrcWordTokenRe = regexp.MustCompile(`\((\d+),(\d+),(\d+)\)`)

// yrcMergeWhitespaceTokens 返回清洗后的 YRC 与"是否真的改过"。
func yrcMergeWhitespaceTokens(yrc string) (string, bool) {
	if yrc == "" || !strings.Contains(yrc, ")") {
		return yrc, false
	}
	changed := false
	lines := strings.Split(yrc, "\n")
	for li, line := range lines {
		if !strings.HasPrefix(line, "[") || !strings.Contains(line, "(") {
			continue
		}
		locs := yrcWordTokenRe.FindAllStringSubmatchIndex(line, -1)
		if len(locs) == 0 {
			continue
		}
		type tok struct {
			start, dur int64
			flag       string
			text       string
		}
		head := line[:locs[0][0]] // "[行始,行长]" 行头原样保留
		toks := make([]tok, 0, len(locs))
		lineChanged := false
		prefix := ""
		for i, m := range locs {
			start, _ := strconv.ParseInt(line[m[2]:m[3]], 10, 64)
			dur, _ := strconv.ParseInt(line[m[4]:m[5]], 10, 64)
			flag := line[m[6]:m[7]]
			textEnd := len(line)
			if i+1 < len(locs) {
				textEnd = locs[i+1][0]
			}
			text := line[m[1]:textEnd]
			if text != "" && strings.TrimSpace(text) == "" {
				lineChanged = true
				if n := len(toks); n > 0 {
					toks[n-1].text += text
					if end := start + dur; end > toks[n-1].start+toks[n-1].dur {
						toks[n-1].dur = end - toks[n-1].start
					}
				} else {
					prefix += text
				}
				continue
			}
			toks = append(toks, tok{start, dur, flag, prefix + text})
			prefix = ""
		}
		if !lineChanged {
			continue
		}
		var b strings.Builder
		b.WriteString(head)
		for _, t := range toks {
			fmt.Fprintf(&b, "(%d,%d,%s)%s", t.start, t.dur, t.flag, t.text)
		}
		lines[li] = b.String()
		changed = true
	}
	if !changed {
		return yrc, false
	}
	return strings.Join(lines, "\n"), true
}

// migrateYRCWhitespaceTokens 对整个 enrich 缓存跑一遍 yrcMergeWhitespaceTokens。
// 调用时机(main.go):importLyricsFromFiles 之后、exportLyricsFiles 之前 —— 修的是
// 权威内容,修完由 export 写回导出文件。幂等:清洗过的内容不再含空白词条,重复跑是空操作。
func migrateYRCWhitespaceTokens() {
	enrichMu.Lock()
	fixed := 0
	for k, e := range enrichCache {
		merged, ok := yrcMergeWhitespaceTokens(e.LyricsYRC)
		if !ok {
			continue
		}
		e.LyricsYRC = merged
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 {
		// 必须显式置脏,否则 saveEnrichCache 是空操作 —— 同 migrateLyricTimelines 里
		// 那条 2026-09-01 实测坐实的潜伏 bug,这里是同一个形态。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 {
		log.Printf("yrc whitespace-token migration: merged space tokens in %d entries", fixed)
		saveEnrichCache()
	}
}
