// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"
)

// 从 Spotify 客户端自己的缓存里取「正在播的这条录音」的 ISRC。
//
// ISRC 是**录音级**的全球唯一标识(同一首歌的原版 / Live / Instrumental / 重录各有各的),
// 正是这个仓库花最多篇幅对付的那类错误——同名不同录音——的正解。
//
// # 为什么这条跟别的本地路径不是一回事
//
// kugoulocal / qqlocal / neteaselocal 读的是「客户端曲库」,用来省掉一次搜索;这条读的是
// **身份**:换曲那一拍 AppleScript 已经拿到了 22 位 Spotify 曲目 ID(spotifytrack.go,零
// 额外开销),而 Spotify 的元数据缓存里,这个 ID 对应的 spotify.metadata.Track 记录就带着
// 这条录音的 ISRC。整条链路**不经过任何名称匹配** —— 不是搜出来最像的那条,是系统正在播的
// 那一条本身。
//
// 实测收益(Katy Perry《I Kissed A Girl》,本地 ISRC USCA20801738):
//   - Deezer **按名字**搜,第一条是 251 秒的 Live 日文版「キス・ア・ガール ライヴ」;
//   - 按 ISRC 查,直接是 180 秒的原版。MusicBrainz 独立确认 180 秒。
//
// # 取数方式
//
// 用 leveldbread.go 按格式读 primary.ldb:key 是 `!xmeta#cache#` + 类型 01 2a + 长度前缀的曲目 uri,
// 值是 spotify.metadata.Track,ISRC 在它的 external_id(第 10 个字段,{1: "isrc", 2: 码})里。
//
// 原来的做法是把整个库读进来、在**原始字节**上按 `k:<22位>#` 切段再正则捞,注释里自己写着
// 「靠的是这些块恰好没启用压缩」—— 而实际上有一部分数据块是 Snappy 压缩的,原样看不见。拿本机
// enrich 缓存里 237 个 Spotify 曲目 ID 对比:原始字节正则命中 43 个(18%),按格式解析命中 233 个
// (98%),两边都命中的结果逐个一致,剩下 4 个是本地压根没有这首的元数据。原来注释里「命中率约
// 三分之一、跟客户端写没写完整曲目详情有关」的结论,真正的原因是压缩块被漏掉了。
//
// 换成按 key 精确查之后也不再需要后台全量索引:一次查询只读每个 .ldb 的尾部、索引块和命中的那一个
// 数据块,几毫秒,可以当场查 —— 原来第一次播到的歌必然查不到,要等下一轮(最多 15 分钟)重扫。
//
// 只认 ISRC 的标准形状(2 位国家码 + 3 位注册码 + 2 位年份 + 5 位流水 = 12 位)。
// 捞错了不会静默出错:拿一个不存在的 ISRC 去 Deezer/Musixmatch 查只会得到"没这首",
// 于是回落搜索。

// spotifyISRCUsersDirOverride 让单测把目录指到临时路径。空 = 用真实路径。
var spotifyISRCUsersDirOverride string

// spotifyISRCUsersDir 是 Spotify 客户端按账号分的缓存根。 外部 App 的路径,不走 paths.go。
func spotifyISRCUsersDir() string {
	if spotifyISRCUsersDirOverride != "" {
		return spotifyISRCUsersDirOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Application Support/Spotify/PersistentCache/Users")
}

// spotifyISRCRescanMin:两次重扫之间的最小间隔。比另外三条本地路径的 60 秒长得多 ——
// 一轮要读进几十 MB 并全量正则扫(实测约 5 秒),而 Spotify 在跑时这个目录的 mtime 一直在变,
// 节流太短会变成持续的后台 CPU 开销。产出(某条录音的 ISRC)一旦写进缓存也不会再变。
const spotifyISRCRescanMin = 15 * time.Minute

// spotifyISRCMaxFileBytes:单个 .ldb/.log 的读入上限。实测最大 2.2MB;设 32MB 是防"文件
// 异常膨胀"时把内存吃光,不是格式约束。
const spotifyISRCMaxFileBytes = 32 << 20

// spotifyISRCMaxTotalBytes:一轮扫描读入的总字节上限。实测整个 primary.ldb 约 70MB。
const spotifyISRCMaxTotalBytes = 256 << 20

var (
	// 两种 key 形态都认:`k:<22位>#` 是曲目详情记录,`spotify:track:<22位>` 出现在别的
	// 记录里。实测两者合并跟只扫第一种命中数一样,但多认一种不花什么代价。
	spotifyTrackKeyRe = regexp.MustCompile(`(?s)(?:k:|spotify:track:)([0-9A-Za-z]{22})[#\x00-\x20]`)
	spotifyISRCRe     = regexp.MustCompile(`(?s)isrc.{0,2}?([A-Z]{2}[A-Z0-9]{3}[0-9]{7})`)
)

var (
	spotifyISRCMu       sync.Mutex
	spotifyISRCIndex    map[string]string // trackID -> ISRC
	spotifyISRCScanned  time.Time
	spotifyISRCDirMod   time.Time
	spotifyISRCReady    bool
	spotifyISRCBuilding bool
)

// spotifyISRCLedgerDirs 列出所有账号的 primary.ldb(多账号登录过就有多个)。
func spotifyISRCLedgerDirs(root string) []string {
	ents, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var dirs []string
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		p := filepath.Join(root, e.Name(), "primary.ldb")
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			dirs = append(dirs, p)
		}
	}
	return dirs
}

// scanSpotifyISRCLedger 扫一个 primary.ldb 目录,把 trackID→ISRC 填进 idx。
//
// 切段方式:相邻两个 key 之间就是前一个 key 的 value。这是 LevelDB 里 key 有序排列的
// 自然结果,不需要理解 protobuf 本身。
func scanSpotifyISRCLedger(dir string, idx map[string]string, budget *int64) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range ents {
		name := e.Name()
		if e.IsDir() || (filepath.Ext(name) != ".ldb" && filepath.Ext(name) != ".log") {
			continue
		}
		path := filepath.Join(dir, name)
		st, err := e.Info()
		if err != nil || st.Size() > spotifyISRCMaxFileBytes || *budget <= 0 {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		*budget -= int64(len(data))
		keys := spotifyTrackKeyRe.FindAllSubmatchIndex(data, -1)
		for i, m := range keys {
			id := string(data[m[2]:m[3]])
			if _, seen := idx[id]; seen {
				continue
			}
			end := len(data)
			if i+1 < len(keys) {
				end = keys[i+1][0]
			}
			if sub := spotifyISRCRe.FindSubmatch(data[m[0]:end]); sub != nil {
				idx[id] = string(sub[1])
			}
		}
	}
}

// refreshSpotifyISRCIndexLocked 在缓存目录变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 spotifyISRCMu。
//
// 节流放到 5 分钟(比另外三条本地路径的 60 秒长):这一轮要读进几十 MB 并全量正则扫,
// 比读一张 SQLite 表贵得多,而它的产出——某条录音的 ISRC——一旦写进缓存就不会变。
func refreshSpotifyISRCIndexLocked() {
	root := spotifyISRCUsersDir()
	if root == "" {
		spotifyISRCIndex, spotifyISRCReady = nil, true
		return
	}
	st, err := os.Stat(root)
	if err != nil || !st.IsDir() {
		// 没装 Spotify / 没登录过 —— 正常情况,不记日志。
		spotifyISRCIndex, spotifyISRCReady = nil, true
		return
	}
	now := time.Now()
	if spotifyISRCReady && st.ModTime().Equal(spotifyISRCDirMod) {
		return
	}
	if spotifyISRCReady && now.Sub(spotifyISRCScanned) < spotifyISRCRescanMin {
		return
	}
	spotifyISRCDirMod, spotifyISRCScanned, spotifyISRCReady = st.ModTime(), now, true

	idx := map[string]string{}
	budget := int64(spotifyISRCMaxTotalBytes)
	for _, dir := range spotifyISRCLedgerDirs(root) {
		scanSpotifyISRCLedger(dir, idx, &budget)
	}
	spotifyISRCIndex = idx
	if len(idx) > 0 {
		log.Printf("spotify isrc: indexed %d recordings from client cache", len(idx))
	}
}

// spotifyISRCEnsureIndexAsync 触发一次**后台**索引构建;已经在建就什么都不做。
//
// ⚠️ 为什么绝不同步建:一轮全量扫描实测约 5 秒,而调用点在歌词解析的热路径上。宁可这一首
// 拿不到 ISRC(照常走搜索,零损失),也不能让整条歌词链路等它。下一首就能用上。
func spotifyISRCEnsureIndexAsync() {
	spotifyISRCMu.Lock()
	if spotifyISRCBuilding {
		spotifyISRCMu.Unlock()
		return
	}
	spotifyISRCBuilding = true
	spotifyISRCMu.Unlock()
	go func() {
		spotifyISRCMu.Lock()
		defer spotifyISRCMu.Unlock()
		refreshSpotifyISRCIndexLocked()
		spotifyISRCBuilding = false
	}()
}

// spotifyISRCBuildIndexNow 同步建一次索引。只给单测用 —— 生产路径一律走
// spotifyISRCEnsureIndexAsync。
func spotifyISRCBuildIndexNow() {
	spotifyISRCMu.Lock()
	defer spotifyISRCMu.Unlock()
	refreshSpotifyISRCIndexLocked()
}

// spotifyLocalISRC 查这条 Spotify 曲目的 ISRC。第二个返回值 false = 没查到,
// 调用方照常走名称搜索。**从不阻塞**:索引没建好就先返回空,后台去建。
func spotifyLocalISRC(trackID string) (string, bool) {
	if len(trackID) != 22 {
		return "", false
	}
	spotifyISRCMu.Lock()
	ready := spotifyISRCReady
	code, ok := spotifyISRCIndex[trackID]
	spotifyISRCMu.Unlock()
	if !ready || !ok {
		// 没建过,或这条查不到(索引可能旧了 —— 这首歌是刚听的)。丢后台重建,
		// 里头的 mtime + 节流判断会决定要不要真扫。
		spotifyISRCEnsureIndexAsync()
	}
	return code, ok
}

// playbackISRC 是给歌词源用的入口:「这次播放的这首歌」的 ISRC,没有就返回空串。
//
// 只在 Spotify 原生客户端播放时有值 —— 曲目 ID 由 platformtrackid.go 在换曲那一拍记下,
// 别的播放器放同一首歌时那里是空的。别名轮 / 拆分身份轮传的是改写过的署名,那时
// playbackTrackIDsFor 必然落空,这里跟着返回空串:提示说的是「系统报的这一条录音」,
// 换了身份就不再对应同一条。
func playbackISRC(artist, title, album string) string {
	_, trackID := playbackTrackIDsFor(artist, title, album)
	if trackID == "" {
		return ""
	}
	code, ok := spotifyLocalISRC(trackID)
	if !ok {
		return ""
	}
	return code
}
