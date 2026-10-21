package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
)

// petitLyric 是プチリリ(PetitLyrics,SyncPower 运营的日本同步歌词服务)这一路:搜索 → 按元数据打分 → 带逐字的按 lyricsId
// 并发取前几名、按名次挑第一份解得开的 → 没有逐字时取名次最高的逐行 → 再没有时把总分第一的那份按纯文本取。接口是它自家
// SDK 用的 `GetPetitLyricsData.php`(POST 表单、回 XML),带 SDK 的 clientAppId,不要账号;几组主机 + clientAppId 轮换着用,
// 见 petitClients。
//
// 一首歌常有好几份:SyncPower 自己做的官方同步(isOfficial=1)和用户上传的;lyricsType 1 纯文本、2 逐行、3 逐字。逐字是
// base64 的明文 XML(<wsy><line><linestring/><word><starttime/><endtime/><wordstring/></word>…),一个字(英文一个字母)
// 一个时间,空格也单独打时间;逐行是一段二进制,只带每行的时间(见 petitLineTimes),文字按同一个 lyricsId 取纯文本那一档、
// 逐行配上。搜索只给排第一的那条带正文,别的按 key_lyricsId 另取。应答里带上传者用户名,不读、不记。
//
// 应答不带封面,带 ISRC:封面按 ISRC 去 Deezer 取那条录音的专辑图(petitCoverByISRC),跟取歌词并发。
//
// 曲库以日本发行的为主,补的是日文歌。时间轴实测见 09 章决策 309。没有公开文档,跟 kuwo.go / migu.go 同一类风险。
type petitResult struct {
	lyrics, yrc, title, artist, album string
	// isrc:这份歌词登记的录音 ISRC,没给时为空;cover:按它在 Deezer 上取到的专辑封面。
	isrc, cover string
	// durationSecs:这份歌词登记的曲长(毫秒精度),0 = 没给。
	durationSecs float64
	plainOnly    bool
}

const (
	// petitSearchMax:一次搜索取几条。同一首歌常有十几份用户上传的,官方那份不一定排在前面。
	petitSearchMax = 20
	// petitMaxCandidatesToFetch:带逐字、过了闸的最多并发取几份。
	petitMaxCandidatesToFetch = 3
	// petitScoreDurationTolerance 跟别的源的时长闸(match.go 的 0.25)取同一个值。
	petitScoreDurationTolerance = 0.25
	// petitServerArtistMaxDiffSecs:歌手对不上、靠服务端按歌手过滤收下的那条,时长最多差几秒(petitServerArtistMatch)。
	petitServerArtistMaxDiffSecs = 1.0
	// petitMaxDurationDiffSecs:两边时长都知道时差多少秒就不是同一版,同 vibeMaxDurationDiffSecs。
	petitMaxDurationDiffSecs = 8.0
	// petitOfficialMaxDiffSecs:官方同步是对着它登记的那条录音做的,时长差过这个数就不是这一条录音,官方那份不再优先。
	petitOfficialMaxDiffSecs = 1.0
	// petitCoverWait:歌词取完之后封面还没回来时最多再等多久。封面跟取歌词并发,一般先到;等不到就不带封面,不拖慢歌词。
	petitCoverWait = 1500 * time.Millisecond

	petitTypePlain = "1"
	petitTypeLine  = "2"
	petitTypeWord  = "3"
	petitStatusOK  = "00000000"
	// petitStatusUnknownClient:clientAppId 不认(参数错是 8150f001,换一组也没用,不轮换)。
	petitStatusUnknownClient = "8170f003"
)

// petitClient 是一组能用的主机 + clientAppId + terminalType,三组分别是它自家的 Android SDK、iOS SDK 和合作方应用
// Onkyo HF Player(应答里 <songs><name> 报的客户端名),三个主机回的是同一套数据,编号在哪个主机上都认。都是借来的:
// 某一组被作废(petitStatusUnknownClient)、主机连不上或 5xx 时换下一组,换过去就一直用它,见 petitPost。
type petitClient struct{ host, appID, terminalType string }

var petitClients = []petitClient{
	{"p1.petitlyrics.com", "p1110417", "10"},
	{"p0.petitlyrics.com", "p1232089", "4"},
	{"on.petitlyrics.com", "on354007", "0"},
}

// petitClientIdx:当前用 petitClients 的哪一组。进程内共享,一组失败就往后挪一格。
var petitClientIdx atomic.Int32

var (
	petitMu    sync.Mutex
	petitCache = map[string]petitResult{}
)

func petitLyric(ctx context.Context, artist, title, album string, durationSecs float64) petitResult {
	if title == "" {
		return petitResult{}
	}
	artist, title, album = originalScriptQueryFields(ctx, artist, title, album)
	// 带上时长:选候选要过时长闸,同名的不同剪辑(~durN 变体)不能共用一份结果。
	key := artist + "|" + title + "|" + album + "|" + strconv.Itoa(int(math.Round(durationSecs)))
	petitMu.Lock()
	if v, ok := petitCache[key]; ok {
		petitMu.Unlock()
		return v
	}
	petitMu.Unlock()

	ctx, sub := withLyricSubFetch(ctx)
	r := resolvePetitLyric(ctx, artist, title, album, durationSecs)
	if r.lyrics != "" && sub.complete(ctx) {
		petitMu.Lock()
		petitCache[key] = r
		petitMu.Unlock()
	}
	return r
}

// petitSong 是应答里一条歌词的元数据。数字字段按字符串收:没有值时是空串。
type petitSong struct {
	LyricsID   string `xml:"lyricsId"`
	Title      string `xml:"title"`
	Artist     string `xml:"artist"`
	Album      string `xml:"album"`
	Duration   string `xml:"duration"` // 毫秒
	LyricsType string `xml:"lyricsType"`
	IsOfficial string `xml:"isOfficial"`
	ISRC       string `xml:"isrc"`
	LyricsData string `xml:"lyricsData"`
}

func (s petitSong) durationSecs() float64 {
	ms, err := strconv.Atoi(strings.TrimSpace(s.Duration))
	if err != nil || ms <= 0 {
		return 0
	}
	return float64(ms) / 1000
}

type petitResponse struct {
	Status string      `xml:"status"`
	Songs  []petitSong `xml:"songs>song"`
}

// petitStatusError:应答的 status 不是成功;petitHTTPError:HTTP 不是 200。都算没问成。
type petitStatusError string

func (e petitStatusError) Error() string { return "petitlyrics status " + string(e) }

type petitHTTPError int

func (e petitHTTPError) Error() string { return fmt.Sprintf("petitlyrics HTTP %d", int(e)) }

// petitPost 用当前那组发一次;那组被作废、连不上或 5xx 时挪到下一组再发,每组至多一次。参数错、4xx、应答解不开不换(换了也一样)。
func petitPost(ctx context.Context, form neturl.Values) (petitResponse, error) {
	var lastErr error
	for range petitClients {
		i := int(petitClientIdx.Load()) % len(petitClients)
		out, err := petitPostWith(ctx, petitClients[i], form)
		if err == nil || ctx.Err() != nil || !petitClientFailed(err) {
			return out, err
		}
		lastErr = err
		if petitClientIdx.CompareAndSwap(int32(i), int32((i+1)%len(petitClients))) {
			log.Printf("petitlyrics: %s (%s) failed: %v; switching to %s", petitClients[i].host, petitClients[i].appID, err,
				petitClients[(i+1)%len(petitClients)].host)
		}
	}
	return petitResponse{}, lastErr
}

// petitClientFailed:这个错是这一组的问题、换一组可能就好 —— 编号被作废、5xx、连接层失败。
func petitClientFailed(err error) bool {
	var se petitStatusError
	if errors.As(err, &se) {
		return se == petitStatusUnknownClient
	}
	var he petitHTTPError
	if errors.As(err, &he) {
		return he >= 500
	}
	var xe *xml.SyntaxError
	return !errors.As(err, &xe) && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF)
}

func petitPostWith(ctx context.Context, c petitClient, form neturl.Values) (petitResponse, error) {
	body := neturl.Values{}
	for k, v := range form {
		body[k] = v
	}
	body.Set("terminalType", c.terminalType)
	body.Set("clientAppId", c.appID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+c.host+"/api/GetPetitLyricsData.php",
		strings.NewReader(body.Encode()))
	if err != nil {
		return petitResponse{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(petitHTTPTimeout), req)
	if err != nil {
		return petitResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return petitResponse{}, petitHTTPError(resp.StatusCode)
	}
	var out petitResponse
	if err := xml.NewDecoder(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes)).Decode(&out); err != nil {
		return petitResponse{}, err
	}
	if out.Status != petitStatusOK {
		return petitResponse{}, petitStatusError(out.Status)
	}
	return out, nil
}

// petitSearch 按歌名(和歌手)搜。时长交给服务端当参考:只按歌名搜时它能把同名的别的歌筛掉大半。
func petitSearch(ctx context.Context, title, artist string, durationSecs float64) ([]petitSong, error) {
	form := neturl.Values{}
	form.Set("key_title", title)
	form.Set("key_artist", artist)
	form.Set("key_album", "")
	dur := ""
	if durationSecs > 0 {
		dur = strconv.Itoa(int(math.Round(durationSecs * 1000)))
	}
	form.Set("key_duration", dur)
	form.Set("lyricsType", petitTypeWord)
	form.Set("maxCount", strconv.Itoa(petitSearchMax))
	out, err := petitPost(ctx, form)
	return out.Songs, err
}

// petitFetch 按 lyricsId 取一份。lyricsType 传 3 时有逐字就回逐字,否则回它有的那一档;传 1 一律回纯文本。
// 应答里没有这一条(被删了)时 ok=false、err=nil,算答了没有。
func petitFetch(ctx context.Context, id, lyricsType string) (song petitSong, ok bool, err error) {
	form := neturl.Values{}
	form.Set("key_lyricsId", id)
	form.Set("lyricsType", lyricsType)
	out, err := petitPost(ctx, form)
	if err != nil {
		return petitSong{}, false, err
	}
	for _, s := range out.Songs {
		if s.LyricsID == id {
			return s, true, nil
		}
	}
	return petitSong{}, false, nil
}

// petitWSY 是逐字那一档解开后的 XML。时间是毫秒,按字符串收(偶尔为空)。
type petitWSY struct {
	Lines []struct {
		Text  string `xml:"linestring"`
		Words []struct {
			Start string `xml:"starttime"`
			End   string `xml:"endtime"`
			Text  string `xml:"wordstring"`
		} `xml:"word"`
	} `xml:"line"`
}

type petitWord struct {
	start, end int
	text       string
}

// petitLatinRune:连着的这种字并成一个词。PetitLyrics 给英文也是一个字母一个时间,逐字染色按字母走、读音按词对不上。
func petitLatinRune(r rune) bool {
	return r < unicode.MaxASCII && (unicode.IsLetter(r) || unicode.IsDigit(r)) || r == '\'' || r == '’'
}

func petitAllLatin(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !petitLatinRune(r) {
			return false
		}
	}
	return true
}

// petitBuildLyrics 把逐字那一档(base64 的 XML)拼成 LRC 和 YRC。行首取第一个字的起点;后一个字的起点早于前一个字的终点时把
// 前一个截到后一个的起点(同 lxMusicWordsToYRC);连着的英文字母并成一个词;一行没有带时间的字时丢掉,只有空白的行在 LRC 里
// 写成只有时间戳的一行(一句唱完、后面是间奏);行首早于上一行的丢掉。解不开时两个都是空串。纯函数,便于单测。
func petitBuildLyrics(data string) (lrc, yrc string) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(data))
	if err != nil {
		return "", ""
	}
	var doc petitWSY
	if err := xml.Unmarshal(raw, &doc); err != nil {
		return "", ""
	}
	var lb, yb strings.Builder
	last := -1
	for _, line := range doc.Lines {
		var words []petitWord
		for _, w := range line.Words {
			start, err1 := strconv.Atoi(strings.TrimSpace(w.Start))
			end, err2 := strconv.Atoi(strings.TrimSpace(w.End))
			if err1 != nil || start < 0 || w.Text == "" {
				continue
			}
			if err2 != nil || end < start {
				end = start
			}
			if n := len(words); n > 0 {
				prev := &words[n-1]
				if start < prev.end {
					prev.end = max(start, prev.start)
				}
				if petitAllLatin(prev.text) && petitAllLatin(w.Text) {
					prev.text += w.Text
					prev.end = max(prev.end, end)
					continue
				}
			}
			words = append(words, petitWord{start: start, end: end, text: w.Text})
		}
		if len(words) == 0 || words[0].start < last {
			continue
		}
		lineStart := words[0].start
		last = lineStart
		var text strings.Builder
		lineEnd := lineStart
		for _, w := range words {
			text.WriteString(w.text)
			lineEnd = max(lineEnd, w.end)
		}
		body := strings.TrimSpace(text.String())
		lb.WriteString(formatLRCStamp(lineStart) + body + "\n")
		if body == "" {
			continue
		}
		fmt.Fprintf(&yb, "[%d,%d]", lineStart, lineEnd-lineStart)
		for _, w := range words {
			fmt.Fprintf(&yb, "(%d,%d,0)%s", w.start, w.end-w.start, w.text)
		}
		yb.WriteString("\n")
	}
	yrc, _ = yrcMergeWhitespaceTokens(strings.TrimSuffix(yb.String(), "\n"))
	return lb.String(), yrc
}

// petitPlainText 解开纯文本那一档(base64 的 UTF-8 正文,CRLF 换行)。
func petitPlainText(data string) string {
	return strings.TrimSpace(petitPlainLines(data))
}

// petitPlainLines:纯文本那一档解开、换行统一成 \n,首尾空白不动(结尾的空行在逐行那一档里也占时间,见 petitZipLines)。
func petitPlainLines(data string) string {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(data))
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(raw), "\r\n", "\n")
}

// 逐行那一档(lyricsType 2)的二进制:`MHDROBJT` 头 + `MLRCOBJT` 块。0x19 是换密钥开关、0x1a 是 16 位保护号、0x38 是行数、
// 0x42 是每行文字槽的字节数,0xcc 起每行一个 16 位小端的时间(百分之一秒),跟密钥异或过。整段长度恰好是
// 0xcc + 行数×2 + 行数×槽宽。文字槽里的字解不干净,不用。格式参考 GitHub sydlexius/canticle(GPL-3.0)的
// internal/petitlyrics/decode.go。
const (
	petitLineKeySwitchOff = 0x19
	petitLineKeyOff       = 0x1a
	petitLineCountOff     = 0x38
	petitLineSlotOff      = 0x42
	petitLineTimesOff     = 0xcc
	petitLineMaxLines     = 10000
	// petitLineWrapCS:时间只有 16 位,约 10.9 分钟回绕一次;后一行比前一行小就是绕了一圈。
	petitLineWrapCS = 65536
)

// petitLineKey:换密钥开关打开时,保护号每个半字节里相邻的两对位对调一次(每个字节最外侧那一对不动),否则保护号就是密钥。
func petitLineKey(id uint16, swap bool) uint16 {
	if !swap {
		return id
	}
	return id&0x0003 | (id&0x000c)<<2 | (id&0x0030)>>2 | (id&0x00c0)<<2 | (id&0x0300)>>2 | (id&0x0c00)<<2 | (id&0x3000)>>2 | id&0xc000
}

// petitLineTimes 从逐行那一档(base64)解出每行的起点(毫秒)。头不对、行数不合理、长度跟行数对不上的一律 ok=false。纯函数,便于单测。
func petitLineTimes(data string) (ms []int, ok bool) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(data))
	if err != nil || len(raw) < petitLineTimesOff || string(raw[:8]) != "MHDROBJT" || string(raw[0x2c:0x34]) != "MLRCOBJT" {
		return nil, false
	}
	n := int(binary.LittleEndian.Uint32(raw[petitLineCountOff:]))
	if n <= 0 || n > petitLineMaxLines || len(raw) < petitLineTimesOff+2*n {
		return nil, false
	}
	if slot := int(binary.LittleEndian.Uint16(raw[petitLineSlotOff:])); slot > 0 && len(raw) != petitLineTimesOff+2*n+slot*n {
		return nil, false
	}
	key := petitLineKey(binary.LittleEndian.Uint16(raw[petitLineKeyOff:]), raw[petitLineKeySwitchOff] != 0)
	wraps, prev := 0, 0
	for i := 0; i < n; i++ {
		cs := int(binary.LittleEndian.Uint16(raw[petitLineTimesOff+2*i:]) ^ key)
		if i > 0 && cs < prev {
			wraps++
		}
		prev = cs
		ms = append(ms, (cs+wraps*petitLineWrapCS)*10)
	}
	return ms, true
}

// petitZipLines 把逐行的时间跟纯文本那一档逐行配成 LRC。纯文本以换行结尾时,结尾那个空行常也占一个时间(最后一句的结束点):
// 先按原样的行数配,配不上再一行一行去掉末尾的空行重配;都对不上时返回空串(错位一行,后面每一句都挂错时间)。
// 空行(中间的、结尾占了时间的)写成只有时间戳的一行。纯函数,便于单测。
func petitZipLines(ms []int, text string) string {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	for len(lines) != len(ms) {
		if len(lines) == 0 || strings.TrimSpace(lines[len(lines)-1]) != "" {
			return ""
		}
		lines = lines[:len(lines)-1]
	}
	var b strings.Builder
	for i, t := range ms {
		b.WriteString(formatLRCStamp(t) + strings.TrimSpace(lines[i]) + "\n")
	}
	return b.String()
}

// petitAltScriptTitleRe:用户把罗马字 / 平假名 / 译文当正文上传时在歌名后面标的括号(「ヴァンパイア(romaji)」)。这种歌名
// 过得了歌名闸,正文却不是原文。
var petitAltScriptTitleRe = regexp.MustCompile(`(?i)[(（\[［【]\s*(romaji|roma|ローマ字|ひらがな|かな|english|translation|和訳|英訳|中文|日本語訳)[^)）\]］】]*[)）\]］】]`)

// petitCandidateScore 给一条搜索结果打分,越高越像本地这首;负数 = 淘汰。身份判定用跟别的源一致的函数,歌手对不上时退到
// 三角验证。时长对得上的官方同步优先,其次是逐字。纯函数,便于单测。
//
// artistKeyed:这条是带着歌手搜回来的。服务端按歌手过滤时认得罗马字艺名、本名这类别名,不按任意子串匹配,乱写一个歌手
// 一条不回;歌名逐字相同、时长差不超过 petitServerArtistMaxDiffSecs 时,歌手对不上也收。见 09 章决策 314。
func petitCandidateScore(s petitSong, artist, title, album string, durationSecs float64, artistKeyed bool) int {
	if s.LyricsID == "" || s.LyricsType == "" {
		return -1
	}
	if !lyricTitleAccepted(s.Title, title) || petitAltScriptTitleRe.MatchString(s.Title) && !petitAltScriptTitleRe.MatchString(title) {
		return -1
	}
	d := s.durationSecs()
	if !lyricSourceArtistMatches(s.Artist, artist) && !petitServerArtistMatch(s, title, durationSecs, artistKeyed) &&
		!lyricRecordingTriangleMatchesGuarded(s.Title, s.Album, s.Artist, d, title, album, artist, durationSecs) {
		return -1
	}
	if versionTagsMismatch(title, album, s.Title, s.Album) {
		return -1
	}
	score := 100
	sameRecording := true
	if durationSecs > 0 && d > 0 {
		diff := math.Abs(d - durationSecs)
		if diff/durationSecs > petitScoreDurationTolerance || diff > petitMaxDurationDiffSecs {
			return -1
		}
		sameRecording = diff <= petitOfficialMaxDiffSecs
		score += int((1 - diff/petitMaxDurationDiffSecs) * 30)
	}
	if s.IsOfficial == "1" && sameRecording {
		score += 40
	}
	switch s.LyricsType {
	case petitTypeWord:
		score += 30
	case petitTypeLine:
		score += 15
	}
	return score
}

// petitServerArtistMatch:见 petitCandidateScore 的 artistKeyed。
func petitServerArtistMatch(s petitSong, title string, durationSecs float64, artistKeyed bool) bool {
	d := s.durationSecs()
	if !artistKeyed || durationSecs <= 0 || math.Abs(d-durationSecs) > petitServerArtistMaxDiffSecs {
		return false
	}
	t := normLoose(s.Title)
	return t != "" && (t == normLoose(title) || t == normLoose(lyricQueryTitle(title)))
}

// petitQueries:按顺序要用的(歌名, 歌手)两组 —— 先带第一位歌手,一条都没过闸再只按歌名(服务端认得歌手的别名,但写法
// 差太多时带着反而一条不回)。歌名被清理过时再按原样的歌名搜一次。去掉重复的。
func petitQueries(qTitle, qArtist, raw string) [][2]string {
	var out [][2]string
	for _, q := range [][2]string{{qTitle, qArtist}, {qTitle, ""}, {raw, ""}} {
		if q[0] == "" {
			continue
		}
		dup := false
		for _, o := range out {
			dup = dup || o == q
		}
		if !dup {
			out = append(out, q)
		}
	}
	return out
}

// scoredPetitSong:过了闸的一条和它的分。
type scoredPetitSong struct {
	song  petitSong
	score int
}

func resolvePetitLyric(ctx context.Context, artist, title, album string, durationSecs float64) petitResult {
	qTitle := strings.TrimSpace(lyricQueryTitle(title))
	var candidates []scoredPetitSong
	queries := petitQueries(qTitle, strings.TrimSpace(firstCreditedArtist(artist)), strings.TrimSpace(title))
	for qi, q := range queries {
		songs, err := petitSearch(ctx, q[0], q[1], durationSecs)
		if err != nil {
			return petitResult{}
		}
		for _, s := range songs {
			if sc := petitCandidateScore(s, artist, title, album, durationSecs, q[1] != ""); sc >= 0 {
				candidates = append(candidates, scoredPetitSong{s, sc})
			}
		}
		if len(candidates) > 0 || qi == len(queries)-1 {
			break
		}
	}
	if len(candidates) == 0 {
		return petitResult{}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })

	cover := petitStartCoverLookup(ctx, candidates, artist, title)
	result := func(s petitSong) petitResult {
		return petitResult{title: s.Title, artist: s.Artist, album: s.Album, isrc: strings.TrimSpace(s.ISRC),
			durationSecs: s.durationSecs()}
	}
	finish := func(r petitResult) petitResult {
		r.cover = cover.wait(ctx, r.isrc)
		return r
	}
	// 逐字只在带逐字的那几份里按名次取前几名:官方的纯文本 / 逐行常排在用户上传的逐字前面,混在一起截前几名会一份逐字都取不到。
	// 搜索结果自带正文的那一条(排第一的)不用再取。
	var words []scoredPetitSong
	for _, c := range candidates {
		if c.song.LyricsType == petitTypeWord && len(words) < petitMaxCandidatesToFetch {
			words = append(words, c)
		}
	}
	fetched := make([]*petitSong, len(words))
	var wg sync.WaitGroup
	for i, c := range words {
		if c.song.LyricsData != "" {
			s := c.song
			fetched[i] = &s
			continue
		}
		wg.Add(1)
		go func(rank int, id string) {
			defer wg.Done()
			s, ok, err := petitFetch(ctx, id, petitTypeWord)
			if err != nil {
				noteLyricSubFetchFailure(ctx)
				return
			}
			if ok {
				fetched[rank] = &s
			}
		}(i, c.song.LyricsID)
	}
	wg.Wait()
	for rank, s := range fetched {
		if s == nil || s.LyricsType != petitTypeWord {
			continue
		}
		if lrc, yrc := petitBuildLyrics(s.LyricsData); isTimedLRC(lrc) {
			r := result(words[rank].song)
			r.lyrics, r.yrc = lrc, yrc
			return finish(r)
		}
	}
	// 都没有能用的逐字:逐行的按名次取前几份,每份时间和纯文本两趟并发取,逐行配上,配上第一份就停。配不上时总分第一的那份
	// 取到的纯文本留着,下面不再取一次。
	top := candidates[0].song
	var topText string
	lineTried := 0
	for _, c := range candidates {
		if c.song.LyricsType != petitTypeLine || lineTried == petitMaxCandidatesToFetch {
			continue
		}
		lineTried++
		lrc, text := petitFetchLineSync(ctx, c.song)
		if lrc != "" {
			r := result(c.song)
			r.lyrics = lrc
			return finish(r)
		}
		if c.song.LyricsID == top.LyricsID {
			topText = text
		}
	}
	// 再没有:名次最高的那份按纯文本取。
	text, ok := topText, topText != ""
	if !ok {
		text, ok = petitFetchPlain(ctx, top.LyricsID)
	}
	if !ok {
		return petitResult{}
	}
	r := result(top)
	r.lyrics, r.plainOnly = text, true
	return finish(r)
}

// petitCoverByISRC:按 ISRC 取一条录音,测试里换成假的。
var petitCoverByISRC = deezerTrackByISRC

// petitCoverLookup:过了闸的候选里第一个带 ISRC 的那条,它在 Deezer 上的专辑封面。isrc 为空 = 没起查询。
type petitCoverLookup struct {
	isrc string
	ch   chan string
}

// petitStartCoverLookup 按名次第一个带 ISRC 的候选起一次 Deezer 查询。Deezer 源关着时不查(同 coverretry.go)。
func petitStartCoverLookup(ctx context.Context, candidates []scoredPetitSong, artist, title string) petitCoverLookup {
	if !lyricSourceEnabled("deezer") {
		return petitCoverLookup{}
	}
	for _, c := range candidates {
		isrc := strings.TrimSpace(c.song.ISRC)
		if isrc == "" {
			continue
		}
		l := petitCoverLookup{isrc: isrc, ch: make(chan string, 1)}
		lookup := petitCoverByISRC
		go func(s petitSong) {
			t, ok := lookup(ctx, isrc)
			if !ok || !petitCoverTrackFits(t, s, artist, title) {
				l.ch <- ""
				return
			}
			l.ch <- t.cover()
		}(c.song)
		return l
	}
	return petitCoverLookup{}
}

// wait:选中的那份歌词跟查询的是同一个 ISRC 时等封面回来,最多等 petitCoverWait。
func (l petitCoverLookup) wait(ctx context.Context, isrc string) string {
	if l.isrc == "" || !strings.EqualFold(l.isrc, isrc) {
		return ""
	}
	timer := time.NewTimer(petitCoverWait)
	defer timer.Stop()
	select {
	case c := <-l.ch:
		return c
	case <-timer.C:
	case <-ctx.Done():
	}
	return ""
}

// petitCoverTrackFits:按 ISRC 取回的那条录音能不能当这份歌词的封面:歌手或曲名对得上(deezerCoverTrackFits,同封面补查),
// 两边都报了时长时差不过 petitMaxDurationDiffSecs。纯函数。
func petitCoverTrackFits(t deezerTrack, s petitSong, artist, title string) bool {
	if !deezerCoverTrackFits(t, []string{s.Artist, artist}, s.Title, title) {
		return false
	}
	if d := s.durationSecs(); d > 0 && t.Duration > 0 && math.Abs(float64(t.Duration)-d) > petitMaxDurationDiffSecs {
		return false
	}
	return true
}

// petitFetchPlain 按 lyricsId 取纯文本那一档。没问成时记一笔(noteLyricSubFetchFailure);回来的不是纯文本、或是空的,ok=false。
func petitFetchPlain(ctx context.Context, id string) (string, bool) {
	s, ok, err := petitFetch(ctx, id, petitTypePlain)
	if err != nil {
		noteLyricSubFetchFailure(ctx)
		return "", false
	}
	if !ok || s.LyricsType != petitTypePlain {
		return "", false
	}
	text := petitPlainText(s.LyricsData)
	return text, text != ""
}

// petitFetchLineSync 取一份逐行:时间那一档(搜索结果自带正文时不再取)和纯文本那一档并发取,配成 LRC。配不上时 lrc 为空,
// text 是取到的纯文本(没取到时为空)。
func petitFetchLineSync(ctx context.Context, song petitSong) (lrc, text string) {
	var (
		wg     sync.WaitGroup
		times  []int
		okT    bool
		zipped string // 纯文本那一档原样的行(没去首尾空白),逐行配对按它数行
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		data := song.LyricsData
		if data == "" {
			s, ok, err := petitFetch(ctx, song.LyricsID, petitTypeLine)
			if err != nil {
				noteLyricSubFetchFailure(ctx)
				return
			}
			if !ok || s.LyricsType != petitTypeLine {
				return
			}
			data = s.LyricsData
		}
		times, okT = petitLineTimes(data)
	}()
	go func() {
		defer wg.Done()
		s, ok, err := petitFetch(ctx, song.LyricsID, petitTypePlain)
		if err != nil {
			noteLyricSubFetchFailure(ctx)
			return
		}
		if ok && s.LyricsType == petitTypePlain {
			text, zipped = petitPlainText(s.LyricsData), petitPlainLines(s.LyricsData)
		}
	}()
	wg.Wait()
	if !okT || text == "" {
		return "", text
	}
	if lrc = petitZipLines(times, zipped); !isTimedLRC(lrc) {
		return "", text
	}
	return lrc, text
}
