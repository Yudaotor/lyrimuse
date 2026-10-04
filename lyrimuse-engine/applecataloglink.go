package main

import (
	"context"
	"log"
	"slices"
	"sort"
	"strings"
	"time"
)

// 存量歌词缓存的 apple_music_url 换成已校验目录锚点的 Apple Music 页(03 章决策 28)。
//
// 新解析的条目由 resolveTrackEnrichment 和缓存命中那条路(trackEnrichment)优先用锚点的页面;这里把已经落盘的补一遍:
// 锚点对得上(归一标题 + 归一专辑 + 署名 + 时长,见 pickAppleCatalogAnchor)、链接是空的或指向别的曲目 ID 的,换成锚点
// 的页面。较早落盘的锚点没有页面地址,先按 ID 批量问(中国区,问不到的再问美区,跟 appleCatalogLookup 同一个顺序)补上、
// 写回锚点缓存。
//
// 要联网,放后台、不挡启动,跟 apple_single_links 同一套水位:有一批没问成就不记,下次启动再来;问成了的那部分照常写。
const (
	migrationAppleCatalogLinks        = "apple_catalog_links"
	migrationAppleCatalogLinksVersion = 1

	// appleCatalogLinkMigrationDelay:比 apple_single_links 晚一分钟开始,两边错开问 iTunes。
	appleCatalogLinkMigrationDelay = 3 * time.Minute
)

// applyAppleCatalogLinkLocked:缓存命中时把条目的 apple_music_url 换成锚点的页面,返回是否真的改了(调用方据此决定要不要
// 落盘)。没有锚点链接、或已经是它时不动。**调用方必须持有 enrichMu**(同 applyRadioDurationHintLocked 的约定)。
func applyAppleCatalogLinkLocked(e *enrichEntry, anchorLink string) bool {
	if anchorLink == "" || e.AppleURL == anchorLink {
		return false
	}
	e.AppleURL = anchorLink
	return true
}

// appleCatalogAnchorEntry:锚点缓存里的一条,带上它的曲目 ID(缓存的键)。
type appleCatalogAnchorEntry struct {
	trackID string
	track   appleCatalogTrack
}

// appleCatalogLinkCandidate:一条要换链接的歌词缓存条目。url 是读的时候的链接,写回时它没被别处改过才动。
type appleCatalogLinkCandidate struct {
	key, url, trackID string
}

// appleCatalogAnchorsByKeyLocked:锚点缓存按「归一标题|归一专辑」分桶,桶内按曲目 ID 排序(谁先被挑中不随 map 遍历次序变)。
// 调用方持 appleCatalogMu。
func appleCatalogAnchorsByKeyLocked() map[string][]appleCatalogAnchorEntry {
	ids := make([]string, 0, len(appleCatalogCache))
	for id := range appleCatalogCache {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make(map[string][]appleCatalogAnchorEntry, len(ids))
	for _, id := range ids {
		t := appleCatalogCache[id]
		k := appleCatalogIndexKey(t.TrackName, t.AlbumName)
		out[k] = append(out[k], appleCatalogAnchorEntry{trackID: id, track: t})
	}
	return out
}

// appleCatalogLinkCandidates 挑出要换链接的条目:同一个归一键下署名对得上的锚点里按时长挑出一条(pickAppleCatalogAnchor),
// 链接是空的、或指向的曲目 ID 不在这几条锚点里。链接已经指向其中任何一条的不动(同名同专辑的几版,哪版都是放过的)。
// 没报专辑名的不挑(锚点索引本来就不收)。结果按 key 排序。纯函数。
func appleCatalogLinkCandidates(entries map[string]enrichEntry, anchors map[string][]appleCatalogAnchorEntry) []appleCatalogLinkCandidate {
	var out []appleCatalogLinkCandidate
	for k, e := range entries {
		artist, title, album := splitEnrichKey(k)
		title = enrichKeyDurationVariantRe.ReplaceAllString(title, "")
		if strings.TrimSpace(album) == "" {
			continue
		}
		var ids []string
		var tracks []appleCatalogTrack
		for _, a := range anchors[appleCatalogIndexKey(title, album)] {
			if appleCatalogArtistFits(artist, a.track) {
				ids = append(ids, a.trackID)
				tracks = append(tracks, a.track)
			}
		}
		if len(ids) == 0 {
			continue
		}
		if cur := appleCatalogIDFromURL(e.AppleURL); cur != "" && slices.Contains(ids, cur) {
			continue
		}
		secs := e.DurationSecs
		if secs <= 0 {
			secs = e.ResolvedDurationSecs
		}
		i := pickAppleCatalogAnchor(tracks, secs)
		if i < 0 {
			continue
		}
		out = append(out, appleCatalogLinkCandidate{key: k, url: e.AppleURL, trackID: ids[i]})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].key < out[j].key })
	return out
}

// startAppleCatalogLinkMigration:常驻进程启动后调。范围照迁移水位定,这一轮不用扫就什么都不做。
func startAppleCatalogLinkMigration(ctx context.Context) {
	scope := migrationScopeOf(migrationAppleCatalogLinks, migrationAppleCatalogLinksVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(appleCatalogLinkMigrationDelay):
		}
		migrateAppleCatalogLinks(ctx, scope, appleLinkRecheckPause)
	}()
}

// migrateAppleCatalogLinks 是迁移本体,返回换了几条、要补的页面地址是不是都问成了(问成了才记水位)。查询在锁外;
// 写回时链接还是当初读的那一个才改。
func migrateAppleCatalogLinks(ctx context.Context, scope migrationScope, pause time.Duration) (int, bool) {
	enrichMu.Lock()
	entries := make(map[string]enrichEntry, len(scope.entries()))
	for k, e := range scope.entries() {
		entries[k] = e
	}
	enrichMu.Unlock()
	appleCatalogMu.Lock()
	anchors := appleCatalogAnchorsByKeyLocked()
	appleCatalogMu.Unlock()
	candidates := appleCatalogLinkCandidates(entries, anchors)

	var missing []string
	seen := map[string]bool{}
	for _, c := range candidates {
		if !seen[c.trackID] && appleCatalogTrackViewURL(c.trackID) == "" {
			seen[c.trackID] = true
			missing = append(missing, c.trackID)
		}
	}
	complete := fillAppleCatalogTrackViewURLs(ctx, missing, pause)
	if ctx.Err() != nil {
		return 0, false
	}

	filled, replaced := 0, 0
	enrichMu.Lock()
	for _, c := range candidates {
		e, ok := enrichCache[c.key]
		if !ok || e.AppleURL != c.url {
			continue
		}
		u := appleCatalogTrackViewURL(c.trackID)
		if u == "" {
			continue
		}
		if e.AppleURL == "" {
			filled++
		} else {
			replaced++
		}
		e.AppleURL = u
		enrichCache[c.key] = e
	}
	if filled+replaced > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if filled+replaced > 0 {
		saveEnrichCache()
	}
	log.Printf("apple catalog links: %d entries match a catalog anchor, %d filled, %d replaced, %d anchors looked up, complete=%v",
		len(candidates), filled, replaced, len(missing), complete)
	if complete {
		markMigrationDone(migrationAppleCatalogLinks, migrationAppleCatalogLinksVersion)
	}
	return filled + replaced, complete
}

// appleCatalogTrackViewURL:锚点缓存里这条曲目的页面地址,没有给空串。
func appleCatalogTrackViewURL(trackID string) string {
	appleCatalogMu.Lock()
	defer appleCatalogMu.Unlock()
	return appleCatalogCache[trackID].TrackViewURL
}

// fillAppleCatalogTrackViewURLs 给这些锚点补页面地址:按 ID 批量问中国区,中国区答了却没有的再问美区(appleCatalogLookup
// 同一个顺序)。问到的写回锚点缓存并落盘;返回是否每一批都问成了。
func fillAppleCatalogTrackViewURLs(ctx context.Context, ids []string, pause time.Duration) bool {
	complete := true
	pending := ids
	for _, country := range []string{"cn", "us"} {
		var notFound []string
		for i := 0; i < len(pending); i += appleLinkRecheckBatch {
			if ctx.Err() != nil {
				return false
			}
			batch := pending[i:min(i+appleLinkRecheckBatch, len(pending))]
			found, ok := itunesLookupTrackIDs(ctx, batch, country)
			if !ok {
				complete = false
				continue
			}
			appleCatalogMu.Lock()
			for _, id := range batch {
				r, hit := found[id]
				if !hit || r.TrackViewURL == "" {
					notFound = append(notFound, id)
					continue
				}
				if t, cached := appleCatalogCache[id]; cached && t.TrackViewURL == "" {
					t.TrackViewURL = r.TrackViewURL
					appleCatalogCache[id] = t
					appleCatalogKeyIndex = nil
					appleCatalogDirty = true
				}
			}
			appleCatalogMu.Unlock()
			if pause > 0 {
				time.Sleep(pause)
			}
		}
		pending = notFound
		if len(pending) == 0 {
			break
		}
	}
	saveAppleCatalogCache()
	return complete
}
