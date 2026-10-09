package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// amll-ttml-db 的歌词索引(metadata/raw-lyrics-index.jsonl):库里每份歌词一行,带各平台曲目 ID、ISRC、歌名、歌手、
// 专辑。两个用途:
//
//   - 按 ID 取词之前先查索引,不在索引里的 ID 不发请求(库里没有的 ID 只会回 404)。
//   - 手上的 ID 都不在库里时,按 ISRC、按歌名歌手专辑在索引里找(amllIndex.lookup)。
//
// 索引落盘在配置目录,进程里第一次用到时读进内存;离上次核对超过 amllIndexRefreshInterval 就在后台按 ETag 核对
// 一次(没变时回 304,不重新下载)。还没有落盘的索引时,这一轮照旧按 ID 直取,同时在后台下载。超过 amllIndexMaxAge
// 没核对成功的索引不再拿来挡请求,只用来按 ISRC / 歌名找。

const (
	amllIndexRemotePath = "metadata/raw-lyrics-index.jsonl"
	// amllIndexRefreshInterval:离上次核对多久之后再核对一次。
	amllIndexRefreshInterval = 6 * time.Hour
	// amllIndexRetryCooldown:后台核对没成功之后隔多久再试。
	amllIndexRetryCooldown = 30 * time.Minute
	// amllIndexMaxAge:索引离上次核对成功超过这么久,就不再拿它挡掉不在里面的 ID。
	amllIndexMaxAge          = 7 * 24 * time.Hour
	amllIndexDownloadTimeout = 60 * time.Second
	amllIndexMaxBytes        = 32 << 20
	// amllIndexMinEntries:解出来不到这么多条的下载当作坏的,不替换手上那份。
	amllIndexMinEntries = 500
	// amllIndexFileVersion:落盘格式的版本;读到别的版本当作没有落盘的索引。
	amllIndexFileVersion = 1
	// amllIndexLookupMaxFetches:按 ISRC / 歌名找到的,一轮最多取这么多份。
	amllIndexLookupMaxFetches = 3
	// amllNameLookupMinAlbumScore:按歌名找时专辑至少要对到 albumScore 的包含档。同名的翻唱、重录、别的歌手合唱的
	// 版本歌名歌手都对得上,只有专辑把它们分开。
	amllNameLookupMinAlbumScore = 100
)

// amllIndexEntry:索引里的一份歌词。各字段都是索引原样给的多个值(同一首歌的几种写法、几个平台 ID)。
type amllIndexEntry struct {
	Titles  []string `json:"titles,omitempty"`
	Artists []string `json:"artists,omitempty"`
	Albums  []string `json:"albums,omitempty"`
	ISRCs   []string `json:"isrcs,omitempty"`
	Apple   []string `json:"apple,omitempty"`
	Spotify []string `json:"spotify,omitempty"`
	NCM     []string `json:"ncm,omitempty"`
	QQ      []string `json:"qq,omitempty"`
}

// amllIndexDirs:各平台目录对应 amllIndexEntry 的哪个 ID 字段。顺序就是按 ISRC / 歌名找到之后取词用哪个 ID 的顺序。
var amllIndexDirs = []struct {
	dir string
	ids func(e *amllIndexEntry) []string
}{
	{"am-lyrics", func(e *amllIndexEntry) []string { return e.Apple }},
	{"spotify-lyrics", func(e *amllIndexEntry) []string { return e.Spotify }},
	{"ncm-lyrics", func(e *amllIndexEntry) []string { return e.NCM }},
	{"qq-lyrics", func(e *amllIndexEntry) []string { return e.QQ }},
}

// amllIndexFile:落盘的样子。
type amllIndexFile struct {
	Version int `json:"version"`
	// ETag / Base:这份是从哪个镜像取的、对方给的 ETag。核对时只对同一个镜像带 If-None-Match。
	ETag string `json:"etag,omitempty"`
	Base string `json:"base,omitempty"`
	// CheckedAt:上次核对成功的时间(Unix 秒)。
	CheckedAt int64            `json:"checked_at"`
	Entries   []amllIndexEntry `json:"entries"`
}

// amllIndex:读进内存的索引。建好之后只读。
type amllIndex struct {
	etag, base string
	checkedAt  time.Time
	entries    []amllIndexEntry
	// byID:"平台目录/ID" → entries 下标。
	byID   map[string]int
	byISRC map[string][]int
}

func newAMLLIndex(entries []amllIndexEntry, etag, base string, checkedAt time.Time) *amllIndex {
	x := &amllIndex{etag: etag, base: base, checkedAt: checkedAt, entries: entries,
		byID: map[string]int{}, byISRC: map[string][]int{}}
	for i := range entries {
		e := &entries[i]
		for _, d := range amllIndexDirs {
			for _, id := range d.ids(e) {
				if _, dup := x.byID[d.dir+"/"+id]; !dup {
					x.byID[d.dir+"/"+id] = i
				}
			}
		}
		for _, code := range e.ISRCs {
			x.byISRC[code] = append(x.byISRC[code], i)
		}
	}
	return x
}

// dueForCheck:该核对了(没有索引、离上次核对超过 amllIndexRefreshInterval、或者核对时间在将来)。
func (x *amllIndex) dueForCheck(now time.Time) bool {
	if x == nil {
		return true
	}
	age := now.Sub(x.checkedAt)
	return age < 0 || age >= amllIndexRefreshInterval
}

// gates:这份索引够新,可以拿来挡掉不在里面的 ID。
func (x *amllIndex) gates(now time.Time) bool {
	return now.Sub(x.checkedAt) < amllIndexMaxAge
}

// hasISRC:索引里有没有这个 ISRC 的条目。x 为 nil(没有索引)时为 false。
func (x *amllIndex) hasISRC(code string) bool {
	return x != nil && len(x.byISRC[normalizeAMLLISRC(code)]) > 0
}

// entryFor:这个平台目录下的这个 ID 在不在索引里,在的话是第几条。
func (x *amllIndex) entryFor(dir, id string) (int, bool) {
	i, ok := x.byID[dir+"/"+id]
	return i, ok
}

// fetchTarget:取第 i 条用哪个平台目录和 ID(按 amllIndexDirs 的顺序取第一个有的)。
func (x *amllIndex) fetchTarget(i int) (string, string) {
	e := &x.entries[i]
	for _, d := range amllIndexDirs {
		if ids := d.ids(e); len(ids) > 0 {
			return d.dir, ids[0]
		}
	}
	return "", ""
}

// amllIndexMatch:按 ISRC / 歌名在索引里找到的一条,带上报给打分的歌名 / 歌手 / 专辑。
type amllIndexMatch struct {
	entry                int
	byISRC               bool
	albumScore           int
	title, artist, album string
}

// lookup 按 ISRC、再按歌名歌手专辑在索引里找,ISRC 找到的排在前面,一共最多 amllIndexLookupMaxFetches 条。
//
//   - ISRC:索引里同一个 ISRC 的那几条,歌名还要对得上(lyricTitleAccepted)、版本限定词和重录标记不冲突。索引里的 ISRC 是投稿人
//     填的,同一个 ISRC 挂在另一种语言版本上的也有,歌名把它挡掉。
//   - 歌名:歌名、歌手(lyricSourceArtistMatches)都对得上,专辑至少到 amllNameLookupMinAlbumScore,版本限定词和重录标记不冲突;
//     本地没有专辑或者不知道时长时不找(时长要拿来核对取回的歌词,见 amllLookupFits)。专辑分高的排前面。
func (x *amllIndex) lookup(q amllQuery) []amllIndexMatch {
	var out []amllIndexMatch
	seen := map[int]bool{}
	add := func(m amllIndexMatch) {
		if !seen[m.entry] && len(out) < amllIndexLookupMaxFetches {
			seen[m.entry] = true
			out = append(out, m)
		}
	}
	if code := normalizeAMLLISRC(q.isrc); code != "" {
		for _, i := range x.byISRC[code] {
			e := &x.entries[i]
			title := e.acceptedTitle(q.title)
			if title == "" {
				continue
			}
			album, score := e.bestAlbum(q.album)
			if versionTagsMismatch(q.title, q.album, title, album) || amllRerecordingMismatch(q.title, q.album, title, album) {
				continue
			}
			artist := e.matchedArtist(q.artist)
			if artist == "" {
				artist = strings.Join(e.Artists, "、")
			}
			add(amllIndexMatch{entry: i, byISRC: true, albumScore: score, title: title, artist: artist, album: album})
		}
	}
	if strings.TrimSpace(q.album) == "" || q.durationSecs <= 0 {
		return out
	}
	var byName []amllIndexMatch
	for i := range x.entries {
		e := &x.entries[i]
		title := e.acceptedTitle(q.title)
		if title == "" {
			continue
		}
		artist := e.matchedArtist(q.artist)
		if artist == "" {
			continue
		}
		album, score := e.bestAlbum(q.album)
		if score < amllNameLookupMinAlbumScore || versionTagsMismatch(q.title, q.album, title, album) ||
			amllRerecordingMismatch(q.title, q.album, title, album) {
			continue
		}
		byName = append(byName, amllIndexMatch{entry: i, albumScore: score, title: title, artist: artist, album: album})
	}
	sort.SliceStable(byName, func(a, b int) bool { return byName[a].albumScore > byName[b].albumScore })
	for _, m := range byName {
		add(m)
	}
	return out
}

// amllRerecordingMarkers:重录版的标记(小写,撇号统一成 ')。重录版跟原版歌名、专辑都对得上(「1989」包含在
// 「1989 (Taylor's Version)」里),versionTagsMismatch 又不把它当另一次录音,在索引里找时单独比:见 amllRerecordingMismatch。
var amllRerecordingMarkers = []string{"taylor's version", "taylors version", "re-record", "rerecord"}

// amllRerecordingMismatch:本地(歌名 + 专辑)和索引这一条(歌名 + 专辑)一边带重录标记、一边不带。
func amllRerecordingMismatch(localTitle, localAlbum, title, album string) bool {
	marked := func(parts ...string) bool {
		s := strings.ToLower(strings.ReplaceAll(strings.Join(parts, " "), "’", "'"))
		for _, m := range amllRerecordingMarkers {
			if strings.Contains(s, m) {
				return true
			}
		}
		return false
	}
	return marked(localTitle, localAlbum) != marked(title, album)
}

// acceptedTitle:这一条的歌名里第一个跟本地歌名对得上的(lyricTitleAccepted),都对不上时为空。
func (e *amllIndexEntry) acceptedTitle(title string) string {
	for _, t := range e.Titles {
		if lyricTitleAccepted(t, title) {
			return t
		}
	}
	return ""
}

// matchedArtist:这一条的歌手里第一个跟本地歌手对得上的(lyricSourceArtistMatches;本地是几位合唱时,对上其中一位
// 就算),都对不上时为空。
func (e *amllIndexEntry) matchedArtist(artist string) string {
	for _, a := range e.Artists {
		if lyricSourceArtistMatches(a, artist) {
			return a
		}
	}
	return ""
}

// bestAlbum:这一条的专辑里跟本地专辑 albumScore 最高的那个和它的分;本地没有专辑时是第一个专辑、0 分。
func (e *amllIndexEntry) bestAlbum(album string) (string, int) {
	best, bestScore := "", -1
	for _, a := range e.Albums {
		if s := albumScore(a, album); s > bestScore {
			best, bestScore = a, s
		}
	}
	return best, max(bestScore, 0)
}

// amllLookupFits:按 ISRC / 歌名找到的那一份,歌词长度跟这首歌对得上(durationFits)。按歌名找到的要求本地时长已知;
// 按 ISRC 找到的本地时长未知时不核对。
func amllLookupFits(m amllIndexMatch, r amllResult, durationSecs float64) bool {
	if durationSecs <= 0 {
		return m.byISRC
	}
	last, ok := lastLRCTimestampSecs(r.lrc)
	return ok && durationFits(last, durationSecs)
}

// normalizeAMLLISRC:去掉连字符和空白、转大写。两边(索引、在播的 ISRC)都过一遍再比。
func normalizeAMLLISRC(code string) string {
	return strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code)))
}

// parseAMLLIndex 解析 raw-lyrics-index.jsonl:一行一份歌词,`{"metadata":[[键,[值…]]…],"rawLyricFile":…}`。只留下用得到
// 的几个键;解不开的行、一个平台 ID 都没有的行跳过。
func parseAMLLIndex(raw []byte) []amllIndexEntry {
	var out []amllIndexEntry
	for _, line := range bytes.Split(raw, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		var row struct {
			Metadata [][]json.RawMessage `json:"metadata"`
		}
		if json.Unmarshal(line, &row) != nil {
			continue
		}
		var e amllIndexEntry
		for _, kv := range row.Metadata {
			if len(kv) != 2 {
				continue
			}
			var key string
			var vals []string
			if json.Unmarshal(kv[0], &key) != nil || json.Unmarshal(kv[1], &vals) != nil {
				continue
			}
			vals = amllIndexValues(vals)
			switch key {
			case "musicName":
				e.Titles = vals
			case "artists":
				e.Artists = vals
			case "album":
				e.Albums = vals
			case "isrc":
				for _, v := range vals {
					e.ISRCs = append(e.ISRCs, normalizeAMLLISRC(v))
				}
			case "appleMusicId":
				e.Apple = vals
			case "spotifyId":
				e.Spotify = vals
			case "ncmMusicId":
				e.NCM = vals
			case "qqMusicId":
				e.QQ = vals
			}
		}
		if len(e.Apple)+len(e.Spotify)+len(e.NCM)+len(e.QQ) > 0 {
			out = append(out, e)
		}
	}
	return out
}

// amllIndexValues:去掉首尾空白,丢掉空值。
func amllIndexValues(vals []string) []string {
	var out []string
	for _, v := range vals {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// ---- 落盘与后台核对 ----

// amllIndexStore:进程里那份索引和它的后台核对。path 为空时不读不写、也不下载(单测默认这样,见 TestMain)。
type amllIndexStore struct {
	path string
	now  func() time.Time

	mu          sync.Mutex
	idx         *amllIndex
	loaded      bool
	refreshing  bool
	lastAttempt time.Time
	// wg:后台核对。单测等它跑完再看结果。
	wg sync.WaitGroup
}

func newAMLLIndexStore(path string, now func() time.Time) *amllIndexStore {
	return &amllIndexStore{path: path, now: now}
}

var amllIndexStorePtr atomic.Pointer[amllIndexStore]

// sharedAMLLIndexStore:进程共用的那一份,第一次用到时按配置目录建。
func sharedAMLLIndexStore() *amllIndexStore {
	if s := amllIndexStorePtr.Load(); s != nil {
		return s
	}
	path := ""
	if configDir() != "" {
		path = configFilePath(clientName + "-amll-index.json")
	}
	amllIndexStorePtr.CompareAndSwap(nil, newAMLLIndexStore(path, time.Now))
	return amllIndexStorePtr.Load()
}

// setSharedAMLLIndexStore 只给单测换掉进程共用的那一份。
func setSharedAMLLIndexStore(s *amllIndexStore) { amllIndexStorePtr.Store(s) }

// current:手上的索引,没有时为 nil。第一次调用时从磁盘读;该核对了就起一次后台核对,不等它。
func (s *amllIndexStore) current() *amllIndex {
	if s.path == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.loaded {
		s.loaded = true
		s.idx = readAMLLIndexFile(s.path)
	}
	now := s.now()
	if !s.refreshing && s.idx.dueForCheck(now) && now.Sub(s.lastAttempt) >= amllIndexRetryCooldown {
		s.refreshing = true
		s.lastAttempt = now
		s.wg.Add(1)
		go s.refresh(s.idx)
	}
	return s.idx
}

// refresh 是一次后台核对。核对成功才换掉手上那份。
func (s *amllIndexStore) refresh(cur *amllIndex) {
	defer s.wg.Done()
	next := s.check(cur)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refreshing = false
	if next != nil {
		s.idx = next
	}
}

// check:磁盘上那份已经不用核对(别的进程刚核对过)就直接用它;否则带着手上那份的 ETag 去问,问到了落盘。
func (s *amllIndexStore) check(cur *amllIndex) *amllIndex {
	now := s.now()
	if disk := readAMLLIndexFile(s.path); disk != nil {
		if !disk.dueForCheck(now) {
			return disk
		}
		if cur == nil || disk.checkedAt.After(cur.checkedAt) {
			cur = disk
		}
	}
	ctx, cancel := context.WithTimeout(withBackgroundOutbound(context.Background()), amllIndexDownloadTimeout)
	defer cancel()
	next, changed, err := fetchAMLLIndex(ctx, cur, now)
	if err != nil {
		log.Printf("amll index: check failed (%v), next try in %s", err, amllIndexRetryCooldown)
		return nil
	}
	if changed {
		log.Printf("amll index: %d entries from %s", len(next.entries), next.base)
	}
	if err := writeAMLLIndexFile(s.path, next); err != nil {
		warnf("amll index: save failed (%v)", err)
	}
	return next
}

// fetchAMLLIndex 按 amllBases 的顺序问索引,只有没问成(传输失败、非 200 / 304、内容解不出够数的条目)才换镜像。对方回
// 304 时沿用 cur 的内容、只更新核对时间,changed 为 false。
func fetchAMLLIndex(ctx context.Context, cur *amllIndex, now time.Time) (next *amllIndex, changed bool, err error) {
	err = tryEach(ctx, amllBases, func(base string) error {
		etag := ""
		if cur != nil && cur.base == base {
			etag = cur.etag
		}
		entries, newETag, notModified, err := fetchAMLLIndexAt(ctx, base, etag)
		if err != nil {
			return err
		}
		if notModified {
			n := *cur
			n.checkedAt = now
			next, changed = &n, false
			return nil
		}
		next, changed = newAMLLIndex(entries, newETag, base, now), true
		return nil
	})
	return next, changed, err
}

// fetchAMLLIndexAt:etag 非空时带 If-None-Match,对方回 304 时 notModified 为 true。
func fetchAMLLIndexAt(ctx context.Context, base, etag string) (entries []amllIndexEntry, newETag string, notModified bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/"+amllIndexRemotePath, nil)
	if err != nil {
		return nil, "", false, err
	}
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	resp, err := doHTTPTracked(lyricHTTPClient(amllIndexDownloadTimeout), req)
	if err != nil {
		return nil, "", false, err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotModified && etag != "":
		return nil, etag, true, nil
	case resp.StatusCode != http.StatusOK:
		return nil, "", false, fmt.Errorf("status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, amllIndexMaxBytes+1))
	if err != nil {
		return nil, "", false, err
	}
	if len(body) > amllIndexMaxBytes {
		return nil, "", false, fmt.Errorf("index larger than %d bytes", amllIndexMaxBytes)
	}
	entries = parseAMLLIndex(body)
	if len(entries) < amllIndexMinEntries {
		return nil, "", false, fmt.Errorf("index has only %d usable entries", len(entries))
	}
	return entries, resp.Header.Get("ETag"), false, nil
}

// readAMLLIndexFile:读不到、解不开、版本不对、条目不够数都返回 nil。
func readAMLLIndexFile(path string) *amllIndex {
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return nil
	}
	var f amllIndexFile
	if json.Unmarshal(raw, &f) != nil || f.Version != amllIndexFileVersion || len(f.Entries) < amllIndexMinEntries {
		return nil
	}
	return newAMLLIndex(f.Entries, f.ETag, f.Base, time.Unix(f.CheckedAt, 0))
}

// writeAMLLIndexFile:常驻进程和 search-lyrics 等一次性子命令都会写这份,writeFileAtomic 的临时文件名是随机的。
func writeAMLLIndexFile(path string, x *amllIndex) error {
	raw, err := json.Marshal(amllIndexFile{Version: amllIndexFileVersion, ETag: x.etag, Base: x.base,
		CheckedAt: x.checkedAt.Unix(), Entries: x.entries})
	if err != nil {
		return err
	}
	return writeFileAtomic(path, raw)
}
