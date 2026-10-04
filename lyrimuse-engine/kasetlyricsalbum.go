package main

import "context"

// 播放器没报专辑的歌(Kaset 放的),搜歌词、给候选打分拿 YouTube Music 登记的专辑当专辑:网易云在同名的几首里按专辑挑,
// 打分给专辑对得上的候选加分。登记专辑只进查询词和打分,不进缓存 key,也不写成 cover_album。见 09 章决策 170。

// lyricsSearchAlbum 返回搜歌词、给候选打分用的专辑,以及其中来自 YouTube Music 登记的那个(播放器报了专辑时为空,
// 记进 LyricsListedAlbum)。播放器报了专辑就用它;没报时用登记的专辑:listed 是条目里记着的(youtube_music_album),
// 空就按 ctx 上的 videoId 现判(判法见 kasetalbum.go,还没问齐是空)。
func lyricsSearchAlbum(ctx context.Context, album, listed string, durationSecs float64, artist, title string) (search, listedUsed string) {
	if album != "" {
		return album, ""
	}
	if listed == "" {
		listed = kasetListedAlbumFor(youTubeMusicVideoIDFrom(ctx), durationSecs, artist, title)
	}
	return listed, listed
}

// listedAlbumLyricsRechecked:这次进程里已经为登记专辑重搜过的条目。那一轮一个歌词源都没连上时不记 LyricsListedAlbum,
// 光靠 listedAlbumLyricsWorthRecheck 会每拍都再来一遍。只在 enrichMu 里读写。
var listedAlbumLyricsRechecked = map[string]bool{}

// listedAlbumLyricsRecheckOnce:这个条目这次进程里还没为登记专辑重搜过就记下、返回 true。调用方持有 enrichMu。
func listedAlbumLyricsRecheckOnce(key string) bool {
	if listedAlbumLyricsRechecked[key] {
		return false
	}
	listedAlbumLyricsRechecked[key] = true
	return true
}

// listedAlbumLyricsWorthRecheck:播放器没报专辑(album 是缓存 key 里的专辑)、YouTube Music 登记的专辑已经判出来,而这份词
// 最近一轮评估没带着它搜过(LyricsListedAlbum 对不上)→ 值得带着它重来一次(retryLyricsUpgrade,分数严格更高才换)。
// 首次解析多半赶在登记专辑判出来之前。没词的交给补空那条(它同样带登记专辑搜);手改过、校准过、关了自动升级的都不动。
func listedAlbumLyricsWorthRecheck(e enrichEntry, album string, pinned, autoUpgrade bool) bool {
	if album != "" || e.YouTubeMusicAlbum == "" || e.LyricsListedAlbum == e.YouTubeMusicAlbum {
		return false
	}
	return e.Lyrics != "" && !e.ManualLyrics && !pinned && autoUpgrade
}
