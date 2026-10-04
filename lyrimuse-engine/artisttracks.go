package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	neturl "net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"time"
)

// `lyrimuse-engine artist-tracks -period <7day|1month|12month|overall> [-tracks N] <歌手名>...`:
// 给 App「听得最多」歌手榜的展开行用 —— 每位歌手在这个时段里听得最多的几首。
//
// 歌名来自同一时段 user.getTopTracks 的全部分页,按歌手榜的合并规则(artistMergeGroups)归到
// 命令行传进来的名字下:传的就是 App 榜单上显示的名字,「周杰倫 / 周杰伦 / Jay Chou」、合唱
// 「Prince & The Revolution」都落到对应那一行。凭据读 config.json,不走命令行,同 top-artists。
//
// 输出一行 JSON:{"rows":{"<歌手名>":{"tracks":[{name,artist,playCount}],"trackCount":N,"playCount":M}},
// "complete":bool}。某个名字一首都没归到时不出现在 rows 里;complete=false 表示分页超过
// -max-pages 没取完,trackCount / playCount 是下限。
//
// -progress:分页不止一页时,第 1 页一到先多输出一行同形态、带 "partial":true 的结果,再输出最终那行。
// 歌曲榜按次数降序,第 2 页以后每首的次数都不高于第 1 页的任何一首,所以 partial 里每位歌手的歌是
// 完整结果的前几首(顺序也对,只是可能更短);它的 trackCount / playCount 不能用。
func runArtistTracksCLI(args []string) {
	fs := flag.NewFlagSet("artist-tracks", flag.ExitOnError)
	period := fs.String("period", "overall", "7day|1month|12month|overall")
	perArtist := fs.Int("tracks", 10, "tracks listed per artist")
	maxPages := fs.Int("max-pages", artistTracksMaxPages, "stop after N pages of 1000 tracks")
	progress := fs.Bool("progress", false, "print a partial result line after the first page")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("artist-tracks: %v", err)
	}
	names := fs.Args()
	switch *period {
	case "7day", "1month", "3month", "6month", "12month", "overall":
	default:
		log.Fatalf("artist-tracks: invalid -period %q", *period)
	}
	if len(names) == 0 {
		log.Fatal("artist-tracks: no artist names given")
	}
	if *perArtist < 1 {
		*perArtist = 10
	}
	if *maxPages < 1 {
		*maxPages = artistTracksMaxPages
	}
	if configDir() == "" {
		log.Fatalf("artist-tracks: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfg, err := loadConfig(filepath.Join(configDir(), "config.json"))
	if err != nil {
		log.Fatalf("artist-tracks: load config: %v", err)
	}
	if cfg.LastfmUser == "" || cfg.lastfmBridgeAPIKey() == "" {
		log.Fatal("artist-tracks: lastfm_user / api key not configured")
	}
	resolve := loadTopArtistsCaches(0)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	enc := json.NewEncoder(os.Stdout)
	var onFirst func([]artistTrack)
	if *progress {
		onFirst = func(first []artistTrack) {
			partial := artistTracksOutput{
				Rows:    groupTracksByArtists(names, first, resolve, artistMergeNameKey, *perArtist),
				Partial: true,
			}
			if err := enc.Encode(partial); err != nil {
				log.Fatalf("artist-tracks: encode: %v", err)
			}
		}
	}
	tracks, complete, err := lastfmTopTracksAll(ctx, cfg.LastfmUser, cfg.lastfmBridgeAPIKey(), *period, *maxPages, onFirst)
	if err != nil {
		log.Fatalf("artist-tracks: fetch: %v", err)
	}
	out := artistTracksOutput{
		Rows:     groupTracksByArtists(names, tracks, resolve, artistMergeNameKey, *perArtist),
		Complete: complete,
	}
	if err := enc.Encode(out); err != nil {
		log.Fatalf("artist-tracks: encode: %v", err)
	}
}

// artistTracksMaxPages:分页上限。每页 1000 首,20 页 = 两万首不同的歌,够绝大多数账号的「全部」;
// 再多就是给 App 一次性打几十个请求,展开一行不值得。
const artistTracksMaxPages = 20

// artistTracksPageConcurrency:第 1 页拿到总页数之后,其余分页同时在飞的请求数。
const artistTracksPageConcurrency = 4

// artistTracksPageTimeout:一页的超时。一页 1000 首实测约 3.5 秒;Last.fm 的本地出站闸每秒放 1 个、攒 5 个,
// 分页超过 5 页时后面的页要先排队,而超时是从排队算起的 —— 按通用的 8 秒,排两三秒之后就只剩几秒下载,
// 任何一页超时整份作废。
const artistTracksPageTimeout = 20 * time.Second

type artistTrack struct {
	Name       string `json:"name"`
	Artist     string `json:"artist"`
	PlayCount  int    `json:"playCount"`
	artistMbid string
}

type artistTracksRow struct {
	Tracks     []artistTrack `json:"tracks"`
	TrackCount int           `json:"trackCount"`
	PlayCount  int           `json:"playCount"`
}

type artistTracksOutput struct {
	Rows     map[string]artistTracksRow `json:"rows"`
	Complete bool                       `json:"complete"`
	Partial  bool                       `json:"partial,omitempty"`
}

// lastfmTopTracksPage 取 user.getTopTracks 的一页(每页 1000 首),同时返回总页数。
func lastfmTopTracksPage(ctx context.Context, user, apiKey, period string, page int) ([]artistTrack, int, error) {
	var out struct {
		TopTracks struct {
			Track []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Artist    struct {
					Name string `json:"name"`
					Mbid string `json:"mbid"`
				} `json:"artist"`
			} `json:"track"`
			Attr struct {
				TotalPages string `json:"totalPages"`
			} `json:"@attr"`
		} `json:"toptracks"`
	}
	params := neturl.Values{
		"method": {"user.getTopTracks"}, "user": {user}, "api_key": {apiKey},
		"period": {period}, "limit": {"1000"}, "page": {strconv.Itoa(page)},
	}
	if err := lastfmAPIGetTimeout(ctx, params, &out, artistTracksPageTimeout); err != nil {
		return nil, 0, err
	}
	rows := make([]artistTrack, 0, len(out.TopTracks.Track))
	for _, t := range out.TopTracks.Track {
		if t.Name == "" || t.Artist.Name == "" {
			continue
		}
		pc, _ := strconv.Atoi(t.PlayCount)
		rows = append(rows, artistTrack{Name: t.Name, Artist: t.Artist.Name, PlayCount: pc, artistMbid: t.Artist.Mbid})
	}
	total, _ := strconv.Atoi(out.TopTracks.Attr.TotalPages)
	return rows, total, nil
}

// lastfmTopTracksAll 取完一个时段的歌曲榜:先取第 1 页拿总页数,其余分页并发取,按页序拼回去
// (保持次数降序)。任何一页失败整体算失败 —— 少一页会让某些歌手的次数静默变少。
// complete=false = 总页数超过 maxPages,只取了前 maxPages 页。onFirst 非空时,还有别的分页要取才在
// 第 1 页到手后调它一次(只有一页时直接返回,不调)。
func lastfmTopTracksAll(ctx context.Context, user, apiKey, period string, maxPages int, onFirst func([]artistTrack)) ([]artistTrack, bool, error) {
	first, total, err := lastfmTopTracksPage(ctx, user, apiKey, period, 1)
	if err != nil {
		return nil, false, err
	}
	last := total
	if last > maxPages {
		last = maxPages
	}
	if last <= 1 {
		return first, total <= maxPages, nil
	}
	if onFirst != nil {
		onFirst(first)
	}
	pages := make([][]artistTrack, last+1)
	pages[1] = first
	errs := make([]error, last+1)
	sem := make(chan struct{}, artistTracksPageConcurrency)
	var wg sync.WaitGroup
	for p := 2; p <= last; p++ {
		wg.Add(1)
		go func(p int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			pages[p], _, errs[p] = lastfmTopTracksPage(ctx, user, apiKey, period, p)
		}(p)
	}
	wg.Wait()
	var all []artistTrack
	for p := 1; p <= last; p++ {
		if errs[p] != nil {
			return nil, false, fmt.Errorf("page %d: %w", p, errs[p])
		}
		all = append(all, pages[p]...)
	}
	return all, total <= maxPages, nil
}

// groupTracksByArtists 把歌曲按署名归到 names(App 榜单上显示的歌手名)下。
//
// 做法是把 names 和所有出现过的署名放进同一次 artistMergeGroups:落在同一桶里的署名就归那位歌手,
// 判「是不是同一个人」跟歌手榜本身完全同一把尺子(名字键、mbid、身份解析的中文名)。署名按次数
// 降序排在 names 后面,跟榜单合并时的输入顺序同一种形态。两个名字落进同一桶时归先出现的那个。
// 每位歌手的歌按次数降序、平手保持输入次序,只留前 perArtist 首;trackCount / playCount 按全部算。
func groupTracksByArtists(names []string, tracks []artistTrack, resolve artistIdentityFn, nameKey func(string) string, perArtist int) map[string]artistTracksRow {
	type credit struct {
		name  string
		mbid  string
		plays int
	}
	creditIndex := map[string]int{}
	var credits []credit
	for _, t := range tracks {
		i, ok := creditIndex[t.Artist]
		if !ok {
			i = len(credits)
			creditIndex[t.Artist] = i
			credits = append(credits, credit{name: t.Artist, mbid: t.artistMbid})
		}
		credits[i].plays += t.PlayCount
		if credits[i].mbid == "" {
			credits[i].mbid = t.artistMbid
		}
	}
	order := make([]int, len(credits))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return credits[order[a]].plays > credits[order[b]].plays })

	entries := make([]lastfmChartEntry, 0, len(names)+len(credits))
	for _, n := range names {
		entries = append(entries, lastfmChartEntry{Name: n})
	}
	entryOfCredit := make([]int, len(credits))
	for _, ci := range order {
		entryOfCredit[ci] = len(entries)
		c := credits[ci]
		entries = append(entries, lastfmChartEntry{Name: c.name, PlayCount: c.plays, Mbid: c.mbid})
	}
	find, _ := artistMergeGroups(entries, resolve, nameKey)

	owner := map[int]string{}
	for i, n := range names {
		if _, taken := owner[find(i)]; !taken {
			owner[find(i)] = n
		}
	}
	grouped := map[string][]artistTrack{}
	for _, t := range tracks {
		name, ok := owner[find(entryOfCredit[creditIndex[t.Artist]])]
		if !ok {
			continue
		}
		grouped[name] = append(grouped[name], t)
	}
	out := make(map[string]artistTracksRow, len(grouped))
	for name, ts := range grouped {
		sort.SliceStable(ts, func(a, b int) bool { return ts[a].PlayCount > ts[b].PlayCount })
		row := artistTracksRow{TrackCount: len(ts)}
		for _, t := range ts {
			row.PlayCount += t.PlayCount
		}
		if len(ts) > perArtist {
			ts = ts[:perArtist]
		}
		row.Tracks = ts
		out[name] = row
	}
	return out
}
