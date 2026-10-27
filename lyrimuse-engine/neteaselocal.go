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
	"slices"
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
// 不限于"正在用网易云播放":dbTrack 收的是客户端见过的歌(歌单、搜索结果都会进),734 行远大于播放历史本身。
// 从搜索结果里点开播放的歌却只进播放历史 `historyTracks`、不进 dbTrack,而开播那一刻就写进播放历史,所以两张表
// 一起读(同一首两张表都有时留 dbTrack 那条)。两张表的 jsonStr 是同一种曲目 JSON。
//
// 全程 fail-soft:没装网易云 / 库打不开 / 表结构变了 / sqlite3 不在,一律当没命中,
// 照常走原来的搜索。

// neteaseLocalDBOverride 让单测把库指到临时路径。空 = 用真实路径。
var neteaseLocalDBOverride string

// neteaseLocalDBPath 是网易云客户端的主数据库。 外部 App 的路径,不走 paths.go 那套;在哪一处见 clientDataRoots。
func neteaseLocalDBPath() string {
	if neteaseLocalDBOverride != "" {
		return neteaseLocalDBOverride
	}
	return neteaseDataRoots().path(neteaseLibraryRel)
}

const neteaseLocalRescanMin = 60 * time.Second

// neteaseLocalMissRescanMin:要查的这首不在索引里、库又变过时,距上次扫描过了这么久就再扫一次,不等 60 秒。客户端点播时
// 才把这首写进播放历史,只按 60 秒节流的话,刚扫过之后点播的歌首轮解析读不到它,封面先用上网易云接口给的专辑图
// (跟客户端自己显示的单曲封面可以不是一张)。见 03 章决策 41。
const neteaseLocalMissRescanMin = 5 * time.Second
const neteaseLocalQueryTimeout = 4 * time.Second
const neteaseLocalMaxRows = 20000

// dbTrack 一行就是一条完整曲目 JSON,列名本身没有语义(`id` + `jsonStr`),所以这里只取
// jsonStr,结构交给 neteaseLocalTrack 解。
const neteaseLocalTracksSQL = "SELECT jsonStr FROM dbTrack WHERE jsonStr <> '' LIMIT 20000"

// neteaseLocalHistorySQL:播放历史表,形状同 dbTrack。老版本客户端没有这张表时查询报错,当作没有,不影响 dbTrack。
const neteaseLocalHistorySQL = "SELECT jsonStr FROM historyTracks WHERE jsonStr <> '' LIMIT 20000"

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
		ID     flexID `json:"id"`
		Name   string `json:"name"`
		PicURL string `json:"picUrl"`
	} `json:"album"`
	Duration float64 `json:"duration"` // 毫秒
	Mark     int64   `json:"mark"`     // 见 neSearchSong.Mark
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

// neteaseLocalRowsRead:一次扫描读到几行,其中几行解得开、带着 id 和歌名。
type neteaseLocalRowsRead struct{ rows, usable int }

// neteaseLocalUsableShare:有行时至少这么多成解得开、带着 id 和歌名,才算认得这份库的格式。实测 1082 行全部解得开;
// 客户端换版改了 jsonStr 的写法时一行都解不开,或者解得开却没有 id、歌名,索引是空的。
const neteaseLocalUsableShare = 0.5

// recognized:读到的行里解得开、带着 id 和歌名的够不够 neteaseLocalUsableShare;一行都没有(新装、清过记录)不算认不出。
func (r neteaseLocalRowsRead) recognized() bool {
	return r.rows == 0 || float64(r.usable) >= neteaseLocalUsableShare*float64(r.rows)
}

// queryNeteaseLocalTracks 读一次 dbTrack,再读播放历史补上 dbTrack 里没有的曲目。dbTrack 读不了就报错;播放历史
// 读不了(老版本没有这张表)只用 dbTrack。read 是两张表合起来读到的行数。
func queryNeteaseLocalTracks(ctx context.Context, dbPath string) ([]neteaseLocalTrack, neteaseLocalRowsRead, error) {
	tracks, read, err := queryNeteaseLocalTable(ctx, dbPath, neteaseLocalTracksSQL)
	if err != nil {
		return nil, read, err
	}
	history, historyRead, err := queryNeteaseLocalTable(ctx, dbPath, neteaseLocalHistorySQL)
	if err != nil {
		return tracks, read, nil
	}
	read.rows += historyRead.rows
	read.usable += historyRead.usable
	seen := make(map[flexID]bool, len(tracks))
	for _, t := range tracks {
		seen[t.ID] = true
	}
	for _, t := range history {
		if t.ID != 0 && !seen[t.ID] {
			seen[t.ID] = true
			tracks = append(tracks, t)
		}
	}
	return tracks, read, nil
}

// queryNeteaseLocalTable 跑一条只取 jsonStr 的查询,read 记读到几行、几行解得开且带着 id 和歌名。mode=ro 的理由同 qqlocal.go:拿一致快照、撞锁
// 就干净失败;该库是 rollback journal 模式(实测 journal_mode=delete,无 -wal/-shm),
// 只读打开不写任何东西,不会干扰客户端。
func queryNeteaseLocalTable(ctx context.Context, dbPath, query string) ([]neteaseLocalTrack, neteaseLocalRowsRead, error) {
	ctx, cancel := context.WithTimeout(ctx, neteaseLocalQueryTimeout)
	defer cancel()
	uri := (&neturl.URL{Scheme: "file", Path: dbPath, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, query).Output()
	if err != nil {
		return nil, neteaseLocalRowsRead{}, err
	}
	trimmed := bytes.TrimSpace(out)
	// 零行时 sqlite3 -json 输出空串而不是 "[]",同 qqlocal.go。
	if len(trimmed) == 0 {
		return nil, neteaseLocalRowsRead{}, nil
	}
	var rows []neteaseLocalRow
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		return nil, neteaseLocalRowsRead{}, err
	}
	if len(rows) > neteaseLocalMaxRows {
		rows = rows[:neteaseLocalMaxRows]
	}
	// 逐行解,单行解不开就跳过而不是整批放弃:jsonStr 是客户端写进去的整条曲目 JSON,
	// 里头混进一条格式异常的记录不该让另外七百多条一起失效。
	read := neteaseLocalRowsRead{rows: len(rows)}
	tracks := make([]neteaseLocalTrack, 0, len(rows))
	for _, r := range rows {
		var t neteaseLocalTrack
		if err := json.Unmarshal([]byte(r.JSONStr), &t); err != nil {
			continue
		}
		if t.ID != 0 && t.Name != "" {
			read.usable++
		}
		tracks = append(tracks, t)
	}
	return tracks, read, nil
}

// refreshNeteaseLocalIndexLocked 在库变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 neteaseLocalMu。
func refreshNeteaseLocalIndexLocked(ctx context.Context) {
	refreshNeteaseLocalIndexAfterLocked(ctx, neteaseLocalRescanMin)
}

// neteaseLocalEntriesLocked:keys 里第一个在索引里有条目的那组。都没有时按 neteaseLocalMissRescanMin 再试一次重扫
// (库没变过照旧不扫)。调用方必须持有 neteaseLocalMu,返回的是拷贝。
func neteaseLocalEntriesLocked(ctx context.Context, keys ...string) []neteaseLocalTrack {
	return neteaseLocalEntriesSettledLocked(ctx, nil, keys...)
}

// neteaseLocalEntriesSettledLocked 同 neteaseLocalEntriesLocked;settled 不空时,查到的那组它不认(同名的只有别的版本)
// 也按 neteaseLocalMissRescanMin 再试一次重扫:客户端点播时才把这一版写进播放历史,同名的另一版早就在索引里。
// 调用方必须持有 neteaseLocalMu。
func neteaseLocalEntriesSettledLocked(ctx context.Context, settled func([]neteaseLocalTrack) bool, keys ...string) []neteaseLocalTrack {
	refreshNeteaseLocalIndexLocked(ctx)
	find := func() []neteaseLocalTrack {
		for _, k := range keys {
			if k != "" && len(neteaseLocalIndex[k]) > 0 {
				return append([]neteaseLocalTrack(nil), neteaseLocalIndex[k]...)
			}
		}
		return nil
	}
	if ents := find(); ents != nil && (settled == nil || settled(ents)) {
		return ents
	}
	refreshNeteaseLocalIndexAfterLocked(ctx, neteaseLocalMissRescanMin)
	return find()
}

// refreshNeteaseLocalIndexAfterLocked:库变过、且距上次扫描超过 minGap 时重建索引。调用方必须持有 neteaseLocalMu。
func refreshNeteaseLocalIndexAfterLocked(ctx context.Context, minGap time.Duration) {
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
	now := time.Now()
	if neteaseLocalReady && st.ModTime().Equal(neteaseLocalDBMod) && st.Size() == neteaseLocalDBSize {
		return
	}
	if neteaseLocalReady && now.Sub(neteaseLocalScanned) < minGap {
		return
	}
	neteaseLocalScanned, neteaseLocalReady = now, true

	tracks, read, err := queryNeteaseLocalTracks(ctx, path)
	if err != nil {
		// 保留上一次的索引,理由同 qqlocal.go:重建失败是常态化的偶发。
		noteLocalCacheReadFailure("netease", path)
		if sqliteSchemaMismatch(err) {
			noteParserUnrecognized("netease-local-library", sqliteErrorDetail(err))
		}
		return
	}
	// 版本读成功才记、真读到才撤掉「被拒」,理由同 qqlocal.go。
	neteaseLocalDBMod, neteaseLocalDBSize = st.ModTime(), st.Size()
	noteLocalCacheReadable("netease")
	// 读得了不等于认得:有行、却大半解不开(或解开了没有 id、歌名)是客户端换了 jsonStr 的写法,索引是空的。
	if read.recognized() {
		noteParserRecognized("netease-local-library")
	} else {
		noteParserUnrecognized("netease-local-library", fmt.Sprintf("%d of %d rows in dbTrack / historyTracks decode with an id and a name", read.usable, read.rows))
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
// 一致:先过 localLibraryEntryFits,全过不了就不命中;再专辑优先、时长差最小。
// 本机实测 (歌手+歌名) 重复 13 组,比 QQ 那边多,这道闸更要紧。
func pickNeteaseLocalEntry(entries []neteaseLocalTrack, album string, durationSecs float64) (neteaseLocalTrack, bool) {
	var best neteaseLocalTrack
	var bestScore float64
	found := false
	for _, e := range entries {
		if !localLibraryEntryFits(album, e.Album.Name, durationSecs, e.Duration/1000) {
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

// neteaseLocalAlbumAgrees:本机曲库一条记录的专辑(entryAlbum)跟这首的专辑(album)对得上,或者有一边不知道。
func neteaseLocalAlbumAgrees(album, entryAlbum string) bool {
	return album == "" || entryAlbum == "" || normLoose(album) == normLoose(entryAlbum)
}

// neteaseLocalEntry 在网易云客户端的本地曲库里挑这首歌的那条记录,不打日志(neteaseLocalSong 命中时才记一行)。
func neteaseLocalEntry(ctx context.Context, artist, title, album string, durationSecs float64) (neteaseLocalTrack, bool) {
	return neteaseLocalEntryKeeping(ctx, artist, title, album, durationSecs, nil)
}

// neteaseLocalEntryKeeping:同 neteaseLocalEntry,keep 不空时按歌名挑的那几条只在它认的里头挑。
//
// 网易云在放这首时(neteaseLocalPlayingTrack)不按歌名挑:播放队列报了这一版的歌曲 id,按 id 在索引里取;索引里还没有
// (刚点播、还没写进播放历史,或者在 60 秒节流里)就用队列里这一条,它跟曲库是同一种曲目 JSON。同名的另一版不拿来顶。
// 不在放时按歌名挑(pickNeteaseLocalEntry);挑出来的专辑对不上、或一条都不认时按 neteaseLocalMissRescanMin 再试一次重扫,
// 刚写进播放历史的这一版不用等 60 秒。见 03 章决策 63。
func neteaseLocalEntryKeeping(ctx context.Context, artist, title, album string, durationSecs float64,
	keep func(neteaseLocalTrack) bool) (neteaseLocalTrack, bool) {
	key := neteaseLocalKey(artist, title)
	if key == "" {
		// 歌手名缺失时不做"只按歌名"兜底:本机跨歌手同名 23 组,这条路径的价值就是不靠猜。
		return neteaseLocalTrack{}, false
	}
	if playing, ok := neteaseLocalPlayingTrack(ctx, artist, title, album, durationSecs); ok {
		neteaseLocalMu.Lock()
		refreshNeteaseLocalIndexLocked(ctx)
		ents := neteaseLocalIndex[key]
		if i := slices.IndexFunc(ents, func(t neteaseLocalTrack) bool { return t.ID == playing.ID }); i >= 0 {
			playing = ents[i]
		}
		neteaseLocalMu.Unlock()
		return playing, true
	}
	candidates := func(ents []neteaseLocalTrack) []neteaseLocalTrack {
		if keep == nil {
			return ents
		}
		return slices.DeleteFunc(slices.Clone(ents), func(t neteaseLocalTrack) bool { return !keep(t) })
	}
	neteaseLocalMu.Lock()
	ents := neteaseLocalEntriesSettledLocked(ctx, func(ents []neteaseLocalTrack) bool {
		t, ok := pickNeteaseLocalEntry(candidates(ents), album, durationSecs)
		return ok && neteaseLocalAlbumAgrees(album, t.Album.Name)
	}, key)
	neteaseLocalMu.Unlock()
	if len(ents) == 0 {
		return neteaseLocalTrack{}, false
	}
	return pickNeteaseLocalEntry(candidates(ents), album, durationSecs)
}

// neteaseLocalPlayingTrack:网易云在放、这次解析的是它在放的这首或它的待播队列(playerSignalApplies,不是别的歌那一轮)时,
// 播放队列里的这一条(neteasePlayingTrack);别的情形 ok=false。
func neteaseLocalPlayingTrack(ctx context.Context, artist, title, album string, durationSecs float64) (neteaseLocalTrack, bool) {
	if playingPlayer() != playerNetease || !playerSignalApplies(ctx) || isOtherTrackRound(ctx) {
		return neteaseLocalTrack{}, false
	}
	return neteasePlayingTrack(artist, title, album, durationSecs)
}

// neteaseLocalSong 在网易云客户端的本地曲库里找这首歌,命中时返回一条可以直接当作
// pick() 结果用的 neSearchSong。第二个返回值 false = 没命中,调用方照常走搜索。
func neteaseLocalSong(ctx context.Context, artist, title, album string, durationSecs float64) (neSearchSong, bool) {
	t, ok := neteaseLocalEntry(ctx, artist, title, album, durationSecs)
	if !ok {
		return neSearchSong{}, false
	}
	song := neSearchSong{ID: int64(t.ID), Name: t.Name, Duration: t.Duration, Mark: t.Mark}
	song.Album.ID, song.Album.Name = int64(t.Album.ID), t.Album.Name
	// 封面用客户端给这首记的那张:它是这首的单曲封面,客户端播放页显示的就是它;专辑自己的封面(picId 算出来的那张)
	// 偶尔是另一张图。
	song.Album.PicURL = neteaseHTTPSImage(t.Album.PicURL)
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
	return neteaseDataRoots().path(neteaseQueueRel)
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
		// ResourceType 是 track(歌)、voice / downloadVoice / localVoice(播客单集)等。单集不预取:没有歌词。
		ResourceType string `json:"resourceType"`
		Track        struct {
			Name    string `json:"name"`
			ID      string `json:"id"`
			Artists []struct {
				Name string `json:"name"`
			} `json:"artists"`
			Album struct {
				Name string `json:"name"`
				// ID 原样收下再取数字(rawDigitsID):实测是字符串,形状变了也不能让整份队列解不开。
				ID     json.RawMessage `json:"id"`
				PicURL string          `json:"picUrl"`
			} `json:"album"`
			Duration int64 `json:"duration"` // 毫秒
			Mark     int64 `json:"mark"`     // 见 neSearchSong.Mark
		} `json:"track"`
	} `json:"list"`
}

// neteaseVoiceTypes 是队列条目里的播客单集。App 认出在放单集时不报(02 章决策 114),预取也跳过它们。
var neteaseVoiceTypes = map[string]bool{"voice": true, "downloadVoice": true, "localVoice": true}

// neteasePlayOrder 记同一份列表里上一次看到的位置,用来从相邻两次换歌推断顺序 / 随机。
//
// 播放模式网易云存在内嵌浏览器的 localStorage 里(playingInfo / setting),值是加密的,读不到。
// 但这份列表同时带着两种顺序:数组顺序(顺序播放)与 randomOrder 从小到大(随机播放),
// 所以看新的一首在哪种顺序里正好是上一首的下一位就知道了。两种都不是(用户手动点了别的歌)
// 就沿用上一次的结论;还没有结论时两种各取一份。
//
// 「下一首播放」把歌插在当前这首后面,整份重写这份文件,还把每一首的 randomOrder 重新随机一遍。重写后的文件
// 含有上一份的全部曲目、又多出几首时,当作同一份列表加了歌,结论和起算位置(按曲目 id 换算)接着用。紧跟当前这首
// 连成一段的新歌记进 inserted:插进来的歌排在最前面先放,换到它们时不拿来判顺序,往后数也从上一首不是插进来的歌
// (anchor)起算、跳过它们。别处多出来的(「添加到播放列表」「更多推荐」追加在末尾)是普通的列表成员。
// 见 09 章决策 224、229。
type neteasePlayOrder struct {
	path     string
	list     string // 文件路径 + mtime + 曲目数
	ids      []string
	anchor   int // 上一首不是插进来的当前曲目在 ids 里的下标
	mode     neteaseOrderMode
	inserted map[string]bool
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

// neteaseObservePosition 记下这一次的位置,返回此刻按哪种顺序往后数、从哪一首起算,以及哪些曲目是插进来的。
// rank 是 randomOrder 名次。
func neteaseObservePosition(path, list string, ids []string, pos int, rank []int) (neteaseOrderMode, int, map[string]bool) {
	neteasePlayOrderMu.Lock()
	defer neteasePlayOrderMu.Unlock()
	prev := neteasePlayOrderLast
	anchor := -1
	var inserted map[string]bool
	switch {
	case prev.list == list:
		anchor, inserted = prev.anchor, prev.inserted
	case prev.path == path && neteaseQueueGrew(prev.ids, ids):
		if prev.anchor >= 0 && prev.anchor < len(prev.ids) {
			anchor = slices.Index(ids, prev.ids[prev.anchor])
		}
		old := make(map[string]bool, len(prev.ids))
		for _, id := range prev.ids {
			old[id] = true
		}
		inserted = make(map[string]bool, len(prev.inserted)+1)
		for id := range prev.inserted {
			inserted[id] = true
		}
		for i := pos + 1; i < len(ids) && ids[i] != "" && (!old[ids[i]] || inserted[ids[i]]); i++ {
			inserted[ids[i]] = true
		}
	default:
		neteasePlayOrderLast = neteasePlayOrder{path: path, list: list, ids: ids, anchor: pos}
		return neteaseOrderUnknown, pos, nil
	}
	mode := prev.mode
	if inserted[ids[pos]] {
		if anchor < 0 {
			anchor = pos
		}
	} else {
		from := anchor
		if from >= 0 && from != pos {
			switch pos {
			case neteaseNextInList(ids, inserted, from):
				mode = neteaseOrderList
			case neteaseNextInShuffle(ids, inserted, rank, from):
				mode = neteaseOrderShuffle
			}
		}
		if mode != prev.mode {
			name := map[neteaseOrderMode]string{neteaseOrderList: "list order", neteaseOrderShuffle: "the shuffle order (randomOrder)"}[mode]
			log.Printf("netease upcoming: position %d to %d follows %s", from, pos, name)
		}
		// 换到了一首不是插进来的歌:插进来的那段已经放过去了。还是同一首(放到一半插了歌)时留着。
		if from != pos {
			inserted = nil
		}
		anchor = pos
	}
	neteasePlayOrderLast = neteasePlayOrder{path: path, list: list, ids: ids, anchor: anchor, mode: mode, inserted: inserted}
	return mode, anchor, inserted
}

// neteaseQueueGrew:after 含有 before 的全部曲目,而且多出了几首(「下一首播放」/「添加到播放列表」重写之后的样子)。
func neteaseQueueGrew(before, after []string) bool {
	if len(before) == 0 || len(after) <= len(before) {
		return false
	}
	have := make(map[string]bool, len(after))
	for _, id := range after {
		have[id] = true
	}
	for _, id := range before {
		if !have[id] {
			return false
		}
	}
	return true
}

// neteaseNextInList 是数组顺序里 from 之后第一首不是插进来的,数到末尾接回开头;除了 from 没有别的返回 -1。
//
// 「列表循环」放完最后一首接回第一首,「顺序播放」放完停下。模式读不到,一律按接回开头数:顺序播放时多解析的那几首
// 用不上,列表循环时才不会在最后一首断掉。见 09 章决策 226。
func neteaseNextInList(ids []string, inserted map[string]bool, from int) int {
	for k := 1; k < len(ids); k++ {
		if i := (from + k) % len(ids); !inserted[ids[i]] {
			return i
		}
	}
	return -1
}

// neteaseNextInShuffle 是随机顺序(randomOrder 名次)里 from 之后第一首不是插进来的,名次排到最后时接回名次最小的那首
// (客户端只在切到随机播放时重新洗牌,接回去还是这一套名次);除了 from 没有别的返回 -1。
func neteaseNextInShuffle(ids []string, inserted map[string]bool, rank []int, from int) int {
	best, first := -1, -1
	for i := range ids {
		if i == from || inserted[ids[i]] {
			continue
		}
		if rank[i] > rank[from] && (best < 0 || rank[i] < rank[best]) {
			best = i
		}
		if first < 0 || rank[i] < rank[first] {
			first = i
		}
	}
	if best < 0 {
		return first
	}
	return best
}

// neteaseUpcoming 从网易云的播放队列文件里取接下来会播的几首。
//
// 这份文件**没有"当前播到第几首"的指针**(顶层只有 list 一个键),而且只在开始播一个列表时写一次,
// 位置只能靠正在播的那首歌反查,查不到就退回同专辑预取。往后按哪种顺序数见 neteasePlayOrder;
// 还判断不出来时两种顺序各取 n 首(去重),多解析几首换两种情况都命中。
// neteaseQueueAt:读网易云的播放队列文件,按歌名歌手找到此刻在放的这首(queueCurrentIndex)。读不了、解不开时 f 是空的;
// 队列里没有这首时 pos 为 -1。neteaseUpcoming、neteasePlayingSong 共用。
func neteaseQueueAt(artist, title string) (f neteaseUpcomingFile, path string, st os.FileInfo, pos int) {
	pos = -1
	path = neteaseUpcomingPath()
	if path == "" {
		return
	}
	st, err := os.Stat(path)
	if err != nil {
		// 没装网易云 / 没播过是常态,静默;被 TCC 拒了不是,那一种要留痕(见 localcachefs.go)。
		noteLocalCacheDenied("netease", path, err)
		return
	}
	if st.Size() > neteaseUpcomingMaxBytes {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteLocalCacheDenied("netease", path, err)
		return
	}
	noteLocalCacheReadable("netease")
	if err := json.Unmarshal(raw, &f); err != nil {
		noteParserUnrecognized("netease-playing-list", err.Error())
		return neteaseUpcomingFile{}, path, st, -1
	}
	noteParserRecognized("netease-playing-list")
	m := newQueueCurrentMatcher(artist, title)
	pos = queueCurrentIndex(len(f.List), -1, func(i int) queueMatch {
		return m.match(neteaseQueueArtists(f, i), f.List[i].Track.Name)
	})
	return f, path, st, pos
}

// neteaseQueueArtists:队列第 i 首的署名,多位歌手用 "/" 连起来。
func neteaseQueueArtists(f neteaseUpcomingFile, i int) string {
	names := make([]string, 0, len(f.List[i].Track.Artists))
	for _, a := range f.List[i].Track.Artists {
		if a.Name != "" {
			names = append(names, a.Name)
		}
	}
	return strings.Join(names, "/")
}

// neteasePlayingSong:网易云播放队列里此刻在放的这首的歌曲 id 与所在专辑的 id(播放器自己报的这一首,18 章决策 65、67)。
// 两边时长都知道时要对得上;认不出返回空串。
func neteasePlayingSong(artist, title string, durationSecs float64) (id, albumID string) {
	f, _, _, pos := neteaseQueueAt(artist, title)
	if pos < 0 {
		return "", ""
	}
	tr := f.List[pos].Track
	if dur := float64(tr.Duration) / 1000; dur > 0 && durationSecs > 0 && !sourceDurationFits(durationSecs, dur) {
		return "", ""
	}
	return strings.TrimSpace(tr.ID), rawDigitsID(tr.Album.ID)
}

// neteasePlayingTrack:网易云播放队列里此刻在放的这首,换成本机曲库那种形状(neteaseLocalTrack:id、歌名、署名、专辑 id /
// 名字 / 封面、时长、mark)。认法同 neteasePlayingSong;两边专辑都知道又对不上时也不认(队列里同名的另一版排在前面)。
// 认不出、单集、id 不是数字时 ok=false。
func neteasePlayingTrack(artist, title, album string, durationSecs float64) (neteaseLocalTrack, bool) {
	f, _, _, pos := neteaseQueueAt(artist, title)
	if pos < 0 || neteaseVoiceTypes[f.List[pos].ResourceType] {
		return neteaseLocalTrack{}, false
	}
	tr := f.List[pos].Track
	if dur := float64(tr.Duration) / 1000; dur > 0 && durationSecs > 0 && !sourceDurationFits(durationSecs, dur) {
		return neteaseLocalTrack{}, false
	}
	if !neteaseLocalAlbumAgrees(album, tr.Album.Name) {
		return neteaseLocalTrack{}, false
	}
	id, err := strconv.ParseInt(strings.TrimSpace(tr.ID), 10, 64)
	if err != nil || id <= 0 || tr.Name == "" {
		return neteaseLocalTrack{}, false
	}
	t := neteaseLocalTrack{ID: flexID(id), Name: tr.Name, Duration: float64(tr.Duration), Mark: tr.Mark}
	if albumID, err := strconv.ParseInt(rawDigitsID(tr.Album.ID), 10, 64); err == nil {
		t.Album.ID = flexID(albumID)
	}
	t.Album.Name, t.Album.PicURL = tr.Album.Name, tr.Album.PicURL
	for _, a := range tr.Artists {
		t.Artists = append(t.Artists, struct {
			Name string `json:"name"`
		}{Name: a.Name})
	}
	return t, true
}

func neteaseUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	f, path, st, pos := neteaseQueueAt(artist, title)
	if len(f.List) == 0 {
		return nil, false
	}
	joinArtists := func(i int) string { return neteaseQueueArtists(f, i) }
	if pos < 0 {
		log.Printf("netease upcoming: %q - %q is not in the client's queue (%d tracks)", artist, title, len(f.List))
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
	ids := make([]string, len(f.List))
	for i := range f.List {
		ids[i] = f.List[i].Track.ID
	}
	mode, anchor, inserted := neteaseObservePosition(path, fmt.Sprintf("%s/%d/%d", path, st.ModTime().UnixNano(), len(f.List)), ids, pos, rank)

	seen := map[int]bool{}
	res := make([]upcomingTrack, 0, 2*n)
	take := func(indices func(yield func(int) bool)) {
		got := 0
		indices(func(i int) bool {
			if got == n {
				return false
			}
			tr := f.List[i].Track
			if tr.Name == "" || seen[i] || neteaseVoiceTypes[f.List[i].ResourceType] {
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
	// 两种顺序都绕圈:数回 anchor 就停。anchor 是插进来的歌时圈里没有它,靠步数封顶。
	walk := func(next func(int) int) func(yield func(int) bool) {
		return func(yield func(int) bool) {
			for i, k := next(anchor), 0; i >= 0 && i != anchor && k < len(ids) && yield(i); i, k = next(i), k+1 {
			}
		}
	}
	listOrder := walk(func(i int) int { return neteaseNextInList(ids, inserted, i) })
	shuffleOrder := walk(func(i int) int { return neteaseNextInShuffle(ids, inserted, rank, i) })
	// 插进来的歌连成一段排在当前这首后面,不管顺序还是随机都先放它们。
	insertedNext := func(yield func(int) bool) {
		for i := pos + 1; i < len(f.List) && inserted[ids[i]] && yield(i); i++ {
		}
	}
	take(insertedNext)
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
