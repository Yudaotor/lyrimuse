package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"io"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

// KKBOX 的「接下来会播哪几首」。
//
// KKBOX 是 Electron 应用,界面是跑在本机 localhost 上的网页。打乱之后的播放顺序只在网页的内存里,不落盘;落盘的是
// 两样东西,拼起来够用:
//   - Local Storage(LevelDB):`wp:pref:<账号>:now_playing` 是播放上下文
//     `kkbox:<类型>:<id>:<序号>:<?>?track=<曲目 id>`,`…:is_shuffle` 是随机开关;
//   - Chromium 的 HTTP 磁盘缓存:打开那个歌单 / 专辑时拉的接口响应
//     (`api-webapps.kkbox.*/v2/tracks-set|albums|playlists/<id>`,gzip 过的 JSON),里面是整份曲目表。
// 顺序播放取当前这首后面几首;随机播放下一首猜不出来,按 shuffleCandidates 的规则交一批(见 queueorder.go)。
//
// 歌手名必须跟 KKBOX 报给系统的**逐字一致**,不然预解析写进缓存的 key 对不上、白解析一遍(内置之前退回同专辑预取,
// 按 Apple 目录的「Taylor Swift」解析了一批,KKBOX 报的却是「Taylor Swift (泰勒絲)」,一条都没用上)。KKBOX 前端
// (ArtistNameHelper)的规则:有 artist_roles 就是 main_artists + featured_artists 用 ", " 连起来,没有才用
// artist.name。同一个歌手的 roles 写法因曲而异(「Taylor Swift」「Taylor Swift (泰勒絲)」「周杰倫」都有),所以
// 每首歌都得拿到它自己的 roles:歌单 / 歌曲集接口里的曲目自带;专辑接口里的曲目只有 id 和歌名,KKBOX 开播专辑时另拉一次
// 批量详情(`/v2/tracks/?ids=…`),播放器报的就是那里的 roles —— 专辑歌手是「周杰倫 (Jay Chou)」,详情里是「周杰倫」。
//
// 只读:LevelDB 不开库、不抢锁(同 leveldbread.go),缓存文件读不动就当没有。Local Storage 的键名里带着账号(邮箱),
// 日志一律不打键名,也不打缓存地址(查询串里有设备 id)。

var (
	kkboxLocalStorageOverride string // 单测指到临时目录;空 = 真实路径
	kkboxCacheDirOverride     string
)

func kkboxSupportPath(rel string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Application Support/KKBOX", rel)
}

func kkboxLocalStorageDir() string {
	if kkboxLocalStorageOverride != "" {
		return kkboxLocalStorageOverride
	}
	return kkboxSupportPath("Local Storage/leveldb")
}

func kkboxCacheDir() string {
	if kkboxCacheDirOverride != "" {
		return kkboxCacheDirOverride
	}
	return kkboxSupportPath("Cache/Cache_Data")
}

// kkboxContextEndpoints:播放上下文的类型 → 接口路径里的那一段。KKBOX 前端恢复上次播放时认五种(restoreLastPlay):
// album / online-playlist / song-list / my-library / track,这里接实测过的三种;收藏库和单曲还没找到曲目表落在哪,
// 退回同专辑预取。上下文串里的类型跟接口路径不同名:歌单是 online-playlist,接口是 playlists。
//
// song-list 还有一种不在 tracks-set 下面:专辑 / 歌单放完之后 KKBOX 自动续播的「XX 合輯」,上下文 id 是它开播那首歌时
// 拉的 `/v2/related-tracks/<那首歌>` 响应里的 data.id(见 kkboxCache.relatedTrackList)。
var kkboxContextEndpoints = map[string]string{
	"song-list":       "tracks-set",
	"album":           "albums",
	"online-playlist": "playlists",
}

// kkboxUpcomingLogged:同一个上下文、同一个失败原因只记一次,换歌不刷屏。
var (
	kkboxUpcomingLogMu  sync.Mutex
	kkboxUpcomingLogged string
)

func kkboxUpcomingNote(key, format string, args ...any) {
	kkboxUpcomingLogMu.Lock()
	defer kkboxUpcomingLogMu.Unlock()
	if kkboxUpcomingLogged == key {
		return
	}
	kkboxUpcomingLogged = key
	log.Printf(format, args...)
}

// kkboxUpcomingRetryDelays:上下文里的列表还没有这首(换了列表、还没落盘)时隔多久重读。Chromium 的 Local Storage
// 攒一会儿才落盘(实测 1 秒到十几秒不等,见 kkboxCurrentPosition);逐次隔 1 / 2 / 2 / 3 / 4 秒,最多等 12 秒(预解析本来就
// 在后台 goroutine 里,用户听一首歌远不止这么久)。单测设成 0。
var kkboxUpcomingRetryDelays = []time.Duration{time.Second, 2 * time.Second, 2 * time.Second, 3 * time.Second, 4 * time.Second}

// kkboxUpcomingBeforeRetry:单测在重读之前改盘上的数据用;平时是 nil。
var kkboxUpcomingBeforeRetry func()

func kkboxUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	for attempt := 0; ; attempt++ {
		tracks, ok, retry := kkboxUpcomingOnce(artist, title, n)
		if retry == "" {
			return tracks, ok
		}
		if attempt >= len(kkboxUpcomingRetryDelays) {
			kkboxUpcomingNote("retry:"+retry, "kkbox upcoming: %s after waiting for the app to save it; falling back to album prefetch", retry)
			return nil, false
		}
		time.Sleep(kkboxUpcomingRetryDelays[attempt])
		if kkboxUpcomingBeforeRetry != nil {
			kkboxUpcomingBeforeRetry()
		}
	}
}

// kkboxUpcomingOnce 读一次。retry 非空 = 上下文里的列表还没有播放器报的这首(换了列表、还没落盘),值得隔一会儿再读;
// 内容是给日志的原因。
func kkboxUpcomingOnce(artist, title string, n int) (tracks []upcomingTrack, ok bool, retry string) {
	pb, ok := kkboxReadPlayback(kkboxLocalStorageDir())
	if !ok {
		return nil, false, ""
	}
	ctx, ok := parseKKBOXContext(pb.context)
	if !ok {
		return nil, false, ""
	}
	endpoint, ok := kkboxContextEndpoints[ctx.kind]
	if !ok {
		kkboxUpcomingNote("kind:"+ctx.kind, "kkbox upcoming: playing from a %q context, which has no cached track list; falling back to album prefetch", ctx.kind)
		return nil, false, ""
	}
	cache := scanKKBOXCache(kkboxCacheDir())
	list, ok := cache.trackList("/v2/" + endpoint + "/" + ctx.id)
	if !ok && ctx.kind == "song-list" {
		list, ok = cache.relatedTrackList(ctx.id)
	}
	var all []upcomingTrack
	var ids []string
	pos := -1
	if ok {
		all, ids = list.upcoming(cache.trackDetails(list.idsWithoutArtist()))
		pos = kkboxCurrentPosition(all, ids, ctx.track, artist, title)
	}
	if pos < 0 {
		// 换了列表、上下文还没落盘(见 kkboxCurrentPosition):KKBOX 打开新列表时刚拉过它的曲目表,按写入时间
		// 找最近几份里有这首的那份。
		all, pos = cache.newestListWith(artist, title)
	}
	if pos < 0 {
		// 新列表的曲目表可能也还没写进缓存:值得再读一次。
		return nil, false, "neither the saved " + ctx.kind + " nor a recently cached track list has the current track"
	}
	cur := all[pos]
	if loosenEnrichKey(cur.artist) != loosenEnrichKey(artist) {
		// 歌手名拼法跟 KKBOX 报的对不上,照这个拼法预解析就是白解析(见文件头注)。重读也不会变。
		kkboxUpcomingNote("artist:"+ctx.id, "kkbox upcoming: the track list names the artist %q but the player reports %q; falling back to album prefetch", cur.artist, artist)
		return nil, false, ""
	}
	if pb.shuffle {
		return shuffleCandidates(len(all), pos, func(i int) (upcomingTrack, bool) { return all[i], true }), true, ""
	}
	if pos+1 >= len(all) {
		return nil, false, ""
	}
	return all[pos+1 : min(pos+1+n, len(all))], true, ""
}

// kkboxCurrentPosition 找播放器报的这首在曲目表里的位置;找不到返回 -1。
//
// 上下文里记着的曲目 id 只当提示:Chromium 的 Local Storage 攒一会儿才落盘,切得勤时「当前是哪首」能晚十几秒以上
// (实测换歌后 1.2 秒还是上一首、3.7 秒已是这一首,也有等 12 秒还停在上一首的)。列表本身换得少,所以 id 指的那首歌名对不上时,
// 在同一份列表里按歌名找;同名的不止一首时要歌手也对上的那首,都对不上就取第一首(交给调用方的歌手校验去拒)。
// 列表里压根没有这首 = 换了列表、上下文还没落盘,调用方隔一会儿重读。
func kkboxCurrentPosition(all []upcomingTrack, ids []string, trackID, artist, title string) int {
	wantTitle := loosenEnrichKey(title)
	for i, id := range ids {
		if id == trackID && loosenEnrichKey(all[i].title) == wantTitle {
			return i
		}
	}
	wantArtist := loosenEnrichKey(artist)
	first := -1
	for i, t := range all {
		if loosenEnrichKey(t.title) != wantTitle {
			continue
		}
		if loosenEnrichKey(t.artist) == wantArtist {
			return i
		}
		if first < 0 {
			first = i
		}
	}
	return first
}

// ---- Local Storage ----

type kkboxPlayback struct {
	context string
	shuffle bool
}

// kkboxPrefPrefix 是 Local Storage key 里「源」之后的那一段:`_<源>\x00\x01wp:pref:<账号>:<名字>`。
var kkboxPrefPrefix = []byte("\x00\x01wp:pref:")

// kkboxPrefKey 拆出账号与名字;不是 wp:pref 的 key 返回 ok=false。
func kkboxPrefKey(k []byte) (account, name string, ok bool) {
	i := bytes.Index(k, kkboxPrefPrefix)
	if i < 0 {
		return "", "", false
	}
	rest := string(k[i+len(kkboxPrefPrefix):])
	j := strings.LastIndexByte(rest, ':')
	if j <= 0 {
		return "", "", false
	}
	return rest[:j], rest[j+1:], true
}

// kkboxReadPlayback 读播放上下文与随机开关。登录过的账号各有一份,取 now_playing 最后写的那个账号。
func kkboxReadPlayback(dir string) (kkboxPlayback, bool) {
	vals := ldbScan(dir, func(k []byte) bool {
		_, name, ok := kkboxPrefKey(k)
		return ok && (name == "now_playing" || name == "is_shuffle")
	})
	type account struct {
		context string
		seq     uint64
		shuffle bool
	}
	accounts := map[string]*account{}
	for k, v := range vals {
		acct, name, _ := kkboxPrefKey([]byte(k))
		text, ok := chromiumLocalStorageString(v.value)
		if !ok {
			continue
		}
		a := accounts[acct]
		if a == nil {
			a = &account{}
			accounts[acct] = a
		}
		switch name {
		case "now_playing":
			var ctx string
			if json.Unmarshal([]byte(text), &ctx) == nil {
				a.context, a.seq = ctx, v.seq
			}
		case "is_shuffle":
			a.shuffle = strings.TrimSpace(text) == "true"
		}
	}
	var best *account
	for _, a := range accounts {
		if a.context == "" || a.context == "kkbox:void" {
			continue
		}
		if best == nil || a.seq > best.seq {
			best = a
		}
	}
	if best == nil {
		return kkboxPlayback{}, false
	}
	return kkboxPlayback{context: best.context, shuffle: best.shuffle}, true
}

// chromiumLocalStorageString 解 Chromium Local Storage 的值:首字节 0 = 其后是 UTF-16LE,1 = Latin-1。
func chromiumLocalStorageString(v []byte) (string, bool) {
	if len(v) == 0 {
		return "", false
	}
	b := v[1:]
	switch v[0] {
	case 0:
		if len(b)%2 != 0 {
			return "", false
		}
		u := make([]uint16, len(b)/2)
		for i := range u {
			u[i] = binary.LittleEndian.Uint16(b[2*i:])
		}
		return string(utf16.Decode(u)), true
	case 1:
		r := make([]rune, len(b))
		for i, c := range b {
			r[i] = rune(c)
		}
		return string(r), true
	}
	return "", false
}

// kkboxContext 是 now_playing 那一串拆开的样子。
type kkboxContext struct {
	kind, id, track string
}

// parseKKBOXContext 拆 `kkbox:<类型>:<id>:<序号>:<?>?track=<曲目 id>`。序号那两段用不上:随机时它是当前这首在原
// 列表里的位置,说不出下一首是谁。
func parseKKBOXContext(s string) (kkboxContext, bool) {
	rest, ok := strings.CutPrefix(s, "kkbox:")
	if !ok {
		return kkboxContext{}, false
	}
	base, query, _ := strings.Cut(rest, "?")
	parts := strings.Split(base, ":")
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return kkboxContext{}, false
	}
	q, err := url.ParseQuery(query)
	if err != nil || q.Get("track") == "" {
		return kkboxContext{}, false
	}
	return kkboxContext{kind: parts[0], id: parts[1], track: q.Get("track")}, true
}

// ---- 曲目表 ----

type kkboxArtist struct {
	Name string `json:"name"`
}

type kkboxTrack struct {
	ID          string       `json:"id"`
	Name        string       `json:"name"`
	Artist      *kkboxArtist `json:"artist"`
	ArtistRoles *struct {
		Main     []kkboxArtist `json:"main_artists"`
		Featured []kkboxArtist `json:"featured_artists"`
	} `json:"artist_roles"`
	Album *struct {
		Name string `json:"name"`
	} `json:"album"`
	DurationMs float64 `json:"duration_ms"`
}

// hasOwnArtist:曲目表里这一条自己带着歌手(歌单、歌曲集、自动续播都带;专辑接口的不带)。
func (t kkboxTrack) hasOwnArtist() bool {
	return t.Artist != nil || t.ArtistRoles != nil
}

type kkboxTrackList struct {
	Data struct {
		ID     string       `json:"id"`     // 自动续播:上下文 id
		Name   string       `json:"name"`   // 专辑接口:专辑名
		Artist *kkboxArtist `json:"artist"` // 专辑接口:专辑歌手
		Tracks []kkboxTrack `json:"tracks"`
	} `json:"data"`
}

// kkboxArtistName 照抄 KKBOX 前端 ArtistNameHelper:有 artist_roles 就 main_artists(没有这个字段才退回 artist.name)
// 加 featured_artists,用 ", " 连起来;没有 artist_roles 就是 artist.name。fallback 是曲目自己没有 artist 时的
// 专辑歌手(专辑接口)。
func kkboxArtistName(t kkboxTrack, fallback string) string {
	base := fallback
	if t.Artist != nil {
		base = t.Artist.Name
	}
	if t.ArtistRoles == nil {
		return base
	}
	var names []string
	if t.ArtistRoles.Main != nil {
		for _, a := range t.ArtistRoles.Main {
			names = append(names, a.Name)
		}
	} else {
		names = append(names, base)
	}
	for _, a := range t.ArtistRoles.Featured {
		names = append(names, a.Name)
	}
	return strings.Join(names, ", ")
}

// parseKKBOXTrackList 解一份曲目表接口响应;没有曲目算没拿到。
func parseKKBOXTrackList(body []byte) (kkboxTrackList, bool) {
	var r kkboxTrackList
	if json.Unmarshal(body, &r) != nil || len(r.Data.Tracks) == 0 {
		return kkboxTrackList{}, false
	}
	return r, true
}

// idsWithoutArtist:自己不带歌手、要去批量详情里找的那些曲目。
func (l kkboxTrackList) idsWithoutArtist() []string {
	var ids []string
	for _, t := range l.Data.Tracks {
		if !t.hasOwnArtist() {
			ids = append(ids, t.ID)
		}
	}
	return ids
}

// upcoming 换成预解析用的曲目表,ids 与之一一对应。自己不带歌手的曲目用 details(批量详情)里的那条;详情里也没有的
// 退回专辑歌手 —— 跟 KKBOX 报的未必一致,当前这首对不上时由调用方退回同专辑预取。
func (l kkboxTrackList) upcoming(details map[string]kkboxTrack) ([]upcomingTrack, []string) {
	albumArtist := ""
	if l.Data.Artist != nil {
		albumArtist = l.Data.Artist.Name
	}
	tracks := make([]upcomingTrack, 0, len(l.Data.Tracks))
	ids := make([]string, 0, len(l.Data.Tracks))
	for _, t := range l.Data.Tracks {
		if !t.hasOwnArtist() {
			if d, ok := details[t.ID]; ok && d.hasOwnArtist() {
				t = d
			}
		}
		album := l.Data.Name
		if t.Album != nil && t.Album.Name != "" {
			album = t.Album.Name
		}
		tracks = append(tracks, upcomingTrack{
			artist: kkboxArtistName(t, albumArtist), title: t.Name, album: album, duration: t.DurationMs / 1000,
		})
		ids = append(ids, t.ID)
	}
	return tracks, ids
}

// ---- Chromium 磁盘缓存 ----

// Chromium「simple cache」的一个条目文件(`<hash>_0`):24 字节头(魔数 8 + 版本 4 + key 长度 4 + key 哈希 4,
// 再补 4 字节对齐)、key(`1/0/<地址>`,带网络隔离时前面还有两段站点,地址总在最后)、紧接着是响应正文(原样存的,
// 这里是 gzip),正文以一个 EOF 记录收尾,之后才是响应头。
const (
	chromiumSimpleCacheMagic      = 0xfcfb6d1ba7725c30
	chromiumSimpleCacheEOFMagic   = 0xf4fa6f45970d41d8
	chromiumSimpleCacheHeaderSize = 24
	// kkboxCacheEntryMaxBytes:单个缓存条目的读入上限。歌单接口实测几 KB 到几十 KB。
	kkboxCacheEntryMaxBytes = 16 << 20
)

// chromiumCacheEntryKey 从条目文件开头取 key。
func chromiumCacheEntryKey(data []byte) (string, bool) {
	if len(data) < chromiumSimpleCacheHeaderSize || binary.LittleEndian.Uint64(data) != chromiumSimpleCacheMagic {
		return "", false
	}
	n := int(binary.LittleEndian.Uint32(data[12:]))
	if n <= 0 || chromiumSimpleCacheHeaderSize+n > len(data) {
		return "", false
	}
	return string(data[chromiumSimpleCacheHeaderSize : chromiumSimpleCacheHeaderSize+n]), true
}

// chromiumCacheKeyURL 取 key 里的地址。
func chromiumCacheKeyURL(key string) (*url.URL, bool) {
	if i := strings.LastIndexByte(key, ' '); i >= 0 {
		key = key[i+1:]
	}
	key = strings.TrimPrefix(key, "1/0/")
	u, err := url.Parse(key)
	if err != nil || u.Host == "" {
		return nil, false
	}
	return u, true
}

// chromiumCacheEntryBody 取响应正文;gzip 的解开。
func chromiumCacheEntryBody(data []byte) ([]byte, bool) {
	key, ok := chromiumCacheEntryKey(data)
	if !ok {
		return nil, false
	}
	start := chromiumSimpleCacheHeaderSize + len(key)
	eof := binary.LittleEndian.AppendUint64(nil, chromiumSimpleCacheEOFMagic)
	end := bytes.Index(data[start:], eof)
	if end < 0 {
		return nil, false
	}
	body := data[start : start+end]
	if !bytes.HasPrefix(body, []byte{0x1f, 0x8b}) {
		return body, true
	}
	zr, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return nil, false
	}
	out, err := io.ReadAll(io.LimitReader(zr, kkboxCacheEntryMaxBytes))
	if err != nil {
		return nil, false
	}
	return out, true
}

// kkboxCacheEntry 是缓存目录里的一条 KKBOX 接口响应:只记位置,正文用到才读。
type kkboxCacheEntry struct {
	file string
	mod  time.Time
	url  *url.URL
}

// kkboxCache 是一次扫描的结果,按写入时间从新到旧排。一次换歌只扫一遍目录(每个文件读开头 4 KB 取 key)。
type kkboxCache []kkboxCacheEntry

// kkboxBatchTracksPath 是批量详情接口(`?ids=a,b,c`)的路径。
const kkboxBatchTracksPath = "/v2/tracks/"

// kkboxRelatedTracksPrefix 是自动续播曲目表的路径前缀,后面跟开播那首歌的 id。
const kkboxRelatedTracksPrefix = "/v2/related-tracks/"

func scanKKBOXCache(dir string) kkboxCache {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out kkboxCache
	head := make([]byte, 4096)
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), "_0") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		n, _ := io.ReadFull(f, head)
		f.Close()
		key, ok := chromiumCacheEntryKey(head[:n])
		if !ok {
			continue
		}
		u, ok := chromiumCacheKeyURL(key)
		if !ok || !strings.HasPrefix(u.Host, "api-webapps.kkbox.") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, kkboxCacheEntry{file: p, mod: info.ModTime(), url: u})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].mod.After(out[j].mod) })
	return out
}

// body 读出一条的正文;太大或读不动当没有。
func (e kkboxCacheEntry) body() ([]byte, bool) {
	st, err := os.Stat(e.file)
	if err != nil || st.Size() > kkboxCacheEntryMaxBytes {
		return nil, false
	}
	data, err := os.ReadFile(e.file)
	if err != nil {
		return nil, false
	}
	return chromiumCacheEntryBody(data)
}

// trackList 取地址路径正好是 path 的最新一份曲目表。
func (c kkboxCache) trackList(path string) (kkboxTrackList, bool) {
	for _, e := range c {
		if e.url.Path != path {
			continue
		}
		body, ok := e.body()
		if !ok {
			return kkboxTrackList{}, false
		}
		return parseKKBOXTrackList(body)
	}
	return kkboxTrackList{}, false
}

// kkboxRecentListLimit:按写入时间往回找「有当前这首的列表」时最多解开几份。
const kkboxRecentListLimit = 8

// isKKBOXTrackListPath:专辑 / 歌单 / 歌曲集 / 自动续播的曲目表接口(`/v2/<类型>/<id>`,不含 `/v2/artists/<id>/albums`
// 这类下一层的)。
func isKKBOXTrackListPath(path string) bool {
	parts := strings.Split(strings.TrimPrefix(path, "/v2/"), "/")
	if len(parts) != 2 || parts[1] == "" {
		return false
	}
	switch parts[0] {
	case "albums", "playlists", "tracks-set", "related-tracks":
		return true
	}
	return false
}

// newestListWith 从最近写入的几份曲目表里找有这首(歌名 + 歌手,见 kkboxCurrentPosition)的那份。
func (c kkboxCache) newestListWith(artist, title string) ([]upcomingTrack, int) {
	tried := 0
	for _, e := range c {
		if tried >= kkboxRecentListLimit {
			break
		}
		if !isKKBOXTrackListPath(e.url.Path) {
			continue
		}
		tried++
		body, ok := e.body()
		if !ok {
			continue
		}
		l, ok := parseKKBOXTrackList(body)
		if !ok {
			continue
		}
		all, ids := l.upcoming(c.trackDetails(l.idsWithoutArtist()))
		if pos := kkboxCurrentPosition(all, ids, "", artist, title); pos >= 0 {
			return all, pos
		}
	}
	return nil, -1
}

// relatedTrackList 在自动续播的曲目表里找 data.id 是 id 的那份。地址里是开播那首歌、不是上下文 id,只能逐份解开看;
// 从新到旧找,刚续播的那份总在最前面。
func (c kkboxCache) relatedTrackList(id string) (kkboxTrackList, bool) {
	for _, e := range c {
		if !strings.HasPrefix(e.url.Path, kkboxRelatedTracksPrefix) {
			continue
		}
		body, ok := e.body()
		if !ok {
			continue
		}
		if l, ok := parseKKBOXTrackList(body); ok && l.Data.ID == id {
			return l, true
		}
	}
	return kkboxTrackList{}, false
}

// trackDetails 从批量详情里取这些曲目,id → 详情。一张专辑可能分几批拉,同一首取最新的那份;地址里的 ids 跟要找的
// 一首都不沾的不解开。
func (c kkboxCache) trackDetails(ids []string) map[string]kkboxTrack {
	if len(ids) == 0 {
		return nil
	}
	want := make(map[string]bool, len(ids))
	for _, id := range ids {
		want[id] = true
	}
	out := map[string]kkboxTrack{}
	for _, e := range c {
		if e.url.Path != kkboxBatchTracksPath || len(out) == len(want) {
			continue
		}
		wanted := false
		for _, id := range strings.Split(e.url.Query().Get("ids"), ",") {
			if want[id] && !hasKey(out, id) {
				wanted = true
				break
			}
		}
		if !wanted {
			continue
		}
		body, ok := e.body()
		if !ok {
			continue
		}
		var r struct {
			Data []kkboxTrack `json:"data"`
		}
		if json.Unmarshal(body, &r) != nil {
			continue
		}
		for _, t := range r.Data {
			if want[t.ID] && !hasKey(out, t.ID) {
				out[t.ID] = t
			}
		}
	}
	return out
}

func hasKey[K comparable, V any](m map[K]V, k K) bool {
	_, ok := m[k]
	return ok
}
