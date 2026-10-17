package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"math"
	"strings"
	"sync"
	"time"
)

// 汽水音乐非会员「试听」:MediaRemote 报的是**试听段自己的时间轴** —— duration 是试听段长度
// (30 / 60s),elapsedTime 从 0 起 —— 而试听段是从整首歌中间截的一段。不纠正的话进度条显示
// 0:06 / 0:29、歌词时间轴对不上(试听段的第 6 秒是原曲的第 `preview.start` + 6 秒)、歌词匹配拿
// 30s 去比几分钟的曲长,各个源都被时长闸挡掉,永远停在「搜索歌词中」。
//
// 试听段信息每首歌都带着(`preview: {start, duration}`,毫秒):本地播放队列缓存(sodalocal.go)
// 与搜索接口(soda.go 的 sodaSearch)两处都有。本地那份只覆盖推荐流 / 听歌模式里的歌,从搜索、
// 专辑页点播的不在里面,所以查不到再走一次搜索(异步,按曲目缓存)。
//
// 认定「正在试听」只看一件事:播放器报的时长 ≈ 这首歌的 preview.duration,且比整首短得多
// (sodaPreviewMatches)。会员 / 限免时报的是整首,不命中,原样不动。
//
// 查找与发布在引擎(读播放状态那一拍,见 liveAppSodaPreview):结论发布给 App
// (lyrimuse-player-preview.json),App 在 MediaControlClient.fetchSnapshot 出口换成原曲口径再写进播放状态;
// App 还没跟上的那一两拍由 appPlaybackTickFor 本地先换。之后整条链路(歌词匹配、网页进度、收听记录)拿到的
// 都是原曲口径。两边必须同一个口径,否则歌词缓存按时长挑出来的版本和 App 显示的进度各说各话。

type sodaPreview struct {
	StartSecs float64
	DurSecs   float64
	FullSecs  float64
}

const (
	// 播放器报的时长与 preview.duration 最多差多少还算同一段(实测 60 对 60.001、30 对 30.001)。
	sodaPreviewDurationTolerance = 1.5
	// 整首至少比播放器报的长这么多才算试听 —— 本来就很短的歌,试听段就是整首,不用换。
	sodaPreviewMinGap = 5.0
	// 只有报的时长这么短时才去搜索:试听段实测 30 / 60s;正常长度的歌不值得多一次网络请求。
	sodaPreviewMaxSearchSecs = 90.0
	// 搜索没找到的曲目多久之后再试一次。前 sodaPreviewQuickRetries 次隔得短(sodaPreviewRetryAfter):搜索接口时不时
	// 整批给降级结果,试听段只有 30 / 60 秒,等 10 分钟就整段错过了(09 章决策 240)。
	sodaPreviewNegativeTTL   = 10 * time.Minute
	sodaPreviewQuickRetries  = 2
	sodaPreviewSearchTimeout = 8 * time.Second
)

// sodaPreviewMatches 判这一拍是不是在放这段试听。纯函数,测试直接覆盖。
func sodaPreviewMatches(mrDuration float64, p sodaPreview) bool {
	return p.DurSecs > 0 && p.FullSecs > 0 &&
		math.Abs(mrDuration-p.DurSecs) <= sodaPreviewDurationTolerance &&
		p.FullSecs-mrDuration > sodaPreviewMinGap
}

// sodaPreviewFromMillis 把缓存 / 接口里的毫秒字段换成 sodaPreview;缺字段返回 false。
func sodaPreviewFromMillis(startMs, durMs, fullMs int64) (sodaPreview, bool) {
	if durMs <= 0 || fullMs <= 0 || startMs < 0 {
		return sodaPreview{}, false
	}
	return sodaPreview{StartSecs: float64(startMs) / 1000, DurSecs: float64(durMs) / 1000, FullSecs: float64(fullMs) / 1000}, true
}

// sodaArtistCandidates 把播放器报的署名拆成可以逐个去查的名字:整串先查(单人署名就是它),
// 再按常见分隔符拆开 —— 汽水多人署名报成「HUSH, 孙盛希」,本地索引却按单个歌手建。
func sodaArtistCandidates(artist string) []string {
	artist = strings.TrimSpace(artist)
	if artist == "" {
		return nil
	}
	out := []string{artist}
	parts := strings.FieldsFunc(artist, func(r rune) bool {
		return r == ',' || r == '，' || r == '/' || r == '&' || r == '、'
	})
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" && p != artist {
			out = append(out, p)
		}
	}
	return out
}

// sodaLocalPreview 在本地队列缓存里找这首歌的试听段,挑法见 sodaPickLocalPreview。队列缓存不记哪一条是正在放的,
// 同名的几个版本分不出来时没结论,交给音频缓存库和搜索。
func sodaLocalPreview(artist, title, album string, mrDuration float64) (sodaPreview, bool) {
	sodaLocalMu.Lock()
	refreshSodaLocalIndexLocked()
	var ents []sodaLocalTrack
	for _, a := range sodaArtistCandidates(artist) {
		if key := sodaLocalKey(a, title); key != "" {
			ents = append(ents, sodaLocalIndex[key]...)
		}
	}
	sodaLocalMu.Unlock()
	var cands []sodaPreviewCandidate
	for _, e := range ents {
		if e.Preview == nil {
			continue
		}
		if p, ok := sodaPreviewFromMillis(e.Preview.Start, e.Preview.Duration, e.Duration); ok {
			cands = append(cands, sodaPreviewCandidate{p: p, album: e.Album.Name})
		}
	}
	return sodaPickLocalPreview(cands, album, mrDuration)
}

// sodaPreviewCandidate:本机记录里一条同歌手、同歌名的曲目的试听段。at 是它在音频缓存库里建立的时刻(秒),队列缓存的为 0。
type sodaPreviewCandidate struct {
	p     sodaPreview
	album string
	at    int64
}

// sodaPickLocalPreview 从本机记录(队列缓存 / 音频缓存库)的同名曲目里给这一拍挑试听段,纯函数。只看试听段跟播放器报的
// 时长对得上的;其中有专辑对得上的,就只在这几条里挑 —— 同名的录音室版和现场版试听段一样长,只有专辑分得开,
// 搜索那条路(sodaPickPreview)同样专辑优先。剩下的取缓存建得最晚的那条(正在放的这首,缓存多半是刚建的);
// 同一刻建的几条换算不一样就没结论。队列缓存不记建立时刻(都是 0),它那边同名几条换算不一样时一律没结论。
func sodaPickLocalPreview(cands []sodaPreviewCandidate, album string, mrDuration float64) (sodaPreview, bool) {
	wantAlbum := normLoose(album)
	var fit, sameAlbum []sodaPreviewCandidate
	for _, c := range cands {
		if !sodaPreviewMatches(mrDuration, c.p) {
			continue
		}
		fit = append(fit, c)
		if wantAlbum != "" && normLoose(c.album) == wantAlbum {
			sameAlbum = append(sameAlbum, c)
		}
	}
	if len(sameAlbum) > 0 {
		fit = sameAlbum
	}
	if len(fit) == 0 {
		return sodaPreview{}, false
	}
	latest := fit[0]
	for _, c := range fit[1:] {
		if c.at > latest.at {
			latest = c
		}
	}
	for _, c := range fit {
		if c.at == latest.at && !sodaPreviewSame(c.p, latest.p) {
			return sodaPreview{}, false
		}
	}
	return latest.p, true
}

// sodaPreviewSame:两条换算的起点、整首时长都一样。
func sodaPreviewSame(a, b sodaPreview) bool {
	return a.StartSecs == b.StartSecs && a.FullSecs == b.FullSecs
}

type sodaPreviewCacheEntry struct {
	p     sodaPreview
	found bool
	at    time.Time
	// misses:连着没搜到几次;隔了 sodaPreviewNegativeTTL 以上再搜的从头数。
	misses int
}

// sodaPreviewRetryAfter:连着没搜到 misses 次之后,隔多久再搜。
func sodaPreviewRetryAfter(misses int) time.Duration {
	switch {
	case misses <= 1:
		return 5 * time.Second
	case misses <= sodaPreviewQuickRetries:
		return 15 * time.Second
	default:
		return sodaPreviewNegativeTTL
	}
}

var (
	sodaPreviewMu       sync.Mutex
	sodaPreviewCache    = map[string]sodaPreviewCacheEntry{}
	sodaPreviewInflight = map[string]bool{}
	// sodaPreviewSearchFn 让单测替换掉网络搜索。
	sodaPreviewSearchFn = sodaSearchPreview
)

// sodaPreviewFor 给这一拍找试听段。本地命中同步返回;本地没有就查搜索结果缓存,缓存也没有就在
// 后台发一次搜索、这一拍先按没找到处理(下一拍拿到)。onSearchFound 在后台搜到的那一刻调用 ——
// 给 App 的发布不必等下一拍,见 liveAppSodaPreview。
func sodaPreviewFor(artist, title, album string, mrDuration float64, onSearchFound func(sodaPreview)) (sodaPreview, bool) {
	if mrDuration <= 0 || strings.TrimSpace(title) == "" {
		return sodaPreview{}, false
	}
	if p, ok := sodaLocalPreview(artist, title, album, mrDuration); ok {
		return p, true
	}
	if mrDuration > sodaPreviewMaxSearchSecs {
		return sodaPreview{}, false
	}
	// 点播的歌不在队列缓存里,但一定在客户端的音频缓存库里;曲目信息已经问到时同步查得到,不用等搜索(见 sodapreload.go)。
	if p, ok := sodaPreloadPreview(artist, title, album, mrDuration); ok {
		return p, true
	}
	key := sodaPreviewSearchKey(artist, title, album)
	sodaPreviewMu.Lock()
	e, cached := sodaPreviewCache[key]
	if cached && (e.found || time.Since(e.at) < sodaPreviewRetryAfter(e.misses)) {
		sodaPreviewMu.Unlock()
		if e.found && sodaPreviewMatches(mrDuration, e.p) {
			return e.p, true
		}
		return sodaPreview{}, false
	}
	if sodaPreviewInflight[key] {
		sodaPreviewMu.Unlock()
		return sodaPreview{}, false
	}
	sodaPreviewInflight[key] = true
	misses := 0
	if cached && !e.found && time.Since(e.at) < sodaPreviewNegativeTTL {
		misses = e.misses
	}
	sodaPreviewMu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), sodaPreviewSearchTimeout)
		defer cancel()
		p, ok := sodaPreviewSearchFn(ctx, artist, title, album, mrDuration)
		if ok {
			slog.Info("soda preview: found via search", "artist", artist, "title", title,
				"start", p.StartSecs, "preview", p.DurSecs, "full", p.FullSecs)
			// 先发布再进缓存:看得到缓存的人(下一拍轮询)一定也看得到已发布的那份。
			if onSearchFound != nil {
				onSearchFound(p)
			}
		}
		entry := sodaPreviewCacheEntry{p: p, found: ok, at: time.Now()}
		if !ok {
			entry.misses = misses + 1
		}
		sodaPreviewMu.Lock()
		sodaPreviewCache[key] = entry
		delete(sodaPreviewInflight, key)
		sodaPreviewMu.Unlock()
	}()
	return sodaPreview{}, false
}

// sodaPreviewSearchKey:搜索结果按歌手、歌名、专辑记。挑哪一条要看专辑(sodaPickPreview),同名的另一个版本得另搜,
// 不能拿上一个版本搜到的试听段。
func sodaPreviewSearchKey(artist, title, album string) string {
	return normLoose(artist) + "|" + normLoose(title) + "|" + normLoose(album)
}

// sodaSearchPreview 按曲名搜一次,在过了身份闸、preview 又对得上播放器时长的候选里挑一条。过了身份闸的候选的整首时长顺手记进
// sodaSearchFullLengths。
func sodaSearchPreview(ctx context.Context, artist, title, album string, mrDuration float64) (sodaPreview, bool) {
	items, err := sodaSearch(ctx, artist, title)
	if err != nil {
		slog.Info("soda preview: search failed", "artist", artist, "title", title, "err", err)
		return sodaPreview{}, false
	}
	noteSodaSearchFullLengths(items, artist, title, album)
	return sodaPickPreview(items, artist, title, album, mrDuration)
}

// sodaSearchFullLengths:搜索答回来、过了身份闸(同 sodaPickPreview)的同歌手同歌名曲目的整首时长(毫秒),按
// sodaFullLengthKey 记。本来就 30 / 60 秒的歌(片头、间奏)在本机的队列缓存、音频缓存库里都查不到曲目信息时,靠它认出
// 报的就是整首(sodaFullLengthKnown),不然一直当成可能是试听段,歌词不解析、收听不记。满 sodaSearchFullLengthsMax 条清空重记。
var sodaSearchFullLengths = map[string][]int64{}

const sodaSearchFullLengthsMax = 512

func sodaFullLengthKey(artist, title string) string {
	return normLoose(artist) + "|" + normLoose(title)
}

func noteSodaSearchFullLengths(items []sodaSearchItem, artist, title, album string) {
	var fulls []int64
	for _, it := range items {
		if it.Duration <= 0 || !lyricTitleAccepted(it.Name, title) || !lyricSourceArtistMatches(it.Artist, artist) ||
			versionTagsMismatch(title, album, it.Name, it.Album) {
			continue
		}
		fulls = append(fulls, int64(it.Duration*1000))
	}
	if len(fulls) == 0 {
		return
	}
	sodaPreviewMu.Lock()
	if len(sodaSearchFullLengths) >= sodaSearchFullLengthsMax {
		sodaSearchFullLengths = map[string][]int64{}
	}
	sodaSearchFullLengths[sodaFullLengthKey(artist, title)] = fulls
	sodaPreviewMu.Unlock()
}

// sodaPickPreview 纯函数,测试直接覆盖。身份闸与歌词那条路同一套(lyricTitleAccepted /
// lyricSourceArtistMatches / versionTagsMismatch);时长不拿整首比(试听时播放器报的是试听段),
// 改比 preview.duration。同名多条时专辑一致的优先。
func sodaPickPreview(items []sodaSearchItem, artist, title, album string, mrDuration float64) (sodaPreview, bool) {
	var best sodaPreview
	bestScore := -1
	for _, it := range items {
		if !lyricTitleAccepted(it.Name, title) || !lyricSourceArtistMatches(it.Artist, artist) ||
			versionTagsMismatch(title, album, it.Name, it.Album) {
			continue
		}
		p, ok := sodaPreviewFromMillis(it.PreviewStartMs, it.PreviewDurationMs, int64(it.Duration*1000))
		if !ok || !sodaPreviewMatches(mrDuration, p) {
			continue
		}
		score := 1
		if album != "" && normLoose(it.Album) == normLoose(album) {
			score = 2
		}
		if score > bestScore {
			best, bestScore = p, score
		}
	}
	return best, bestScore > 0
}

// ---- 发布给 App ----
//
// 只读通道:引擎只写,App 只读(同 playerartistfix.go)。App 按 bundle + 曲名 + 歌手比对、
// 并且只在它那一拍报的时长仍是试听段长度时才换算,换歌 / 转成整首播放都自然失效。
type playerPreviewFixState struct {
	UpdatedAt       int64   `json:"updatedAt"`
	Bundle          string  `json:"bundle"`
	Title           string  `json:"title"`
	Artist          string  `json:"artist"`
	PreviewStart    float64 `json:"previewStart"`
	PreviewDuration float64 `json:"previewDuration"`
	FullDuration    float64 `json:"fullDuration"`
}

var (
	playerPreviewFixMu   sync.Mutex
	playerPreviewFixPath string
	playerPreviewFixLast playerPreviewFixState
)

// setPlayerPreviewFixPath 由 setLyricsFillPaths 调用。空路径 = 不发布(单测默认如此)。
// 上一个进程留下的那份**不删**:App 按 bundle + 曲名 + 歌手 + 「这一拍报的仍是试听段长度」逐条核,
// 对不上的旧记录自然不生效;而放到一半引擎被重启时,留着它 App 才不会退回试听段的时间轴
// (新进程启动到第一拍轮询要十几秒)。
func setPlayerPreviewFixPath(path string) {
	playerPreviewFixMu.Lock()
	defer playerPreviewFixMu.Unlock()
	playerPreviewFixPath = path
	playerPreviewFixLast = playerPreviewFixState{}
}

// publishPlayerPreviewFix 发布一条试听段换算。同一条重复发布不写盘(每一拍都会调到)。
func publishPlayerPreviewFix(bundle, title, artist string, p sodaPreview) {
	playerPreviewFixMu.Lock()
	defer playerPreviewFixMu.Unlock()
	if playerPreviewFixPath == "" {
		return
	}
	next := playerPreviewFixState{Bundle: bundle, Title: title, Artist: artist,
		PreviewStart: p.StartSecs, PreviewDuration: p.DurSecs, FullDuration: p.FullSecs}
	if next == playerPreviewFixLast {
		return
	}
	stamped := next
	stamped.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(stamped)
	if err != nil {
		return
	}
	if err := writeFileAtomic(playerPreviewFixPath, data); err != nil {
		slog.Warn("player preview fix: state write failed", "err", err)
		return
	}
	playerPreviewFixLast = next
	slog.Info("player preview fix: published", "bundle", bundle, "title", title,
		"start", p.StartSecs, "preview", p.DurSecs, "full", p.FullSecs)
}

// sodaPreviewKnown 记最近一次查到试听段的是哪一首、试听段与整首多长 —— 会话时长补正要认它
// (见 sodaPreviewSessionBackfill)。查到就记,不等换算:App 可能先于下一拍套上发布的纠正、直接报整首。
var (
	sodaPreviewKnownMu  sync.Mutex
	sodaPreviewKnownKey string
	sodaPreviewKnownP   sodaPreview
)

func noteSodaPreviewKnown(artist, title string, p sodaPreview) {
	sodaPreviewKnownMu.Lock()
	sodaPreviewKnownKey, sodaPreviewKnownP = normLoose(artist)+"|"+normLoose(title), p
	sodaPreviewKnownMu.Unlock()
}

// sodaPreviewSessionBackfill 判这次播放的会话时长要不要补成整首:会话开在试听段还没查到的那一拍,
// 记下的是试听段长度(30 / 60s);按它算「听满一半」,试听 30 秒就会被记成一次收听。只认最近查到试听段的
// 这一首、且会话时长正好是它的试听段长度、这一拍已是整首 —— 别的时长跳变(换曲预载窗口里拼进来的
// 下一首时长)一概不碰。
func sodaPreviewSessionBackfill(bundle, artist, title string, sessDur, curDur float64) bool {
	if bundle != sodaMusicBundleID {
		return false
	}
	sodaPreviewKnownMu.Lock()
	key, p := sodaPreviewKnownKey, sodaPreviewKnownP
	sodaPreviewKnownMu.Unlock()
	if key == "" || key != normLoose(artist)+"|"+normLoose(title) {
		return false
	}
	return math.Abs(sessDur-p.DurSecs) <= sodaPreviewDurationTolerance && math.Abs(curDur-p.FullSecs) < 0.5
}

// sodaPreviewLookupPending 判这首歌的试听段是不是还没有结论:还在后台搜,或者报的时长正是试听段的长度
// (sodaPreviewTypicalLength)、又没有证据说这首整首就这么长(sodaFullLengthKnown)。没结论时先别按这一拍的时长
// 解析歌词、建条目、记收听(见 poller 的 SodaPreviewPending):按 30s 去比缓存里几分钟的曲长,会另开一个「时长变体」
// 重新解析,挑出来的多半是凑数的歌词;会话时长记成 30s,听满一半就算一次收听(09 章决策 240)。
func sodaPreviewLookupPending(artist, title, album string, mrDuration float64) bool {
	sodaPreviewMu.Lock()
	inflight := sodaPreviewInflight[sodaPreviewSearchKey(artist, title, album)]
	sodaPreviewMu.Unlock()
	if inflight {
		return true
	}
	return sodaPreviewTypicalLength(mrDuration) && !sodaFullLengthKnown(artist, title, mrDuration)
}

// sodaPreviewTypicalLength:报的时长是不是试听段的长度(实测只有 30 / 60s 两种)。
func sodaPreviewTypicalLength(mrDuration float64) bool {
	return math.Abs(mrDuration-30) <= sodaPreviewDurationTolerance || math.Abs(mrDuration-60) <= sodaPreviewDurationTolerance
}

// sodaFullLengthKnown:本机的队列缓存或音频缓存库(曲目信息已经问到的)里有这首、或者试听段搜索答回来的同名曲目
// (sodaSearchFullLengths)里有,整首时长跟报的对得上 —— 这首本来就这么长,不是试听。
func sodaFullLengthKnown(artist, title string, mrDuration float64) bool {
	fits := func(fullMs int64) bool {
		return fullMs > 0 && math.Abs(float64(fullMs)/1000-mrDuration) <= sodaPreviewMinGap
	}
	sodaLocalMu.Lock()
	refreshSodaLocalIndexLocked()
	var ents []sodaLocalTrack
	for _, a := range sodaArtistCandidates(artist) {
		if key := sodaLocalKey(a, title); key != "" {
			ents = append(ents, sodaLocalIndex[key]...)
		}
	}
	sodaLocalMu.Unlock()
	for _, e := range ents {
		if fits(e.Duration) {
			return true
		}
	}
	want := loosenEnrichKey(artist + "|" + title)
	if want == "|" {
		return false
	}
	for _, t := range sodaPreloadIndex() {
		if loosenEnrichKey(t.upcoming.artist+"|"+t.upcoming.title) == want && fits(t.fullMs) {
			return true
		}
	}
	sodaPreviewMu.Lock()
	searched := sodaSearchFullLengths[sodaFullLengthKey(artist, title)]
	sodaPreviewMu.Unlock()
	for _, ms := range searched {
		if fits(ms) {
			return true
		}
	}
	return false
}
