package main

import (
	"context"
	"math"
	"strings"
)

// 播放器只报了歌名、歌手为空的曲目,按「歌名 + 时长」认出是谁的哪一首。网易云云盘里没匹配到曲库的歌就是这样:
// 系统那份正在播放只有歌名和时长,网易云自己的本机曲库里也一样(见 03 章决策 32)。
//
// 认出来的歌手拿去找封面、拼链接,并跟专辑一起记进 inferred_artist / inferred_album 给 App 显示;不进缓存键,
// 也不进 fields()(中继和 ListenBrainz 的载荷),打卡照旧按播放器报的。
type inferredIdentity struct {
	artist string
	album  string
}

// inferredIdentityDurationTolerance:QQ 报的曲长跟播放器报的差多少秒以内才算同一首。
const inferredIdentityDurationTolerance = 2.0

// inferIdentityByTitle:QQ 按歌名搜(不带歌手),结果交给 pickInferredIdentity。歌名或时长不知道时不搜。
func inferIdentityByTitle(ctx context.Context, title string, durationSecs float64) (inferredIdentity, bool) {
	if strings.TrimSpace(title) == "" || durationSecs <= 0 {
		return inferredIdentity{}, false
	}
	items, _ := qqSearchSongs(ctx, qqSearchQueries("", title), title)
	return pickInferredIdentity(items, title, durationSecs)
}

// pickInferredIdentity:按 QQ 的排序取第一条过了歌名闸(lyricTitleAccepted)和版本闸(versionTagsMismatch)的结果,
// 它报了歌手、曲长跟播放器报的差不超过 inferredIdentityDurationTolerance 才认。这一条对不上就不认,别往下找:
// 同名同长的翻唱很多,分得开原唱的只有排序。也别改成认歌词胜出的那条:歌词打分偏向歌名一字不差的,原唱歌名
// 带合作者署名时胜出的是翻唱(见 03 章决策 32)。纯函数。
func pickInferredIdentity(items []qqSearchItem, title string, durationSecs float64) (inferredIdentity, bool) {
	for _, it := range items {
		if !lyricTitleAccepted(it.Name, title) || versionTagsMismatch(title, "", it.Name, it.Album) {
			continue
		}
		artist := strings.TrimSpace(it.Singer)
		if artist == "" || !inferredDurationMatches(it.Interval, durationSecs) {
			return inferredIdentity{}, false
		}
		return inferredIdentity{artist: artist, album: strings.TrimSpace(it.Album)}, true
	}
	return inferredIdentity{}, false
}

// inferredIdentityWorthBackfill:播放器没报歌手、歌名和时长都有、还没认出来,值得补一次外围去认(次数与间隔跟别的
// 外围补全共用 peripheralBackfillWindowOpen)。
func inferredIdentityWorthBackfill(e enrichEntry, artist, title string, durationSecs float64) bool {
	return artist == "" && strings.TrimSpace(title) != "" && durationSecs > 0 && e.InferredArtist == ""
}

func inferredDurationMatches(songSecs, playingSecs float64) bool {
	return songSecs > 0 && playingSecs > 0 && math.Abs(songSecs-playingSecs) <= inferredIdentityDurationTolerance
}
