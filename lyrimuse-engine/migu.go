package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// miguLyric 是歌词第九个候选来源(咪咕音乐,非官方接口:搜索→按元数据校验重排→并发拉
// 前几条歌词→挑第一份真同步的;选中的那条带 trcUrl 就再拉一份中文译文)。接口契约
// 用 curl 实测过两个端点:`pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do`
// 搜歌(带 `User-Agent` + `Referer: https://m.music.migu.cn/` 即可,不需要签名/登录),
// 结果里每条直接给 `lyricUrl`(逐行 LRC 文件)和可选的 `trcUrl`(同一时间轴的中文译文
// LRC,外语歌才有)——取词不用再多打一次接口,比酷我少一跳。
//
// 跟酷我(kuwo.go)最大的不同是**搜索排序基本可信**:同一批探测曲(周杰伦《稻香》、
// 梦然《少年》)原版录音室版本都排第一,Live/Remix 版在后。所以这里不像 kuwo 那样"完全
// 不信排序、按时长重新打分"——搜索结果里也没有时长字段可打——只套一遍跟别的源同一套
// 身份闸(lyricTitleAccepted / lyricSourceArtistMatches / versionTagsMismatch)淘汰不对
// 的,通过的保持咪咕原有顺序,取前几条并发拉词、按名次挑第一份真同步的。身份闸的必要性:
// 搜《稻香》第 4 条是 "周杰伦 - 稻香 / 稳重的牧牛铃"(用户上传的翻唱),歌手字段就不是
// 周杰伦,身份闸能直接挡掉。
//
// LRC 文件本身有两处咪咕特有的形状:① 前四行是挂着 00:01～00:04
// 真时间戳的元数据行——"歌曲名 稻香 / 歌手名 周杰伦 / 作词：… / 作曲：…",不剥掉的话
// 开头几秒会显示成歌词;前两行没有冒号,现有 creditLineRe / genericHanCreditLineRe
// 都认不出来,所以在 miguStripMetaLines 里专门剥(作词/作曲那两行跟别的源一样留给
// 下游既有的署名处理);② 译文 LRC 顶着同一套元数据头,同样要剥。
//
// 搜索结果没有时长字段,时长用恒定码率 MP3 的文件大小估(miguSearchItem.durationSecs):通过身份闸的候选里
// 时长对得上的排前面(sourceDurationFits,同酷狗 / QQ),选中那条的时长交给打分层。`albums` 对不少曲目为空,
// 专辑参与身份闸时按空处理。逐字轨来自
// 搜索结果里的 `mrcurl`(加密的 MRC 文件),只给选中的那一条拉,解密与转换见 migumrc.go。
//
// 合规提醒:这是网页/客户端接口、非公开 API 文档,"可能随时失效、要求验证码或发生变更"
// ——跟 kuwo.go / musixmatch.go 同一类风险,不是新引入一种风险类别。healthcheck 走
// enabledLyricSourceNames()(见 enrich.go lyricSourceNames),接进去自动被覆盖。
type miguResult struct {
	lyrics, tr, title, artist, album string
	// yrc:MRC 解出的逐字轨(migumrc.go),没有 mrcurl 或解不开就是空串。
	yrc string
	// cover:搜索结果自带 imgItems(三档尺寸),不用再多发请求——见 miguCoverURL。拿不到
	// 就留空,交给 enrich.go 的 coverOrFallback 退到 Apple 封面。
	cover string
	// durationSecs:选中那条估出来的时长(秒),0 = 估不出来。见 miguSearchItem.durationSecs。
	durationSecs float64
	// plainOnly:选中的那条只有纯文本、没有时间戳,lyrics 装的就是纯文本。语义同
	// deezerResult.plainOnly:分数恒 -1,只有用户在弹窗里手点才采用;这时不带译文和逐字轨。
	plainOnly bool
}

var (
	miguMu    sync.Mutex
	miguCache = map[string]miguResult{}
)

func miguLyric(ctx context.Context, artist, title, album string, durationSecs float64) miguResult {
	if title == "" {
		return miguResult{}
	}
	// 时长进键:挑选按时长排序,按别名认还要求时长已知(miguAliasCandidate),同一首歌换一个时长结果可能不同。
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(durationSecs))
	miguMu.Lock()
	if v, ok := miguCache[key]; ok {
		miguMu.Unlock()
		return v
	}
	miguMu.Unlock()

	ctx, sub := withLyricSubFetch(ctx)
	r := resolveMiguLyric(ctx, artist, title, album, durationSecs)
	// 译文、逐字哪一趟没问成的不缓存,见 lyricsubfetch.go。
	if r.lyrics != "" && sub.complete(ctx) {
		miguMu.Lock()
		miguCache[key] = r
		miguMu.Unlock()
	}
	return r
}

// miguSearchItem 只挑了搜索响应 songResultData.result[] 里用得上的字段(实测
// 响应结构核实过)。
type miguSearchItem struct {
	Name        string `json:"name"`
	CopyrightID string `json:"copyrightId"`
	LyricURL    string `json:"lyricUrl"` // 逐行 LRC 文件的直链;为空 = 这条没有歌词
	TrcURL      string `json:"trcUrl"`   // 中文译文 LRC 的直链;外语歌才有,多数为空
	MrcURL      string `json:"mrcurl"`   // 逐字歌词(加密 MRC)的直链;没有逐字时为空
	Singers     []struct {
		Name string `json:"name"`
	} `json:"singers"`
	Albums []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"albums"` // 经常缺失
	ImgItems []miguImgItem `json:"imgItems"`
	// RateFormats / NewRateFormats:各档音质的文件信息,只用来估时长(durationSecs)。
	RateFormats    []miguRateFormat `json:"rateFormats"`
	NewRateFormats []miguRateFormat `json:"newRateFormats"`
	// SongAliasName / TranslateName:这首歌的别名(多个用「、」隔开,常是英文名或拼音)与译名,只给 miguAliasCandidate 用。
	SongAliasName string `json:"songAliasName"`
	TranslateName string `json:"translateName"`
	// duration:备用搜索(miguJadeiteSearch)那边直接给的时长(秒);search_all.do 的结果没有,为 0。
	duration float64
}

// aliasNames:SongAliasName 与 TranslateName 按「、」拆开后的各个写法。
func (it miguSearchItem) aliasNames() []string {
	var out []string
	for _, s := range []string{it.SongAliasName, it.TranslateName} {
		for _, a := range strings.Split(s, "、") {
			if a = strings.TrimSpace(a); a != "" {
				out = append(out, a)
			}
		}
	}
	return out
}

type miguRateFormat struct {
	Format   string `json:"format"`
	Size     string `json:"size"`
	FileType string `json:"fileType"`
}

// miguMP3Kbps:恒定码率 MP3 的格式码 → 码率(kbps)。PQ 020007 = 128k、HQ 020010 = 320k、LQ 000019 = 64k,按这个顺序取。
var miguMP3Kbps = []struct {
	format string
	kbps   float64
}{{"020007", 128}, {"020010", 320}, {"000019", 64}}

// durationSecs 估这条录音的时长:恒定码率 MP3 的文件大小 × 8 ÷ 码率(三档算出来彼此一致,跟实际时长差零点几秒);
// 没有 MP3 档时用备用搜索给的 duration,都没有是 0。见 09 章决策 140。
func (it miguSearchItem) durationSecs() float64 {
	for _, k := range miguMP3Kbps {
		for _, list := range [][]miguRateFormat{it.NewRateFormats, it.RateFormats} {
			for _, f := range list {
				if f.Format != k.format || !strings.EqualFold(f.FileType, "mp3") {
					continue
				}
				if n, err := strconv.ParseFloat(f.Size, 64); err == nil && n > 0 {
					return n * 8 / (k.kbps * 1000)
				}
			}
		}
	}
	return it.duration
}

type miguImgItem struct {
	Img         string `json:"img"`
	ImgSizeType string `json:"imgSizeType"` // "01"/"02"/"03",数字越大图越大
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

func (it miguSearchItem) albumID() string {
	if len(it.Albums) == 0 {
		return ""
	}
	return strings.TrimSpace(it.Albums[0].ID)
}

// miguCoverURL 从 imgItems 里挑最大的一档("03"),没有就退到最后一条非空的。纯函数,
// 便于单测。
func miguCoverURL(it miguSearchItem) string {
	return miguPickImg(it.ImgItems)
}

func miguPickImg(items []miguImgItem) string {
	best := ""
	for _, img := range items {
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

// miguSearchQueries:咪咕的搜索词,按顺序试,前一个挑不出候选才用下一个。「歌手 歌名」一起搜时咪咕优先排这位
// 歌手的热门歌,歌名比较普通、又是新歌时,这首会被挤出前 20 条(Ariana Grande《oh well》:「Ariana Grande
// oh well」20 条全是她的旧歌,单搜「oh well」第二条就是它),所以再补一次只用歌名。补搜的结果照样过
// miguCandidateScore 的歌名 / 歌手 / 专辑闸。见 09 章决策 127。
func miguSearchQueries(artist, title string) []string {
	// 搜索词里歌名带编号时去掉带编号的那几层,见 lyricQueryTitle。
	title = strings.TrimSpace(lyricQueryTitle(title))
	combined := strings.TrimSpace(artist + " " + title)
	if combined == title || title == "" {
		return []string{combined}
	}
	return []string{combined, title}
}

// miguSearchQuery 按 miguSearchHosts 逐个主机问 search_all.do;都没问成(而且不是调用方取消)再问另一套搜索服务
// miguJadeiteSearch。
func miguSearchQuery(ctx context.Context, q string) ([]miguSearchItem, error) {
	var items []miguSearchItem
	err := tryEach(ctx, miguSearchHosts, func(host string) error {
		got, err := miguSearchAt(ctx, host, q)
		if err == nil {
			items = got
		}
		return err
	})
	if err != nil && ctx.Err() == nil {
		if got, jerr := miguJadeiteSearch(ctx, q); jerr == nil {
			return got, nil
		}
	}
	return items, err
}

// miguSearchAt 问一台主机的搜索端点。searchSwitch 只开 song 一类,pageSize=10——身份闸淘汰后剩下
// 的够挑;isCorrect=1 让咪咕自己纠一次错别字(实测不影响原版排第一)。
func miguSearchAt(ctx context.Context, host, q string) ([]miguSearchItem, error) {
	u := "https://" + host + "/MIGUM2.0/v1.0/content/search_all.do?text=" + neturl.QueryEscape(q) +
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
		// 查无结果时 code 仍是 000000(实测),别的值是服务端拒绝。
		reportEndpointRejected(req.URL)
		return nil, fmt.Errorf("code %s", out.Code)
	}
	reportEndpointAccepted(req.URL)
	return out.SongResultData.Result, nil
}

// miguFetchLRC 拉一份 LRC 文件(lyricUrl / trcUrl 都是这个形状):纯文本,可能带 CRLF,
// 顶着咪咕的元数据头——统一在这里归一化换行并剥头,调用方拿到的就是能直接过
// isTimedLRC 的正文。个别文件是 GBK 编码,先转成 UTF-8(decodeLyricBytes);转不了就当这份文件不可用,
// 别把非法字节存进缓存。
func miguFetchLRC(ctx context.Context, url string) (string, error) {
	body, err := miguFetchFile(ctx, url, 512<<10)
	if err != nil {
		return "", err
	}
	text, ok := decodeLyricBytes(body)
	if !ok {
		return "", fmt.Errorf("lyric file is neither UTF-8 nor GB18030")
	}
	return miguStripMetaLines(text), nil
}

// miguFetchFile 下载一份歌词文件(lrc / trc / mrc)。https 没问成(连接被重置、超时、非 200)按 http 再取一次:
// d.musicapp.migu.cn 两种协议给的是同一个文件,别的主机没有这些文件。
func miguFetchFile(ctx context.Context, url string, maxBytes int64) ([]byte, error) {
	urls := []string{url}
	if rest, ok := strings.CutPrefix(url, "https://"); ok {
		urls = append(urls, "http://"+rest)
	}
	var body []byte
	err := tryEach(ctx, urls, func(u string) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		b, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes))
		if err != nil {
			return err
		}
		body = b
		return nil
	})
	return body, err
}

// miguMetaLineRe 认咪咕 LRC 顶部那两行没有冒号的元数据——"歌曲名 稻香"/"歌手名 周杰伦"
// (偶尔也见到带冒号的写法,一并收)。只认这两个词打头:它们不可能是真歌词的开头。
// 纯文本版本开头的 "@migu music@" 水印行同样剥掉,只认整行恰好是它。
// 作词/作曲那两行不在这里剥——别的源同样带这两行,交给下游既有的署名处理,不为一个源
// 另起一套口径。
var miguMetaLineRe = regexp.MustCompile(`^(歌曲名|歌手名)(\s|[:：]|$)|^@migu music@$`)

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

// miguAliasDurationTolerance:按别名认的候选,估出的时长跟本地差多少以内才收。
const miguAliasDurationTolerance = 0.03

// miguAliasCandidate:歌名过不了闸、但别名或译名(aliasNames)有一个跟本地曲名归一相等的这一条能不能收 —— 本地是英文名
// 或拼音、咪咕登记的是中文原名(「Love Love Love」对「爱爱爱」)。别名有时挂的是别的歌(现场版的别名写着另一首的名字),
// 所以比 miguCandidateScore 严:本地时长已知、估出的时长差 miguAliasDurationTolerance 以内;歌手闸、版本闸照旧。见 09 章决策 155。
func miguAliasCandidate(item miguSearchItem, artist, title, album string, durationSecs float64) bool {
	if normLoose(title) == "" || strings.TrimSpace(item.LyricURL) == "" || !durationsWithin(item.durationSecs(), durationSecs, miguAliasDurationTolerance) {
		return false
	}
	if !lyricSourceArtistMatches(item.artistName(), artist) || versionTagsMismatch(title, album, item.Name, item.albumName()) {
		return false
	}
	for _, a := range item.aliasNames() {
		if lyricTitleSameName(a, title) {
			return true
		}
	}
	return false
}

// miguMaxCandidatesToFetch 是通过身份闸后最多并发拉歌词的候选数。咪咕排序可信、原版
// 通常就是第一条,3 条足够覆盖"第一条恰好没词/不是同步歌词"的情况,不必像酷我拉 5 条。
const miguMaxCandidatesToFetch = 3

// resolveMiguLyric:①搜索(单次请求,10 条;挑不出候选时只用歌名再搜一次,两次都挑不出时才用按别名认的,见 miguAliasCandidate);
// ②身份闸淘汰、保持原序;③取前几条**并发**拉
// LRC;④剥完头之后不是真同步的(isTimedLRC)先放一边;⑤按名次(不是"谁先拉完")挑第一份
// 同步的;⑥选中那条有 trcUrl 就再拉译文(同样剥头、同样要求同步;拉不到只是没有译文,不影响
// 正文);⑦一份同步的都没有时,按名次退回第一份纯文本(plainOnly),口径同 deezer 的纯文本回退。
func resolveMiguLyric(ctx context.Context, artist, title, album string, durationSecs float64) miguResult {
	type scoredItem struct {
		item  miguSearchItem
		score int
	}
	var candidates, aliasCandidates []scoredItem
	for _, q := range miguSearchQueries(artist, title) {
		items, err := miguSearchQuery(ctx, q)
		if err != nil {
			// 请求没成(所有备用主机都失败)就别换搜索词再打一遍:换词救不了连不上。
			break
		}
		for _, it := range items {
			if s := miguCandidateScore(it, artist, title, album); s >= 0 {
				candidates = append(candidates, scoredItem{it, s})
			} else if miguAliasCandidate(it, artist, title, album, durationSecs) {
				aliasCandidates = append(aliasCandidates, scoredItem{it, 0})
			}
		}
		if len(candidates) > 0 {
			break
		}
	}
	if len(candidates) == 0 {
		candidates = aliasCandidates
	}
	if len(candidates) == 0 {
		return miguResult{}
	}
	// 估出来的时长对不上(>12%,同打分层 sourceDurationOff)的排到对得上的后面,组内保持咪咕原有顺序。
	sort.SliceStable(candidates, func(i, j int) bool {
		fi := sourceDurationFits(durationSecs, candidates[i].item.durationSecs())
		fj := sourceDurationFits(durationSecs, candidates[j].item.durationSecs())
		if fi != fj {
			return fi
		}
		return candidates[i].score > candidates[j].score
	})
	if len(candidates) > miguMaxCandidatesToFetch {
		candidates = candidates[:miguMaxCandidatesToFetch]
	}

	type fetched struct{ lrc, plain string }
	fetchedByRank := make([]fetched, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, item miguSearchItem) {
			defer wg.Done()
			lrc, err := miguFetchLRC(ctx, item.LyricURL)
			if err != nil {
				return
			}
			if isTimedLRC(lrc) {
				fetchedByRank[rank].lrc = lrc
			} else if strings.TrimSpace(lrc) != "" {
				fetchedByRank[rank].plain = lrc
			}
		}(i, c.item)
	}
	wg.Wait()

	build := func(it miguSearchItem, lyrics string, plainOnly bool) miguResult {
		cover := miguCoverURL(it)
		if c := miguAlbumCover(ctx, it.albumID()); c != "" {
			cover = c
		}
		return miguResult{
			lyrics: lyrics, title: it.Name, artist: it.artistName(), album: it.albumName(),
			cover: cover, plainOnly: plainOnly, durationSecs: it.durationSecs(),
		}
	}
	for rank, f := range fetchedByRank {
		if f.lrc == "" {
			continue
		}
		it := candidates[rank].item
		r := build(it, f.lrc, false)
		if u := strings.TrimSpace(it.TrcURL); u != "" {
			tr, err := miguFetchLRC(ctx, u)
			if err != nil {
				noteLyricSubFetchFailure(ctx)
			} else if isTimedLRC(tr) {
				r.tr = tr
			}
		}
		r.yrc = miguFetchMRCYRC(ctx, it.MrcURL)
		return r
	}
	for rank, f := range fetchedByRank {
		if f.plain != "" {
			return build(candidates[rank].item, f.plain, true)
		}
	}
	return miguResult{}
}

// ---- 备用搜索:jadeite 的另一套搜索服务 ----
//
// 咪咕客户端现在用的搜索(jadeite.migu.cn/music_search/v3/search/searchAll),跟 search_all.do 不是同一个服务:
// search_all.do 的几个主机都没问成时才问它。请求要带客户端的签名头 —— md5(查询词 + miguJadeiteSignKey +
// miguJadeiteSignSalt + 设备号 + 毫秒时间戳),参数取自 lx-music 的咪咕源。结果的歌词地址跟 search_all.do 指向同一批
// 文件,但不给逐字(mrcurl 恒空),时长直接给(duration,秒)。实测见 09 章决策 140。

const (
	miguJadeiteURL      = "https://jadeite.migu.cn/music_search/v3/search/searchAll"
	miguJadeiteDeviceID = "963B7AA0D21511ED807EE5846EC87D20"
	miguJadeiteSignKey  = "6cdc72a439cef99a3418d2a78aa28c73"
	miguJadeiteSignSalt = "yyapp2d16148780a1dcc7408e06336b98cfd50"
	miguJadeiteSwitch   = `{"song":1,"album":0,"singer":0,"tagSong":1,"mvSong":0,"bestShow":1,"songlist":0,"lyricSong":0}`
	miguJadeiteUA       = "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"
)

// miguJadeiteSign 算签名头:md5(查询词 + 密钥 + 盐 + 设备号 + 毫秒时间戳)的十六进制小写。
func miguJadeiteSign(q, ts string) string {
	sum := md5.Sum([]byte(q + miguJadeiteSignKey + miguJadeiteSignSalt + miguJadeiteDeviceID + ts))
	return hex.EncodeToString(sum[:])
}

type miguJadeiteItem struct {
	Name       string  `json:"name"`
	Album      string  `json:"album"`
	AlbumID    string  `json:"albumId"`
	Duration   float64 `json:"duration"`
	LrcURL     string  `json:"lrcUrl"`
	TrcURL     string  `json:"trcUrl"`
	MrcURL     string  `json:"mrcurl"`
	Img3       string  `json:"img3"`
	SingerList []struct {
		Name string `json:"name"`
	} `json:"singerList"`
}

// item 换成 search_all.do 那边的形状,后面的身份闸、取词照旧走同一套。
func (j miguJadeiteItem) item() miguSearchItem {
	it := miguSearchItem{Name: j.Name, LyricURL: j.LrcURL, TrcURL: j.TrcURL, MrcURL: j.MrcURL, duration: j.Duration}
	for _, s := range j.SingerList {
		it.Singers = append(it.Singers, struct {
			Name string `json:"name"`
		}{s.Name})
	}
	if j.Album != "" || j.AlbumID != "" {
		it.Albums = append(it.Albums, struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		}{j.AlbumID, j.Album})
	}
	if strings.HasPrefix(j.Img3, "http") {
		it.ImgItems = []miguImgItem{{Img: j.Img3, ImgSizeType: "03"}}
	}
	return it
}

func miguJadeiteSearch(ctx context.Context, q string) ([]miguSearchItem, error) {
	ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
	u := miguJadeiteURL + "?isCorrect=0&isCopyright=1&searchSwitch=" + neturl.QueryEscape(miguJadeiteSwitch) +
		"&pageSize=10&text=" + neturl.QueryEscape(q) + "&pageNo=1&sort=0&sid=USS"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("uiVersion", "A_music_3.6.1")
	req.Header.Set("deviceId", miguJadeiteDeviceID)
	req.Header.Set("timestamp", ts)
	req.Header.Set("sign", miguJadeiteSign(q, ts))
	req.Header.Set("channel", "0146921")
	req.Header.Set("User-Agent", miguJadeiteUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	var out struct {
		Code           string `json:"code"`
		SongResultData struct {
			ResultList [][]miguJadeiteItem `json:"resultList"`
		} `json:"songResultData"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&out); err != nil {
		return nil, err
	}
	if out.Code != "000000" {
		reportEndpointRejected(req.URL)
		return nil, fmt.Errorf("code %s", out.Code)
	}
	reportEndpointAccepted(req.URL)
	var items []miguSearchItem
	for _, group := range out.SongResultData.ResultList {
		for _, j := range group {
			items = append(items, j.item())
		}
	}
	return items, nil
}

// ---- 专辑封面:按专辑 id 另问一次 ----
//
// 搜索结果里每首歌自带的 imgItems 是**这段录音最早所在那张专辑**的图,而 albums[0] 写的是这一条
// 实际所属的专辑 —— 精选集、合辑里两者对不上。实测「陶喆 - 飞机场的10:30」那条专辑写的是
// 「Ultrasound 乐之路 1997-2003」,图却是 1997 年首张专辑《David Tao》的蓝色封面;同一张精选集里
// 的「天天 (2003 Version)」「飞机场的10:30 (原始试听版)」配的又是精选集自己的封面。封面挂在专辑名
// 旁边展示、也会被当成这张专辑的封面存下来,所以按 albums[0].id 取专辑自己的那张。
//
// 只给**选中的那一条**问(一首歌一次),按专辑 id 缓存;问不到就退回歌曲自带的图,不比原来差。

const miguAlbumInfoPath = "/MIGUM2.0/v1.0/content/resourceinfo.do"

var (
	miguAlbumCoverMu    sync.Mutex
	miguAlbumCoverCache = map[string]string{} // 专辑 id → 封面地址(只存取到了的)
)

func miguAlbumCover(ctx context.Context, albumID string) string {
	if albumID == "" {
		return ""
	}
	miguAlbumCoverMu.Lock()
	if v, ok := miguAlbumCoverCache[albumID]; ok {
		miguAlbumCoverMu.Unlock()
		return v
	}
	miguAlbumCoverMu.Unlock()

	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	var body []byte
	_ = tryEach(ctx, miguAlbumHosts, func(host string) error {
		b, err := miguAlbumInfoAt(ctx, host, albumID)
		if err == nil {
			body = b
		}
		return err
	})
	if body == nil {
		return ""
	}
	cover := miguParseAlbumCover(body, albumID)
	if cover != "" {
		miguAlbumCoverMu.Lock()
		miguAlbumCoverCache[albumID] = cover
		miguAlbumCoverMu.Unlock()
	}
	return cover
}

// miguAlbumInfoAt 取一个主机上的专辑信息响应体;err 非 nil 是没问成。
func miguAlbumInfoAt(ctx context.Context, host, albumID string) ([]byte, error) {
	u := "https://" + host + miguAlbumInfoPath + "?needSimple=00&resourceType=2003&resourceId=" + neturl.QueryEscape(albumID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://m.music.migu.cn/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(4*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

// miguParseAlbumCover 从专辑信息响应里取封面。返回的资源必须是专辑(resourceType 2003)、而且就是要的那张。
func miguParseAlbumCover(body []byte, albumID string) string {
	var data struct {
		Code     string `json:"code"`
		Resource []struct {
			ResourceType string        `json:"resourceType"`
			AlbumID      string        `json:"albumId"`
			ImgItems     []miguImgItem `json:"imgItems"`
		} `json:"resource"`
	}
	if err := json.Unmarshal(body, &data); err != nil || data.Code != "000000" {
		return ""
	}
	for _, r := range data.Resource {
		if r.ResourceType != "2003" || (r.AlbumID != "" && r.AlbumID != albumID) {
			continue
		}
		if c := miguPickImg(r.ImgItems); c != "" {
			return c
		}
	}
	return ""
}
