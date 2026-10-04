package main

import (
	"log"
	"path/filepath"
)

// Spotify 的同专辑兜底:从客户端自己的元数据缓存(primary.ldb)取这张专辑的曲目表,不联网。
//
// 链路:换曲时记下的曲目 id(spotifyTrackIDHintFor)→ spotify.metadata.Track 的第 3 个字段(所属专辑
// {1: gid})→ spotify.metadata.Album 的第 11 个字段(按碟重复,每碟里第 3 个字段是按顺序的曲目 {1: gid})
// → 每首的 IdentityTrait(歌名 / 第一位歌手)与时长,跟读播放队列那一层用的是同一套元数据。
//
// 曲目名来自 Spotify 自己,跟它真播到时报给系统的逐字一致,写进 enrich key 不会跟真播放那一刻对不上
// (网易云曲库的写法常在繁简、英文大小写、版本后缀上跟 Spotify 不同)。只有客户端加载过的专辑才在缓存里,
// 取不到就返回 ok=false,由 albumTracks 退回网易云专辑接口。

// spotifyAlbumKind 是 spotify.metadata.Album 在元数据缓存 key 里的类型字节(实测抄下来的,同
// spotifyTrackKind 那两段;取到的值还会按 type_url 核对)。
var spotifyAlbumKind = []byte{0x01, 0x29}

// spotifyAlbumTracks 取当前这首所在专辑的曲目表。
func spotifyAlbumTracks(artist, title, album string) ([]albumTrack, bool) {
	userDir := spotifyActiveUserDir()
	trackID := spotifyTrackIDHintFor(artist, title)
	if userDir == "" || trackID == "" {
		return nil, false
	}
	ldbDir := filepath.Join(userDir, "primary.ldb")
	trackKey := spotifyXmetaKey(spotifyTrackKind, trackID)
	albumID := spotifyParseTrackAlbumID(ldbGet(ldbDir, [][]byte{trackKey})[string(trackKey)])
	if albumID == "" {
		return nil, false
	}
	albumKey := spotifyXmetaKeyURI(spotifyAlbumKind, "spotify:album:"+albumID)
	ids := spotifyParseAlbumTrackIDs(ldbGet(ldbDir, [][]byte{albumKey})[string(albumKey)])
	if len(ids) == 0 {
		log.Printf("album prefetch: spotify client cache has no track list for %q, asking netease", album)
		return nil, false
	}
	metas := spotifyResolveMeta(userDir, ids)
	tracks := make([]albumTrack, 0, len(ids))
	for _, id := range ids {
		m, ok := metas[id]
		if !ok || m.title == "" {
			continue // 本地没有这首的元数据:不拿空名字去猜
		}
		tracks = append(tracks, albumTrack{title: m.title, artist: m.artist, duration: m.seconds})
	}
	if len(tracks) == 0 {
		return nil, false
	}
	log.Printf("album prefetch: %q from spotify client cache (%d of %d tracks have metadata)", album, len(tracks), len(ids))
	return tracks, true
}

// spotifyParseTrackAlbumID 取 spotify.metadata.Track 里所属专辑的 id。拿不到返回 ""。
func spotifyParseTrackAlbumID(v []byte) string {
	fields, err := pbParse(spotifyFindAny(v, "spotify.metadata.Track", 0))
	if err != nil {
		return ""
	}
	for _, f := range fields {
		if f.num != 3 || f.wire != 2 {
			continue
		}
		sub, err := pbParse(f.b)
		if err != nil {
			return ""
		}
		for _, s := range sub {
			if s.num == 1 && s.wire == 2 && len(s.b) == 16 {
				return spotifyGIDToID(s.b)
			}
		}
	}
	return ""
}

// spotifyParseAlbumTrackIDs 按碟、按碟内顺序取 spotify.metadata.Album 的曲目 id。
func spotifyParseAlbumTrackIDs(v []byte) []string {
	val := spotifyFindAny(v, "spotify.metadata.Album", 0)
	if val == nil {
		return nil
	}
	fields, err := pbParse(val)
	if err != nil {
		return nil
	}
	var ids []string
	for _, f := range fields {
		if f.num != 11 || f.wire != 2 {
			continue
		}
		disc, err := pbParse(f.b)
		if err != nil {
			continue
		}
		for _, d := range disc {
			if d.num != 3 || d.wire != 2 {
				continue
			}
			track, err := pbParse(d.b)
			if err != nil {
				continue
			}
			for _, t := range track {
				if t.num == 1 && t.wire == 2 && len(t.b) == 16 {
					ids = append(ids, spotifyGIDToID(t.b))
					break
				}
			}
		}
	}
	return ids
}
