package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// 预解析要的那几样播放器查询交给 App 代跑:Music.app 的系统待播队列与当前列表往后几首、Music.app 资料库里某张专辑的曲目、
// Spotify 有没有开随机、浏览器里 YouTube Music / Spotify 网页版的待播队列。collector 自己不发 AppleEvent,
// 系统设置「自动化」里只剩 Lyrimuse 一条,授权框也只可能来自 App。
//
// 通道是一对共享文件:collector 写一份带类型的请求(`lyrimuse-player-query-request.json`,种类 + 参数,不带脚本),
// App 只跑自己内置的那几段只读脚本,把原始输出写回 `lyrimuse-player-query-reply.json`(App 侧 PlayerQueryServer)。
// 一次只有一个请求在途,按 id 认应答。App 不可用(没在跑、退出中)时不发,直接当查不到,调用方照旧退回同专辑预取。
// 输出怎么解析留在各自的调用方(parseAppleMusicSystemQueue / parseAppleMusicUpcoming / parseMusicAppAlbumTracks /
// parseYTMusicQueue / parseSpotifyWebQueue)。

const (
	appQueryAppleMusicQueue       = "apple_music_queue"
	appQueryAppleMusicUpcoming    = "apple_music_upcoming"
	appQueryAppleMusicAlbumTracks = "apple_music_album_tracks"
	appQuerySpotifyShuffle        = "spotify_shuffle"
	appQueryBrowserQueue          = "browser_queue"

	appQuerySchema = 1

	// appQueryScriptTimeout:等一次 Music / 浏览器脚本(系统待播队列同样)应答的上限。App 那边跑脚本的进程级超时是 6 秒,再加它看
	// 请求文件的间隔(0.5 秒)与写回。
	appQueryScriptTimeout = 8 * time.Second
	// appQueryShuffleTimeout:等 Spotify 随机状态的上限(App 那边脚本超时 2 秒)。
	appQueryShuffleTimeout = 4 * time.Second
)

// appQueryPoll:等应答时多久看一次应答文件(一次 stat,变了才读)。单测调短。
var appQueryPoll = 100 * time.Millisecond

type appQueryRequest struct {
	Schema      int    `json:"schema"`
	ID          string `json:"id"`
	Kind        string `json:"kind"`
	Count       int    `json:"count,omitempty"`
	Album       string `json:"album,omitempty"`
	BundleID    string `json:"bundle_id,omitempty"`
	Platform    string `json:"platform,omitempty"`
	WrittenAtMs int64  `json:"written_at_ms"`
}

type appQueryReply struct {
	Schema      int    `json:"schema"`
	ID          string `json:"id"`
	OK          bool   `json:"ok"`
	Output      string `json:"output"`
	Error       string `json:"error,omitempty"`
	WrittenAtMs int64  `json:"written_at_ms"`
}

var (
	// appQueryMu:一次只有一个请求在途(请求文件只有一份)。
	appQueryMu sync.Mutex

	appQueryCfgMu   sync.Mutex
	appQueryReqPath string
	appQueryRepPath string
	appQueryReady   func() bool

	appQuerySeq atomic.Int64
)

// setAppQueryChannel 登记请求 / 应答文件与「App 此刻可用」的判断。run() 里登记;没登记 = 不问(CLI 子命令与测试默认如此)。
func setAppQueryChannel(requestPath, replyPath string, ready func() bool) {
	appQueryCfgMu.Lock()
	defer appQueryCfgMu.Unlock()
	appQueryReqPath, appQueryRepPath, appQueryReady = requestPath, replyPath, ready
}

// askApp 让 App 跑一次 req 这种查询,返回它的原始输出。ok=false = 没登记通道、App 此刻不可用、写不出请求、
// 到 timeout 没等到这一份的应答,或者 App 回报没跑成(参数不对、浏览器没配对、脚本失败)。
func askApp(req appQueryRequest, timeout time.Duration) (string, bool) {
	appQueryCfgMu.Lock()
	reqPath, repPath, ready := appQueryReqPath, appQueryRepPath, appQueryReady
	appQueryCfgMu.Unlock()
	if reqPath == "" || repPath == "" || ready == nil || !ready() {
		return "", false
	}
	appQueryMu.Lock()
	defer appQueryMu.Unlock()
	now := time.Now()
	req.Schema = appQuerySchema
	req.ID = fmt.Sprintf("%d-%d-%d", os.Getpid(), now.UnixNano(), appQuerySeq.Add(1))
	req.WrittenAtMs = now.UnixMilli()
	data, err := json.Marshal(req)
	if err != nil {
		return "", false
	}
	if err := writeFileAtomic(reqPath, data); err != nil {
		log.Printf("app query %s: could not write the request: %v", req.Kind, err)
		return "", false
	}
	var lastMod time.Time
	lastSize := int64(-1)
	for deadline := now.Add(timeout); time.Now().Before(deadline); {
		time.Sleep(appQueryPoll)
		info, err := os.Stat(repPath)
		if err != nil || (info.ModTime().Equal(lastMod) && info.Size() == lastSize) {
			continue
		}
		lastMod, lastSize = info.ModTime(), info.Size()
		raw, err := os.ReadFile(repPath)
		if err != nil {
			continue
		}
		var rep appQueryReply
		if json.Unmarshal(raw, &rep) != nil || rep.ID != req.ID {
			continue
		}
		return rep.Output, rep.OK
	}
	log.Printf("app query %s: no reply from the App within %s", req.Kind, timeout)
	return "", false
}
