package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 网易云登记名与别名补扫(歌曲实体阶段 2,18 章决策 18):缓存条目上网易云链接里的歌曲 id 按批问歌曲详情,登记歌名、歌手、
// 别名与译名(alias、transNames)、时长按 id 存进 `lyrimuse-netease-names.json`(派生数据,丢了重取)。建实体表时先核对链接
// (attachNeteaseNames),再跟 Apple 名字一样当名字证据。

const (
	neteaseNamesFileVersion = 1
	neteaseNamesDelay       = 3 * time.Minute
	neteaseNamesInterval    = 24 * time.Hour
	// neteaseNamesBatch:/api/song/detail 一次 200 个能回,1,000 个回 400。
	neteaseNamesBatch       = 200
	neteaseNamesPace        = time.Second
	neteaseNamesRecheck     = 180 * 24 * time.Hour
	songEvidenceNeteaseName = "netease_name"
)

// neteaseCatalogName:一个网易云歌曲 id 的登记信息。网易云没有这首时 Name 为空。
type neteaseCatalogName struct {
	Name         string   `json:"name,omitempty"`
	Artists      []string `json:"artists,omitempty"`
	Aliases      []string `json:"aliases,omitempty"`
	DurationSecs float64  `json:"duration_secs,omitempty"`
	Checked      int64    `json:"checked"`
}

type neteaseNamesFile struct {
	Version int                           `json:"version"`
	Songs   map[string]neteaseCatalogName `json:"songs"`
}

func neteaseNamesPath() string { return configFilePath(clientName + "-netease-names.json") }

// readNeteaseNames 读补扫结果;缺失、坏掉、版本对不上都返回空表。
func readNeteaseNames(path string) map[string]neteaseCatalogName {
	out := map[string]neteaseCatalogName{}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return out
	}
	var f neteaseNamesFile
	if err := json.Unmarshal(data, &f); err != nil {
		noteFileErr("decode", path, err)
		return out
	}
	if f.Version != neteaseNamesFileVersion || f.Songs == nil {
		return out
	}
	return f.Songs
}

func writeNeteaseNames(path string, songs map[string]neteaseCatalogName) error {
	data, err := json.Marshal(neteaseNamesFile{Version: neteaseNamesFileVersion, Songs: songs})
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data)
}

// neteaseNamesDue:缓存条目上网易云链接里的歌曲 id 里没问过、或问过超过 neteaseNamesRecheck 的,排好序。
func neteaseNamesDue(entries map[string]enrichEntry, have map[string]neteaseCatalogName, now time.Time) []string {
	seen := map[string]bool{}
	var out []string
	for _, e := range entries {
		id := neteaseSongIDFromURL(e.NeteaseURL)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		if rec, ok := have[id]; ok && now.Sub(time.Unix(rec.Checked, 0)) < neteaseNamesRecheck {
			continue
		}
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// fetchNeteaseNames 按 neteaseNamesBatch 一批问,结果并进 have(这一批里网易云没有的也记成问过),返回发了几次请求、问完了
// 没有。一批没问成就等 backoff 再问(规则见 catalogSweepBackoff);每问成 catalogSweepSaveEvery 批调一次 save。两次请求之间隔 pace。
func fetchNeteaseNames(ctx context.Context, ids []string, have map[string]neteaseCatalogName, now time.Time, pace, backoff time.Duration,
	fetch func(ctx context.Context, ids []string) (map[string]neteaseCatalogName, bool), save func()) (int, bool) {
	requests, failures, done := 0, 0, 0
	for start := 0; start < len(ids); {
		if ctx.Err() != nil {
			return requests, false
		}
		batch := ids[start:min(start+neteaseNamesBatch, len(ids))]
		got, ok := fetch(ctx, batch)
		requests++
		if !ok {
			if failures++; failures >= catalogSweepMaxFailures || !sleepCtx(ctx, backoff) {
				return requests, false
			}
			continue
		}
		failures = 0
		start += len(batch)
		for _, id := range batch {
			rec := got[id]
			rec.Checked = now.Unix()
			have[id] = rec
		}
		if done++; done%catalogSweepSaveEvery == 0 {
			save()
		}
		if !sleepCtx(ctx, pace) {
			return requests, false
		}
	}
	return requests, true
}

// neteaseSongDetails 问一批歌曲详情;ok=false 表示没问成(网络、限流、网易云回的 code 不是 200)。
func neteaseSongDetails(ctx context.Context, ids []string) (map[string]neteaseCatalogName, bool) {
	body, err := neteaseFetchBody(ctx, "https://music.163.com/api/song/detail/?ids=["+strings.Join(ids, ",")+"]", "", 8*time.Second)
	if err != nil {
		return nil, false
	}
	var resp struct {
		Code  int `json:"code"`
		Songs []struct {
			ID         int64    `json:"id"`
			Name       string   `json:"name"`
			Alias      []string `json:"alias"`
			TransNames []string `json:"transNames"`
			Duration   float64  `json:"duration"`
			Artists    []struct {
				Name string `json:"name"`
			} `json:"artists"`
		} `json:"songs"`
	}
	if json.Unmarshal(body, &resp) != nil || resp.Code != 200 {
		return nil, false
	}
	out := make(map[string]neteaseCatalogName, len(resp.Songs))
	for _, s := range resp.Songs {
		rec := neteaseCatalogName{Name: s.Name, DurationSecs: s.Duration / 1000}
		for _, a := range s.Artists {
			if a.Name != "" {
				rec.Artists = append(rec.Artists, a.Name)
			}
		}
		for _, n := range append(slices.Clone(s.Alias), s.TransNames...) {
			if n = strings.TrimSpace(n); n != "" && n != s.Name && !slices.Contains(rec.Aliases, n) {
				rec.Aliases = append(rec.Aliases, n)
			}
		}
		out[strconv.FormatInt(s.ID, 10)] = rec
	}
	return out, true
}

// startNeteaseNamesSweep 由 poller 单开一个 goroutine:启动后 neteaseNamesDelay 补一次,之后每 neteaseNamesInterval 一次;
// 补到了新结果、实体表开着,就重建一次实体表。
func startNeteaseNamesSweep(ctx context.Context) {
	timer := time.NewTimer(neteaseNamesDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		next := neteaseNamesInterval
		if features().SongEntityPhase2 {
			settled, complete := sweepNeteaseNames(ctx, neteaseNamesPath(), time.Now())
			if settled > 0 && features().SongEntityShadow {
				rebuildSongEntityTableForEvidence(time.Now())
			}
			if !complete {
				next = catalogSweepRetry
			}
		}
		timer.Reset(next)
	}
}

// sweepNeteaseNames 补一轮,返回这一轮记下了几个 id(问成了的)、到期的问完了没有。
func sweepNeteaseNames(ctx context.Context, path string, now time.Time) (int, bool) {
	enrichMu.Lock()
	entries := make(map[string]enrichEntry, len(enrichCache))
	for k, v := range enrichCache {
		entries[k] = v
	}
	enrichMu.Unlock()
	have := readNeteaseNames(path)
	due := neteaseNamesDue(entries, have, now)
	if len(due) == 0 {
		return 0, true
	}
	save := func() {
		if err := writeNeteaseNames(path, have); err != nil {
			slog.Error("song entities: write netease names", "err", err)
		}
	}
	requests, complete := fetchNeteaseNames(withBackgroundOutbound(ctx), due, have, now, neteaseNamesPace, catalogSweepBackoff,
		neteaseSongDetails, save)
	settled := 0
	for _, id := range due {
		if have[id].Checked == now.Unix() {
			settled++
		}
	}
	if err := writeNeteaseNames(path, have); err != nil {
		slog.Error("song entities: write netease names", "err", err)
		return 0, false
	}
	slog.Info("song entities: netease names swept", "due", len(due), "settled", settled, "requests", requests, "known", len(have),
		"complete", complete)
	return settled, complete
}

// attachNeteaseNames 把补扫到的网易云登记名挂到写法上。先核对这条写法的网易云链接没配错:网易云那一轨的时长跟写法差不超过
// isrcDurationFits 的容差,登记歌名或某个别名跟写法同一个写法族,歌手也对得上;过了才把登记歌名和全部别名挂上。
func attachNeteaseNames(vs []songVariant, names map[string]neteaseCatalogName) {
	for i := range vs {
		v := &vs[i]
		id := v.id(songIDNeteaseSong)
		rec, ok := names[id]
		if !ok || rec.Name == "" || !isrcDurationFits(v.durationSecs, rec.DurationSecs) {
			continue
		}
		titles := append([]string{rec.Name}, rec.Aliases...)
		titleOK := slices.ContainsFunc(titles, func(t string) bool { return songFamilyTitle(t) == v.family })
		artistOK := slices.ContainsFunc(rec.Artists, func(a string) bool { return songArtistMatch(v.primary, artistCreditPrimary(a)) })
		if !titleOK || !artistOK {
			continue
		}
		for _, t := range titles {
			v.addCatalogName(songCatalogName{name: t, artist: rec.Artists[0], kind: songEvidenceNeteaseName, id: id})
		}
	}
}
