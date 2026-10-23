package main

import (
	"encoding/json"
	"fmt"
	"html"
	"os"
	"regexp"
	"strings"
)

// `lyrimuse-engine spotify-artist-bio <歌手 ID>`:Spotify 客户端本机元数据缓存(primary.ldb)里这位歌手的简介,给 App 的歌手
// 简介卡用。只读,LevelDB 不开库、不抢锁(同 leveldbread.go)。只有在 Spotify 里看过的歌手才有缓存(本机 48 位里 19 位有),
// 依次看三处:spotify.metadata.Artist 的 12.1(biography)、DetailedEvaluationTrait 的 1、IdentityTrait 的 3。正文带
// `<br/>`、`<a …>` 和 HTML 实体,换成纯文本。输出一行 JSON:有是 {"bio":"…"},没有是 {}。见 05 章决策 91。

var (
	spotifyArtistMetaKind     = []byte{0x01, 0x28}
	spotifyArtistEvalKind     = []byte{0x01, 0xd8}
	spotifyArtistIdentityKind = []byte{0x01, 0xd2}
)

// spotifyArtistBio:这位歌手在本机缓存里的简介,没有为 ""。
func spotifyArtistBio(artistID string) string {
	root := spotifyISRCUsersDir()
	if artistID == "" || root == "" {
		return ""
	}
	uri := "spotify:artist:" + artistID
	keys := [][]byte{
		spotifyXmetaKeyURI(spotifyArtistMetaKind, uri),
		spotifyXmetaKeyURI(spotifyArtistEvalKind, uri),
		spotifyXmetaKeyURI(spotifyArtistIdentityKind, uri),
	}
	for _, dir := range spotifyISRCLedgerDirs(root) {
		vals := ldbGet(dir, keys)
		if bio := spotifyPickArtistBio(vals[string(keys[0])], vals[string(keys[1])], vals[string(keys[2])]); bio != "" {
			return bio
		}
	}
	return ""
}

// spotifyPickArtistBio:三处按顺序取第一份有字的,整理成纯文本。纯函数,单测覆盖。
func spotifyPickArtistBio(meta, eval, identity []byte) string {
	for _, raw := range []string{
		spotifyAnyField(meta, "spotify.metadata.Artist", 12, 1),
		spotifyAnyField(eval, "DetailedEvaluationTrait", 1),
		spotifyAnyField(identity, "IdentityTrait", 3),
	} {
		if text := spotifyBioText(raw); text != "" {
			return text
		}
	}
	return ""
}

// spotifyAnyField:Any 包着的消息里沿字段号一路往下取的那段字节;取不到为 ""。
func spotifyAnyField(v []byte, typeSuffix string, path ...int) string {
	b := spotifyFindAny(v, typeSuffix, 0)
	for _, num := range path {
		fields, err := pbParse(b)
		if err != nil {
			return ""
		}
		var next []byte
		for _, f := range fields {
			if f.num == num && f.wire == 2 {
				next = f.b
				break
			}
		}
		if next == nil {
			return ""
		}
		b = next
	}
	return string(b)
}

var (
	spotifyBioBreak    = regexp.MustCompile(`(?i)<br\s*/?>`)
	spotifyBioTag      = regexp.MustCompile(`<[^>]*>`)
	spotifyBioBlankRun = regexp.MustCompile(`\n{3,}`)
)

// spotifyBioText:`<br/>` 换行,别的标签去掉(链接留文字),HTML 实体还原,行尾空白去掉、连着的空行并成一个。纯函数,单测覆盖。
func spotifyBioText(raw string) string {
	s := spotifyBioBreak.ReplaceAllString(raw, "\n")
	s = html.UnescapeString(spotifyBioTag.ReplaceAllString(s, ""))
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimSpace(l)
	}
	return strings.TrimSpace(spotifyBioBlankRun.ReplaceAllString(strings.Join(lines, "\n"), "\n\n"))
}

func runSpotifyArtistBioCLI(args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "spotify-artist-bio: exactly one artist ID is required")
		os.Exit(2)
	}
	out := map[string]string{}
	if bio := spotifyArtistBio(args[0]); bio != "" {
		out["bio"] = bio
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, "spotify-artist-bio: encode:", err)
		os.Exit(1)
	}
}
