package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
)

// 一个歌手在 Last.fm 编目里的曲目表,按听众降序 —— 编目匹配的候选来源。
//
// # 为什么必须是「这个歌手名下的曲目表」,而不是 track.search
//
// 我们要找的是「同一首歌在编目里写法不同的那一条」,而播放器报的写法本身查不到它
// (实测:简体《那个女孩》只查得到 126 听众的影子,繁体正规条目《那個女孩》889 听众
// 完全不在结果里)。track.search 也救不了 —— 它按给定的字面串搜,同样返回不了繁体那条,
// 反而会把 `张泽熙 / 那个女孩`、`宝石gem / 那个女孩` 这些**同名不同歌**带进来;拿全网
// 模糊搜索的结果去决定一条不可逆的 scrobble 写哪个条目,一次错配就是永久记错。
//
// artist.getTopTracks 天然受控在**一个歌手名下**,而且本身就按听众降序 —— 「人最多的
// 那条」就是它排在前面的那条,不用另算。`autocorrect=1` 还顺带把罗马字写法归位
// (实测 `David Tao` 与 `陶喆` 返回同一份榜)。
//
// # 为什么只拉一页
//
// 我们只关心够得上 lastfmCatalogListenersMin 的条目(影子条目不参与匹配)。实测陶喆名下
// 12,635 条曲目里听众 ≥ 500 的只有 155 条,而 limit=1000 那一页的末条只有 18 听众 ——
// 一页就已经把全部够格的候选包完了,翻页只会拉回更多影子。
const (
	lastfmTopTracksLimit   = "1000"
	lastfmTopTracksTimeout = 8 * time.Second
)

// lastfmTopTrack 是候选比对需要的那几个字段。listeners 决定选谁,mbid 是「编目正规身份」
// 最硬的信号(影子条目不会有)。
type lastfmTopTrack struct {
	Name      string
	Artist    string
	Listeners int
	MBID      string
}

// topTracks 返回这个歌手名下按听众降序的曲目表。
//
// 进程内缓存、**不落盘**:判定结论本身是永久落盘的(见 lastfmcatalog.go),所以这张表
// 只在「这首歌还没判过」时才被用到,同一个歌手连播几首时命中一次内存就够;落盘反而要
// 多管一份格式迁移和过期。失败不缓存 —— 一次网络抖动不该让这个歌手在本次进程内
// 永远匹配不到编目。
func (c *lastfmCatalogMatcher) topTracks(ctx context.Context, artist string) ([]lastfmTopTrack, error) {
	key := lastfmCatalogArtistKey(artist)
	if key == "" {
		return nil, nil
	}
	c.mu.Lock()
	cached, ok := c.tops[key]
	c.mu.Unlock()
	if ok {
		return cached, nil
	}

	q := neturl.Values{}
	q.Set("method", "artist.getTopTracks")
	q.Set("api_key", c.apiKey)
	q.Set("format", "json")
	q.Set("artist", artist)
	q.Set("limit", lastfmTopTracksLimit)
	q.Set("autocorrect", "1")

	base := c.baseURL
	if base == "" {
		base = lastfmAPIBase
	}
	ctx, cancel := context.WithTimeout(ctx, lastfmTopTracksTimeout)
	defer cancel()
	// 双重编码同 probe:歌手名含 `+`/`%` 时标准编码必然查不到(见 lastfmGetQuery)。
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+lastfmGetQuery(q), nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(c.hc, req)
	if err != nil {
		return nil, fmt.Errorf("get top tracks: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		TopTracks struct {
			Track []struct {
				Name      string `json:"name"`
				MBID      string `json:"mbid"`
				Listeners string `json:"listeners"`
				Artist    struct {
					Name string `json:"name"`
				} `json:"artist"`
			} `json:"track"`
		} `json:"toptracks"`
		Error   int    `json:"error"`
		Message string `json:"message"`
	}
	decodeErr := json.NewDecoder(resp.Body).Decode(&body)
	// error 6 在这里是「这个歌手编目里没有」——确定的答案(空表),不是失败。
	if body.Error == 6 && strings.Contains(strings.ToLower(body.Message), "not found") {
		c.storeTopTracks(key, nil)
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("artist.getTopTracks status %d", resp.StatusCode)
	}
	if decodeErr != nil {
		return nil, fmt.Errorf("decode artist.getTopTracks: %w", decodeErr)
	}
	if body.Error != 0 {
		return nil, fmt.Errorf("artist.getTopTracks error %d: %s", body.Error, body.Message)
	}

	out := make([]lastfmTopTrack, 0, len(body.TopTracks.Track))
	for _, t := range body.TopTracks.Track {
		if strings.TrimSpace(t.Name) == "" || strings.TrimSpace(t.Artist.Name) == "" {
			continue
		}
		listeners, err := atoiOrZero(t.Listeners)
		if err != nil {
			// 解不出来的听众数会让这一条按 0 参与排序,而 0 正是影子条目的样子 ——
			// 与其把它当成「人很少」,不如整份应答当作没查成(这一层是选谁的依据)。
			return nil, fmt.Errorf("artist.getTopTracks listeners %q: %w", t.Listeners, err)
		}
		out = append(out, lastfmTopTrack{
			Name:      t.Name,
			Artist:    t.Artist.Name,
			Listeners: listeners,
			MBID:      t.MBID,
		})
	}
	c.storeTopTracks(key, out)
	return out, nil
}

func (c *lastfmCatalogMatcher) storeTopTracks(key string, rows []lastfmTopTrack) {
	c.mu.Lock()
	if c.tops == nil {
		c.tops = map[string][]lastfmTopTrack{}
	}
	c.tops[key] = rows
	c.mu.Unlock()
}

// catalogTitleMatches 从曲目表里挑出「跟这个曲名是同一份录音」的条目,保持表自带的
// 听众降序。上限是给调用方的请求预算兜底的:够格的候选通常只有一两条(同一首歌在编目里
// 的不同写法),取太多只会为越来越冷门的写法多打 track.getInfo。
func catalogTitleMatches(rows []lastfmTopTrack, title string, limit int) []lastfmTopTrack {
	key := lastfmCatalogTitleKey(title)
	if key == "" {
		return nil
	}
	var out []lastfmTopTrack
	for _, r := range rows {
		if lastfmCatalogTitleKey(r.Name) != key {
			continue
		}
		out = append(out, r)
		if len(out) >= limit {
			break
		}
	}
	return out
}
