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
//
// 缓存里存**两槽**(2026-08-22 分槽,三条铁律对两槽同样生效):
//   - lyrics_decision:最近一次评估 —— 可能维持原状,甚至输入本身是脏的(换曲窗口的
//     串扰时长,见 observeWrongDuration);
//   - lyrics_decision_applied:当前歌词的出处 —— 最近一次"胜者内容成为(或确认仍是)
//     当前歌词"的评估。
//
// 分槽的直接起因:一轮脏输入的 upgrade 评估把 first-resolve 的存档盖掉,「解析决策」
// 弹窗展示的记录跟生效歌词对不上号,用户拿它跟手动重搜一比更懵。字段注释见
// enrichEntry.LyricsDecisionApplied。
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
	// 这一轮因源级熔断被**跳过**(压根没发请求)的源,见 sourcebreaker.go——跟"超时没露面"
	// 又是另一回事:这是我们主动不问它。由三处写缓存点在 buildLyricsDecision 之后填。
	SourcesSkipped []string `json:"sources_skipped,omitempty"`
	// 胜者的源名;空 = 这一轮没选出任何可用候选。
	Winner string `json:"winner,omitempty"`
	// 这次评估的结果有没有真的落到 Lyrics 字段上。upgrade/rescore 评估完维持现状时是
	// false —— 此时这份记录的含义是"最近一次完整评估的证据",不是"当前歌词的出处"。
	Applied bool `json:"applied"`
	// 全部候选(含被判负分的),按 scoredLyricCandidates 的排序原样保留。
	Candidates []lyricsDecisionCandidate `json:"candidates,omitempty"`
	// RetryMethod/CorrectedTitle:**胜者**是不是"标题反查改写标题之后"那一轮搜出来的,
	// 以及改写成了什么。两者都空 = 胜者来自按本地标题的正常那一轮(绝大多数情况)。
	//
	// 2026-09-02 加。起因是一次事后无法审计的错配(打上花火被反查成《春雷》):存档里
	// 只有 winner/candidates 时,想知道"库里还有多少条是走这条高风险路径来的"完全无从
	// 下手——光看标题分不出对错,Uchiagehanabi→春雷(错)和 Black Hole→黑洞里(对)在
	// 标题层面是同一个形状。这两个字段把"走没走那条路径"变成可 grep 的事实。
	//
	// ⚠️ 仍然服从头注那条"只写不读"铁律:解析逻辑不许拿它当输入。
	RetryMethod    string `json:"retry_method,omitempty"`
	CorrectedTitle string `json:"corrected_title,omitempty"`
}

// 一条候选的元数据 —— 字段跟 scoredLyricCandidateResult 一一对应,唯独**没有歌词正文**。
type lyricsDecisionCandidate struct {
	Source string `json:"source"`
	Score  int    `json:"score"`
	// 分数构成明细(或被判负分时的那条 reject 原因),kind 词汇表见 match.go 的 scoreTerm。
	ScoreTerms []scoreTerm `json:"score_terms,omitempty"`
	// 这个源实际匹配到的是哪首歌/哪个版本 —— 复盘"选错版本"类问题的关键字段。
	Title  string `json:"title,omitempty"`
	Artist string `json:"artist,omitempty"`
	Album  string `json:"album,omitempty"`
	// CoverURL:这个源当时给出的封面(2026-09-01 加,用户要求决策面板把封面也显示出来)。
	// 跟 Title/Artist/Album 同一个用途 —— 判断"这个源匹配到的是不是同一个版本",而封面
	// 往往比专辑名更一眼看得出来(现场版/精选集/单曲封面差别很直观)。
	//
	// 2026-09-01 实测(search-lyrics 真查一次《Shall We Dance (Live)》):网易云/酷狗/QQ/
	// LRCLIB **四个源都给得出**封面(LRCLIB 那条是 iTunes 的 mzstatic 图),连被判 -1 的
	// 候选也有。不过仍然当"可能为空"处理 —— 某个源某次没查到是正常的。
	// 存档里的 URL 还可能随时间失效 —— App 侧按"取不到就当没有"处理。
	//
	// ⚠️ 存量存档里没有这个字段,老的决策记录一律显示不出封面,这是预期行为(存档是
	// "当时那一刻的固化",不能事后补 —— 现在再去查一次封面,拿到的不是当时那个)。
	CoverURL                   string  `json:"cover_url,omitempty"`
	SourceReportedDurationSecs float64 `json:"source_reported_duration_secs,omitempty"`
	HasWordTiming              bool    `json:"has_word_timing,omitempty"`
	Instrumental               bool    `json:"instrumental,omitempty"`
	// BakedTranslationLines:见 scoredLyricCandidateResult 同名字段(2026-09-04)。
	BakedTranslationLines int `json:"baked_translation_lines,omitempty"`
}

// buildLyricsDecision 把一轮完整评估固化成决策记录。picked 传 nil 表示没选出;
// applied 表示这次评估的胜者有没有真的写进缓存(见 lyricsDecision.Applied)。
// 决策存档的 path 取值全集。
//
// ⚠️ 新增一条**必须同时**在 App 侧 LyricsDecisionSheet.pathLabel 那个 switch 里补中文译名 ——
// 那边 default 分支是"原样显示原始值",漏了就是界面上直接印一个英文串给用户看。2026-08-21
// 加 manual-rematch 时就这么漏过一次(用户截图反馈「这里的文案是否没做好中文的」)。
// lyricsDecisionPaths 那个测试守着这份清单,改了要一起改。
const (
	lyricsDecisionPathFirstResolve  = "first-resolve"  // 首次解析
	lyricsDecisionPathUpgrade       = "upgrade"        // 升级重试(本来有、想换更好的)
	lyricsDecisionPathRefill        = "refill"         // 补搜缺失歌词(本来一条都没搜到)
	lyricsDecisionPathRescore       = "rescore"        // 规则换版重选
	lyricsDecisionPathManualRematch = "manual-rematch" // 用户点「重新自动匹配」那一次
)

// lyricsDecisionPaths 是上面那五条的清单,给测试用(见 lyricsdecisionpath_test.go)。
func lyricsDecisionPaths() []string {
	return []string{
		lyricsDecisionPathFirstResolve,
		lyricsDecisionPathUpgrade,
		lyricsDecisionPathRefill,
		lyricsDecisionPathRescore,
		lyricsDecisionPathManualRematch,
	}
}

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
		// 只记**胜者**那条的来路:候选里混着两轮的结果,记"这一批里有人走过反查"没有意义,
		// 要回答的问题是"当前这份歌词是不是那么来的"。
		d.RetryMethod, d.CorrectedTitle = picked.RetryMethod, picked.RetriedTitle
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
			CoverURL:                   c.CoverURL,
			SourceReportedDurationSecs: c.SourceReportedDurationSecs,
			HasWordTiming:              c.HasWordTiming,
			Instrumental:               c.Instrumental,
			BakedTranslationLines:      c.BakedTranslationLines,
		})
	}
	return d
}
