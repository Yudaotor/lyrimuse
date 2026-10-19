package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"math"
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
//     `endTime`(毫秒)+ `text`,来源标着 LYRIC_FIND 或 MUSIX_MATCH,没有逐字、没有译文,也没有歌名。开头那句 `...` 是前奏占位。队列里还没播到的
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

// amazonPlaybackISRC:App 此刻报的 Amazon Music 当前曲目就是这首时(amazonCurrentASIN),它在本机目录缓存里的 ISRC。
// 只认当前曲目:amazonASINFor 那两条退路(队列、整份缓存的索引)按歌手 + 歌名认 ASIN,同名的另一版(删减版与不删减版、
// 单曲与专辑版)落在同一个位上,拿到的是另一条录音的号(09 章决策 225)。
func amazonPlaybackISRC(artist, title string) string {
	return amazonISRCForASIN(amazonCurrentASIN(artist, title))
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

// amazonQueueASINs:amazonUpcoming 交出去的那几首,歌名 + 歌手 → ASIN;amazonQueueAlbums 是同一个键下目录缓存里那一首的专辑名。
// 队列预解析的那几首解析歌词时靠它认身份。
var (
	amazonQueueMu     sync.Mutex
	amazonQueueASINs  = map[string]string{}
	amazonQueueAlbums = map[string]string{}
)

// amazonTrackIdentity:比对用的歌手 + 歌名,跟歌词缓存键同一套归一化(normEnrichTitle 剥掉 ` [Explicit]` 这类尾巴)——
// 目录里的歌名带着它,歌词解析拿到的是剥过的。
func amazonTrackIdentity(artist, title string) string {
	return loosenEnrichKey(artist) + "\x00" + loosenEnrichKey(normEnrichTitle(title))
}

// amazonASINFor:这首(系统报的歌手 / 歌名 / 专辑)在 Amazon Music 里的 ASIN。当前这首取 App 报的(noteAmazonCurrentTrack),
// 队列里的取 amazonUpcoming 记下的(两边都知道专辑时要对得上),都不是就取歌词缓存里记着的曲目页(amazonCachedASIN)。
// 认不出返回 ""。会取 enrichMu(经 amazonCachedASIN):调用方不能持着它。
func amazonASINFor(artist, title, album string) string {
	if asin := amazonCurrentASIN(artist, title); asin != "" {
		return asin
	}
	id := amazonTrackIdentity(artist, title)
	amazonQueueMu.Lock()
	asin, queued := amazonQueueASINs[id], amazonQueueAlbums[id]
	amazonQueueMu.Unlock()
	if asin != "" && (album == "" || queued == "" || amazonAlbumKey(album) == amazonAlbumKey(queued)) {
		return asin
	}
	return amazonCachedASIN(artist, title, album)
}

// amazonAlbumKey:比对专辑名用的写法,跟歌词缓存键里那一段同一套(cleanMediaTag,再按宽松键折平)。
func amazonAlbumKey(album string) string {
	return loosenEnrichKey(cleanMediaTag(album))
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

// amazonCachedASINs:用 Amazon Music 放过的歌,歌词缓存里记着它的曲目页(AmazonURL),按 amazonTrackIdentity 索引,同一个
// 歌手 + 歌名下记着每一条写法的专辑和 ASIN。手动搜索(另起的进程,没有常驻进程的时钟和队列)和补空 / 全量扫库
// (扫到的多半不是在放的那首)只能靠它认出这首。最多每 amazonCachedASINsTTL 从缓存重建一次。
var (
	amazonCachedASINsMu    sync.Mutex
	amazonCachedASINs      map[string][]amazonCachedTrack
	amazonCachedASINsBuilt time.Time
)

const amazonCachedASINsTTL = 30 * time.Second

// amazonCachedTrack:歌词缓存里一条记着 Amazon 曲目页的写法(键里的专辑段、曲目页里的 ASIN)。
type amazonCachedTrack struct {
	album, asin string
}

func amazonCachedASIN(artist, title, album string) string {
	now := time.Now()
	amazonCachedASINsMu.Lock()
	defer amazonCachedASINsMu.Unlock()
	if amazonCachedASINs == nil || now.Sub(amazonCachedASINsBuilt) >= amazonCachedASINsTTL {
		index := map[string][]amazonCachedTrack{}
		enrichMu.Lock()
		for key, e := range enrichCache {
			if asin := amazonASINFromTrackURL(e.AmazonURL); asin != "" {
				a, t, al := splitEnrichKey(key)
				id := amazonTrackIdentity(a, t)
				index[id] = append(index[id], amazonCachedTrack{album: al, asin: asin})
			}
		}
		enrichMu.Unlock()
		amazonCachedASINs, amazonCachedASINsBuilt = index, now
	}
	return pickAmazonCachedASIN(amazonCachedASINs[amazonTrackIdentity(artist, title)], album)
}

// pickAmazonCachedASIN:同一个歌手 + 歌名的几条写法里挑这一首的 ASIN。都是同一个 ASIN 就是它;不止一个(单曲与专辑版、
// 精选集、删减与不删减各是各的曲目)时只认专辑对得上的(amazonAlbumKey),对不上、或者对得上的几条也不是同一个就认不出:
// 同名的另一版时长、剪辑可能不同,拿它的本地歌词和目录信息,时间轴、专辑、时长都配错。结果跟几条的先后无关。见 09 章决策 255。
func pickAmazonCachedASIN(tracks []amazonCachedTrack, album string) string {
	if len(tracks) == 0 {
		return ""
	}
	if !slices.ContainsFunc(tracks, func(t amazonCachedTrack) bool { return t.asin != tracks[0].asin }) {
		return tracks[0].asin
	}
	want := amazonAlbumKey(album)
	found := ""
	for _, t := range tracks {
		if want == "" || amazonAlbumKey(t.album) != want {
			continue
		}
		if found != "" && found != t.asin {
			return ""
		}
		found = t.asin
	}
	return found
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
func amazonLocalLyricsFor(artist, title, album string) (lyricSourceResult, bool) {
	r, _, ok := amazonLocalLyrics(artist, title, album)
	return r, ok
}

// amazonLocalLyrics 同 amazonLocalLyricsFor,另带回这份正文是不是借来的(amazonLyricsBorrowedBy 非空):借来的
// 不置 identityFromLocalClient,不享受同源加权,跟各源按内容公平打分。
func amazonLocalLyrics(artist, title, album string) (r lyricSourceResult, borrowed, ok bool) {
	if !isNativeLyricSource(amazonLocalLyricsSource) {
		return lyricSourceResult{}, false, false
	}
	asin := amazonASINFor(artist, title, album)
	lrc, coarse, ok := amazonLyricsForASIN(asin)
	if !ok {
		return lyricSourceResult{}, false, false
	}
	r = lyricSourceResult{
		source: amazonLocalLyricsSource, lyr: lrc, matchTitle: title, matchArtist: artist,
		identityFromLocalClient: !coarse,
	}
	meta, hasMeta := amazonCatalog([]string{asin})[asin]
	if hasMeta {
		r.matchTitle, r.matchArtist, r.matchAlbum, r.srcDur = meta.Title, meta.Artist.Name, meta.albumName(), meta.durationSecs()
		r.matchCover = amazonJPEGImage(meta.Album.Image)
		if other := amazonLyricsBorrowedBy(asin, meta, lrc); other != "" {
			log.Printf("amazon: local lyrics of %s (%q) are word for word those of %s, a different song; no native-source bonus", asin, meta.Title, other)
			r.identityFromLocalClient, borrowed = false, true
		}
	}
	return r, borrowed, true
}

// amazonBorrowedLyricsMinDurationDiffSecs:两首歌名不同、时长差这么多以上,才认定是两首歌共用了一份正文。
const amazonBorrowedLyricsMinDurationDiffSecs = 3.0

// amazonLyricsBorrowedBy:这首(asin,目录记录 meta)的本地歌词正文,在 Hammer Cache 里一字不差地也挂在另一个 ASIN 上,
// 而那首去掉括号后歌名不同、时长差 amazonBorrowedLyricsMinDurationDiffSecs 以上 —— Amazon 把一首歌的词挂到了另一首上,
// 返回那首的「ASIN 歌名」,没有返回 ""。实例:「Khalil Fong - Ai!」(《唉!》,221s)挂的是同专辑「Love Love Love」
// (《爱爱爱》,213s)的词。歌词本身没有歌名字段,只能这样认。同一首歌的不同剪辑(Radio Edit 之类)歌名去括号后一样,不算。
//
// 两首都会被认成借来的:分不出正文原本是谁的,只撤同源加权,不丢候选,原主那首靠跨源共识照样能赢。
//
// 要整库扫一遍 Hammer Cache,结论按这首(ASIN、歌名、时长)+ 正文记下,Hammer Cache 和曲目目录两个库目录里的文件
// (名字、大小、修改时间)都没变就不再扫(amazonBorrowedMemo):一首歌的首次解析、先上屏、升级重试、手动搜索都会问到同一首。
func amazonLyricsBorrowedBy(asin string, meta amazonCatalogTrack, lrc string) string {
	dir := amazonHammerCacheDir()
	memoKey := strings.Join([]string{dir, asin, meta.Title, strconv.FormatFloat(meta.durationSecs(), 'f', -1, 64), lrc}, "\x00")
	stamp := ldbDirStamp(dir)
	if stamp != "" {
		stamp += "\x00" + ldbDirStamp(amazonLocalStorageDir())
	}
	if stamp != "" {
		amazonBorrowedMemoMu.Lock()
		m, ok := amazonBorrowedMemo[memoKey]
		amazonBorrowedMemoMu.Unlock()
		if ok && m.stamp == stamp {
			return m.other
		}
	}
	other := amazonLyricsBorrowedByScan(dir, asin, meta, lrc)
	if stamp != "" {
		amazonBorrowedMemoMu.Lock()
		if _, had := amazonBorrowedMemo[memoKey]; !had && len(amazonBorrowedMemo) >= amazonBorrowedMemoMax {
			clear(amazonBorrowedMemo)
		}
		amazonBorrowedMemo[memoKey] = amazonBorrowedVerdict{stamp: stamp, other: other}
		amazonBorrowedMemoMu.Unlock()
	}
	return other
}

// amazonBorrowedMemoMax:借词结论最多记几首。
const amazonBorrowedMemoMax = 32

type amazonBorrowedVerdict struct {
	stamp, other string
}

var (
	amazonBorrowedMemoMu sync.Mutex
	amazonBorrowedMemo   = map[string]amazonBorrowedVerdict{}
)

// ldbDirStamp:LevelDB 目录里各文件的名字、大小、修改时间拼成的指纹,库有写入就会变;读不了目录为 ""。
func ldbDirStamp(dir string) string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	var b strings.Builder
	for _, e := range ents {
		info, err := e.Info()
		if err != nil {
			continue
		}
		fmt.Fprintf(&b, "%s|%d|%d\n", e.Name(), info.Size(), info.ModTime().UnixNano())
	}
	return b.String()
}

// amazonLyricsBorrowedByScan:amazonLyricsBorrowedBy 真去扫库的那一步。
func amazonLyricsBorrowedByScan(dir, asin string, meta amazonCatalogTrack, lrc string) string {
	prefix := asin + "-"
	var others []string
	for k, v := range ldbScan(dir, func([]byte) bool { return true }) {
		other, _, found := strings.Cut(k, "-")
		if v.deleted || !found || strings.HasPrefix(k, prefix) || slices.Contains(others, other) {
			continue
		}
		if o, _, ok := amazonLyricsLRC(v.value); ok && o == lrc {
			others = append(others, other)
		}
	}
	if len(others) == 0 {
		return ""
	}
	title := loosenEnrichKey(normEnrichTitle(stripParens(meta.Title)))
	for other, m := range amazonCatalog(others) {
		if loosenEnrichKey(normEnrichTitle(stripParens(m.Title))) == title {
			continue
		}
		if math.Abs(m.durationSecs()-meta.durationSecs()) < amazonBorrowedLyricsMinDurationDiffSecs {
			continue
		}
		return other + " " + strconv.Quote(m.Title)
	}
	return ""
}

// amazonProvisionalLyrics:首次解析开跑时先上屏的那份(见 resolveEnrichAsync)。只给正用 Amazon Music 放着的这首
// (isNewTrack),而且它本机缓存里有这首的歌词;正文是借来的(amazonLyricsBorrowedBy)不先上屏。别的情况返回 false。
func amazonProvisionalLyrics(isNewTrack bool, bundleID, artist, title, album string) (enrichEntry, bool) {
	if !isNewTrack || bundleID != amazonMusicBundleID {
		return enrichEntry{}, false
	}
	r, borrowed, ok := amazonLocalLyrics(artist, title, album)
	if !ok || borrowed {
		return enrichEntry{}, false
	}
	return enrichEntry{Lyrics: bt(r.lyr), LyricsSource: amazonLocalLyricsSource}, true
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
func amazonLocalLyricsAvailable(bundleID, artist, title, album string) bool {
	if bundleID != amazonMusicBundleID {
		return false
	}
	asin := amazonASINFor(artist, title, album)
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
		id := amazonTrackIdentity(t.Artist.Name, t.Title)
		amazonQueueASINs[id], amazonQueueAlbums[id] = a, t.albumName()
	}
	// 只留最近这一批:队列窗口只有两三首,旧的对照留着没有用。
	if len(amazonQueueASINs) > 32 {
		amazonQueueASINs, amazonQueueAlbums = map[string]string{}, map[string]string{}
		for _, a := range asins {
			if t, ok := meta[a]; ok {
				id := amazonTrackIdentity(t.Artist.Name, t.Title)
				amazonQueueASINs[id], amazonQueueAlbums[id] = a, t.albumName()
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
