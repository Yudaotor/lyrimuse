// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"math"
	"net/http"
	neturl "net/url"
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
// instrumental 是 LRCLIB 自己标注的"这首歌是纯音乐"——2026-08-03 补上:这个字段
// 原来读出来就直接丢了(instrumental==true 时跟"这个源压根没查到"返回同一个空结构体
// 处理),下游"啥都没有"的空状态因此永远只有一种,用户分不清"是真没找到歌词"还是
// "这首歌本来就没有歌词"。见 fetchScoredLyricCandidatesStreaming 里怎么把这个信号
// 一路传到 enrichEntry.Instrumental。
type lrclibResult struct {
	lyrics, title, artist, album string
	// durationSecs:LRCLIB 自报的这首歌时长(秒),0=没给。透传用,见 lyricCandidate 同名字段。
	durationSecs float64
	instrumental bool
	// plainOnly:2026-08-30 加,"只有纯文本歌词,没有带时间戳的版本"这个明确结论——真实案例
	// 海龟先生《Porn Star》,网易云/QQ 的搜索接口把标题里的敏感词整体过滤掉(HTTP 200 但
	// body 是空结果,不是真的没收录),LRCLIB 却精确命中、内容和时长都对得上,只是这首歌
	// 在 LRCLIB 自己库里就只有 plainLyrics、没有 syncedLyrics。以前遇到这种情况直接判定
	// "没查到"整个丢弃(lyrics 留空),没人能看到内容,哪怕是不能同步显示的纯文本也比什么
	// 都没有强(见"歌词窗口"新增的纯文本静态展示、"搜索候选歌词"弹窗新增的"无时间戳"标签)。
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

	r := resolveLRCLIBLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" || r.instrumental {
		lrclibMu.Lock()
		lrclibCache[key] = r
		lrclibMu.Unlock()
	}
	return r
}

// resolveLRCLIBLyric 三级降级,越往后越宽松。改动之前只有第一级,一失败就整源判"没收录"。
//
// ① /api/get 带 album_name(原有行为,最严)
// ② /api/get 去掉 album_name —— **2026-08-05 实测坐实的真实盲区**:album_name 是参与
//
//	匹配的,传一个 LRCLIB 那边没有的专辑名会直接 404,哪怕这首歌其实收录了。实测同一首
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
// ⚠️ 这个截止是**硬**的,不是软的:enrich.go 的 collect 循环 `case <-deadline: break collect`
// 之后就不再读 resultsCh、也不再调 onUpdate,晚到的结果整轮丢弃。所以三级串行的总预算必须
// 塞进 20s 里——超出去等于这一源白跑,前两级的收益也一起没了。(第一级从 10s 收到 8s 是为了
// 给后两级腾时间;lrclib.net 慢,但 8s 仍然远超它的正常响应。)
func resolveLRCLIBLyric(ctx context.Context, artist, title, album string, durationSecs float64) lrclibResult {
	if r := lrclibGet(ctx, artist, title, album, 8*time.Second); r.lyrics != "" || r.instrumental {
		return r
	}
	if album != "" {
		if r := lrclibGet(ctx, artist, title, "", 5*time.Second); r.lyrics != "" || r.instrumental {
			return r
		}
	}
	return lrclibSearch(ctx, artist, title, album, durationSecs, 5*time.Second)
}

// lrclibRequest 是三级共用的请求执行 + JSON 解码,out 传指针。
func lrclibRequest(ctx context.Context, url string, timeout time.Duration, out any) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false
	}
	// LRCLIB 的使用规范要求带上能标识调用方的 User-Agent。
	req.Header.Set("User-Agent", clientName+"/"+clientVersion+" (+https://github.com/Yudaotor/desktop-lyrics-suite)")
	resp, err := doHTTPTracked(&http.Client{Timeout: timeout}, req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false // 404(未收录)或其它错误一律放弃,不重试;下次 enrich 短 TTL 到期自然再试
	}
	return json.NewDecoder(resp.Body).Decode(out) == nil
}

func lrclibGet(ctx context.Context, artist, title, album string, timeout time.Duration) lrclibResult {
	u := "https://lrclib.net/api/get?artist_name=" + neturl.QueryEscape(artist) +
		"&track_name=" + neturl.QueryEscape(title)
	if album != "" {
		u += "&album_name=" + neturl.QueryEscape(album)
	}
	var out lrclibSearchItem
	if !lrclibRequest(ctx, u, timeout, &out) {
		return lrclibResult{}
	}
	if out.Instrumental {
		return lrclibResult{instrumental: true}
	}
	if isTimedLRC(out.SyncedLyrics) {
		return lrclibResult{lyrics: out.SyncedLyrics, durationSecs: out.Duration, title: out.TrackName, artist: out.ArtistName, album: out.AlbumName}
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
	// PlainLyrics:2026-08-30 起才读——见 lrclibResult.plainOnly 头注,只在没有 syncedLyrics
	// 时当兜底用,不参与任何"这条候选算不算数"的正常判定。
	PlainLyrics string `json:"plainLyrics"`
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
	lyrics := best.SyncedLyrics
	if plainOnly {
		lyrics = best.PlainLyrics
	}
	return lrclibResult{lyrics: lyrics, plainOnly: plainOnly, durationSecs: best.Duration, title: best.TrackName, artist: best.ArtistName, album: best.AlbumName}
}

// 曲名判定统一走 match.go 的 lyricTitleAccepted。
//
// 历史:这一级曾经有一个专用的、比别处更严的 lrclibStrictTitleMatch —— 因为当时别的源
// 走的是 looseContains(双向子串包含),而这一级**只在前两级精确 get 都 404 之后才跑**,
// 恰好落在"这首歌 LRCLIB 大概没收录、search 返回的全是同歌手近似曲名"这个场合,双向包含
// 在那儿是灾难:查 "Real Love" 会命中 "Real Love Baby",时长又都在容差内,于是把另一首歌
// 的歌词当成这一首返回。2026-08-09 起 lyricTitleAccepted 对**所有源**都收紧成了同一条
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

// pickLRCLIBSearchResultDetailed 是 pickLRCLIBSearchResult 的完整版本——2026-08-30 加
// allowPlainOnly 这道口子(见 lrclibResult.plainOnly 头注):false 时跟旧版逐字节一致
// (只认 isTimedLRC),true 时"没有带时间戳的版本"不再直接判废,退一步认"至少有纯文本"。
// 第二个返回值标出选中的这条究竟是不是靠纯文本兜底选出来的,调用方据此决定要不要给
// lrclibResult 打上 plainOnly 标记。
//
// ⚠️ allowPlainOnly 只放宽"要不要带时间戳"这一道门,其余判定(曲名/歌手/版本限定词/
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
