package main

import (
	"hash/crc32"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"unicode"
)

// parenBGFileForms:parenBGFileForm 真的接回、核对过的条目数。全量导出结束时有就记一行日志。
var parenBGFileForms atomic.Int64

// parenBGFileForm:写进歌词文件夹的正文 / 逐字。从括号里拆出来的背景人声(bgparen.go)接回所属主句的行尾,写成「 (和声)」。
// 歌词文件里没有背景人声这一项,不接回去的话这段和声只在缓存里:清空后从文件恢复、换一台 Mac 读这个文件夹都会丢,
// 别的播放器读文件也看不到。这个写法拆分器认得,再拆一次跟缓存里一样(启动迁移会重拆)。导入比对文件时同样用它认出
// 「文件还是导出时那份」(lyricsimport.go),不然状态记录一作废,每首拆过的歌都会被当成文件改过。
// 只管 parenBGSources 的条目:AMLL / Apple 的背景人声不是从括号里来的。
func parenBGFileForm(source, lrc, yrc, bg string) (string, string) {
	if bg == "" || yrc == "" || !parenBGSources[source] {
		return lrc, yrc
	}
	parenBGFileForms.Add(1)
	bgByHead := map[string]string{}
	for _, l := range strings.Split(bg, "\n") {
		if head := yrcLineHeadFullRe.FindString(l); head != "" {
			if _, dup := bgByHead[head]; !dup {
				bgByHead[head] = l[len(head):]
			}
		}
	}
	type merged struct {
		start        int
		mainK, plain string
	}
	ylines := strings.Split(yrc, "\n")
	var recs []merged
	for i, l := range ylines {
		m := yrcLineHeadFullRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		words, ok := bgByHead[m[0]]
		if !ok {
			continue
		}
		delete(bgByHead, m[0])
		loc := yrcWordTokenRe.FindStringIndex(words)
		plain := strings.TrimSpace(yrcWordTokenRe.ReplaceAllString(words, ""))
		if loc == nil || loc[0] != 0 || plain == "" {
			continue
		}
		ylines[i] = l + words[:loc[1]] + " (" + strings.TrimLeftFunc(words[loc[1]:], unicode.IsSpace) + ")"
		start, _ := strconv.Atoi(m[1])
		recs = append(recs, merged{start: start, mainK: parenBGNormKey(yrcWordTokenRe.ReplaceAllString(l[len(m[0]):], "")), plain: plain})
	}
	if len(recs) == 0 {
		return lrc, yrc
	}
	// 逐行那边找回同一行:文字跟逐字主句相同、时间相差不超过 parenBGPairToleranceMs。两种配法各试一次 —— 按逐行的先后
	// 每个时间戳配最近的一行(拆分时的配法,splitParenBackground),或按背景人声的先后各配最近的一个时间戳;同一句短时间里
	// 唱好几遍时两种会配出不同的行。哪种接回去的拆得回缓存里那一份就用哪种,都不行就照旧写拆过的正文和逐字。
	type stamp struct {
		line, ms int
		key      string
	}
	llines := strings.Split(lrc, "\n")
	var stamps []stamp
	for i, l := range llines {
		ms, end := parenBGLRCStamps(l)
		key := parenBGNormKey(strings.TrimSpace(l[end:]))
		for _, t := range ms {
			stamps = append(stamps, stamp{line: i, ms: t, key: key})
		}
	}
	near := func(s stamp, r merged) bool {
		return s.key == r.mainK && parenBGAbs(r.start-s.ms) <= parenBGPairToleranceMs
	}
	attach := func(byLRC bool) string {
		usedRec, usedStamp := make([]bool, len(recs)), make([]bool, len(stamps))
		tail := map[int]string{}
		pair := func(si, ri int) {
			usedStamp[si], usedRec[ri] = true, true
			if _, ok := tail[stamps[si].line]; !ok {
				tail[stamps[si].line] = recs[ri].plain
			}
		}
		if byLRC {
			for si, s := range stamps {
				best := -1
				for ri, r := range recs {
					if !usedRec[ri] && near(s, r) && (best < 0 || parenBGAbs(r.start-s.ms) < parenBGAbs(recs[best].start-s.ms)) {
						best = ri
					}
				}
				if best >= 0 {
					pair(si, best)
				}
			}
		} else {
			for ri, r := range recs {
				best := -1
				for si, s := range stamps {
					if !usedStamp[si] && near(s, r) && (best < 0 || parenBGAbs(r.start-s.ms) < parenBGAbs(r.start-stamps[best].ms)) {
						best = si
					}
				}
				if best >= 0 {
					pair(best, ri)
				}
			}
		}
		out := slices.Clone(llines)
		for i, plain := range tail {
			out[i] = strings.TrimRightFunc(out[i], unicode.IsSpace) + " (" + plain + ")"
		}
		return strings.Join(out, "\n")
	}
	fileYRC := strings.Join(ylines, "\n")
	for _, byLRC := range []bool{true, false} {
		fileLRC := attach(byLRC)
		if sp, ok := splitParenBackground(fileLRC, fileYRC); ok && sp.lrc == lrc && sp.yrc == yrc && parenBGSameTrack(sp.bg, bg) {
			return fileLRC, fileYRC
		}
	}
	return lrc, yrc
}

// parenBGFileFormVersion:接回写法的版本,算进 parenBGFileSource。parenBGFileForm 或拆分规则改了、同样的缓存原文
// 会写出不一样的文件时加一,不然文件状态记录里旧的指纹还对得上,文件不会重写。
const parenBGFileFormVersion = 1

// parenBGFileSource:这份缓存原文(文件头、正文、逐字、背景人声)的指纹。不用接回去(没有背景人声、不是 parenBGSources)为 0。
func parenBGFileSource(header, source, lrc, yrc, bg string) uint32 {
	if bg == "" || yrc == "" || !parenBGSources[source] {
		return 0
	}
	c := crc32.ChecksumIEEE([]byte{parenBGFileFormVersion})
	for _, s := range []string{header, lrc, yrc, bg} {
		c = crc32.Update(c, crc32.IEEETable, []byte(s))
		c = crc32.Update(c, crc32.IEEETable, []byte{0})
	}
	if c == 0 {
		c = 1
	}
	return c
}

// parenBGSameTrack:两份背景人声轨的行一样(不管先后、空行):存量迁移并进来的按行头排过序,拆分出来的按逐字的行序。
func parenBGSameTrack(a, b string) bool {
	lines := func(s string) []string {
		var out []string
		for _, l := range strings.Split(s, "\n") {
			if strings.TrimSpace(l) != "" {
				out = append(out, l)
			}
		}
		sort.Strings(out)
		return out
	}
	return slices.Equal(lines(a), lines(b))
}
