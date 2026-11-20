package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// zingLyric 是 Zing MP3(越南)这一路:搜索 → 按元数据重新打分排序 → 并发取前几条的歌词 → 按名次挑第一份带时间轴的。
// 接口是 zingmp3.vn 网页端的私有接口,不要账号:每个请求带 `ctime`、`version`、`apiKey` 和签名 `sig`
// (HMAC-SHA512,见 zingSign),外加一个会话 cookie `zmp3_rqid` —— 没有它一律回 err -201,而它就在那条 -201 应答的
// Set-Cookie 里,拿到再发一次即可,不用先取首页(首页对越南以外的出口 302 到 restrict.html,接口不限出口)。
//
// 取词 `/api/v2/lyric/get/lyric` 回 `sentences`(逐字:每句一组词,词带起止毫秒)和 `file`(同一份歌词的逐行 LRC,
// 放在 static-zmp3.zmdcdn.me)。逐行用 LRC 文件,逐字用 sentences,逐字跟逐行对得上才用(zingWordTrackAgrees);
// sentences 为空时只交逐行。没词的曲目和不存在的 id 都回 err 0、两样都不带,算答了没有。没有纯文本、译文、罗马音。
//
// 签名密钥藏在网页 JS 里,随网页升级可能换。几组从开源客户端收集来的密钥轮换着用(zingKeys),签名被拒
// (err -104 / -116)才换下一组;全被拒时报 zing_signature_rejected、整源按反爬拦截那套暂停(noteBlocked),
// 不再每轮都发。网页 JS 在 CDN 上按版本号放,当前版本号只有首页给、首页又限越南出口,所以不自动去 JS 里取密钥
// (09 章决策 373)。
//
// 曲库以越南发行的为主,别国的歌多是翻唱、伴奏和「Originally Performed By」这类条目,补的是越南歌。
type zingResult struct {
	lyrics, yrc, title, artist, album, cover string
	// durationSecs:搜索结果自报的时长(秒),0 = 没给。
	durationSecs float64
}

const (
	zingAPIBase    = "https://zingmp3.vn"
	zingSearchPath = "/api/v2/search"
	zingLyricPath  = "/api/v2/lyric/get/lyric"
	// zingCookieName:接口要的会话 cookie,由接口自己的应答下发。
	zingCookieName = "zmp3_rqid"
	// zingSearchCount:一次搜索取几条。同名的翻唱、Remix、伴奏常排在原版前后,20 条够把原版留在里面。
	zingSearchCount = 20
	// zingMaxCandidatesToFetch:过了闸之后最多并发取几条的歌词。
	zingMaxCandidatesToFetch = 3
	// zingScoreDurationTolerance / zingMaxDurationDiffSecs:时长闸,口径同 VIBE(09 章决策 283)。
	zingScoreDurationTolerance = 0.25
	zingMaxDurationDiffSecs    = 8.0
	// zingConcurrentQueries:开头同时发几条检索词,同 genieConcurrentQueries。
	zingConcurrentQueries = 2
	// zingWordTrackMaxOffsetMs / zingWordTrackMinAgreement:逐字的一句在这么多毫秒内找得到文字对得上的逐行、
	// 而且这样的句子占到这个比例,逐字才用。口径同 Deezer(deezerWordTrackAgrees)。
	zingWordTrackMaxOffsetMs  = 1500
	zingWordTrackMinAgreement = 0.8
)

// 应答 JSON 里的 err。别的非 0 值一律算没问成。
const (
	zingErrOK = 0
	// zingErrNoSession:没带会话 cookie(或它过期了)。
	zingErrNoSession = -201
	// zingErrBadSignature / zingErrBadAPIKey:签名对不上 / apiKey 不认。都是这组密钥失效了。
	zingErrBadSignature = -104
	zingErrBadAPIKey    = -116
)

// zingKey 是一组签名参数。version 只是原样带上的参数,服务端不校验它跟密钥配不配。
type zingKey struct {
	apiKey, secret, version string
}

// zingKeys:按顺序轮换的几组密钥。第一组是网页现行版本(1.22.x)JS 里的,第二组是 1.6.x 时代的,两组实测都还能用。
// 网页换了密钥时把新的一组加到最前面。
var zingKeys = []zingKey{
	{apiKey: "X5BM3w8N7MKozC0B85o4KMlzLZKhV00y", secret: "acOrvUS15XRW2o9JksiK1KgQ6Vbds8ZW", version: "1.22.4"},
	{apiKey: "88265e23d4284f25963e6eedac8fbfa3", secret: "2aa2d1c561e809b267f3638c4a307aab", version: "1.6.34"},
}

// zingKeyIdx:当前用 zingKeys 的哪一组。进程内共享,一组被拒就往后挪一格。
var zingKeyIdx atomic.Int32

// zingNow 可换,只为单测(签名里带 ctime)。
var zingNow = time.Now

var (
	zingMu    sync.Mutex
	zingCache = map[string]zingResult{}

	zingCookieMu sync.Mutex
	zingCookie   string

	zingLastFailMu  sync.Mutex
	zingLastFailure string
)

func zingSetLastFailureReason(reason string) {
	zingLastFailMu.Lock()
	zingLastFailure = reason
	zingLastFailMu.Unlock()
}

// zingLastFailureReasonNow 供 search-lyrics / test-lyric-sources 用:本进程里最近一次认出的失败原因,目前只有
// zing_signature_rejected(全部密钥都被拒)。接口正经答一次就清掉。
func zingLastFailureReasonNow() string {
	zingLastFailMu.Lock()
	defer zingLastFailMu.Unlock()
	return zingLastFailure
}

// zingProvider 把 zingLyric 接到 LyricProvider 上。结果的源名由调度填(runLyricProvider)。
type zingProvider struct{ desc *ProviderDescriptor }

func (p zingProvider) Descriptor() *ProviderDescriptor { return p.desc }

// QueryIndependentFailure:密钥全被拒(zing_signature_rejected)时换个别名照样被拒。
func (p zingProvider) QueryIndependentFailure() string { return zingLastFailureReasonNow() }

func (p zingProvider) DiagnosedFailure() string { return zingLastFailureReasonNow() }

// ProbeOwnTrack:Zing MP3 只有越南曲库,共用的两首探测曲一首搜不到、一首只有不带歌词的条目(09 章决策 373)。
func (p zingProvider) ProbeOwnTrack(ctx context.Context) bool {
	t := p.desc.Probe
	return zingLyric(ctx, t.Artist, t.Title, "", 0).lyrics != ""
}

func (p zingProvider) Resolve(ctx context.Context, q ProviderQuery, _ RoundEnv) SourceResult {
	r := zingLyric(ctx, q.Artist, q.SourceTitle, q.Album, q.DurationSecs)
	return SourceResult{lyr: r.lyrics, yrc: r.yrc, matchTitle: r.title, matchArtist: r.artist, matchAlbum: r.album, matchCover: r.cover, srcDur: r.durationSecs}
}

func zingLyric(ctx context.Context, artist, title, album string, durationSecs float64) zingResult {
	if title == "" {
		return zingResult{}
	}
	// 带上时长:选候选要过时长闸,同名的不同剪辑(~durN 变体)不能共用一份结果。
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(math.Round(durationSecs)))
	zingMu.Lock()
	if v, ok := zingCache[key]; ok {
		zingMu.Unlock()
		return v
	}
	zingMu.Unlock()

	ctx, sub := withLyricSubFetch(ctx)
	r := resolveZingLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" && sub.complete(ctx) {
		zingMu.Lock()
		zingCache[key] = r
		zingMu.Unlock()
	}
	return r
}

// zingSign 算签名:参数里属于签名范围的几项(zingSignedParam)按键名排序拼成「k=v」串,取 SHA-256 的十六进制,
// 接在接口路径后面,再用密钥做 HMAC-SHA512。纯函数,便于单测。
func zingSign(path string, params map[string]string, secret string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		if zingSignedParam(k) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + "=" + params[k])
	}
	sum := sha256.Sum256([]byte(b.String()))
	mac := hmac.New(sha512.New, []byte(secret))
	mac.Write([]byte(path + hex.EncodeToString(sum[:])))
	return hex.EncodeToString(mac.Sum(nil))
}

// zingSignedParam:网页客户端只把这几项算进签名,别的参数(q 等)不算。
func zingSignedParam(k string) bool {
	switch k {
	case "ctime", "id", "type", "page", "count", "version":
		return true
	}
	return false
}

// zingAPIError:应答的 err 不是 0。zingStatusError:HTTP 不是 200。都算没问成。
type zingAPIError int

func (e zingAPIError) Error() string { return fmt.Sprintf("zing err %d", int(e)) }

type zingStatusError int

func (e zingStatusError) Error() string { return fmt.Sprintf("zing HTTP %d", int(e)) }

// errZingKeysRejected:全部密钥都被拒了。
var errZingKeysRejected = errors.New("zing: all signing keys rejected")

func zingKeyRejected(code int) bool { return code == zingErrBadSignature || code == zingErrBadAPIKey }

// zingCall 发一次签名请求,回应答的 data。缺会话 cookie(-201)时用那条应答下发的 cookie 再发一次;这组密钥被拒时
// 挪到下一组再发,每组至多一次;全被拒时记失败原因、整源暂停。
func zingCall(ctx context.Context, path string, params map[string]string) (json.RawMessage, error) {
	sessionRetried := false
	tried := 0
	for tried < len(zingKeys) {
		i := int(zingKeyIdx.Load()) % len(zingKeys)
		code, data, sentCookie, err := zingCallWith(ctx, zingKeys[i], path, params)
		if err != nil {
			return nil, err
		}
		switch {
		case code == zingErrOK:
			zingSetLastFailureReason("")
			if b := sharedLyricSourceBreaker(); b != nil {
				b.clearBlocked(lyricSourceZing)
			}
			return data, nil
		case code == zingErrNoSession && zingSessionRenewed(sentCookie) && !sessionRetried:
			sessionRetried = true
			continue
		case zingKeyRejected(code):
			tried++
			next := (i + 1) % len(zingKeys)
			if zingKeyIdx.CompareAndSwap(int32(i), int32(next)) && tried < len(zingKeys) {
				log.Printf("zing: key %d rejected (err %d); switching to key %d", i, code, next)
			}
			continue
		}
		return nil, zingAPIError(code)
	}
	log.Printf("zing: every signing key was rejected; pausing the source")
	zingSetLastFailureReason(lyricFailureReasonZingSignatureRejected)
	if b := sharedLyricSourceBreaker(); b != nil {
		b.noteBlocked(lyricSourceZing)
	}
	return nil, errZingKeysRejected
}

// zingSessionRenewed:发请求时带的会话 cookie 已经换成新的了(这条或并发的另一条应答下发的),值得再发一次。
func zingSessionRenewed(sent string) bool {
	zingCookieMu.Lock()
	defer zingCookieMu.Unlock()
	return zingCookie != "" && zingCookie != sent
}

// zingCallWith 用一组密钥发一次。sentCookie:这次带的会话 cookie;应答下发的新 cookie 当场存下。
func zingCallWith(ctx context.Context, k zingKey, path string, params map[string]string) (code int, data json.RawMessage, sentCookie string, err error) {
	p := make(map[string]string, len(params)+4)
	for key, v := range params {
		p[key] = v
	}
	p["ctime"] = strconv.FormatInt(zingNow().Unix(), 10)
	p["version"] = k.version
	sig := zingSign(path, p, k.secret)
	q := neturl.Values{}
	for key, v := range p {
		q.Set(key, v)
	}
	q.Set("apiKey", k.apiKey)
	q.Set("sig", sig)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, zingAPIBase+path+"?"+q.Encode(), nil)
	if err != nil {
		return 0, nil, sentCookie, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Accept", "application/json")
	zingCookieMu.Lock()
	sentCookie = zingCookie
	zingCookieMu.Unlock()
	if sentCookie != "" {
		req.Header.Set("Cookie", zingCookieName+"="+sentCookie)
	}
	resp, err := doHTTPTracked(lyricHTTPClient(zingHTTPTimeout), req)
	if err != nil {
		return 0, nil, sentCookie, err
	}
	defer resp.Body.Close()
	for _, c := range resp.Cookies() {
		if c.Name == zingCookieName && c.Value != "" {
			zingCookieMu.Lock()
			zingCookie = c.Value
			zingCookieMu.Unlock()
		}
	}
	if resp.StatusCode != http.StatusOK {
		return 0, nil, sentCookie, zingStatusError(resp.StatusCode)
	}
	var out struct {
		Err  *int            `json:"err"`
		Data json.RawMessage `json:"data"`
	}
	if err := decodeLyricSourceJSON(req, resp, lyricSourceResponseMaxBytes, &out); err != nil {
		return 0, nil, sentCookie, err
	}
	if out.Err == nil {
		return 0, nil, sentCookie, fmt.Errorf("zing: response without err field")
	}
	return *out.Err, out.Data, sentCookie, nil
}

// zingSearchItem 是搜索结果里用得上的字段。
type zingSearchItem struct {
	EncodeID     string  `json:"encodeId"`
	Title        string  `json:"title"`
	ArtistsNames string  `json:"artistsNames"`
	Duration     float64 `json:"duration"`
	// HasLyric:有歌词时为 true,没有时这个字段不出现。
	HasLyric   bool   `json:"hasLyric"`
	ThumbnailM string `json:"thumbnailM"`
	Album      struct {
		Title string `json:"title"`
	} `json:"album"`
}

type zingSearchOutcome struct {
	items []zingSearchItem
	err   error
}

func zingSearch(ctx context.Context, query string) ([]zingSearchItem, error) {
	data, err := zingCall(ctx, zingSearchPath, map[string]string{
		"q": query, "type": "song", "page": "1", "count": strconv.Itoa(zingSearchCount),
	})
	if err != nil {
		return nil, err
	}
	var out struct {
		Items []zingSearchItem `json:"items"`
	}
	if len(data) == 0 || string(data) == "null" {
		return nil, nil
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

// zingWord / zingSentence 是取词应答 sentences 里的一个词 / 一句。
type zingWord struct {
	StartTime int    `json:"startTime"`
	EndTime   int    `json:"endTime"`
	Data      string `json:"data"`
}

type zingSentence struct {
	Words []zingWord `json:"words"`
}

// zingLyricData 是取词应答的 data。
type zingLyricData struct {
	Sentences []zingSentence `json:"sentences"`
	// File:同一份歌词的逐行 LRC 地址,没有时为空。
	File string `json:"file"`
}

// zingFetchFile 取 LRC 文件。404 算没有(found=false、err=nil),别的非 200 和连接错误算没问成。
func zingFetchFile(ctx context.Context, u string) (text string, found bool, err error) {
	if !strings.HasPrefix(u, "https://") {
		return "", false, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", false, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(zingHTTPTimeout), req)
	if err != nil {
		return "", false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return "", false, nil
	}
	if resp.StatusCode != http.StatusOK {
		return "", false, zingStatusError(resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes))
	if err != nil {
		return "", false, err
	}
	text, _ = decodeLyricBytes(b)
	return text, true, nil
}

// zingSyncLine 是逐行 LRC 的一句。
type zingSyncLine struct {
	ms   int
	text string
}

// zingParseLRC 解析 LRC 文件:只认行首带时间戳、正文不空的行,按起点排序。纯函数,便于单测。
func zingParseLRC(text string) []zingSyncLine {
	var out []zingSyncLine
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(strings.TrimPrefix(raw, "\ufeff"))
		head := lrcLeadingTimeTagsRegex.FindString(line)
		if head == "" {
			continue
		}
		body := strings.TrimSpace(line[len(head):])
		if body == "" {
			continue
		}
		for _, m := range lrcTimestampCaptureRe.FindAllStringSubmatch(head, -1) {
			out = append(out, zingSyncLine{ms: lrcCaptureMs(m), text: body})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ms < out[j].ms })
	return out
}

// zingWordLines 把 sentences 整理成逐字行:去掉空词、按起点排好;词数不到两个的句子不算逐字(一句一个「词」就是逐行)。
// 起点倒退、终点早于起点的词说明这份数据坏了,整份不要(返回 nil)。纯函数,便于单测。
func zingWordLines(sentences []zingSentence) [][]zingWord {
	var out [][]zingWord
	multi := 0
	for _, s := range sentences {
		var ws []zingWord
		for _, w := range s.Words {
			if strings.TrimSpace(w.Data) == "" {
				continue
			}
			if w.EndTime < w.StartTime || (len(ws) > 0 && w.StartTime < ws[len(ws)-1].StartTime) {
				return nil
			}
			ws = append(ws, w)
		}
		if len(ws) == 0 {
			continue
		}
		if len(ws) > 1 {
			multi++
		}
		out = append(out, ws)
	}
	if multi == 0 {
		return nil
	}
	return out
}

// zingWordLineText 是一句逐字拼回来的整句,词之间一个空格。
func zingWordLineText(ws []zingWord) string {
	parts := make([]string, 0, len(ws))
	for _, w := range ws {
		parts = append(parts, strings.TrimSpace(w.Data))
	}
	return strings.Join(parts, " ")
}

// zingWordTrackAgrees 判逐字能不能用:逐字的每一句在 zingWordTrackMaxOffsetMs 内找得到文字互相包含的逐行
// (归一口径同 deezerTextKey),这样的句子占到 zingWordTrackMinAgreement 才用。纯函数,便于单测。
func zingWordTrackAgrees(words [][]zingWord, lines []zingSyncLine) bool {
	if len(words) == 0 || len(lines) == 0 {
		return false
	}
	agree := 0
	for _, ws := range words {
		t := deezerTextKey(zingWordLineText(ws))
		if t == "" {
			continue
		}
		start := ws[0].StartTime
		for _, l := range lines {
			r := deezerTextKey(l.text)
			if r == "" {
				continue
			}
			d := l.ms - start
			if d < 0 {
				d = -d
			}
			if d <= zingWordTrackMaxOffsetMs && (strings.Contains(r, t) || strings.Contains(t, r)) {
				agree++
				break
			}
		}
	}
	return float64(agree) >= float64(len(words))*zingWordTrackMinAgreement
}

// zingBuildYRC 把逐字行拼成 YRC:`[行始,行长](词始,词长,0)词 …`,词之间的空格挂在前一个词末尾。
// 起止相同的词(零时长)跟后面同一起点、有时长的那个词同唱一段,把那段时长平分给这几个词;后面的词起点更晚时,
// 平分到它开口为止;句尾的留零时长。纯函数,便于单测。
func zingBuildYRC(lines [][]zingWord) string {
	var b strings.Builder
	for _, ws := range lines {
		spans := zingWordSpans(ws)
		lineStart := spans[0][0]
		lineEnd := spans[len(spans)-1][1]
		for _, s := range spans {
			lineEnd = max(lineEnd, s[1])
		}
		fmt.Fprintf(&b, "[%d,%d]", lineStart, lineEnd-lineStart)
		for i, w := range ws {
			text := strings.TrimSpace(w.Data)
			if i < len(ws)-1 {
				text += " "
			}
			fmt.Fprintf(&b, "(%d,%d,0)%s", spans[i][0], spans[i][1]-spans[i][0], text)
		}
		b.WriteString("\n")
	}
	return strings.TrimSuffix(b.String(), "\n")
}

// zingWordSpans 给一句里每个词定起止(毫秒),零时长词的平分规则见 zingBuildYRC。
func zingWordSpans(ws []zingWord) [][2]int {
	spans := make([][2]int, len(ws))
	for i := 0; i < len(ws); {
		if ws[i].EndTime > ws[i].StartTime {
			spans[i] = [2]int{ws[i].StartTime, ws[i].EndTime}
			i++
			continue
		}
		j := i
		for j < len(ws) && ws[j].StartTime == ws[i].StartTime && ws[j].EndTime == ws[j].StartTime {
			j++
		}
		if j < len(ws) && ws[j].StartTime == ws[i].StartTime {
			n := j - i + 1
			start, total := ws[i].StartTime, ws[j].EndTime-ws[i].StartTime
			for k := 0; k < n; k++ {
				spans[i+k] = [2]int{start + total*k/n, start + total*(k+1)/n}
			}
			i = j + 1
			continue
		}
		end := ws[i].StartTime
		if j < len(ws) {
			end = ws[j].StartTime
		}
		n, start := j-i, ws[i].StartTime
		for k := 0; k < n; k++ {
			spans[i+k] = [2]int{start + (end-start)*k/n, start + (end-start)*(k+1)/n}
		}
		i = j
	}
	return spans
}

// zingBuildLRC 拼逐行 LRC:有 LRC 文件时用它,没有时用逐字行的起点和整句。
func zingBuildLRC(lines []zingSyncLine, words [][]zingWord) string {
	var b strings.Builder
	if len(lines) > 0 {
		for _, l := range lines {
			b.WriteString(formatLRCStamp(l.ms) + l.text + "\n")
		}
		return b.String()
	}
	for _, ws := range words {
		b.WriteString(formatLRCStamp(ws[0].StartTime) + zingWordLineText(ws) + "\n")
	}
	return b.String()
}

// zingSentenceLines 把 sentences 每句拼成逐行(不管词数),只在没有 LRC 文件、也不成逐字时用。
func zingSentenceLines(sentences []zingSentence) []zingSyncLine {
	var out []zingSyncLine
	for _, s := range sentences {
		var parts []string
		start := -1
		for _, w := range s.Words {
			if t := strings.TrimSpace(w.Data); t != "" {
				if start < 0 {
					start = w.StartTime
				}
				parts = append(parts, t)
			}
		}
		if start >= 0 {
			out = append(out, zingSyncLine{ms: start, text: strings.Join(parts, " ")})
		}
	}
	return out
}

// zingCoverURL:搜索结果的 thumbnailM 是缩略图档(`photo-resize-zmp3.zmdcdn.me/w240_r1x1_jpeg/cover/…`,
// 也有 `covers/…`),换成原图(`photo-zmp3.zmdcdn.me/cover/…`)。没有专辑图的歌给的是歌手照片或横幅
// (`avatars/…`、`banner/…`),不是这条录音的封面,回空。别的形状原样返回。纯函数,便于单测。
func zingCoverURL(thumb string) string {
	thumb = strings.TrimSpace(thumb)
	u, err := neturl.Parse(thumb)
	if err != nil || u.Scheme != "https" || u.Host != "photo-resize-zmp3.zmdcdn.me" {
		return thumb
	}
	parts := strings.SplitN(strings.TrimPrefix(u.Path, "/"), "/", 2)
	if len(parts) != 2 || !strings.HasPrefix(parts[0], "w") {
		return thumb
	}
	if !strings.HasPrefix(parts[1], "cover/") && !strings.HasPrefix(parts[1], "covers/") {
		return ""
	}
	return "https://photo-zmp3.zmdcdn.me/" + parts[1]
}

// zingCandidateScore 给一条搜索结果打分,越高越像本地这首;负数 = 淘汰。口径同 vibeCandidateScore。纯函数,便于单测。
func zingCandidateScore(item zingSearchItem, artist, title, album string, durationSecs float64) int {
	if !item.HasLyric || item.EncodeID == "" {
		return -1
	}
	if !lyricTitleAccepted(item.Title, title) {
		return -1
	}
	d := item.Duration
	if !lyricSourceArtistMatches(item.ArtistsNames, artist) &&
		!lyricRecordingTriangleMatchesGuarded(item.Title, item.Album.Title, item.ArtistsNames, d, title, album, artist, durationSecs) {
		return -1
	}
	if versionTagsMismatch(title, album, item.Title, item.Album.Title) {
		return -1
	}
	score := 100
	if durationSecs > 0 && d > 0 {
		diff := math.Abs(d-durationSecs) / durationSecs
		if diff > zingScoreDurationTolerance || math.Abs(d-durationSecs) > zingMaxDurationDiffSecs {
			return -1
		}
		score += int((1 - diff) * 50)
	}
	return score
}

// zingFetched 是一条候选取词的结果。
type zingFetched struct {
	lyrics, yrc string
	failed      bool
}

// zingFetchLyric 取一条候选的歌词:先取词接口,有 LRC 文件再取文件。逐字过了 zingWordTrackAgrees 才带上;
// LRC 文件没问成时这一条算没问成(结果照用 sentences 拼的逐行,但不进缓存)。
func zingFetchLyric(ctx context.Context, id string) zingFetched {
	data, err := zingCall(ctx, zingLyricPath, map[string]string{"id": id})
	if err != nil {
		return zingFetched{failed: true}
	}
	var d zingLyricData
	if len(data) > 0 && string(data) != "null" {
		if err := json.Unmarshal(data, &d); err != nil {
			return zingFetched{failed: true}
		}
	}
	var lines []zingSyncLine
	failed := false
	if d.File != "" {
		text, found, err := zingFetchFile(ctx, d.File)
		switch {
		case err != nil:
			failed = true
		case found:
			lines = zingParseLRC(text)
		}
	}
	words := zingWordLines(d.Sentences)
	if len(lines) == 0 && len(words) == 0 {
		lines = zingSentenceLines(d.Sentences)
	}
	out := zingFetched{lyrics: zingBuildLRC(lines, words), failed: failed}
	if len(words) > 0 && (len(lines) == 0 && !failed || zingWordTrackAgrees(words, lines)) {
		out.yrc = zingBuildYRC(words)
	}
	return out
}

// resolveZingLyric:检索词的顺序同 resolveGenieLyric(「歌名 第一位歌手」→ 只按歌名 → 歌名被清理过时按原样),
// 前两条同时发;过闸的按分数取前几条并发取词,按名次挑第一份带时间轴的。
func resolveZingLyric(ctx context.Context, artist, title, album string, durationSecs float64) zingResult {
	type scoredItem struct {
		item  zingSearchItem
		score int
	}
	qTitle := vibeQueryText(lyricQueryTitle(title))
	queries := vibeQueries(qTitle, strings.TrimSpace(qTitle+" "+vibeQueryText(firstCreditedArtist(artist))),
		strings.TrimSpace(lyricQueryTitle(title)))
	// 第二条用不上时让它在后台跑完,别取消:取消掉的请求会被熔断记成一次失败(同 resolveGenieLyric)。
	pending := make([]chan zingSearchOutcome, len(queries))
	start := func(i int) {
		ch := make(chan zingSearchOutcome, 1)
		pending[i] = ch
		go func() {
			items, err := zingSearch(ctx, queries[i])
			ch <- zingSearchOutcome{items, err}
		}()
	}
	for i := 0; i < len(queries) && i < zingConcurrentQueries; i++ {
		start(i)
	}
	var candidates []scoredItem
	for qi := range queries {
		if pending[qi] == nil {
			start(qi)
		}
		res := <-pending[qi]
		if res.err != nil {
			noteLyricSubFetchFailure(ctx)
			return zingResult{}
		}
		for _, it := range res.items {
			if s := zingCandidateScore(it, artist, title, album, durationSecs); s >= 0 {
				candidates = append(candidates, scoredItem{it, s})
			}
		}
		if len(candidates) > 0 {
			break
		}
	}
	if len(candidates) == 0 {
		return zingResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
	if len(candidates) > zingMaxCandidatesToFetch {
		candidates = candidates[:zingMaxCandidatesToFetch]
	}

	fetched := make([]zingFetched, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func(rank int, id string) {
			defer wg.Done()
			fetched[rank] = zingFetchLyric(ctx, id)
		}(i, c.item.EncodeID)
	}
	wg.Wait()

	for rank, c := range candidates {
		f := fetched[rank]
		if f.failed {
			noteLyricSubFetchFailure(ctx)
		}
		if !isTimedLRC(f.lyrics) {
			continue
		}
		return zingResult{lyrics: f.lyrics, yrc: f.yrc, title: c.item.Title, artist: c.item.ArtistsNames,
			album: c.item.Album.Title, cover: zingCoverURL(c.item.ThumbnailM), durationSecs: c.item.Duration}
	}
	return zingResult{}
}
