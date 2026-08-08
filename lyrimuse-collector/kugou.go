// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"net/http"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// kugouLyric 是歌词第四个候选来源(酷狗音乐,非官方接口:搜索→KRC 歌词库搜索→下载,三步)。
// 只缓存成功(拿到逐行 LRC)的结果,跟 qqLyric/lrclibLyric 的缓存策略一致。是否采用交给
// enrich.go 里统一的 scoreLyricCandidate 打分决定,这里只负责"尽力拿一份候选"。
type kugouResult struct {
	lrc string
	yrc string // 归一化成 YRCParser 语法后的逐字数据,没有则空串
	// title/artist/album 是酷狗曲库里这首歌实际匹配到的歌名/歌手/专辑——纯粹给"搜索
	// 候选歌词"弹窗展示用,不参与任何匹配/打分逻辑,取自搜索结果本身(本来就已经查到,
	// 只是原来没往外传)。酷狗搜索接口没有可靠的封面图字段(AlbumImage 实测经常是空
	// 字符串),这里不尝试凑封面。
	title, artist, album string
}

var (
	kugouMu    sync.Mutex
	kugouCache = map[string]kugouResult{}
)

func kugouLyric(artist, title string, durationSecs float64) kugouResult {
	if title == "" {
		return kugouResult{}
	}
	key := artist + "|" + title
	kugouMu.Lock()
	if v, ok := kugouCache[key]; ok {
		kugouMu.Unlock()
		return v
	}
	kugouMu.Unlock()

	r := resolveKugouLyric(artist, title, durationSecs)
	if r.lrc != "" {
		kugouMu.Lock()
		kugouCache[key] = r
		kugouMu.Unlock()
	}
	return r
}

// krcXORKey 是酷狗 lyrics.kugou.com 下载接口对 fmt=krc(逐字)响应内容加密用的固定
// 16 字节异或密钥——公开算法(社区已逆向),已用真实歌曲验证解密成功(见 krcToYRC 注释)。
var krcXORKey = []byte{0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69}

// decryptKRC 解密 fmt=krc 下载响应的 base64 content:去掉开头 4 字节"krc1"魔数、按位
// 异或 krcXORKey(下标循环)、zlib 解压。任何一步失败都返回空串,不 panic。
func decryptKRC(b64 string) string {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) <= 4 {
		return ""
	}
	body := raw[4:]
	dec := make([]byte, len(body))
	for i, b := range body {
		dec[i] = b ^ krcXORKey[i%len(krcXORKey)]
	}
	zr, err := zlib.NewReader(bytes.NewReader(dec))
	if err != nil {
		return ""
	}
	defer zr.Close()
	out, err := io.ReadAll(zr)
	if err != nil {
		return ""
	}
	return string(out)
}

var (
	krcLineRegex = regexp.MustCompile(`^(\[(\d+),\d+\])(.*)$`)
	krcWordRegex = regexp.MustCompile(`<(\d+),(\d+),(\d+)>`)
)

// krcToYRC 把解密后的酷狗 KRC 正文转换成 YRCParser(desktop-lyrics)认识的语法。
//
// 酷狗原生:"[行始ms,行长ms]<词始ms,词长ms,flag>词"——这里的"词始ms"是相对这一行
// 行始的偏移量,从 0 开始逐词累加,加到这一行的行长为止。网易云原生 YRC:
// "[行始ms,行长ms](词始ms,词长ms,flag)词"——这里的"词始ms"是从整首歌开头算起的绝对
// 时间戳。两种格式外形都是"三个数字加一对括号",实际语义完全不是一回事:若只做尖括号
// →圆括号的语法转换而不做这层相对转绝对的换算,Swift 端(YRCParser 按"词始时间戳=
// 绝对播放位置"这个假设算 fillFraction)读到的词始时间戳会远小于真实播放位置,导致
// 这一行一开始播放,行内所有词的 fillFraction 立刻超过 1(已"填满"),整行瞬间全部
// 点亮,没有逐字推进效果。
//
// 修法:按行处理,每行先读出行始时间戳,再把行内每个词的相对偏移量都加上行始时间戳、
// 换算成绝对时间戳,才落成 YRCParser 认的语法。只对精确匹配 <数字,数字,数字> 的片段
// 动手,不做裸字符 Replace,避免歌词正文里偶然出现的尖括号被误伤。行头 [行始,行长] 和
// LRC 署名头([ti:]/[ar:] 等)本来就跟 YRC 兼容/会被 YRCParser 自然跳过,原样保留。
func krcToYRC(krc string) string {
	if krc == "" {
		return ""
	}
	normalized := strings.ReplaceAll(krc, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	lines := strings.Split(normalized, "\n")
	for i, line := range lines {
		m := krcLineRegex.FindStringSubmatch(line)
		if m == nil {
			continue // 署名头/其它不含 [行始,行长] 前缀的行,原样保留
		}
		lineStart, err := strconv.Atoi(m[2])
		if err != nil {
			continue
		}
		body := krcWordRegex.ReplaceAllStringFunc(m[3], func(match string) string {
			wm := krcWordRegex.FindStringSubmatch(match)
			wordStart, _ := strconv.Atoi(wm[1]) // 已经过 \d+ 校验,不会解析失败
			return fmt.Sprintf("(%d,%s,%s)", lineStart+wordStart, wm[2], wm[3])
		})
		lines[i] = m[1] + body
	}
	return strings.Join(lines, "\n")
}

type kugouSong struct {
	Hash       string  `json:"hash"`
	SongName   string  `json:"songname"`
	SingerName string  `json:"singername"`
	AlbumName  string  `json:"album_name"`
	Duration   float64 `json:"duration"` // 秒
}

// kugouEscape 编码查询参数值。mobilecdn.kugou.com/krcs.kugou.com 这两个接口不认标准
// application/x-www-form-urlencoded 里空格编码成 "+" 的写法(会直接搜出 0 结果),必须
// 编码成 "%20"——neturl.QueryEscape 对除空格外的字符转义规则都对,只把它的 "+" 输出替换
// 成 "%20" 即可,不用换成 PathEscape(PathEscape 不转义 "&"/"="等 query 里有特殊含义的
// 字符,遇到"Prince & The Revolution"这类歌手名会把 & 直接拼进 query 破坏参数边界)。
func kugouEscape(s string) string {
	return strings.ReplaceAll(neturl.QueryEscape(s), "+", "%20")
}

func kugouGet(u string, v any) error {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// resolveKugouLyric:①搜索拿 hash/时长(歌手名+歌名都要对上,同 netease/qq 的身份校验);
// ②用 hash+时长 查 KRC 歌词库候选(krcs.kugou.com,官方推荐候选优先,取第一条);
// ③用候选的 id+accesskey 下载两次(lyrics.kugou.com,分别 fmt=lrc 整行、fmt=krc 逐字,
// 同一个 id/accesskey,只是 fmt 参数不同)。lrc 失败则整体放弃;krc 单独失败不影响 lrc
// (逐字数据本来就是"有更好、没有也不影响整行可用"的加分项)。任何一步
// 失败/拿不到都直接放弃,不重试(下次 enrich 短 TTL 到期自然再试)。
func resolveKugouLyric(artist, title string, durationSecs float64) kugouResult {
	var sr struct {
		Data struct {
			Info []kugouSong `json:"info"`
		} `json:"data"`
	}
	q := artist + " " + title
	if err := kugouGet("http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword="+kugouEscape(q)+"&page=1&pagesize=10&showtype=1", &sr); err != nil {
		return kugouResult{}
	}
	var chosen *kugouSong
	for i := range sr.Data.Info {
		s := &sr.Data.Info[i]
		if s.Hash == "" || !lyricTitleAccepted(s.SongName, title) ||
			!artistMatches(s.SingerName, artist) {
			continue
		}
		chosen = s
		break
	}
	if chosen == nil {
		return kugouResult{}
	}
	durMs := int64(chosen.Duration * 1000)
	if durMs <= 0 && durationSecs > 0 {
		durMs = int64(durationSecs * 1000)
	}
	var kr struct {
		Candidates []struct {
			ID        string `json:"id"`
			AccessKey string `json:"accesskey"`
		} `json:"candidates"`
	}
	krcURL := fmt.Sprintf("http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=%s&duration=%d&hash=%s",
		kugouEscape(artist+" - "+title), durMs, chosen.Hash)
	if err := kugouGet(krcURL, &kr); err != nil || len(kr.Candidates) == 0 {
		return kugouResult{}
	}
	c := kr.Candidates[0]
	if c.ID == "" || c.AccessKey == "" {
		return kugouResult{}
	}
	var dl struct {
		Content string `json:"content"`
	}
	dlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=lrc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(dlURL, &dl); err != nil || dl.Content == "" {
		return kugouResult{}
	}
	raw, err := base64.StdEncoding.DecodeString(dl.Content)
	if err != nil {
		return kugouResult{}
	}
	lrc := string(raw)
	if !isTimedLRC(lrc) {
		return kugouResult{}
	}

	var yrc string
	var krcDl struct {
		Content string `json:"content"`
	}
	krcDlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=krc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(krcDlURL, &krcDl); err == nil && krcDl.Content != "" {
		if decrypted := decryptKRC(krcDl.Content); decrypted != "" {
			yrc = krcToYRC(decrypted)
		}
	}
	return kugouResult{lrc: lrc, yrc: yrc, title: chosen.SongName, artist: chosen.SingerName, album: chosen.AlbumName}
}
