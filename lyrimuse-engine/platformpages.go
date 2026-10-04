package main

// 各平台歌手 / 专辑 / 歌曲主页的后台预取,给 App「听得最多」榜单的右键菜单(「在 Spotify 中显示」「在 Apple Music 中打开」)用。
// 歌手与专辑来自 MusicBrainz:歌手条目的 url-rels 登记着 Spotify / Apple Music 歌手页;专辑按「歌手 mbid + 专辑名」搜
// release-group,再看它下面各个 release 的 url-rels 里有没有 Spotify 专辑页。歌曲先从歌词缓存查出它属于哪张专辑,
// 再在那张专辑的 Spotify 嵌入页(open.spotify.com/embed/album/<ID>,公开、不用登录)的曲目表里按歌名找曲目 ID。
// 本机没有别的途径拿到这几类 ID(Spotify 官方接口要登录,见 12 章)。App 只读这份缓存、不联网;歌手的 mbid 取自身份缓存。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	neturl "net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// platformPagesCheckInterval:两轮预取之间至少隔这么久。间隔记在缓存文件里,重启不会提前再跑。
	platformPagesCheckInterval = 6 * time.Hour
	// platformPagesRequestBudget:每轮最多发多少个 MusicBrainz 请求(全局 1.1 s 限速,约一分钟跑完)。
	platformPagesRequestBudget = 60
	// platformPagesChartLimit:每个时段取榜单前多少名,跟 App 榜单一次取的条数一致(ChartVisibleRows.fetchLimit,selftest 对账)。
	platformPagesChartLimit = 50
	// platformPagesRetryAfter:查过但没登记的条目,隔这么久才再查一次。
	platformPagesRetryAfter = 30 * 24 * time.Hour
	// platformPagesPartialRetry:一轮把请求额度用完、还有条目没查时,隔这么久接着查(不等满 platformPagesCheckInterval)。
	platformPagesPartialRetry = 30 * time.Minute
	// platformPagesEmbedBudget:每轮最多取多少张专辑的 Spotify 嵌入页(一张专辑的歌共用一次)。
	platformPagesEmbedBudget = 20
	// platformPagesTrackAlbums:一首歌在歌词缓存里记着几张专辑时,最多试几张。
	platformPagesTrackAlbums = 2
)

// platformPagesPeriods:要预取的榜单时段,跟 App 榜单的四档一致(LastfmStatsService.Period,selftest 对账)。
var platformPagesPeriods = []string{"7day", "1month", "12month", "overall"}

type platformArtistPages struct {
	Spotify string `json:"spotify,omitempty"` // Spotify 歌手 ID(22 位)
	Apple   string `json:"apple,omitempty"`   // Apple Music 歌手页(https)
	Checked int64  `json:"checked"`
}

type platformAlbumPages struct {
	Spotify string `json:"spotify,omitempty"` // Spotify 专辑 ID(22 位)
	Checked int64  `json:"checked"`
}

type platformTrackPages struct {
	Spotify string `json:"spotify,omitempty"` // Spotify 曲目 ID(22 位)
	Checked int64  `json:"checked"`
}

// platformPagesFile 是缓存文件的形状。Swift 侧 PlatformPagesCache 按同一个形状读,改字段两边一起改。
type platformPagesFile struct {
	Updated int64                          `json:"updated"`
	Artists map[string]platformArtistPages `json:"artists"` // 键:歌手 mbid
	Albums  map[string]platformAlbumPages  `json:"albums"`  // 键:platformAlbumKey(歌手, 专辑)
	Tracks  map[string]platformTrackPages  `json:"tracks"`  // 键:platformAlbumKey(歌手, 歌名),同一个算法
}

var (
	platformPagesMu    sync.Mutex
	platformPagesCache = platformPagesFile{Artists: map[string]platformArtistPages{}, Albums: map[string]platformAlbumPages{},
		Tracks: map[string]platformTrackPages{}}
	platformPagesPath string // 空 = 只用内存不持久化(单测)
)

// platformAlbumKey 是专辑条目的键:Last.fm 榜单给的歌手名与专辑名原样去首尾空白、转小写。
// Swift 侧 PlatformPagesCache.albumKey 必须同一个算法。
func platformAlbumKey(artist, album string) string {
	return strings.ToLower(strings.TrimSpace(artist)) + "|" + strings.ToLower(strings.TrimSpace(album))
}

func loadPlatformPagesCache(path string) {
	platformPagesPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f platformPagesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return
	}
	if f.Artists == nil {
		f.Artists = map[string]platformArtistPages{}
	}
	if f.Albums == nil {
		f.Albums = map[string]platformAlbumPages{}
	}
	if f.Tracks == nil {
		f.Tracks = map[string]platformTrackPages{}
	}
	platformPagesMu.Lock()
	platformPagesCache = f
	platformPagesMu.Unlock()
	noteCacheLoaded(path, fmt.Sprintf("platform pages (%d artists, %d albums, %d tracks)", len(f.Artists), len(f.Albums), len(f.Tracks)))
}

func savePlatformPagesCache() {
	platformPagesMu.Lock()
	if platformPagesPath == "" {
		platformPagesMu.Unlock()
		return
	}
	data, err := json.Marshal(platformPagesCache)
	platformPagesMu.Unlock()
	if err != nil {
		return
	}
	if err := writeFileAtomic(platformPagesPath, data); err != nil {
		slog.Error("save platform pages cache", "err", err)
	}
}

// platformPagesSource 是预取要用的联网动作和本机查询,单测换成假的。
type platformPagesSource struct {
	topArtists func(ctx context.Context, period string) ([]lastfmChartEntry, error)
	topAlbums  func(ctx context.Context, period string) ([]lastfmChartEntry, error)
	topTracks  func(ctx context.Context, period string) ([]lastfmChartEntry, error)
	// artistPages 查一位歌手登记的平台主页;albumSpotify 按歌手 mbid + 专辑名找 Spotify 专辑 ID。
	// 两者都返回这次用掉的 MusicBrainz 请求数;err 非空 = 没问成(这次不记结论,下轮再查)。
	artistPages  func(ctx context.Context, mbid string) (platformArtistPages, int, error)
	albumSpotify func(ctx context.Context, mbid, album string) (string, int, error)
	// artistMbid 查一个歌手名在身份缓存里的 mbid,没有返回空。
	artistMbid func(name string) string
	// trackAlbums 查一首歌在歌词缓存里记着哪些专辑名(最多 n 个,次数多的在前)。
	trackAlbums func(artist, title string, n int) []string
	// albumTracks 取一张 Spotify 专辑的曲目表(嵌入页)。
	albumTracks func(ctx context.Context, albumID string) ([]spotifyAlbumTrack, error)
}

// platformPagesDigest 由后台任务(runDigests)调用:距上一轮不到 platformPagesCheckInterval 就跳过;没配 Last.fm 也跳过。
func (p *poller) platformPagesDigest(now time.Time, env digestEnv) {
	user, key := env.cfg.LastfmUser, env.cfg.lastfmBridgeAPIKey()
	if user == "" || key == "" {
		return
	}
	src := platformPagesSource{
		topArtists: func(ctx context.Context, period string) ([]lastfmChartEntry, error) {
			return lastfmTopArtistsPeriod(ctx, user, key, period, platformPagesChartLimit)
		},
		topAlbums: func(ctx context.Context, period string) ([]lastfmChartEntry, error) {
			return lastfmTopAlbumsPeriod(ctx, user, key, period, platformPagesChartLimit)
		},
		topTracks: func(ctx context.Context, period string) ([]lastfmChartEntry, error) {
			return lastfmTopTracksPeriod(ctx, user, key, period, platformPagesChartLimit)
		},
		trackAlbums:  enrichAlbumsFor,
		albumTracks:  spotifyEmbedAlbumTracks,
		artistPages:  mbArtistPlatformPages,
		albumSpotify: mbAlbumSpotifyID,
		artistMbid: func(name string) string {
			id, _ := cachedArtistIdentity(strings.TrimSpace(firstCreditedArtist(name)))
			return id.Mbid
		},
	}
	if warmPlatformPages(env.ctx, now, platformPagesRequestBudget, src) {
		savePlatformPagesCache()
	}
}

// warmPlatformPages 跑一轮预取:距上一轮不到间隔就什么都不做、返回 false。否则取四个时段的歌手榜与专辑榜,
// 按榜单顺序(近期时段在前、名次靠前的在前)给缺的或过期的条目查一次,用掉 budget 个 MusicBrainz 请求就停。
// 本轮时间戳:查完了记现在;额度用完没查完,记成 platformPagesPartialRetry 之后就到期;被取消(进程退出)不记,
// 下次启动接着查。返回 true = 缓存有变化,调用方负责落盘。
func warmPlatformPages(ctx context.Context, now time.Time, budget int, src platformPagesSource) bool {
	platformPagesMu.Lock()
	last := platformPagesCache.Updated
	platformPagesMu.Unlock()
	if last > 0 && now.Sub(time.Unix(last, 0)) < platformPagesCheckInterval {
		return false
	}
	var artists, albums, tracks []lastfmChartEntry
	for _, period := range platformPagesPeriods {
		if rows, err := src.topArtists(ctx, period); err == nil {
			artists = append(artists, rows...)
		}
		if rows, err := src.topAlbums(ctx, period); err == nil {
			albums = append(albums, rows...)
		}
		if src.topTracks != nil {
			if rows, err := src.topTracks(ctx, period); err == nil {
				tracks = append(tracks, rows...)
			}
		}
	}
	if len(artists) == 0 && len(albums) == 0 && len(tracks) == 0 {
		// Last.fm 没取到:这轮不算数、不记任何结论,但也不能下一拍就重试(后台任务每 5 秒一拍,一拍 12 个请求),
		// 记成 platformPagesPartialRetry 之后到期。
		if ctx.Err() == nil {
			platformPagesMu.Lock()
			platformPagesCache.Updated = now.Add(platformPagesPartialRetry - platformPagesCheckInterval).Unix()
			platformPagesMu.Unlock()
		}
		return false
	}
	changed := false
	stale := func(checked int64) bool {
		return checked == 0 || now.Sub(time.Unix(checked, 0)) >= platformPagesRetryAfter
	}

	seenArtist := map[string]bool{}
	for _, a := range artists {
		if budget <= 0 || ctx.Err() != nil {
			break
		}
		mbid := src.artistMbid(a.Name)
		if mbid == "" || seenArtist[mbid] {
			continue
		}
		seenArtist[mbid] = true
		platformPagesMu.Lock()
		cur, ok := platformPagesCache.Artists[mbid]
		platformPagesMu.Unlock()
		if ok && !stale(cur.Checked) {
			continue
		}
		pages, used, err := src.artistPages(ctx, mbid)
		budget -= used
		if err != nil {
			continue
		}
		pages.Checked = now.Unix()
		platformPagesMu.Lock()
		platformPagesCache.Artists[mbid] = pages
		platformPagesMu.Unlock()
		changed = true
	}

	seenAlbum := map[string]bool{}
	for _, al := range albums {
		if budget <= 0 || ctx.Err() != nil {
			break
		}
		key := platformAlbumKey(al.Artist, al.Name)
		if seenAlbum[key] || strings.TrimSpace(al.Name) == "" {
			continue
		}
		seenAlbum[key] = true
		mbid := src.artistMbid(al.Artist)
		if mbid == "" {
			continue
		}
		platformPagesMu.Lock()
		cur, ok := platformPagesCache.Albums[key]
		platformPagesMu.Unlock()
		if ok && !stale(cur.Checked) {
			continue
		}
		id, used, err := src.albumSpotify(ctx, mbid, al.Name)
		budget -= used
		if err != nil {
			continue
		}
		platformPagesMu.Lock()
		platformPagesCache.Albums[key] = platformAlbumPages{Spotify: id, Checked: now.Unix()}
		platformPagesMu.Unlock()
		changed = true
	}

	// 歌曲:歌词缓存里查出专辑 → 专辑的 Spotify ID(没查过就按上面同一个办法查) → 专辑嵌入页的曲目表里按歌名找。
	// 歌词缓存里还没有这首歌的专辑时不记结论(这首歌以后被解析了还能再查)。
	embedBudget := platformPagesEmbedBudget
	albumTrackLists := map[string][]spotifyAlbumTrack{}
	// 这一轮取失败的嵌入页:同一张专辑的其余曲目不再重取,也不记结论。
	albumTrackFailed := map[string]bool{}
	seenTrack := map[string]bool{}
	outOfBudget := false
	for _, tr := range tracks {
		if budget <= 0 || ctx.Err() != nil || src.trackAlbums == nil || src.albumTracks == nil {
			outOfBudget = outOfBudget || budget <= 0
			break
		}
		key := platformAlbumKey(tr.Artist, tr.Name)
		if seenTrack[key] || strings.TrimSpace(tr.Name) == "" {
			continue
		}
		seenTrack[key] = true
		platformPagesMu.Lock()
		cur, ok := platformPagesCache.Tracks[key]
		platformPagesMu.Unlock()
		if ok && !stale(cur.Checked) {
			continue
		}
		albumNames := src.trackAlbums(tr.Artist, tr.Name, platformPagesTrackAlbums)
		if len(albumNames) == 0 {
			continue
		}
		mbid := src.artistMbid(tr.Artist)
		found, settled := "", true
		for _, albumName := range albumNames {
			akey := platformAlbumKey(tr.Artist, albumName)
			platformPagesMu.Lock()
			alb, known := platformPagesCache.Albums[akey]
			platformPagesMu.Unlock()
			if !known || stale(alb.Checked) {
				if mbid == "" {
					// 歌手 mbid 还没解析出来,这张专辑根本没查过:不能算「查过、没有」,否则这首会被记成
					// 无 Spotify 链接、整整一个检查周期不再看。不落这首的结论,下一轮 mbid 到了再查(这里不花预算)。
					settled = false
					continue
				}
				if budget <= 0 {
					settled = false
					break
				}
				id, used, err := src.albumSpotify(ctx, mbid, albumName)
				budget -= used
				if err != nil {
					settled = false
					continue
				}
				alb = platformAlbumPages{Spotify: id, Checked: now.Unix()}
				platformPagesMu.Lock()
				platformPagesCache.Albums[akey] = alb
				platformPagesMu.Unlock()
				changed = true
			}
			if alb.Spotify == "" {
				continue
			}
			if albumTrackFailed[alb.Spotify] {
				settled = false
				continue
			}
			list, have := albumTrackLists[alb.Spotify]
			if !have {
				if embedBudget <= 0 {
					settled = false
					outOfBudget = true
					break
				}
				embedBudget--
				var err error
				list, err = src.albumTracks(ctx, alb.Spotify)
				if err != nil {
					albumTrackFailed[alb.Spotify] = true
					settled = false
					continue
				}
				albumTrackLists[alb.Spotify] = list
			}
			if found = matchSpotifyAlbumTrack(list, tr.Name); found != "" {
				break
			}
		}
		if found == "" && !settled {
			continue
		}
		platformPagesMu.Lock()
		platformPagesCache.Tracks[key] = platformTrackPages{Spotify: found, Checked: now.Unix()}
		platformPagesMu.Unlock()
		changed = true
	}

	if ctx.Err() != nil {
		return changed
	}
	stamp := now
	if budget <= 0 || outOfBudget {
		stamp = now.Add(platformPagesPartialRetry - platformPagesCheckInterval)
	}
	platformPagesMu.Lock()
	platformPagesCache.Updated = stamp.Unix()
	platformPagesMu.Unlock()
	return true
}

// lastfmTopAlbumsPeriod 拉 user.getTopAlbums 的一个时段(7day / 1month / 12month / overall)。
func lastfmTopAlbumsPeriod(ctx context.Context, user, apiKey, period string, limit int) ([]lastfmChartEntry, error) {
	var out struct {
		TopAlbums struct {
			Album []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Artist    struct {
					Name string `json:"name"`
				} `json:"artist"`
			} `json:"album"`
		} `json:"topalbums"`
	}
	params := neturl.Values{
		"method": {"user.getTopAlbums"}, "user": {user}, "api_key": {apiKey},
		"period": {period}, "limit": {strconv.Itoa(limit)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.TopAlbums.Album))
	for _, a := range out.TopAlbums.Album {
		pc, _ := strconv.Atoi(a.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: a.Name, Artist: a.Artist.Name, PlayCount: pc})
	}
	return entries, nil
}

// mbURLRelations 是 MusicBrainz 条目 url-rels 的形状,只取链接地址。
type mbURLRelations struct {
	Relations []struct {
		URL struct {
			Resource string `json:"resource"`
		} `json:"url"`
	} `json:"relations"`
}

var spotifyIDPattern = regexp.MustCompile(`^[A-Za-z0-9]{22}$`)

// spotifyIDFromURL 从 open.spotify.com/<kind>/<ID> 取 ID;不是这一类链接、或 ID 不是 22 位 base62 返回空。
func spotifyIDFromURL(raw, kind string) string {
	u, err := neturl.Parse(raw)
	if err != nil || u.Host != "open.spotify.com" {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	for i := 0; i+1 < len(parts); i++ {
		if parts[i] == kind && spotifyIDPattern.MatchString(parts[i+1]) {
			return parts[i+1]
		}
	}
	return ""
}

// pickArtistPlatformPages 从歌手条目的 url-rels 里挑 Spotify 歌手 ID 和 Apple Music 歌手页。纯函数。
func pickArtistPlatformPages(rels mbURLRelations) platformArtistPages {
	var out platformArtistPages
	for _, r := range rels.Relations {
		raw := r.URL.Resource
		if out.Spotify == "" {
			out.Spotify = spotifyIDFromURL(raw, "artist")
		}
		if out.Apple == "" {
			if u, err := neturl.Parse(raw); err == nil && u.Host == "music.apple.com" && strings.Contains(u.Path, "/artist/") {
				parts := strings.Split(strings.Trim(u.Path, "/"), "/")
				if _, err := strconv.ParseInt(parts[len(parts)-1], 10, 64); err == nil {
					out.Apple = raw
				}
			}
		}
	}
	return out
}

func mbArtistPlatformPages(ctx context.Context, mbid string) (platformArtistPages, int, error) {
	if err := musicbrainzThrottle(ctx); err != nil {
		return platformArtistPages{}, 0, err
	}
	var rels mbURLRelations
	u := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(mbid) + "?inc=url-rels&fmt=json"
	if err := mbGetJSON(ctx, u, &rels); err != nil {
		return platformArtistPages{}, 1, err
	}
	return pickArtistPlatformPages(rels), 1, nil
}

// editionTail 匹配专辑名末尾一段括号(「(Deluxe)」「[2015 Remaster]」「（豪华版）」)。
var editionTail = regexp.MustCompile(`\s*[(\[（【][^()\[\]（）【】]*[)\]）】]\s*$`)

// platformAlbumSearchTitles 是按专辑名搜 MusicBrainz 时依次要试的写法:原样,再去掉「 - Single」「 - EP」与末尾那段
// 再版 / 加料版括号(「Xscape (Deluxe)」在 MusicBrainz 上叫「Xscape」)。去重,不产出空串。纯函数。
func platformAlbumSearchTitles(album string) []string {
	out := []string{}
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		for _, x := range out {
			if strings.EqualFold(x, s) {
				return
			}
		}
		out = append(out, s)
	}
	add(album)
	base := trimSingleOrEPSuffix(album)
	if m := editionTail.FindString(base); m != "" && albumHintHasEditionQualifier(m) {
		base = strings.TrimSpace(base[:len(base)-len(m)])
	}
	add(base)
	return out
}

// mbLuceneQuote 把一段文字放进 Lucene 查询的双引号里:转义反斜杠和双引号。
func mbLuceneQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

type mbReleaseGroupSearch struct {
	ReleaseGroups []struct {
		ID    string `json:"id"`
		Score int    `json:"score"`
	} `json:"release-groups"`
}

type mbReleaseBrowse struct {
	Releases []mbURLRelations `json:"releases"`
}

// pickReleaseSpotifyAlbum 在一组 release 的 url-rels 里取第一个 Spotify 专辑 ID。纯函数。
func pickReleaseSpotifyAlbum(b mbReleaseBrowse) string {
	for _, rel := range b.Releases {
		for _, r := range rel.Relations {
			if id := spotifyIDFromURL(r.URL.Resource, "album"); id != "" {
				return id
			}
		}
	}
	return ""
}

// mbAlbumSpotifyID 按歌手 mbid + 专辑名找 Spotify 专辑 ID:每种写法搜一次 release-group(分数够 musicbrainzMinScore
// 才认),认下的那个再列它的 release 看 url-rels。找到专辑但没有 Spotify 链接、或每种写法都搜不到,返回空串(确定结论)。
func mbAlbumSpotifyID(ctx context.Context, mbid, album string) (string, int, error) {
	used := 0
	for _, title := range platformAlbumSearchTitles(album) {
		if err := musicbrainzThrottle(ctx); err != nil {
			return "", used, err
		}
		used++
		var search mbReleaseGroupSearch
		q := "releasegroup:" + mbLuceneQuote(title) + " AND arid:" + mbid
		if err := mbGetJSON(ctx, "https://musicbrainz.org/ws/2/release-group?query="+neturl.QueryEscape(q)+"&fmt=json&limit=3", &search); err != nil {
			return "", used, err
		}
		if len(search.ReleaseGroups) == 0 || search.ReleaseGroups[0].Score < musicbrainzMinScore {
			continue
		}
		if err := musicbrainzThrottle(ctx); err != nil {
			return "", used, err
		}
		used++
		var browse mbReleaseBrowse
		u := "https://musicbrainz.org/ws/2/release?release-group=" + neturl.QueryEscape(search.ReleaseGroups[0].ID) + "&inc=url-rels&fmt=json&limit=100"
		if err := mbGetJSON(ctx, u, &browse); err != nil {
			return "", used, err
		}
		return pickReleaseSpotifyAlbum(browse), used, nil
	}
	return "", used, nil
}

// lastfmTopTracksPeriod 拉 user.getTopTracks 的一个时段。
func lastfmTopTracksPeriod(ctx context.Context, user, apiKey, period string, limit int) ([]lastfmChartEntry, error) {
	var out struct {
		TopTracks struct {
			Track []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Artist    struct {
					Name string `json:"name"`
				} `json:"artist"`
			} `json:"track"`
		} `json:"toptracks"`
	}
	params := neturl.Values{
		"method": {"user.getTopTracks"}, "user": {user}, "api_key": {apiKey},
		"period": {period}, "limit": {strconv.Itoa(limit)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.TopTracks.Track))
	for _, t := range out.TopTracks.Track {
		pc, _ := strconv.Atoi(t.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: t.Name, Artist: t.Artist.Name, PlayCount: pc})
	}
	return entries, nil
}

// enrichAlbumsFor 在歌词缓存里找这首歌(歌手 + 歌名,不管专辑)记着的专辑名:去重,条目多的在前、同数按名字排,最多 n 个。
// 只读内存;没加载歌词缓存的进程(子命令)返回空。
func enrichAlbumsFor(artist, title string, n int) []string {
	prefix := cleanMediaTag(artist) + "|" + normEnrichTitle(title) + "|"
	counts := map[string]int{}
	enrichMu.Lock()
	for k := range enrichCache {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		if album := strings.TrimSpace(k[len(prefix):]); album != "" {
			counts[album]++
		}
	}
	enrichMu.Unlock()
	albums := make([]string, 0, len(counts))
	for a := range counts {
		albums = append(albums, a)
	}
	sort.Slice(albums, func(i, j int) bool {
		if counts[albums[i]] != counts[albums[j]] {
			return counts[albums[i]] > counts[albums[j]]
		}
		return albums[i] < albums[j]
	})
	if len(albums) > n {
		albums = albums[:n]
	}
	return albums
}

// spotifyAlbumTrack 是 Spotify 专辑嵌入页曲目表里的一首。
type spotifyAlbumTrack struct {
	Title string
	ID    string
}

var spotifyEmbedDataRe = regexp.MustCompile(`(?s)<script id="__NEXT_DATA__" type="application/json">(.*?)</script>`)

// parseSpotifyEmbedAlbum 从专辑嵌入页的 __NEXT_DATA__ 里取曲目表(props.pageProps.state.data.entity.trackList)。
// 页面不是预期形状、或某一首的 uri 不是 spotify:track:<22 位 ID> 就跳过那一首。纯函数。
func parseSpotifyEmbedAlbum(html []byte) []spotifyAlbumTrack {
	m := spotifyEmbedDataRe.FindSubmatch(html)
	if m == nil {
		return nil
	}
	var data struct {
		Props struct {
			PageProps struct {
				State struct {
					Data struct {
						Entity struct {
							TrackList []struct {
								Title string `json:"title"`
								URI   string `json:"uri"`
							} `json:"trackList"`
						} `json:"entity"`
					} `json:"data"`
				} `json:"state"`
			} `json:"pageProps"`
		} `json:"props"`
	}
	if err := json.Unmarshal(m[1], &data); err != nil {
		return nil
	}
	var out []spotifyAlbumTrack
	for _, t := range data.Props.PageProps.State.Data.Entity.TrackList {
		id := strings.TrimPrefix(t.URI, "spotify:track:")
		if id == t.URI || !spotifyIDPattern.MatchString(id) || strings.TrimSpace(t.Title) == "" {
			continue
		}
		out = append(out, spotifyAlbumTrack{Title: t.Title, ID: id})
	}
	return out
}

// matchSpotifyAlbumTrack 在专辑曲目表里按歌名找曲目 ID:先比归一后的原样歌名,再比去掉再版尾巴(stripReleaseTail,
// 「(Remastered 2015)」「 - Remastered」)之后的写法;都对不上返回空,不猜。纯函数。
func matchSpotifyAlbumTrack(tracks []spotifyAlbumTrack, title string) string {
	want := normLoose(title)
	if want == "" {
		return ""
	}
	for _, t := range tracks {
		if normLoose(t.Title) == want {
			return t.ID
		}
	}
	base, _ := stripReleaseTail(title)
	wantBase := normLoose(base)
	for _, t := range tracks {
		b, _ := stripReleaseTail(t.Title)
		if normLoose(b) == wantBase {
			return t.ID
		}
	}
	return ""
}

// spotifyEmbedClient 发 Spotify 嵌入页请求。单测换成假服务器。
var spotifyEmbedClient = &http.Client{Timeout: 10 * time.Second}

// spotifyEmbedBaseURL 是 Spotify 专辑嵌入页的前缀。单测换成假服务器。
var spotifyEmbedBaseURL = "https://open.spotify.com/embed/album/"

func spotifyEmbedAlbumTracks(ctx context.Context, albumID string) ([]spotifyAlbumTrack, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, spotifyEmbedBaseURL+neturl.PathEscape(albumID), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
	resp, err := doHTTPTracked(spotifyEmbedClient, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("spotify embed album %s: status %d", albumID, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	tracks := parseSpotifyEmbedAlbum(body)
	if len(tracks) == 0 {
		// 专辑不会一首都没有:页面不是认得的形状。报错而不是回空表,这一首就不会被记成「查过、没有」。
		noteParserUnrecognized(spotifyEmbedParserName, "__NEXT_DATA__ props.pageProps.state.data.entity.trackList missing")
		return nil, fmt.Errorf("spotify embed album %s: %w", albumID, errPageUnrecognized)
	}
	noteParserRecognized(spotifyEmbedParserName)
	return tracks, nil
}

// spotifyEmbedParserName:parserdrift.go 里这条路径的名字。
const spotifyEmbedParserName = "spotify-embed-album"
