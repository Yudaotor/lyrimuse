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
//     专辑搜索(type=10)与按歌手泛搜 /api/search/get → /api/search/get/web → /eapi/search/get
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

// neteaseCloudSearchEndpoint 是搜歌的第四条路径。结果里的字段名跟 search/get 不同
// (ar / al / dt 对 artists / album / duration),neteaseSearchSongs 负责归一。
const neteaseCloudSearchEndpoint = "https://music.163.com/api/cloudsearch/pc"

// neteaseSearchSongs 按 search/get → search/get/web → eapi 的 search/get → cloudsearch/pc 的顺序搜歌,每条路径
// 内部由 get(resolveNeteaseInfo 里那个)按主机退。
//
// 一条路径答了、但答的不能用(neteaseSearchVerdict:result 不是对象、songs 解不开,或者有歌却没有一首跟查询词沾边),
// 照没问成处理、接着问下一条。各条都不能用时交回第一份解得开的结果(跟只问第一条时一样);一份解得开的都没有才返回错误,
// 优先交 search/get 几条的错误,它们都没报错(被跳过或答的解不开)时交 cloudsearch 的。
// 前面几条答的不能用、后面一条答的能用,算前面几条在这台机器上答垃圾的一次实证,连着几次就先跳过(neteaseSearchJunkSkipped)。
// cloudsearch 是最后一条,从不跳过。见 09 章决策 378。
func neteaseSearchSongs(get func(string, any) error, q string) ([]neSearchSong, error) {
	escaped := neturl.QueryEscape(q)
	const query = "?type=1&limit=30&s="
	var err error
	var junk []string
	var firstSongs []neSearchSong
	for _, endpoint := range []string{neteaseSearchEndpointPrimary, neteaseSearchEndpointFallback, neteaseSearchEndpointEapi} {
		if neteaseSearchJunkSkipped(endpoint) {
			continue
		}
		var r struct {
			Result json.RawMessage `json:"result"`
		}
		if gerr := get(endpoint+query+escaped, &r); gerr != nil {
			err = gerr
			continue
		}
		songs, why := neteaseSearchVerdict(r.Result, q)
		if why == "" {
			neteaseSearchJunkSettle(endpoint, junk)
			return songs, nil
		}
		log.Printf("netease: %s answered an unusable search for %q (%s), trying the next path", neteaseEndpointBucket(endpoint), q, why)
		junk = append(junk, endpoint)
		if firstSongs == nil {
			firstSongs = songs
		}
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
	if cerr := get(neteaseCloudSearchEndpoint+query+escaped, &c); cerr != nil {
		if firstSongs != nil {
			return firstSongs, nil
		}
		if err != nil {
			return nil, err
		}
		return nil, cerr
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
	if len(songs) > 0 && neteaseSearchOverlaps(q, texts) {
		neteaseSearchJunkSettle("", junk)
		return songs, nil
	}
	if firstSongs != nil {
		return firstSongs, nil
	}
	return songs, nil
}

// neteaseSearchVerdict 判 search/get 一类路径答回来的 result 能不能用,能用时 why 为空。
// 没有 result、result 是 null 或者 songs 是空的,算「确实没有」,能用。result 不是对象(有的地区出口回加密的十六进制串)、
// songs 解不开,或者有歌却没有一首跟查询词沾边(neteaseSearchOverlaps;有的地区出口不管搜什么都回同一批无关的歌),不能用。
// 后一种 songs 照样交回,给各条都不能用时兜底。
func neteaseSearchVerdict(raw json.RawMessage, q string) (songs []neSearchSong, why string) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, ""
	}
	if trimmed[0] != '{' {
		return nil, "result is not an object"
	}
	var r struct {
		Songs []neSearchSong `json:"songs"`
	}
	if json.Unmarshal(trimmed, &r) != nil {
		return nil, "songs undecodable"
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
	if json.Unmarshal(trimmed, &t) != nil {
		return nil, "songs undecodable"
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
	if !neteaseSearchOverlaps(q, texts) {
		return r.Songs, "no result shares a word with the query"
	}
	return r.Songs, ""
}

// neteaseSearchOverlaps:texts 里有没有一首(一组字段:歌名、专辑、别名、歌手)跟查询词沾边。查询词按 albumTokens 切词
// (繁简、大小写、变音折叠,数字 / 拉丁 / CJK 交界处断开,单字和虚词不算),每个词再过 normLoose(全角字母数字折半角);
// 某个词出现在某个字段里(字段也过 normLoose),或者某个字段里两字以上的一段 CJK 出现在某个查询词里(查询词里中日文常连写),
// 就算沾边。查询词切不出词时判不了,按沾边算。
func neteaseSearchOverlaps(q string, texts [][]string) bool {
	var tokens []string
	for t := range albumTokens(q) {
		if n := normLoose(t); utf8.RuneCountInString(n) >= 2 {
			tokens = append(tokens, n)
		}
	}
	if len(tokens) == 0 {
		return true
	}
	for _, fields := range texts {
		for _, f := range fields {
			nf := normLoose(f)
			if nf == "" {
				continue
			}
			for _, t := range tokens {
				if strings.Contains(nf, t) {
					return true
				}
			}
			for ft := range albumTokens(f) {
				ft = normLoose(ft)
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
