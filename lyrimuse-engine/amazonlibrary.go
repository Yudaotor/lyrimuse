package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Amazon Music 客户端本机数据:目录缓存、本地歌词、播放队列。都是只读,读不动当没有。
//
//   - 目录缓存:`Data/Local Storage`(LevelDB),键 `*.MusicContent.CacheEntry.PrimeCatalog_KATANA_<ASIN>`,值是 boost
//     序列化归档,中间夹一个 JSON 对象(title、artist.name、album.name、duration 秒数字符串、hasLyrics)。多个歌手在
//     artist.name 里已经用 ` & ` 连好,跟它报给系统 Now Playing 的写法一样。
//   - 本地歌词:`Data/Hammer Cache`(LevelDB),键 `<ASIN>-<市场 ID>`,值同样是 boost 归档夹 JSON:`lyrics.lines[]` 逐行 `startTime` /
//     `endTime`(毫秒)+ `text`,来源标着 LYRIC_FIND,没有逐字、没有译文。开头那句 `...` 是前奏占位。队列里还没播到的
//     几首它也提前拉好了。
//   - 播放队列:日志里的 `updateQueue` 行(见 amazonLogTail),是「当前这首 + 后两首」的滑动窗口。
//
// 本地歌词**不是歌词源**(同 KKBOX 本地歌词,见 kkboxlyrics.go 头注):不能按歌名搜,只在正用 Amazon Music 放歌时读,
// 不进源清单、没有开关。players.json 里 Amazon Music 的 nativeLyricSource 填 amazonLocalLyricsSource,享受同源加权。
// 身份靠 ASIN(当前这首来自 App 读日志认出的曲目标识,队列里的来自 amazonUpcoming 记下的对照),不靠歌名猜。

// amazonLocalLyricsSource:Amazon Music 本地歌词那份候选的来源名。
const amazonLocalLyricsSource = "amazon"

// amazonLyricsMinLines:少于这么多句带时间的不算有歌词。
const amazonLyricsMinLines = 3

var (
	amazonLocalStorageOverride string
	amazonHammerCacheOverride  string
)

func amazonMusicDataPath(sub string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Amazon Music", "Data", sub)
}

func amazonLocalStorageDir() string {
	if amazonLocalStorageOverride != "" {
		return amazonLocalStorageOverride
	}
	return amazonMusicDataPath("Local Storage")
}

func amazonHammerCacheDir() string {
	if amazonHammerCacheOverride != "" {
		return amazonHammerCacheOverride
	}
	return amazonMusicDataPath("Hammer Cache")
}

// ---- 目录缓存 ----

type amazonCatalogTrack struct {
	Title     string `json:"title"`
	Duration  string `json:"duration"`
	HasLyrics bool   `json:"hasLyrics"`
	Artist    struct {
		Name string `json:"name"`
		ASIN string `json:"asin"`
	} `json:"artist"`
	Album struct {
		Name  string `json:"name"`
		Title string `json:"title"`
		Image string `json:"image"`
		ASIN  string `json:"asin"`
	} `json:"album"`
}

func (t amazonCatalogTrack) albumName() string {
	if t.Album.Name != "" {
		return t.Album.Name
	}
	return t.Album.Title
}

func (t amazonCatalogTrack) durationSecs() float64 {
	v, _ := strconv.ParseFloat(t.Duration, 64)
	return v
}

// amazonFirstJSONObject 从一段二进制里取出第一个 JSON 对象(boost 归档里夹着的那个)。
func amazonFirstJSONObject(raw []byte, v any) bool {
	i := bytes.IndexByte(raw, '{')
	if i < 0 {
		return false
	}
	return json.NewDecoder(bytes.NewReader(raw[i:])).Decode(v) == nil
}

// amazonCatalogKeyPrefix:目录缓存里一首的键是它加上 ASIN。
const amazonCatalogKeyPrefix = "*.MusicContent.CacheEntry.PrimeCatalog_KATANA_"

// amazonCatalog 查一组 ASIN 的目录缓存。查不到的不在结果里。
func amazonCatalog(asins []string) map[string]amazonCatalogTrack {
	keys := make([][]byte, 0, len(asins))
	for _, a := range asins {
		keys = append(keys, []byte(amazonCatalogKeyPrefix+a))
	}
	out := map[string]amazonCatalogTrack{}
	for k, v := range ldbGet(amazonLocalStorageDir(), keys) {
		var t amazonCatalogTrack
		if !amazonFirstJSONObject(v, &t) || t.Title == "" || t.Artist.Name == "" {
			continue
		}
		out[strings.TrimPrefix(k, amazonCatalogKeyPrefix)] = t
	}
	return out
}

// ---- 专辑页 / 歌单页的曲目表 ----

// amazonLookupTrack:专辑页、歌单页那份曲目表里的一首。这份表跟单曲的目录记录存在同一组键下(键尾是专辑 / 歌单的
// ASIN),值里是 `albumList[].tracks[]` / `playlistList[].tracks[]`。单曲那份目录记录不带 ISRC,只有这里带。
type amazonLookupTrack struct {
	ASIN       string `json:"asin"`
	GlobalASIN string `json:"globalAsin"`
	ISRC       string `json:"isrc"`
}

type amazonLookupBody struct {
	AlbumList []struct {
		Tracks []amazonLookupTrack `json:"tracks"`
	} `json:"albumList"`
	PlaylistList []struct {
		Tracks []amazonLookupTrack `json:"tracks"`
	} `json:"playlistList"`
}

// amazonISRCIndexTTL:曲目 ASIN → ISRC 的索引最多隔这么久从目录缓存重建一次(重建要把目录缓存整个读一遍)。
const amazonISRCIndexTTL = 30 * time.Second

var (
	amazonISRCIndexMu    sync.Mutex
	amazonISRCIndex      map[string]string
	amazonISRCIndexBuilt time.Time
)

// amazonISRCForASIN:这首(曲目 ASIN)的 ISRC,取自本机缓存里打开 / 播放过的专辑页、歌单页那份曲目表;没见过返回 ""。
// 从电台、单曲推荐直接放的歌多半没有。
func amazonISRCForASIN(asin string) string {
	if asin == "" {
		return ""
	}
	now := time.Now()
	amazonISRCIndexMu.Lock()
	defer amazonISRCIndexMu.Unlock()
	if amazonISRCIndex == nil || now.Sub(amazonISRCIndexBuilt) >= amazonISRCIndexTTL {
		amazonISRCIndex, amazonISRCIndexBuilt = buildAmazonISRCIndex(), now
	}
	return amazonISRCIndex[asin]
}

// buildAmazonISRCIndex 扫一遍目录缓存,把专辑页、歌单页曲目表里每首的 ASIN 映到它的 ISRC(格式不对的不收,见 normalizeISRC)。
func buildAmazonISRCIndex() map[string]string {
	prefix := []byte(amazonCatalogKeyPrefix)
	out := map[string]string{}
	add := func(tracks []amazonLookupTrack) {
		for _, t := range tracks {
			code := normalizeISRC(t.ISRC)
			if code == "" {
				continue
			}
			for _, asin := range []string{t.ASIN, t.GlobalASIN} {
				if asin != "" {
					out[asin] = code
				}
			}
		}
	}
	for _, v := range ldbScan(amazonLocalStorageDir(), func(k []byte) bool { return bytes.HasPrefix(k, prefix) }) {
		if v.deleted || !bytes.Contains(v.value, []byte(`"isrc"`)) {
			continue
		}
		var body amazonLookupBody
		if !amazonFirstJSONObject(v.value, &body) {
			continue
		}
		for _, a := range body.AlbumList {
			add(a.Tracks)
		}
		for _, p := range body.PlaylistList {
			add(p.Tracks)
		}
	}
	return out
}

// amazonPlaybackISRC:这首(系统报的歌手 / 歌名)在 Amazon Music 里的 ISRC,ASIN 怎么认见 amazonASINFor。
// 会取 enrichMu(经 amazonASINFor):调用方不能持着它。
func amazonPlaybackISRC(artist, title string) string {
	return amazonISRCForASIN(amazonASINFor(artist, title))
}

// ---- 本地歌词 ----

type amazonLyricsBody struct {
	Lyrics struct {
		Lines []struct {
			StartTime int64  `json:"startTime"`
			EndTime   int64  `json:"endTime"`
			Text      string `json:"text"`
		} `json:"lines"`
	} `json:"lyrics"`
}

// amazonLyricsLRC 把本地歌词换成 LRC。前奏占位 `...` 和空句去掉;带时间的句子不够 amazonLyricsMinLines 返回 ok=false。
// coarse:每一句都只到整秒(不享受同源加权,同 KKBOX)。
func amazonLyricsLRC(body []byte) (lrc string, coarse, ok bool) {
	var r amazonLyricsBody
	if !amazonFirstJSONObject(body, &r) {
		return "", false, false
	}
	var b strings.Builder
	timed := 0
	coarse = true
	for _, l := range r.Lyrics.Lines {
		text := strings.TrimSpace(l.Text)
		if text == "" || text == "..." || text == "…" || l.StartTime < 0 {
			continue
		}
		timed++
		if l.StartTime%1000 != 0 {
			coarse = false
		}
		cs := l.StartTime / 10
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", cs/6000, cs/100%60, cs%100, text)
	}
	if timed < amazonLyricsMinLines {
		return "", false, false
	}
	return b.String(), coarse, true
}

// amazonLyricsForASIN 在 Hammer Cache 里找这个 ASIN 的歌词(键带市场 ID,按前缀找)。
func amazonLyricsForASIN(asin string) (lrc string, coarse, ok bool) {
	if asin == "" {
		return "", false, false
	}
	prefix := []byte(asin + "-")
	var newest ldbValue
	found := false
	for _, v := range ldbScan(amazonHammerCacheDir(), func(k []byte) bool { return bytes.HasPrefix(k, prefix) }) {
		if !v.deleted && (!found || v.seq > newest.seq) {
			newest, found = v, true
		}
	}
	if !found {
		return "", false, false
	}
	return amazonLyricsLRC(newest.value)
}

// amazonQueueASINs:amazonUpcoming 交出去的那几首,歌名 + 歌手 → ASIN。队列预解析的那几首解析歌词时靠它认身份。
var (
	amazonQueueMu    sync.Mutex
	amazonQueueASINs = map[string]string{}
)

// amazonTrackIdentity:比对用的歌手 + 歌名,跟歌词缓存键同一套归一化(normEnrichTitle 剥掉 ` [Explicit]` 这类尾巴)——
// 目录里的歌名带着它,歌词解析拿到的是剥过的。
func amazonTrackIdentity(artist, title string) string {
	return loosenEnrichKey(artist) + "\x00" + loosenEnrichKey(normEnrichTitle(title))
}

// amazonASINFor:这首(系统报的歌手 / 歌名)在 Amazon Music 里的 ASIN。当前这首取 App 报的(noteAmazonCurrentTrack),
// 队列里的取 amazonUpcoming 记下的,都不是就取歌词缓存里记着的曲目页(amazonCachedASIN)。认不出返回 ""。
// 会取 enrichMu(经 amazonCachedASIN):调用方不能持着它。
func amazonASINFor(artist, title string) string {
	if asin := amazonCurrentASIN(artist, title); asin != "" {
		return asin
	}
	amazonQueueMu.Lock()
	asin := amazonQueueASINs[amazonTrackIdentity(artist, title)]
	amazonQueueMu.Unlock()
	if asin != "" {
		return asin
	}
	return amazonCachedASIN(artist, title)
}

// amazonCurrentASIN:App 此刻报的当前曲目就是这首(按 amazonTrackIdentity 比)时它的 ASIN,否则 ""。
func amazonCurrentASIN(artist, title string) string {
	amazonCurrentMu.Lock()
	cur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	if cur.trackID == "" || amazonTrackIdentity(cur.artist, cur.title) != amazonTrackIdentity(artist, title) {
		return ""
	}
	if asin, ok := strings.CutPrefix(cur.trackID, "asin://"); ok {
		return asin
	}
	return ""
}

// amazonCachedASINs:用 Amazon Music 放过的歌,歌词缓存里记着它的曲目页(AmazonURL),从中认出的 ASIN,按
// amazonTrackIdentity 索引。手动搜索(另起的进程,没有常驻进程的时钟和队列)和补空 / 全量扫库(扫到的多半不是
// 在放的那首)只能靠它认出这首。最多每 amazonCachedASINsTTL 从缓存重建一次。
var (
	amazonCachedASINsMu    sync.Mutex
	amazonCachedASINs      map[string]string
	amazonCachedASINsBuilt time.Time
)

const amazonCachedASINsTTL = 30 * time.Second

func amazonCachedASIN(artist, title string) string {
	now := time.Now()
	amazonCachedASINsMu.Lock()
	defer amazonCachedASINsMu.Unlock()
	if amazonCachedASINs == nil || now.Sub(amazonCachedASINsBuilt) >= amazonCachedASINsTTL {
		index := map[string]string{}
		enrichMu.Lock()
		for key, e := range enrichCache {
			if asin := amazonASINFromTrackURL(e.AmazonURL); asin != "" {
				a, t, _ := splitEnrichKey(key)
				index[amazonTrackIdentity(a, t)] = asin
			}
		}
		enrichMu.Unlock()
		amazonCachedASINs, amazonCachedASINsBuilt = index, now
	}
	return amazonCachedASINs[amazonTrackIdentity(artist, title)]
}

// amazonASINFromTrackURL:amazonTrackURL 的反向,不是那个形状返回 ""。
func amazonASINFromTrackURL(u string) string {
	asin, ok := strings.CutPrefix(u, "https://music.amazon.com/tracks/")
	if !ok || amazonTrackURL("asin://"+asin) != u {
		return ""
	}
	return asin
}

// amazonLocalLyricsFor 给歌词检索用:正在用 Amazon Music 放歌时才读,换成一份跟各歌词源同形的原始应答。
func amazonLocalLyricsFor(artist, title string) (lyricSourceResult, bool) {
	if !isNativeLyricSource(amazonLocalLyricsSource) {
		return lyricSourceResult{}, false
	}
	asin := amazonASINFor(artist, title)
	lrc, coarse, ok := amazonLyricsForASIN(asin)
	if !ok {
		return lyricSourceResult{}, false
	}
	r := lyricSourceResult{
		source: amazonLocalLyricsSource, lyr: lrc, matchTitle: title, matchArtist: artist,
		identityFromLocalClient: !coarse,
	}
	if meta, ok := amazonCatalog([]string{asin})[asin]; ok {
		r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur = meta.Title, meta.Artist.Name, meta.albumName(), meta.durationSecs()
		r.matchCover = amazonJPEGImage(meta.Album.Image)
	}
	return r, true
}

// amazonProvisionalLyrics:首次解析开跑时先上屏的那份(见 resolveEnrichAsync)。只给正用 Amazon Music 放着的这首
// (isNewTrack),而且它本机缓存里有这首的歌词;别的情况返回 false。
func amazonProvisionalLyrics(isNewTrack bool, bundleID, artist, title string) (enrichEntry, bool) {
	if !isNewTrack || bundleID != amazonMusicBundleID {
		return enrichEntry{}, false
	}
	r, ok := amazonLocalLyricsFor(artist, title)
	if !ok {
		return enrichEntry{}, false
	}
	return enrichEntry{Lyrics: r.lyr, LyricsSource: amazonLocalLyricsSource}, true
}

// amazonLyricsAvailableTTL:同一首记多久。trackEnrichment 在一首歌的播放期间会被反复调用,每次都扫一遍 Hammer Cache
// 不值当;Amazon Music 开播前就把词拉好了,30 秒内问到的都是同一个答案。
const amazonLyricsAvailableTTL = 30 * time.Second

var (
	amazonLyricsAvailMu   sync.Mutex
	amazonLyricsAvailMemo = map[string]struct {
		at time.Time
		ok bool
	}{}
)

// amazonLocalLyricsAvailable:正用 Amazon Music 放的这首,本地现在有没有它的词(见 amazonLyricsWorthRecheck)。
func amazonLocalLyricsAvailable(bundleID, artist, title string) bool {
	if bundleID != amazonMusicBundleID {
		return false
	}
	asin := amazonASINFor(artist, title)
	if asin == "" {
		return false
	}
	now := time.Now()
	amazonLyricsAvailMu.Lock()
	if m, ok := amazonLyricsAvailMemo[asin]; ok && now.Sub(m.at) < amazonLyricsAvailableTTL {
		amazonLyricsAvailMu.Unlock()
		return m.ok
	}
	amazonLyricsAvailMu.Unlock()
	_, _, ok := amazonLyricsForASIN(asin)
	amazonLyricsAvailMu.Lock()
	for k, m := range amazonLyricsAvailMemo {
		if now.Sub(m.at) >= amazonLyricsAvailableTTL {
			delete(amazonLyricsAvailMemo, k)
		}
	}
	amazonLyricsAvailMemo[asin] = struct {
		at time.Time
		ok bool
	}{now, ok}
	amazonLyricsAvailMu.Unlock()
	return ok
}

// amazonLyricsRechecked:这次进程里已经为 Amazon 本地歌词重来过的条目。只在 enrichMu 里读写。
var amazonLyricsRechecked = map[string]bool{}

// amazonLyricsRecheckOnce:同 kkboxLyricsRecheckOnce。调用方持有 enrichMu。
func amazonLyricsRecheckOnce(key string) bool {
	if amazonLyricsRechecked[key] {
		return false
	}
	amazonLyricsRechecked[key] = true
	return true
}

// amazonLyricsWorthRecheck:同 kkboxLyricsWorthRecheck。条目当初不是用 Amazon Music 放着解析的(没见过这份候选),
// 现在正用它放、本地有词 → 值得重来一次(retryLyricsUpgrade,分数严格更高才替换)。
func amazonLyricsWorthRecheck(e enrichEntry, bundleID string, pinned, autoUpgrade, available bool) bool {
	if bundleID != amazonMusicBundleID || !autoUpgrade || pinned || e.ManualLyrics || e.Instrumental || !available {
		return false
	}
	if slices.Contains(e.LyricsSourcesSeen, amazonLocalLyricsSource) || slices.Contains(e.LyricsSourcesResponded, amazonLocalLyricsSource) {
		return false
	}
	if e.LyricsDecision != nil && slices.Contains(e.LyricsDecision.SourcesResponded, amazonLocalLyricsSource) {
		return false
	}
	return e.LyricsRetryCount < lyricsRetryMaxAttempts
}

// ---- 队列 ----

// parseAmazonQueueLine 解析 `updateQueue` 行:`UriList = asin-//A, asin-//B, asin-//C , function = updateQueue`。
// 返回 `asin://…` / `podcast://…` 标识;不是这一行返回 ok=false。
func parseAmazonQueueLine(line string) ([]string, bool) {
	if !strings.Contains(line, "function = updateQueue") {
		return nil, false
	}
	i := strings.Index(line, "UriList = ")
	if i < 0 {
		return nil, false
	}
	rest := line[i+len("UriList = "):]
	if j := strings.Index(rest, " , function = updateQueue"); j >= 0 {
		rest = rest[:j]
	}
	var out []string
	for _, u := range strings.Split(rest, ",") {
		u = strings.TrimSpace(u)
		if a, ok := strings.CutPrefix(u, "asin-//"); ok && a != "" {
			out = append(out, "asin://"+a)
		} else if p, ok := strings.CutPrefix(u, "podcast-//"); ok && p != "" {
			out = append(out, "podcast://"+p)
		}
	}
	return out, true
}

// amazonUpcoming:队列窗口里当前这首后面那几首。窗口第一首必须是日志里正在放的那首、而且就是播放器报的这首,
// 否则拿不准(用户刚点了别的、日志没对上),退回同专辑预取。歌名 / 歌手 / 专辑 / 时长从目录缓存查,查不到的不交。
// 一首都查不到时:放的是电台(云端队列)就不预取 —— 同专辑的歌放不到,整张专辑解析一遍只会跟正在放的那首抢歌词源;
// 歌单 / 专辑才退回同专辑预取。
func amazonUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	amazonCurrentMu.Lock()
	cur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	if cur.artist != artist || cur.title != title || cur.trackID == "" {
		log.Printf("amazon music upcoming: the log does not confirm the current track; falling back to album prefetch")
		return nil, false
	}
	queue, cloudQueue := amazonQueueWindow()
	if len(queue) < 2 || queue[0] != cur.trackID {
		log.Printf("amazon music upcoming: the queue window does not start at the current track; falling back to album prefetch")
		return nil, false
	}
	var asins []string
	for _, id := range queue[1:] {
		if a, ok := strings.CutPrefix(id, "asin://"); ok {
			asins = append(asins, a)
		}
	}
	if len(asins) > n {
		asins = asins[:n]
	}
	meta := amazonCatalog(asins)
	var out []upcomingTrack
	amazonQueueMu.Lock()
	for _, a := range asins {
		t, ok := meta[a]
		if !ok {
			continue
		}
		out = append(out, upcomingTrack{artist: t.Artist.Name, title: t.Title, album: t.albumName(), duration: t.durationSecs()})
		amazonQueueASINs[amazonTrackIdentity(t.Artist.Name, t.Title)] = a
	}
	// 只留最近这一批:队列窗口只有两三首,旧的对照留着没有用。
	if len(amazonQueueASINs) > 32 {
		amazonQueueASINs = map[string]string{}
		for _, a := range asins {
			if t, ok := meta[a]; ok {
				amazonQueueASINs[amazonTrackIdentity(t.Artist.Name, t.Title)] = a
			}
		}
	}
	amazonQueueMu.Unlock()
	if len(out) == 0 && cloudQueue {
		log.Printf("amazon music upcoming: none of the queued tracks is in the local catalog cache; playing a station, skipping album prefetch")
		return nil, true
	}
	if len(out) == 0 {
		log.Printf("amazon music upcoming: none of the queued tracks is in the local catalog cache; falling back to album prefetch")
		return nil, false
	}
	return out, true
}
