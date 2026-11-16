package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// 酷我客户端自己落盘的歌词 —— 酷我源的快速路径。
//
// 酷我 Mac 客户端(App Store 版,带沙盒)播放时把这首歌的歌词当场写进自己容器的 Caches/DocumentData/Lyric,
// 文件名是「歌手 - 歌名 - 曲目 id.lrcx」(少数是 .lrc),歌手、歌名跟它报给系统的写法一致(多位歌手用「&」连)。
// 两种格式:
//   - .lrcx:第一行 `utf8`,第二行是跟网络 lrcx 接口同一份逐字正文异或 `yeelion` 后的 base64(不带网络那份的
//     `tp=content` 头和 zlib),可能还有一行 `offset=…`。解开后就是 `[kuwo:NNN]` 头加 `<a,b>` 字级时间,
//     kuwoLrcxToYRC 原样可用。
//   - .lrc:第一行 `utf8`,后面是明文逐行 LRC。
//
// 跟酷狗本地那条(kugoulocal.go)同一种定位:零网络、是客户端为正在放的那一版下的那一份,身份来自文件名里的
// 曲目 id、不经搜索,命中时给同源加权;命中不了照常走网络。曲目 id 另记进 player_song_ids,App 拼成酷我歌曲页
// (playercatalog.go)。全程 fail-soft:目录不在、读不动、格式变了一律当没命中。
//
// 目录在酷我的私有容器里,经 `otherAppContainer` 取,没有「完全磁盘访问」时不读。见 09 章决策 377。

// kuwoLocalDirOverride 让单测把目录指到临时路径。空 = 用真实路径。
var kuwoLocalDirOverride string

// kuwoContainerDocumentDir 是酷我容器里 Caches/DocumentData 下的 rel。
func kuwoContainerDocumentDir(rel string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return otherAppContainer(filepath.Join(home, "Library/Containers/com.wenyu.kwplayermac/Data/Caches/DocumentData", rel))
}

// kuwoLocalLyricDir 是酷我客户端的歌词目录。
func kuwoLocalLyricDir() string {
	if kuwoLocalDirOverride != "" {
		return kuwoLocalDirOverride
	}
	return kuwoContainerDocumentDir("Lyric")
}

// kuwoLocalMaxFileBytes:单个歌词文件的大小上限,防目录里混进异常大的文件时白读白解。
const kuwoLocalMaxFileBytes = 1 << 20

// kuwoLocalRescanMin:两次重扫之间的最小间隔。客户端开播时才落盘,设大了换歌那一拍抢先扫过一次,
// 新写进来的那份整轮查不到(同 kugouLocalRescanMin)。只列目录、不读文件,不必省。
const kuwoLocalRescanMin = 2 * time.Second

// kuwoLocalNamedFile 认「歌手 - 歌名 - 曲目 id.lrcx / .lrc」。
var kuwoLocalNamedFile = regexp.MustCompile(`^(.+?) - (.+) - ([0-9]{1,20})\.(lrcx|lrc)$`)

type kuwoLocalEntry struct {
	path, artist, title, rid string
	mod                      time.Time
}

var (
	kuwoLocalMu      sync.Mutex
	kuwoLocalIndex   map[string][]kuwoLocalEntry
	kuwoLocalDirMod  time.Time
	kuwoLocalScanned time.Time
	kuwoLocalReady   bool
)

// kuwoLocalNamedIdentity 从文件名拆出歌手、歌名和曲目 id。
func kuwoLocalNamedIdentity(fileName string) (artist, title, rid string, ok bool) {
	m := kuwoLocalNamedFile.FindStringSubmatch(fileName)
	if m == nil {
		return "", "", "", false
	}
	artist, title = strings.TrimSpace(m[1]), strings.TrimSpace(m[2])
	return artist, title, m[3], artist != "" && title != ""
}

// refreshKuwoLocalIndexLocked 在目录 mtime 变过、且距上次扫描超过节流间隔时重建索引。调用方持有 kuwoLocalMu。
func refreshKuwoLocalIndexLocked() {
	dir := kuwoLocalLyricDir()
	if dir == "" {
		kuwoLocalIndex, kuwoLocalReady = nil, true
		return
	}
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		noteLocalCacheDenied("kuwo", dir, err)
		kuwoLocalIndex, kuwoLocalReady = nil, true
		return
	}
	now := time.Now()
	if kuwoLocalReady && st.ModTime().Equal(kuwoLocalDirMod) {
		return
	}
	if kuwoLocalReady && now.Sub(kuwoLocalScanned) < kuwoLocalRescanMin {
		return
	}
	kuwoLocalScanned, kuwoLocalReady = now, true
	ents, err := os.ReadDir(dir)
	if err != nil {
		noteLocalCacheDenied("kuwo", dir, err)
		kuwoLocalIndex = nil
		return
	}
	kuwoLocalDirMod = st.ModTime()
	noteLocalCacheReadable("kuwo")
	idx := map[string][]kuwoLocalEntry{}
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		artist, title, rid, ok := kuwoLocalNamedIdentity(e.Name())
		if !ok {
			continue
		}
		key := kugouLocalKey(artist, title)
		if key == "" {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		idx[key] = append(idx[key], kuwoLocalEntry{path: filepath.Join(dir, e.Name()), artist: artist, title: title,
			rid: rid, mod: info.ModTime()})
	}
	kuwoLocalIndex = idx
	if len(idx) > 0 {
		log.Printf("kuwo local: indexed %d tracks from client lyrics", len(idx))
	}
}

// kuwoLocalLookup 找这首歌在本地的那份。精确键(歌手、歌名各自 normLoose)落空时退到宽松匹配:歌手仍要精确相等,
// 歌名只认「多出来的是副标题」(kugouLocalTitleMatches,同一把尺子),几份都对得上时只留歌名长度最接近的那几份。
// 同一首有好几份(不同版本各落一份)时取最近写的:客户端开播时才写,最近那份就是在放的那一版。loose=true 是宽松命中。
func kuwoLocalLookup(artist, title string) (hit kuwoLocalEntry, loose, ok bool) {
	key := kugouLocalKey(artist, title)
	if key == "" {
		return kuwoLocalEntry{}, false, false
	}
	kuwoLocalMu.Lock()
	defer kuwoLocalMu.Unlock()
	refreshKuwoLocalIndexLocked()
	entries := kuwoLocalIndex[key]
	if len(entries) == 0 {
		na, nt := normLoose(artist), normLoose(title)
		bestGap := -1
		for _, list := range kuwoLocalIndex {
			for _, e := range list {
				if normLoose(e.artist) != na || !kugouLocalTitleMatches(e.title, title) {
					continue
				}
				gap := len(normLoose(e.title)) - len(nt)
				if gap < 0 {
					gap = -gap
				}
				switch {
				case bestGap < 0 || gap < bestGap:
					entries, bestGap = []kuwoLocalEntry{e}, gap
				case gap == bestGap:
					entries = append(entries, e)
				}
			}
		}
		loose = true
	}
	if len(entries) == 0 {
		return kuwoLocalEntry{}, false, false
	}
	hit = entries[0]
	for _, e := range entries[1:] {
		if e.mod.After(hit.mod) || (e.mod.Equal(hit.mod) && e.path < hit.path) {
			hit = e
		}
	}
	return hit, loose, true
}

// kuwoLocalLyric 在酷我客户端落盘的歌词里找这首歌。第二个返回值 false = 没命中,调用方照常走网络。
// durationSecs 只用来挡「歌词比歌还长」的另一个版本(kugouLocalLyricFitsDuration,同一道闸)。
func kuwoLocalLyric(artist, title string, durationSecs float64) (kuwoResult, bool) {
	hit, loose, ok := kuwoLocalLookup(artist, title)
	if !ok {
		return kuwoResult{}, false
	}
	lrc, yrc := kuwoLocalFileLyrics(hit.path)
	if lrc == "" || !kugouLocalLyricFitsDuration(lrc, durationSecs) {
		return kuwoResult{}, false
	}
	log.Printf("kuwo local: hit %q - %q (rid %s)", artist, title, hit.rid)
	return kuwoResult{
		lyrics: lrc, yrc: yrc, title: hit.title, artist: hit.artist, rid: hit.rid,
		// 宽松命中是按歌名前缀猜的,跟搜索打分一样可能认错版本,不配拿同源加权。
		fromLocalClient: !loose,
	}, true
}

// kuwoPlayingSongIDs:酷我此刻在放的这首在本地歌词文件名里的曲目 id,和 .lrcx 头里 `[al:]` 记的专辑 id(.lrc 没有)。
// 只认精确键,宽松命中不算(记错了歌曲页整首指错)。
func kuwoPlayingSongIDs(artist, title string) (songID, albumID string) {
	hit, loose, ok := kuwoLocalLookup(artist, title)
	if !ok || loose {
		return "", ""
	}
	if strings.HasSuffix(hit.path, ".lrcx") {
		if raw, err := os.ReadFile(hit.path); err == nil && len(raw) <= kuwoLocalMaxFileBytes {
			if text, ok := kuwoDecodeLocalLrcx(raw); ok {
				albumID = kuwoLrcxAlbumID(text)
			}
		}
	}
	return hit.rid, albumID
}

// kuwoLrcxAlbumIDRe 是 lrcx 头里的专辑 id 行:酷我在 `[al:]` 里写的是专辑的数字 id,不是专辑名。
var kuwoLrcxAlbumIDRe = regexp.MustCompile(`(?m)^\[al:([0-9]{1,20})\]\s*$`)

func kuwoLrcxAlbumID(text string) string {
	m := kuwoLrcxAlbumIDRe.FindStringSubmatch(strings.ReplaceAll(text, "\r\n", "\n"))
	if m == nil {
		return ""
	}
	return m[1]
}

// kuwoLocalFileLyrics 读一个本地歌词文件,返回逐行 LRC 和逐字 YRC(.lrc 没有逐字)。读不了、解不开返回空串。
func kuwoLocalFileLyrics(path string) (lrc, yrc string) {
	st, err := os.Stat(path)
	if err != nil || st.Size() > kuwoLocalMaxFileBytes {
		return "", ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return "", ""
	}
	if strings.HasSuffix(path, ".lrc") {
		return kuwoLocalPlainLRC(raw), ""
	}
	text, ok := kuwoDecodeLocalLrcx(raw)
	if !ok {
		noteParserUnrecognized("kuwo-local-lyric", "lrcx body did not decode")
		return "", ""
	}
	return kuwoLrcxToLRC(text), kuwoLrcxToYRC(text)
}

// kuwoLocalPlainLRC:本地 .lrc 去掉第一行的编码标记 `utf8`,行尾统一成 \n。
func kuwoLocalPlainLRC(raw []byte) string {
	text := strings.ReplaceAll(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\r", "\n")
	if first, rest, ok := strings.Cut(text, "\n"); ok && strings.EqualFold(strings.TrimSpace(first), "utf8") {
		text = rest
	}
	return kuwoLrcxToLRC(text)
}

// kuwoDecodeLocalLrcx 解开本地 .lrcx:按 \r\n 分行,第二行补齐 base64 的 `=` 后解码、与 `yeelion` 逐字节异或。
// 第一行不是 `utf8` 或解不开都返回 false。
func kuwoDecodeLocalLrcx(raw []byte) (string, bool) {
	lines := bytes.Split(raw, []byte("\r\n"))
	if len(lines) < 2 || !strings.EqualFold(string(bytes.TrimSpace(lines[0])), "utf8") {
		return "", false
	}
	b64 := string(bytes.TrimSpace(lines[1]))
	if b64 == "" {
		return "", false
	}
	if pad := len(b64) % 4; pad != 0 {
		b64 += strings.Repeat("=", 4-pad)
	}
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", false
	}
	key := []byte(kuwoLrcxKey)
	for i := range data {
		data[i] ^= key[i%len(key)]
	}
	text := string(data)
	if !strings.Contains(text, "[") {
		return "", false
	}
	return text, true
}

// kuwoLrcxToLRC 把 lrcx 正文(或明文 LRC)整理成逐行 LRC:只留带时间戳的行,去掉字级标记。译文行(整行 `<0,0>`、
// 挂在原文时间戳上)原样留着,跟网络那份一样由 adoptBakedTranslation 摘出去。正文一句都没有返回空串。
func kuwoLrcxToLRC(text string) string {
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	var out []string
	hasText := false
	for _, line := range strings.Split(text, "\n") {
		m := kuwoLrcxLineRe.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
		}
		body := strings.TrimSpace(kuwoLrcxWordTimeRe.ReplaceAllString(m[4], ""))
		if body != "" {
			hasText = true
		}
		out = append(out, "["+m[1]+":"+m[2]+"."+m[3]+"]"+body)
	}
	if !hasText {
		return ""
	}
	return strings.Join(out, "\n")
}

// kuwoLocalCoverURL:本地命中时补封面。本地文件不带图,系统会话也从不报封面,按歌手 + 歌名搜一次,只认曲目 id
// 跟本地那份相同的那一条;搜不到、没有这一条返回空串。
func kuwoLocalCoverURL(ctx context.Context, artist, title, rid string) string {
	if rid == "" {
		return ""
	}
	items, err := kuwoSearch(ctx, artist, title)
	if err != nil {
		return ""
	}
	for _, it := range items {
		if kuwoMusicID(it.MusicRID) == rid {
			return kuwoCoverURL(it.WebAlbumPicShort)
		}
	}
	return ""
}
