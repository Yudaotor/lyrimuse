package main

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Spotify Canvas(歌曲页上那段竖版循环短片),给歌词窗口当背景。只读 Spotify 客户端的本机元数据缓存(primary.ldb):它加载过
// Canvas 的曲目各存一条,类型 01 30,值是 Any 包着的 spotify.canvaz.cache.EntityCanvazResponse.Canvaz(2 短片地址、4 类型、
// 5 曲目 uri)。不向 Spotify 要:Canvas 只有它网页播放器的私有接口给,那条接口的条款不许第三方用。所以能拿到的只有 Spotify
// 客户端自己加载过的那些。
//
// 条目自己记着 Spotify 曲目 id 的按 id 查;别的播放器放的歌按 ISRC(只认播放器报的、核实过的两级)对到缓存里同一段录音的
// Spotify 曲目。查到的地址记进条目 spotify_canvas_url,App 下载后当歌词窗口背景。见 07 章决策 183。

var (
	spotifyCanvasKind      = []byte{0x01, 0x30}
	spotifyCanvasURLShape  = regexp.MustCompile(`^https://canvaz\.scdn\.co/upload/[A-Za-z0-9/_-]+\.cnvs\.mp4$`)
	spotifyCanvasKeyPrefix = append([]byte("!xmeta#cache#"), spotifyCanvasKind...)
)

// spotifyCanvasRefresh:缓存索引隔多久才看一次库变没变;同一条目隔多久再查一次。Spotify 开播一首新歌后才去拉它的 Canvas,
// 用 Spotify 放时第一次查常常还没有,隔一会儿再查。
const spotifyCanvasRefresh = 30 * time.Second

// spotifyCanvasURL:一条 Canvas 缓存值里的短片地址。类型是视频(1 VIDEO、2 VIDEO_LOOPING、3 VIDEO_LOOPING_RANDOM;图片、GIF 不要)、
// 记的曲目就是 trackURI、地址过形状闸才给,否则 ""。纯函数,单测覆盖。
func spotifyCanvasURL(v []byte, trackURI string) string {
	b := spotifyFindAny(v, ".EntityCanvazResponse.Canvaz", 0)
	if b == nil {
		return ""
	}
	fields, err := pbParse(b)
	if err != nil {
		return ""
	}
	var url, entity string
	var kind uint64
	for _, f := range fields {
		switch {
		case f.num == 2 && f.wire == 2:
			url = string(f.b)
		case f.num == 4 && f.wire == 0:
			kind = f.v
		case f.num == 5 && f.wire == 2:
			entity = string(f.b)
		}
	}
	if entity != trackURI || kind < 1 || kind > 3 || !spotifyCanvasURLShape.MatchString(url) {
		return ""
	}
	return url
}

// spotifyXmetaKeyTrackURI:`!xmeta#cache#` + 类型 2 字节 + `#` + 长度 + uri + `#` 这种 key 里的 uri。形状不对为 ""。纯函数。
func spotifyXmetaKeyTrackURI(k []byte) string {
	const head = len("!xmeta#cache#") + 3
	if len(k) < head+2 || k[head-1] != '#' {
		return ""
	}
	n := int(k[head])
	if len(k) != head+1+n+1 || k[len(k)-1] != '#' {
		return ""
	}
	return string(k[head+1 : head+1+n])
}

type spotifyCanvasIndex struct {
	byTrack map[string]string // 曲目 id → 短片地址
	byISRC  map[string]string // ISRC → 短片地址
}

// canvasFor:这一条的 Canvas。先按自己的 Spotify 曲目 id,再按可信的 ISRC(播放器报的在前,同级按号排)。没有为 ""。
func (idx *spotifyCanvasIndex) canvasFor(e enrichEntry) string {
	if idx == nil {
		return ""
	}
	if u := idx.byTrack[e.SpotifyTrackID]; e.SpotifyTrackID != "" && u != "" {
		return u
	}
	for _, code := range spotifyCanvasISRCs(e) {
		if u := idx.byISRC[code]; u != "" {
			return u
		}
	}
	return ""
}

// spotifyCanvasISRCs:条目里播放器报的、核实过的 ISRC,播放器报的在前,同级按号排。搜出来的那级不用:对错了就是别的录音的短片。
func spotifyCanvasISRCs(e enrichEntry) []string {
	var out []string
	for _, code := range e.ISRCs {
		code = normalizeISRC(code)
		if l := e.ISRCLevels[code]; l == isrcLevelPlayer || l == isrcLevelVerified {
			out = append(out, code)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		pi, pj := e.ISRCLevels[out[i]] == isrcLevelPlayer, e.ISRCLevels[out[j]] == isrcLevelPlayer
		if pi != pj {
			return pi
		}
		return out[i] < out[j]
	})
	return out
}

// buildSpotifyCanvasIndex:扫各账号的库,收齐带短片的 Canvas(多账号时先扫到的算),再一次查出这些曲目的 ISRC。
func buildSpotifyCanvasIndex(dirs []string) *spotifyCanvasIndex {
	idx := &spotifyCanvasIndex{byTrack: map[string]string{}, byISRC: map[string]string{}}
	for _, dir := range dirs {
		for k, v := range ldbScan(dir, func(k []byte) bool { return bytes.HasPrefix(k, spotifyCanvasKeyPrefix) }) {
			uri := spotifyXmetaKeyTrackURI([]byte(k))
			id := spotifyTrackIDFromURI(uri)
			if id == "" || idx.byTrack[id] != "" {
				continue
			}
			if u := spotifyCanvasURL(v.value, uri); u != "" {
				idx.byTrack[id] = u
			}
		}
	}
	ids := make([]string, 0, len(idx.byTrack))
	for id := range idx.byTrack {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	isrcs := spotifyLocalISRCs(ids)
	for _, id := range ids {
		if code := normalizeISRC(isrcs[id]); code != "" && idx.byISRC[code] == "" {
			idx.byISRC[code] = idx.byTrack[id]
		}
	}
	return idx
}

// spotifyLedgerStamp:这几个库目录里每个文件的名字、大小、修改时间。Spotify 写过库就会变。
func spotifyLedgerStamp(dirs []string) string {
	var b strings.Builder
	for _, dir := range dirs {
		ents, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range ents {
			if info, err := e.Info(); err == nil {
				fmt.Fprintf(&b, "%s/%s:%d:%d;", dir, e.Name(), info.Size(), info.ModTime().UnixNano())
			}
		}
	}
	return b.String()
}

var (
	spotifyCanvasMu      sync.Mutex
	spotifyCanvasCached  *spotifyCanvasIndex
	spotifyCanvasStamp   string
	spotifyCanvasCheckAt time.Time
)

// spotifyCanvasIndexNow:当前的索引。距上次看库不到 spotifyCanvasRefresh 直接用;库没变也接着用;变了重建(约零点几秒,
// 只在后台任务里调)。没装 Spotify 为 nil。
func spotifyCanvasIndexNow(now time.Time) *spotifyCanvasIndex {
	spotifyCanvasMu.Lock()
	defer spotifyCanvasMu.Unlock()
	if spotifyCanvasCached != nil && now.Sub(spotifyCanvasCheckAt) < spotifyCanvasRefresh {
		return spotifyCanvasCached
	}
	spotifyCanvasCheckAt = now
	root := spotifyISRCUsersDir()
	if root == "" {
		spotifyCanvasCached, spotifyCanvasStamp = nil, ""
		return nil
	}
	dirs := spotifyISRCLedgerDirs(root)
	stamp := spotifyLedgerStamp(dirs)
	if spotifyCanvasCached != nil && stamp == spotifyCanvasStamp {
		return spotifyCanvasCached
	}
	spotifyCanvasCached, spotifyCanvasStamp = buildSpotifyCanvasIndex(dirs), stamp
	return spotifyCanvasCached
}

// spotifyCanvasChecked:这次启动里各条目上次查 Canvas 的时刻。受 enrichMu 保护。
var spotifyCanvasChecked = map[string]time.Time{}

// spotifyCanvasJobLocked:正在放的这一条还没有 Canvas、有 Spotify 曲目 id 或可信 ISRC、距上次查过了 spotifyCanvasRefresh 时
// 返回 true(并记下这次)。调用方持有 enrichMu。
func spotifyCanvasJobLocked(key string, e enrichEntry, now time.Time) bool {
	if e.SpotifyCanvasURL != "" || (e.SpotifyTrackID == "" && len(spotifyCanvasISRCs(e)) == 0) {
		return false
	}
	if at, ok := spotifyCanvasChecked[key]; ok && now.Sub(at) < spotifyCanvasRefresh {
		return false
	}
	spotifyCanvasChecked[key] = now
	return true
}

// runSpotifyCanvasJob:锁外拿索引,锁里按条目现在的样子查,查到就写回、落盘。
func runSpotifyCanvasJob(key string) {
	idx := spotifyCanvasIndexNow(time.Now())
	if idx == nil {
		return
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	url := ""
	if ok && e.SpotifyCanvasURL == "" {
		url = idx.canvasFor(e)
	}
	if url == "" {
		enrichMu.Unlock()
		return
	}
	e.SpotifyCanvasURL = url
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	requestEnrichSaveFor(key)
	log.Printf("spotify canvas: %s → %s", key, url)
}
