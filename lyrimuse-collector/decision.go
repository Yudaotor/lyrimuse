package main

import "time"

// 歌词解析的**决策记录**(2026-08-17 加,吸收自对 lyra 的对比审阅 C2/C3)。
//
// 背景:歌词缓存"解析一次永久保留",而选中哪个源有相当大的运气成分(20 秒总上限内哪些源
// 赶上了这一轮,见 enrichEntry.LyricsScore 的注释)。此前缓存里只存胜者的总分,事后想知道
// "为什么是这个源"只能靠「歌词管理」重新联网搜一遍 —— 而重搜是**另一轮抽签**,合法地
// 给出另一组候选(2026-08-07 实锤:popup 显示 qq 482 赢,实际当时是 Musixmatch 962 赢,
// 差别在决策时手里有时长、重搜时没有)。当时的修补是把 duration_secs 存下来,堵了一个
// 输入差异;这里把**决策本身**存下来,堵掉整类问题:哪些源应答了、各自得了多少分、
// 为什么被拒,几个月后离线也能一字不差地复盘。
//
// ⚠️ 三条铁律:
//  1. **只存元数据,绝不存歌词正文** —— 每条候选 ~200-400 字节,全缓存也就 ~0.3MB;
//     带上正文就是把缓存文件翻倍。
//  2. **只写不读** —— 解析逻辑的任何分支都不许读这个字段拿它当输入,否则"记录行为"
//     变成"影响行为",复盘价值就没了(lyra 用 result-unchanged 断言守同一条线)。
//  3. 手动改过的条目(ManualLyrics)不更新 —— 三个写入站点本来就对 ManualLyrics 早退,
//     人工覆盖之前那份自动决策的记录就地保留,说明"自动选出来的曾经是什么"。
type lyricsDecision struct {
	// Path:这份记录来自哪条决策路径 —— "first-resolve"(首次解析)/"upgrade"(升级重试)/
	// "rescore"(打分规则换版后重选)。
	Path      string `json:"path"`
	DecidedAt int64  `json:"decided_at"`
	// 当时用的打分规则版本(lyricsScoringVersion)。跨版本对比 score 没有意义,先看它。
	ScoringVersion int `json:"scoring_version"`
	// 实际发给各源的查询词(已 toSimplified)和校验用的曲长 —— 决策的完整输入。
	QueryArtist  string  `json:"query_artist,omitempty"`
	QueryTitle   string  `json:"query_title,omitempty"`
	QueryAlbum   string  `json:"query_album,omitempty"`
	DurationSecs float64 `json:"duration_secs,omitempty"`
	// 这一轮**应答过**的源(哪怕给的候选被判负分也算)。跟 LyricsSourcesSeen(只算给出
	// 可用候选的)的区别正是排查的第一问:酷狗是超时没露面,还是回了份烂候选?
	// 两回事,两种修法(lyra 的 trace 把 no response / found-but-REJECT 分开报,同一个理由)。
	SourcesResponded []string `json:"sources_responded,omitempty"`
	// 胜者的源名;空 = 这一轮没选出任何可用候选。
	Winner string `json:"winner,omitempty"`
	// 这次评估的结果有没有真的落到 Lyrics 字段上。upgrade/rescore 评估完维持现状时是
	// false —— 此时这份记录的含义是"最近一次完整评估的证据",不是"当前歌词的出处"。
	Applied bool `json:"applied"`
	// 全部候选(含被判负分的),按 scoredLyricCandidates 的排序原样保留。
	Candidates []lyricsDecisionCandidate `json:"candidates,omitempty"`
}

// 一条候选的元数据 —— 字段跟 scoredLyricCandidateResult 一一对应,唯独**没有歌词正文**。
type lyricsDecisionCandidate struct {
	Source string `json:"source"`
	Score  int    `json:"score"`
	// 分数构成明细(或被判负分时的那条 reject 原因),kind 词汇表见 match.go 的 scoreTerm。
	ScoreTerms []scoreTerm `json:"score_terms,omitempty"`
	// 这个源实际匹配到的是哪首歌/哪个版本 —— 复盘"选错版本"类问题的关键字段。
	Title                      string  `json:"title,omitempty"`
	Artist                     string  `json:"artist,omitempty"`
	Album                      string  `json:"album,omitempty"`
	SourceReportedDurationSecs float64 `json:"source_reported_duration_secs,omitempty"`
	HasWordTiming              bool    `json:"has_word_timing,omitempty"`
	Instrumental               bool    `json:"instrumental,omitempty"`
}

// buildLyricsDecision 把一轮完整评估固化成决策记录。picked 传 nil 表示没选出;
// applied 表示这次评估的胜者有没有真的写进缓存(见 lyricsDecision.Applied)。
func buildLyricsDecision(
	path, artist, title, album string, durationSecs float64,
	scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult, applied bool,
) *lyricsDecision {
	d := &lyricsDecision{
		Path:             path,
		DecidedAt:        time.Now().Unix(),
		ScoringVersion:   lyricsScoringVersion,
		QueryArtist:      artist,
		QueryTitle:       title,
		QueryAlbum:       album,
		DurationSecs:     durationSecs,
		SourcesResponded: lyricSourcesResponded(scored),
		Applied:          applied,
		Candidates:       make([]lyricsDecisionCandidate, 0, len(scored)),
	}
	if picked != nil {
		d.Winner = picked.Source
	}
	for i := range scored {
		c := &scored[i]
		d.Candidates = append(d.Candidates, lyricsDecisionCandidate{
			Source:                     c.Source,
			Score:                      c.Score,
			ScoreTerms:                 c.ScoreTerms,
			Title:                      c.Title,
			Artist:                     c.Artist,
			Album:                      c.Album,
			SourceReportedDurationSecs: c.SourceReportedDurationSecs,
			HasWordTiming:              c.HasWordTiming,
			Instrumental:               c.Instrumental,
		})
	}
	return d
}
