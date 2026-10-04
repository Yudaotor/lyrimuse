package main

import (
	"log"
	"strings"
)

// KKBOX 同一首歌的歌手有两种写法:列表里的 roles(「田馥甄」)与详情里带括号别名的 artist.name(「田馥甄 (Hebe)」),
// 播放器报哪种因专辑而异(见 kkboxqueue.go 头注)。队列预取只按一种写法解析;真播到时报的是另一种、缓存里没有这个
// key,就把只差这层括号别名的那条整份搬到播放的 key 下(kkboxAliasSiblingLocked),不再联网解析一遍。
//
// 只对 KKBOX 生效、只在精确 key 与宽松匹配(canonicalEnrichKey)都没命中时才找:别的播放器没有这种两套写法,
// 而全局放宽歌手匹配会把名字里本来就带括号的不同艺人认成一个。

// kkboxAliasVariant:两个歌手串是不是只差第一位歌手的括号别名(「田馥甄」对「田馥甄 (Hebe)」,其余逐字相同)。纯函数。
func kkboxAliasVariant(a, b string) bool {
	if a == b {
		return false
	}
	aFirst, aRest, _ := strings.Cut(a, ", ")
	bFirst, bRest, _ := strings.Cut(b, ", ")
	if aRest != bRest {
		return false
	}
	short, long := aFirst, bFirst
	if len(short) > len(long) {
		short, long = long, short
	}
	return short != "" && strings.HasPrefix(long, short+" (") && strings.HasSuffix(long, ")")
}

// kkboxAliasSiblingLocked:这首 KKBOX 在放的歌,缓存里有没有歌名、专辑都一样、歌手只差括号别名、而且有歌词的那条。
// **调用方必须持有 enrichMu**。
func kkboxAliasSiblingLocked(key, bundleID string) (string, bool) {
	if bundleID != kkboxBundleID {
		return "", false
	}
	artist, title, album := splitEnrichKey(key)
	if artist == "" || title == "" {
		return "", false
	}
	suffix := "|" + title + "|" + album
	for k, e := range enrichCache {
		if !strings.HasSuffix(k, suffix) || strings.TrimSpace(e.Lyrics) == "" {
			continue
		}
		if kkboxAliasVariant(strings.TrimSuffix(k, suffix), artist) {
			return k, true
		}
	}
	return "", false
}

// kkboxAliasCopyLocked:把 sib 那条整份搬到 key 下。当前歌词的出处改记成复用(path artist-alias-reuse、
// reused_from = sib),跟跨专辑复用同一种标法。**调用方必须持有 enrichMu**,落盘 / 导出 / 通知由调用方在解锁后做。
func kkboxAliasCopyLocked(key, sib string) enrichEntry {
	e := enrichCache[sib]
	if e.LyricsDecisionApplied != nil {
		d := *withDecisionDetails(sib, e.LyricsDecisionApplied)
		d.Path = lyricsDecisionPathArtistAliasReuse
		d.ReusedFrom = sib
		e.LyricsDecisionApplied = &d
		e.LyricsDecision = &d
	}
	enrichCache[key] = e
	enrichDirty = true
	log.Printf("enrich: %q reusing %q (KKBOX artist alias spelling)", key, sib)
	return e
}
