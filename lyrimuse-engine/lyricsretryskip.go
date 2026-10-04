package main

import "strings"

// 自动补空扫描与全量扫库要跳过的空歌词条目。手动「重试无歌词条目」不受影响 —— 用户点了就是要现在搜。
//
// 不按「数据缺失」一刀切:缺时长、缺专辑、连歌手都缺的条目照样常能搜到(靠歌名命中),本机缓存里
// 缺字段的条目有歌词的远多于没歌词的。跳过的只有两类「再搜也不会有」的:
//   - 没歌手、没专辑,补空已经失败 lyricsNoAnchorGiveUpCount 次:没有任何可依据的信息(播客单集、
//     电台节目之类),第一次靠歌名搜不到,之后也不会;
//   - 结构上是播放器把歌词写进身份留下的污染(见 lyricsPollutedKeys)。

// lyricsNoAnchorGiveUpCount:没歌手没专辑的空条目,补空失败几次后自动路径不再碰。
const lyricsNoAnchorGiveUpCount = 3

// lyricsPollutedMinVariants:同一个身份字段下另一个字段至少出现几个不同值,才算污染。
const lyricsPollutedMinVariants = 3

// lyricsNoAnchorGaveUp:没歌手、没专辑,补空已经失败够次数了。
func lyricsNoAnchorGaveUp(key string, e enrichEntry) bool {
	artist, _, album := splitEnrichKey(key)
	return strings.TrimSpace(artist) == "" && strings.TrimSpace(album) == "" &&
		e.LyricsFillCount >= lyricsNoAnchorGiveUpCount
}

// lyricsPollutedKeys 找出结构上是「一个字段装身份、另一个字段放歌词」留下的空歌词条目:同一张专辑下,
// 某个字段完全一样、而且能按带空格的分隔符拆成两段(塞着「歌名 - 歌手」),另一个字段却出现了
// lyricsPollutedMinVariants 个以上不同的值。信任进来的其他播放器出这种毛病时(见 trustedlyricartist.go
// 头注),纠正上线之前每句歌词都落了一条。
//
// 只看「同一歌手同一专辑下有很多不同歌名」不行,那就是一张正常专辑;所以要求不变的那个字段带分隔符
// —— 正常数据里歌手名几乎不带空格破折号,带破折号的歌名在同一张专辑下也只对应一个歌手。
// 调用方必须持有 enrichMu。
func lyricsPollutedKeys(cache map[string]enrichEntry) map[string]bool {
	type group struct {
		variants map[string]bool
		keys     []string
	}
	byTitle := map[string]*group{}
	byArtist := map[string]*group{}
	add := func(m map[string]*group, gk, variant, key string, empty bool) {
		g := m[gk]
		if g == nil {
			g = &group{variants: map[string]bool{}}
			m[gk] = g
		}
		g.variants[variant] = true
		if empty {
			g.keys = append(g.keys, key)
		}
	}
	for key, e := range cache {
		artist, title, album := splitEnrichKey(key)
		empty := e.Lyrics == "" && !e.ManualLyrics && !e.Instrumental
		if len(trustedSplitCandidates(title)) > 0 {
			add(byTitle, title+"|"+album, artist, key, empty)
		}
		if len(trustedSplitCandidates(artist)) > 0 {
			add(byArtist, artist+"|"+album, title, key, empty)
		}
	}
	out := map[string]bool{}
	for _, m := range []map[string]*group{byTitle, byArtist} {
		for _, g := range m {
			if len(g.variants) < lyricsPollutedMinVariants {
				continue
			}
			for _, k := range g.keys {
				out[k] = true
			}
		}
	}
	return out
}
