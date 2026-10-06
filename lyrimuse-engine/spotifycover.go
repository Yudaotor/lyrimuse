package main

import "encoding/hex"

// spotifyCoverImageBase:Spotify 的图床,专辑封面的地址是它加上图片 file_id 的十六进制。
const spotifyCoverImageBase = "https://i.scdn.co/image/"

// spotifyLocalCover:这条 Spotify 曲目所属专辑的封面地址,取自客户端的元数据缓存(见 spotifyParseTrackCover)。
// 拿不到返回 ""。只给候选展示用,见 09 章决策 197。
func spotifyLocalCover(trackID string) string {
	root := spotifyISRCUsersDir()
	if len(trackID) != 22 || root == "" {
		return ""
	}
	key := spotifyXmetaKey(spotifyTrackKind, trackID)
	for _, dir := range spotifyISRCLedgerDirs(root) {
		if url := spotifyParseTrackCover(ldbGet(dir, [][]byte{key})[string(key)]); url != "" {
			return url
		}
	}
	return ""
}

// spotifyParseTrackCover:spotify.metadata.Track 所属专辑(第 3 个字段)的封面。专辑的第 17 个字段是一组图,每张
// {1: file_id(20 字节), 2: 尺寸档, 3、4: 宽高};取尺寸档 0 那张,没有就第一张。拿不到返回 ""。
func spotifyParseTrackCover(v []byte) string {
	fields, err := pbParse(spotifyFindAny(v, "spotify.metadata.Track", 0))
	if err != nil {
		return ""
	}
	for _, f := range fields {
		if f.num != 3 || f.wire != 2 {
			continue
		}
		album, err := pbParse(f.b)
		if err != nil {
			return ""
		}
		for _, a := range album {
			if a.num == 17 && a.wire == 2 {
				return spotifyPickCoverImage(a.b)
			}
		}
	}
	return ""
}

// spotifyPickCoverImage:一组封面图里尺寸档 0 那张的地址,没有就第一张。
func spotifyPickCoverImage(group []byte) string {
	images, err := pbParse(group)
	if err != nil {
		return ""
	}
	first := ""
	for _, img := range images {
		if img.num != 1 || img.wire != 2 {
			continue
		}
		fields, err := pbParse(img.b)
		if err != nil {
			continue
		}
		id, size := "", uint64(0)
		for _, f := range fields {
			switch {
			case f.num == 1 && f.wire == 2 && len(f.b) == 20:
				id = hex.EncodeToString(f.b)
			case f.num == 2 && f.wire == 0:
				size = f.v
			}
		}
		if id == "" {
			continue
		}
		if size == 0 {
			return spotifyCoverImageBase + id
		}
		if first == "" {
			first = spotifyCoverImageBase + id
		}
	}
	return first
}
