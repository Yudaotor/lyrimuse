package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"slices"
	"sort"
	"time"
)

// Apple 目录名字补扫(歌曲实体阶段 2,18 章决策 13):缓存条目上 Apple 链接里的歌曲 id,按美区、中国区、台区各取一次歌名、
// 歌手、audioLocale 和时长,按 id 存进 `lyrimuse-apple-catalog-names.json`(派生数据,丢了重取)。建实体表时先核对链接没配错
// (attachAppleNames),再拿各区的名字当名字证据(nameEdges)、audioLocale 进无人声否决。

const (
	appleNamesFileVersion = 1
	// appleNamesDelay 排在实体表第一次重建(songEntityBuildDelay)之前;补到新结果后自己再重建一次。
	appleNamesDelay    = 2 * time.Minute
	appleNamesInterval = 24 * time.Hour
	// appleNamesBatch:amp-api 的 songs?ids= 一次最多 300 个,301 个回 400「Too Many Ids」。
	appleNamesBatch   = 300
	appleNamesPace    = time.Second
	appleNamesRecheck = 180 * 24 * time.Hour
	// songEvidenceAppleName:同一个 Apple 歌曲 id 在某个区的名字跟另一条写法对得上。排在全部证据之后加:名字只补并,
	// 不改变别的证据先并出来的结构(排在前面会改变加边顺序,让原来并上的撞上否决)。
	songEvidenceAppleName = "apple_name"
)

var appleNamesStorefronts = []string{"us", "cn", "tw"}

type appleCatalogName struct {
	Name   string `json:"name"`
	Artist string `json:"artist"`
}

// appleCatalogNames:一个 Apple 歌曲 id 在各区的名字(那个区没上架时没有)。Checked 是问的时刻,三个区都没有时 Names 为空。
type appleCatalogNames struct {
	Names        map[string]appleCatalogName `json:"names,omitempty"`
	AudioLocale  string                      `json:"audio_locale,omitempty"`
	DurationSecs float64                     `json:"duration_secs,omitempty"`
	Checked      int64                       `json:"checked"`
}

type appleNamesFile struct {
	Version int                          `json:"version"`
	Songs   map[string]appleCatalogNames `json:"songs"`
}

func appleNamesPath() string { return configFilePath(clientName + "-apple-catalog-names.json") }

// readAppleNames 读补扫结果;缺失、坏掉、版本对不上都返回空表。
func readAppleNames(path string) map[string]appleCatalogNames {
	out := map[string]appleCatalogNames{}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return out
	}
	var f appleNamesFile
	if err := json.Unmarshal(data, &f); err != nil {
		noteFileErr("decode", path, err)
		return out
	}
	if f.Version != appleNamesFileVersion || f.Songs == nil {
		return out
	}
	return f.Songs
}

func writeAppleNames(path string, songs map[string]appleCatalogNames) error {
	data, err := json.Marshal(appleNamesFile{Version: appleNamesFileVersion, Songs: songs})
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data)
}

// appleNamesDue:缓存条目上的 Apple 歌曲 id 里没问过、或问过超过 appleNamesRecheck 的,排好序。
func appleNamesDue(entries map[string]enrichEntry, have map[string]appleCatalogNames, now time.Time) []string {
	seen := map[string]bool{}
	var out []string
	for _, e := range entries {
		id := appleCatalogIDFromURL(e.AppleURL)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		if rec, ok := have[id]; ok && now.Sub(time.Unix(rec.Checked, 0)) < appleNamesRecheck {
			continue
		}
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// fetchAppleNames 按 appleNamesBatch 一批、三个区各问一遍,结果并进 have,返回发了几次请求。一批里有一个区没问成,这一批
// 都不记,下次再问。fetch 是按区取一批 id,ok=false 表示没问成。两次请求之间隔 pace。
func fetchAppleNames(ctx context.Context, ids []string, have map[string]appleCatalogNames, now time.Time, pace time.Duration,
	fetch func(ctx context.Context, storefront string, ids []string) (map[string]appleCatalogSong, bool)) int {
	requests := 0
	for start := 0; start < len(ids); start += appleNamesBatch {
		batch := ids[start:min(start+appleNamesBatch, len(ids))]
		got := map[string]map[string]appleCatalogSong{}
		complete := true
		for _, sf := range appleNamesStorefronts {
			if ctx.Err() != nil {
				return requests
			}
			songs, ok := fetch(ctx, sf, batch)
			requests++
			if !ok {
				complete = false
				break
			}
			got[sf] = songs
			select {
			case <-ctx.Done():
				return requests
			case <-time.After(pace):
			}
		}
		if !complete {
			continue
		}
		for _, id := range batch {
			rec := appleCatalogNames{Checked: now.Unix()}
			for _, sf := range appleNamesStorefronts {
				s, ok := got[sf][id]
				if !ok {
					continue
				}
				if rec.Names == nil {
					rec.Names = map[string]appleCatalogName{}
				}
				rec.Names[sf] = appleCatalogName{Name: s.title, Artist: s.artist}
				if rec.AudioLocale == "" {
					rec.AudioLocale = s.audioLocale
				}
				if rec.DurationSecs == 0 {
					rec.DurationSecs = s.durationSecs
				}
			}
			have[id] = rec
		}
	}
	return requests
}

// startAppleNamesSweep 由 poller 单开一个 goroutine:启动后 appleNamesDelay 补一次,之后每 appleNamesInterval 一次,只问到期的 id;
// 补到了新结果、实体表开着,就重建一次实体表,不等它每天那一次。
func startAppleNamesSweep(ctx context.Context) {
	timer := time.NewTimer(appleNamesDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		if features().SongEntityPhase2 && sweepAppleNames(ctx, appleNamesPath(), time.Now()) > 0 && features().SongEntityShadow {
			rebuildSongEntityTable(time.Now())
		}
		timer.Reset(appleNamesInterval)
	}
}

// sweepAppleNames 补一轮,返回这一轮记下了几个 id(问成了的)。
func sweepAppleNames(ctx context.Context, path string, now time.Time) int {
	enrichMu.Lock()
	entries := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		entries[k] = v
	}
	enrichMu.Unlock()
	have := readAppleNames(path)
	due := appleNamesDue(entries, have, now)
	if len(due) == 0 {
		return 0
	}
	requests := fetchAppleNames(ctx, due, have, now, appleNamesPace, appleCatalogSongsByID)
	settled := 0
	for _, id := range due {
		if have[id].Checked == now.Unix() {
			settled++
		}
	}
	if err := writeAppleNames(path, have); err != nil {
		slog.Error("song entities: write apple names", "err", err)
		return 0
	}
	slog.Info("song entities: apple names swept", "due", len(due), "settled", settled, "requests", requests, "known", len(have))
	return settled
}

// attachAppleNames 把补扫到的名字挂到写法上。先核对这条写法的 Apple 链接没配错:目录里那一轨的时长跟写法差不超过
// isrcDurationFits 的容差,而且至少一个区的歌名跟写法的写法族键相同(带版本尾巴的那一版不算)、歌手也对得上;过了才带上
// 各区的名字和 audioLocale。
func attachAppleNames(vs []songVariant, names map[string]appleCatalogNames) {
	for i := range vs {
		v := &vs[i]
		rec, ok := names[v.id(songIDAppleSong)]
		if !ok || len(rec.Names) == 0 || !isrcDurationFits(v.durationSecs, rec.DurationSecs) {
			continue
		}
		verified := false
		for _, n := range rec.Names {
			if songFamilyTitle(n.Name) == v.family && songArtistMatch(v.primary, artistCreditPrimary(n.Artist)) {
				verified = true
				break
			}
		}
		if !verified {
			continue
		}
		for _, sf := range appleNamesStorefronts {
			if n, ok := rec.Names[sf]; ok && !slices.Contains(v.appleNames, n) {
				v.appleNames = append(v.appleNames, n)
			}
		}
		v.audioLocale = rec.AudioLocale
	}
}

// attachSpotifyLanguages:带 Spotify 曲目 id 的写法,从 Spotify 本机元数据缓存读演唱语言(languagesOf,按曲目 id 查),有
// zxx 记成 zxx,否则记第一个;覆盖 attachAppleNames 挂的 audioLocale(Spotify 曲目 id 是播放器给的,Apple 链接是检索配的)。
func attachSpotifyLanguages(vs []songVariant, languagesOf func(trackID string) []string) {
	for i := range vs {
		id := vs[i].id(songIDSpotifyTrack)
		if id == "" {
			continue
		}
		langs := languagesOf(id)
		switch {
		case len(langs) == 0:
		case slices.Contains(langs, "zxx"):
			vs[i].audioLocale = "zxx"
		default:
			vs[i].audioLocale = langs[0]
		}
	}
}

// spotifyLanguagesForVariants:attachSpotifyLanguages 的查询,一次批量读完这批写法的 Spotify 曲目。
func spotifyLanguagesForVariants(vs []songVariant) func(trackID string) []string {
	var ids []string
	for i := range vs {
		if id := vs[i].id(songIDSpotifyTrack); id != "" {
			ids = append(ids, id)
		}
	}
	metas := spotifyLocalTrackMetas(ids, func(v []byte) bool { return len(spotifyTrackLanguages(v)) > 0 })
	return func(trackID string) []string { return spotifyTrackLanguages(metas[trackID]) }
}

// songRegisteredViaAppleNames:平台登记的歌名跟写法歌名一中一外时,写法挂着的(核对过的)Apple 名字里有一个区跟登记歌名
// 同一种文字、对得上,就当登记歌名对上了(18 章决策 16)。
func songRegisteredViaAppleNames(v *songVariant, registered string) bool {
	for _, n := range v.appleNames {
		if ok, _ := songTitlesCompatible(registered, n.Name); ok {
			return true
		}
	}
	return false
}

// nameEdges:带核对过的 Apple 名字的写法 y,某个区的歌手跟另一条写法 x 的主歌手对得上、歌名的写法族键相同、两边都有时长且
// 差不超过时长闸,连一条名字边。x 跟 y 本来就同一位主歌手、同一个写法族时不连(写法族边管)。
func (b *songEdgeBuilder) nameEdges() {
	byFamily := map[string][]int{}
	for i := range b.vs {
		if f := b.vs[i].family; f != "" {
			byFamily[f] = append(byFamily[f], i)
		}
	}
	for yi := range b.vs {
		y := &b.vs[yi]
		for _, n := range y.appleNames {
			for _, xi := range byFamily[songFamilyTitle(n.Name)] {
				x := &b.vs[xi]
				if xi == yi || !songArtistMatch(x.primary, artistCreditPrimary(n.Artist)) {
					continue
				}
				if x.family == y.family && songArtistMatch(x.primary, y.primary) {
					continue
				}
				if ok, known := songDurationsWithinGate(x, y); !ok || !known {
					b.drop(songEvidenceAppleName, "duration", 1)
					continue
				}
				b.add(songEdge{kind: songEvidenceAppleName, a: xi, b: yi, value: y.id(songIDAppleSong)})
			}
		}
	}
}
