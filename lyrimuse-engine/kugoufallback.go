package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
)

// ---- 酷狗各接口的备用 ----
//
// 同 qqfallback.go 的思路,两层:
//   - 同一个接口的备用主机:酷狗所有请求都走 kugouGet,它按 kugouURLAlternates 的顺序试,只有没问成
//     (传输失败 / 非 200 / 解不开)才换下一个。
//     /api/v3/*(搜歌、专辑信息、专辑曲目):mobilecdn → ioscdn → mobiles
//     /search(歌词候选)与 /download(歌词正文):krcs 与 lyrics 两个主机都提供,互为备用
//     m.kugou.com(待播队列查专辑):http → https
//   - 另一套后端:搜歌在 /api/v3 几个主机都没问成、或回了拒绝码时,退到 songsearch.kugou.com
//     (字段名不同,见 kugouSongSearch)。
//
// 主机和字段都逐个实测过,实测记录见 docs/features/09 第 89 条。

var kugouHostAlternates = map[string][]string{
	"mobilecdn.kugou.com": {"mobilecdn.kugou.com", "ioscdn.kugou.com", "mobiles.kugou.com"},
	"krcs.kugou.com":      {"krcs.kugou.com", "lyrics.kugou.com"},
	"lyrics.kugou.com":    {"lyrics.kugou.com", "krcs.kugou.com"},
}

// kugouURLAlternates 把一条酷狗地址展开成按顺序要试的几条;没有备用的原样返回一条。
func kugouURLAlternates(raw string) []string {
	u, err := neturl.Parse(raw)
	if err != nil {
		return []string{raw}
	}
	if u.Host == "m.kugou.com" && u.Scheme == "http" {
		v := *u
		v.Scheme = "https"
		return []string{raw, v.String()}
	}
	hosts, ok := kugouHostAlternates[u.Host]
	if !ok {
		return []string{raw}
	}
	out := make([]string, 0, len(hosts))
	for _, h := range hosts {
		v := *u
		v.Host = h
		out = append(out, v.String())
	}
	return out
}

// kugouGet 发一个酷狗 GET 并把响应解进 v,按 kugouURLAlternates 的顺序试,第一个 200 且解得开的
// 就停(tryEach)。解得动就记 reportEndpointAccepted。
func kugouGet(ctx context.Context, u string, v any) error {
	_, err := kugouGetVia(ctx, u, v, false)
	return err
}

// kugouGetJudged 同 kugouGet,但不记 Accepted:调用方还要从应答体里认拒绝码,认完对交回的那条地址(答了话的主机)
// 自己记 reportEndpointAccepted / reportEndpointRejected。
func kugouGetJudged(ctx context.Context, u string, v any) (*neturl.URL, error) {
	return kugouGetVia(ctx, u, v, true)
}

func kugouGetVia(ctx context.Context, u string, v any, judged bool) (*neturl.URL, error) {
	var answered *neturl.URL
	err := tryEach(ctx, kugouURLAlternates(u), func(alt string) error {
		au, err := kugouGetAt(ctx, alt, v, judged)
		if err == nil {
			answered = au
		}
		return err
	})
	return answered, err
}

// errKugouNotFound:接口答了 404(没有这一条)。是「问成了、没有」,调用方别把它记成没问成。
var errKugouNotFound = errors.New("kugou: not found")

func kugouGetAt(ctx context.Context, u string, v any, judged bool) (*neturl.URL, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(kugouHTTPTimeout), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("status %d: %w", resp.StatusCode, errKugouNotFound)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	if judged {
		return req.URL, decodeJudgedLyricSourceJSON(req, resp, lyricSourceResponseMaxBytes, v)
	}
	return req.URL, decodeLyricSourceJSON(req, resp, lyricSourceResponseMaxBytes, v)
}

// kugouSearchSongs 搜一次歌:/api/v3/search/song(几个主机)→ songsearch。ok=false 是两套都没问成。
// 接口答了但一条都没有也是 ok=true。
func kugouSearchSongs(ctx context.Context, keyword string) ([]kugouSong, bool) {
	var sr struct {
		Status  *int `json:"status"`
		Errcode *int `json:"errcode"`
		Data    struct {
			Info []kugouSong `json:"info"`
		} `json:"data"`
	}
	searchURL := "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=" + kugouEscape(keyword) + "&page=1&pagesize=" + strconv.Itoa(kugouSearchPageSize) + "&showtype=1"
	if u, err := kugouGetJudged(ctx, searchURL, &sr); err == nil {
		if !kugouSearchRejected(sr.Status, sr.Errcode) {
			reportEndpointAccepted(u)
			return sr.Data.Info, true
		}
		reportEndpointRejected(u)
	}
	// /api/v3 没问成或被拒:退到另一套搜索后端。
	songs, err := kugouSongSearch(ctx, keyword)
	if err != nil {
		return nil, false
	}
	return songs, true
}

const kugouSongSearchEndpoint = "https://songsearch.kugou.com/song_search_v2"

// kugouSongSearchItem 是 songsearch 一条结果。字段名跟 /api/v3 不同,同一首歌挂在别的专辑下的条目在 Grp 里。
type kugouSongSearchItem struct {
	FileHash   string  `json:"FileHash"`
	SongName   string  `json:"SongName"`
	SingerName string  `json:"SingerName"`
	AlbumName  string  `json:"AlbumName"`
	AlbumID    string  `json:"AlbumID"`
	Duration   float64 `json:"Duration"`
	TransParam struct {
		Language   string `json:"language"`
		UnionCover string `json:"union_cover"`
	} `json:"trans_param"`
	Grp []kugouSongSearchItem `json:"Grp"`
}

// kugouSong 把一条 songsearch 结果(连同 Grp)归一成 /api/v3 的形态。FileHash 是大写,krcs 查候选大小写都认(实测),
// 这里统一成小写跟 /api/v3 一致。
func (s kugouSongSearchItem) kugouSong() kugouSong {
	var song kugouSong
	song.Hash = strings.ToLower(s.FileHash)
	song.SongName, song.SingerName, song.AlbumName, song.AlbumID = s.SongName, s.SingerName, s.AlbumName, s.AlbumID
	song.Duration = s.Duration
	song.TransParam.Language, song.TransParam.UnionCover = s.TransParam.Language, s.TransParam.UnionCover
	for _, g := range s.Grp {
		song.Group = append(song.Group, g.kugouSong())
	}
	return song
}

// kugouSongSearch 走 songsearch 这套搜索后端,条目归一成 kugouSong(trans_param.language 同名)。查无结果时
// 同样回 status=1、error_code=0(实测)。
func kugouSongSearch(ctx context.Context, keyword string) ([]kugouSong, error) {
	var out struct {
		Status    *int `json:"status"`
		ErrorCode *int `json:"error_code"`
		Data      struct {
			Lists []kugouSongSearchItem `json:"lists"`
		} `json:"data"`
	}
	u := kugouSongSearchEndpoint + "?keyword=" + kugouEscape(keyword) + "&page=1&pagesize=" + strconv.Itoa(kugouSearchPageSize) + "&platform=WebFilter"
	pu, err := kugouGetJudged(ctx, u, &out)
	if err != nil {
		return nil, err
	}
	if kugouSearchRejected(out.Status, out.ErrorCode) {
		reportEndpointRejected(pu)
		return nil, errors.New("kugou songsearch rejected")
	}
	reportEndpointAccepted(pu)
	songs := make([]kugouSong, 0, len(out.Data.Lists))
	for _, s := range out.Data.Lists {
		songs = append(songs, s.kugouSong())
	}
	return songs, nil
}
