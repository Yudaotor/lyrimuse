// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

// kugouLyric 是歌词第四个候选来源(酷狗音乐,非官方接口:搜索→KRC 歌词库搜索→下载,三步)。
// 只缓存成功(拿到逐行 LRC)的结果,跟 qqLyric/lrclibLyric 的缓存策略一致。是否采用交给
// enrich.go 里统一的 scoreLyricCandidate 打分决定,这里只负责"尽力拿一份候选"。
var (
	kugouMu    sync.Mutex
	kugouCache = map[string]string{}
)

func kugouLyric(artist, title string, durationSecs float64) string {
	if title == "" {
		return ""
	}
	key := artist + "|" + title
	kugouMu.Lock()
	if v, ok := kugouCache[key]; ok {
		kugouMu.Unlock()
		return v
	}
	kugouMu.Unlock()

	l := resolveKugouLyric(artist, title, durationSecs)
	if l != "" {
		kugouMu.Lock()
		kugouCache[key] = l
		kugouMu.Unlock()
	}
	return l
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
// ③用候选的 id+accesskey 下载(lyrics.kugou.com,内容是 base64)。任何一步失败/拿不到
// 都直接放弃,不重试(下次 enrich 短 TTL 到期自然再试)。
func resolveKugouLyric(artist, title string, durationSecs float64) string {
	var sr struct {
		Data struct {
			Info []kugouSong `json:"info"`
		} `json:"data"`
	}
	q := artist + " " + title
	if err := kugouGet("http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword="+kugouEscape(q)+"&page=1&pagesize=10&showtype=1", &sr); err != nil {
		return ""
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
		return ""
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
		return ""
	}
	c := kr.Candidates[0]
	if c.ID == "" || c.AccessKey == "" {
		return ""
	}
	var dl struct {
		Content string `json:"content"`
	}
	dlURL := fmt.Sprintf("http://lyrics.kugou.com/download?ver=1&client=pc&id=%s&accesskey=%s&fmt=lrc&charset=utf8", c.ID, c.AccessKey)
	if err := kugouGet(dlURL, &dl); err != nil || dl.Content == "" {
		return ""
	}
	raw, err := base64.StdEncoding.DecodeString(dl.Content)
	if err != nil {
		return ""
	}
	lrc := string(raw)
	if !isTimedLRC(lrc) {
		return ""
	}
	return lrc
}
