package main

import (
	"encoding/json"
	"strings"
)

// KKBOX 的同专辑预取:队列读不到(收藏库、单曲、电台这些上下文,见 kkboxContextEndpoints)时退回的那条路。
//
// 曲目表要么取 KKBOX 自己的(缓存里有这张专辑的专辑接口响应时,歌名、歌手都是它报的写法),要么退回网易云的专辑曲目表 ——
// 后者的歌手写法跟 KKBOX 报的不一样(「五月天」对「五月天 (Mayday)」),照原样预解析出来的条目播到时 key 对不上,
// 所以按当前这首的写法改写(kkboxAlbumTrackArtists)。同一张专辑里 KKBOX 的写法一致,拿当前这首的当准。

// kkboxAlbumTracks:当前这首的单曲详情 → 专辑 id → 缓存里这张专辑的曲目表(自己不带歌手的曲目用批量详情补)。
func kkboxAlbumTracks(artist, title string) ([]albumTrack, bool) {
	c := scanKKBOXCache(kkboxCacheDir())
	albumID := ""
	for _, e := range c {
		id, ok := strings.CutPrefix(e.url.Path, "/v2/tracks/")
		if !ok || id == "" {
			continue
		}
		body, ok := e.body()
		if !ok {
			continue
		}
		var d struct {
			Data kkboxTrack `json:"data"`
		}
		var a struct {
			Data struct {
				Album *struct {
					ID string `json:"id"`
				} `json:"album"`
			} `json:"data"`
		}
		if json.Unmarshal(body, &d) != nil || json.Unmarshal(body, &a) != nil || a.Data.Album == nil {
			continue
		}
		if kkboxLyricMatch(d.Data, artist, title, 0) {
			albumID = a.Data.Album.ID
			break
		}
	}
	if albumID == "" {
		return nil, false
	}
	list, ok := c.trackList("/v2/albums/" + albumID)
	if !ok {
		return nil, false
	}
	ids := make([]string, 0, len(list.Data.Tracks))
	for _, t := range list.Data.Tracks {
		ids = append(ids, t.ID)
	}
	details := c.trackDetails(ids)
	albumArtist := ""
	if list.Data.Artist != nil {
		albumArtist = list.Data.Artist.Name
	}
	tracks := make([]albumTrack, 0, len(list.Data.Tracks))
	for _, t := range list.Data.Tracks {
		if d, ok := details[t.ID]; ok && d.hasOwnArtist() {
			t = d
		}
		tracks = append(tracks, albumTrack{title: t.Name, artist: kkboxArtistName(t, albumArtist), duration: t.DurationMs / 1000})
	}
	return tracks, len(tracks) > 0
}

// kkboxAlbumTrackArtists 把别家曲目表里的歌手改写成 KKBOX 的写法:当前这首报的每一位歌手(「五月天 (Mayday)」)按去掉括号别名、
// 繁简折算后的形态(「五月天」)对上;一首歌的歌手全都对得上才改写,用 KKBOX 的 ", " 连起来,有一位对不上就原样留着
// (拼出一半 KKBOX 写法、一半别家写法的串,两边都对不上)。
func kkboxAlbumTrackArtists(tracks []albumTrack, currentArtist string) []albumTrack {
	forms := map[string]string{}
	for _, name := range strings.Split(currentArtist, ", ") {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		forms[loosenEnrichKey(kkboxBareArtist(name))] = name
	}
	if len(forms) == 0 {
		return tracks
	}
	out := make([]albumTrack, len(tracks))
	for i, t := range tracks {
		out[i] = t
		parts := artistCreditParts(t.artist)
		if len(parts) == 0 {
			parts = []string{t.artist}
		}
		names := make([]string, 0, len(parts))
		for _, p := range parts {
			name, ok := forms[loosenEnrichKey(p)]
			if !ok {
				names = nil
				break
			}
			names = append(names, name)
		}
		if names != nil {
			out[i].artist = strings.Join(names, ", ")
		}
	}
	return out
}

// kkboxBareArtist 去掉结尾的括号别名:「五月天 (Mayday)」→「五月天」;没有就原样。
func kkboxBareArtist(name string) string {
	if i := strings.LastIndex(name, " ("); i > 0 && strings.HasSuffix(name, ")") {
		return name[:i]
	}
	return name
}
