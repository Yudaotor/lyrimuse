// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"math"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// lrclibLyric 是网易云/QQ 音乐都没能给出逐行歌词时的第三档兜底。LRCLIB(lrclib.net)
// 是免费、无需 key 的开源逐行 LRC 歌词库，对网易云/QQ 音乐这类中文平台曲库覆盖偏弱的
// 欧美/R&B 等曲目往往有收录。只缓存"拿到有效逐行歌词"或"确认是纯音乐"的结果，跟
// qqLyric 的缓存策略一致(单纯的查无此歌/网络失败不缓存,留给下次 enrich 重试)。
// lrclibResult.title/artist/album 是 LRCLIB 收录的这首歌的 trackName/artistName/
// albumName——纯粹给"搜索候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自 /api/get
// 响应本身(本来就已经查到,只是原来只挑了 syncedLyrics 就把其余字段丢了)。LRCLIB 的
// API 没有封面图字段,这个来源永远给不出封面,不是没查、是压根不存在。
//
// instrumental 是 LRCLIB 自己标注的"这首歌是纯音乐"——补上:这个字段
// 原来读出来就直接丢了(instrumental==true 时跟"这个源压根没查到"返回同一个空结构体
// 处理),下游"啥都没有"的空状态因此永远只有一种,用户分不清"是真没找到歌词"还是
// "这首歌本来就没有歌词"。见 fetchScoredLyricCandidatesStreaming 里怎么把这个信号
// 一路传到 enrichEntry.Instrumental。
type lrclibResult struct {
	lyrics, title, artist, album string
	// yrc / roma:条目 lyricsfile 里的逐字时间转成的 YRC、逐行罗马音(lrclibItemExtras),没有时为空。只跟带时间轴的
	// lyrics 一起出现;lyricsfile 带假名读音时 lyrics 前面还拼了一行 `[kana:…]`(attachKanaLine)。
	yrc, roma string
	// durationSecs:LRCLIB 自报的这首歌时长(秒),0=没给。透传用,见 lyricCandidate 同名字段。
	durationSecs float64
	instrumental bool
	// plainOnly:"只有纯文本歌词,没有带时间戳的版本"这个结论——LRCLIB 有时精确命中、
	// 内容和时长都对得上,但库里只有 plainLyrics、没有 syncedLyrics(常见于网易云/QQ
	// 搜索接口把标题里的敏感词过滤掉、返回空结果的歌,如海龟先生《Porn Star》)。这种
	// 情况不整个丢弃判定"没查到":纯文本也比什么都没有强(见"歌词窗口"的纯文本静态
	// 展示、"搜索候选歌词"弹窗的"无时间戳"标签)。
	// true 时 lyrics 装的是**纯文本**(没有 [mm:ss] 前缀),不是 isTimedLRC 判定链路能吃的
	// 东西——调用方(match.go 的 scoreLyricCandidateDetailed)看到这个标记要绕开"不是带
	// 时间戳的歌词就判废"那条闸,改判一个专门的、明确写着"仅纯文本"的理由,但**分数依旧
	// 钉死在 -1**——绝不能让它被 pickLyricCandidate/自动路径当成可用候选选中,只有"搜索
	// 候选歌词"弹窗里用户自己明确点选"采用此候选"才能用它。
	plainOnly bool
}

var (
	lrclibMu    sync.Mutex
	lrclibCache = map[string]lrclibResult{} // artist|title|album -> result
)

func lrclibLyric(ctx context.Context, artist, title, album string, durationSecs float64) lrclibResult {
	if title == "" {
		return lrclibResult{}
	}
	// 缓存键仍然只用 artist|title|album——durationSecs 只影响 /api/search 那一级挑哪个
	// 候选,不构成曲目身份;把它并进键里只会让同一首歌因为时长读数的微小抖动反复穿透缓存。
	key := artist + "|" + title + "|" + album
	lrclibMu.Lock()
	if v, ok := lrclibCache[key]; ok {
		lrclibMu.Unlock()
		return v
	}
	lrclibMu.Unlock()

	r := resolveLRCLIBLyricForms(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" || r.instrumental {
		lrclibMu.Lock()
		lrclibCache[key] = r
		lrclibMu.Unlock()
	}
	return r
}

// resolveLRCLIBLyricForms:查询词被 searchQueryFields 改过写法(繁体转简体)时,先按原样写法(searchQueryOriginalFrom)
// 走完整三级,没拿到带时间轴、时长对得上的,再按归一后的写法查一遍(不带专辑的 get + search),两份取好的那份,
// 同样好时原样写法优先。LRCLIB 是各地用户上传的,繁体与日文汉字的歌按哪种写法收录的都有,只按简体查会漏,
// 见 09 章决策 137。
func resolveLRCLIBLyricForms(ctx context.Context, artist, title, album string, durationSecs float64) lrclibResult {
	oa, ot, oal, ok := searchQueryOriginalFrom(ctx)
	if !ok {
		return resolveLRCLIBLyric(ctx, artist, title, album, durationSecs)
	}
	first := resolveLRCLIBLyric(ctx, oa, ot, oal, durationSecs)
	if lrclibResultRank(first, durationSecs) == lrclibRankSettled || (oa == artist && ot == title) {
		return first
	}
	second := resolveLRCLIBLyric(ctx, artist, title, "", durationSecs)
	if lrclibResultRank(second, durationSecs) > lrclibResultRank(first, durationSecs) {
		return second
	}
	return first
}

// lrclibResultRank 给 resolveLRCLIBLyric 的结果排个高低:带时间轴且时长对得上(或明说纯音乐)> 带时间轴 > 纯文本 > 没有。
func lrclibResultRank(r lrclibResult, durationSecs float64) int {
	switch {
	case r.instrumental || (r.lyrics != "" && !r.plainOnly && sourceDurationFits(durationSecs, r.durationSecs)):
		return lrclibRankSettled
	case r.lyrics != "" && !r.plainOnly:
		return 2
	case r.lyrics != "":
		return 1
	}
	return 0
}

const lrclibRankSettled = 3

// resolveLRCLIBLyric 三级降级,越往后越宽松,一级失败才试下一级(比"整源判没收录"更宽松)。
//
// 两级 get 都带 duration(lrclibDurationParam):服务端只认时长在 ±2 秒内的记录。不带时它按名字
// 取最早入库的那一条(ORDER BY id),常是旧的纯文本条目或别的版本,见 09 章决策 137。
//
// ① /api/get 带 album_name(原有行为,最严)
// ② /api/get 去掉 album_name —— album_name 是参与
//
//	匹配的,传一个 LRCLIB 那边没有的专辑名会直接 404,哪怕这首歌其实收录了。同一首
//	Michael Jackson - Blue Gangsta:album_name=XSCAPE → 200、=XSCAPE (Deluxe) → 200
//	(它库里恰好两条都有)、=一个瞎写的专辑名 → **404**、完全不传 → 200。而 Music.app
//	的专辑标签跟 LRCLIB 的写法经常对不上(本地化名、(Deluxe Edition) vs (Deluxe)、
//	大小写),所以这一级是纯赚:仍然是 artist+track 精确匹配,没有任何"挑候选"的风险。
//
// ③ /api/search 模糊检索 + 严格挑选 —— 覆盖曲名本身对不上的情况(Apple Music 标签常带
//
//	feat./remaster 后缀而 LRCLIB 是干净曲名)。这一级必须挑,而且**绝不能盲取第一条**:
//	实测搜 "Blue Gangsta (Original Version)" 返回的第一个候选 duration=4.0 秒,是明显的
//	垃圾数据。挑选规则见 pickLRCLIBSearchResult。
//
// 超时预算:8s + 5s + 5s = 最坏 18s,卡在 enrich 的 20s 搜索截止之内并留一点余量。
//
// 这个截止是**硬**的,不是软的:enrich.go 的 collect 循环 `case <-deadline: break collect`
// 之后就不再读 resultsCh、也不再调 onUpdate,晚到的结果整轮丢弃。所以三级串行的总预算必须
// 塞进 20s 里——超出去等于这一源白跑,前两级的收益也一起没了。(第一级从 10s 收到 8s 是为了
// 给后两级腾时间;lrclib.net 慢,但 8s 仍然远超它的正常响应。)
// 503 重试(lrclibRequest)与第二种写法那一遍(resolveLRCLIBLyricForms)不在这份预算里,同样受 20s 截止约束:
// 503 当场就回(约 0.6s),重试只多 1～2s;第二种写法只在查询词被繁转简改过时才查。
//
// get 层只在拿到**带时间轴、时长也对得上**(sourceDurationFits;本地或它自报的时长未知时不看)的版本时提前收工,
// 或者它明说这首是纯音乐。只有纯文本、或者时长明显不对的,先记下来当兜底、照常往下走:search 层可能有同名的
// 带时间轴版本,「带时间戳的一条都挑不出来,才轮到纯文本」(见 lrclibSearch)。search 层也没挑出带时间轴的,
// 再用这份兜底。
func resolveLRCLIBLyric(ctx context.Context, artist, title, album string, durationSecs float64) lrclibResult {
	var fallback lrclibResult
	settled := func(r lrclibResult) bool {
		if r.instrumental || (r.lyrics != "" && !r.plainOnly && sourceDurationFits(durationSecs, r.durationSecs)) {
			return true
		}
		if fallback.lyrics == "" && r.lyrics != "" {
			fallback = r
		}
		return false
	}
	if r := lrclibGet(ctx, artist, title, album, durationSecs, 8*time.Second); settled(r) {
		return r
	}
	if album != "" {
		if r := lrclibGet(ctx, artist, title, "", durationSecs, 5*time.Second); settled(r) {
			return r
		}
	}
	s := lrclibSearch(ctx, artist, title, album, durationSecs, 5*time.Second)
	if s.instrumental || (s.lyrics != "" && !s.plainOnly) || fallback.lyrics == "" {
		return s
	}
	return fallback
}

// lrclibRequest 是三级共用的请求执行 + JSON 解码,out 传指针。
//
// 服务端同时只处理有限个请求,排不上队就回 503(ServerOverloaded + Retry-After: 1),不是在限我们的流:按
// Retry-After 等一下再发一次(lrclibOverloadWait),只重试这一次。见 09 章决策 137。
func lrclibRequest(ctx context.Context, url string, timeout time.Duration, out any) bool {
	for attempt := 0; ; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return false
		}
		// LRCLIB 的使用规范要求带上能标识调用方的 User-Agent。
		req.Header.Set("User-Agent", clientName+"/"+clientVersion+" (+https://github.com/Yudaotor/desktop-lyrics-suite)")
		resp, err := doHTTPTracked(lyricHTTPClient(timeout), req)
		if err != nil {
			return false
		}
		if resp.StatusCode == http.StatusOK {
			ok := json.NewDecoder(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes)).Decode(out) == nil
			resp.Body.Close()
			return ok
		}
		wait, retry := lrclibOverloadWait(resp.StatusCode, resp.Header.Get("Retry-After"))
		resp.Body.Close()
		if !retry || attempt > 0 {
			return false // 404(未收录)或其它错误放弃;下次 enrich 短 TTL 到期自然再试
		}
		if !lrclibOverloadPause(ctx, wait) {
			return false
		}
	}
}

// lrclibOverloadPause 等 d,ctx 先结束就返回 false。可换,只为单测;生产路径永远是这个实现。
var lrclibOverloadPause = func(ctx context.Context, d time.Duration) bool {
	select {
	case <-time.After(d):
		return true
	case <-ctx.Done():
		return false
	}
}

// lrclibOverloadRetryMax:503 的 Retry-After 不超过这么久才等着重试,更久的当这一次没问成。
const lrclibOverloadRetryMax = 2 * time.Second

// lrclibOverloadWait:这次应答要不要等一下再发一次、等多久。只认 503 + 秒数写法、不超过 lrclibOverloadRetryMax 的 Retry-After。
func lrclibOverloadWait(status int, retryAfter string) (time.Duration, bool) {
	if status != http.StatusServiceUnavailable {
		return 0, false
	}
	d, ok := retryAfterSeconds(retryAfter)
	if !ok || d > lrclibOverloadRetryMax {
		return 0, false
	}
	return d, true
}

// lrclibDurationParam:/api/get 的 duration 参数值。服务端只收 1～3600 秒(超出范围回 400),本地时长不在这个范围里就不带。
func lrclibDurationParam(durationSecs float64) string {
	if durationSecs < 1 || durationSecs > 3600 {
		return ""
	}
	return strconv.FormatFloat(durationSecs, 'f', 2, 64)
}

func lrclibGet(ctx context.Context, artist, title, album string, durationSecs float64, timeout time.Duration) lrclibResult {
	u := "https://lrclib.net/api/get?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	if album != "" {
		u += "&album_name=" + neturl.QueryEscape(album)
	}
	if d := lrclibDurationParam(durationSecs); d != "" {
		u += "&duration=" + d
	}
	var out lrclibSearchItem
	if !lrclibRequest(ctx, u, timeout, &out) {
		return lrclibResult{}
	}
	if out.Instrumental {
		return lrclibResult{instrumental: true}
	}
	if isTimedLRC(out.SyncedLyrics) {
		ex := lrclibItemExtras(out)
		return lrclibResult{lyrics: attachKanaLine(out.SyncedLyrics, ex.kana), yrc: ex.yrc, roma: ex.roma, durationSecs: out.Duration, title: out.TrackName, artist: out.ArtistName, album: out.AlbumName}
	}
	// 没有带时间戳的版本——退而求其次看有没有纯文本(plainOnly 的头注)。仍然要求非空,
	// 空字符串谈不上"有份纯文本",跟"整个没查到"没区别。
	if out.PlainLyrics != "" {
		return lrclibResult{lyrics: out.PlainLyrics, plainOnly: true, durationSecs: out.Duration, title: out.TrackName, artist: out.ArtistName, album: out.AlbumName}
	}
	return lrclibResult{}
}

// lrclibSearchItem 同时用于 /api/get 的单条响应和 /api/search 的数组元素——两个端点
// 返回的字段集一致(实测核实过 /api/search 的元素含 trackName/artistName/albumName/
// duration/instrumental/plainLyrics/syncedLyrics)。
type lrclibSearchItem struct {
	TrackName    string  `json:"trackName"`
	ArtistName   string  `json:"artistName"`
	AlbumName    string  `json:"albumName"`
	Duration     float64 `json:"duration"`
	Instrumental bool    `json:"instrumental"`
	SyncedLyrics string  `json:"syncedLyrics"`
	// PlainLyrics:才读——见 lrclibResult.plainOnly 头注,只在没有 syncedLyrics
	// 时当兜底用,不参与任何"这条候选算不算数"的正常判定。
	PlainLyrics string `json:"plainLyrics"`
	// HasWordSync / Lyricsfile:服务端标的「有逐字」与整份 lyricsfile(YAML,见 lyricsfile.go),只用来取逐字、罗马音与假名标注。
	HasWordSync bool   `json:"hasWordSync"`
	Lyricsfile  string `json:"lyricsfile"`
}

// lrclibItemExtras 从条目的 lyricsfile 取逐字、罗马音、假名标注(lyricsfileExtrasFrom)。服务端标了 hasWordSync、
// 或者文档里出现 words / transliteration 才去解析。
func lrclibItemExtras(it lrclibSearchItem) lyricsfileExtras {
	if it.Lyricsfile == "" || (!it.HasWordSync && !strings.Contains(it.Lyricsfile, "words:") && !strings.Contains(it.Lyricsfile, "transliteration")) {
		return lyricsfileExtras{}
	}
	return lyricsfileExtrasFrom(it.Lyricsfile, it.SyncedLyrics)
}

// lrclibSearchItems 只取一次 /api/search 的候选数组,不做挑选。
func lrclibSearchItems(ctx context.Context, artist, title string, timeout time.Duration) []lrclibSearchItem {
	u := "https://lrclib.net/api/search?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	var items []lrclibSearchItem
	if !lrclibRequest(ctx, u, timeout, &items) {
		return nil
	}
	return items
}

func lrclibSearch(ctx context.Context, artist, title, album string, durationSecs float64, timeout time.Duration) lrclibResult {
	// 原样标题和去括号裸标题各搜一次,**并发**跑,合并候选后统一挑一条。
	//
	// 为什么并发而不是再串一级降级:上面 resolveLRCLIBLyric 的三级已经吃掉 8+5+5=18s,
	// 而 enrich 那边 20s 是**硬**截止(到点就不再读 resultsCh,晚到的结果整轮丢弃,前两级
	// 的收益跟着一起没)。再串一级必然超预算。这两条查询打的是同一个端点、互不依赖,
	// 并发跑总耗时仍然只是一个 timeout,总预算一分钟没变。
	//
	// 为什么两条都要、不能只留裸标题:实测搜 "Automatic (Remastered 2014)" 回的两条
	// 都是同名重制版(严格档下唯一可能被接受的候选),搜 "Automatic" 回的 20 条则全是
	// 普通版。丢掉任何一条都会漏一类歌。
	queries := searchTitleVariants(title)
	lists := make([][]lrclibSearchItem, len(queries))
	var wg sync.WaitGroup
	for i, q := range queries {
		wg.Add(1)
		go func(idx int, query string) {
			defer wg.Done()
			lists[idx] = lrclibSearchItems(ctx, artist, query, timeout)
		}(i, q)
	}
	wg.Wait()
	var items []lrclibSearchItem
	for _, l := range lists {
		items = append(items, l...)
	}
	// 挑选判定用的始终是**本地原样标题** title,裸标题只是搜索词——放宽的是"拿什么去搜",
	// 不是"什么算匹配"。合并顺序跟着 searchTitleVariants 走(忽略括号档裸标题在前、严格档
	// 原样在前),时长同样接近时排在前面的那一档优先(pick 的并列取先到者)。
	//
	// 带时间戳的候选优先(allowPlainOnly=false,跟旧行为一致);一条都挑不出来才退一步
	// 认纯文本兜底——不是"两档一起扫、纯文本也能跟带时间戳的候选抢"，是"带时间戳的确实
	// 一条都没有,才轮到纯文本"(见 lrclibResult.plainOnly 头注)。
	if lyricSearchItemsTap != nil {
		lyricSearchItemsTap("lrclib", artist, title, album, durationSecs, items)
	}
	best, plainOnly := pickLRCLIBSearchResultDetailed(items, artist, title, album, durationSecs, false)
	if best == nil {
		best, plainOnly = pickLRCLIBSearchResultDetailed(items, artist, title, album, durationSecs, true)
	}
	if best == nil {
		return lrclibResult{}
	}
	if plainOnly {
		return lrclibResult{lyrics: best.PlainLyrics, plainOnly: true, durationSecs: best.Duration, title: best.TrackName, artist: best.ArtistName, album: best.AlbumName}
	}
	ex := lrclibItemExtras(*best)
	return lrclibResult{lyrics: attachKanaLine(best.SyncedLyrics, ex.kana), yrc: ex.yrc, roma: ex.roma, durationSecs: best.Duration, title: best.TrackName, artist: best.ArtistName, album: best.AlbumName}
}

// 曲名判定统一走 match.go 的 lyricTitleAccepted。
//
// 历史:这一级曾经有一个专用的、比别处更严的 lrclibStrictTitleMatch —— 因为当时别的源
// 走的是 looseContains(双向子串包含),而这一级**只在前两级精确 get 都 404 之后才跑**,
// 恰好落在"这首歌 LRCLIB 大概没收录、search 返回的全是同歌手近似曲名"这个场合,双向包含
// 在那儿是灾难:查 "Real Love" 会命中 "Real Love Baby",时长又都在容差内,于是把另一首歌
// 的歌词当成这一首返回。lyricTitleAccepted 对**所有源**都收紧成了同一条
// 规则(相等 或 各自去括号后相等,不认子串),这个专用函数就没有存在的理由了。

// lrclibSearchDurationTolerance 跟 scoreLyricCandidate 的时长闸门(match.go 里那个
// ratio <= 0.25)取同一个值——挑一个下游注定会因为时长对不上而丢弃的候选毫无意义。
const lrclibSearchDurationTolerance = 0.25

// pickLRCLIBSearchResult 从 /api/search 的候选里挑一个,挑不出就返回 nil(宁可这一源没
// 结果,也不要把错的塞给下游)。纯函数,便于单测。
//
// 四道门,顺序无关但都必须过:
// ① 必须是真的带时间戳的逐行歌词(isTimedLRC)——search 的结果里 syncedLyrics 可能为空;
// ② 曲名要对得上,用的是**比 titleMatches 更严**的 lrclibStrictTitleMatch(理由见那边注释:
//
//	双向子串包含在这一级会把同歌手的近似曲名当成本曲);
//
// ③ 歌手要对得上(lyricSourceArtistMatches:artistMatches 的拆分比较 + 两侧多人
//
//	合credit 的段集交集档,仍比子串包含严,见 match.go 那边的防仿冒注释);
//
// ④ 版本限定词不能相反(versionTagsMismatch)——搜 "Song" 很容易返回 "Song (Live)",
//
//	那是另一次录音、时间轴对不上,见 match.go 里那段注释。
//
// 过门之后按时长挑最接近的。**这一步是必须的,不是优化**:实测搜
// "Blue Gangsta (Original Version)" 返回的第一个候选 duration=4.0 秒(库里的脏数据),
// 盲取第一条就会拿它。本地时长未知(durationSecs<=0)时退回"取第一个过门的",此时没有
// 任何信号能分辨,交给下游 scoreLyricCandidate 继续把关。
func pickLRCLIBSearchResult(items []lrclibSearchItem, artist, title, album string, durationSecs float64) *lrclibSearchItem {
	best, _ := pickLRCLIBSearchResultDetailed(items, artist, title, album, durationSecs, false)
	return best
}

// pickLRCLIBSearchResultDetailed 是 pickLRCLIBSearchResult 的完整版本——加
// allowPlainOnly 这道口子(见 lrclibResult.plainOnly 头注):false 时跟旧版逐字节一致
// (只认 isTimedLRC),true 时"没有带时间戳的版本"不再直接判废,退一步认"至少有纯文本"。
// 第二个返回值标出选中的这条究竟是不是靠纯文本兜底选出来的,调用方据此决定要不要给
// lrclibResult 打上 plainOnly 标记。
//
// allowPlainOnly 只放宽"要不要带时间戳"这一道门,其余判定(曲名/歌手/版本限定词/
// 时长容差)原样保留——纯文本候选跟带时间戳的候选面对的是同一套"这条到底是不是这首歌"
// 的身份核验,没有理由放松,松了就是在瞎猜。
func pickLRCLIBSearchResultDetailed(items []lrclibSearchItem, artist, title, album string, durationSecs float64, allowPlainOnly bool) (best *lrclibSearchItem, plainOnly bool) {
	bestDiff := -1.0
	for i := range items {
		it := &items[i]
		timed := isTimedLRC(it.SyncedLyrics)
		if !timed && !(allowPlainOnly && it.PlainLyrics != "") {
			continue
		}
		if !lyricTitleAccepted(it.TrackName, title) ||
			!lyricSourceArtistMatches(it.ArtistName, artist) {
			continue
		}
		// 专辑名一起看:限定词常常只写在专辑上(见 versionTagsMismatch 的注释)。
		// v9 起带 sameRecordingDespiteVersionTags 豁免,与打分层的 versionTags 闸同一对
		// 组合:本地专辑《My Space 演唱會紀念盤》(专辑名推导出 live)对上 lrclib 的截短
		// 拼法 "My Space"(推导不出)会误判 mismatch,而这里有 it.Duration 可查,豁免的
		// 四道门查得动——不加的话同场对版在召回层就被扔掉,连进打分的机会都没有。
		if versionTagsMismatch(title, album, it.TrackName, it.AlbumName) &&
			!sameRecordingDespiteVersionTags(title, album, durationSecs, it.TrackName, it.AlbumName, it.Duration) {
			continue
		}
		if durationSecs <= 0 {
			if best == nil {
				best, plainOnly = it, !timed
			}
			continue
		}
		if it.Duration <= 0 {
			continue // 时长未知且我们有本地时长可比 → 没法核对,跳过(脏数据多出在这里)
		}
		diff := math.Abs(it.Duration-durationSecs) / durationSecs
		if diff > lrclibSearchDurationTolerance {
			continue
		}
		if bestDiff < 0 || diff < bestDiff {
			best, bestDiff, plainOnly = it, diff, !timed
		}
	}
	return best, plainOnly
}
