package main

import (
	"log"
	"math"
	"strings"
)

// 同一段录音收在多张专辑下时,让它们用同一份歌词。
//
// # 问题
//
// enrich 缓存 key 是 `artist|title|album`(enrichKey),**专辑是身份的一部分**。同一段录音
// 收在原版专辑和 Deluxe / Bonus Version / Video Album 里,就是两条独立条目,各跑一遍全源
// 检索、各自选源。两次用的是同一套打分,但候选集合受当次网络、源冷却、专辑名参与的匹配分
// 影响,结果并不保证一致。用户可见的症状是「从不同专辑进去播同一首歌,歌词会变、可能变差」。
//
// # 判据为什么是时长,而且是绝对秒数
//
// 专辑名规则(认 Deluxe / Remaster 这类后缀)认不出「世纪典藏【绝赞版】」「HIStory
// Continues」这类再版名,本机两例都真实存在。时长是纯数值判据,没有这个问题。
//
// **别复用 durationMismatch 的 12%**。那把尺子是给**拆分**方向用的(防止版本词漏词把
// 两个录音合成一条,见 splitByDuration / resolveEnrichKeyForDuration),误拆的代价只是多一
// 条缓存,所以宽松是对的;这里是**合并**方向,误合并会把另一段录音的歌词套上去,必须严得多
// —— 12% 对一首 4 分钟的歌是 28.8 秒,足够放进一个完全不同的版本。
//
// 本机全量数据把分界线量得很干净:同一段录音被读数抖动/取整拆开的那批,时长差最大
// 1.85 秒;确实是不同版本、只是碰巧共用同一份歌词文本的那批,最小差 2.1 秒(再往上是
// 4.0 / 6.5 / 10.7 / 23.1 / 66.5 秒)。两组之间没有重叠。
const crossAlbumReuseToleranceSecs = 2.0

// crossAlbumSiblingLyrics 在缓存里找「同一段录音、收在另一张专辑下」的兄弟条目,返回它的
// key;没有合适的就返回空串。**调用方必须持有 enrichMu。**
//
// 兄弟的判据:同一种写法(sameEnrichWriting)、album 不同、两边时长都已知且差在容差内;两边都已经分到同一首歌的实体时
// 要是同一个实体(实体按 ISRC 等证据拆开的原版和重制版时长常常只差一两秒)。
//
// 只返回**歌词评分比 self 高**的那条 —— 跟存量合并命令 `cross-album-reuse -apply` 用的是
// 同一条「评分高的赢」规则,两处结论保持一致。同分不动:同分说明两份都站得住,这时换一份
// 只会让用户觉得歌词莫名其妙变了。只跟**同一打分版本**的兄弟比:不同版本的分数不在一把尺子上
// (早期版本普遍多算几百分),拿旧版本的虚高分换掉新解析的词,还会让这条顶着新版本号再也不被重排。
func crossAlbumSiblingLyrics(cache map[string]enrichEntry, key string, self enrichEntry) string {
	if self.DurationSecs <= 0 {
		return ""
	}
	artist, title, album := splitEnrichKey(key)
	if artist == "" || title == "" {
		return ""
	}
	best, bestScore := "", self.LyricsScore
	// 正文可能退回在小文件里(bodytext.go):先用元数据筛,最后才取正文,别让每次都把全库正文读一遍。
	for k, e := range cache {
		// 标了纯音乐的兄弟,词还留在条目里、分数照旧(重评判出「这份是别的版本的」时也这样标),不搬。
		if k == key || e.Lyrics.IsZero() || e.DurationSecs <= 0 || e.Instrumental {
			continue
		}
		if e.LyricsScore <= bestScore || e.lyricsScoring() != self.lyricsScoring() {
			continue
		}
		if math.Abs(e.DurationSecs-self.DurationSecs) > crossAlbumReuseToleranceSecs || !crossAlbumSameRecording(self, e) {
			continue
		}
		a, t, al := splitEnrichKey(k)
		if !sameEnrichWriting(a, t, artist, title) || loosenEnrichKey(al) == loosenEnrichKey(album) {
			continue
		}
		if strings.TrimSpace(e.Lyrics.String()) == "" {
			continue
		}
		best, bestScore = k, e.LyricsScore
	}
	return best
}

// sameEnrichWriting:两条写法的歌手、歌名是不是同一种写法。按宽松比对(loosenEnrichKey:繁简、大小写、空格、多歌手分隔符),
// 跟 canonicalEnrichKey 认重复条目同一层:enrich key 保留原样,同一位歌手在不同专辑、不同播放器下常有全大写和首字母大写、
// 「&」和「/」两种写法。跨专辑复用、同曲共享组的写法族边(familyEdges)、cross-album-reuse 归组三处共用。见 09 章决策 305。
func sameEnrichWriting(artistA, titleA, artistB, titleB string) bool {
	return enrichWritingKey(artistA, titleA) == enrichWritingKey(artistB, titleB)
}

// enrichWritingKey:sameEnrichWriting 比的那个键,按它归组用。
func enrichWritingKey(artist, title string) string {
	return loosenEnrichKey(artist + "|" + title)
}

// crossAlbumSameRecording:两条写法可能是同一段录音 —— 有一边还没分到实体,或者两边是同一个实体。
func crossAlbumSameRecording(a, b enrichEntry) bool {
	return a.Song == "" || b.Song == "" || a.Song == b.Song
}

// adoptCrossAlbumSiblingLyrics 在写入一条记录之前,把它对齐到评分更高的跨专辑兄弟上。
// 改了返回 true。**调用方必须持有 enrichMu。**
//
// 只搬歌词族字段;封面 / 强调色 / 各家链接**不搬** —— 那些是专辑维度的,同一段录音在原版和
// Deluxe 下本来就该有各自的封面。
//
// 两类条目一律不碰,它们代表用户已经表过态:ManualLyrics(在「歌词管理」里手改过正文,
// 那个标记的本意就是不许机器覆盖)、ManualPickSHA(手动选过源 —— 他选的可能恰好是评分较低
// 的那份,「评分高的赢」会把这个选择静默抹掉)。
//
// **这条只做单向**:新写入的条目会对齐到更好的兄弟,但**不会反过来去改兄弟**。反向写要动
// 另一个 key,而那条可能正被展示面读着;而且一次写入触发多条记录变更,出错时很难追。代价是
// 「这次解析结果比兄弟更好」时两条仍然不一致 —— 那一类由存量命令
// `cross-album-reuse -apply` 定期对齐,分工写在 09 章。
func adoptCrossAlbumSiblingLyrics(key string, e *enrichEntry) bool {
	if e == nil || strings.TrimSpace(e.Lyrics.String()) == "" {
		return false
	}
	if e.ManualLyrics || e.ManualPickSHA != "" {
		return false
	}
	sib := crossAlbumSiblingLyrics(enrichCache, key, *e)
	if sib == "" {
		return false
	}
	src := enrichCache[sib]
	if src.Lyrics.Equal(e.Lyrics) {
		return false
	}
	log.Printf("enrich: %q adopting lyrics from %q (cross-album, score %d -> %d)",
		key, sib, e.LyricsScore, src.LyricsScore)
	e.Lyrics = src.Lyrics
	e.LyricsYRC = src.LyricsYRC
	e.LyricsBG, e.LyricsBGChecked = src.LyricsBG, src.LyricsBGChecked
	e.LyricsSpeakers, e.LyricsSpeakersChecked = src.LyricsSpeakers, src.LyricsSpeakersChecked
	e.LyricsKana, e.LyricsKanaChecked, e.LyricsKanaRomaFor = src.LyricsKana, src.LyricsKanaChecked, src.LyricsKanaRomaFor
	e.LyricsTr = src.LyricsTr
	e.LyricsTrSource = src.LyricsTrSource
	e.LyricsTrLang = src.LyricsTrLang
	e.resetTranslationAttempts()
	e.LyricsRoma = src.LyricsRoma
	e.LyricsSource = src.LyricsSource
	e.LyricsScore = src.LyricsScore
	if len(e.LyricsSongwriters) == 0 {
		e.LyricsSongwriters = src.LyricsSongwriters
	}
	// 当前歌词的出处现在确实是兄弟那一轮的决策,整份搬过来再标明复用来源;
	// lyrics_decision(最近一次评估)保持不动 —— 那记的是这条自己评估过什么,是事实。
	if src.LyricsDecisionApplied != nil {
		// 搬过来要改 path / reused_from,指纹一变就对不上兄弟的旁路文件 —— 先把明细补回来(decisionstore.go)。
		d := *withDecisionDetails(sib, src.LyricsDecisionApplied)
		d.Path = lyricsDecisionPathCrossAlbumReuse
		d.ReusedFrom = sib
		e.LyricsDecisionApplied = &d
	} else {
		// 兄弟那条没有决策记录:自己那份旧的已经描述不了现在的正文,换成只标明复用来源的最小记录(见 crossalbumcli.go 同一处)。
		e.LyricsDecisionApplied = &lyricsDecision{Path: lyricsDecisionPathCrossAlbumReuse, ReusedFrom: sib}
	}
	return true
}
