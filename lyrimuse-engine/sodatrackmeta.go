package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 汽水 2.9 起音频缓存库(sodapreload.go)的记录只带曲目 id,不带歌名、歌手、专辑、时长(09 章决策 239)。这里按 id 问
// `seo_track`(soda.go)补上,结果落盘,同一个 id 只问一次;问到一批,预载索引按新的一代重解,再给在汽水上放过、
// 还没记歌曲页的条目补一次(backfillSodaPagesFromClientCache)。
//
// 只问缓存库里的 id:都是客户端自己缓存过的曲目(放过的、预载的),缓存建得晚的先问。走后台请求
// (withBackgroundOutbound),一次一个;连着失败 sodaTrackMetaMaxFailures 次就停 sodaTrackMetaPause,
// 没问到的 id 在 sodaTrackMetaRetryAfter 之内不再问。

// sodaTrackMeta:按曲目 id 问来的曲目信息,字段跟 2.9 之前缓存库里的 playable 一一对应(时长、试听段都是毫秒;
// 应答里试听段的 start 为 0 时省略,读出来就是 0,跟 playable 的读法一样)。
type sodaTrackMeta struct {
	Name           string             `json:"name"`
	Artists        []sodaTrackMetaRef `json:"artists"`
	Album          sodaTrackMetaRef   `json:"album"`
	DurationMs     int64              `json:"duration"`
	PreviewStartMs int64              `json:"preview_start,omitempty"`
	PreviewDurMs   int64              `json:"preview_duration,omitempty"`
	// At:问到的时刻(秒)。超过 sodaTrackMetaMax 条时先丢问得最早的。
	At int64 `json:"at"`
}

type sodaTrackMetaRef struct {
	ID   string `json:"id,omitempty"`
	Name string `json:"name"`
}

const (
	sodaTrackMetaMax         = 3000
	sodaTrackMetaRetryAfter  = 6 * time.Hour
	sodaTrackMetaMaxFailures = 3
	sodaTrackMetaPause       = 10 * time.Minute
	sodaTrackMetaTimeout     = 15 * time.Second
)

var (
	sodaTrackMetaMu    sync.Mutex
	sodaTrackMetaCache = map[string]sodaTrackMeta{}
	sodaTrackMetaPath  string
	sodaTrackMetaDirty bool
	// 待问的 id(先进先问)、已排上的(问完才放下,问的过程中再来的不重复排)、没问到的(id → 时刻)。
	sodaTrackMetaPending []string
	sodaTrackMetaQueued  = map[string]bool{}
	sodaTrackMetaFailed  = map[string]time.Time{}
	sodaTrackMetaRunning bool
	sodaTrackMetaPaused  time.Time
	// sodaTrackMetaGen:每问到一批加一,预载索引(sodaPreloadIndex)据此重解。
	sodaTrackMetaGen atomic.Int64
	// sodaTrackMetaFetch 问一个 id;单测换成假的。
	sodaTrackMetaFetch = sodaFetchTrackMeta
	// sodaTrackMetaSaveMu 让两次保存串行,理由同 appleAlbumHintSaveMu。
	sodaTrackMetaSaveMu sync.Mutex
)

var errSodaTrackMetaMissing = errors.New("soda: seo_track answered without this track")

// sodaTrackMetaFromPlayable 从缓存库老版本记录里的 playable 取曲目信息。
func sodaTrackMetaFromPlayable(p map[string]any) sodaTrackMeta {
	var m sodaTrackMeta
	m.Name, _ = p["name"].(string)
	arr, _ := p["artists"].([]any)
	for _, a := range arr {
		am, _ := a.(map[string]any)
		name, _ := am["name"].(string)
		id, _ := am["id"].(string)
		m.Artists = append(m.Artists, sodaTrackMetaRef{ID: id, Name: name})
	}
	if am, ok := p["album"].(map[string]any); ok {
		m.Album.Name, _ = am["name"].(string)
		m.Album.ID, _ = am["id"].(string)
	}
	m.DurationMs, _ = msgpackrInt(p["duration"])
	if pv, ok := p["preview"].(map[string]any); ok {
		m.PreviewStartMs, _ = msgpackrInt(pv["start"])
		m.PreviewDurMs, _ = msgpackrInt(pv["duration"])
	}
	return m
}

// preloaded 把曲目信息换成一条预载记录;没有歌名、没有歌手的不认。
func (m sodaTrackMeta) preloaded(id string, at int64) (sodaPreloadedTrack, bool) {
	name := strings.TrimSpace(m.Name)
	var artists []string
	artistID := ""
	for _, a := range m.Artists {
		if s := strings.TrimSpace(a.Name); s != "" {
			if len(artists) == 0 {
				artistID = a.ID
			}
			artists = append(artists, s)
		}
	}
	if name == "" || len(artists) == 0 {
		return sodaPreloadedTrack{}, false
	}
	// 歌手用 "/" 连起来,跟 sodaUpcomingArtist 同一个理由:要跟播放器报的完整串对得上。
	return sodaPreloadedTrack{id: id, at: at, albumID: m.Album.ID, artistID: artistID,
		previewStartMs: m.PreviewStartMs, previewDurMs: m.PreviewDurMs, fullMs: m.DurationMs, upcoming: upcomingTrack{
			artist: strings.Join(artists, "/"), title: name, album: strings.TrimSpace(m.Album.Name), duration: float64(m.DurationMs) / 1000,
		}}, true
}

// sodaPreloadsWithMeta:缓存库里的全部曲目。只有曲目 id 的记录按问来的曲目信息补齐;还没问到的这一次不出现,交给后台去问。
func sodaPreloadsWithMeta(raw []byte) []sodaPreloadedTrack {
	all := parseSodaPreloads(raw)
	out := make([]sodaPreloadedTrack, 0, len(all))
	var missing []sodaPreloadedTrack
	sodaTrackMetaMu.Lock()
	for _, t := range all {
		if t.upcoming.title != "" {
			out = append(out, t)
			continue
		}
		if m, ok := sodaTrackMetaCache[t.id]; ok {
			if full, ok := m.preloaded(t.id, t.at); ok {
				out = append(out, full)
			}
			continue
		}
		missing = append(missing, t)
	}
	sodaTrackMetaMu.Unlock()
	if len(missing) > 0 {
		sort.SliceStable(missing, func(i, j int) bool { return missing[i].at > missing[j].at })
		ids := make([]string, 0, len(missing))
		for _, t := range missing {
			ids = append(ids, t.id)
		}
		requestSodaTrackMeta(ids)
	}
	return out
}

// requestSodaTrackMeta 把还没问过的 id 按给的顺序排进待问,后台没在问、也没在停手时开问。
func requestSodaTrackMeta(ids []string) {
	now := time.Now()
	sodaTrackMetaMu.Lock()
	defer sodaTrackMetaMu.Unlock()
	for _, id := range ids {
		if _, ok := sodaTrackMetaCache[id]; ok || sodaTrackMetaQueued[id] {
			continue
		}
		if at, ok := sodaTrackMetaFailed[id]; ok {
			if now.Sub(at) < sodaTrackMetaRetryAfter {
				continue
			}
			delete(sodaTrackMetaFailed, id)
		}
		sodaTrackMetaQueued[id] = true
		sodaTrackMetaPending = append(sodaTrackMetaPending, id)
	}
	if len(sodaTrackMetaPending) == 0 || sodaTrackMetaRunning || now.Before(sodaTrackMetaPaused) {
		return
	}
	sodaTrackMetaRunning = true
	go sodaTrackMetaWorker()
}

// sodaTrackMetaWorker 一个一个问到待问的问完;连着失败太多就停手,剩下的退回去等下一次排上。问到了就落盘、让预载索引
// 重解,再给存量条目补一次歌曲页。
func sodaTrackMetaWorker() {
	added, failures := 0, 0
	for {
		sodaTrackMetaMu.Lock()
		if failures >= sodaTrackMetaMaxFailures {
			sodaTrackMetaPaused = time.Now().Add(sodaTrackMetaPause)
			for _, id := range sodaTrackMetaPending {
				delete(sodaTrackMetaQueued, id)
			}
			sodaTrackMetaPending = nil
		}
		if len(sodaTrackMetaPending) == 0 {
			sodaTrackMetaRunning = false
			sodaTrackMetaMu.Unlock()
			break
		}
		id := sodaTrackMetaPending[0]
		sodaTrackMetaPending = sodaTrackMetaPending[1:]
		sodaTrackMetaMu.Unlock()

		ctx, cancel := withCancelAfter(withBackgroundOutbound(context.Background()), sodaTrackMetaTimeout)
		m, err := sodaTrackMetaFetch(ctx, id)
		cancel()
		sodaTrackMetaMu.Lock()
		delete(sodaTrackMetaQueued, id)
		if err != nil {
			failures++
			sodaTrackMetaFailed[id] = time.Now()
		} else {
			failures = 0
			delete(sodaTrackMetaFailed, id)
			m.At = time.Now().Unix()
			sodaTrackMetaCache[id] = m
			pruneSodaTrackMetaLocked()
			sodaTrackMetaDirty = true
			added++
		}
		sodaTrackMetaMu.Unlock()
	}
	if failures >= sodaTrackMetaMaxFailures {
		log.Printf("soda: track lookups failed %d times in a row, pausing for %s", failures, sodaTrackMetaPause)
	}
	if added == 0 {
		return
	}
	sodaTrackMetaGen.Add(1)
	saveSodaTrackMeta()
	log.Printf("soda: looked up %d track ids from the client's audio cache", added)
	backfillSodaPagesFromClientCache()
}

// pruneSodaTrackMetaLocked:超过上限时丢掉问得最早的。调用方持 sodaTrackMetaMu。
func pruneSodaTrackMetaLocked() {
	over := len(sodaTrackMetaCache) - sodaTrackMetaMax
	if over <= 0 {
		return
	}
	ids := make([]string, 0, len(sodaTrackMetaCache))
	for id := range sodaTrackMetaCache {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool {
		if a, b := sodaTrackMetaCache[ids[i]].At, sodaTrackMetaCache[ids[j]].At; a != b {
			return a < b
		}
		return ids[i] < ids[j]
	})
	for _, id := range ids[:over] {
		delete(sodaTrackMetaCache, id)
	}
}

// sodaSeoTrackMetaResponse:seo_track 应答里曲目信息那一块(跟 sodaSeoTrackResponse 取的是同一个对象,这里多要 id 与试听段)。
type sodaSeoTrackMetaResponse struct {
	SeoTrack struct {
		Track struct {
			ID       string             `json:"id"`
			Name     string             `json:"name"`
			Duration int64              `json:"duration"`
			Artists  []sodaTrackMetaRef `json:"artists"`
			Album    sodaTrackMetaRef   `json:"album"`
			Preview  struct {
				Start    int64 `json:"start"`
				Duration int64 `json:"duration"`
			} `json:"preview"`
		} `json:"track"`
	} `json:"seo_track"`
}

// sodaFetchTrackMeta 按曲目 id 问 seo_track 取曲目信息(两个主机依次试)。
func sodaFetchTrackMeta(ctx context.Context, id string) (sodaTrackMeta, error) {
	var m sodaTrackMeta
	err := tryEach(ctx, sodaSeoHosts, func(host string) error {
		raw, err := sodaGetSeoTrackAt(ctx, host, id)
		if err != nil {
			return err
		}
		m, err = sodaTrackMetaFromSeo(raw, id)
		return err
	})
	return m, err
}

// sodaTrackMetaFromSeo 从 seo_track 的应答体里取曲目信息。不是这个 id、没有歌名的按失败算(端点换了形状和曲库里
// 没有分不开,都等下次再问)。
func sodaTrackMetaFromSeo(raw []byte, id string) (sodaTrackMeta, error) {
	var body sodaSeoTrackMetaResponse
	if err := json.Unmarshal(raw, &body); err != nil {
		return sodaTrackMeta{}, err
	}
	t := body.SeoTrack.Track
	if strings.TrimSpace(t.ID) != id || strings.TrimSpace(t.Name) == "" {
		return sodaTrackMeta{}, errSodaTrackMetaMissing
	}
	return sodaTrackMeta{Name: t.Name, Artists: t.Artists, Album: t.Album, DurationMs: t.Duration,
		PreviewStartMs: t.Preview.Start, PreviewDurMs: t.Preview.Duration}, nil
}

func loadSodaTrackMeta(path string) {
	sodaTrackMetaMu.Lock()
	sodaTrackMetaPath = path
	sodaTrackMetaMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var m map[string]sodaTrackMeta
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		sodaTrackMetaMu.Lock()
		sodaTrackMetaCache = m
		sodaTrackMetaMu.Unlock()
		noteCacheLoaded(path, fmt.Sprintf("%d Soda track lookups", len(m)))
	}
}

func saveSodaTrackMeta() {
	sodaTrackMetaSaveMu.Lock()
	defer sodaTrackMetaSaveMu.Unlock()
	sodaTrackMetaMu.Lock()
	if !sodaTrackMetaDirty || sodaTrackMetaPath == "" {
		sodaTrackMetaMu.Unlock()
		return
	}
	data, err := json.Marshal(sodaTrackMetaCache)
	sodaTrackMetaDirty = false
	path := sodaTrackMetaPath
	sodaTrackMetaMu.Unlock()
	if err != nil {
		return
	}
	if err := writeFileAtomic(path, data); err != nil {
		slog.Error("save soda track lookups", "err", err)
	}
}

// backfillSodaPagesFromClientCache:在汽水上放过、还没记歌曲页的条目,按客户端本机的播放队列与音频缓存库补记歌曲页、
// 专辑与歌手 id(挑法与形状闸同播放时 playerCatalogIDsFor,报过原样写法的按它查)。只补没有歌曲页的,返回补了几条。
// 不走 playerCatalogIDsFor 的记忆:问到一批之后紧接着补,那份记忆里可能还是 20 秒前的「没有」。
func backfillSodaPagesFromClientCache() int {
	type want struct {
		key, artist, title, album string
		dur                       float64
	}
	enrichMu.Lock()
	var wants []want
	for k, e := range enrichCache {
		if e.SodaURL != "" || !slices.Contains(e.Players, sodaMusicBundleID) {
			continue
		}
		artist, title, album := splitEnrichKey(k)
		if r, ok := e.Reported[sodaMusicBundleID]; ok && r.Title != "" {
			artist, title, album = r.Artist, r.Title, r.Album
		}
		wants = append(wants, want{k, artist, title, album, e.DurationSecs})
	}
	enrichMu.Unlock()
	found := map[string]playerCatalogIDs{}
	for _, w := range wants {
		ids := sodaPlayingCatalogIDs(w.artist, w.title, w.album, w.dur)
		if ids.song == "" {
			continue
		}
		if !playerCatalogIDOK(sodaMusicBundleID, ids.album) {
			ids.album = ""
		}
		if !playerCatalogIDOK(sodaMusicBundleID, ids.artist) {
			ids.artist = ""
		}
		found[w.key] = ids
	}
	if len(found) == 0 {
		return 0
	}
	var changed []string
	enrichMu.Lock()
	for k, ids := range found {
		e, ok := enrichCache[k]
		if !ok || e.SodaURL != "" {
			continue
		}
		if applyPlayerCatalogIDsLocked(&e, sodaMusicBundleID, ids) {
			enrichCache[k] = e
			noteEnrichPendingLocked(k)
			changed = append(changed, k)
		}
	}
	if len(changed) > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if len(changed) > 0 {
		log.Printf("soda: noted the song page on %d entries played in the client, from its local caches", len(changed))
		saveEnrichPendingBatch(changed)
	}
	return len(changed)
}
