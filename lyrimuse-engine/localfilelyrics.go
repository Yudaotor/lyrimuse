package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

// 放本地文件的播放器正在放的那首,同目录同名的 .lrc —— 用户自己给这个文件配的歌词。App 找到正在放的文件
// (reAMP 和放本机文件的 QQ 音乐、网易云、酷狗、Spotify 按进程号找开着的文件,VOX 由脚本接口直接给,Pine 读界面,Apple Music 换歌时
// 问一次脚本的 location),把路径写进播放状态(local_file);只在正用它放这首时读。
//
// 不是歌词源:不进源清单,同 KKBOX 本地歌词(16 章 4.3)。players.json 里 reAMP、VOX、Pine 的 nativeLyricSource 填它
// (`playsLocalFiles` 按它认);Apple Music 自家源是 applemusic,另外记在 `playsLocalFiles` 和同源加权的目标里
// (setNativeLyricSourcesForPlayer)。按文件认这首、不靠搜,置 identityFromLocalClient 享受同源加权。见 02 章决策 126、178。

// localFileLyricsSource:同名 .lrc 那份候选的来源名(歌词缓存的 lyrics_source、决策记录、界面上的来源都用它)。
const localFileLyricsSource = "localfile"

// localFileLyricsMaxBytes:大过这个的 .lrc 不读(不是歌词)。
const localFileLyricsMaxBytes = 1 << 20

var (
	localFileCurrentMu sync.Mutex
	// localFileCurrent:App 此刻报的当前曲目和它的文件(只对放本地文件的播放器记)。
	localFileCurrent struct{ artist, title, path string }
)

// playsLocalFiles:这个播放器会放用户自己的文件:players.json 里 nativeLyricSource 填 localfile 的(reAMP、VOX、Pine),
// 加上 playsLocalFilesBesidesStreaming 那几家。
func playsLocalFiles(bundleID string) bool {
	player := playerForBundleID(bundleID)
	return player != "" && (playerNativeLyricSources[player] == localFileLyricsSource || playsLocalFilesBesidesStreaming(player))
}

// playsLocalFilesBesidesStreaming:自家另有歌词源、也放用户自己文件的播放器:放资料库里本地文件的 Apple Music、放本地列表的
// 洛雪(文件路径由引擎从洛雪的列表读,lxMusicLocalFilePath)、用「打开文件」放本机文件的 QQ 音乐、网易云、酷狗和从「本地文件」
// 列表放的 Spotify(App 按进程号找开着的文件,PlayerOpenFile)。放本地文件时文件旁的 .lrc、文件标签里的歌词就是它自己的
// 那份,同源加权也算 localfile。
func playsLocalFilesBesidesStreaming(player string) bool {
	switch player {
	case playerAppleMusic, playerLXMusic, playerQQMusic, playerNetease, playerKugou, playerSpotify:
		return true
	}
	return false
}

// noteLocalFileCurrentTrack:每拍读到 App 的播放状态时记下当前曲目的文件。不是放本地文件的播放器或没有文件时清掉。
func noteLocalFileCurrentTrack(bundleID, artist, title, path string) {
	if !playsLocalFiles(bundleID) || path == "" {
		artist, title, path = "", "", ""
	}
	localFileCurrentMu.Lock()
	defer localFileCurrentMu.Unlock()
	localFileCurrent.artist, localFileCurrent.title, localFileCurrent.path = artist, title, path
}

// localFileCurrentPath:App 此刻报的当前曲目就是这首(歌手、歌名不分大小写相同)时它的文件,否则 ""。
func localFileCurrentPath(artist, title string) string {
	localFileCurrentMu.Lock()
	cur := localFileCurrent
	localFileCurrentMu.Unlock()
	if cur.path == "" || !strings.EqualFold(strings.TrimSpace(cur.artist), strings.TrimSpace(artist)) ||
		!strings.EqualFold(strings.TrimSpace(cur.title), strings.TrimSpace(title)) {
		return ""
	}
	return cur.path
}

// localFileLyricsName:一个目录的文件名里,跟音频文件同名(不含扩展名,区分大小写)、扩展名是 .lrc(不分大小写)的那个;没有为 ""。
func localFileLyricsName(audioName string, entries []string) string {
	base := strings.TrimSuffix(audioName, filepath.Ext(audioName))
	for _, name := range entries {
		ext := filepath.Ext(name)
		if strings.EqualFold(ext, ".lrc") && strings.TrimSuffix(name, ext) == base {
			return name
		}
	}
	return ""
}

// localFileLRCTimestamp:LRC 的时间标签 [mm:ss] / [mm:ss.xx]。
var localFileLRCTimestamp = regexp.MustCompile(`\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]`)

// decodeLocalLyricsFile:.lrc 的字节转成文本。UTF-16 按 BOM 认;UTF-8 去掉 BOM;别的交给 decodeLyricBytes(不是 UTF-8 的行按
// GB18030 转,中文 .lrc 常是 GBK)。没有时间标签的不要:纯文本歌词对不上时间。
func decodeLocalLyricsFile(data []byte) (string, bool) {
	var text string
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xFE}), bytes.HasPrefix(data, []byte{0xFE, 0xFF}):
		big := data[0] == 0xFE
		body := data[2:]
		units := make([]uint16, 0, len(body)/2)
		for i := 0; i+1 < len(body); i += 2 {
			if big {
				units = append(units, uint16(body[i])<<8|uint16(body[i+1]))
			} else {
				units = append(units, uint16(body[i+1])<<8|uint16(body[i]))
			}
		}
		text = string(utf16.Decode(units))
	default:
		decoded, ok := decodeLyricBytes(bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}))
		if !ok {
			return "", false
		}
		text = decoded
	}
	text = strings.ReplaceAll(text, "\r\n", "\n")
	if !localFileLRCTimestamp.MatchString(text) {
		return "", false
	}
	return text, true
}

// localFileLyrics:正在放的这首同目录同名的 .lrc 的正文,没有(或读不出)时退到文件自己标签里的歌词
// (localFileEmbeddedLyrics);都没有为 false。
func localFileLyrics(artist, title string) (string, bool) {
	audio := localFileCurrentPath(artist, title)
	if audio == "" {
		return "", false
	}
	dir := filepath.Dir(audio)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			names = append(names, e.Name())
		}
	}
	if name := localFileLyricsName(filepath.Base(audio), names); name != "" {
		if lrc, ok := readLocalLyricsFile(filepath.Join(dir, name)); ok {
			return lrc, true
		}
	}
	text, ok := localFileEmbeddedLyricsMemo(audio)
	if !ok {
		return "", false
	}
	return strings.ReplaceAll(text, "\r\n", "\n"), true
}

// localFileEmbeddedMemoMax:标签的结论最多记几个文件。待播预取会一次问好几首,别小于预取的首数。
const localFileEmbeddedMemoMax = 16

type localFileEmbeddedVerdict struct {
	modTime time.Time
	size    int64
	tags    localFileTags
}

var (
	localFileEmbeddedMemoMu sync.Mutex
	localFileEmbeddedMemoed = map[string]localFileEmbeddedVerdict{}
)

// localFileEmbeddedLyricsMemo:同 localFileEmbeddedLyrics,结论记在 localFileTagsMemo 里。
func localFileEmbeddedLyricsMemo(path string) (string, bool) {
	t := localFileTagsMemo(path)
	return t.lyrics, t.hasLyrics
}

// localFileTagsMemo:同 readLocalFileTags,结论按路径记下,文件的修改时间和大小没变就不再读。标签区要整块读
// (最多 16MB,常带封面),播放期间反复问、文件又可能在 NAS / 外置盘上,不能每次都读一遍;只 stat 一下。
func localFileTagsMemo(path string) localFileTags {
	info, err := os.Stat(path)
	if err != nil {
		return localFileTags{}
	}
	localFileEmbeddedMemoMu.Lock()
	m, seen := localFileEmbeddedMemoed[path]
	localFileEmbeddedMemoMu.Unlock()
	if seen && m.size == info.Size() && m.modTime.Equal(info.ModTime()) {
		return m.tags
	}
	tags := readLocalFileTags(path)
	localFileEmbeddedMemoMu.Lock()
	if _, had := localFileEmbeddedMemoed[path]; !had && len(localFileEmbeddedMemoed) >= localFileEmbeddedMemoMax {
		clear(localFileEmbeddedMemoed)
	}
	localFileEmbeddedMemoed[path] = localFileEmbeddedVerdict{modTime: info.ModTime(), size: info.Size(), tags: tags}
	localFileEmbeddedMemoMu.Unlock()
	return tags
}

func readLocalLyricsFile(path string) (string, bool) {
	if info, err := os.Stat(path); err != nil || info.Size() == 0 || info.Size() > localFileLyricsMaxBytes {
		return "", false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return "", false
	}
	return decodeLocalLyricsFile(data)
}

// localFileLyricsFor 给歌词检索用:reAMP 是当前播放器的同源(见 setNativeLyricSourcesForPlayer)、这首有同名 .lrc 时,
// 换成一份跟各歌词源同形的原始应答。身份就是正在放的这首,时长用它的。
func localFileLyricsFor(artist, title string, durationSecs float64) (lyricSourceResult, bool) {
	if !isNativeLyricSource(localFileLyricsSource) {
		return lyricSourceResult{}, false
	}
	lrc, ok := localFileLyrics(artist, title)
	if !ok {
		return lyricSourceResult{}, false
	}
	// 文件标签里只有不带时间的歌词:交成纯文本,打分恒 −1、不顶掉任何一份带时间的;各源都没有带时间的版本时由纯文本兜底
	// 采用(plainTextFallbackFromScored 排在网上的纯文本前面)。
	return lyricSourceResult{
		source: localFileLyricsSource, lyr: lrc, matchTitle: title, matchArtist: artist, srcDur: durationSecs,
		identityFromLocalClient: true, plainOnly: !localFileLRCTimestamp.MatchString(lrc),
	}, true
}

// localFileLyricsAvailableTTL:同一首的「有没有 .lrc」记多久。trackEnrichment 在播放期间反复调,不必每次读目录。
const localFileLyricsAvailableTTL = 30 * time.Second

var (
	localFileLyricsAvailMu   sync.Mutex
	localFileLyricsAvailMemo = map[string]struct {
		at time.Time
		ok bool
	}{}
)

// localFileLyricsAvailable:正用放本地文件的播放器放的这首,现在有没有同名 .lrc(见 localFileLyricsWorthRecheck)。
func localFileLyricsAvailable(bundleID, artist, title string) bool {
	if !playsLocalFiles(bundleID) {
		return false
	}
	audio := localFileCurrentPath(artist, title)
	if audio == "" {
		return false
	}
	now := time.Now()
	localFileLyricsAvailMu.Lock()
	if m, ok := localFileLyricsAvailMemo[audio]; ok && now.Sub(m.at) < localFileLyricsAvailableTTL {
		localFileLyricsAvailMu.Unlock()
		return m.ok
	}
	localFileLyricsAvailMu.Unlock()
	// 只认带时间的:只有纯文本的不值得为它重来一轮(纯文本兜底在补歌词那条路上照样会采用)。
	text, ok := localFileLyrics(artist, title)
	ok = ok && localFileLRCTimestamp.MatchString(text)
	localFileLyricsAvailMu.Lock()
	for k, m := range localFileLyricsAvailMemo {
		if now.Sub(m.at) >= localFileLyricsAvailableTTL {
			delete(localFileLyricsAvailMemo, k)
		}
	}
	localFileLyricsAvailMemo[audio] = struct {
		at time.Time
		ok bool
	}{now, ok}
	localFileLyricsAvailMu.Unlock()
	return ok
}

// localFileLyricsRechecked:这次进程里已经为同名 .lrc 重来过的条目。只在 enrichMu 里读写。
var localFileLyricsRechecked = map[string]bool{}

// localFileLyricsRecheckOnce:同 kkboxLyricsRecheckOnce。调用方持有 enrichMu。
func localFileLyricsRecheckOnce(key string) bool {
	if localFileLyricsRechecked[key] {
		return false
	}
	localFileLyricsRechecked[key] = true
	return true
}

// localFileLyricsWorthRecheck:同 amazonLyricsWorthRecheck。条目当初没见过这份候选(不是用这类播放器放着解析的,或者 .lrc 是后来
// 才放进去的),现在正用它放、有同名 .lrc → 值得重来一次(retryLyricsUpgrade,分数严格更高才替换)。
func localFileLyricsWorthRecheck(e enrichEntry, bundleID string, pinned, autoUpgrade, available bool) bool {
	if !playsLocalFiles(bundleID) || !autoUpgrade || pinned || e.ManualLyrics || e.Instrumental || !available {
		return false
	}
	if slices.Contains(e.LyricsSourcesSeen, localFileLyricsSource) || slices.Contains(e.LyricsSourcesResponded, localFileLyricsSource) {
		return false
	}
	if e.LyricsDecision != nil && slices.Contains(e.LyricsDecision.SourcesResponded, localFileLyricsSource) {
		return false
	}
	return e.LyricsRetryCount < lyricsRetryMaxAttempts
}
