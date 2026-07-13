// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
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

var krcWordRegex = regexp.MustCompile(`<(\d+),(\d+),(\d+)>`)

// krcToYRC 把解密后的酷狗 KRC 正文转换成 YRCParser(desktop-lyrics)认识的语法。酷狗
// 原生就是"[行始ms,行长ms]<词始ms,词长ms,flag>词"这种尖括号写法,跟网易云 YRC 的圆括号
// 写法结构完全一样(同样 3 个数字、词紧跟在标记后面),只需把尖括号换成圆括号,不用重排
// 词序、不用补数字。用正则精确匹配 <数字,数字,数字> 再替换,而不是裸字符 Replace 全局
// 换 </>,避免歌词正文里偶然出现的尖括号被误伤(虽然实测目前没见过这种情况,但更安全)。
// 行头 [行始,行长] 和 LRC 署名头([ti:]/[ar:] 等)本来就跟 YRC 兼容/会被 YRCParser 自然
// 跳过,不用额外处理。
func krcToYRC(krc string) string {
	if krc == "" {
		return ""
	}
	return krcWordRegex.ReplaceAllString(krc, "($1,$2,$3)")
}

type kugouSong struct {
	Hash       string  `json:"hash"`
	SongName   string  `json:"songname"`
	SingerName string  `json:"singername"`
	Duration   float64 `json:"duration"` // 秒
}

// kugouEscape 编码查询参数值。实测坐实:mobilecdn.kugou.com/krcs.kugou.com 这两个接口
// 不认标准 application/x-www-form-urlencoded 里空格编码成 "+" 的写法(会直接搜出 0
// 结果),必须编码成 "%20"——neturl.QueryEscape 对除空格外的字符转义规则都对,只把它的
// "+" 输出替换成 "%20" 即可,不用换成 PathEscape(PathEscape 不转义 "&"/"="等query里
// 有特殊含义的字符,遇到"Prince & The Revolution"这类歌手名会把 & 直接拼进 query 破坏
// 参数边界)。
func kugouEscape(s string) string {
	return strings.ReplaceAll(neturl.QueryEscape(s), "+", "%20")
}

func kugouGet(u string, v any) error {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := (&http.Client{Timeout: 6 * time.Second}).Do(req)
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
// 同一个 id/accesskey,只是 fmt 参数不同)。lrc 失败则整体放弃(跟原来一样);krc 单独
// 失败不影响 lrc(逐字数据本来就是"有更好、没有也不影响整行可用"的加分项)。任何一步
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
		if s.Hash == "" || !looseContains(s.SongName, title) || !artistMatches(s.SingerName, artist) {
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
	return kugouResult{lrc: lrc, yrc: yrc}
}
