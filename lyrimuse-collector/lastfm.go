// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// lastfmScrobbler 把 Mac 播放镜像写入 Last.fm(track.updateNowPlaying /
// track.scrobble)。跟文件里另一处"桥接"逻辑方向相反且互不影响:桥接是读 iPhone
// 已经 scrobble 到 Last.fm 的记录转发进 LB;这里是写 Mac 播放到 Last.fm,补全它作为
// 社交/统计门面时的历史。凭证是经一次性网页授权换取的永久 session key(sk)。
type lastfmScrobbler struct {
	apiKey, secret, sk string
	hc                 *http.Client
	// dead:session key / API key 已被 Last.fm 判死(error 9/10/26 一击、error 4 两击,
	// 见 shouldDisable)。置位后停止一切后续提交 —— 原来这种情况下每首歌照样白打 2 个
	// 注定失败的请求,且除了日志刷屏没有任何机制让用户知道 scrobble 早就全停了
	// (2026-08-11 审阅确认)。进程重启(保存配置/重连账号都会 kickstart collector)
	// 自然复位。
	dead atomic.Bool
	// suspect4:第一次撞上 error 4(Authentication Failed)的时刻(UnixNano,0=无嫌疑)。
	// error 4 跟 9/10/26 不同:真撤销授权时它确实会出现,但 Last.fm 服务端不稳时也会
	// **误报**(2026-08-17 实测:一上午 500/超时/DNS 失败之后来了一发 error 4,授权
	// 其实完好,进程重启后第一次提交就成功了——不重启的话镜像就永久停在一次误报上)。
	// 所以单发 error 4 只记嫌疑、不熔断;30s~30min 内再次撞上才坐实。真撤销时每次
	// 调用都失败,第二击最多半分钟就到,多打的请求屈指可数;换来的是孤立误报不再
	// 永久杀死镜像。成功一次即洗清嫌疑。
	suspect4 atomic.Int64
	// clearStatus:第一次提交成功时删掉上次运行留下的状态文件(有就删,没有白删一次),
	// sync.Once 保证整个进程生命周期只做一次这个 stat+remove。
	clearStatus sync.Once
	// collapse 决定一条提交该用哪个艺人名 —— 播放器报的合唱串("汪苏泷 & 荷莉")在
	// Last.fm 编目里往往不存在,原样提交会造出一个只有自己一个听众的影子艺人页。
	// 为 nil(没配只读 api_key)时所有提交按原样走,见 lastfmcollapse.go。
	collapse *lastfmArtistCollapser
}

// newLastfmScrobbler 三者任一为空则不启用(返回 nil,调用方需判空跳过)。
func newLastfmScrobbler(apiKey, secret, sk string) *lastfmScrobbler {
	if apiKey == "" || secret == "" || sk == "" {
		return nil
	}
	return &lastfmScrobbler{apiKey: apiKey, secret: secret, sk: sk, hc: &http.Client{Timeout: 8 * time.Second}}
}

// lastfmScrobblerIfEnabled 是 newLastfmScrobbler 的唯一调用点(run() 里)，多包一层
// features.LastfmMirrorScrobble 开关——跟凭据判断是 AND 关系,任一为否都返回 nil。
func lastfmScrobblerIfEnabled(cfg *config) *lastfmScrobbler {
	if !features.LastfmMirrorScrobble {
		return nil
	}
	s := newLastfmScrobbler(cfg.LastfmScrobbleAPIKey, cfg.LastfmScrobbleSecret, cfg.LastfmScrobbleSessionKey)
	if s != nil {
		// 用**只读**的那个 api_key:track.getInfo 不需要签名/session key,而且读写本来
		// 就是两个独立的 key,别让判定这一步碰到写凭据。
		s.collapse = newLastfmArtistCollapser(cfg.LastfmAPIKey)
	}
	return s
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
	resp, err := doHTTPTracked(s.hc, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	// Last.fm 的错误经常以 HTTP 200 + {"error":N,"message":...} 返回(读路径
	// LastfmAuthFlow.swift 早有同样的注释,写路径一直没做,2026-08-11 审阅确认)——
	// 所以 200 和非 200 的 body 都要解析,先认 error 字段再看状态码。
	var out struct {
		Error     int    `json:"error"`
		Message   string `json:"message"`
		Scrobbles *struct {
			Attr struct {
				Accepted json.Number `json:"accepted"`
				Ignored  json.Number `json:"ignored"`
			} `json:"@attr"`
		} `json:"scrobbles"`
	}
	_ = json.Unmarshal(body, &out) // 解不开就当没有错误体,靠状态码兜底
	if out.Error != 0 {
		return &lastfmAPIError{Code: out.Error, Message: out.Message, Method: method}
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lastfm %s: status %d: %s", method, resp.StatusCode, body)
	}
	// track.scrobble 的"被忽略"也是 200:accepted=0(时间戳超两周、艺人被判无效等),
	// 原来会被当成功。不算致命错误,但必须如实报出去让日志可见。
	if out.Scrobbles != nil {
		if accepted, _ := out.Scrobbles.Attr.Accepted.Int64(); accepted == 0 {
			return fmt.Errorf("lastfm %s: ignored by server (accepted=0)", method)
		}
	}
	return nil
}

// lastfmAPIError 是 Last.fm 应用层错误(区别于网络/HTTP 错误)。
type lastfmAPIError struct {
	Code    int
	Message string
	Method  string
}

func (e *lastfmAPIError) Error() string {
	return fmt.Sprintf("lastfm %s: api error %d: %s", e.Method, e.Code, e.Message)
}

// fatal:这几个错误码属于"凭据级"错误 —— 4=Authentication Failed,9=Invalid session
// key(用户在网站上撤销了授权),10=Invalid API key,26=API key suspended。其余
// (服务暂时不可用/限流等)是暂时性的,永不熔断。注意 fatal 不直接等于熔断:error 4
// 需要复发确认(服务端不稳时会误报),裁决在 shouldDisable。
func (e *lastfmAPIError) fatal() bool {
	switch e.Code {
	case 4, 9, 10, 26:
		return true
	}
	return false
}

// shouldDisable 裁决这次 API 错误要不要熔断镜像:9/10/26 一击致命;4 要两击坐实
// (间隔 ≥confirmGap 才算第二击 —— 换歌那一刻 nowPlaying+scrobble 几乎同时各失败
// 一发,那是同一次故障;超过 suspectWindow 的旧嫌疑作废,隔了半天的两次孤立误报
// 不该累积成死刑)。并发安全:CAS 输了说明别的 goroutine 刚记下同一桩嫌疑,这一发
// 按 burst 处理返回 false 即可。
func (s *lastfmScrobbler) shouldDisable(apiErr *lastfmAPIError, now time.Time) bool {
	if !apiErr.fatal() {
		return false
	}
	if apiErr.Code != 4 {
		return true
	}
	const confirmGap = 30 * time.Second
	const suspectWindow = 30 * time.Minute
	prev := s.suspect4.Load()
	age := time.Duration(now.UnixNano() - prev)
	if prev != 0 && age >= confirmGap && age <= suspectWindow {
		return true
	}
	if prev == 0 || age > suspectWindow {
		s.suspect4.CompareAndSwap(prev, now.UnixNano())
	}
	return false
}

func (s *lastfmScrobbler) updateNowPlaying(ctx context.Context, artist, track, album string) error {
	artist = s.collapse.resolve(ctx, artist, track)
	p := map[string]string{"artist": artist, "track": track}
	if album != "" {
		p["album"] = album
	}
	return s.call(ctx, "track.updateNowPlaying", p)
}

func (s *lastfmScrobbler) scrobble(ctx context.Context, artist, track, album string, timestamp int64) error {
	// 正在播放和完成收听必须走同一次判定,否则 Last.fm 上会出现"now playing 是 A、
	// 落库却是 A & B"这种自相矛盾的状态。判定结果有缓存,这里不会再打一次网络。
	artist = s.collapse.resolve(ctx, artist, track)
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
func mirrorAsync(s *lastfmScrobbler, what string, call func(ctx context.Context) error) {
	if s == nil || s.dead.Load() {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		err := call(ctx)
		if err == nil {
			// 成功即洗清 error 4 的嫌疑(见 suspect4 注释)——能写进去就说明凭据活着。
			s.suspect4.Store(0)
			// 干净的一次成功:把上次运行可能留下的"授权失效"状态文件清掉(App 的
			// Last.fm 卡靠它显示红标),整个进程只查一次。
			s.clearStatus.Do(func() { os.Remove(lastfmStatusPath) })
			return
		}
		var apiErr *lastfmAPIError
		if errors.As(err, &apiErr) && s.shouldDisable(apiErr, time.Now()) {
			// 只有第一个发现者负责收尾:打一条(且只有一条)显眼日志 + 落状态文件给
			// App 读。之后 mirrorAsync 在入口处直接短路,不再刷屏、不再白打请求。
			if s.dead.CompareAndSwap(false, true) {
				log.Printf("lastfm mirror DISABLED: %v (fatal credential error; reconnect the account in Lyrimuse settings to resume)", apiErr)
				writeLastfmMirrorStatus(apiErr)
			}
			return
		}
		if apiErr != nil && apiErr.fatal() {
			// 单发 error 4:嫌疑已记下,先不熔断 —— 复发才停(见 shouldDisable)。
			log.Printf("lastfm mirror %s: %v (single error 4 may be transient server flakiness; mirror stays up, disables only on recurrence)", what, apiErr)
			return
		}
		log.Printf("lastfm mirror %s failed: %v", what, err)
	}()
}

// writeLastfmMirrorStatus 把致命的 Last.fm 写入错误落盘(lyrimuse-lastfm-status.json),
// App 的账号卡读它来显示"授权已失效"红标 —— 沿用 collector 落盘/Swift 读的既有约定
// (同 lfmMirroredPath 等)。写失败只记日志:状态文件是通知通道,不是正确性依赖。
func writeLastfmMirrorStatus(apiErr *lastfmAPIError) {
	if lastfmStatusPath == "" {
		return
	}
	data, err := json.Marshal(struct {
		Error   int    `json:"error"`
		Message string `json:"message"`
		Method  string `json:"method"`
		At      int64  `json:"at"`
	}{apiErr.Code, apiErr.Message, apiErr.Method, time.Now().Unix()})
	if err != nil {
		return
	}
	if err := os.WriteFile(lastfmStatusPath, data, 0o644); err != nil {
		log.Printf("lastfm mirror: write status file failed: %v", err)
	}
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
	resp, err := doHTTPTracked(http.DefaultClient, req)
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
