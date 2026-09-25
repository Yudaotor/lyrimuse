package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
)

// ---- 网易云各接口的备用 ----
//
// 同 qqfallback.go 的思路,两层:
//   - 同一个接口的备用主机:网易云的接口都挂在 neteaseHosts 这几个主机上,路径和响应一致。
//     neteaseFetchBody 按顺序试,只有没问成(传输失败 / 非 200 / 读不出响应体)才换下一个主机。
//     响应体里的拒绝码(限流)**不换主机**:网易云按接口路径分桶限流(neteaseEndpointBucket 只看
//     路径),换主机绕不过去,还是在对着同一个桶撞;这类由各调用方照旧退避这个桶、换另一条路径。
//   - 同一功能的另一条路径(另一个桶):
//     搜歌 /api/search/get → /api/search/get/web → /api/cloudsearch/pc(字段名不同,见 neteaseSearchSongs)
//     单曲详情 /api/song/detail → /api/v3/song/detail(字段名 al / ar / dt)
//     整行歌词 /api/song/lyric → /api/song/lyric/v1(见 neteaseV1LyricLines)
//     专辑曲目 /api/album/{id} → /api/v1/album/{id}
//     逐字歌词只有 /api/song/lyric/v1,专辑搜索(type=10)与泛搜只有 search/get 两条,这几个只换主机。
//
// 主机和字段都逐个实测过,实测记录见 docs/features/09 第 88 条。

var neteaseHosts = []string{"music.163.com", "interface.music.163.com", "interface3.music.163.com"}

// neteaseHostURLs 把一条 music.163.com 上的地址展开成 neteaseHosts 上的同一条地址,按顺序。
// 不是这几个主机的地址原样返回一条。
func neteaseHostURLs(rawURL string) []string {
	u, err := neturl.Parse(rawURL)
	if err != nil || u.Host != neteaseHosts[0] {
		return []string{rawURL}
	}
	out := make([]string, 0, len(neteaseHosts))
	for _, h := range neteaseHosts {
		v := *u
		v.Host = h
		out = append(out, v.String())
	}
	return out
}

// neteaseFetchBody 发一个网易云 GET,按 neteaseHosts 顺序试,返回第一个 HTTP 200 的响应体。
// 每次尝试前都过 neteaseThrottle(按路径分桶,各主机共用一个桶);桶在退避中时整条放弃,不换主机。
// cookie 非空时带上(专辑接口要 os=pc)。
func neteaseFetchBody(ctx context.Context, rawURL, cookie string, timeout time.Duration) ([]byte, error) {
	cli := lyricHTTPClient(timeout)
	var lastErr error = errors.New("netease: not reached")
	for _, u := range neteaseHostURLs(rawURL) {
		if err := neteaseThrottle(ctx, u); err != nil {
			return nil, err
		}
		body, err := neteaseFetchBodyAt(ctx, cli, u, cookie)
		if err == nil {
			return body, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return nil, lastErr
}

func neteaseFetchBodyAt(ctx context.Context, cli *http.Client, u, cookie string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://music.163.com/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
	}
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// neteaseCloudSearchEndpoint 是搜歌的第三条路径。结果里的字段名跟 search/get 不同
// (ar / al / dt 对 artists / album / duration),neteaseSearchSongs 负责归一。
const neteaseCloudSearchEndpoint = "https://music.163.com/api/cloudsearch/pc"

// neteaseSearchSongs 按 search/get → search/get/web → cloudsearch/pc 的顺序搜歌,每条路径内部
// 由 get(resolveNeteaseInfo 里那个)按主机退。三条都没问成才返回错误。
func neteaseSearchSongs(get func(string, any) error, q string) ([]neSearchSong, error) {
	escaped := neturl.QueryEscape(q)
	const query = "?type=1&limit=30&s="
	var err error
	for _, endpoint := range []string{neteaseSearchEndpointPrimary, neteaseSearchEndpointFallback} {
		var r struct {
			Result struct {
				Songs []neSearchSong `json:"songs"`
			} `json:"result"`
		}
		if err = get(endpoint+query+escaped, &r); err == nil {
			return r.Result.Songs, nil
		}
	}
	var c struct {
		Result struct {
			Songs []struct {
				ID   int64   `json:"id"`
				Name string  `json:"name"`
				Dt   float64 `json:"dt"`
				Ar   []struct {
					Name string `json:"name"`
				} `json:"ar"`
				Al struct {
					ID   int64  `json:"id"`
					Name string `json:"name"`
				} `json:"al"`
			} `json:"songs"`
		} `json:"result"`
	}
	if cerr := get(neteaseCloudSearchEndpoint+query+escaped, &c); cerr != nil {
		return nil, err
	}
	songs := make([]neSearchSong, 0, len(c.Result.Songs))
	for _, s := range c.Result.Songs {
		var song neSearchSong
		song.ID, song.Name, song.Duration = s.ID, s.Name, s.Dt
		song.Album.ID, song.Album.Name = s.Al.ID, s.Al.Name
		for _, a := range s.Ar {
			song.Artists = append(song.Artists, struct {
				Name string `json:"name"`
			}{Name: a.Name})
		}
		songs = append(songs, song)
	}
	return songs, nil
}

// neteaseV1LyricLines 去掉 /api/song/lyric/v1 整行歌词开头那几行 JSON 格式的署名
// (`{"t":0,"c":[{"tx":"作词: "},…]}`),剩下的跟 /api/song/lyric 的正文一致(实测)。
func neteaseV1LyricLines(s string) string {
	if !strings.Contains(s, "\n{") && !strings.HasPrefix(s, "{") {
		return s
	}
	lines := strings.Split(s, "\n")
	out := lines[:0]
	for _, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), "{") {
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "\n")
}
