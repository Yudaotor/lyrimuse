package main

// adoptBackfilledLyrics:补外围字段那一轮(backfillPeripheralFields)内部跑的是完整的 resolveTrackEnrichment,
// 歌词也搜了一遍。条目原本一条歌词都没有时,把搜到的收下 —— 跟补空路径(needsLyricsFirstFill)要做的
// 是同一件事,不收就得等补空的 24 小时退避。条目已经有歌词、被手改过、确证纯音乐,或者这一轮也没选出
// 歌词,一律不动,返回 false。
//
// 收下的字段跟 resolveTrackEnrichment 选中歌词时写的那一组一致(正文 / 来源 / 分数与打分版本 / 译文、
// 罗马音、逐字时间轴 / 语种 / 解析时长 / 决策存档两槽 / 本轮各源到场情况)。PlainLyrics 不动:有了带时间戳
// 的正文,纯文本兜底本来就不显示。调用方持 enrichMu,并已核对这期间条目没被改过。
func adoptBackfilledLyrics(e *enrichEntry, fresh enrichEntry) bool {
	if e.Lyrics != "" || e.ManualLyrics || e.Instrumental || fresh.Lyrics == "" {
		return false
	}
	e.Lyrics = fresh.Lyrics
	e.LyricsSource = fresh.LyricsSource
	e.LyricsScore = fresh.LyricsScore
	e.LyricsScoringVersion = fresh.LyricsScoringVersion
	e.ResolvedDurationSecs = fresh.ResolvedDurationSecs
	e.LyricsTr, e.LyricsRoma, e.LyricsYRC = fresh.LyricsTr, fresh.LyricsRoma, fresh.LyricsYRC
	e.LyricsTrLang, e.LyricsTrSource = fresh.LyricsTrLang, fresh.LyricsTrSource
	e.SongLanguage = fresh.SongLanguage
	e.LyricsDecision = fresh.LyricsDecision
	e.LyricsDecisionApplied = fresh.LyricsDecisionApplied
	e.LyricsSourcesSeen = fresh.LyricsSourcesSeen
	e.LyricsSourcesResponded = fresh.LyricsSourcesResponded
	e.LyricsSourcesSkipped = fresh.LyricsSourcesSkipped
	return true
}
