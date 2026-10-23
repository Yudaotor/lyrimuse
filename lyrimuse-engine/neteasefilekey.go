package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"encoding/base64"
	"encoding/json"
	"log"
	"math"
	"strconv"
	"strings"
)

// 网易云音乐下载的歌曲文件,注释标签里写着「163 key(Don't modify):」加一段 Base64:AES-128-ECB(固定密钥,PKCS#7 填充)
// 解开是 `music:` 加一段 JSON,带这首在网易云上的曲目 id、歌名、歌手、专辑、时长(毫秒)和封面地址。放本地文件的播放器
// (reAMP、VOX、Pine Player)放这种文件时,网易云那条源按这个 id 取,不按名字搜:同名的几版里搜索会挑到别的版本。
// 见 02 章决策 177。

const neteaseFileKeyPrefix = "163 key(Don't modify):"

// neteaseFileKeyAES:网易云客户端写这段用的密钥,各家标签工具公开的同一串。
var neteaseFileKeyAES = []byte("#14ljk_!\\]&0U<'(")

// neteaseFileKeyMaxDurationGap:标签里的时长跟这首的时长差过这么多秒,就当不是这首的文件(待播按文件名拼的路径可能指错)。
const neteaseFileKeyMaxDurationGap = 3.0

// neteaseFlexID:网易云写的 id,有时是字符串、有时是数字。
type neteaseFlexID int64

func (id *neteaseFlexID) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "" || s == "null" {
		*id = 0
		return nil
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return err
	}
	*id = neteaseFlexID(n)
	return nil
}

// neteaseFileKey:163 key 解开后用到的那几项。
type neteaseFileKey struct {
	MusicID   neteaseFlexID `json:"musicId"`
	MusicName string        `json:"musicName"`
	// Artist:[["歌手名", id], …]。
	Artist   [][]json.RawMessage `json:"artist"`
	AlbumID  neteaseFlexID       `json:"albumId"`
	Album    string              `json:"album"`
	AlbumPic string              `json:"albumPic"`
	Duration float64             `json:"duration"`
}

// parseNeteaseFileKey:一条注释是不是 163 key,是的话解开。占位的那种(解开没有内容)、解不开、不是 `music:` 开头、没有曲目 id 的
// 都为 false。纯函数,单测覆盖。
func parseNeteaseFileKey(comment string) (neteaseFileKey, bool) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(comment), neteaseFileKeyPrefix)
	if !ok {
		return neteaseFileKey{}, false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(rest))
	if err != nil || len(raw) == 0 || len(raw)%aes.BlockSize != 0 {
		return neteaseFileKey{}, false
	}
	block, err := aes.NewCipher(neteaseFileKeyAES)
	if err != nil {
		return neteaseFileKey{}, false
	}
	for i := 0; i < len(raw); i += aes.BlockSize {
		block.Decrypt(raw[i:i+aes.BlockSize], raw[i:i+aes.BlockSize])
	}
	pad := int(raw[len(raw)-1])
	if pad == 0 || pad > aes.BlockSize {
		return neteaseFileKey{}, false
	}
	body, ok := bytes.CutPrefix(raw[:len(raw)-pad], []byte("music:"))
	if !ok {
		return neteaseFileKey{}, false
	}
	var k neteaseFileKey
	if json.Unmarshal(body, &k) != nil || k.MusicID <= 0 {
		return neteaseFileKey{}, false
	}
	return k, true
}

// artistNames:歌手名按写的顺序,名字不是字符串的跳过。
func (k neteaseFileKey) artistNames() []string {
	var out []string
	for _, a := range k.Artist {
		if len(a) == 0 {
			continue
		}
		var name string
		if json.Unmarshal(a[0], &name) == nil && strings.TrimSpace(name) != "" {
			out = append(out, name)
		}
	}
	return out
}

// song:换成网易云源 pick() 选中的那种结果。封面用它记的这张(http 换 https)。
func (k neteaseFileKey) song() neSearchSong {
	song := neSearchSong{ID: int64(k.MusicID), Name: k.MusicName, Duration: k.Duration}
	song.Album.ID, song.Album.Name = int64(k.AlbumID), k.Album
	song.Album.PicURL = neteaseHTTPSImage(k.AlbumPic)
	for _, name := range k.artistNames() {
		song.Artists = append(song.Artists, struct {
			Name string `json:"name"`
		}{Name: name})
	}
	return song
}

// neteaseFileKeyFromTags:标签注释里第一条能解开的 163 key。
func neteaseFileKeyFromTags(t localFileTags) (neteaseFileKey, bool) {
	for _, c := range t.comments {
		if k, ok := parseNeteaseFileKey(c); ok {
			return k, true
		}
	}
	return neteaseFileKey{}, false
}

// neteaseFileKeyDurationAgrees:两边都有时长时差不过 neteaseFileKeyMaxDurationGap 秒;哪边没有都算对得上。纯函数。
func neteaseFileKeyDurationAgrees(k neteaseFileKey, durationSecs float64) bool {
	if durationSecs <= 0 || k.Duration <= 0 {
		return true
	}
	return math.Abs(k.Duration/1000-durationSecs) <= neteaseFileKeyMaxDurationGap
}

type localFilePathKey struct{}

// withLocalFilePath 给 ctx 挂上这首的本地文件(放本地文件的播放器的待播那几首)。空串原样返回。
func withLocalFilePath(ctx context.Context, path string) context.Context {
	if path == "" {
		return ctx
	}
	return context.WithValue(ctx, localFilePathKey{}, path)
}

// localFilePathFor:这一轮解析的这首是哪个本地文件:ctx 上挂着的(待播),否则 App 此刻报的当前文件(歌名歌手对得上才算)。
func localFilePathFor(ctx context.Context, artist, title string) string {
	if p, _ := ctx.Value(localFilePathKey{}).(string); p != "" {
		return p
	}
	return localFileCurrentPath(artist, title)
}

// neteaseFileKeySong:这首是本地文件、标签里有 163 key、时长对得上时,交回它记的那一条网易云曲目。
func neteaseFileKeySong(ctx context.Context, artist, title string, durationSecs float64) (neSearchSong, bool) {
	path := localFilePathFor(ctx, artist, title)
	if path == "" {
		return neSearchSong{}, false
	}
	k, ok := neteaseFileKeyFromTags(localFileTagsMemo(path))
	if !ok || !neteaseFileKeyDurationAgrees(k, durationSecs) {
		return neSearchSong{}, false
	}
	// 每首歌最多一行:上游 neteaseLookup 有缓存。这行是「songID 来自文件标签、没走搜索」的凭据,同 netease local 那行。
	log.Printf("netease file key: %q - %q → %d", artist, title, int64(k.MusicID))
	return k.song(), true
}
