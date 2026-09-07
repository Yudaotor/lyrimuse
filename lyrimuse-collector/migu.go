// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"encoding/json"
)

// miguLyric 是歌词第九个候选来源(咪咕音乐,非官方接口:搜索→按元数据校验重排→并发拉
// 前几条歌词→挑第一份真同步的;选中的那条带 trcUrl 就再拉一份中文译文)。接口契约
// 2026-09-04 用 curl 实测过两个端点:`pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do`
// 搜歌(带 `User-Agent` + `Referer: https://m.music.migu.cn/` 即可,不需要签名/登录),
// 结果里每条直接给 `lyricUrl`(逐行 LRC 文件)和可选的 `trcUrl`(同一时间轴的中文译文
// LRC,外语歌才有)——取词不用再多打一次接口,比酷我少一跳。
//
// 跟酷我(kuwo.go)最大的不同是**搜索排序基本可信**:同一批探测曲(周杰伦《稻香》、
// 梦然《少年》)原版录音室版本都排第一,Live/Remix 版在后。所以这里不像 kuwo 那样"完全
// 不信排序、按时长重新打分"——搜索结果里也没有时长字段可打——只套一遍跟别的源同一套
// 身份闸(lyricTitleAccepted / lyricSourceArtistMatches / versionTagsMismatch)淘汰不对
// 的,通过的保持咪咕原有顺序,取前几条并发拉词、按名次挑第一份真同步的。淘汰的必要性
// 实测坐实:搜《稻香》第 4 条是 "周杰伦 - 稻香 / 稳重的牧牛铃"(用户上传的翻唱),歌手
// 字段就不是周杰伦,身份闸能直接挡掉。
//
// LRC 文件本身有两处咪咕特有的形状(2026-09-04 实测):① 前四行是挂着 00:01～00:04
// 真时间戳的元数据行——"歌曲名 稻香 / 歌手名 周杰伦 / 作词：… / 作曲：…",不剥掉的话
// 开头几秒会显示成歌词;前两行没有冒号,现有 creditLineRe / genericHanCreditLineRe
// 都认不出来,所以在 miguStripMetaLines 里专门剥(作词/作曲那两行跟别的源一样留给
// 下游既有的署名处理);② 译文 LRC 顶着同一套元数据头,同样要剥。
//
// 没有时长字段(搜索结果只有码率/文件大小),sourceReportedDurationSecs 留 0 = 该项不
// 参与打分,跟 amll 一样;`albums` 对不少曲目为空,专辑参与身份闸时按空处理。只有逐行,
// 没有逐字(`mrcurl` 字段存在但实测样本里都是空的,格式也是加密的,先不碰)。
//
// 合规提醒:这是网页/客户端接口、非公开 API 文档,"可能随时失效、要求验证码或发生变更"
// ——跟 kuwo.go / musixmatch.go 同一类风险,不是新引入一种风险类别。healthcheck 走
// enabledLyricSourceNames()(见 enrich.go lyricSourceNames),接进去自动被覆盖。
type miguResult struct {
	lyrics, tr, title, artist, album string
	// cover:搜索结果自带 imgItems(三档尺寸),不用再多发请求——见 miguCoverURL。拿不到
	// 就留空,交给 enrich.go 的 coverOrFallback 退到 Apple 封面。
	cover string
}

var (
	miguMu    sync.Mutex
	miguCache = map[string]miguResult{}
)

func miguLyric(ctx context.Context, artist, title, album string, durationSecs float64) miguResult {
	if title == "" {
		return miguResult{}
	}
	key := artist + "|" + title + "|" + album
	miguMu.Lock()
	if v, ok := miguCache[key]; ok {
		miguMu.Unlock()
		return v
	}
	miguMu.Unlock()

	r := resolveMiguLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" {
		miguMu.Lock()
		miguCache[key] = r
		miguMu.Unlock()
	}
	return r
}

// miguSearchItem 只挑了搜索响应 songResultData.result[] 里用得上的字段(2026-09-04 实测
// 响应结构核实过)。
type miguSearchItem struct {
	Name        string `json:"name"`
	CopyrightID string `json:"copyrightId"`
	LyricURL    string `json:"lyricUrl"` // 逐行 LRC 文件的直链;为空 = 这条没有歌词
	TrcURL      string `json:"trcUrl"`   // 中文译文 LRC 的直链;外语歌才有,多数为空
	Singers     []struct {
		Name string `json:"name"`
	} `json:"singers"`
	Albums []struct {
		Name string `json:"name"`
	} `json:"albums"` // 经常缺失
	ImgItems []struct {
		Img         string `json:"img"`
		ImgSizeType string `json:"imgSizeType"` // "01"/"02"/"03",数字越大图越大
	} `json:"imgItems"`
}

// artistName 把多个演唱者拼成一个字符串——身份闸 lyricSourceArtistMatches 自己会处理
// 分隔符与多歌手的情形,这里只负责给它一个跟别的源同形状的输入。
func (it miguSearchItem) artistName() string {
	names := make([]string, 0, len(it.Singers))
	for _, s := range it.Singers {
		if n := strings.TrimSpace(s.Name); n != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, "/")
}

func (it miguSearchItem) albumName() string {
	if len(it.Albums) == 0 {
		return ""
	}
	return strings.TrimSpace(it.Albums[0].Name)
}

// miguCoverURL 从 imgItems 里挑最大的一档("03"),没有就退到最后一条非空的。纯函数,
// 便于单测。
func miguCoverURL(it miguSearchItem) string {
	best := ""
	for _, img := range it.ImgItems {
		u := strings.TrimSpace(img.Img)
		if u == "" {
			continue
		}
		if img.ImgSizeType == "03" {
			return u
		}
		best = u
	}
	return best
}

// miguSearch 请求搜索端点。searchSwitch 只开 song 一类,pageSize=10——身份闸淘汰后剩下
// 的够挑;isCorrect=1 让咪咕自己纠一次错别字(实测不影响原版排第一)。
func miguSearch(ctx context.Context, artist, title string) ([]miguSearchItem, error) {
	q := strings.TrimSpace(artist + " " + title)
	u := "https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do?text=" + neturl.QueryEscape(q) +
		"&pageNo=1&pageSize=10&searchSwitch=" + neturl.QueryEscape(`{"song":1}`) + "&isCorrect=1"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://m.music.migu.cn/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Code           string `json:"code"` // "000000" = 成功
		SongResultData struct {
			Result []miguSearchItem `json:"result"`
		} `json:"songResultData"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&out); err != nil {
		return nil, err
	}
	if out.Code != "" && out.Code != "000000" {
		return nil, fmt.Errorf("code %s", out.Code)
	}
	return out.SongResultData.Result, nil
}

// miguFetchLRC 拉一份 LRC 文件(lyricUrl / trcUrl 都是这个形状):纯文本,可能带 CRLF,
// 顶着咪咕的元数据头——统一在这里归一化换行并剥头,调用方拿到的就是能直接过
// isTimedLRC 的正文。
func miguFetchLRC(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 512<<10))
	if err != nil {
		return "", err
	}
	return miguStripMetaLines(string(body)), nil
}

// miguMetaLineRe 认咪咕 LRC 顶部那两行没有冒号的元数据——"歌曲名 稻香"/"歌手名 周杰伦"
// (偶尔也见到带冒号的写法,一并收)。只认这两个词打头:它们不可能是真歌词的开头。
// 作词/作曲那两行不在这里剥——别的源同样带这两行,交给下游既有的署名处理,不为一个源
// 另起一套口径。
var miguMetaLineRe = regexp.MustCompile(`^(歌曲名|歌手名)(\s|[:：]|$)`)

// miguStripMetaLines 把 CRLF 归一成 LF,剥掉元数据行和去掉时间戳后为空的行。纯函数,
// 便于单测。
func miguStripMetaLines(lrc string) string {
	lrc = strings.ReplaceAll(lrc, "\r\n", "\n")
	lrc = strings.ReplaceAll(lrc, "\r", "\n")
	var b strings.Builder
	for _, line := range strings.Split(lrc, "\n") {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" || miguMetaLineRe.MatchString(text) {
			continue
		}
		b.WriteString(strings.TrimRight(line, " \t"))
		b.WriteString("\n")
	}
	return b.String()
}

// miguCandidateScore 给一条搜索结果打分:通过身份闸 = 100,没通过 = -1(淘汰)。咪咕自己
// 的排序基本可信、结果里又没有时长字段,所以通过者一律同分,靠稳定排序保留咪咕原有顺序
// ——这跟 kuwo.go 那套"不信排序、按时长重排"刻意不同,理由见文件头注。身份闸用跟别的源
// 完全一致的判定函数,不为这一个源另起一套更松的规则。纯函数,便于单测。
func miguCandidateScore(item miguSearchItem, artist, title, album string) int {
	if strings.TrimSpace(item.LyricURL) == "" {
		return -1
	}
	if !lyricTitleAccepted(item.Name, title) {
		return -1
	}
	if !lyricSourceArtistMatches(item.artistName(), artist) {
		return -1
	}
	if versionTagsMismatch(title, album, item.Name, item.albumName()) {
		return -1
	}
	return 100
}

// miguMaxCandidatesToFetch 是通过身份闸后最多并发拉歌词的候选数。咪咕排序可信、原版
// 通常就是第一条,3 条足够覆盖"第一条恰好没词/不是同步歌词"的情况,不必像酷我拉 5 条。
const miguMaxCandidatesToFetch = 3

// resolveMiguLyric:①搜索(单次请求,10 条);②身份闸淘汰、保持原序;③取前几条**并发**拉
// LRC;④丢弃剥完头之后不是真同步的(isTimedLRC);⑤按名次(不是"谁先拉完")挑第一份;
// ⑥选中那条有 trcUrl 就再拉译文(同样剥头、同样要求同步;拉不到只是没有译文,不影响
// 正文)。
func resolveMiguLyric(ctx context.Context, artist, title, album string, _ float64) miguResult {
	items, err := miguSearch(ctx, artist, title)
	if err != nil || len(items) == 0 {
		return miguResult{}
	}

	type scoredItem struct {
		item  miguSearchItem
		score int
	}
	var candidates []scoredItem
	for _, it := range items {
		if s := miguCandidateScore(it, artist, title, album); s >= 0 {
			candidates = append(candidates, scoredItem{it, s})
		}
	}
	if len(candidates) == 0 {
		return miguResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > miguMaxCandidatesToFetch {
		candidates = candidates[:miguMaxCandidatesToFetch]
	}

	fetchedByRank := make([]string, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, item miguSearchItem) {
			defer wg.Done()
			lrc, err := miguFetchLRC(ctx, item.LyricURL)
			if err != nil || !isTimedLRC(lrc) {
				return
			}
			fetchedByRank[rank] = lrc
		}(i, c.item)
	}
	wg.Wait()

	for rank, lrc := range fetchedByRank {
		if lrc == "" {
			continue
		}
		it := candidates[rank].item
		r := miguResult{
			lyrics: lrc, title: it.Name, artist: it.artistName(), album: it.albumName(),
			cover: miguCoverURL(it),
		}
		if u := strings.TrimSpace(it.TrcURL); u != "" {
			if tr, err := miguFetchLRC(ctx, u); err == nil && isTimedLRC(tr) {
				r.tr = tr
			}
		}
		return r
	}
	return miguResult{}
}
