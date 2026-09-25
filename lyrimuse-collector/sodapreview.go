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
// 纠正在 fetchRawMediaControlState 里做(与酷狗署名纠正同一个位置),之后整条链路(歌词匹配、
// 网页进度、收听记录)拿到的都是原曲口径;同一份结论发布给 App(lyrimuse-player-preview.json),
// App 在 MediaControlClient.fetchSnapshot 出口做同样的换算。两边必须同时换,否则歌词缓存按
// 时长挑出来的版本和 App 显示的进度各说各话。

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
	// 搜索没找到的曲目多久之后再试一次。
	sodaPreviewNegativeTTL   = 10 * time.Minute
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

// sodaLocalPreview 在本地队列缓存里找这首歌的试听段。只收 preview 与播放器报的时长对得上的那条。
func sodaLocalPreview(artist, title string, mrDuration float64) (sodaPreview, bool) {
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
		if e.Preview == nil {
			continue
		}
		if p, ok := sodaPreviewFromMillis(e.Preview.Start, e.Preview.Duration, e.Duration); ok && sodaPreviewMatches(mrDuration, p) {
			return p, true
		}
	}
	return sodaPreview{}, false
}

type sodaPreviewCacheEntry struct {
	p     sodaPreview
	found bool
	at    time.Time
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
// 给 App 的发布不必等下一拍轮询(5s),见 applySodaPreview。
func sodaPreviewFor(artist, title, album string, mrDuration float64, onSearchFound func(sodaPreview)) (sodaPreview, bool) {
	if mrDuration <= 0 || strings.TrimSpace(title) == "" {
		return sodaPreview{}, false
	}
	if p, ok := sodaLocalPreview(artist, title, mrDuration); ok {
		return p, true
	}
	if mrDuration > sodaPreviewMaxSearchSecs {
		return sodaPreview{}, false
	}
	// 点播的歌不在队列缓存里,但一定在客户端的音频缓存库里,同步查得到,不用等搜索(见 sodapreload.go)。
	if p, ok := sodaPreloadPreview(artist, title, mrDuration); ok {
		return p, true
	}
	key := normLoose(artist) + "|" + normLoose(title)
	sodaPreviewMu.Lock()
	e, cached := sodaPreviewCache[key]
	if cached && (e.found || time.Since(e.at) < sodaPreviewNegativeTTL) {
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
		sodaPreviewMu.Lock()
		sodaPreviewCache[key] = sodaPreviewCacheEntry{p: p, found: ok, at: time.Now()}
		delete(sodaPreviewInflight, key)
		sodaPreviewMu.Unlock()
	}()
	return sodaPreview{}, false
}

// sodaSearchPreview 按曲名搜一次,在过了身份闸、preview 又对得上播放器时长的候选里挑一条。
func sodaSearchPreview(ctx context.Context, artist, title, album string, mrDuration float64) (sodaPreview, bool) {
	items, err := sodaSearch(ctx, artist, title)
	if err != nil {
		slog.Info("soda preview: search failed", "artist", artist, "title", title, "err", err)
		return sodaPreview{}, false
	}
	return sodaPickPreview(items, artist, title, album, mrDuration)
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
// 只读通道:collector 只写,App 只读(同 playerartistfix.go)。App 按 bundle + 曲名 + 歌手比对、
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
// 对不上的旧记录自然不生效;而放到一半 collector 被重启时,留着它 App 才不会退回试听段的时间轴
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

// sodaPreviewApplied 记最近一次换算的是哪一首、换成了什么 —— 会话时长补正要认它
// (见 sodaPreviewSessionBackfill)。
var (
	sodaPreviewAppliedMu  sync.Mutex
	sodaPreviewAppliedKey string
	sodaPreviewAppliedP   sodaPreview
)

// sodaPreviewSessionBackfill 判这次播放的会话时长要不要补成整首:会话开在试听段还没查到的那一拍,
// 记下的是试听段长度(30 / 60s);按它算「听满一半」,试听 30 秒就会被记成一次收听。只认刚换算过的
// 这一首、且会话时长正好是它的试听段长度、这一拍已是整首 —— 别的时长跳变(换曲预载窗口里拼进来的
// 下一首时长)一概不碰。
func sodaPreviewSessionBackfill(bundle, artist, title string, sessDur, curDur float64) bool {
	if bundle != sodaMusicBundleID {
		return false
	}
	sodaPreviewAppliedMu.Lock()
	key, p := sodaPreviewAppliedKey, sodaPreviewAppliedP
	sodaPreviewAppliedMu.Unlock()
	if key == "" || key != normLoose(artist)+"|"+normLoose(title) {
		return false
	}
	return math.Abs(sessDur-p.DurSecs) <= sodaPreviewDurationTolerance && math.Abs(curDur-p.FullSecs) < 0.5
}

// sodaPreviewLookupPending 判这首歌的试听段是不是还在后台搜。在搜的时候先别按试听段时长去解析歌词
// (见 poller 的 SodaPreviewPending):按 30s 去比缓存里几分钟的曲长,会另开一个「时长变体」重新
// 解析,挑出来的多半是凑数的歌词,还留在缓存里。
func sodaPreviewLookupPending(artist, title string) bool {
	sodaPreviewMu.Lock()
	defer sodaPreviewMu.Unlock()
	return sodaPreviewInflight[normLoose(artist)+"|"+normLoose(title)]
}

// applySodaPreview 在原始载荷上做换算:时长换成整首,位置(含 elapsedTimeNow)加上试听段起点。
// 只动汽水的载荷。返回是否换算了;没换算时 pending 表示试听段还在后台搜。
func applySodaPreview(raw *mediaControlRawState) (applied, pending bool) {
	if raw.BundleID != sodaMusicBundleID {
		return false, false
	}
	title, artist := cleanMediaTag(raw.Title), cleanMediaTag(raw.Artist)
	bundle, rawTitle, rawArtist := raw.BundleID, raw.Title, raw.Artist
	p, ok := sodaPreviewFor(artist, title, cleanMediaTag(raw.Album), raw.Duration, func(found sodaPreview) {
		publishPlayerPreviewFix(bundle, rawTitle, rawArtist, found)
	})
	if !ok {
		return false, sodaPreviewLookupPending(artist, title)
	}
	raw.Duration = p.FullSecs
	raw.ElapsedTime += p.StartSecs
	if raw.ElapsedTimeNow > 0 {
		raw.ElapsedTimeNow += p.StartSecs
	}
	sodaPreviewAppliedMu.Lock()
	sodaPreviewAppliedKey, sodaPreviewAppliedP = normLoose(artist)+"|"+normLoose(title), p
	sodaPreviewAppliedMu.Unlock()
	publishPlayerPreviewFix(raw.BundleID, raw.Title, raw.Artist, p)
	return true, false
}
