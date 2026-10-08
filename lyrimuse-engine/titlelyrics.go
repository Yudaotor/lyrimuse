package main

import (
	"context"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// 标题反查的第四条路:按歌词搜(见 titleReverseLookup)。
//
// 前三条都拿名字当线索 —— 本地标题、本地专辑名、Apple 商店里的叫法。播放器报的歌名、专辑名都是它自己的意译,而商店
// 里只有原文名时三条都够不着,可这首的歌词往往已经在手上:播放器自带的那份,或者首轮哪个源按别的写法答出来的。拿其中几句去网易云按歌词搜
// (type=1006),在歌手对得上的结果里按时长挑。判据跟歌手泛搜那条相同:只看前 retryTitleFromLyricSearchMaxRank 条、
// bestAlbumTrackByDurationDetailed(2 秒容差,两首不同的歌一样近就弃权)。翻唱靠歌手、现场版和别的录音靠时长挡。
// 见 09 章决策 211。

// retryTitleFromLyricSearchMaxRank:按歌词搜回来、歌手对得上的结果只看前这么多条。
const retryTitleFromLyricSearchMaxRank = 5

// lyricSearchQueryMinLetters:拿去搜的那句至少要有这么多个字(只数字母 / 汉字 / 假名这类,不数空白和标点)。短句
// 在别的歌里也常见,搜出来全是不相干的。
const lyricSearchQueryMinLetters = 6

// lyricSearchQueryMax:最多拿几句去搜(每句一次请求)。
const lyricSearchQueryMax = 2

var (
	lyricSearchLineTags   = regexp.MustCompile(`\[[^\]]*\]`)
	lyricSearchInlineTags = regexp.MustCompile(`<\d+:\d+(?:[.:]\d+)?>`)
)

// lyricSearchQueries:从首轮歌词样本(lyricSamplesForStorefront)里挑去搜的句子:去掉时间标签和括号里的部分
// (多是和声、背景人声),跳过署名行(isCreditLine)和太短的句子,同一句只取一次,字多的在前,最多 lyricSearchQueryMax 句。
// 样本截在 300 个字,每份最后一句可能只剩半截,不用。纯函数。
func lyricSearchQueries(samples []string) []string {
	type line struct {
		text    string
		letters int
	}
	var lines []line
	seen := map[string]bool{}
	for _, sample := range samples {
		rows := strings.Split(sample, "\n")
		if len(rows) > 1 {
			rows = rows[:len(rows)-1]
		}
		for _, row := range rows {
			text := lyricSearchInlineTags.ReplaceAllString(lyricSearchLineTags.ReplaceAllString(row, ""), "")
			text = strings.Join(strings.Fields(stripParens(text)), " ")
			if text == "" || isCreditLine(text) {
				continue
			}
			n := countRunes(text, unicode.IsLetter)
			key := normLoose(text)
			if n < lyricSearchQueryMinLetters || seen[key] {
				continue
			}
			seen[key] = true
			lines = append(lines, line{text, n})
		}
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].letters > lines[j].letters })
	var out []string
	for _, l := range lines {
		if len(out) == lyricSearchQueryMax {
			break
		}
		out = append(out, l.text)
	}
	return out
}

// retryTitleFromLyricSearchDetailed:拿 lyricSearchQueries 挑出的句子依次去网易云按歌词搜,第一句就挑出来的为准;
// artist 是对上的那个署名(artists 里的一个)。网易云这一次没问成(限流、连不上)就不接着打下一句。
func retryTitleFromLyricSearchDetailed(ctx context.Context, artists, samples []string, durationSecs float64) (title, artist string, diff float64, ok bool) {
	if len(artists) == 0 || durationSecs <= 0 {
		return "", "", 0, false
	}
	for _, q := range lyricSearchQueries(samples) {
		songs, reqOK := neteaseSongSearch(ctx, neteaseSearchTypeLyric, 10, q)
		if !reqOK {
			return "", "", 0, false
		}
		tracks := topSearchRanked(neteaseSongsByArtist(songs, artists), retryTitleFromLyricSearchMaxRank)
		if t, d, found := bestAlbumTrackByDurationDetailed(tracks, durationSecs); found {
			for _, tr := range tracks {
				if tr.title == t {
					return t, tr.artist, d, true
				}
			}
		}
	}
	return "", "", 0, false
}
