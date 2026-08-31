// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// kuwoLyric 是歌词第八个候选来源(酷我音乐,非官方接口:搜索→按元数据重新打分排序→
// 并发拉前几条歌词→挑第一份真同步的)。接口契约从一份公开的第三方开源实现
// 逆向出来,2026-08-31 用 curl 实测两个端点全部验证过——
// 不是照抄一份没验证过的第三方代码,是照抄一份**验证过真能用**的接口契约。
//
// ⚠️ 这个源的搜索排序完全不可信,这是接入前实测坐实的,不是猜测:兰亭序/周杰伦、
// 海阔天空/BEYOND、起风了/买辣椒也用券、平凡之路/朴树 四首歌各跑一遍,**原版录音室
// 版本一次都没进 top10**,返回的全是 DJ 版/翻唱/Live 片段/伴奏/用户上传。排除过两个
// 容易走偏的解释:① rn 从 10 提到 30 没用(周杰伦国内是 QQ 音乐独占,酷我曲库本来就
// 没有原版);② 不是地理限制(美国出口/香港出口各打一次,TOTAL 和 top3 完全一致)。
// 所以不能像 kugou/lrclib 那样"搜到第一条通过身份校验的就收工"——必须先给全部候选
// 按标题/歌手/时长重新打分排序(kuwoCandidateScore),再挑分数最高的几条**并发**拉
// 歌词,第一份真的带同步时间戳的才采纳。按这套流程实测的产出率:海阔天空 5 中 4、
// 平凡之路 5 中 3、起风了 5 中 1——"有歌词"跟"是对的那首歌词"是两件事,能不能真的
// 采纳最终仍由 enrich.go 的 scoreLyricCandidateDetailed 把关,这里只负责"尽力挑一份
// 靠谱候选给下游"。
//
// 只有逐行 LRC,没有逐字/YRC,也没有社区译文——酷我的 lyric 接口只回 {time,
// lineLyric},没有别的字段可挖。定位跟 amll/lyricfind 一样,是覆盖率有限的"锦上添花"
// 兜底档,不是主力源,建议排在 lyricsSourceDefaultOrder 末尾(见 features.go)。
//
// 合规提醒(2026-08-31):`search.kuwo.cn/r.s` 和 `kuwo.cn/openapi/...` 都是网页端
// 接口、非公开 API 文档,这类接口"可能随时失效、
// 要求验证码或发生变更"——跟 musixmatch.go/amllttml.go 是同一类风险,不是新引入
// 一种风险类别。healthcheck 走的是 enabledLyricSourceNames()(见 enrich.go
// lyricSourceNames),这个源接进去之后会被健康检查自动覆盖,不需要单独接线。
type kuwoResult struct {
	lyrics, title, artist, album string
	// durationSecs:酷我搜索结果自报的这首歌时长(秒),0=没给/解析不动。透传用,
	// 见 lyricCandidate.sourceReportedDurationSecs。
	durationSecs float64
	// cover:2026-08-31 加。搜索结果自带 web_albumpic_short,不用像 kugou 那样再多发
	// 一次请求——见 kuwoCoverURL。拿不到就留空,交给 enrich.go 的 coverOrFallback
	// 退到 Apple 封面。
	cover string
}

var (
	kuwoMu    sync.Mutex
	kuwoCache = map[string]kuwoResult{}
)

func kuwoLyric(ctx context.Context, artist, title, album string, durationSecs float64) kuwoResult {
	if title == "" {
		return kuwoResult{}
	}
	key := artist + "|" + title + "|" + album
	kuwoMu.Lock()
	if v, ok := kuwoCache[key]; ok {
		kuwoMu.Unlock()
		return v
	}
	kuwoMu.Unlock()

	r := resolveKuwoLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" {
		kuwoMu.Lock()
		kuwoCache[key] = r
		kuwoMu.Unlock()
	}
	return r
}

// kuwoSearchItem 只挑了搜索响应里用得上的字段(2026-08-31 实测响应结构核实过)。
type kuwoSearchItem struct {
	MusicRID string `json:"MUSICRID"` // 形如 "MUSIC_150350148",取 '_' 之后作 musicId
	SongName string `json:"SONGNAME"`
	Artist   string `json:"ARTIST"`
	Album    string `json:"ALBUM"`    // 经常为空串
	Duration string `json:"DURATION"` // 字符串秒数,偶尔是 "m:ss"(见 kuwoDurationSecs)
	// WebAlbumPicShort:2026-08-31 实测坐实的封面字段,形如 "120/38/70/3416909732.jpg"——
	// 首段是尺寸,见 kuwoCoverURL。
	WebAlbumPicShort string `json:"web_albumpic_short"`
}

// kuwoCoverURL 把搜索结果自带的 web_albumpic_short(形如
// "120/38/70/3416909732.jpg",首段是像素尺寸)拼成能直接访问的封面 URL,顺手把首段
// 换成 500 拿大图(2026-08-31 实测 200/500 都能 200)。拿不到就返回空串,不是错误。
func kuwoCoverURL(short string) string {
	short = strings.TrimSpace(short)
	if short == "" {
		return ""
	}
	if parts := strings.SplitN(short, "/", 2); len(parts) == 2 {
		short = "500/" + parts[1]
	}
	return "https://img1.kuwo.cn/star/albumcover/" + short
}

// kuwoSearch 请求搜索端点(Referer 必须是 www.kuwo.cn,跟歌词端点的 Referer 不同,
// 见 kuwoFetchLyric 那边——2026-08-31 实测坐实,写错会被拒)。
func kuwoSearch(ctx context.Context, artist, title string) ([]kuwoSearchItem, error) {
	q := strings.TrimSpace(title + " " + artist)
	u := "https://search.kuwo.cn/r.s?all=" + neturl.QueryEscape(q) +
		"&ft=music&itemset=web_2013&client=kt&pn=0&rn=10&rformat=json&encoding=utf8&pcjson=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://www.kuwo.cn/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Abslist []kuwoSearchItem `json:"abslist"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Abslist, nil
}

// kuwoMusicID 从 "MUSIC_150350148" 这种 MUSICRID 里取出 '_' 之后的数字部分,拿不到
// 返回空串。纯函数,便于单测。
func kuwoMusicID(rid string) string {
	idx := strings.LastIndex(rid, "_")
	if idx < 0 || idx == len(rid)-1 {
		return ""
	}
	return rid[idx+1:]
}

// kuwoDurationSecs 解析酷我搜索结果的 DURATION 字段——绝大多数是纯秒数字符串,
// 2026-08-31 交接文档提到偶尔可能是 "m:ss",两种都兼容,解析不动返回 0
// (0 = 该项不参与打分,跟别的源自报时长的约定一致)。纯函数,便于单测。
func kuwoDurationSecs(s string) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if v, err := strconv.ParseFloat(s, 64); err == nil && v >= 0 {
		return v
	}
	parts := strings.Split(s, ":")
	if len(parts) != 2 {
		return 0
	}
	m, errM := strconv.Atoi(parts[0])
	sec, errS := strconv.ParseFloat(parts[1], 64)
	if errM != nil || errS != nil || m < 0 || sec < 0 {
		return 0
	}
	return float64(m)*60 + sec
}

// kuwoLyricLine 是歌词响应 data.lrclist 数组的一个元素。
type kuwoLyricLine struct {
	Time      string `json:"time"`      // 秒数字符串,如 "9.28"
	LineLyric string `json:"lineLyric"` // 这一行歌词正文
}

// kuwoFetchLyric 请求歌词端点(Referer 必须是 kuwo.cn,不是 www.kuwo.cn——两个端点
// 各自要求不同的 Referer,写死同一个会被其中一个拒掉,2026-08-31 实测坐实)。
// lrclist 可能是空数组(纯音乐/伴奏/无歌词),这种情况 HTTP 状态码仍是 200、`code`
// 字段仍是 200,不是错误,调用方按"空列表"处理即可,不需要单独判 code。
func kuwoFetchLyric(ctx context.Context, musicID string) ([]kuwoLyricLine, error) {
	u := "https://kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=" + neturl.QueryEscape(musicID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://kuwo.cn/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Data struct {
			LrcList []kuwoLyricLine `json:"lrclist"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Data.LrcList, nil
}

// kuwoNormalizeTime 把"秒数字符串"(如 "9.28")转成标准 LRC 的 "mm:ss.xx"——照抄
// 第三方实现的 normalize_time 算法(交接文档第 2 节),第二个返回值标"这一行是否
// 解析成功",解析不动的行由调用方跳过、不拼进 LRC(时间戳缺失/乱码的行留在 LRC 里
// 只会破坏后续行的时间轴,不如直接丢弃这一行,损失的只是那一行文字)。纯函数,
// 便于单测。
func kuwoNormalizeTime(raw string) (string, bool) {
	s, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil {
		return "", false
	}
	if s < 0 {
		s = 0
	}
	return fmt.Sprintf("%02d:%05.2f", int(s/60), math.Mod(s, 60)), true
}

// kuwoBuildLRC 把歌词行数组拼成标准逐行 LRC 文本。跳过时间戳解析不动、或者去空白后
// 正文为空的行(交接文档第 2 节)。纯函数,便于单测。
func kuwoBuildLRC(lines []kuwoLyricLine) string {
	var b strings.Builder
	for _, l := range lines {
		ts, ok := kuwoNormalizeTime(l.Time)
		if !ok {
			continue
		}
		text := strings.TrimSpace(l.LineLyric)
		if text == "" {
			continue
		}
		b.WriteString("[" + ts + "]" + text + "\n")
	}
	return b.String()
}

// kuwoScoreDurationTolerance 跟别的源的时长闸门(match.go 的 0.25)取同一个值。
const kuwoScoreDurationTolerance = 0.25

// kuwoCandidateScore 给一条搜索结果打分,分数越高越像本地这首歌;返回负数表示直接
// 淘汰(不进后续候选)。**必须自己重新排序**,不能信酷我搜索接口自己给的顺序——见
// 文件头注"搜索排序完全不可信"那段实测。曲名/歌手用跟别的源完全一致的判定函数
// (lyricTitleAccepted/lyricSourceArtistMatches/versionTagsMismatch),不为这一个源
// 另起一套更松的规则。纯函数,便于单测。
func kuwoCandidateScore(item kuwoSearchItem, artist, title, album string, durationSecs float64) int {
	if !lyricTitleAccepted(item.SongName, title) {
		return -1
	}
	if !lyricSourceArtistMatches(item.Artist, artist) {
		return -1
	}
	if versionTagsMismatch(title, album, item.SongName, item.Album) {
		return -1
	}
	score := 100
	if durationSecs > 0 {
		d := kuwoDurationSecs(item.Duration)
		if d <= 0 {
			return score // 时长未知,没法比对,不额外加分也不扣分
		}
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > kuwoScoreDurationTolerance {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// kuwoMaxCandidatesToFetch 是通过身份校验后最多并发拉歌词的候选数——交接文档建议
// "取前 5 条并发拉",不是全部 10 条都拉:身份校验已经淘汰了明显不对的,剩下的候选里
// "有没有真同步歌词"才是筛不掉的那道门,拉太多条只是白耗网络,5 条足够覆盖实测产出率
// (海阔天空 5 中 4、平凡之路 5 中 3)。
const kuwoMaxCandidatesToFetch = 5

// resolveKuwoLyric:①搜索(单次请求,10 条原始结果);②按元数据重新打分排序、淘汰
// 身份对不上的;③取分数最高的几条**并发**拉歌词;④丢弃 lrclist 为空的、丢弃解析后
// 非同步的(isTimedLRC);⑤按候选原本的分数名次(不是"谁先拉完")挑第一份真同步的
// 采纳——"有歌词"不等于"是对的那首"(见文件头注),分数更高的候选应该优先采纳,不能
// 让网络响应的先后顺序偷偷决定结果。
func resolveKuwoLyric(ctx context.Context, artist, title, album string, durationSecs float64) kuwoResult {
	items, err := kuwoSearch(ctx, artist, title)
	if err != nil || len(items) == 0 {
		return kuwoResult{}
	}

	type scoredItem struct {
		item  kuwoSearchItem
		score int
	}
	var candidates []scoredItem
	for _, it := range items {
		if it.MusicRID == "" {
			continue
		}
		if s := kuwoCandidateScore(it, artist, title, album, durationSecs); s >= 0 {
			candidates = append(candidates, scoredItem{it, s})
		}
	}
	if len(candidates) == 0 {
		return kuwoResult{}
	}
	// 稳定排序:分数相同时保留搜索结果原有的先后顺序,不引入运行间的随机性。
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > kuwoMaxCandidatesToFetch {
		candidates = candidates[:kuwoMaxCandidatesToFetch]
	}

	type fetched struct {
		lrc string
		it  kuwoSearchItem
	}
	fetchedByRank := make([]*fetched, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, item kuwoSearchItem) {
			defer wg.Done()
			musicID := kuwoMusicID(item.MusicRID)
			if musicID == "" {
				return
			}
			lines, err := kuwoFetchLyric(ctx, musicID)
			if err != nil || len(lines) == 0 {
				return // lrclist 为空(纯音乐/伴奏/无歌词)——丢弃,见文件头注
			}
			lrc := kuwoBuildLRC(lines)
			if !isTimedLRC(lrc) {
				return // 解析后不是真同步的——丢弃,见文件头注
			}
			fetchedByRank[rank] = &fetched{lrc: lrc, it: item}
		}(i, c.item)
	}
	wg.Wait()

	// 按分数名次(rank 从 0 开始,分数已从高到低排过)挑第一个真的拿到同步歌词的,
	// 不是"谁先拉完网络请求"——并发只是为了不串行等 5 次网络往返,采纳顺序仍然由
	// 打分结果决定。
	for _, f := range fetchedByRank {
		if f == nil {
			continue
		}
		return kuwoResult{
			lyrics: f.lrc, title: f.it.SongName, artist: f.it.Artist, album: f.it.Album,
			durationSecs: kuwoDurationSecs(f.it.Duration), cover: kuwoCoverURL(f.it.WebAlbumPicShort),
		}
	}
	return kuwoResult{}
}
