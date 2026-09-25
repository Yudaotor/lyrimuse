package main

import (
	"bytes"
	"context"
	"encoding/json"
	"hash/fnv"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 酷狗的**当前**播放队列:userCurrentPlayList.plist。
//
// ## 为什么换到这份文件
//
// 酷狗 3.3.2 起队列改存在这份 plist 里、换歌那一刻重写(署名修正那边先查实的,见 kugoulyricartist.go
// 与 docs/features/02 章),播普通歌单时**不再写** currentPlayList.sqlite —— 那份库里只剩升级前的旧歌单
// (实测记录见第 09 章决策 67)。播「首页 → 推荐」这类推荐流时反过来:这份 plist 被清成两个空列表,
// 队列写在那份库里(见 kugouUpcomingPath)。结构是:
//
//	userPlayList[0]  队列本身,按列表顺序的一组曲目字典
//	userPlayList[1]  当前这首(一个曲目字典)
//	userPlayList[2]  当前这首在队列里的下标,**字符串**(实测 "16")
//
// 也就是说它**自带当前位置**,不用像 sqlite 那份一样靠歌名反查 —— 但仍然要核对那个位置上的
// 歌是不是此刻在播的这首(同 QQ 那条路:文件停在上一次播放是常态),对不上再在队列里找一遍
// (换歌和写文件之间有先后,poller 这一拍可能比酷狗写盘快)。
//
// ## 这份文件缺的两样,从哪补
//
//   - **专辑名**:条目里压根没有。专辑是 enrich key 的一部分、宽松比对也不忽略它,拿空专辑去
//     预解析,真播到时 key 对不上,等于白解析还多一条重复。用条目的 strFileHash 去客户端曲库
//     kugou3.sqlite 的 Allmusic 表查 albumname —— 实测那 50 首 hash 全部查得到,专辑名跟播放器
//     实际上报的 50/50 一致(其中 1 首两边都是空)。查不到的那首**跳过**,不拿空串去猜。
//   - **署名**:用 singerName,不用 musicName 前缀。实测 50 首里 49 首播放器报的(经署名修正后)
//     就是 singerName;多署名的歌播放器会先报完整串(「少司命、新乐尘符」)、修正后落到
//     singerName(「少司命」),key 最终用的是后者。旧 sqlite 那条路拼 singerInfo 全部署名,
//     对这种歌反而对不上。
//
// ## 播放模式
//
// KugouConfigPlist.plist 里有个 playMode,但**不可信**:实测随机播放一份推荐队列时它照样是 0(0 本来
// 是 09-22 按列表顺序播了一整天时看到的值),容器里其它偏好文件也找不到随机开关。所以顺序 / 随机
// 主要看换歌行为(queueorder.go),小队列干脆整份预取,见 kugouPickUpcoming。playMode 读得到且不是 0
// 时仍当作「不是列表顺序」,直接按随机处理。

// 单测把三份文件指到临时路径。空 = 用真实路径。
var (
	kugouQueuePlistOverride  string
	kugouConfigPlistOverride string
	kugouLibraryDBOverride   string
)

// kugouQueuePlistMaxBytes:plutil 输出的大小上限。实测 50 首 177KB,16MB 防的是"队列被塞到上万首 /
// 格式变了"时把内存吃光,同 qqUpcomingMaxBytes。
const kugouQueuePlistMaxBytes = 16 << 20

// kugouListOrderPlayMode 是 playMode 里「按列表顺序」的那个值。随机时它也可能是这个值,见文件头注。
const kugouListOrderPlayMode = 0

func kugouContainerPath(rel string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.kugou.mac.Music/Data", rel)
}

func kugouQueuePlistPath() string {
	if kugouQueuePlistOverride != "" {
		return kugouQueuePlistOverride
	}
	return kugouContainerPath("Library/Preferences/userCurrentPlayList.plist")
}

func kugouConfigPlistPath() string {
	if kugouConfigPlistOverride != "" {
		return kugouConfigPlistOverride
	}
	return kugouContainerPath("Library/Preferences/KugouConfigPlist.plist")
}

// kugouLibraryDBPath 是客户端曲库(Allmusic 表按 musichash 存着专辑名)。
func kugouLibraryDBPath() string {
	if kugouLibraryDBOverride != "" {
		return kugouLibraryDBOverride
	}
	return kugouContainerPath("Documents/kugou3.sqlite")
}

// kugouQueueSong 是队列里一首歌用得上的那几个字段。
type kugouQueueSong struct {
	musicName  string // "歌手 - 歌名"
	singerName string
	hash       string // strFileHash
	seconds    float64
}

func kugouQueueSongFrom(v any) (kugouQueueSong, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return kugouQueueSong{}, false
	}
	song := kugouQueueSong{}
	song.musicName, _ = m["musicName"].(string)
	song.singerName, _ = m["singerName"].(string)
	song.hash, _ = m["strFileHash"].(string)
	switch d := m["musicTime"].(type) {
	case float64:
		song.seconds = d // musicTime 本来就是秒(实测 201.0)
	case int64:
		song.seconds = float64(d)
	}
	return song, song.musicName != ""
}

// artistAndTitle:署名优先 singerName,空的时候退回 musicName 前缀那一半(理由见文件头注)。
func (s kugouQueueSong) artistAndTitle() (artist, title string) {
	prefix, title := kugouUpcomingSplit(s.musicName)
	if s.singerName != "" {
		return s.singerName, title
	}
	return prefix, title
}

// isCurrent:这首是不是此刻在播的那首。singerName 和 musicName 前缀两种署名都认 —— 播放器在
// 署名修正生效前后分别报这两种(见文件头注)。
func (s kugouQueueSong) isCurrent(artist, title string) bool {
	want := loosenEnrichKey(artist + "|" + title)
	prefix, t := kugouUpcomingSplit(s.musicName)
	for _, a := range []string{s.singerName, prefix} {
		if a != "" && loosenEnrichKey(a+"|"+t) == want {
			return true
		}
	}
	return false
}

// kugouLoadQueue 读 userCurrentPlayList.plist,返回队列与当前这首的位置(-1 = 当前这首不在队列里)。
//
// handled=false 只表示「这份文件读不到」(没有 / 解不开 / 结构不认识);读到了就一律 handled=true。
func kugouLoadQueue(artist, title string) (list []kugouQueueSong, pos int, handled bool) {
	path := kugouQueuePlistPath()
	if path == "" {
		return nil, -1, false
	}
	if _, err := os.Stat(path); err != nil {
		noteLocalCacheDenied("kugou", path, err)
		return nil, -1, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), kugouUpcomingQueryTimeout)
	defer cancel()
	// 文件现在就是 XML,但 plist 随时可能被客户端存成二进制;统一过一遍 plutil,同 QQ 那条路。
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", path).Output()
	if err != nil || len(out) > kugouQueuePlistMaxBytes {
		return nil, -1, false
	}
	noteLocalCacheReadable("kugou")
	root, err := parsePlistXML(out)
	if err != nil {
		return nil, -1, false
	}
	top, _ := root.(map[string]any)
	parts, _ := top["userPlayList"].([]any)
	if len(parts) == 0 {
		return nil, -1, false
	}
	rawList, isList := parts[0].([]any)
	if !isList {
		return nil, -1, false
	}
	// 结构认出来了,从这里往下都是 handled=true。
	list = make([]kugouQueueSong, 0, len(rawList))
	for _, v := range rawList {
		song, _ := kugouQueueSongFrom(v) // 解不开的占个空位,保住下标跟 userPlayList[2] 对齐
		list = append(list, song)
	}

	pos = -1
	if len(parts) > 2 {
		if idx, ok := kugouQueueIndex(parts[2]); ok && idx < len(list) && list[idx].isCurrent(artist, title) {
			pos = idx
		}
	}
	if pos < 0 {
		// 指针对不上(文件还没跟上这次切歌,或者格式里没有这一项):在队列里找一次。
		for i, song := range list {
			if song.isCurrent(artist, title) {
				pos = i
				break
			}
		}
	}
	return list, pos, true
}

// kugouUpcomingFromPlist 从 userCurrentPlayList.plist 取接下来会播的几首。
//
// handled 的含义同 kugouLoadQueue;读到了文件时 ok 才说明取没取到(理由见 kugouUpcoming)。
func kugouUpcomingFromPlist(artist, title string, n int) (res []upcomingTrack, ok, handled bool) {
	list, pos, handled := kugouLoadQueue(artist, title)
	if !handled {
		return nil, false, false
	}
	if pos < 0 {
		return nil, false, true // 当前这首不在当前队列里
	}
	// 整份一次查完:随机时候选可能是队列里任何一首。一条 IN 查询,几千首也是毫秒级。
	albums := kugouAlbumsByHash(list)
	tracks := make([]upcomingTrack, len(list))
	for i, song := range list {
		a, t := song.artistAndTitle()
		album, found := albums[strings.ToUpper(song.hash)]
		if t == "" || song.hash == "" || !found {
			continue // 专辑名拿不到就不预解析这首(理由见文件头注),留个空位保住下标
		}
		tracks[i] = upcomingTrack{artist: a, title: t, album: album, duration: song.seconds}
	}
	res, ok = kugouPickUpcoming("plist", tracks, pos, n)
	return res, ok, true
}

var (
	kugouPlayOrderMu   sync.Mutex
	kugouPlayOrderLast queueOrder
)

// kugouPickUpcoming 从整份队列里挑要预解析的那几首(两份队列来源共用)。tracks 与队列下标对齐,
// title 为空的是拿不全、要跳过的那首。
//
//   - 队列不超过 queueShuffleWholeListMax 首:不管顺序还是随机,整份交出去(从当前往后、到末尾接回开头,
//     顺序播放下紧接着的那几首排在最前)。实测「酷狗首页 → 推荐」给的就是一份 15 首的固定队列,
//     随机时从第 0 首直接跳到第 14 首,按列表往后取 5 首一首都没播到;整份解析也只花一次(缓存永久保留)。
//   - 更大的队列:从换歌行为推断随机(queueOrder),随机时每换一首补 queueShuffleBatch 首没解析过的,
//     顺序时照旧往后取 n 首。playMode 读得到且不是列表顺序时直接按随机处理。
//
// 队列里除了当前这首再没有能预解析的歌时返回 ok=false,退回同专辑预取;有歌但都解析过了是 ok=true。
func kugouPickUpcoming(source string, tracks []upcomingTrack, pos, n int) ([]upcomingTrack, bool) {
	at := func(i int) (upcomingTrack, bool) { return tracks[i], tracks[i].title != "" }
	others := 0
	for i := range tracks {
		if _, ok := at(i); ok && i != pos {
			others++
		}
	}
	if others == 0 {
		return nil, false
	}

	kugouPlayOrderMu.Lock()
	prevPos := kugouPlayOrderLast.pos
	shuffled, flipped := kugouPlayOrderLast.observe(kugouQueueID(source, tracks), pos)
	kugouPlayOrderMu.Unlock()
	if flipped {
		log.Printf("kugou upcoming: moved from position %d to %d in the queue, treating playback as shuffled", prevPos, pos)
	}
	if mode, known := kugouPlayMode(); known && mode != kugouListOrderPlayMode {
		shuffled = true
	}

	if shuffled || len(tracks) <= queueShuffleWholeListMax {
		return shuffleCandidates(len(tracks), pos, at), true
	}
	res := make([]upcomingTrack, 0, n)
	for i := pos + 1; i < len(tracks) && len(res) < n; i++ {
		if t, ok := at(i); ok {
			res = append(res, t)
		}
	}
	return res, len(res) > 0
}

// kugouQueueID 是一份队列的身份:来源 + 全部曲目的摘要。不用文件 mtime —— 推荐流那份库每换一首就重写一次,
// 内容不变,按 mtime 算会让顺序 / 随机的证据每首都被清空。
func kugouQueueID(source string, tracks []upcomingTrack) string {
	h := fnv.New64a()
	h.Write([]byte(source))
	for _, t := range tracks {
		h.Write([]byte{0})
		h.Write([]byte(t.artist + "|" + t.title))
	}
	return strconv.FormatUint(h.Sum64(), 16) + "/" + strconv.Itoa(len(tracks))
}

// kugouQueueIndex 解 userPlayList[2]。实测是字符串 "16";整数也认,防客户端哪天改了存法。
func kugouQueueIndex(v any) (int, bool) {
	switch x := v.(type) {
	case string:
		n, err := strconv.Atoi(strings.TrimSpace(x))
		return n, err == nil && n >= 0
	case int64:
		return int(x), x >= 0
	}
	return 0, false
}

// kugouPlayMode 读 KugouConfigPlist.plist 的 playMode。known=false 表示读不到。
func kugouPlayMode() (mode int64, known bool) {
	path := kugouConfigPlistPath()
	if path == "" {
		return 0, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), kugouUpcomingQueryTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "playMode", "raw", "-o", "-", path).Output()
	if err != nil {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

// kugouAlbumsByHash 按 strFileHash 去客户端曲库查专辑名,返回 大写 hash → 专辑名。
//
// 查得到但专辑列是 NULL 的,映射成空串 —— 那是"这首歌确实没有专辑",跟"曲库里没这首"(不在
// 返回值里)是两回事,前者照样预解析。库读不到就返回空表,调用方会把这几首全部跳过。
func kugouAlbumsByHash(songs []kugouQueueSong) map[string]string {
	path := kugouLibraryDBPath()
	if path == "" {
		return nil
	}
	if _, err := os.Stat(path); err != nil {
		noteLocalCacheDenied("kugou", path, err)
		return nil
	}
	quoted := make([]string, 0, len(songs))
	for _, s := range songs {
		h := strings.ToUpper(s.hash)
		if !isHexString(h) {
			continue // hash 要拼进 SQL,只放行十六进制串
		}
		quoted = append(quoted, "'"+h+"'")
	}
	if len(quoted) == 0 {
		return nil
	}
	query := "SELECT upper(musichash) AS h, ifnull(albumname, '') AS a FROM Allmusic WHERE upper(musichash) IN (" +
		strings.Join(quoted, ",") + ")"
	ctx, cancel := context.WithTimeout(context.Background(), kugouUpcomingQueryTimeout)
	defer cancel()
	// mode=ro 的理由同 kugouUpcomingFromSQLite:只读快照撞上客户端写锁就直接失败、fail-soft。
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, query).Output()
	if err != nil {
		return nil
	}
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil // 零行时 sqlite3 -json 输出空串,不是 "[]"
	}
	var rows []struct {
		Hash  string `json:"h"`
		Album string `json:"a"`
	}
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		return nil
	}
	albums := make(map[string]string, len(rows))
	for _, r := range rows {
		albums[r.Hash] = r.Album
	}
	return albums
}

func isHexString(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'A' && r <= 'F' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

// ---- 同专辑兜底:问酷狗自己的专辑曲目表 ----

var (
	kugouAlbumMu      sync.Mutex
	kugouAlbumIDCache = map[string]string{}       // 大写 hash → 专辑 id
	kugouAlbumCache   = map[string][]albumTrack{} // 专辑 id → 曲目表
)

// kugouAlbumTracks 是酷狗的同专辑兜底:在队列里找到当前这首,拿它的 strFileHash 问酷狗这首属于哪张专辑
// (getSongInfo 的 albumid),再取那张专辑的曲目表(album/song)。曲目表里的「歌手 - 歌名」是酷狗自己的
// 写法,跟队列里的 musicName 同一种格式、同一套拆法。队列里没有这首、没有 hash、接口失败都返回 ok=false,
// 由 albumTracks 退回网易云那条。
func kugouAlbumTracks(artist, title, album string) ([]albumTrack, bool) {
	list, pos, handled := kugouLoadQueue(artist, title)
	if !handled || pos < 0 {
		return nil, false
	}
	hash := strings.ToUpper(list[pos].hash)
	if !isHexString(hash) {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	albumID := kugouAlbumIDByHash(ctx, hash)
	if albumID == "" {
		return nil, false
	}
	tracks := kugouAlbumSongList(ctx, albumID)
	if len(tracks) == 0 {
		return nil, false
	}
	log.Printf("album prefetch: %q from kugou album %s (%d tracks)", album, albumID, len(tracks))
	return tracks, true
}

// kugouAlbumIDByHash 按文件 hash 问这首属于哪张专辑。查不到返回 ""。
func kugouAlbumIDByHash(ctx context.Context, hash string) string {
	kugouAlbumMu.Lock()
	if id, ok := kugouAlbumIDCache[hash]; ok {
		kugouAlbumMu.Unlock()
		return id
	}
	kugouAlbumMu.Unlock()
	var out struct {
		AlbumID json.Number `json:"albumid"`
	}
	u := "http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=" + neturl.QueryEscape(hash)
	if err := kugouGet(ctx, u, &out); err != nil {
		return ""
	}
	id := out.AlbumID.String()
	if id == "" || id == "0" {
		return ""
	}
	kugouAlbumMu.Lock()
	kugouAlbumIDCache[hash] = id
	kugouAlbumMu.Unlock()
	return id
}

// kugouAlbumSongList 取一张专辑的曲目表。area_code=1 必须带:不带时接口返回 status=1 但列表为空(实测)。
func kugouAlbumSongList(ctx context.Context, albumID string) []albumTrack {
	kugouAlbumMu.Lock()
	if v, ok := kugouAlbumCache[albumID]; ok {
		kugouAlbumMu.Unlock()
		return v
	}
	kugouAlbumMu.Unlock()
	var out struct {
		Data struct {
			Info []struct {
				Filename string  `json:"filename"`
				Duration float64 `json:"duration"` // 秒
			} `json:"info"`
		} `json:"data"`
	}
	u := "http://mobilecdn.kugou.com/api/v3/album/song?area_code=1&page=1&pagesize=100&albumid=" + neturl.QueryEscape(albumID)
	if err := kugouGet(ctx, u, &out); err != nil {
		return nil
	}
	tracks := make([]albumTrack, 0, len(out.Data.Info))
	for _, it := range out.Data.Info {
		artist, title := kugouUpcomingSplit(it.Filename)
		if title == "" {
			continue
		}
		tracks = append(tracks, albumTrack{title: title, artist: artist, duration: it.Duration})
	}
	if len(tracks) > 0 {
		kugouAlbumMu.Lock()
		kugouAlbumCache[albumID] = tracks
		kugouAlbumMu.Unlock()
	}
	return tracks
}
