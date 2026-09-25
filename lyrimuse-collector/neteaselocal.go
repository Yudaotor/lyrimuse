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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 网易云客户端自己的本地曲库 —— netease 源"拿 songID"这一步的快速路径。
//
// 与 qqlocal.go **同一形状**(读别的 App 的本地库拿权威 ID、省掉搜索那一跳),差别只在
// 表结构:网易云把它见过的每一首歌整条 JSON 存进 sqlite_storage.sqlite3 的 `dbTrack`
// 表(`id` = songID,`jsonStr` = 含 name / artists / album / duration 的完整曲目 JSON;
// 本机实测 734 行,id/name/duration 734/734 齐全,歌手 720、专辑 719)。
//
// resolveNeteaseInfo 现在先查它;命中就直接当作 pick() 选中的那条 chosen,整个搜索循环
// (多条查询词 × /api/search,还带限流退避)都不跑。
//
// 跟酷狗本地 KRC(kugoulocal.go)**不是**一回事,跟 qqlocal 一样只省"找到是哪首歌"
// 这一步 —— 歌词正文(/api/song/lyric)照旧联网取,所以同样**不碰熔断**。
//
// 为什么值得:网易云那段搜索是这条源最脆的地方 —— 它按端点分桶做应用层限流,**限流时
// 照样回 HTTP 200**、把拒绝写在 body 的 code 里(见 resolveNeteaseInfo 里那段长注释),
// 一次几分钟的限流能让那段时间解析的歌永远缺译文/罗马音(网易云是唯一同时给这两轨的源)。
// 本地命中时这一整段风险连同挑错版本的风险一起绕开。
//
// 不限于"正在用网易云播放":dbTrack 收的是客户端见过的歌(播放历史 62 条、歌单、搜索结果
// 都会进),734 行远大于播放历史本身。
//
// 全程 fail-soft:没装网易云 / 库打不开 / 表结构变了 / sqlite3 不在,一律当没命中,
// 照常走原来的搜索。

// neteaseLocalDBOverride 让单测把库指到临时路径。空 = 用真实路径。
var neteaseLocalDBOverride string

// neteaseLocalDBPath 是网易云客户端的主数据库。 外部 App 的路径,不走 paths.go 那套。
func neteaseLocalDBPath() string {
	if neteaseLocalDBOverride != "" {
		return neteaseLocalDBOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.netease.163music/Data",
		"Documents/storage/sqlite_storage.sqlite3")
}

const neteaseLocalRescanMin = 60 * time.Second
const neteaseLocalQueryTimeout = 4 * time.Second
const neteaseLocalMaxRows = 20000

// dbTrack 一行就是一条完整曲目 JSON,列名本身没有语义(`id` + `jsonStr`),所以这里只取
// jsonStr,结构交给 neteaseLocalTrack 解。
const neteaseLocalTracksSQL = "SELECT jsonStr FROM dbTrack WHERE jsonStr <> '' LIMIT 20000"

// flexID 同时接受 "123" 和 123 两种写法。dbTrack 当前把 id / album.id 写成**字符串**
// 形态的数字("569213220"),但这是别人的库,换版改成数字形态不该让整条路径失效。
type flexID int64

func (f *flexID) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "" || s == "null" {
		return nil
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return err
	}
	*f = flexID(v)
	return nil
}

type neteaseLocalTrack struct {
	ID      flexID `json:"id"`
	Name    string `json:"name"`
	Artists []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Album struct {
		ID   flexID `json:"id"`
		Name string `json:"name"`
	} `json:"album"`
	Duration float64 `json:"duration"` // 毫秒
}

type neteaseLocalRow struct {
	JSONStr string `json:"jsonStr"`
}

var (
	neteaseLocalMu      sync.Mutex
	neteaseLocalIndex   map[string][]neteaseLocalTrack
	neteaseLocalDBMod   time.Time
	neteaseLocalDBSize  int64
	neteaseLocalScanned time.Time
	neteaseLocalReady   bool
)

// neteaseLocalKey 是索引键 —— 与 kugouLocalKey / qqLocalKey 同一把尺子(normLoose)。
func neteaseLocalKey(artist, title string) string {
	na, nt := normLoose(artist), normLoose(title)
	if na == "" || nt == "" {
		return ""
	}
	return na + "|" + nt
}

// queryNeteaseLocalTracks 读一次 dbTrack。mode=ro 的理由同 qqlocal.go:拿一致快照、撞锁
// 就干净失败;该库是 rollback journal 模式(实测 journal_mode=delete,无 -wal/-shm),
// 只读打开不写任何东西,不会干扰客户端。
func queryNeteaseLocalTracks(ctx context.Context, dbPath string) ([]neteaseLocalTrack, error) {
	ctx, cancel := context.WithTimeout(ctx, neteaseLocalQueryTimeout)
	defer cancel()
	uri := (&neturl.URL{Scheme: "file", Path: dbPath, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, neteaseLocalTracksSQL).Output()
	if err != nil {
		return nil, err
	}
	trimmed := bytes.TrimSpace(out)
	// 零行时 sqlite3 -json 输出空串而不是 "[]",同 qqlocal.go。
	if len(trimmed) == 0 {
		return nil, nil
	}
	var rows []neteaseLocalRow
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		return nil, err
	}
	if len(rows) > neteaseLocalMaxRows {
		rows = rows[:neteaseLocalMaxRows]
	}
	// 逐行解,单行解不开就跳过而不是整批放弃:jsonStr 是客户端写进去的整条曲目 JSON,
	// 里头混进一条格式异常的记录不该让另外七百多条一起失效。
	tracks := make([]neteaseLocalTrack, 0, len(rows))
	for _, r := range rows {
		var t neteaseLocalTrack
		if err := json.Unmarshal([]byte(r.JSONStr), &t); err != nil {
			continue
		}
		tracks = append(tracks, t)
	}
	return tracks, nil
}

// refreshNeteaseLocalIndexLocked 在库变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 neteaseLocalMu。
func refreshNeteaseLocalIndexLocked(ctx context.Context) {
	path := neteaseLocalDBPath()
	if path == "" {
		neteaseLocalIndex, neteaseLocalReady = nil, true
		return
	}
	st, err := os.Stat(path)
	if err != nil || st.IsDir() {
		// 没装网易云 / 没登录过 / 路径变了 —— 正常情况,静默退回网络解析。
		// 被 TCC 拒了**不是**常态,那一种由 noteLocalCacheDenied 记一行,理由见它的头注。
		noteLocalCacheDenied("netease", path, err)
		neteaseLocalIndex, neteaseLocalReady = nil, true
		return
	}
	// 读到了就撤掉「被拒」—— 授权之后设置页那个提示要能自己消失。
	noteLocalCacheReadable("netease")
	now := time.Now()
	if neteaseLocalReady && st.ModTime().Equal(neteaseLocalDBMod) && st.Size() == neteaseLocalDBSize {
		return
	}
	if neteaseLocalReady && now.Sub(neteaseLocalScanned) < neteaseLocalRescanMin {
		return
	}
	neteaseLocalDBMod, neteaseLocalDBSize = st.ModTime(), st.Size()
	neteaseLocalScanned, neteaseLocalReady = now, true

	tracks, err := queryNeteaseLocalTracks(ctx, path)
	if err != nil {
		// 保留上一次的索引,理由同 qqlocal.go:重建失败是常态化的偶发。
		return
	}
	idx := map[string][]neteaseLocalTrack{}
	for _, t := range tracks {
		if t.ID == 0 || t.Name == "" || len(t.Artists) == 0 {
			continue
		}
		// 多歌手曲目(实测 106 条)每个署名各挂一次:本地标签常只写其中一位,
		// 只按第一个歌手建键会让这些歌全查不到。
		for _, a := range t.Artists {
			key := neteaseLocalKey(a.Name, t.Name)
			if key == "" {
				continue
			}
			idx[key] = append(idx[key], t)
		}
	}
	neteaseLocalIndex = idx
	if len(idx) > 0 {
		log.Printf("netease local: indexed %d tracks from client library", len(idx))
	}
}

// pickNeteaseLocalEntry 在同名同歌手的多条本地记录里挑一条。判据与 pickQQLocalEntry
// 一致:先过时长闸(sourceDurationFits,12% 口径),全过不了就不命中;再专辑优先、时长差最小。
// 本机实测 (歌手+歌名) 重复 13 组,比 QQ 那边多,这道闸更要紧。
func pickNeteaseLocalEntry(entries []neteaseLocalTrack, album string, durationSecs float64) (neteaseLocalTrack, bool) {
	var best neteaseLocalTrack
	var bestScore float64
	found := false
	for _, e := range entries {
		if !sourceDurationFits(durationSecs, e.Duration/1000) {
			continue
		}
		score := 0.0
		if album != "" && e.Album.Name != "" && normLoose(e.Album.Name) == normLoose(album) {
			score += 1000
		}
		if durationSecs > 0 && e.Duration > 0 {
			score -= math.Abs(e.Duration/1000 - durationSecs)
		}
		if !found || score > bestScore {
			best, bestScore, found = e, score, true
		}
	}
	return best, found
}

// neteaseLocalSong 在网易云客户端的本地曲库里找这首歌,命中时返回一条可以直接当作
// pick() 结果用的 neSearchSong。第二个返回值 false = 没命中,调用方照常走搜索。
func neteaseLocalSong(ctx context.Context, artist, title, album string, durationSecs float64) (neSearchSong, bool) {
	key := neteaseLocalKey(artist, title)
	if key == "" {
		// 歌手名缺失时不做"只按歌名"兜底:本机跨歌手同名 23 组,这条路径的价值就是不靠猜。
		return neSearchSong{}, false
	}
	neteaseLocalMu.Lock()
	refreshNeteaseLocalIndexLocked(ctx)
	ents := append([]neteaseLocalTrack(nil), neteaseLocalIndex[key]...)
	neteaseLocalMu.Unlock()
	if len(ents) == 0 {
		return neSearchSong{}, false
	}
	t, ok := pickNeteaseLocalEntry(ents, album, durationSecs)
	if !ok {
		return neSearchSong{}, false
	}
	song := neSearchSong{ID: int64(t.ID), Name: t.Name, Duration: t.Duration}
	song.Album.ID, song.Album.Name = int64(t.Album.ID), t.Album.Name
	for _, a := range t.Artists {
		song.Artists = append(song.Artists, struct {
			Name string `json:"name"`
		}{Name: a.Name})
	}
	// 每首歌最多一行:上游 neteaseLookup 有缓存,不会重复问。这行是"这首歌的 songID 来自
	// 客户端曲库、没走 /api/search"的唯一凭据,同 kugou local / qq local 那两行。
	log.Printf("netease local: hit %q - %q (album %q) → %d", artist, title, song.Album.Name, song.ID)
	return song, true
}

// ---- 播放队列:接下来会播的几首(见 upcoming.go)----

// neteaseUpcomingOverride 让单测把队列文件指到临时路径。空 = 用真实路径。
var neteaseUpcomingOverride string

// neteaseUpcomingMaxBytes 是这份文件的大小上限。实测 552 首 1.29MB,16MB 是防"队列被塞到
// 上万首 / 格式变了"时把内存吃光,不是格式约束。
const neteaseUpcomingMaxBytes = 16 << 20

// neteaseUpcomingPath 是网易云客户端的当前播放列表。
//
// 跟 neteaseLocalDBPath 是两份东西:那个是客户端曲库(sqlite),这个是**此刻的播放队列**
// (明文 JSON,无加密)。
func neteaseUpcomingPath() string {
	if neteaseUpcomingOverride != "" {
		return neteaseUpcomingOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.netease.163music/Data/Documents",
		"storage/file_storage/webdata/file/playingList")
}

// neteaseUpcomingFile 只摘这条路径用得上的字段。每个条目还带着几十个别的(推荐算法标记、
// 版权位、来源页),都不相干。
type neteaseUpcomingFile struct {
	List []struct {
		// DisplayOrder 实测恒等于数组下标,留着只为看得懂文件;顺序以数组为准。
		DisplayOrder int `json:"displayOrder"`
		// RandomOrder 是一个随机大数(实测 6354311200、492958900 这类):随机播放按它**从小到大**放。
		// 实测连续 6 首的名次是 401 → 402 → 403 → 404 → 405 → 406,列表位置却是 96 → 371 → 225 → 549 → 188 → 375。
		RandomOrder float64 `json:"randomOrder"`
		Track       struct {
			Name    string `json:"name"`
			ID      string `json:"id"`
			Artists []struct {
				Name string `json:"name"`
			} `json:"artists"`
			Album struct {
				Name string `json:"name"`
			} `json:"album"`
			Duration int64 `json:"duration"` // 毫秒
		} `json:"track"`
	} `json:"list"`
}

// neteasePlayOrder 记同一份列表里上一次看到的位置,用来从相邻两次换歌推断顺序 / 随机。
//
// 播放模式网易云存在内嵌浏览器的 localStorage 里(playingInfo / setting),值是加密的,读不到。
// 但这份列表同时带着两种顺序:数组顺序(顺序播放)与 randomOrder 从小到大(随机播放),
// 所以看新的一首在哪种顺序里正好是上一首的下一位就知道了。两种都不是(用户手动点了别的歌)
// 就沿用上一次的结论;还没有结论时两种各取一份。
type neteasePlayOrder struct {
	list string // 文件路径 + mtime + 曲目数
	pos  int
	mode neteaseOrderMode
}

type neteaseOrderMode int

const (
	neteaseOrderUnknown neteaseOrderMode = iota
	neteaseOrderList
	neteaseOrderShuffle
)

var (
	neteasePlayOrderMu   sync.Mutex
	neteasePlayOrderLast neteasePlayOrder
)

// neteaseObservePosition 记下这一次的位置,返回此刻按哪种顺序往后数。rank 是 randomOrder 名次。
func neteaseObservePosition(list string, pos int, rank []int) neteaseOrderMode {
	neteasePlayOrderMu.Lock()
	defer neteasePlayOrderMu.Unlock()
	prev := neteasePlayOrderLast
	if prev.list != list {
		neteasePlayOrderLast = neteasePlayOrder{list: list, pos: pos}
		return neteaseOrderUnknown
	}
	mode := prev.mode
	switch {
	case pos == prev.pos:
	case pos == prev.pos+1:
		mode = neteaseOrderList
	case rank[pos] == rank[prev.pos]+1:
		mode = neteaseOrderShuffle
	}
	if mode != prev.mode {
		name := map[neteaseOrderMode]string{neteaseOrderList: "list order", neteaseOrderShuffle: "the shuffle order (randomOrder)"}[mode]
		log.Printf("netease upcoming: position %d to %d follows %s", prev.pos, pos, name)
	}
	neteasePlayOrderLast = neteasePlayOrder{list: list, pos: pos, mode: mode}
	return mode
}

// neteaseUpcoming 从网易云的播放队列文件里取接下来会播的几首。
//
// 这份文件**没有"当前播到第几首"的指针**(顶层只有 list 一个键),而且只在开始播一个列表时写一次,
// 位置只能靠正在播的那首歌反查,查不到就退回同专辑预取。往后按哪种顺序数见 neteasePlayOrder;
// 还判断不出来时两种顺序各取 n 首(去重),多解析几首换两种情况都命中。
func neteaseUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	path := neteaseUpcomingPath()
	if path == "" {
		return nil, false
	}
	st, err := os.Stat(path)
	if err != nil {
		// 没装网易云 / 没播过是常态,静默;被 TCC 拒了不是,那一种要留痕(见 localcachefs.go)。
		noteLocalCacheDenied("netease", path, err)
		return nil, false
	}
	if st.Size() > neteaseUpcomingMaxBytes {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteLocalCacheDenied("netease", path, err)
		return nil, false
	}
	noteLocalCacheReadable("netease")
	var f neteaseUpcomingFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, false
	}
	joinArtists := func(i int) string {
		names := make([]string, 0, len(f.List[i].Track.Artists))
		for _, a := range f.List[i].Track.Artists {
			if a.Name != "" {
				names = append(names, a.Name)
			}
		}
		return strings.Join(names, "/")
	}
	want := loosenEnrichKey(artist + "|" + title)
	pos := -1
	for i := range f.List {
		if loosenEnrichKey(joinArtists(i)+"|"+f.List[i].Track.Name) == want {
			pos = i
			break
		}
	}
	if pos < 0 {
		return nil, false
	}
	// byRandom[k] = randomOrder 第 k 小的那首的下标;rank[i] = 第 i 首的名次。
	byRandom := make([]int, len(f.List))
	for i := range byRandom {
		byRandom[i] = i
	}
	sort.SliceStable(byRandom, func(a, b int) bool { return f.List[byRandom[a]].RandomOrder < f.List[byRandom[b]].RandomOrder })
	rank := make([]int, len(f.List))
	for k, i := range byRandom {
		rank[i] = k
	}
	mode := neteaseObservePosition(fmt.Sprintf("%s/%d/%d", path, st.ModTime().UnixNano(), len(f.List)), pos, rank)

	seen := map[int]bool{}
	res := make([]upcomingTrack, 0, 2*n)
	take := func(indices func(yield func(int) bool)) {
		got := 0
		indices(func(i int) bool {
			if got == n {
				return false
			}
			tr := f.List[i].Track
			if tr.Name == "" || seen[i] {
				return true
			}
			seen[i] = true
			got++
			res = append(res, upcomingTrack{
				artist: joinArtists(i),
				title:  tr.Name,
				album:  tr.Album.Name,
				// 这份文件里的 duration 是毫秒(实测 295732),upcomingTrack 要秒。
				duration: float64(tr.Duration) / 1000,
			})
			return true
		})
	}
	listOrder := func(yield func(int) bool) {
		for i := pos + 1; i < len(f.List) && yield(i); i++ {
		}
	}
	shuffleOrder := func(yield func(int) bool) {
		for k := rank[pos] + 1; k < len(byRandom) && yield(byRandom[k]); k++ {
		}
	}
	switch mode {
	case neteaseOrderList:
		take(listOrder)
	case neteaseOrderShuffle:
		take(shuffleOrder)
	default:
		take(listOrder)
		take(shuffleOrder)
	}
	return res, len(res) > 0
}
