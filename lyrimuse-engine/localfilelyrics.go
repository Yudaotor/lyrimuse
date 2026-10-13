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

// 放本地文件的播放器(reAMP)正在放的那首,同目录同名的 .lrc —— 用户自己给这个文件配的歌词。App 按播放器的进程号找到
// 正在放的文件,把路径写进播放状态(local_file,只对 reAMP 填);只在正用它放这首时读。
//
// 不是歌词源:不进源清单,同 KKBOX 本地歌词(16 章 4.3)。players.json 里 reAMP 的 nativeLyricSource 填它,按文件认这首、
// 不靠搜,置 identityFromLocalClient 享受同源加权。见 02 章决策 126。

// localFileLyricsSource:同名 .lrc 那份候选的来源名(歌词缓存的 lyrics_source、决策记录、界面上的来源都用它)。
const localFileLyricsSource = "localfile"

// localFileLyricsMaxBytes:大过这个的 .lrc 不读(不是歌词)。
const localFileLyricsMaxBytes = 1 << 20

var (
	localFileCurrentMu sync.Mutex
	// localFileCurrent:App 此刻报的当前曲目和它的文件(只对 reAMP 记)。
	localFileCurrent struct{ artist, title, path string }
)

// noteLocalFileCurrentTrack:每拍读到 App 的播放状态时记下当前曲目的文件。不是 reAMP 或没有文件时清掉。
func noteLocalFileCurrentTrack(bundleID, artist, title, path string) {
	if bundleID != reampBundleID || path == "" {
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

// localFileLyrics:正在放的这首同目录同名的 .lrc 的正文;读不到为 false。
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
	name := localFileLyricsName(filepath.Base(audio), names)
	if name == "" {
		return "", false
	}
	path := filepath.Join(dir, name)
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
	return lyricSourceResult{
		source: localFileLyricsSource, lyr: lrc, matchTitle: title, matchArtist: artist, srcDur: durationSecs,
		identityFromLocalClient: true,
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

// localFileLyricsAvailable:正用 reAMP 放的这首,现在有没有同名 .lrc(见 localFileLyricsWorthRecheck)。
func localFileLyricsAvailable(bundleID, artist, title string) bool {
	if bundleID != reampBundleID {
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
	_, ok := localFileLyrics(artist, title)
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

// localFileLyricsWorthRecheck:同 amazonLyricsWorthRecheck。条目当初没见过这份候选(不是用 reAMP 放着解析的,或者 .lrc 是后来
// 才放进去的),现在正用它放、有同名 .lrc → 值得重来一次(retryLyricsUpgrade,分数严格更高才替换)。
func localFileLyricsWorthRecheck(e enrichEntry, bundleID string, pinned, autoUpgrade, available bool) bool {
	if bundleID != reampBundleID || !autoUpgrade || pinned || e.ManualLyrics || e.Instrumental || !available {
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
