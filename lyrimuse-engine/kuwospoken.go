package main

import (
	"context"
	"fmt"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 酷我音乐放的说话类内容(故事、有声书、相声、广播剧):系统会话跟歌一样报歌名、歌手、时长,只是不带专辑。认出来的按有声内容处理
// (playerMarksSpoken → playSession.isSpoken):不发正在播放、不提交收听、不预取、网页中继不推;结论记进条目的 player_spoken,
// App 据此不让 Discord 显示。见 02 章决策 268。
//
// 怎么认:只问会话没报专辑的。歌名、歌手交给酷我搜索(kuwoSearch),取歌名(去掉宣传尾段)、歌手逐字对上、时长差
// kuwoSpokenDurationSlack 以内的那一条的专辑 id,再问酷我这张专辑的信息:skipStart(跳过片头的毫秒数)大于 0 是酷我按长音频
// 登记的专辑。对不上、没有专辑 id、应答里没有这一项都当歌。
//
// 后台问:开播那一拍没结论时调用方按「还在判」最多等 spokenVerdictWait;没问成当歌,隔 kuwoSpokenRetryAfter 再问。

const (
	// kuwoSpokenDurationSlack:搜索结果的时长(整秒)跟会话报的差多少秒以内算同一条。
	kuwoSpokenDurationSlack = 3.0
	kuwoSpokenRetryAfter    = time.Minute
	// kuwoSpokenMaxVerdicts:结论表的上限,满了整表清掉、只留刚问完的那一条(它就是正在放的)。
	kuwoSpokenMaxVerdicts = 256
	// kuwoAlbumInfoMaxBytes:专辑信息应答的上限。rn=0 不带曲目表,一份一千来字节。
	kuwoAlbumInfoMaxBytes = 64 << 10
	// kuwoSpokenAskTimeout:后台那一问(搜索加专辑信息)的总上限。
	kuwoSpokenAskTimeout = 10 * time.Second
)

// kuwoAlbumInfoEndpoints:专辑信息接口,https 没问成按 http 再问。
var kuwoAlbumInfoEndpoints = []string{"https://search.kuwo.cn/r.s", "http://search.kuwo.cn/r.s"}

var (
	kuwoSpokenMu       sync.Mutex
	kuwoSpokenVerdicts = map[string]bool{}
	kuwoSpokenAsking   = map[string]bool{}
	kuwoSpokenFailedAt = map[string]time.Time{}
	// kuwoSpokenGo 把那一问交给后台;单测换成同步执行。
	kuwoSpokenGo = func(f func()) { go f() }
)

func kuwoSpokenKey(artist, title string, durationSecs float64) string {
	return normLoose(artist) + "\x00" + normLoose(title) + "\x00" + strconv.Itoa(int(math.Round(durationSecs)))
}

// kuwoSpokenVerdict:酷我这一首是不是说话类内容。spoken 是判成了;pending 是后台还在问。会话报了专辑、没有歌名或歌手的不问,当歌。
// 没结论又不在冷却期时交给后台去问,不等它。
func kuwoSpokenVerdict(artist, title, album string, durationSecs float64) (spoken, pending bool) {
	if strings.TrimSpace(album) != "" || strings.TrimSpace(title) == "" || strings.TrimSpace(artist) == "" {
		return false, false
	}
	key := kuwoSpokenKey(artist, title, durationSecs)
	kuwoSpokenMu.Lock()
	if v, ok := kuwoSpokenVerdicts[key]; ok {
		kuwoSpokenMu.Unlock()
		return v, false
	}
	if kuwoSpokenAsking[key] {
		kuwoSpokenMu.Unlock()
		return false, true
	}
	if at, ok := kuwoSpokenFailedAt[key]; ok && time.Since(at) < kuwoSpokenRetryAfter {
		kuwoSpokenMu.Unlock()
		return false, false
	}
	kuwoSpokenAsking[key] = true
	kuwoSpokenMu.Unlock()
	kuwoSpokenGo(func() { askKuwoSpoken(key, artist, title, durationSecs) })
	kuwoSpokenMu.Lock()
	defer kuwoSpokenMu.Unlock()
	if v, ok := kuwoSpokenVerdicts[key]; ok {
		return v, false
	}
	return false, kuwoSpokenAsking[key]
}

// askKuwoSpoken 是 kuwoSpokenVerdict 交给后台的那一问。为正在放的这首问,按前台发。问完丢掉还在等它的 id 记忆,下一拍重读。
func askKuwoSpoken(key, artist, title string, durationSecs float64) {
	ctx, cancel := withCancelAfter(context.Background(), kuwoSpokenAskTimeout)
	defer cancel()
	spoken, answered := kuwoSpokenLookup(ctx, artist, title, durationSecs)
	now := time.Now()
	kuwoSpokenMu.Lock()
	delete(kuwoSpokenAsking, key)
	if answered {
		delete(kuwoSpokenFailedAt, key)
		if len(kuwoSpokenVerdicts) >= kuwoSpokenMaxVerdicts {
			clear(kuwoSpokenVerdicts)
		}
		kuwoSpokenVerdicts[key] = spoken
	} else {
		for k, at := range kuwoSpokenFailedAt {
			if now.Sub(at) >= kuwoSpokenRetryAfter {
				delete(kuwoSpokenFailedAt, k)
			}
		}
		kuwoSpokenFailedAt[key] = now
	}
	kuwoSpokenMu.Unlock()
	if spoken {
		log.Printf("kuwo: %q - %q is spoken audio (its Kuwo album skips an intro)", artist, title)
	}
	forgetPendingPlayerCatalogIDs()
}

// kuwoSpokenLookup:问酷我这一首是不是说话类内容;answered 为 false 是没问成(不是「不是」)。
func kuwoSpokenLookup(ctx context.Context, artist, title string, durationSecs float64) (spoken, answered bool) {
	items, err := kuwoSearch(ctx, artist, title)
	if err != nil {
		return false, false
	}
	albumID := kuwoSpokenAlbumID(items, artist, title, durationSecs)
	if albumID == "" {
		return false, true
	}
	var body []byte
	err = tryEach(ctx, kuwoAlbumInfoEndpoints, func(endpoint string) error {
		got, err := kuwoAlbumInfoAt(ctx, endpoint, albumID)
		if err == nil {
			body = got
		}
		return err
	})
	if err != nil {
		return false, false
	}
	skip, ok := kuwoAlbumSkipStart(body, albumID)
	if !ok {
		noteParserUnrecognized("kuwo-albuminfo", "no skipStart for album "+albumID)
		return false, true
	}
	return skip > 0, true
}

// kuwoSpokenAlbumID:搜索结果里就是会话报的这一首的那一条的专辑 id:歌名去掉宣传尾段(kuwoSongTitle)后、歌手都按 normLoose
// 相等,两边时长都知道时差 kuwoSpokenDurationSlack 以内。不止一条时取第一条带专辑 id 的;没有为空串。纯函数,单测覆盖。
func kuwoSpokenAlbumID(items []kuwoSearchItem, artist, title string, durationSecs float64) string {
	wantTitle, wantArtist := normLoose(title), normLoose(artist)
	if wantTitle == "" || wantArtist == "" {
		return ""
	}
	for _, it := range items {
		if normLoose(kuwoSongTitle(it.SongName)) != wantTitle || normLoose(it.Artist) != wantArtist {
			continue
		}
		if d := kuwoDurationSecs(it.Duration); d > 0 && durationSecs > 0 && math.Abs(d-durationSecs) > kuwoSpokenDurationSlack {
			continue
		}
		if id := rawDigitsID(it.AlbumID); id != "" {
			return id
		}
	}
	return ""
}

func kuwoAlbumInfoAt(ctx context.Context, endpoint, albumID string) ([]byte, error) {
	u := endpoint + "?stype=albuminfo&pn=0&rn=0&encoding=utf8&albumid=" + neturl.QueryEscape(albumID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	// 不带浏览器 User-Agent 回 403。
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(kuwoHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	raw, err := readLyricSourceBody(req, resp, kuwoAlbumInfoMaxBytes)
	if err != nil {
		return nil, err
	}
	reportEndpointAccepted(req.URL)
	return raw, nil
}

// 专辑信息应答是单引号的伪 JSON(`{'albumid':'10344691',…,'skipStart':'3000',…}`),只按键名取这两项,也认双引号。
var (
	kuwoAlbumInfoIDRe   = regexp.MustCompile(`['"]albumid['"]\s*:\s*['"]?([0-9]+)`)
	kuwoAlbumInfoSkipRe = regexp.MustCompile(`['"]skipStart['"]\s*:\s*['"]?([0-9]+)`)
)

// kuwoAlbumSkipStart:专辑信息应答里这张专辑的 skipStart;应答不是这张专辑、没有这一项时 ok 为 false。纯函数,单测覆盖。
func kuwoAlbumSkipStart(body []byte, albumID string) (skip int, ok bool) {
	id := kuwoAlbumInfoIDRe.FindSubmatch(body)
	m := kuwoAlbumInfoSkipRe.FindSubmatch(body)
	if id == nil || string(id[1]) != albumID || m == nil {
		return 0, false
	}
	v, err := strconv.Atoi(string(m[1]))
	if err != nil {
		return 0, false
	}
	return v, true
}
