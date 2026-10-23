package main

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net/http"
	neturl "net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 酷狗的网页歌曲页 `www.kugou.com/mixsong/<EMixSongID>.html`(不登录能开)。EMixSongID 是曲目 mixId 编码后加服务端校验,离线
// 推不出来;不签名的几个搜索接口都不给它,只有网页版的签名搜索(complexsearch.kugou.com,网页 JS 里公开的盐,userid 0、
// token 空、随机 mid)给。酷狗在放时引擎已经从它本机库里记下这一首的 mixId(`player_song_ids`,kugouPlayingSong):按歌手、歌名
// 搜一次,mixId 对得上的那一条才认,换出网页歌曲页记进 `kugou_url`。每个 mixId 每次启动只试一次。见 07 章决策 182。

const (
	kugouSearchSignSalt = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
	kugouSearchTimeout  = 8 * time.Second
	kugouSongPageBase   = "https://www.kugou.com/mixsong/"
)

// kugouSearchURL:签名搜索的地址。单测换成假服务器。
var kugouSearchURL = "https://complexsearch.kugou.com/v2/search/song"

var kugouEMixShape = regexp.MustCompile(`^[0-9a-z]{4,16}$`)

// kugouSearchParams:签名搜索的参数(含签名)。签名是盐 + 按键名排好的「键=值」直接连起来 + 盐的 md5。纯函数,单测覆盖。
func kugouSearchParams(keyword, mid string, now time.Time) neturl.Values {
	p := map[string]string{
		"callback": "callback123", "srcappid": "2919", "clientver": "1000", "clienttime": strconv.FormatInt(now.UnixMilli(), 10),
		"mid": mid, "uuid": mid, "dfid": "-", "keyword": keyword, "page": "1", "pagesize": "30", "bitrate": "0", "isfuzzy": "0",
		"inputtype": "0", "platform": "WebFilter", "userid": "0", "iscorrection": "1", "privilege_filter": "0", "filter": "10",
		"token": "", "appid": "1014",
	}
	keys := make([]string, 0, len(p))
	for k := range p {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(kugouSearchSignSalt)
	for _, k := range keys {
		b.WriteString(k + "=" + p[k])
	}
	b.WriteString(kugouSearchSignSalt)
	sum := md5.Sum([]byte(b.String()))
	v := neturl.Values{}
	for k, val := range p {
		v.Set(k, val)
	}
	v.Set("signature", hex.EncodeToString(sum[:]))
	return v
}

// kugouSongPageFromSearch:搜索应答(JSONP)里 mixId 对得上的那一条的网页歌曲页;没有这一条为 "",形状不对为 false。
// 纯函数,单测覆盖。
func kugouSongPageFromSearch(body []byte, mixID string) (string, bool) {
	s := string(body)
	open, end := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
	if open < 0 || end <= open {
		return "", false
	}
	var r struct {
		Data *struct {
			Lists []struct {
				MixSongID  json.Number `json:"MixSongID"`
				EMixSongID string      `json:"EMixSongID"`
			} `json:"lists"`
		} `json:"data"`
	}
	if json.Unmarshal([]byte(s[open+1:end]), &r) != nil || r.Data == nil {
		return "", false
	}
	for _, it := range r.Data.Lists {
		if it.MixSongID.String() == mixID && kugouEMixShape.MatchString(it.EMixSongID) {
			return kugouSongPageBase + it.EMixSongID + ".html", true
		}
	}
	return "", true
}

// kugouSongPage:按歌手 + 歌名、再按歌名搜,mixId 对得上的那一条的网页歌曲页。都没有为 "",没问成为 false。
func kugouSongPage(ctx context.Context, mixID, artist, title string) (string, bool) {
	answered := false
	for _, kw := range []string{strings.TrimSpace(artist + " " + title), strings.TrimSpace(title)} {
		if kw == "" {
			continue
		}
		page, ok := kugouSearchOnce(ctx, kw, mixID)
		if page != "" {
			return page, true
		}
		answered = answered || ok
	}
	return "", answered
}

func kugouSearchOnce(ctx context.Context, keyword, mixID string) (string, bool) {
	mid := fmt.Sprintf("%016x%016x", rand.Uint64(), rand.Uint64())
	ctx, cancel := withCancelAfter(ctx, kugouSearchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, kugouSearchURL+"?"+kugouSearchParams(keyword, mid, time.Now()).Encode(), nil)
	if err != nil {
		return "", false
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
	req.Header.Set("Referer", "https://www.kugou.com/")
	resp, err := doHTTPTracked(lyricHTTPClient(kugouSearchTimeout), req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return "", false
	}
	return kugouSongPageFromSearch(body, mixID)
}

// kugouSongPageTried:这次启动里已经为它找过网页歌曲页的 mixId。受 enrichMu 保护。
var kugouSongPageTried = map[string]bool{}

type kugouSongPageJob struct {
	key, mixID, artist, title string
}

// kugouSongPageJobLocked:酷狗在放这一首、记下了 mixId、还没有网页歌曲页、这次启动没试过时,交一份要做的事。调用方持有 enrichMu。
func kugouSongPageJobLocked(key string, e enrichEntry, bundleID, artist, title string) (kugouSongPageJob, bool) {
	mix := e.PlayerSongIDs[kugouMusicBundleID]
	if bundleID != kugouMusicBundleID || e.KugouURL != "" || mix == "" || kugouSongPageTried[mix] {
		return kugouSongPageJob{}, false
	}
	kugouSongPageTried[mix] = true
	return kugouSongPageJob{key: key, mixID: mix, artist: artist, title: title}, true
}

// runKugouSongPageJob:找到了就写回条目(条目记的还是这个 mixId、还没有网页歌曲页时),落盘。
func runKugouSongPageJob(job kugouSongPageJob) {
	page, _ := kugouSongPage(withBackgroundOutbound(context.Background()), job.mixID, job.artist, job.title)
	if page == "" {
		return
	}
	enrichMu.Lock()
	e, ok := enrichCache[job.key]
	if !ok || e.KugouURL != "" || e.PlayerSongIDs[kugouMusicBundleID] != job.mixID {
		enrichMu.Unlock()
		return
	}
	e.KugouURL = page
	enrichCache[job.key] = e
	enrichDirty = true
	enrichMu.Unlock()
	requestEnrichSaveFor(job.key)
	log.Printf("kugou song page: %s → %s", job.key, page)
}
