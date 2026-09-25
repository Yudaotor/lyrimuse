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

var spotifyISRCShape = regexp.MustCompile(`^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$`)

// spotifyISRCMissTTL:「查过、没有」记多久。客户端可能过一会儿才把这首的元数据写进缓存,不能永久记成
// 没有;但一首歌解析时会问好几次,不记的话每次都要重读一遍索引块。
const spotifyISRCMissTTL = time.Minute

// spotifyISRCCacheCap 防无界增长。命中的永久记(一条录音的 ISRC 不会变)。
const spotifyISRCCacheCap = 4096

var (
	spotifyISRCMu     sync.Mutex
	spotifyISRCHits   = map[string]string{}
	spotifyISRCMisses = map[string]time.Time{}
	spotifyISRCLogged = map[string]bool{}
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

// spotifyParseISRC 从 spotify.metadata.Track 的值里取 ISRC(external_id,第 10 个字段)。
func spotifyParseISRC(v []byte) string {
	val := spotifyFindAny(v, "spotify.metadata.Track", 0)
	if val == nil {
		return ""
	}
	fields, err := pbParse(val)
	if err != nil {
		return ""
	}
	for _, f := range fields {
		if f.num != 10 || f.wire != 2 {
			continue
		}
		sub, err := pbParse(f.b)
		if err != nil {
			continue
		}
		var typ, id string
		for _, s := range sub {
			if s.wire == 2 && s.num == 1 {
				typ = string(s.b)
			}
			if s.wire == 2 && s.num == 2 {
				id = string(s.b)
			}
		}
		if typ == "isrc" && spotifyISRCShape.MatchString(id) {
			return id
		}
	}
	return ""
}

// spotifyLocalISRC 查这条 Spotify 曲目的 ISRC。第二个返回值 false = 没查到,调用方照常走名称搜索。
func spotifyLocalISRC(trackID string) (string, bool) {
	if len(trackID) != 22 {
		return "", false
	}
	spotifyISRCMu.Lock()
	if code, ok := spotifyISRCHits[trackID]; ok {
		spotifyISRCMu.Unlock()
		return code, true
	}
	if at, ok := spotifyISRCMisses[trackID]; ok && time.Since(at) < spotifyISRCMissTTL {
		spotifyISRCMu.Unlock()
		return "", false
	}
	spotifyISRCMu.Unlock()

	code := ""
	if root := spotifyISRCUsersDir(); root != "" {
		key := spotifyXmetaKey(spotifyTrackKind, trackID)
		for _, dir := range spotifyISRCLedgerDirs(root) { // 登录过多个账号时每个账号一份库
			if code = spotifyParseISRC(ldbGet(dir, [][]byte{key})[string(key)]); code != "" {
				break
			}
		}
	}

	spotifyISRCMu.Lock()
	defer spotifyISRCMu.Unlock()
	if len(spotifyISRCHits) >= spotifyISRCCacheCap || len(spotifyISRCMisses) >= spotifyISRCCacheCap {
		spotifyISRCHits, spotifyISRCMisses, spotifyISRCLogged = map[string]string{}, map[string]time.Time{}, map[string]bool{}
	}
	if code == "" {
		spotifyISRCMisses[trackID] = time.Now()
		return "", false
	}
	delete(spotifyISRCMisses, trackID)
	spotifyISRCHits[trackID] = code
	// 命中记一行(每首一次):取数方式依赖 Spotify 的内部格式,它换一版就可能静默失效,这行是唯一能
	// 发现它失效的凭据。
	if !spotifyISRCLogged[trackID] {
		spotifyISRCLogged[trackID] = true
		log.Printf("spotify isrc: %s -> %s (from client metadata cache)", trackID, code)
	}
	return code, true
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
