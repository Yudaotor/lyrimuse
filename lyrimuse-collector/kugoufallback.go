package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
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
// 就停。ctx 已取消时不再试下一个。
func kugouGet(ctx context.Context, u string, v any) error {
	var lastErr error = errors.New("kugou: not reached")
	for _, alt := range kugouURLAlternates(u) {
		err := kugouGetAt(ctx, alt, v)
		if err == nil {
			return nil
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return lastErr
}

func kugouGetAt(ctx context.Context, u string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
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
	searchURL := "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=" + kugouEscape(keyword) + "&page=1&pagesize=10&showtype=1"
	if err := kugouGet(ctx, searchURL, &sr); err == nil {
		u, _ := neturl.Parse(searchURL)
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

// kugouSongSearch 走 songsearch 这套搜索后端,条目归一成 kugouSong。字段名跟 /api/v3 不同
// (FileHash / SongName / SingerName / AlbumName / AlbumID / Duration,trans_param.language 同名);
// FileHash 是大写,krcs 查候选大小写都认(实测),这里统一成小写跟 /api/v3 一致。查无结果时
// 同样回 status=1、error_code=0(实测)。
func kugouSongSearch(ctx context.Context, keyword string) ([]kugouSong, error) {
	var out struct {
		Status    *int `json:"status"`
		ErrorCode *int `json:"error_code"`
		Data      struct {
			Lists []struct {
				FileHash   string  `json:"FileHash"`
				SongName   string  `json:"SongName"`
				SingerName string  `json:"SingerName"`
				AlbumName  string  `json:"AlbumName"`
				AlbumID    string  `json:"AlbumID"`
				Duration   float64 `json:"Duration"`
				TransParam struct {
					Language string `json:"language"`
				} `json:"trans_param"`
			} `json:"lists"`
		} `json:"data"`
	}
	u := kugouSongSearchEndpoint + "?keyword=" + kugouEscape(keyword) + "&page=1&pagesize=10&platform=WebFilter"
	if err := kugouGet(ctx, u, &out); err != nil {
		return nil, err
	}
	pu, _ := neturl.Parse(u)
	if kugouSearchRejected(out.Status, out.ErrorCode) {
		reportEndpointRejected(pu)
		return nil, errors.New("kugou songsearch rejected")
	}
	reportEndpointAccepted(pu)
	songs := make([]kugouSong, 0, len(out.Data.Lists))
	for _, s := range out.Data.Lists {
		var song kugouSong
		song.Hash = strings.ToLower(s.FileHash)
		song.SongName, song.SingerName, song.AlbumName, song.AlbumID = s.SongName, s.SingerName, s.AlbumName, s.AlbumID
		song.Duration = s.Duration
		song.TransParam.Language = s.TransParam.Language
		songs = append(songs, song)
	}
	return songs, nil
}
