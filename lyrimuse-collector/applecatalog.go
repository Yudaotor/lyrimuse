// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// ---- Apple 目录锚点 ----
//
// media-control 的 now-playing 快照里有一个一直被丢掉的字段 `uniqueIdentifier`
// (MediaRemote 的 kMRMediaRemoteNowPlayingInfoUniqueIdentifier)。2026-08-22 实测坐实:
// 放 **Apple Music 目录曲目**(流媒体/加进资料库的目录条目)时,它就是 **Apple 的目录
// 曲目 ID**——
//
//	uniqueIdentifier=1485220325 → iTunes lookup 回 trackNumber=18 的「印地安老斑鸠 (Live)」、
//	collectionId=1485220306、trackTimeMillis=208293,而同一份快照的 duration 是 208.293,
//	逐位一致。
//
// 于是一次 lookup 就能拿到这条曲目的**权威**元数据:曲目署名、**专辑署名**
// (collectionArtistName,只在它与曲目署名不同时才出现——正好是"客串/群星/演唱会嘉宾"
// 这类曲目)、专辑 ID、以及权威时长。
//
// ⚠️ 两个必须守住的边界,都是实测出来的:
//
//  1. **只对 Apple Music 目录曲目成立**。用户自己导入/购买的文件,uniqueIdentifier 是一个
//     任意的 64 位本地持久 ID,可以是负数——实测同一台机器上一首本地导入的 Michael
//     Jackson 曲目拿到 -3446272063698972557,直接拿去 lookup 是 HTTP 400;取绝对值
//     (3446272063698972557)是 0 results。所以 trackID<=0 一律不发请求。
//  2. 别的播放器(QQ/网易云/Spotify)在这个字段里放什么**没有任何保证**,理论上可能撞上
//     一个真实的 Apple 目录 ID。所以除了 bundle id 必须是 Apple Music,拿回来的结果还要
//     **自校验**:曲目名和专辑名都得对上本地标签,对不上就当没有这个锚点。
//
// 自校验顺带解决了 media-control 的"脏快照"(见 enrich.go 的 observeWrongDuration:换曲
// 预载窗口里它会把**下一首**的时长和当前曲目的标题拼进同一份快照)。两种情形都安全:
// uniqueIdentifier 跟着当前曲目 → 校验通过 → 用它的权威时长把脏时长顶掉;跟着下一首 →
// 曲目名对不上 → 锚点作废、退回现状(30 秒去抖那条防线照旧)。不会更差。
const (
	// appleCatalogMaxPlausibleID:目录 ID 的合理上界。现役 ID 是 10 位数量级,留三个数量级
	// 余量。本地持久 ID 是满量程 64 位,正数那一半靠这条挡掉绝大部分。
	appleCatalogMaxPlausibleID = 1_000_000_000_000
	// appleCatalogMaxMisses:同一个 ID 查空多少次之后不再试。查空的原因可能是"这就不是
	// 目录 ID"(永远查不到)也可能是网络抖动,给几次机会就够。刻意**不落盘**这个计数——
	// 跟 mbPrimaryNameCache 只落盘查到了的条目同一个理由(见那边注释)。
	appleCatalogMaxMisses = 3
	// appleCatalogDurationLogThreshold:权威时长跟 media-control 报的差多少才值得打日志。
	// 正常情况两者逐位相等,只有撞上脏快照才会差开,所以这条日志天然稀疏。
	appleCatalogDurationLogThreshold = 0.5
)

// appleCatalogTrack 是一条 Apple 目录曲目的权威元数据。字段名对齐 iTunes Search API 的
// 语义,不是我们自己的抽象。
//
// ⚠️ 跟 apple.go 的 itunesResult **刻意分开**,不是重复实现:那个是"封面 + 跳转链接"的匹配
// 结果(TrackViewURL/ArtworkURL100),来自**全文搜索**(itunesSearch)或**专辑曲目表**
// (itunesLookupTracks,entity=song),身份靠 artist/title/album 文本模糊对齐;这个是"这次
// 播放的到底是目录里哪一条"的**按 ID 精确查**结果,多带 ArtistName/AlbumArtist/DurationSecs
// 三个那边用不到的字段,而身份是 ID 认的。两者的可信度等级不一样,别合并。
type appleCatalogTrack struct {
	TrackName string `json:"track_name"`
	// ArtistName:曲目级署名。可能是客串者(演唱会嘉宾、群星合辑里的某位)。
	ArtistName string `json:"artist_name"`
	// AlbumArtist:专辑级署名(collectionArtistName)。iTunes **只在它与曲目署名不同时**
	// 才给这个字段——所以它非空本身就是"这首歌的署名跟专辑主人不是一个人"的信号,正是
	// 歌词检索最该多试一个名字的场合。
	AlbumArtist  string  `json:"album_artist,omitempty"`
	AlbumName    string  `json:"album_name"`
	AlbumID      int64   `json:"album_id"`
	DurationSecs float64 `json:"duration_secs"`
	// TrackNumber:这条曲目在专辑里的序号。**只作自校验用** —— 同一张专辑上「去掉括号后
	// 同名」的兄弟轨(甚至连括号都不用剥的完全同名轨)靠曲目名和专辑名分不开,序号能。
	TrackNumber int `json:"track_number,omitempty"`
}

var (
	appleCatalogMu       sync.Mutex
	appleCatalogCache    = map[string]appleCatalogTrack{} // key = 十进制 track id
	appleCatalogPath     string                           // 空 = 只用内存(单测/一次性子命令)
	appleCatalogDirty    bool
	appleCatalogInflight = map[int64]bool{}
	appleCatalogMisses   = map[int64]int{}
	// appleCatalogByTrack:已校验通过的锚点按"归一标题|归一专辑"建的索引。给歌词检索那
	// 一侧用——它拿不到 uniqueIdentifier(trackEnrichment 的签名里没有,而为了这个把参数
	// 从 5 个串到 4 层深处不值得),但它手里有 title/album,查这份索引就够。跟
	// appleMusicMatchCached 是同一种"按 (artist,title,album) 问一个包级缓存"的形状。
	appleCatalogByTrack = map[string]appleCatalogTrack{}
)

func appleCatalogIndexKey(title, album string) string {
	return normLoose(title) + "|" + normLoose(album)
}

// loadAppleCatalogCache/saveAppleCatalogCache:整份 map 序列化 + 临时文件原子改名,跟
// loadMBPrimaryNameCache 同一套。目录 ID → 元数据是**不变映射**(ID 一旦发布就不会改指
// 别的曲目),所以这份缓存永久有效、没有 TTL;只落盘查到了的条目。
func loadAppleCatalogCache(path string) {
	appleCatalogMu.Lock()
	appleCatalogPath = path
	appleCatalogMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]appleCatalogTrack
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		appleCatalogMu.Lock()
		appleCatalogCache = m
		appleCatalogMu.Unlock()
		log.Printf("loaded %d cached Apple catalog tracks from %s", len(m), path)
	}
}

func saveAppleCatalogCache() {
	appleCatalogMu.Lock()
	if !appleCatalogDirty || appleCatalogPath == "" {
		appleCatalogMu.Unlock()
		return
	}
	data, err := json.Marshal(appleCatalogCache)
	appleCatalogDirty = false
	path := appleCatalogPath
	appleCatalogMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
	}
}

// appleCatalogPlausibleID:这个 uniqueIdentifier 值有没有可能是目录 ID。见文件头 ⚠️ 1。
func appleCatalogPlausibleID(trackID int64) bool {
	return trackID > 0 && trackID < appleCatalogMaxPlausibleID
}

// appleCatalogLookup 打一次 iTunes lookup。只在**查到了**时返回 ok=true 并写缓存。
func appleCatalogLookup(trackID int64) (appleCatalogTrack, bool) {
	u := fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&country=cn", trackID)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return appleCatalogTrack{}, false
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 5 * time.Second}, req)
	if err != nil {
		return appleCatalogTrack{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return appleCatalogTrack{}, false
	}
	var r struct {
		Results []struct {
			WrapperType          string  `json:"wrapperType"`
			TrackName            string  `json:"trackName"`
			ArtistName           string  `json:"artistName"`
			CollectionArtistName string  `json:"collectionArtistName"`
			CollectionName       string  `json:"collectionName"`
			CollectionID         int64   `json:"collectionId"`
			TrackNumber          int     `json:"trackNumber"`
			TrackTimeMillis      float64 `json:"trackTimeMillis"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return appleCatalogTrack{}, false
	}
	for _, it := range r.Results {
		// wrapperType 必须是 track:同一个 id 空间里还有 collection/artist,
		// 拿一张专辑的元数据当曲目用会得出完全错误的时长。
		if it.WrapperType != "track" || it.TrackName == "" {
			continue
		}
		t := appleCatalogTrack{
			TrackName:    cleanMediaTag(it.TrackName),
			ArtistName:   cleanMediaTag(it.ArtistName),
			AlbumArtist:  cleanMediaTag(it.CollectionArtistName),
			AlbumName:    cleanMediaTag(it.CollectionName),
			AlbumID:      it.CollectionID,
			TrackNumber:  it.TrackNumber,
			DurationSecs: it.TrackTimeMillis / 1000,
		}
		appleCatalogMu.Lock()
		appleCatalogCache[fmt.Sprint(trackID)] = t
		appleCatalogDirty = true
		appleCatalogMu.Unlock()
		saveAppleCatalogCache()
		return t, true
	}
	return appleCatalogTrack{}, false
}

// appleCatalogTrackCachedOnly 只读缓存,永不发请求——给 poll 主循环用。
func appleCatalogTrackCachedOnly(trackID int64) (appleCatalogTrack, bool) {
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	t, ok := appleCatalogCache[fmt.Sprint(trackID)]
	return t, ok
}

// prefetchAppleCatalogTrack 后台补一次 lookup。**刻意异步**:调用方是 poll 主循环
// (5 秒一轮,同时负责播放位置跟踪),在那条路径上同步等一次对外 HTTP 是把网络抖动直接
// 变成"进度卡住"——这个项目已经为同一个理由把 poll() 的对外提交异步化过一次。
// 这一轮先按现状走,下一轮(5 秒后)缓存就热了。
func prefetchAppleCatalogTrack(trackID int64) {
	if !appleCatalogPlausibleID(trackID) {
		return
	}
	appleCatalogMu.Lock()
	if appleCatalogInflight[trackID] || appleCatalogMisses[trackID] >= appleCatalogMaxMisses {
		appleCatalogMu.Unlock()
		return
	}
	if _, ok := appleCatalogCache[fmt.Sprint(trackID)]; ok {
		appleCatalogMu.Unlock()
		return
	}
	appleCatalogInflight[trackID] = true
	appleCatalogMu.Unlock()

	go func() {
		_, ok := appleCatalogLookup(trackID)
		appleCatalogMu.Lock()
		delete(appleCatalogInflight, trackID)
		if !ok {
			appleCatalogMisses[trackID]++
		}
		appleCatalogMu.Unlock()
	}()
}

// appleCatalogAnchor 给出"这次播放的到底是 Apple 目录里哪一条"的**已校验**锚点。
// 缓存没命中时不阻塞:发一次后台补取、本轮返回 ok=false。
//
// 校验(见文件头 ⚠️ 2)要求曲目名和专辑名都对上本地标签。本地没有专辑标签时只校曲目名
// ——Apple Music 走这条路径时专辑标签为空极罕见,不值得为它整条作废。
func appleCatalogAnchor(bundleID string, trackID int64, localTrackNumber int, localTitle, localAlbum string) (appleCatalogTrack, bool) {
	if bundleID != appleMusicBundleID || localTitle == "" || !appleCatalogPlausibleID(trackID) {
		return appleCatalogTrack{}, false
	}
	t, ok := appleCatalogTrackCachedOnly(trackID)
	if !ok {
		prefetchAppleCatalogTrack(trackID)
		return appleCatalogTrack{}, false
	}
	// ⚠️ 曲目名用**逐字同名**,不是 lyricTitleAccepted(2026-08-22 对抗性复核改)。
	// 那个函数的第二档会把双方各自 stripParens 之后再比相等 —— 于是同一张专辑上的括号
	// 兄弟轨互相判等,而专辑名又必然相同,锚点照样"成立",把差 40~47% 的时长当成权威值:
	//   XSCAPE (Deluxe) #8「Xscape」244.9s  vs #16「Xscape (Original Version)」344.4s
	//   BADモード      #13「Face My Fears (English Version)」219.1s vs #14「(A. G. Cook Remix)」322.0s
	// (两组都来自用户自己的资料库,不是构造的)。这正好推翻了原来那句"曲目名对不上 →
	// 锚点作废、不会更差"——只要下一首是同专辑的括号兄弟轨,曲目名就是"对得上"的。
	// 锚点是**按 ID 认身份**的,压根不需要歌词检索那套宽松匹配。
	if normLoose(t.TrackName) == "" || normLoose(t.TrackName) != normLoose(localTitle) {
		return appleCatalogTrack{}, false
	}
	if localAlbum != "" && albumScore(t.AlbumName, localAlbum) < 100 {
		return appleCatalogTrack{}, false
	}
	// 音轨号交叉核对:逐字同名也挡不住**完全同名**的兄弟轨(实测 XSCAPE (Deluxe) 上
	// #1 和 #17 都叫「Love Never Felt So Good」,234.9s / 245.7s)。两边都拿得到序号时
	// 必须相等;有一边没有就跳过这一条(不把"缺证据"当"反证据")。
	if localTrackNumber > 0 && t.TrackNumber > 0 && localTrackNumber != t.TrackNumber {
		return appleCatalogTrack{}, false
	}
	appleCatalogMu.Lock()
	appleCatalogByTrack[appleCatalogIndexKey(localTitle, localAlbum)] = t
	appleCatalogMu.Unlock()
	return t, true
}

// appleCatalogSearchIdentities 给歌词检索多几个**查询身份**:本地署名查不到东西时,
// 换 Apple 目录里的权威署名再试。
//
// 返回的两个名字语义不同,顺序也是有讲究的:
//   - AlbumArtist(专辑署名)放前面。它非空就意味着"这首歌的署名跟专辑主人不是一个人"
//     ——演唱会嘉宾、群星合辑、客串曲目,正是本地署名最容易跟各家歌词库对不上的那批。
//     实测:「枫+退后+搁浅 (Live)」本地署名「南拳妈妈弹头」时网易云 4 条查询词一条都
//     召回不到目标,换专辑署名「周杰伦」查,目标排第 1。
//   - ArtistName(曲目署名)放后面,只在它跟本地标签写法不同时才算一个变体。
//
// ⚠️ 只当**检索身份**用,绝不回写 canonical_artist / 展示字段——跟 lyricPrimaryQueryArtist
// 同一条纪律(把署名换成别人正是 2026-07-10 那次回归的形态)。
func appleCatalogSearchIdentities(artist, title, album string) []string {
	appleCatalogMu.Lock()
	t, ok := appleCatalogByTrack[appleCatalogIndexKey(title, album)]
	if !ok {
		// 索引只由播放路径(appleCatalogAnchor)填,而 search-lyrics 是独立的一次性进程 ——
		// 它 loadAppleCatalogCache 读回来的是 appleCatalogCache,索引仍然是空的。
		// 2026-08-22 对抗性复核指出:不退化的话那次 load 是**空操作**,注释却写着它修好了
		// "手动搜索名次跟自动决策对不上"。磁盘缓存里本来就有 track_name/album_name,
		// 扫一遍就够,条目量是"这台机器放过的目录曲目数",线性扫可以接受。
		want := appleCatalogIndexKey(title, album)
		for _, c := range appleCatalogCache {
			if appleCatalogIndexKey(c.TrackName, c.AlbumName) == want {
				t, ok = c, true
				break
			}
		}
	}
	appleCatalogMu.Unlock()
	if !ok {
		return nil
	}
	var out []string
	seen := map[string]bool{normLoose(artist): true}
	for _, cand := range []string{t.AlbumArtist, t.ArtistName} {
		n := normLoose(cand)
		if cand == "" || n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, cand)
	}
	return out
}

// dedupeArtistIdentities 把几组"换个名字再搜一遍"的候选身份按 normLoose 去重后串成一条
// 列表,保留各组内部的原有顺序。给 scoredLyricCandidatesStreaming 用:Apple 目录锚点那
// 一组和 retryArtistIdentities 那一组完全可能给出同一个名字(比如手工别名表里恰好登记过
// 同一位歌手),不去重就是同一个查询词白跑一整轮五源抓取(每轮 20 秒兜底)。
func dedupeArtistIdentities(groups ...[]string) []string {
	seen := map[string]bool{}
	var out []string
	for _, g := range groups {
		for _, name := range g {
			n := normLoose(name)
			if name == "" || n == "" || seen[n] {
				continue
			}
			seen[n] = true
			out = append(out, name)
		}
	}
	return out
}
