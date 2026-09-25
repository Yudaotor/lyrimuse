// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// QQ 音乐客户端自己的本地曲库 —— QQ 源"拿 songmid"这一步的快速路径。
//
// 现有链路拿 mid 要走 qqMusicMatchCached → resolveQQMusicMatch:一次 smartbox /
// client_search 搜索(6 秒超时)外加一整套候选打分挑选。那一步正是"挑错版本"的来源——
// 同名曲、live/remix 变体、翻唱与仿冒账号,全靠打分去分辨(见 match.go 里 PRINCE《319》
// X-cerpt 那桩)。
//
// 而 QQ 客户端把它认得的每一首歌连 songmid 一起**明文**记在 qqmusic.sqlite 的 SONGS 表里
// (本机实测 508 行,K_SONG_RESERVE1 就是 songmid,508/508 非空)。命中时这一跳网络连同它
// 的挑选风险一起省掉:拿到的是客户端为这首歌记下的那个 mid,不是搜出来最像的那个。
//
// 跟酷狗的本地 KRC(kugoulocal.go)**不是**一回事,差别必须说清:
//   - 酷狗那条是**零网络** —— 歌词正文就在盘上;这条只省"搜索"那一跳,歌词正文
//     (qqLyric / qqQRCLyric)照旧联网取。
//   - 所以熔断口径也不同:酷狗那条在源冷却时仍要查本地(熔断挡的是网络、不该挡读盘),
//     这条**不碰熔断** —— 它拿到 mid 之后照样要发请求,源冷却时拿到 mid 也没用。
//
// 不限于"正在用 QQ 音乐播放":SONGS 是持久曲库(收藏歌单 + 最近播放),用 Apple Music 放
// 一首在 QQ 里收藏过的歌,一样查得到 mid。
//
// 为什么 exec /usr/bin/sqlite3 而不是引一个 SQLite 驱动:这个 module 至今**零外部依赖**
// (go.mod 里一条 require 都没有),为读 5 个字段引入 cgo 驱动或一个纯 Go 的 SQLite 实现
// 都不划算;而 exec 系统自带命令本来就是这个仓库的既有做法(osascript / scutil /
// defaults / pgrep)。
//
// 全程 fail-soft:没装 QQ 音乐 / 库打不开 / 表结构变了 / sqlite3 不在,一律当没命中,
// 照常回落 resolveQQMusicMatch。它读的是**另一个 App 的数据库**,对方升级随时可能改表。

// qqLocalDBOverride 让单测把库指到临时路径。空 = 用真实路径。
var qqLocalDBOverride string

// qqLocalDBPath 是 QQ 音乐客户端的曲库。 这是**外部 App** 的路径,不是这个项目自己的
// 数据位置,所以不走 paths.go 那套身份口径。
func qqLocalDBPath() string {
	if qqLocalDBOverride != "" {
		return qqLocalDBOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.tencent.QQMusicMac/Data/Library",
		"Application Support/QQMusicMac/qqmusic.sqlite")
}

// qqLocalRescanMin:两次重扫之间的最小间隔。客户端**每切一首歌**就写这个库(实测 mtime
// 每首都动),所以 mtime 变了并不意味着 SONGS 有我们关心的新行 —— 节流才是主闸,mtime
// 只用作"没变就绝对不用重扫"的快速否定。
const qqLocalRescanMin = 60 * time.Second

// qqLocalQueryTimeout:单次查询的墙钟上限。本机 508 行在毫秒级返回,4 秒纯粹是防"库被
// 锁住 / 盘卡住"时拖住歌词主流程。
const qqLocalQueryTimeout = 4 * time.Second

// qqLocalMaxRows:一次读回的行数上限。防的是"这个库将来变得很大"时把整张表塞进内存,
// 不是格式约束。
const qqLocalMaxRows = 20000

// K_SONG_RESERVE1 / K_SONG_RESERVE12 是 QQ 自己的保留字段名(整张表 83 列里有 60 多个
// K_SONG_RESERVE*),含义靠实测对出来:RESERVE1 是 14 位 base62 的 songmid、RESERVE12 是
// 毫秒时长(与 media-control 报的秒数逐首吻合)。 保留字段的语义**没有任何兼容承诺**,
// 客户端换版可能挪位置 —— 所以下游一律有守卫:mid 拿去查歌词,查不到就是没命中;时长
// 只作挑选判据,离谱了顶多让这条候选落选,不会把错的歌词喂上去。
const qqLocalSongsSQL = `SELECT K_SONG_RESERVE1 AS mid, name, singer, album,
	K_SONG_RESERVE12 AS ms FROM SONGS
	WHERE K_SONG_RESERVE1 <> '' AND name <> '' LIMIT 20000`

type qqLocalEntry struct {
	mid, title, artist, album string
	duration                  float64 // 秒,0=库里没给
}

type qqLocalRow struct {
	Mid    string `json:"mid"`
	Name   string `json:"name"`
	Singer string `json:"singer"`
	Album  string `json:"album"`
	MS     int64  `json:"ms"`
}

var (
	qqLocalMu      sync.Mutex
	qqLocalIndex   map[string][]qqLocalEntry
	qqLocalDBMod   time.Time
	qqLocalDBSize  int64
	qqLocalScanned time.Time
	qqLocalReady   bool
)

// qqLocalKey 是索引键 —— 歌手与歌名各自 normLoose(繁简/大小写/标点/变音都折掉),跟这个
// 仓库其它跨源匹配用的是同一把尺子(与 kugouLocalKey 同构)。
func qqLocalKey(artist, title string) string {
	na, nt := normLoose(artist), normLoose(title)
	if na == "" || nt == "" {
		return ""
	}
	return na + "|" + nt
}

// queryQQLocalSongs 读一次 SONGS。
//
// mode=ro 而不是 immutable=1:immutable 跳过一切锁,代价是可能读到客户端正写到一半的页;
// mode=ro 拿到的是一致快照,真撞上锁就直接 SQLITE_BUSY 失败 —— 对我们正好,fail-soft 退回
// 网络那条。这个库是 rollback journal 模式(没有 -wal / -shm),只读打开不需要写任何东西,
// 不会干扰客户端。
func queryQQLocalSongs(ctx context.Context, dbPath string) ([]qqLocalRow, error) {
	ctx, cancel := context.WithTimeout(ctx, qqLocalQueryTimeout)
	defer cancel()
	// 用 net/url 组 URI 而不是手工拼:真实路径里带空格("Application Support"),必须转义成
	// %20,否则 sqlite3 收到的是被截断的文件名。
	uri := (&neturl.URL{Scheme: "file", Path: dbPath, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, qqLocalSongsSQL).Output()
	if err != nil {
		return nil, err
	}
	trimmed := bytes.TrimSpace(out)
	// sqlite3 -json 对**零行**结果输出的是空串,不是 "[]" —— 直接喂给 Unmarshal 会报
	// "unexpected end of JSON input",把"这库里没这首歌"错当成"读库失败"。
	if len(trimmed) == 0 {
		return nil, nil
	}
	var rows []qqLocalRow
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		return nil, err
	}
	if len(rows) > qqLocalMaxRows {
		rows = rows[:qqLocalMaxRows]
	}
	return rows, nil
}

// refreshQQLocalIndexLocked 在库变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 qqLocalMu。
func refreshQQLocalIndexLocked(ctx context.Context) {
	path := qqLocalDBPath()
	if path == "" {
		qqLocalIndex, qqLocalReady = nil, true
		return
	}
	st, err := os.Stat(path)
	if err != nil || st.IsDir() {
		// 没装 QQ 音乐 / 没登录过 / 路径变了 —— 都是正常情况,静默退回网络解析。
		// 被 TCC 拒了**不是**常态,那一种由 noteLocalCacheDenied 记一行,理由见它的头注。
		noteLocalCacheDenied("qq", path, err)
		qqLocalIndex, qqLocalReady = nil, true
		return
	}
	// 读到了就撤掉「被拒」—— 授权之后设置页那个提示要能自己消失。
	noteLocalCacheReadable("qq")
	now := time.Now()
	if qqLocalReady && st.ModTime().Equal(qqLocalDBMod) && st.Size() == qqLocalDBSize {
		return
	}
	if qqLocalReady && now.Sub(qqLocalScanned) < qqLocalRescanMin {
		return
	}
	qqLocalDBMod, qqLocalDBSize = st.ModTime(), st.Size()
	qqLocalScanned, qqLocalReady = now, true

	rows, err := queryQQLocalSongs(ctx, path)
	if err != nil {
		// 库被锁 / sqlite3 不在 / 表结构变了。保留上一次的索引:它可能仍然有用,而且
		// 重建失败是常态化的偶发(客户端切歌时正好在写),不该每次都把命中率清零。
		return
	}
	idx := map[string][]qqLocalEntry{}
	for _, r := range rows {
		key := qqLocalKey(r.Singer, r.Name)
		if key == "" || r.Mid == "" {
			continue
		}
		idx[key] = append(idx[key], qqLocalEntry{
			mid: r.Mid, title: r.Name, artist: r.Singer, album: r.Album,
			duration: float64(r.MS) / 1000,
		})
	}
	qqLocalIndex = idx
	if len(idx) > 0 {
		log.Printf("qq local: indexed %d tracks from client library", len(idx))
	}
}

// pickQQLocalEntry 在同名同歌手的多条本地记录里挑一条。
//
// 先过时长闸(sourceDurationFits,与打分层 sourceDurationOff 同 12% 口径):本地库里同名
// 不同版本(remix / live / 节选)是真实存在的,给错版本会让逐字歌词的时间轴整首错位——
// 比"没命中、老实走网络"糟得多。全部过不了闸就**不命中**,宁可白跑一次搜索。
//
// 过了闸之后:专辑对得上的优先(+1000 足够压过任何时长差),其次时长差最小。
func pickQQLocalEntry(entries []qqLocalEntry, album string, durationSecs float64) (qqLocalEntry, bool) {
	var best qqLocalEntry
	var bestScore float64
	found := false
	for _, e := range entries {
		if !sourceDurationFits(durationSecs, e.duration) {
			continue
		}
		score := 0.0
		if album != "" && e.album != "" && normLoose(e.album) == normLoose(album) {
			score += 1000
		}
		if durationSecs > 0 && e.duration > 0 {
			score -= math.Abs(e.duration - durationSecs)
		}
		if !found || score > bestScore {
			best, bestScore, found = e, score, true
		}
	}
	return best, found
}

// qqLocalMatch 在 QQ 客户端的本地曲库里找这首歌的 songmid。第二个返回值 false = 没命中,
// 调用方照常走 resolveQQMusicMatch。
func qqLocalMatch(ctx context.Context, artist, title, album string, durationSecs float64) (qqMusicMatch, bool) {
	key := qqLocalKey(artist, title)
	if key == "" {
		// 歌手名缺失(部分播放器不报)时不做"只按歌名"的兜底:本地库里跨歌手同名有 6 组,
		// 而这条路径的全部价值就在于"不靠猜"。猜不准就让它走网络搜索,那边有完整的打分。
		return qqMusicMatch{}, false
	}
	qqLocalMu.Lock()
	refreshQQLocalIndexLocked(ctx)
	ents := append([]qqLocalEntry(nil), qqLocalIndex[key]...)
	qqLocalMu.Unlock()
	if len(ents) == 0 {
		return qqMusicMatch{}, false
	}
	e, ok := pickQQLocalEntry(ents, album, durationSecs)
	if !ok {
		return qqMusicMatch{}, false
	}
	// 每首歌最多一行:上游 qqMusicMatchCached 按 artist|title|album|duration 缓存,不会重复问。
	// 这行是"这首歌的 mid 来自客户端曲库、没走 smartbox 搜索"的唯一凭据 —— 跟 kugou local
	// 那行同一用途,决策面板只记得到源名、记不到 mid 是怎么来的。
	log.Printf("qq local: hit %q - %q (album %q) → %s", artist, title, e.album, e.mid)
	// 复用 qqMatchFromCand:url 得是 qqSongURL 那个形状,下游 qqMidFromURL 才解得回 mid。
	m := qqMatchFromCand(qqCand{
		mid: e.mid, title: e.title, artist: e.artist,
		album: e.album, interval: e.duration,
	}, false)
	// 身份来自客户端曲库记下的那个 mid,不经搜索 —— 同源加权的准入条件。
	m.fromLocalLibrary = true
	return m, true
}

// ---- 播放队列:接下来会播的几首(见 upcoming.go)----

// qqUpcomingOverride 让单测把归档指到临时路径。空 = 用真实路径。
var qqUpcomingOverride string

// qqUpcomingMaxBytes 是 plutil 输出的大小上限。本机 13 首的队列转出来 132KB,
// 16MB 是防"格式变了 / 队列被塞进上万首"时把内存吃光,不是格式约束。
const qqUpcomingMaxBytes = 16 << 20

// qqUpcomingPath 是 QQ 音乐客户端的当前播放列表归档(NSKeyedArchiver bplist)。
// 跟 qqLocalDBPath 是两份完全不同的东西:那个是曲库(sqlite,存"这台机器上有哪些歌"),
// 这个是**此刻的播放列表**。它只在开始播一个列表时写一次,之后换歌不重写 —— 顺序播放、
// 随机播放都实测过,LastPlayingIndex 一直停在开播那一首。同目录的 normalPlayingList.archive
// 与它逐字节相同,随机播放时也一样,所以打乱后的顺序不在这两份文件里。
func qqUpcomingPath() string {
	if qqUpcomingOverride != "" {
		return qqUpcomingOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.tencent.QQMusicMac/Data/Library",
		"Application Support/QQMusicMac/iTemp/PlayingList.archive")
}

// qqDeref 把 NSKeyedArchiver 的对象引用解成实际对象。不是引用就原样返回 ——
// 归档里同一个字段可能是 UID 也可能是立即值(实测 LastPlayingIndex 就是直接的整数)。
func qqDeref(objs []any, v any) any {
	u, ok := v.(plistUID)
	if !ok {
		return v
	}
	if int(u) < 0 || int(u) >= len(objs) {
		return nil
	}
	return objs[u]
}

// qqPlistField 取一个字典字段并解引用。
func qqPlistField(objs []any, obj any, key string) any {
	m, ok := obj.(map[string]any)
	if !ok {
		return nil
	}
	return qqDeref(objs, m[key])
}

// qqUpcomingArtist 把一条曲目的全部署名拼成一串。
//
// 拼**全部**的理由同 sodaUpcomingArtist:少了后面几位,loosenEnrichKey 折平分隔符
// 之后仍然对不上播放器报的完整串,预取好的条目命中不了。singerList 是权威来源
// (NSArray,每个成员一个 name);它空的时候才退回 singerInfo.name 那个主歌手。
func qqUpcomingArtist(objs []any, song any) string {
	var names []string
	if list, ok := qqPlistField(objs, song, "singerList").(map[string]any); ok {
		if arr, ok := qqDeref(objs, list["NS.objects"]).([]any); ok {
			for _, it := range arr {
				if s, ok := qqPlistField(objs, qqDeref(objs, it), "name").(string); ok && s != "" {
					names = append(names, s)
				}
			}
		}
	}
	if len(names) == 0 {
		if s, ok := qqPlistField(objs, qqPlistField(objs, song, "singerInfo"), "name").(string); ok {
			return s
		}
		return ""
	}
	return strings.Join(names, "/")
}

// qqPlayOrderLast 记同一份播放列表里上一次看到的位置,用来从相邻两次换歌推断顺序 / 随机(见 queueorder.go)。
//
// 播放模式 QQ 只存在加密的 MMKV 里(iData/),读不到;系统媒体接口上也没有(它注册的遥控命令不带
// 随机 / 循环信息)。列表身份 = 归档路径 + mtime + 曲目数:归档只在开播时写,mtime 变了就是换了列表。
var (
	qqPlayOrderMu   sync.Mutex
	qqPlayOrderLast queueOrder
)

// qqObservePosition 记下这一次的位置,返回此刻是否按随机处理。
func qqObservePosition(list string, pos int) (shuffled bool) {
	qqPlayOrderMu.Lock()
	defer qqPlayOrderMu.Unlock()
	prevPos := qqPlayOrderLast.pos
	shuffled, flipped := qqPlayOrderLast.observe(list, pos)
	if flipped {
		log.Printf("qq upcoming: moved from position %d to %d in the play list, treating playback as shuffled and prefetching from the whole list", prevPos, pos)
	}
	return shuffled
}

// qqUpcoming 从 QQ 音乐的播放列表归档里取接下来会播的几首。
//
// 当前这首先看 LastPlayingIndex 那一条,对不上再在整份列表里按歌名歌手找(归档只在开播时写,
// 换过歌之后 LastPlayingIndex 必然过期)。列表里找不到 = 这份文件是上一次播放留下的(用户切去
// 别的播放器听、或者刚启动还没播),返回 ok=false,让调用方退回同专辑预取。
// 推断为随机播放时交出的是「可能随机到的」那一批(见 queueShuffleWholeListMax 头注),n 不适用;
// 那一批里全都解析过了也返回 ok=true(交给队列这一层处理过了,不必再退回同专辑预取)。
// qqPlayingList 是解开的播放列表归档,以及此刻在播的这首在里面的位置。
type qqPlayingList struct {
	path  string
	objs  []any
	items []any
	pos   int
}

// qqLoadPlayingList 读归档并找到当前这首:先看 LastPlayingIndex 那一条,对不上再在整份列表里按歌名歌手找。
// 列表里没有这首(归档是上一次播放留下的)或读不动都返回 ok=false。
func qqLoadPlayingList(artist, title string) (qqPlayingList, bool) {
	path := qqUpcomingPath()
	if path == "" {
		return qqPlayingList{}, false
	}
	// 零外部依赖:用系统自带的 plutil 把 bplist 转成 XML 再解,同这个文件里 exec
	// /usr/bin/sqlite3 的路数。 只能转 xml1,json 会因为 UID 直接失败,见 plistxml.go。
	ctx, cancel := context.WithTimeout(context.Background(), qqLocalQueryTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", path).Output()
	if err != nil {
		// plutil 对读不到的文件是退出码非零 + stderr,拿不到 fs.ErrPermission。先 Stat 一次
		// 把"被 TCC 拒"这一种单独认出来 —— 它不是常态,要在设置页留痕(见 localcachefs.go)。
		if _, statErr := os.Stat(path); statErr != nil {
			noteLocalCacheDenied("qq", path, statErr)
		}
		return qqPlayingList{}, false
	}
	noteLocalCacheReadable("qq")
	if len(out) > qqUpcomingMaxBytes {
		return qqPlayingList{}, false
	}
	root, err := parsePlistXML(out)
	if err != nil {
		return qqPlayingList{}, false
	}
	rootMap, ok := root.(map[string]any)
	if !ok {
		return qqPlayingList{}, false
	}
	objs, _ := rootMap["$objects"].([]any)
	top, _ := rootMap["$top"].(map[string]any)
	if len(objs) == 0 || top == nil {
		return qqPlayingList{}, false
	}
	items, ok := qqPlistField(objs, qqPlistField(objs, qqDeref(objs, top["PlayingList"]), "ListData"), "NS.objects").([]any)
	if !ok {
		return qqPlayingList{}, false
	}
	want := loosenEnrichKey(artist + "|" + title)
	isCurrent := func(i int) bool {
		song := qqDeref(objs, items[i])
		name, _ := qqPlistField(objs, song, "songName").(string)
		return loosenEnrichKey(qqUpcomingArtist(objs, song)+"|"+name) == want
	}
	pos := -1
	if idx, ok := qqDeref(objs, top["LastPlayingIndex"]).(int64); ok && idx >= 0 && int(idx) < len(items) && isCurrent(int(idx)) {
		pos = int(idx)
	} else {
		for i := range items {
			if isCurrent(i) {
				pos = i
				break
			}
		}
	}
	if pos < 0 {
		return qqPlayingList{}, false // 列表里没有此刻在播的这首:归档是上一次播放留下的
	}
	return qqPlayingList{path: path, objs: objs, items: items, pos: pos}, true
}

func qqUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	pl, ok := qqLoadPlayingList(artist, title)
	if !ok {
		return nil, false
	}
	path, objs, items, pos := pl.path, pl.objs, pl.items, pl.pos
	list := ""
	if st, err := os.Stat(path); err == nil {
		list = fmt.Sprintf("%s/%d/%d", path, st.ModTime().UnixNano(), len(items))
	}
	if qqObservePosition(list, pos) {
		return qqShuffleCandidates(objs, items, pos), true
	}
	res := make([]upcomingTrack, 0, n)
	for i := pos + 1; i < len(items) && len(res) < n; i++ {
		if t, ok := qqTrackAt(objs, items, i); ok {
			res = append(res, t)
		}
	}
	return res, len(res) > 0
}

// qqShuffleCandidates 是随机播放时交出去预解析的那一批,规则见 queueShuffleWholeListMax 头注。
func qqShuffleCandidates(objs []any, items []any, pos int) []upcomingTrack {
	return shuffleCandidates(len(items), pos, func(i int) (upcomingTrack, bool) {
		return qqTrackAt(objs, items, i)
	})
}

// qqAlbumTracks 是 QQ 音乐的同专辑兜底:在播放列表归档里找到当前这首,拿它的 albumMid 问 QQ 自己的
// 专辑曲目表(qqAlbumSongs,按 albumMid 缓存)。曲目名与全部歌手是 QQ 自己的写法,跟 QQ 播放器报的一致,
// 写进 enrich key 不会跟真播到那一刻对不上。归档里没有这首、没有 albumMid、接口失败都返回 ok=false,
// 由 albumTracks 退回网易云那条。
func qqAlbumTracks(artist, title, album string) ([]albumTrack, bool) {
	pl, ok := qqLoadPlayingList(artist, title)
	if !ok {
		return nil, false
	}
	mid, _ := qqPlistField(pl.objs, qqPlistField(pl.objs, qqDeref(pl.objs, pl.items[pl.pos]), "albumInfo"), "albumMid").(string)
	if mid == "" {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	songs, err := qqAlbumSongs(ctx, mid)
	if err != nil || len(songs) == 0 {
		return nil, false
	}
	tracks := make([]albumTrack, 0, len(songs))
	for _, s := range songs {
		singers := s.singers
		if len(singers) == 0 && s.singer != "" {
			singers = []string{s.singer}
		}
		tracks = append(tracks, albumTrack{title: s.name, artist: strings.Join(singers, "/"), duration: s.interval})
	}
	log.Printf("album prefetch: %q from qq album %s (%d tracks)", album, mid, len(tracks))
	return tracks, true
}

// qqTrackAt 取列表第 i 首;没有歌名的条目返回 ok=false。
func qqTrackAt(objs []any, items []any, i int) (upcomingTrack, bool) {
	song := qqDeref(objs, items[i])
	name, _ := qqPlistField(objs, song, "songName").(string)
	if name == "" {
		return upcomingTrack{}, false
	}
	album, _ := qqPlistField(objs, qqPlistField(objs, song, "albumInfo"), "name").(string)
	// song_Duration 是秒(实测 214),不是毫秒 —— 跟汽水那边相反,别照抄。
	dur, _ := qqPlistField(objs, song, "song_Duration").(float64)
	return upcomingTrack{
		artist:   qqUpcomingArtist(objs, song),
		title:    name,
		album:    album,
		duration: dur,
	}, true
}
