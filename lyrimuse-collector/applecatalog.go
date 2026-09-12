// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
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

// appleCatalogAlbumIDFor:按"归一标题|归一专辑"取这首歌所属的**目录专辑 ID**(collectionId)。
// 动态封面(motioncover.go)要的就是这个——那份资源是按**专辑**挂的,不是按曲目。
//
// 两级查找跟 appleCatalogSearchIdentities 一样:先查播放路径填的索引,再退回扫落盘缓存
// (一次性子命令里索引是空的,理由见那边注释)。**只认已校验过的锚点**——索引与缓存里的条目
// 都经过 appleCatalogAnchor 的曲目名/专辑名自校验,所以这里拿到的 ID 是可信的;刻意不提供
// "拿 artist/album 去搜一个专辑 ID"的退路,理由见 motioncover.go 文件头 ⚠️ 1。
func appleCatalogAlbumIDFor(title, album string) (int64, bool) {
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	want := appleCatalogIndexKey(title, album)
	if t, ok := appleCatalogByTrack[want]; ok && t.AlbumID > 0 {
		return t.AlbumID, true
	}
	for _, c := range appleCatalogCache {
		if c.AlbumID > 0 && appleCatalogIndexKey(c.TrackName, c.AlbumName) == want {
			return c.AlbumID, true
		}
	}
	return 0, false
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
		log.Printf("cache: loaded %d Apple catalog tracks from %s", len(m), path)
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

// appleStorefrontArtistCache 按"艺人|专辑"缓存 appleStorefrontArtistIdentities 的结果——
// 跟 mbPrimaryNameCache(musicbrainz.go)同一套持久化模式和同一条设计取舍:只落盘
// **查到了**的条目,查空的只留在内存里(避免一次偶发的网络抖动/超时把这张专辑永久钉死
// 在"没有别的署名"上,下个进程还有机会重试)。2026-08-30 加,起因是把 retryArtistIdentities
// 里 knownArtistAlias 那条手工表退休之后,原来"零网络请求"的那批已知歌手(方大同等)
// 每次搜索候选歌词都要多打 1~4 次 iTunes 请求——这份缓存让**同一首歌第二次起**恢复到
// 零网络请求,含"歌词管理"手动搜索这种每次都是全新进程、内存缓存跨不过去的场景
// (跟 mbPrimaryNameCache 落盘的理由完全一样)。
var (
	appleStorefrontArtistMu    sync.Mutex
	appleStorefrontArtistCache = map[string][]string{}
	appleStorefrontArtistPath  string // 空 = 只用内存不持久化(单测/一次性子命令)
	appleStorefrontArtistDirty bool
)

// appleStorefrontArtistCacheVersion:落盘格式版本。v1 是裸 map(2026-08-30 ~ 09-12),里面的署名**没有经过
// 「这首歌确实在那张专辑里」的核对**(见 appleStorefrontTrackMatches),已实测装进过错人(back number《Happy End - EP》
// → 韩国歌手 Rothy);v2 起整份换成 {"version":2,"entries":{…}},读到 v1 一律丢掉重查 —— 重查每张专辑只花一次,
// 比逐条甄别哪条是错的划算,也比只删已知那一条彻底。
const appleStorefrontArtistCacheVersion = 2

type appleStorefrontArtistFile struct {
	Version int                 `json:"version"`
	Entries map[string][]string `json:"entries"`
}

func loadAppleStorefrontArtistCache(path string) {
	appleStorefrontArtistPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f appleStorefrontArtistFile
	if err := json.Unmarshal(data, &f); err == nil && f.Version == appleStorefrontArtistCacheVersion && f.Entries != nil {
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache = f.Entries
		appleStorefrontArtistMu.Unlock()
		log.Printf("cache: loaded %d Apple storefront artist entries from %s", len(f.Entries), path)
		return
	}
	var legacy map[string][]string
	if err := json.Unmarshal(data, &legacy); err == nil && legacy != nil {
		log.Printf("cache: discarding %d unverified v1 Apple storefront artist entries from %s (re-derived on demand with per-track verification)", len(legacy), path)
	}
}

func saveAppleStorefrontArtistCache() {
	appleStorefrontArtistMu.Lock()
	if !appleStorefrontArtistDirty || appleStorefrontArtistPath == "" {
		appleStorefrontArtistMu.Unlock()
		return
	}
	keep := make(map[string][]string, len(appleStorefrontArtistCache))
	for k, v := range appleStorefrontArtistCache {
		if len(v) > 0 {
			keep[k] = v
		}
	}
	data, err := json.Marshal(appleStorefrontArtistFile{Version: appleStorefrontArtistCacheVersion, Entries: keep})
	appleStorefrontArtistDirty = false
	path := appleStorefrontArtistPath
	appleStorefrontArtistMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("save apple storefront artist cache: %v", err)
	}
}

// appleStorefrontTitleCache 按"艺人|专辑|曲名"缓存**这一首**在原产地商店的规范曲名 ——
// 跟 appleStorefrontArtistCache 是同一次 iTunes 查询的两个产物,但缓存粒度必然不同:署名是
// **专辑级**的(同一张专辑每首歌署名一样),曲名是**曲目级**的,所以分两份各按各的粒度落盘,
// 不合并成一份(合并就得让专辑级的键去装曲目级的值)。
//
// 2026-09-12 加。病根见 appleStorefrontIdentitiesAndTitle 里取 canonicalTitle 那几行的注释。
//
// 跟署名缓存有一处**刻意不同**:这份连"查过了、本地写法就是规范的"这个空结论也落盘(署名那边
// 空值只留内存)。两者空值的含义不一样 —— 署名查空往往是"这张专辑在别的商店没有",留着下次
// 重试有意义;而曲名查空是**绝大多数歌的正常结论**(本地标签本来就是规范写法),不记下来的话
// 每首歌每次都要重新打两次 iTunes 请求。只在这一轮真的定位到过专辑(probed)时才记空串,
// 网络抖动那一轮不会把结论钉死。
var (
	appleStorefrontTitleMu    sync.Mutex
	appleStorefrontTitleCache = map[string]string{}
	appleStorefrontTitlePath  string // 空 = 只用内存不持久化(单测/一次性子命令)
	appleStorefrontTitleDirty bool
)

const appleStorefrontTitleCacheVersion = 1

type appleStorefrontTitleFile struct {
	Version int               `json:"version"`
	Entries map[string]string `json:"entries"`
}

func loadAppleStorefrontTitleCache(path string) {
	appleStorefrontTitlePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f appleStorefrontTitleFile
	if err := json.Unmarshal(data, &f); err == nil && f.Version == appleStorefrontTitleCacheVersion && f.Entries != nil {
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache = f.Entries
		appleStorefrontTitleMu.Unlock()
		log.Printf("cache: loaded %d Apple storefront title entries from %s", len(f.Entries), path)
	}
}

func saveAppleStorefrontTitleCache() {
	appleStorefrontTitleMu.Lock()
	if !appleStorefrontTitleDirty || appleStorefrontTitlePath == "" {
		appleStorefrontTitleMu.Unlock()
		return
	}
	entries := make(map[string]string, len(appleStorefrontTitleCache))
	for k, v := range appleStorefrontTitleCache {
		entries[k] = v
	}
	data, err := json.Marshal(appleStorefrontTitleFile{Version: appleStorefrontTitleCacheVersion, Entries: entries})
	appleStorefrontTitleDirty = false
	path := appleStorefrontTitlePath
	appleStorefrontTitleMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("save apple storefront title cache: %v", err)
	}
}

// appleStorefrontArtistIdentities 给歌词检索多几个**查询身份**,不需要 MusicBrainz、
// 不需要任何手工登记表:同一张专辑在 Apple Music 不同区域商店(CN/US)的曲目署名经常
// 不一样——国际艺名歌手最典型(方大同/Khalil Fong)——这条直接复用 iTunes Search 本来
// 就会回、只是一直没被解码的 artistName 字段,通用地对**任何**歌手生效。
//
// 2026-08-30 加,实测验证过(curl 直接打 iTunes Search API,不是猜的):查询词全程用
// 同一个字符串"方大同 15"(艺人+专辑名,不需要预先知道换成什么名字去查),country=CN
// 时曲目署名回"方大同",country=US 时回"Khalil Fong"——iTunes 自己按商店把这个字段
// 本地化了。跟 resolveAppleMusicMatchViaAlbum 同一套"按专辑名搜、精确定位到
// collectionId 后拿完整曲目表"技巧(比按标题全文搜索准——见那边注释里方大同「Three
// Tour」那个真实案例),但目的不同,刻意不合并:那边要的是"这首歌"的封面/链接,这边要
// 的是"这张专辑在各商店的署名怎么写",不需要定位到具体某一首曲目,专辑里随便一首曲目
// 的署名都能作数,反而更省一次逐曲比对。
//
// 只在 album 非空时生效(跟 resolveAppleMusicMatchViaAlbum 一样)——这条技巧的核心就是
// 靠专辑名精确定位,没有专辑名没法做这件事。
//
// ⚠️ 2026-09-12 加两道门(用户问「这是个日文歌,为什么会出现韩国歌手」):
//   - **挑中的专辑里必须真的有这首歌**(appleStorefrontTrackMatches:时长在容差内,且曲名归一相等或跨文字系统)。
//     原来只按专辑名挑最像的那张、从不核对歌手或曲目,于是 back number《Happy End - EP》在 US 商店(日文 EP 不上架)
//     对上了韩国歌手 Rothy 的同名 EP,「Rothy」被当成 back number 的别名落盘、整张 EP 每首歌的别名轮都拿它白查四个源。
//     只取**对上的那一首**的署名,不再把专辑里随便一首的署名都收进来。
//   - **问哪些商店按文字系统定**(appleStorefrontsFor):基线 CN / US,署名 / 曲名 / 专辑名或首轮歌词正文里出现假名
//     → JP、谚文 → KR、西里尔 → RU、泰文 → TH、繁体汉字 → TW。日文歌只问 CN / US 是永远找不到原专辑的。
func appleStorefrontArtistIdentities(ctx context.Context, artist, title, album string, durationSecs float64, lyricSamples []string) []string {
	names, _ := appleStorefrontIdentitiesAndTitle(ctx, artist, title, album, durationSecs, lyricSamples)
	return names
}

// appleStorefrontCanonicalTitle:同一次商店遍历的**第二个产物** —— 这一条录音在原产地商店的曲名。
// 空 = 本地写法就是规范写法(绝大多数歌),或者压根没定位到这张专辑。
//
// 2026-09-12 加,真实病根(用户报「为什么这首歌只搜出这一个结果」,Mrs. GREEN APPLE《クスシキ》):
// Apple Music 国际区把这首日文歌的标签写成罗马字「KUSUSHIKI」,而 QQ / 酷狗 / 网易云收录的都是
// 日文原名「クスシキ」—— 九个源全应答,却只有 LRCLIB(库里恰好有一条罗马字标题的记录)给得出候选。
// 而三条已有的标题反查路(title-from-album / title-from-artist-search / 「署名 - 曲名」拆分重入)
// **全都拿本地标题当输入**,本地标题正是坏掉的那个东西 —— 死结:要先有日文名才查得到日文名。
//
// 出口本来就在手上:appleStorefrontIdentitiesAndTitle 为了找署名,会按"专辑名 + 时长 + 跨文字系统
// 曲名"(appleStorefrontTrackMatches)逐个商店定位到**这一条录音**,JP 那一轮早就把「クスシキ」
// 取到了 —— 只是那个函数从头到尾只看 ArtistName,曲名用完即弃。把它带出来,一次额外请求都不用多打
// 就能解开死结。消费方见 enrich.go 标题反查那段的第三条路。
//
// ⚠️ **前提(已知边界)**:问哪些商店由 appleStorefrontsFor 按文字系统定,而这类歌的三项标签
// 全是罗马字 —— 把原产地商店带进来的,是**首轮某个源给回来的正文**(lyricSamples)。所以这条
// 修复救得了"九个源里至少有一个给出了正文"的形状(那次是 LRCLIB 给了日文正文);**九源全空时
// 手上没有任何原产地信号,这个死结仍然解不开**。真要覆盖那一档得穷举更多商店(每多一个就多一次
// Search + 可能一次 lookup),是另一笔账,没在这次一起做。TestAppleStorefrontCanonicalTitleLive
// 的 lyricSamples 参数把这个前提钉在测试里了。
func appleStorefrontCanonicalTitle(ctx context.Context, artist, title, album string, durationSecs float64, lyricSamples []string) string {
	_, canonical := appleStorefrontIdentitiesAndTitle(ctx, artist, title, album, durationSecs, lyricSamples)
	return canonical
}

// appleStorefrontIdentitiesAndTitle 是上面两个函数共用的本体:一次商店遍历,两个产物。
func appleStorefrontIdentitiesAndTitle(ctx context.Context, artist, title, album string, durationSecs float64, lyricSamples []string) (names []string, canonicalTitle string) {
	if album == "" {
		return nil, ""
	}
	// 署名的缓存键按 artist+album(不含 title):决定 iTunes 搜索结果和署名的是这两个,同一张
	// 专辑不同曲目该共用同一次查询结果,不必逐曲重查。第一首通过曲目核对就等于核实了这张专辑。
	// 曲名则必然是逐曲的,单独一个键(见 appleStorefrontTitleCache 头注)。
	key := normLoose(artist) + "|" + normLoose(album)
	titleKey := key + "|" + normLoose(title)
	appleStorefrontArtistMu.Lock()
	cachedNames, namesOK := appleStorefrontArtistCache[key]
	appleStorefrontArtistMu.Unlock()
	appleStorefrontTitleMu.Lock()
	cachedTitle, titleOK := appleStorefrontTitleCache[titleKey]
	appleStorefrontTitleMu.Unlock()
	// ⚠️ **两样都命中**才能直接回。只有署名缓存(2026-09-12 之前存下的,或同专辑另一首歌留下的)
	// 是不够的 —— 这一首的曲名还没查过,直接回等于把死结原样留着。
	if namesOK && titleOK {
		return cachedNames, cachedTitle
	}

	q := neturl.QueryEscape(artist + " " + album)
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	probed := false // 至少有一个商店真的定位到了专辑、取过它的曲目表
	for _, country := range appleStorefrontsFor(append([]string{artist, title, album}, lyricSamples...)...) {
		bestID, bestScore := int64(0), 0
		for _, r := range itunesSearch(ctx, q, country) {
			if sc := albumScore(r.CollectionName, album); sc > bestScore {
				bestScore, bestID = sc, r.CollectionID
			}
		}
		if bestID == 0 {
			continue
		}
		var hit *itunesResult
		tracks := itunesLookupTracks(ctx, bestID, country)
		probed = true
		for i := range tracks {
			if appleStorefrontTrackMatches(title, durationSecs, tracks[i]) {
				hit = &tracks[i]
				break
			}
		}
		if hit == nil {
			log.Printf("lyrics: storefront %s: album %q matched %q by name only, none of its %d tracks is %q (%.0fs) — treated as a different album", country, album, artist, len(tracks), title, durationSecs)
			continue
		}
		// ⚠️ 规范曲名必须在下面那道**署名去重之前**取。本地署名本来就对时(日文歌最常见的形状 ——
		// 「Mrs. GREEN APPLE」在哪个商店都这么写),`seen[n]` 那条 continue 会把整条 hit 跳过,
		// 曲名跟着一起丢 —— 2026-09-12 之前正是这么丢的,见 appleStorefrontCanonicalTitle 头注。
		// 取第一个与本地写法不同的:商店按 appleStorefrontsFor 的顺序问,原产地排在基线 CN/US
		// 之后,而真正"换了文字系统"的写法只会出现在原产地那一份。
		if canonicalTitle == "" && hit.TrackName != "" && normLoose(hit.TrackName) != normLoose(title) {
			canonicalTitle = hit.TrackName
		}
		n := normLoose(hit.ArtistName)
		if hit.ArtistName == "" || n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, hit.ArtistName)
	}

	appleStorefrontArtistMu.Lock()
	appleStorefrontArtistCache[key] = out
	// 查空不算脏 —— 空值不落盘,下一个进程还能再试一次,理由同 mbPrimaryNameCache。
	if len(out) > 0 {
		appleStorefrontArtistDirty = true
	}
	appleStorefrontArtistMu.Unlock()
	saveAppleStorefrontArtistCache()
	if probed {
		// 空串也记(含义:查过了,本地写法就是规范的),理由见 appleStorefrontTitleCache 头注。
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache[titleKey] = canonicalTitle
		appleStorefrontTitleDirty = true
		appleStorefrontTitleMu.Unlock()
		saveAppleStorefrontTitleCache()
	}
	return out, canonicalTitle
}

// appleStorefrontTrackMatches:挑中的那张专辑里,这一条曲目是不是本地正在放的这首歌。有时长就以时长为主
// (同名不同歌很难恰好一样长:Rothy 那首 232s 对 back number 314s),曲名要么归一相等、要么跨文字系统(同一录音
// 在 JP 商店叫「ハッピーエンド」、在 US 商店叫「情勝策略」这类本地化写法);没有时长时只能要求曲名归一相等。
func appleStorefrontTrackMatches(localTitle string, durationSecs float64, t itunesResult) bool {
	want := normLoose(localTitle)
	if want == "" {
		return false
	}
	sameTitle := normLoose(t.TrackName) == want
	if durationSecs <= 0 {
		return sameTitle
	}
	if t.TrackTimeMillis <= 0 || math.Abs(t.TrackTimeMillis/1000-durationSecs) > appleTitleSearchDurationTolerance(durationSecs) {
		return false
	}
	return sameTitle || artistScriptDiffers(localTitle, t.TrackName)
}

// appleStorefrontsFor:按文字系统决定问哪些商店(2026-09-12,用户:「是否可以更通用一点,不仅限于 JP」)。
// 基线 CN / US;样本(署名 / 曲名 / 专辑名 + 首轮歌词正文片段)里假名 → JP、谚文 → KR、西里尔 → RU、泰文 → TH、
// 繁体汉字(toSimplified 会改动) → TW。最多再加两个商店:每多一个就多一次 Search(命中再一次 lookup),按专辑只算一次。
// 歌词正文也算样本,是因为标签常是罗马字 / 英文(back number《Happy End》三项标签全是拉丁字母),只有词是日文。
func appleStorefrontsFor(samples ...string) []string {
	out := []string{"CN", "US"}
	seen := map[string]bool{"CN": true, "US": true}
	add := func(c string) {
		if !seen[c] && len(out) < 4 {
			seen[c] = true
			out = append(out, c)
		}
	}
	for _, sample := range samples {
		switch dominantScript(sample) {
		case scriptKana:
			add("JP")
		case scriptHangul:
			add("KR")
		case scriptCyrillic:
			add("RU")
		case scriptThai:
			add("TH")
		case scriptHan:
			if toSimplified(sample) != sample {
				add("TW")
			}
		}
	}
	return out
}

// lyricSamplesForStorefront:给 appleStorefrontsFor 当文字系统样本的首轮歌词正文片段(每条最多 300 个字符,最多 3 条)。
func lyricSamplesForStorefront(results []scoredLyricCandidateResult) []string {
	var out []string
	for _, r := range results {
		if r.Lyrics == "" {
			continue
		}
		rs := []rune(r.Lyrics)
		if len(rs) > 300 {
			rs = rs[:300]
		}
		out = append(out, string(rs))
		if len(out) >= 3 {
			break
		}
	}
	return out
}

// appleTitleSearchIdentities 给歌词检索再多一个**查询身份**来源:拿本地的曲名(+时长)去
// iTunes 全文搜索里找**这一条录音**,采用它在 Apple 目录里的署名。跟上面两条的分工:
//   - appleCatalogSearchIdentities 要**锚点**(本地是从 Apple Music 播放、带 uniqueIdentifier);
//   - appleStorefrontArtistIdentities 要**专辑名**(靠专辑名精确定位到 collectionId);
//   - 这一条两样都不要,只要曲名 —— 正是浏览器播 YouTube Music 那条路的形状:MV 常常不报
//     专辑名,而 YT Music 的 zh-HK 界面把艺人名**本地化**了(2026-09-08 用户报王子
//     《Why You Wanna Treat Me So Bad?》九个源全空:MediaSession 报的 artist 是「王子」,
//     六个源的曲库里这首歌都署「Prince」,换成 Prince 查六个源当场全中)。
//
// 怎么防"同名不同歌"把别人的署名塞进来(这条没有专辑证据,是三条里最弱的,所以门最严):
//   - 曲名**归一后必须完全相等**(normLoose),不是 looseContains 那种包含关系;
//   - 本地有时长时,iTunes 那条的 trackTimeMillis 必须在 appleTitleSearchDurationTolerance 之内
//     —— 同名的另一首歌很难恰好也是这个长度;本地没时长时只信搜索结果里**第一条**同名的;
//   - 最多两个署名(appleTitleSearchMaxIdentities),跟本地写法 normLoose 相同的剔掉;
//   - **本地署名与 iTunes 署名必须一个含 CJK、一个不含**(artistScriptDiffers):这条来源要救的
//     形状是"平台把艺人名翻译/本地化了"(王子 ↔ Prince),跨文字系统正是这种情形的签名;同一文字
//     系统里名字对不上,更可能是**另一位艺人的同名歌**(尤其 Outro / Intro / 序曲 这类通用曲名的
//     器乐段,本地本来就没有歌词,别名轮再拿别人的同名歌去查只会把错的词安上去)。
//
// 查询词先用「艺人 + 曲名」(iTunes 对认不出的艺人 token 容忍度不错,实测「王子 Why You…」
// 照样把 Prince 那条排在前面),一个都没挑出来再用裸曲名试一次。
// 只当**检索身份**用、绝不回写 canonical_artist / 展示字段 —— 跟另两条同一条纪律。
// 缓存只在内存(按 艺人|曲名|时长取整):它只在别名轮触发时才被调用,而 search-lyrics 是
// 一次性进程,落盘收益不大;查空也缓存 —— 同一首歌同一进程里别名轮最多重进几次,不必每次
// 都再打两次 iTunes。
const (
	appleTitleSearchMaxIdentities = 2
	// appleTitleSearchMinDurationSecs:本地时长短于它的不问。抽样库里"九源全空"的 48 条曲目,
	// 多是 Outro / Intro / Doxology / 序曲 这类几十秒的器乐段 —— 它们本来就没有词,而通用曲名 +
	// 几十秒的时长在 iTunes 里最容易撞上另一位艺人的同名段(实测 陶喆《Doxology》47s 撞出
	// "A Covering");真正有词、艺人名又被本地化的歌几乎不会短于 75 秒。
	appleTitleSearchMinDurationSecs = 75
)

// appleTitleSearchDurationTolerance:本地时长与 iTunes 那条允许差多少秒。取 max(4s, 3%):
// MediaSession 报的时长偶有零点几秒的抖动,专辑版与 MV 版通常相同或只差几秒;再宽就会
// 开始放进同名的另一首歌。
func appleTitleSearchDurationTolerance(durationSecs float64) float64 {
	return math.Max(4, durationSecs*0.03)
}

var (
	appleTitleSearchIdentityMu    sync.Mutex
	appleTitleSearchIdentityCache = map[string][]string{}
)

func appleTitleSearchIdentities(ctx context.Context, artist, title string, durationSecs float64) []string {
	if strings.TrimSpace(title) == "" {
		return nil
	}
	key := normLoose(artist) + "|" + normLoose(title) + "|" + fmt.Sprintf("%.0f", durationSecs)
	appleTitleSearchIdentityMu.Lock()
	if v, ok := appleTitleSearchIdentityCache[key]; ok {
		appleTitleSearchIdentityMu.Unlock()
		return v
	}
	appleTitleSearchIdentityMu.Unlock()

	var out []string
	for _, q := range []string{strings.TrimSpace(artist + " " + title), title} {
		var results []itunesResult
		for _, country := range []string{"CN", "US"} {
			results = append(results, itunesSearch(ctx, neturl.QueryEscape(q), country)...)
		}
		if out = pickAppleTitleSearchIdentities(results, artist, title, durationSecs); len(out) > 0 {
			break
		}
	}
	if len(out) > 0 {
		log.Printf("lyrics: apple title-search identities for %q - %q (%.1fs): %v", artist, title, durationSecs, out)
	}
	appleTitleSearchIdentityMu.Lock()
	appleTitleSearchIdentityCache[key] = out
	appleTitleSearchIdentityMu.Unlock()
	return out
}

// pickAppleTitleSearchIdentities 是 appleTitleSearchIdentities 的挑选逻辑,纯函数、可单测:
// 见那边头注里的三道门。
func pickAppleTitleSearchIdentities(results []itunesResult, artist, title string, durationSecs float64) []string {
	want := normLoose(title)
	if want == "" {
		return nil
	}
	if durationSecs > 0 && durationSecs < appleTitleSearchMinDurationSecs {
		return nil
	}
	seen := map[string]bool{normLoose(artist): true}
	var out []string
	for _, r := range results {
		if normLoose(r.TrackName) != want {
			continue
		}
		if durationSecs > 0 {
			if r.TrackTimeMillis <= 0 {
				continue
			}
			if math.Abs(r.TrackTimeMillis/1000-durationSecs) > appleTitleSearchDurationTolerance(durationSecs) {
				continue
			}
		} else if len(out) >= 1 {
			// 没有时长可核:只信第一条同名的,再多就是在猜。
			break
		}
		n := normLoose(r.ArtistName)
		if r.ArtistName == "" || n == "" || seen[n] {
			continue
		}
		if !artistScriptDiffers(artist, r.ArtistName) {
			continue
		}
		seen[n] = true
		out = append(out, r.ArtistName)
		if len(out) >= appleTitleSearchMaxIdentities {
			break
		}
	}
	return out
}

// artistScriptDiffers:两个署名是否一个含 CJK(汉字 / 假名 / 谚文)、一个完全不含。这是
// "平台把艺人名本地化了"的签名(王子 ↔ Prince、迈克尔·杰克逊 ↔ Michael Jackson),也是
// appleTitleSearchIdentities 敢采用一个字面上毫无关系的署名的唯一理由;同文字系统内的不同
// 名字不采(多半是另一位艺人的同名歌)。本地署名为空时按"不同"处理 —— 那时没有可比的对象,
// 交给调用方前面的守卫。
func artistScriptDiffers(local, candidate string) bool {
	if strings.TrimSpace(local) == "" {
		return true
	}
	return containsCJKScript(local) != containsCJKScript(candidate)
}

func containsCJKScript(s string) bool {
	for _, r := range s {
		if isCJKScriptRune(r) {
			return true
		}
	}
	return false
}

// dedupeArtistIdentities 把几组"换个名字再搜一遍"的候选身份按 normLoose 去重后串成一条
// 列表,保留各组内部的原有顺序。给 scoredLyricCandidatesStreaming 用:Apple 目录锚点那
// 一组和 retryArtistIdentities 那一组完全可能给出同一个名字(比如手工别名表里恰好登记过
// 同一位歌手),不去重就是同一个查询词白跑一整轮全源抓取(每轮 20 秒兜底)。
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
