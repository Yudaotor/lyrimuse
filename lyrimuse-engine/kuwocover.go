package main

import (
	"bytes"
	"image"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 酷我的本机封面:系统会话从不带封面(02 章决策 263),酷我客户端把在放、列表里的歌的专辑图存在容器 Caches/DocumentData/HDPicture/
// 下,文件名「歌手 - 专辑.jpg」,歌手、专辑跟它报给系统会话的一字不差(300×300)。酷我在放这首、App 报了专辑时,按这对名字取那张
// 图,当这首的设备封面交给 deviceCoverURLIfFresh,之后跟设备直送的一样处理。
//
// 专辑空的不读:那份文件名只剩歌手(「歌手 - .jpg」),同一位歌手别的没报专辑的条目会盖掉它,认不出是不是这一首的。
// 容器经 kuwoContainerDocumentDir 取,没有「完全磁盘访问」时不读。见 02 章决策 269。

// kuwoCoverDirOverride 让单测把目录指到临时路径。空 = 用真实路径。
var kuwoCoverDirOverride string

// kuwoCoverMaxBytes:封面文件的大小上限,防目录里混进异常大的文件时白读。实测 8～135 KB。
const kuwoCoverMaxBytes = 2 << 20

// kuwoCoverMinEdge:短边不到这个数的不当封面(同 App 交设备封面的下限 CoverArtReplacementGate.deviceArtworkMinEdge)。
const kuwoCoverMinEdge = 64

func kuwoCoverDir() string {
	if kuwoCoverDirOverride != "" {
		return kuwoCoverDirOverride
	}
	return kuwoContainerDocumentDir("HDPicture")
}

// kuwoLocalCoverArtwork:酷我在放 artist / title 这一首时,它容器里按 App 报的歌手、专辑存的那张封面。不是酷我、App 报的不是这一首、
// 没报专辑、名字里有路径分隔符、没授权、文件不在、太大、解不出、不像封面(太小、偏离正方形超过 15%)都当没拿到。
func kuwoLocalCoverArtwork(bundleID, artist, title string) (data []byte, mimeType string, ok bool) {
	if bundleID != kuwoMusicBundleID {
		return nil, "", false
	}
	rawArtist, rawAlbum, ok := appPlaybackTrackTags(bundleID, artist, title)
	if !ok {
		return nil, "", false
	}
	name := kuwoCoverFileName(rawArtist, rawAlbum)
	dir := kuwoCoverDir()
	if name == "" || dir == "" {
		return nil, "", false
	}
	path := filepath.Join(dir, name)
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > kuwoCoverMaxBytes {
		return nil, "", false
	}
	b, err := os.ReadFile(path)
	noteFileErr("read", path, err)
	if err != nil {
		return nil, "", false
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(b))
	if err != nil || !kuwoCoverShaped(cfg.Width, cfg.Height) {
		return nil, "", false
	}
	return b, http.DetectContentType(b), true
}

// kuwoCoverFileName:酷我存封面用的文件名「歌手 - 专辑.jpg」;专辑空、名字带路径分隔符或 NUL 的为 ""。
func kuwoCoverFileName(artist, album string) string {
	artist, album = strings.TrimSpace(artist), strings.TrimSpace(album)
	if artist == "" || album == "" || strings.ContainsAny(artist+album, "/\x00") {
		return ""
	}
	return artist + " - " + album + ".jpg"
}

// kuwoCoverShaped:短边够 kuwoCoverMinEdge、长宽差不超过长边的 15%(同 App 的 CoverArtReplacementGate.isCoverShaped)。
func kuwoCoverShaped(w, h int) bool {
	if min(w, h) < kuwoCoverMinEdge {
		return false
	}
	return float64(max(w, h)-min(w, h)) <= 0.15*float64(max(w, h))
}

// appPlaybackTrackTags:App 此刻报的这一首(播放器、歌手、歌名都对得上)里播放器原样报的歌手、专辑;原样那份空时用 App 报的。
// App 状态不可用、报的不是这一首时 ok 为假。
func appPlaybackTrackTags(bundleID, artist, title string) (rawArtist, rawAlbum string, ok bool) {
	appPlaybackArtworkMu.Lock()
	r := appPlaybackArtworkReader
	appPlaybackArtworkMu.Unlock()
	if r == nil {
		return "", "", false
	}
	rec, avail := r.read(time.Now())
	if avail != appStateAvailable || !rec.hasTrack() || rec.Player != bundleID || rec.Track.Artist != artist ||
		!sameAppTrackTitle(rec.Track.Title, title) {
		return "", "", false
	}
	rawArtist, rawAlbum = rec.Track.Raw.Artist, rec.Track.Raw.Album
	if rawArtist == "" {
		rawArtist = rec.Track.Artist
	}
	if rawAlbum == "" {
		rawAlbum = rec.Track.Album
	}
	return rawArtist, rawAlbum, true
}
