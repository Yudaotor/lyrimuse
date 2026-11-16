package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// ---- 网易云各接口的备用 ----
//
// 同 qqfallback.go 的思路,两层:
//   - 同一个接口的备用主机:网易云的接口都挂在 neteaseHosts 这几个主机上,路径和响应一致。
//     neteaseFetchBody 按顺序试,只有没问成(传输失败 / 非 200 / 读不出响应体)才换下一个主机。
//     响应体里的拒绝码(限流)**不换主机**:网易云按接口路径分桶限流(neteaseEndpointBucket 只看
//     路径),换主机绕不过去,还是在对着同一个桶撞;这类由各调用方照旧退避这个桶、换另一条路径。
//   - 同一功能的另一条路径(另一个桶):
//     搜歌 /api/search/get → /api/search/get/web → /eapi/search/get → /api/cloudsearch/pc(字段名不同,见 neteaseSearchSongs)
//     单曲详情 /api/song/detail → /api/v3/song/detail(字段名 al / ar / dt)→ /eapi/song/detail
//     歌词 /api/song/lyric/v1(整行 / 译文 / 罗马音 / 逐字一次取齐,署名行见 neteaseV1LyricLines)→ /eapi/song/lyric/v1
//       → /api/song/lyric(没有逐字)
//     专辑曲目 /api/album/{id} → /api/v1/album/{id} → /eapi/album/{id}
//     专辑搜索(type=10)、按歌手泛搜、按歌词搜:同样这四条(neteaseSearchPaths;曲目字段名在 neteaseSongSearchVerdict 归一)
//   - /eapi/ 开头的是网易云客户端用的加密写法:跟去掉 e 的 /api/ 是同一个接口、同一份返回,只是请求改成 POST、
//     查询参数加密进表单(neteaseNewRequest)。每条链各补一条,明文路径整条被拒或被封时还有它。
//
// 主机和字段都逐个实测过,实测记录见 docs/features/09 第 88 条,eapi 见第 143 条。

var neteaseHosts = []string{"music.163.com", "interface.music.163.com", "interface3.music.163.com"}

// neteaseHostURLs 把一条 music.163.com 上的地址展开成 neteaseHosts 上的同一条地址,按顺序。
// 不是这几个主机的地址原样返回一条。
func neteaseHostURLs(rawURL string) []string {
	u, err := neturl.Parse(rawURL)
	if err != nil || u.Host != neteaseHosts[0] {
		return []string{rawURL}
	}
	out := make([]string, 0, len(neteaseHosts))
	for _, h := range neteaseHosts {
		v := *u
		v.Host = h
		out = append(out, v.String())
	}
	return out
}

// neteaseFetchBody 发一个网易云 GET,按 neteaseHosts 顺序试,返回第一个 HTTP 200 的响应体。
// 每次尝试前都过 neteaseThrottle(按路径分桶,各主机共用一个桶);桶在退避中时整条放弃,不换主机。
// cookie 非空时带上(专辑接口要 os=pc)。
func neteaseFetchBody(ctx context.Context, rawURL, cookie string, timeout time.Duration) ([]byte, error) {
	cli := lyricHTTPClient(timeout)
	var lastErr error = errors.New("netease: not reached")
	for _, u := range neteaseHostURLs(rawURL) {
		if err := neteaseThrottle(ctx, u); err != nil {
			return nil, err
		}
		body, err := neteaseFetchBodyAt(ctx, cli, u, cookie)
		if err == nil {
			return body, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return nil, lastErr
}

func neteaseFetchBodyAt(ctx context.Context, cli *http.Client, u, cookie string) ([]byte, error) {
	req, err := neteaseNewRequest(ctx, u)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://music.163.com/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
	}
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, lyricSourceResponseMaxBytes))
}

// neteaseEapiKey:eapi 请求体的 AES-128 密钥。网易云客户端协议里的固定常量,各开源实现通用,不是账号凭据。
const neteaseEapiKey = "e82ckenh8dichen8"

// neteaseNewRequest 建一个网易云请求。路径以 /eapi/ 开头的按 eapi 写法发:POST 到同一地址(去掉查询串),
// 查询参数原样当字符串放进 JSON,加密成表单字段 params;返回仍是明文 JSON。别的路径照常 GET。
func neteaseNewRequest(ctx context.Context, rawURL string) (*http.Request, error) {
	u, err := neturl.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	rest, ok := strings.CutPrefix(u.Path, "/eapi/")
	if !ok {
		return http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	}
	data := map[string]string{}
	for k, v := range u.Query() {
		data[k] = v[0]
	}
	params, err := neteaseEapiParams("/api/"+rest, data)
	if err != nil {
		return nil, err
	}
	u.RawQuery = ""
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), strings.NewReader("params="+params))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return req, nil
}

// neteaseEapiParams 算 eapi 的表单字段 params:明文是「接口路径-36cd479b6b5-JSON-36cd479b6b5-校验」,校验是
// md5("nobody" + 接口路径 + "use" + JSON + "md5forencrypt") 的十六进制;AES-128-ECB + PKCS#7 加密后转大写十六进制。
// 接口路径是 /api/ 开头的那个写法。
func neteaseEapiParams(apiPath string, data map[string]string) (string, error) {
	text, err := json.Marshal(data)
	if err != nil {
		return "", err
	}
	sum := md5.Sum([]byte("nobody" + apiPath + "use" + string(text) + "md5forencrypt"))
	msg := []byte(apiPath + "-36cd479b6b5-" + string(text) + "-36cd479b6b5-" + hex.EncodeToString(sum[:]))
	pad := aes.BlockSize - len(msg)%aes.BlockSize
	msg = append(msg, bytes.Repeat([]byte{byte(pad)}, pad)...)
	block, err := aes.NewCipher([]byte(neteaseEapiKey))
	if err != nil {
		return "", err
	}
	for i := 0; i < len(msg); i += aes.BlockSize {
		block.Encrypt(msg[i:i+aes.BlockSize], msg[i:i+aes.BlockSize])
	}
	return strings.ToUpper(hex.EncodeToString(msg)), nil
}

// neteaseCloudSearchEndpoint 是搜索的第四条路径。搜歌(type=1、1006)结果里的字段名跟 search/get 不同
// (ar / al / dt / alia / tns 对 artists / album / duration / alias / transNames),专辑搜索(type=10)同名。
const neteaseCloudSearchEndpoint = "https://music.163.com/api/cloudsearch/pc"

// neteaseSearchAnswer:一条搜索路径答回来、判过能不能用的结果。n 是结果条数;why 非空是不能用(写进日志)。
// 不能用但 n > 0 的(有结果、一条都不沾边)留着,给各条都不能用时兜底。
type neteaseSearchAnswer[T any] struct {
	val T
	n   int
	why string
}

// neteaseSearchPaths 按 search/get → search/get/web → eapi 的 search/get → cloudsearch/pc 的顺序问同一个查询串 query
// (? 开头),ask 问一条并判能不能用(没问成交 error;cloud 表示问的是 cloudsearch)。q 是查询词,只用来写日志。
//
// 一条路径答了、但答的不能用(result 不是对象、列表解不开,或者有结果却没有一条跟查询词沾边),照没问成处理、接着问下一条。
// 前三条答的「确实没有」(没有 result / null / 空列表)算能用;cloudsearch 答空不算,也不算它答垃圾。
// 各条都不能用时交回第一份解得开的结果(跟只问第一条时一样);一份解得开的都没有才返回错误,
// 优先交 search/get 几条的错误,它们都没报错(被跳过或答的解不开)时交 cloudsearch 的。
// 前面几条答的不能用、后面一条答的能用,算前面几条在这台机器上答垃圾的一次实证,连着几次就先跳过(neteaseSearchJunkSkipped)。
// cloudsearch 是最后一条,从不跳过。见 09 章决策 378、380。
func neteaseSearchPaths[T any](q, query string, ask func(u string, cloud bool) (neteaseSearchAnswer[T], error)) (T, error) {
	var zero T
	var err error
	var junk []string
	var first *neteaseSearchAnswer[T]
	for _, endpoint := range []string{neteaseSearchEndpointPrimary, neteaseSearchEndpointFallback, neteaseSearchEndpointEapi} {
		if neteaseSearchJunkSkipped(endpoint) {
			continue
		}
		a, aerr := ask(endpoint+query, false)
		if aerr != nil {
			err = aerr
			continue
		}
		if a.why == "" {
			neteaseSearchJunkSettle(endpoint, junk)
			return a.val, nil
		}
		log.Printf("netease: %s answered an unusable search for %q (%s), trying the next path", neteaseEndpointBucket(endpoint), q, a.why)
		junk = append(junk, endpoint)
		if first == nil && a.n > 0 {
			first = &a
		}
	}
	a, cerr := ask(neteaseCloudSearchEndpoint+query, true)
	if cerr == nil && a.why != "" && a.n == 0 {
		cerr = fmt.Errorf("netease: cloudsearch answered an unusable search (%s)", a.why)
	}
	if cerr != nil {
		if first != nil {
			return first.val, nil
		}
		if err != nil {
			return zero, err
		}
		return zero, cerr
	}
	if a.why == "" && a.n > 0 {
		neteaseSearchJunkSettle("", junk)
		return a.val, nil
	}
	if first != nil {
		return first.val, nil
	}
	return a.val, nil
}

// neteaseSearchSongs 搜歌(type=1),四条路径和判定见 neteaseSearchPaths;每条路径内部由 get(resolveNeteaseInfo 里那个)按主机退。
// cloudsearch 的字段名在这里归一回 neSearchSong。
func neteaseSearchSongs(get func(string, any) error, q string) ([]neSearchSong, error) {
	return neteaseSearchPaths(q, "?type=1&limit=30&s="+neturl.QueryEscape(q), func(u string, cloud bool) (neteaseSearchAnswer[[]neSearchSong], error) {
		if !cloud {
			var r struct {
				Result json.RawMessage `json:"result"`
			}
			if err := get(u, &r); err != nil {
				return neteaseSearchAnswer[[]neSearchSong]{}, err
			}
			songs, why := neteaseSearchVerdict(r.Result, q)
			return neteaseSearchAnswer[[]neSearchSong]{val: songs, n: len(songs), why: why}, nil
		}
		var c struct {
			Result struct {
				Songs []struct {
					ID   int64    `json:"id"`
					Name string   `json:"name"`
					Alia []string `json:"alia"`
					Tns  []string `json:"tns"`
					Dt   float64  `json:"dt"`
					Ar   []struct {
						Name string `json:"name"`
					} `json:"ar"`
					Al struct {
						ID     int64  `json:"id"`
						Name   string `json:"name"`
						PicURL string `json:"picUrl"`
					} `json:"al"`
				} `json:"songs"`
			} `json:"result"`
		}
		if err := get(u, &c); err != nil {
			return neteaseSearchAnswer[[]neSearchSong]{}, err
		}
		songs := make([]neSearchSong, 0, len(c.Result.Songs))
		texts := make([][]string, 0, len(c.Result.Songs))
		for _, s := range c.Result.Songs {
			var song neSearchSong
			song.ID, song.Name, song.Duration = s.ID, s.Name, s.Dt
			song.Album.ID, song.Album.Name, song.Album.PicURL = s.Al.ID, s.Al.Name, s.Al.PicURL
			fields := append([]string{s.Name, s.Al.Name}, s.Alia...)
			fields = append(fields, s.Tns...)
			for _, a := range s.Ar {
				song.Artists = append(song.Artists, struct {
					Name string `json:"name"`
				}{Name: a.Name})
				fields = append(fields, a.Name)
			}
			songs = append(songs, song)
			texts = append(texts, fields)
		}
		return neteaseSearchJudged(songs, texts, q, normLoose), nil
	})
}

// neteaseSearchJudged:list 有结果却没有一条跟查询词沾边(neteaseSearchOverlaps,texts 是每条的字段)时判不能用。
func neteaseSearchJudged[T any](list []T, texts [][]string, q string, norm func(string) string) neteaseSearchAnswer[[]T] {
	a := neteaseSearchAnswer[[]T]{val: list, n: len(list)}
	if len(list) > 0 && !neteaseSearchOverlaps(norm, q, texts) {
		a.why = "no result shares a word with the query"
	}
	return a
}

// neteaseSearchDecode 把 search/get 一类路径答回来的 result 解进 v。没有 result、result 是 null 时 v 不动(确实没有);
// result 不是对象(有的地区出口回加密的十六进制串)或解不开时交回原因。
func neteaseSearchDecode(raw json.RawMessage, v any) string {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return ""
	}
	if trimmed[0] != '{' {
		return "result is not an object"
	}
	if json.Unmarshal(trimmed, v) != nil {
		return "result undecodable"
	}
	return ""
}

// neteaseSearchVerdict 判 search/get 一类路径搜歌(type=1)答回来的 result 能不能用,能用时 why 为空。
// 没有 result、result 是 null 或者 songs 是空的,算「确实没有」,能用。result 不是对象、songs 解不开,
// 或者有歌却没有一首跟查询词沾边(neteaseSearchOverlaps;有的地区出口不管搜什么都回同一批无关的歌),不能用。
// 后一种 songs 照样交回,给各条都不能用时兜底。
func neteaseSearchVerdict(raw json.RawMessage, q string) (songs []neSearchSong, why string) {
	var r struct {
		Songs []neSearchSong `json:"songs"`
	}
	if why := neteaseSearchDecode(raw, &r); why != "" {
		return nil, why
	}
	if len(r.Songs) == 0 {
		return r.Songs, ""
	}
	var t struct {
		Songs []struct {
			Name       string   `json:"name"`
			Alias      []string `json:"alias"`
			TransNames []string `json:"transNames"`
			Artists    []struct {
				Name string `json:"name"`
			} `json:"artists"`
			Album struct {
				Name string `json:"name"`
			} `json:"album"`
		} `json:"songs"`
	}
	if json.Unmarshal(bytes.TrimSpace(raw), &t) != nil {
		return nil, "result undecodable"
	}
	texts := make([][]string, 0, len(t.Songs))
	for _, s := range t.Songs {
		fields := append([]string{s.Name, s.Album.Name}, s.Alias...)
		fields = append(fields, s.TransNames...)
		for _, a := range s.Artists {
			fields = append(fields, a.Name)
		}
		texts = append(texts, fields)
	}
	a := neteaseSearchJudged(r.Songs, texts, q, normLoose)
	return a.val, a.why
}

// neteaseSearchAlbum:专辑搜索(type=10)结果里的一张。search/get 一类和 cloudsearch 字段同名。
type neteaseSearchAlbum struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Artist struct {
		Name string `json:"name"`
	} `json:"artist"`
	Artists []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Alias      []string `json:"alias"`
	TransNames []string `json:"transNames"`
}

// neteaseAlbumSearchVerdict 判专辑搜索答回来的 result,口径同 neteaseSearchVerdict(沾边看专辑名、别名、歌手)。
// search/get 一类还带 hlWords(服务端认出的查询词):正常出口原样回查询词,答垃圾的出口回一个跟查询词无关的数字(「-53」「84」),
// 它也算一个字段:结果跟查询词毫不相干、但服务端认的是这个查询词时,是网易云真没有,能用,不多打请求。
func neteaseAlbumSearchVerdict(raw json.RawMessage, q string) neteaseSearchAnswer[[]neteaseSearchAlbum] {
	var r struct {
		HlWords []string             `json:"hlWords"`
		Albums  []neteaseSearchAlbum `json:"albums"`
	}
	if why := neteaseSearchDecode(raw, &r); why != "" {
		return neteaseSearchAnswer[[]neteaseSearchAlbum]{why: why}
	}
	texts := make([][]string, 0, len(r.Albums)+1)
	texts = append(texts, r.HlWords)
	for _, a := range r.Albums {
		fields := append([]string{a.Name, a.Artist.Name}, a.Alias...)
		fields = append(fields, a.TransNames...)
		for _, ar := range a.Artists {
			fields = append(fields, ar.Name)
		}
		texts = append(texts, fields)
	}
	return neteaseSearchJudged(r.Albums, texts, q, normLoose)
}

// neteaseSearchHit:neteaseSongSearch 结果里的一首,search/get 一类(artists / album / duration / alias / transNames)和
// cloudsearch(ar / al / dt / alia / tns)两种字段名都收。lyrics 是按歌词搜时带回的那段歌词:search/get 一类是 {"txt": …},
// cloudsearch 是一组字符串。
type neteaseSearchHit struct {
	Name     string  `json:"name"`
	Duration float64 `json:"duration"`
	Dt       float64 `json:"dt"`
	Artists  []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Ar []struct {
		Name string `json:"name"`
	} `json:"ar"`
	Album struct {
		Name string `json:"name"`
	} `json:"album"`
	Al struct {
		Name string `json:"name"`
	} `json:"al"`
	Alias      []string        `json:"alias"`
	Alia       []string        `json:"alia"`
	TransNames []string        `json:"transNames"`
	Tns        []string        `json:"tns"`
	Lyrics     json.RawMessage `json:"lyrics"`
}

// neteaseSearchHitLyrics 取 lyrics 里的歌词文字;认不出的写法交空。
func neteaseSearchHitLyrics(raw json.RawMessage) []string {
	var lines []string
	if json.Unmarshal(raw, &lines) == nil {
		return lines
	}
	var o struct {
		Txt string `json:"txt"`
	}
	if json.Unmarshal(raw, &o) == nil && o.Txt != "" {
		return []string{o.Txt}
	}
	return nil
}

// neteaseSongSearchVerdict 判 neteaseSongSearch 答回来的 result,口径同 neteaseSearchVerdict,沾边还看带回的歌词
// (按歌词搜时查询词是一句歌词)。norm 是给字段和查询词折写法的:歌词又长又几乎不重复,得用 normLooseUncached,
// 别灌进 normLoose 的备忘表。
func neteaseSongSearchVerdict(raw json.RawMessage, q string, norm func(string) string) neteaseSearchAnswer[[]neteaseSearchSong] {
	var r struct {
		Songs []neteaseSearchHit `json:"songs"`
	}
	if why := neteaseSearchDecode(raw, &r); why != "" {
		return neteaseSearchAnswer[[]neteaseSearchSong]{why: why}
	}
	songs := make([]neteaseSearchSong, 0, len(r.Songs))
	texts := make([][]string, 0, len(r.Songs))
	for _, h := range r.Songs {
		s := neteaseSearchSong{Name: h.Name, Duration: h.Duration}
		if s.Duration == 0 {
			s.Duration = h.Dt
		}
		fields := []string{h.Name, h.Album.Name, h.Al.Name}
		for _, list := range [][]string{h.Alias, h.Alia, h.TransNames, h.Tns, neteaseSearchHitLyrics(h.Lyrics)} {
			fields = append(fields, list...)
		}
		for _, a := range append(h.Artists, h.Ar...) {
			s.Artists = append(s.Artists, a)
			fields = append(fields, a.Name)
		}
		songs = append(songs, s)
		texts = append(texts, fields)
	}
	return neteaseSearchJudged(songs, texts, q, norm)
}

// neteaseSearchOverlaps:texts 里有没有一条(一组字段:歌名、专辑、别名、歌手)跟查询词沾边。查询词按 albumTokens 切词
// (繁简、大小写、变音折叠,数字 / 拉丁 / CJK 交界处断开,单字和虚词不算),每个词再过 norm(normLoose 或 normLooseUncached,
// 全角字母数字折半角);某个词出现在某个字段里(字段也过 norm),或者某个字段里两字以上的一段 CJK 出现在某个查询词里
// (查询词里中日文常连写),就算沾边。查询词切不出词时判不了,按沾边算。
func neteaseSearchOverlaps(norm func(string) string, q string, texts [][]string) bool {
	var tokens []string
	for t := range albumTokens(q) {
		if n := norm(t); utf8.RuneCountInString(n) >= 2 {
			tokens = append(tokens, n)
		}
	}
	if len(tokens) == 0 {
		return true
	}
	for _, fields := range texts {
		for _, f := range fields {
			nf := norm(f)
			if nf == "" {
				continue
			}
			for _, t := range tokens {
				if strings.Contains(nf, t) {
					return true
				}
			}
			for ft := range albumTokens(f) {
				ft = norm(ft)
				r, _ := utf8.DecodeRuneInString(ft)
				if utf8.RuneCountInString(ft) < 2 || !isCJKRune(r) {
					continue
				}
				for _, t := range tokens {
					if strings.Contains(t, ft) {
						return true
					}
				}
			}
		}
	}
	return false
}

// 一条 search/get 类路径连着 neteaseSearchJunkStrikes 次被实证答垃圾(它答的不能用、同一次搜索里后面一条答的能用),
// 之后 neteaseSearchJunkSkipFor 这么久里搜歌不问它;它答一次能用的就清零。到期后照常问,还是垃圾就立刻再跳过。
// 只在进程内记,不落盘。
const (
	neteaseSearchJunkStrikes = 2
	neteaseSearchJunkSkipFor = 30 * time.Minute
)

type neteaseSearchJunkState struct {
	strikes int
	until   time.Time
}

var (
	neteaseSearchJunkMu  sync.Mutex
	neteaseSearchJunk    = map[string]neteaseSearchJunkState{}
	neteaseSearchJunkNow = time.Now
)

func neteaseSearchJunkSkipped(endpoint string) bool {
	neteaseSearchJunkMu.Lock()
	defer neteaseSearchJunkMu.Unlock()
	return neteaseSearchJunkNow().Before(neteaseSearchJunk[endpoint].until)
}

// neteaseSearchJunkSettle 在一次搜索拿到能用的结果后调:answered 是答出能用结果的那条(cloudsearch 传空),清零;
// junk 是同一次搜索里在它前面答了不能用的那几条,各记一次。
func neteaseSearchJunkSettle(answered string, junk []string) {
	neteaseSearchJunkMu.Lock()
	defer neteaseSearchJunkMu.Unlock()
	if answered != "" {
		delete(neteaseSearchJunk, answered)
	}
	for _, endpoint := range junk {
		st := neteaseSearchJunk[endpoint]
		st.strikes++
		if st.strikes >= neteaseSearchJunkStrikes {
			st.until = neteaseSearchJunkNow().Add(neteaseSearchJunkSkipFor)
			log.Printf("netease: %s keeps answering unusable searches (%d in a row), skipping it for %s",
				neteaseEndpointBucket(endpoint), st.strikes, neteaseSearchJunkSkipFor)
		}
		neteaseSearchJunk[endpoint] = st
	}
}

// neteaseV1LyricLines 把 /api/song/lyric/v1 整行歌词里 JSON 格式的署名行(`{"t":1000,"c":[{"tx":"作词: "},{"tx":"某某"}]}`)
// 换回 /api/song/lyric 的写法(`[00:01.00] 作词 : 某某`),其余原样。换完跟老接口的正文逐行一致(实测),
// 下游的署名行判定、行数都照旧。t 为负(没词的曲目给的占位)按 0 算;没有 t(纯文本歌词)时老接口也不带时间戳,照样不带。
func neteaseV1LyricLines(s string) string {
	if !strings.Contains(s, "\n{") && !strings.HasPrefix(s, "{") {
		return s
	}
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if !strings.HasPrefix(t, "{") {
			out = append(out, l)
			continue
		}
		var credit struct {
			T *int `json:"t"`
			C []struct {
				Tx string `json:"tx"`
			} `json:"c"`
		}
		if json.Unmarshal([]byte(t), &credit) != nil {
			continue
		}
		var b strings.Builder
		for _, c := range credit.C {
			b.WriteString(c.Tx)
		}
		text := strings.TrimSpace(b.String())
		if label, name, ok := strings.Cut(text, ":"); ok {
			text = strings.TrimSpace(label) + " : " + strings.TrimSpace(name)
		}
		switch {
		case text == "":
		case credit.T == nil:
			out = append(out, text)
		default:
			out = append(out, lrcTimestamp(max(*credit.T, 0))+" "+text)
		}
	}
	return strings.Join(out, "\n")
}
