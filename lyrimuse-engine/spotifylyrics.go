package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Spotify 本地歌词:Spotify 桌面客户端自己拉过的歌词,读它内嵌浏览器的 HTTP 缓存,不联网、不要登录。
//
// 定位是 Musixmatch 的备用管道。Spotify 歌词接口 `spclient.wg.spotify.com/color-lyrics/v2/track/<id>` 的
// 应答里 `provider` 多是 `MusixMatch`,数据跟 musixmatch.go 那一路同源;那一路只靠匿名 token,token 拿不到时这份
// 还在。跟 KKBOX 本地歌词(kkboxlyrics.go)一样**不是歌词源**:不能按歌名去搜,只有 Spotify 自己显示过歌词的
// 歌才有(打开歌词面板或「正在播放」视图时它才去拉),所以不进源清单、设置里没有开关。Spotify 没有配同源歌词,
// 这份按普通候选跟各源公平打分,不加同源权重。
//
// 缓存是 Chromium 的 Simple Cache(`Cache_Data/<16 位十六进制>_0`):文件头 24 字节(magic、版本、key 长度、
// key 哈希),紧跟着 key(`1/0/_dk_https://spotify.com https://spotify.com <请求 URL>`),再往后是响应体原样
// (本机实测是 gzip)。文件名由 key 的 SHA-1 算出来,但 key 里带着专辑封面图的 ID,光凭曲目 ID 算不出文件名,
// 所以按文件头建一份 曲目 ID → 文件 的索引。本机实测 7507 个条目、212 首歌词,读一遍文件头 1.15 秒(已在系统
// 缓存里),而一次性的 search-lyrics 子进程每次都是冷的:超过 spotifyLyricsMaxEntryBytes 的不读(歌词条目实测
// 4.8~7.4KB),索引连同「读到哪个修改时间为止」一起落盘(lyrimuse-spotify-lyrics-index.json),新进程只读比它新的文件。
//
// 应答体:`lyrics.syncType`(`LINE_SYNCED` 才用)、`lyrics.lines[].startTimeMs`(字符串,毫秒)与 `words`,
// 间奏行的 `words` 是 `♪`。本机 5 份全是逐行、没有逐字(`syllables` 为空)。
//
// 曲目 ID 取自换曲时记下的那个(spotifyTrackIDHintFor),没有就用歌词缓存条目里存的 spotify_track_id。
// 候选的歌名 / 歌手 / 专辑 / 时长取 Spotify 自己元数据库里的(spotifyResolveMeta),取不到就用本地这首的。
// 只读,读不动当没有。

// spotifyLocalLyricsSource:这份候选的来源名(歌词缓存的 lyrics_source、决策记录、界面上的来源都用它)。
const spotifyLocalLyricsSource = "spotify"

const (
	// spotifySimpleCacheMagic:Simple Cache 条目文件头的 magic(小端)。
	spotifySimpleCacheMagic uint64 = 0xfcfb6d1ba7725c30
	// spotifyLyricsHeadBytes:建索引时每个文件读多少字节(文件头 + key)。
	spotifyLyricsHeadBytes = 4096
	// spotifyLyricsMaxFileBytes:歌词条目文件的读取上限。实测 6KB 上下。
	spotifyLyricsMaxFileBytes = 2 << 20
	// spotifyLyricsMaxEntryBytes:建索引时比这大的文件不读文件头(图片、脚本这类),歌词条目实测 4.8~7.4KB。
	spotifyLyricsMaxEntryBytes = 64 << 10
	// spotifyLyricsRescanMin:两次扫目录至少隔多久。
	spotifyLyricsRescanMin = 5 * time.Second
	// spotifyLyricsMinLines:少于这么多句带时间的不算有歌词。
	spotifyLyricsMinLines = 3
	// spotifyLyricsParserName:parserdrift.go 里这条路径的名字。
	spotifyLyricsParserName = "spotify-lyrics-cache"
)

var spotifyLyricsKeyRe = regexp.MustCompile(`https://spclient\.wg\.spotify\.com/color-lyrics/v2/track/([0-9A-Za-z]{22})/`)

// spotifyLyricsCacheDirOverride 让单测指定缓存目录;空 = 本机 Spotify 的。
var spotifyLyricsCacheDirOverride string

// spotifyLyricsIndexPathOverride 让单测指定索引文件;指定了缓存目录而没指定它时不落盘。
var spotifyLyricsIndexPathOverride string

func spotifyLyricsIndexPath() string {
	if spotifyLyricsIndexPathOverride != "" {
		return spotifyLyricsIndexPathOverride
	}
	if spotifyLyricsCacheDirOverride != "" || configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-spotify-lyrics-index.json")
}

// spotifyLyricsIndexFile:落盘的索引。Watermark 是读过文件头的文件里最新的修改时间(纳秒),比它旧、又不在
// Tracks 里的文件就是没有歌词的,不必再读。
type spotifyLyricsIndexFile struct {
	Dir       string                        `json:"dir"`
	Watermark int64                         `json:"watermark"`
	Tracks    map[string]spotifyIndexedFile `json:"tracks"`
}

type spotifyIndexedFile struct {
	Name string `json:"name"`
	Mod  int64  `json:"mod"`
}

func spotifyLyricsCacheDir() string {
	if spotifyLyricsCacheDirOverride != "" {
		return spotifyLyricsCacheDirOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Caches/com.spotify.client/Browser/Cache/Cache_Data")
}

type spotifyLyricsFile struct {
	name string
	mod  time.Time
}

var (
	spotifyLyricsMu        sync.Mutex
	spotifyLyricsDir       string
	spotifyLyricsIndex     = map[string]spotifyLyricsFile{} // 曲目 ID → 最新那份
	spotifyLyricsSeenFiles = map[string]bool{}              // 看过的文件名
	spotifyLyricsScannedAt time.Time
	spotifyLyricsWatermark time.Time
)

// spotifyLyricsFileFor 查这首在缓存里的歌词文件。调用方不持有任何锁。
func spotifyLyricsFileFor(trackID string) (string, bool) {
	spotifyLyricsMu.Lock()
	defer spotifyLyricsMu.Unlock()
	dir := spotifyLyricsCacheDir()
	if dir == "" {
		return "", false
	}
	if dir != spotifyLyricsDir {
		spotifyLyricsDir = dir
		spotifyLyricsIndex = map[string]spotifyLyricsFile{}
		spotifyLyricsSeenFiles = map[string]bool{}
		spotifyLyricsScannedAt = time.Time{}
		spotifyLyricsWatermark = time.Time{}
		spotifyLoadLyricsIndexLocked(dir)
	}
	if time.Since(spotifyLyricsScannedAt) >= spotifyLyricsRescanMin {
		spotifyLyricsScannedAt = time.Now()
		spotifyScanLyricsCacheLocked(dir)
	}
	f, ok := spotifyLyricsIndex[trackID]
	if !ok {
		return "", false
	}
	return filepath.Join(dir, f.name), true
}

// spotifyScanLyricsCacheLocked 读新出现的文件的文件头,补进索引;已经不在的文件从索引里拿掉。有变化就落盘。
func spotifyScanLyricsCacheLocked(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	present := make(map[string]bool, len(entries))
	badMagic, read := 0, 0
	changed := false
	watermark := spotifyLyricsWatermark
	for _, de := range entries {
		name := de.Name()
		if !strings.HasSuffix(name, "_0") || de.IsDir() {
			continue
		}
		present[name] = true
		if spotifyLyricsSeenFiles[name] {
			continue
		}
		spotifyLyricsSeenFiles[name] = true
		info, err := de.Info()
		if err != nil || info.Size() > spotifyLyricsMaxEntryBytes {
			continue
		}
		// 上次读到过这个时刻,比它旧、又不在索引里的就是没有歌词的。
		if !info.ModTime().After(spotifyLyricsWatermark) {
			continue
		}
		head, err := readFileHead(filepath.Join(dir, name), spotifyLyricsHeadBytes)
		if err != nil {
			continue
		}
		read++
		if info.ModTime().After(watermark) {
			watermark = info.ModTime()
		}
		key, ok := spotifySimpleCacheKey(head)
		if !ok {
			badMagic++
			continue
		}
		m := spotifyLyricsKeyRe.FindStringSubmatch(key)
		if m == nil {
			continue
		}
		if cur, ok := spotifyLyricsIndex[m[1]]; !ok || info.ModTime().After(cur.mod) {
			spotifyLyricsIndex[m[1]] = spotifyLyricsFile{name: name, mod: info.ModTime()}
			changed = true
		}
	}
	for name := range spotifyLyricsSeenFiles {
		if !present[name] {
			delete(spotifyLyricsSeenFiles, name)
		}
	}
	for id, f := range spotifyLyricsIndex {
		if !present[f.name] {
			delete(spotifyLyricsIndex, id)
			changed = true
		}
	}
	if watermark.After(spotifyLyricsWatermark) {
		spotifyLyricsWatermark = watermark
		changed = true
	}
	// 读到的文件头全都不是 Simple Cache 的格式:Chromium 换了缓存格式。
	if read > 0 && badMagic == read {
		noteParserUnrecognized(spotifyLyricsParserName, fmt.Sprintf("%d cache entries, none with the simple cache header", read))
	}
	if changed {
		spotifySaveLyricsIndexLocked(dir)
	}
}

// spotifyLoadLyricsIndexLocked 读回落盘的索引(只认同一个缓存目录的)。调用方持有 spotifyLyricsMu。
func spotifyLoadLyricsIndexLocked(dir string) {
	path := spotifyLyricsIndexPath()
	if path == "" {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f spotifyLyricsIndexFile
	if json.Unmarshal(raw, &f) != nil || f.Dir != dir {
		return
	}
	for id, t := range f.Tracks {
		spotifyLyricsIndex[id] = spotifyLyricsFile{name: t.Name, mod: time.Unix(0, t.Mod)}
	}
	spotifyLyricsWatermark = time.Unix(0, f.Watermark)
}

// spotifySaveLyricsIndexLocked 落盘索引。调用方持有 spotifyLyricsMu。
func spotifySaveLyricsIndexLocked(dir string) {
	path := spotifyLyricsIndexPath()
	if path == "" {
		return
	}
	f := spotifyLyricsIndexFile{Dir: dir, Watermark: spotifyLyricsWatermark.UnixNano(), Tracks: map[string]spotifyIndexedFile{}}
	for id, t := range spotifyLyricsIndex {
		f.Tracks[id] = spotifyIndexedFile{Name: t.name, Mod: t.mod.UnixNano()}
	}
	raw, err := json.Marshal(f)
	if err != nil {
		return
	}
	_ = writeFileAtomic(path, raw)
}

func readFileHead(path string, n int) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, n)
	got, err := io.ReadFull(f, buf)
	if err != nil && err != io.ErrUnexpectedEOF {
		return nil, err
	}
	return buf[:got], nil
}

// spotifySimpleCacheKey 从条目文件开头取出 key。不是 Simple Cache 的文件头返回 ok=false。纯函数。
func spotifySimpleCacheKey(b []byte) (string, bool) {
	if len(b) < 24 || binary.LittleEndian.Uint64(b[0:8]) != spotifySimpleCacheMagic {
		return "", false
	}
	n := int(binary.LittleEndian.Uint32(b[12:16]))
	if n <= 0 || 24+n > len(b) {
		return "", false
	}
	return string(b[24 : 24+n]), true
}

// spotifyLyricsBody 取条目文件里 key 之后的响应体并解压。gzip 与未压缩的 JSON 认得,其余返回 ok=false。纯函数。
func spotifyLyricsBody(file []byte) ([]byte, bool) {
	key, ok := spotifySimpleCacheKey(file)
	if !ok {
		return nil, false
	}
	rest := file[24+len(key):]
	switch {
	case len(rest) >= 2 && rest[0] == 0x1f && rest[1] == 0x8b:
		zr, err := gzip.NewReader(bytes.NewReader(rest))
		if err != nil {
			return nil, false
		}
		zr.Multistream(false)
		out, err := io.ReadAll(io.LimitReader(zr, spotifyLyricsMaxFileBytes))
		if err != nil && len(out) == 0 {
			return nil, false
		}
		return out, true
	case len(rest) > 0 && rest[0] == '{':
		var raw json.RawMessage
		if json.NewDecoder(bytes.NewReader(rest)).Decode(&raw) != nil {
			return nil, false
		}
		return raw, true
	}
	return nil, false
}

type spotifyColorLyrics struct {
	Lyrics *struct {
		SyncType string `json:"syncType"`
		Lines    []struct {
			StartTimeMs string `json:"startTimeMs"`
			Words       string `json:"words"`
		} `json:"lines"`
		Provider string `json:"provider"`
	} `json:"lyrics"`
}

// spotifyColorLyricsLRC 把歌词接口的应答换成 LRC。recognized=false 是应答不是认得的形状(没有 lyrics 对象);
// 认得但不是逐行时间轴、或带时间的句子不够 spotifyLyricsMinLines,ok=false。纯函数。
func spotifyColorLyricsLRC(body []byte) (lrc string, recognized, ok bool) {
	var r spotifyColorLyrics
	if json.Unmarshal(body, &r) != nil || r.Lyrics == nil {
		return "", false, false
	}
	if r.Lyrics.SyncType != "LINE_SYNCED" {
		return "", true, false
	}
	var b strings.Builder
	timed := 0
	for _, l := range r.Lyrics.Lines {
		ms, err := strconv.ParseInt(l.StartTimeMs, 10, 64)
		if err != nil || ms < 0 {
			continue
		}
		text := strings.TrimSpace(l.Words)
		if text == "♪" {
			text = ""
		} else if text != "" {
			timed++
		}
		cs := ms / 10
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", cs/6000, cs/100%60, cs%100, text)
	}
	if timed < spotifyLyricsMinLines {
		return "", true, false
	}
	return b.String(), true, true
}

// spotifyLocalLyricsTrackID:这首在 Spotify 上的曲目 ID,以及这个 ID 是哪张专辑那一条的(idAlbum)。先看换曲时
// 记下的(就是这一首),再看歌词缓存条目里存的:专辑一致的那条优先,没有就取同名同歌手里 key 最小的那条 ——
// 按 map 顺序取的话,录音室版和 Live 版各有一条时每次可能拿到不同的 ID。调用方不持有 enrichMu。
func spotifyLocalLyricsTrackID(artist, title, album string) (id, idAlbum string) {
	if id := spotifyTrackIDHintFor(artist, title); id != "" {
		return id, album
	}
	exact := enrichKey(artist, title, album)
	prefix := enrichKey(artist, title, "")
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e, ok := enrichCache[exact]; ok && e.SpotifyTrackID != "" {
		return e.SpotifyTrackID, album
	}
	bestKey := ""
	for k, e := range enrichCache {
		if e.SpotifyTrackID != "" && strings.HasPrefix(k, prefix) && (bestKey == "" || k < bestKey) {
			bestKey, id = k, e.SpotifyTrackID
		}
	}
	if bestKey == "" {
		return "", ""
	}
	_, _, idAlbum = splitEnrichKey(bestKey)
	return id, idAlbum
}

// spotifyLocalLyricsFor 给歌词检索用:缓存里有这首的逐行歌词就换成一份跟各歌词源同形的原始应答。
// 调用方不持有 enrichMu。
func spotifyLocalLyricsFor(artist, title, album string) (lyricSourceResult, bool) {
	id, idAlbum := spotifyLocalLyricsTrackID(artist, title, album)
	if id == "" {
		return lyricSourceResult{}, false
	}
	lrc, ok := spotifyLocalLyricsByTrackID(id)
	if !ok {
		return lyricSourceResult{}, false
	}
	// 取不到元数据时,专辑填这个 ID 实际所属的那一条的专辑(可能是另一个版本),不拿本地的冒充 —— 版本比对才看得出来。
	r := lyricSourceResult{source: spotifyLocalLyricsSource, lyr: lrc, matchTitle: title, matchArtist: artist, matchAlbum: idAlbum}
	if dir := spotifyActiveUserDir(); dir != "" {
		if m, ok := spotifyResolveMeta(dir, []string{id})[id]; ok {
			if m.title != "" {
				r.matchTitle, r.matchArtist, r.matchAlbum = m.title, m.artist, m.album
			}
			r.srcDur = m.seconds
		}
	}
	return r, true
}

// spotifyLocalLyricsByTrackID 读这首在缓存里的逐行歌词。
func spotifyLocalLyricsByTrackID(id string) (string, bool) {
	path, ok := spotifyLyricsFileFor(id)
	if !ok {
		return "", false
	}
	st, err := os.Stat(path)
	if err != nil || st.Size() > spotifyLyricsMaxFileBytes {
		return "", false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	body, ok := spotifyLyricsBody(raw)
	if !ok {
		noteParserUnrecognized(spotifyLyricsParserName, "lyrics entry body is neither gzip nor JSON")
		return "", false
	}
	lrc, recognized, ok := spotifyColorLyricsLRC(body)
	if !recognized {
		noteParserUnrecognized(spotifyLyricsParserName, "color-lyrics response has no lyrics object")
		return "", false
	}
	noteParserRecognized(spotifyLyricsParserName)
	return lrc, ok
}

// spotifyLyricsRechecked:这次进程里已经为 Spotify 本地歌词重来过的条目。只在 enrichMu 里读写。
var spotifyLyricsRechecked = map[string]bool{}

// spotifyLyricsRecheckOnce:这个条目这次进程里还没为 Spotify 本地歌词重来过就记下、返回 true。调用方持有 enrichMu。
func spotifyLyricsRecheckOnce(key string) bool {
	if spotifyLyricsRechecked[key] {
		return false
	}
	spotifyLyricsRechecked[key] = true
	return true
}

// spotifyLyricsWorthRecheck:正在用 Spotify 放的这首,Spotify 缓存里有它的逐行歌词,而当初解析时 Musixmatch 那一路
// 没给出候选、也没见过这份 → 值得重来一次(retryLyricsUpgrade,分数严格更高才替换)。Spotify 开播时才拉当前这首的词,
// 预解析过、或解析跟它赛跑的条目,不补这一次就进不了打分。Musixmatch 给出过候选时不补:两份同源,多一份不改结论。
// available 由调用方在锁外算好传进来。手改过、校准过、关了自动升级的都不动。
func spotifyLyricsWorthRecheck(e enrichEntry, bundleID string, pinned, autoUpgrade, available bool) bool {
	if bundleID != spotifyBundleID || !autoUpgrade || pinned || e.ManualLyrics || e.Instrumental || !available {
		return false
	}
	if slices.Contains(e.LyricsSourcesSeen, "musixmatch") ||
		slices.Contains(e.LyricsSourcesSeen, spotifyLocalLyricsSource) || slices.Contains(e.LyricsSourcesResponded, spotifyLocalLyricsSource) {
		return false
	}
	if e.LyricsDecision != nil && slices.Contains(e.LyricsDecision.SourcesResponded, spotifyLocalLyricsSource) {
		return false
	}
	return e.LyricsRetryCount < lyricsRetryMaxAttempts
}

// spotifyLyricsAvailableTTL:同一首记多久。trackEnrichment 在播放期间每一拍都问,Spotify 开播后一两秒就把词写进缓存,
// 30 秒内问到的都是同一个答案。
const spotifyLyricsAvailableTTL = 30 * time.Second

type spotifyLyricsAvailableAt struct {
	at time.Time
	ok bool
}

var (
	spotifyLyricsAvailableMu   sync.Mutex
	spotifyLyricsAvailableMemo = map[string]spotifyLyricsAvailableAt{}
)

// spotifyLocalLyricsAvailable:这首现在在 Spotify 缓存里有没有逐行歌词(给 spotifyLyricsWorthRecheck)。
// 调用方不持有 enrichMu。
func spotifyLocalLyricsAvailable(artist, title string) bool {
	id, _ := spotifyLocalLyricsTrackID(artist, title, "")
	if id == "" {
		return false
	}
	now := time.Now()
	spotifyLyricsAvailableMu.Lock()
	if m, ok := spotifyLyricsAvailableMemo[id]; ok && now.Sub(m.at) < spotifyLyricsAvailableTTL {
		spotifyLyricsAvailableMu.Unlock()
		return m.ok
	}
	spotifyLyricsAvailableMu.Unlock()
	_, ok := spotifyLocalLyricsByTrackID(id)
	spotifyLyricsAvailableMu.Lock()
	for k, m := range spotifyLyricsAvailableMemo {
		if now.Sub(m.at) >= spotifyLyricsAvailableTTL {
			delete(spotifyLyricsAvailableMemo, k)
		}
	}
	spotifyLyricsAvailableMemo[id] = spotifyLyricsAvailableAt{at: now, ok: ok}
	spotifyLyricsAvailableMu.Unlock()
	return ok
}
