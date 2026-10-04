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
// 歌手名必须跟 KKBOX 报给系统的**逐字一致**,不然预解析写进缓存的 key 对不上、白解析一遍。KKBOX 前端
// (ArtistNameHelper)的规则:有 artist_roles 就是 main_artists + featured_artists 用 ", " 连起来,没有才用
// artist.name。同一个歌手的 roles 写法因曲而异(「Taylor Swift」「Taylor Swift (泰勒絲)」「周杰倫」都有),所以
// 每首歌都得拿到它自己的 roles。播放器报的是**曲目详情**(`/v2/tracks/<id>`、批量 `/v2/tracks/?ids=…`)里的 roles;
// 专辑接口里的曲目只有 id 和歌名,KKBOX 开播专辑时另拉一次批量详情 —— 专辑歌手是「周杰倫 (Jay Chou)」,详情里是「周杰倫」。
// 歌单 / 歌曲集 / 自动续播接口里的曲目自带 roles,但**同一个曲目 id 在列表里和详情里可能不是一个写法**:列表里是
// 「田馥甄」「Taylor Swift」,详情里是「田馥甄 (Hebe)」「Taylor Swift (泰勒絲)」,正好是 artist.name 的写法;另一些
// 曲目两边都是「Taylor Swift」。**同一张专辑里写法一致,同一位歌手跨专辑不一致**(实测 34 组「歌手 + 专辑」无一混用,
// Taylor Swift 在 Showgirl 那张全带别名、其余专辑全不带)。没播过的曲目详情多半不在缓存里,所以列表里 roles 的第一位
// 主唱正是 artist.name 去掉括号别名时(kkboxArtistSpellings),先按专辑找证据:缓存里同一张专辑别的曲目的详情
// (kkboxCache.albumForms)、此刻在放的这首播放器报的写法(kkboxQueue.adoptObserved);都没有就按列表里的写法预解析。
// 猜错了不白解析:真播到时报的是另一种写法,trackEnrichment 把这一条整份搬过去(kkboxalias.go)。
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
// album / online-playlist / song-list / my-library / track,五种都接;收藏库只接「全部歌曲」(见 kkboxLibraryLists)。
// 上下文串里的类型跟接口路径不同名:歌单是 online-playlist,接口是 playlists。
//
// 单曲(`kkbox:track:<曲目 id>`,没有序号、没有 ?track=)放完是按这首的「相关歌曲」自动续播的,接下来会播的就是
// `/v2/related-tracks/<这首>` 那份表(第一首是它自己);续播起来之后上下文换成那份表的 song-list(见下一段)。
//
// song-list 还有一种不在 tracks-set 下面:专辑 / 歌单放完之后 KKBOX 自动续播的「XX 合輯」,上下文 id 是它开播那首歌时
// 拉的 `/v2/related-tracks/<那首歌>` 响应里的 data.id(见 kkboxCache.relatedTrackList)。
var kkboxContextEndpoints = map[string]string{
	"song-list":       "tracks-set",
	"album":           "albums",
	"online-playlist": "playlists",
	"track":           "related-tracks",
	"my-library":      "library",
}

// kkboxLibraryLists:收藏库里的哪一份 → `/v2/library/` 下面的接口。收藏库的上下文是
// `kkbox:my-library:<那一份>:<序号>?track_id=<曲目 id>`,内置的四份是 @all(全部歌曲)/ @favorites(收藏歌曲)/
// @history(播放历史)/ @offline(离线),自建歌单用它自己的 id。只接 @all:它的接口 `library/all-tracks` 是
// `{version, tracks:[{id}]}`,每首只有 id,歌名歌手从曲目详情补(trackDetails);收藏歌曲的接口形状不同,播放历史 /
// 离线不走 HTTP,自建歌单那份没见过能解开的样本,都退回同专辑预取。
var kkboxLibraryLists = map[string]string{"@all": "all-tracks"}

// kkboxListenWith:「一起聽」频道(`kkbox:listen-with:channel:<频道 id>`,没有 ?track=)。下一首由主持人实时决定,
// 本机没有队列:磁盘缓存里不会出现这个频道的曲目表,IndexedDB / Session Storage 里也没有。这种上下文不预取,
// 也不退回同专辑预取(那批几乎都不会播到)。
const kkboxListenWith = "listen-with"

// kkboxContextListPath:上下文对应的曲目表接口路径;收藏库里没接的那几份返回 ok=false。
func kkboxContextListPath(ctx kkboxContext, endpoint string) (string, bool) {
	if ctx.kind != "my-library" {
		return "/v2/" + endpoint + "/" + ctx.id, true
	}
	name, ok := kkboxLibraryLists[ctx.id]
	if !ok {
		return "", false
	}
	return "/v2/library/" + name, true
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
// 攒一会儿才落盘(见 kkboxCurrentPosition);逐次隔 1 / 2 / 2 / 3 / 4 秒,最多等 12 秒(预解析本来就
// 在后台 goroutine 里,用户听一首歌远不止这么久)。单测设成 0。
var kkboxUpcomingRetryDelays = []time.Duration{time.Second, 2 * time.Second, 2 * time.Second, 3 * time.Second, 4 * time.Second}

// kkboxUpcomingBeforeRetry:单测在重读之前改盘上的数据用;平时是 nil。
var kkboxUpcomingBeforeRetry func()

func kkboxUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	for attempt := 0; ; attempt++ {
		tracks, ok, retry := kkboxUpcomingOnce(artist, title, n)
		if retry == "" {
			named := kkboxNamedTracks(tracks)
			if ok && len(tracks) > 0 && len(named) == 0 {
				// 接下来那几首的详情都没进缓存(收藏库 @all 常见):队列读到了,却一首也叫不出名字。
				// 交一个空列表出去等于什么都不预取,不如退回同专辑预取。
				return nil, false
			}
			return named, ok
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

// kkboxNamedTracks 去掉没有歌名的:收藏库的曲目表每首只有 id,详情没进缓存的那几首叫不出名字,交出去也解析不了。
func kkboxNamedTracks(tracks []upcomingTrack) []upcomingTrack {
	out := tracks[:0:0]
	for _, t := range tracks {
		if t.title != "" {
			out = append(out, t)
		}
	}
	return out
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
	if ctx.kind == kkboxListenWith {
		kkboxUpcomingNote("listen-with:"+ctx.id, "kkbox upcoming: listen-with channel, the host picks the next track and there is no local queue; skipping prefetch")
		return nil, true, ""
	}
	endpoint, ok := kkboxContextEndpoints[ctx.kind]
	if !ok {
		kkboxUpcomingNote("kind:"+ctx.kind, "kkbox upcoming: playing from a %q context, which has no cached track list; falling back to album prefetch", ctx.kind)
		return nil, false, ""
	}
	path, ok := kkboxContextListPath(ctx, endpoint)
	if !ok {
		kkboxUpcomingNote("library:"+ctx.id, "kkbox upcoming: playing from a my-library list that is not read; falling back to album prefetch")
		return nil, false, ""
	}
	cache := scanKKBOXCache(kkboxCacheDir())
	list, ok := cache.trackList(path)
	if !ok && ctx.kind == "song-list" {
		list, ok = cache.relatedTrackList(ctx.id)
	}
	var q kkboxQueue
	pos := -1
	if ok {
		q = list.upcoming(cache.trackDetails(list.ids()), cache.albumForms())
		pos = kkboxCurrentPosition(q, ctx.track, artist, title)
	}
	if pos < 0 {
		// 换了列表、上下文还没落盘(见 kkboxCurrentPosition):KKBOX 打开新列表时刚拉过它的曲目表,按写入时间
		// 找最近几份里有这首的那份。
		q, pos = cache.newestListWith(artist, title)
	}
	if pos < 0 {
		// 新列表的曲目表可能也还没写进缓存:值得再读一次。
		return nil, false, "neither the saved " + ctx.kind + " nor a recently cached track list has the current track"
	}
	if !q.spelledAs(pos, artist) {
		// 歌手名哪种写法都跟 KKBOX 报的对不上:多半是同名的另一首,照这个拼法预解析就是白解析(见文件头注)。重读也不会变。
		kkboxUpcomingNote("artist:"+ctx.id, "kkbox upcoming: the track list names the artist %q but the player reports %q; falling back to album prefetch", q.tracks[pos].artist, artist)
		return nil, false, ""
	}
	q.adoptObserved(pos, artist)
	if pb.shuffle {
		// 叫不出名字的(详情没进缓存)不占候选名额,理由同下面顺序播放那支。
		picked := shuffleCandidates(len(q.tracks), pos, func(i int) (upcomingTrack, bool) { return q.tracks[i], q.tracks[i].title != "" })
		var idx []int
		for _, t := range picked {
			for i := range q.tracks {
				if q.tracks[i] == t {
					idx = append(idx, i)
					break
				}
			}
		}
		return q.picked(idx), true, ""
	}
	if pos+1 >= len(q.tracks) {
		return nil, false, ""
	}
	// 取接下来 n 首**叫得出名字的**:先截 n 首再滤,详情没进缓存的那几首会把后面叫得出名字的一起挤掉。
	// 一首也没有时仍交出(没名字的)那几首,由 kkboxUpcoming 判「读到了却一首也解析不了」、退回同专辑预取。
	var idx []int
	for i := pos + 1; i < len(q.tracks) && len(idx) < n; i++ {
		if q.tracks[i].title != "" {
			idx = append(idx, i)
		}
	}
	if len(idx) == 0 {
		for i := pos + 1; i < min(pos+1+n, len(q.tracks)); i++ {
			idx = append(idx, i)
		}
	}
	return q.picked(idx), true, ""
}

// kkboxCurrentPosition 找播放器报的这首在曲目表里的位置;找不到返回 -1。
//
// 上下文里记着的曲目 id 只当提示:Chromium 的 Local Storage 攒一会儿才落盘,切得勤时「当前是哪首」能晚十几秒以上
// (换歌后能晚十几秒,见 09 章决策 100)。列表本身换得少,所以 id 指的那首歌名对不上时,
// 在同一份列表里按歌名找;同名的不止一首时要歌手也对上的那首,都对不上就取第一首(交给调用方的歌手校验去拒)。
// 列表里压根没有这首 = 换了列表、上下文还没落盘,调用方隔一会儿重读。
func kkboxCurrentPosition(q kkboxQueue, trackID, artist, title string) int {
	wantTitle := loosenEnrichKey(title)
	for i, id := range q.ids {
		if id == trackID && loosenEnrichKey(q.tracks[i].title) == wantTitle {
			return i
		}
	}
	first := -1
	for i, t := range q.tracks {
		if loosenEnrichKey(t.title) != wantTitle {
			continue
		}
		if q.spelledAs(i, artist) {
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
	if err != nil {
		return kkboxContext{}, false
	}
	track := q.Get("track")
	if track == "" {
		track = q.Get("track_id") // 收藏库的上下文用这个键
	}
	if parts[0] == "track" && track == "" {
		track = parts[1] // 单曲:上下文本身就是这首
	}
	if parts[0] == kkboxListenWith {
		return kkboxContext{kind: kkboxListenWith, id: parts[len(parts)-1]}, true // 「一起聽」没有当前曲目 id
	}
	if track == "" {
		return kkboxContext{}, false
	}
	return kkboxContext{kind: parts[0], id: parts[1], track: track}, true
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
		// Images:单曲详情里带专辑封面三档(large 600 / medium 300 / small 80),曲目表接口不一定带。
		Images *struct {
			Large  *kkboxImage `json:"large"`
			Medium *kkboxImage `json:"medium"`
		} `json:"images"`
	} `json:"album"`
	DurationMs float64 `json:"duration_ms"`
}

type kkboxImage struct {
	URL string `json:"url"`
}

// albumCover:专辑封面地址,换成原图(见 kkboxOriginalImage);没有就空串。
func (t kkboxTrack) albumCover() string {
	if t.Album == nil || t.Album.Images == nil {
		return ""
	}
	for _, img := range []*kkboxImage{t.Album.Images.Large, t.Album.Images.Medium} {
		if img != nil && img.URL != "" {
			return kkboxOriginalImage(img.URL)
		}
	}
	return ""
}

// kkboxOriginalImage:图床地址末尾的 `/fit/600x600.jpg` 换成 `/original.jpg` 拿原图(实测 5000 / 1000);
// fit 档比原图大时是放大出来的,3000 起回 404。不是这个形状的地址原样返回。
func kkboxOriginalImage(u string) string {
	if !strings.Contains(u, "i.kfs.io/") {
		return u
	}
	if i := strings.LastIndex(u, "/fit/"); i > 0 && strings.HasSuffix(u, ".jpg") {
		return u[:i] + "/original.jpg"
	}
	return u
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

// kkboxArtistSpellings:这首歌播放器可能报的歌手写法,第一个是 kkboxArtistName。列表里的 roles 第一位主唱正是
// artist.name 去掉括号别名(「田馥甄」对「田馥甄 (Hebe)」)时,详情里可能是 artist.name 那种写法,补上第二个(见文件头注),
// 并返回判这张专辑用哪种写法的键(kkboxAlbumFormKey);只有一种写法时键为空。第二种只拿来认当前这首、按专辑证据改选,
// 不另外预解析。详情本身(fromDetails)就是播放器报的那一份,不猜。
func kkboxArtistSpellings(t kkboxTrack, fallback, album string, fromDetails bool) ([]string, string) {
	primary := kkboxArtistName(t, fallback)
	if fromDetails || t.Artist == nil || t.ArtistRoles == nil || len(t.ArtistRoles.Main) == 0 {
		return []string{primary}, ""
	}
	first := t.ArtistRoles.Main[0].Name
	if first == "" || t.Artist.Name == first || !strings.HasPrefix(t.Artist.Name, first+" (") {
		return []string{primary}, ""
	}
	alt := t
	roles := *t.ArtistRoles
	roles.Main = append([]kkboxArtist{{Name: t.Artist.Name}}, t.ArtistRoles.Main[1:]...)
	alt.ArtistRoles = &roles
	return []string{primary, kkboxArtistName(alt, fallback)}, kkboxAlbumFormKey(first, album)
}

// kkboxAlbumFormKey:「这张专辑的第一位主唱带不带括号别名」按这个键记。stem 是不带别名的写法。
func kkboxAlbumFormKey(stem, album string) string {
	return loosenEnrichKey(stem) + "\x00" + loosenEnrichKey(album)
}

// kkboxDetailForm:一条详情里第一位主唱是不是带 artist.name 的括号别名;不是这种形态的 ok=false。
func kkboxDetailForm(t kkboxTrack) (key string, alias, ok bool) {
	if t.Artist == nil || t.ArtistRoles == nil || len(t.ArtistRoles.Main) == 0 || t.Album == nil {
		return "", false, false
	}
	an, first := t.Artist.Name, t.ArtistRoles.Main[0].Name
	i := strings.Index(an, " (")
	if i <= 0 || (first != an && first != an[:i]) {
		return "", false, false
	}
	return kkboxAlbumFormKey(an[:i], t.Album.Name), first == an, true
}

// parseKKBOXTrackList 解一份曲目表接口响应;没有曲目算没拿到。
func parseKKBOXTrackList(body []byte) (kkboxTrackList, bool) {
	var r kkboxTrackList
	if json.Unmarshal(body, &r) != nil || len(r.Data.Tracks) == 0 {
		return kkboxTrackList{}, false
	}
	return r, true
}

// ids:列表里全部曲目的 id,拿去曲目详情里找(详情是播放器报的那一份,见文件头注)。
func (l kkboxTrackList) ids() []string {
	ids := make([]string, 0, len(l.Data.Tracks))
	for _, t := range l.Data.Tracks {
		ids = append(ids, t.ID)
	}
	return ids
}

// kkboxQueue 是换成预解析用的曲目表:tracks 的歌手是第一种写法,ids / spellings / formKeys 与之一一对应。
// 两种写法的 spellings 是 [列表里的写法, artist.name 那种写法],formKeys 是判这张专辑用哪种的键。
type kkboxQueue struct {
	tracks    []upcomingTrack
	ids       []string
	spellings [][]string
	formKeys  []string
}

// upcoming 换成预解析用的曲目表。详情里有这首就用详情那条(播放器报的就是它);没有就用列表里自带的,自己也不带歌手的
// 退回专辑歌手 —— 跟 KKBOX 报的未必一致,当前这首对不上时由调用方退回同专辑预取。两种写法的,forms(专辑 → 带不带别名)
// 里有这张专辑就只留那一种。
func (l kkboxTrackList) upcoming(details map[string]kkboxTrack, forms map[string]bool) kkboxQueue {
	albumArtist := ""
	if l.Data.Artist != nil {
		albumArtist = l.Data.Artist.Name
	}
	q := kkboxQueue{
		tracks:    make([]upcomingTrack, 0, len(l.Data.Tracks)),
		ids:       make([]string, 0, len(l.Data.Tracks)),
		spellings: make([][]string, 0, len(l.Data.Tracks)),
		formKeys:  make([]string, 0, len(l.Data.Tracks)),
	}
	for _, t := range l.Data.Tracks {
		fromDetails := false
		if d, ok := details[t.ID]; ok && d.hasOwnArtist() {
			t, fromDetails = d, true
		}
		album := l.Data.Name
		if t.Album != nil && t.Album.Name != "" {
			album = t.Album.Name
		}
		names, formKey := kkboxArtistSpellings(t, albumArtist, album, fromDetails)
		q.tracks = append(q.tracks, upcomingTrack{artist: names[0], title: t.Name, album: album, duration: t.DurationMs / 1000})
		q.ids = append(q.ids, t.ID)
		q.spellings = append(q.spellings, names)
		q.formKeys = append(q.formKeys, formKey)
	}
	for k, alias := range forms {
		q.settleForm(k, alias)
	}
	return q
}

// settleForm:这张专辑用哪种写法已经有证据,两种写法的那几首只留这一种。
func (q *kkboxQueue) settleForm(key string, alias bool) {
	for i, k := range q.formKeys {
		if k != key || len(q.spellings[i]) < 2 {
			continue
		}
		pick := q.spellings[i][0]
		if alias {
			pick = q.spellings[i][1]
		}
		q.spellings[i] = []string{pick}
		q.tracks[i].artist = pick
		q.formKeys[i] = ""
	}
}

// adoptObserved:此刻在放的第 pos 首还是两种写法时,播放器报的那种就是这张专辑的写法。
func (q *kkboxQueue) adoptObserved(pos int, artist string) {
	if len(q.spellings[pos]) < 2 {
		return
	}
	q.settleForm(q.formKeys[pos], loosenEnrichKey(q.spellings[pos][1]) == loosenEnrichKey(artist))
}

// spelledAs:第 i 首的某种写法跟播放器报的对得上。
func (q kkboxQueue) spelledAs(i int, artist string) bool {
	want := loosenEnrichKey(artist)
	for _, n := range q.spellings[i] {
		if loosenEnrichKey(n) == want {
			return true
		}
	}
	return false
}

// picked 把选出来的这几首交出去,每首一种写法(有专辑证据的已经按证据改过,见 settleForm)。
func (q kkboxQueue) picked(idx []int) []upcomingTrack {
	out := make([]upcomingTrack, 0, len(idx))
	for _, i := range idx {
		out = append(out, q.tracks[i])
	}
	return out
}

// ---- Chromium 磁盘缓存 ----

// Chromium「simple cache」的一个条目文件(`<hash>_0`):24 字节头(魔数 8 + 版本 4 + key 长度 4 + key 哈希 4,
// 再补 4 字节对齐)、key(`1/0/<地址>`,带网络隔离时前面还有两段站点,地址总在最后)、紧接着是响应正文(原样存的,
// 这里是 gzip),正文以一个 EOF 记录收尾,之后才是响应头。
const (
	chromiumSimpleCacheMagic      = 0xfcfb6d1ba7725c30
	chromiumSimpleCacheEOFMagic   = 0xf4fa6f45970d41d8
	chromiumSimpleCacheHeaderSize = 24
	// kkboxCacheEntryMaxBytes:单个缓存条目的读入上限。歌单接口一般几 KB 到几十 KB。
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

// kkboxScanMemo:每个缓存文件上一次读开头认出来的地址,按路径 + 修改时间 + 大小记(url 为 nil = 不是
// KKBOX 接口的响应)。这个目录里是整个 App 的 HTTP 缓存(实测两千来个文件),一次换歌要扫好几遍
// (预取重读、歌词、专辑各一遍),每遍都把每个文件打开读 4KB 是白花的 —— 条目写下之后不再改,认过一次就够了。
var (
	kkboxScanMemoMu sync.Mutex
	kkboxScanMemo   = map[string]kkboxScanMemoEntry{}
)

type kkboxScanMemoEntry struct {
	mod  time.Time
	size int64
	url  *url.URL
}

func scanKKBOXCache(dir string) kkboxCache {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out kkboxCache
	head := make([]byte, 4096)
	seen := make(map[string]bool, len(ents))
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), "_0") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		p := filepath.Join(dir, e.Name())
		seen[p] = true
		kkboxScanMemoMu.Lock()
		m, hit := kkboxScanMemo[p]
		kkboxScanMemoMu.Unlock()
		if !hit || !m.mod.Equal(info.ModTime()) || m.size != info.Size() {
			m = kkboxScanMemoEntry{mod: info.ModTime(), size: info.Size(), url: kkboxCacheEntryURL(p, head)}
			kkboxScanMemoMu.Lock()
			kkboxScanMemo[p] = m
			kkboxScanMemoMu.Unlock()
		}
		if m.url == nil {
			continue
		}
		out = append(out, kkboxCacheEntry{file: p, mod: info.ModTime(), url: m.url})
	}
	// 已经不在目录里的(Chromium 淘汰了)从记忆里清掉,不然这张表只涨不落。只清这个目录下的。
	prefix := filepath.Clean(dir) + string(filepath.Separator)
	kkboxScanMemoMu.Lock()
	for p := range kkboxScanMemo {
		if strings.HasPrefix(p, prefix) && !seen[p] {
			delete(kkboxScanMemo, p)
		}
	}
	kkboxScanMemoMu.Unlock()
	sort.SliceStable(out, func(i, j int) bool { return out[i].mod.After(out[j].mod) })
	return out
}

// kkboxCacheEntryURL 读一个缓存文件的开头、认出它存的是哪个地址;不是 KKBOX 接口的响应、读不动返回 nil。
// head 是调用方给的缓冲,免得每个文件都分配一份。
func kkboxCacheEntryURL(path string, head []byte) *url.URL {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	n, _ := io.ReadFull(f, head)
	f.Close()
	key, ok := chromiumCacheEntryKey(head[:n])
	if !ok {
		return nil
	}
	u, ok := chromiumCacheKeyURL(key)
	if !ok || !strings.HasPrefix(u.Host, "api-webapps.kkbox.") {
		return nil
	}
	return u
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
	case "library":
		return parts[1] == kkboxLibraryLists["@all"]
	}
	return false
}

// newestListWith 从最近写入的几份曲目表里找有这首(歌名 + 歌手,见 kkboxCurrentPosition)的那份。
func (c kkboxCache) newestListWith(artist, title string) (kkboxQueue, int) {
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
		q := l.upcoming(c.trackDetails(l.ids()), c.albumForms())
		if pos := kkboxCurrentPosition(q, "", artist, title); pos >= 0 {
			return q, pos
		}
	}
	return kkboxQueue{}, -1
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

// trackDetails 从曲目详情里取这些曲目,id → 详情:批量的 `/v2/tracks/?ids=…` 与单首的 `/v2/tracks/<id>`(开播时拉的)。
// 一张专辑可能分几批拉,同一首取最新的那份;地址跟要找的一首都不沾的不解开。
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
		if len(out) == len(want) {
			break
		}
		if single, ok := strings.CutPrefix(e.url.Path, kkboxBatchTracksPath); ok && single != "" {
			if !want[single] || hasKey(out, single) {
				continue
			}
		} else if e.url.Path == kkboxBatchTracksPath {
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
		} else {
			continue
		}
		// 走 detailTracks 的记忆:同一份详情一次换歌里会被问好几遍(每份候选列表一遍、重读又一遍),
		// 每遍都重新读盘 + 解压 + 解 JSON 是白花的。
		for _, t := range e.detailTracks() {
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

// kkboxDetailMemo:解析过的曲目详情文件,按路径 + 修改时间记。Chromium 的缓存条目写下之后不再改,一个文件只解析一次。
var (
	kkboxDetailMemoMu sync.Mutex
	kkboxDetailMemo   = map[string]kkboxDetailMemoEntry{}
)

type kkboxDetailMemoEntry struct {
	mod    time.Time
	tracks []kkboxTrack
}

// detailTracks:一条曲目详情(单首或批量)里的曲目;不是详情接口或解不开返回空。
func (e kkboxCacheEntry) detailTracks() []kkboxTrack {
	if !strings.HasPrefix(e.url.Path, kkboxBatchTracksPath) {
		return nil
	}
	kkboxDetailMemoMu.Lock()
	m, ok := kkboxDetailMemo[e.file]
	kkboxDetailMemoMu.Unlock()
	if ok && m.mod.Equal(e.mod) {
		return m.tracks
	}
	var tracks []kkboxTrack
	if body, ok := e.body(); ok {
		var many struct {
			Data []kkboxTrack `json:"data"`
		}
		var one struct {
			Data kkboxTrack `json:"data"`
		}
		if json.Unmarshal(body, &many) == nil {
			tracks = many.Data
		} else if json.Unmarshal(body, &one) == nil && one.Data.ID != "" {
			tracks = []kkboxTrack{one.Data}
		}
	}
	kkboxDetailMemoMu.Lock()
	kkboxDetailMemo[e.file] = kkboxDetailMemoEntry{mod: e.mod, tracks: tracks}
	kkboxDetailMemoMu.Unlock()
	return tracks
}

// albumForms:缓存里全部曲目详情给出的「这张专辑的第一位主唱带不带括号别名」。同一张专辑两种都见过(没实测到过)就不下结论。
// 顺带把已经不在缓存目录里的文件从 kkboxDetailMemo 里清掉(Chromium 会淘汰旧条目)。
func (c kkboxCache) albumForms() map[string]bool {
	out := map[string]bool{}
	mixed := map[string]bool{}
	present := make(map[string]bool, len(c))
	for _, e := range c {
		present[e.file] = true
	}
	kkboxDetailMemoMu.Lock()
	for f := range kkboxDetailMemo {
		if !present[f] {
			delete(kkboxDetailMemo, f)
		}
	}
	kkboxDetailMemoMu.Unlock()
	for _, e := range c {
		for _, t := range e.detailTracks() {
			key, alias, ok := kkboxDetailForm(t)
			if !ok || mixed[key] {
				continue
			}
			if prev, seen := out[key]; seen && prev != alias {
				mixed[key] = true
				delete(out, key)
				continue
			}
			out[key] = alias
		}
	}
	return out
}
