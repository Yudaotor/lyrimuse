// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// lastfmScrobbler 把 Mac 播放镜像写入 Last.fm(track.updateNowPlaying /
// track.scrobble)。跟文件里另一处"桥接"逻辑方向相反且互不影响:桥接是读 iPhone
// 已经 scrobble 到 Last.fm 的记录转发进 LB;这里是写 Mac 播放到 Last.fm,补全它作为
// 社交/统计门面时的历史。凭证是经一次性网页授权换取的永久 session key(sk)。
type lastfmScrobbler struct {
	apiKey, secret, sk string
	hc                 *http.Client
}

// newLastfmScrobbler 三者任一为空则不启用(返回 nil,调用方需判空跳过)。
func newLastfmScrobbler(apiKey, secret, sk string) *lastfmScrobbler {
	if apiKey == "" || secret == "" || sk == "" {
		return nil
	}
	return &lastfmScrobbler{apiKey: apiKey, secret: secret, sk: sk, hc: &http.Client{Timeout: 8 * time.Second}}
}

// sign 实现 Last.fm 签名算法:参数(不含 format/callback)按 key 字母序拼接、末尾接
// shared secret,取 MD5 十六进制。
func (s *lastfmScrobbler) sign(params map[string]string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteString(params[k])
	}
	b.WriteString(s.secret)
	sum := md5.Sum([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

func (s *lastfmScrobbler) call(ctx context.Context, method string, params map[string]string) error {
	p := make(map[string]string, len(params)+2)
	for k, v := range params {
		p[k] = v
	}
	p["method"] = method
	p["api_key"] = s.apiKey
	p["sk"] = s.sk
	form := neturl.Values{}
	for k, v := range p {
		form.Set(k, v)
	}
	form.Set("api_sig", s.sign(p))
	form.Set("format", "json")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://ws.audioscrobbler.com/2.0/", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", clientName)
	resp, err := s.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("lastfm %s: status %d: %s", method, resp.StatusCode, body)
	}
	return nil
}

func (s *lastfmScrobbler) updateNowPlaying(ctx context.Context, artist, track, album string) error {
	p := map[string]string{"artist": artist, "track": track}
	if album != "" {
		p["album"] = album
	}
	return s.call(ctx, "track.updateNowPlaying", p)
}

func (s *lastfmScrobbler) scrobble(ctx context.Context, artist, track, album string, timestamp int64) error {
	p := map[string]string{"artist": artist, "track": track, "timestamp": strconv.FormatInt(timestamp, 10)}
	if album != "" {
		p["album"] = album
	}
	return s.call(ctx, "track.scrobble", p)
}

// mirrorAsync 异步、尽力而为地把一次 Last.fm 写入(track.updateNowPlaying /
// track.scrobble)镜像出去——不阻塞 poll 循环(Last.fm 可能慢/抽风),失败只记日志不
// 重试(下一次 poll/scrobble 自然会覆盖)。goroutine 自带超时上限,不会泄露(同
// resolveEnrichAsync 的模式)。s==nil(未配置镜像凭证)时整体跳过,call 不会被执行。
// 原来 mirrorNowPlaying/mirrorScrobble 是两份几乎逐行相同的样板代码,合并成这一个。
func mirrorAsync(s *lastfmScrobbler, what string, call func(ctx context.Context) error) {
	if s == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := call(ctx); err != nil {
			log.Printf("lastfm mirror %s failed: %v", what, err)
		}
	}()
}

// lastfmTrack is a track from Last.fm. UTS is the scrobble time in unix seconds
// (0 for the currently-playing entry, which has no timestamp).
type lastfmTrack struct {
	Title, Artist, Album string
	UTS                  int64
}

// lastfmRecent fetches a user's recent Last.fm tracks: the currently-playing one
// (if any) and completed scrobbles with timestamps (newest first). Bridges iPhone
// playback (FastScrobbler→Last.fm) into ListenBrainz — now-playing mirrors the
// live track, completed scrobbles are forwarded as listens so "last played" and
// history reflect the phone on any device.
func lastfmRecent(ctx context.Context, user, apiKey string) (nowPlaying *lastfmTrack, done []lastfmTrack, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	u := fmt.Sprintf(
		"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=%s&api_key=%s&format=json&limit=50",
		neturl.QueryEscape(user), neturl.QueryEscape(apiKey))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		log.Printf("lastfmRecent: build request: %v", err)
		return nil, nil, false
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("lastfmRecent: request failed: %v", err)
		return nil, nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("lastfmRecent: status %d", resp.StatusCode)
		return nil, nil, false
	}
	var out struct {
		RecentTracks struct {
			Track []struct {
				Name   string `json:"name"`
				Artist struct {
					Text string `json:"#text"`
				} `json:"artist"`
				Album struct {
					Text string `json:"#text"`
				} `json:"album"`
				Date struct {
					UTS string `json:"uts"`
				} `json:"date"`
				Attr struct {
					NowPlaying string `json:"nowplaying"`
				} `json:"@attr"`
			} `json:"track"`
		} `json:"recenttracks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		log.Printf("lastfmRecent: decode response: %v", err)
		return nil, nil, false
	}
	for _, t := range out.RecentTracks.Track {
		if t.Name == "" {
			continue
		}
		tr := lastfmTrack{Title: t.Name, Artist: t.Artist.Text, Album: t.Album.Text}
		if t.Attr.NowPlaying == "true" {
			np := tr
			nowPlaying = &np
		} else if t.Date.UTS != "" {
			tr.UTS, _ = strconv.ParseInt(t.Date.UTS, 10, 64)
			done = append(done, tr)
		}
	}
	return nowPlaying, done, true
}
