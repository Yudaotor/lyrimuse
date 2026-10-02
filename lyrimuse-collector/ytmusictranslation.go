package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"strings"
	"sync"
	"time"
)

// YouTube Music 给 LyricFind 歌词配的译文,是机翻链的第 0 级(machineTranslateLRCWithBase):只用于 lyricfind 源从
// YouTube Music 取回的那份歌词,没翻到的行照旧交给后面几级。译文是 Google 机翻(歌词页标「由 Google 翻译」),
// 跟其余几级一样按机翻记(LyricsTrSource)。
//
// 取法:逐行歌词那一页的 browse 应答不带译文,要再发一次 browse 续页。续页 token 由歌词的 browseId 拼成
// (ytmusicTranslationContinuation),hl 是要译成的语言,不登录、Android 身份即可。应答的 lyricsTranslations 只有
// 译文,不带原文和时间,条目按顺序对应逐行歌词里正文非空、不是「♪」的那些行(ytmusicTranslatableLines),条数
// 对不上整份不用。决策见 10 章决策 30。

// ytmusicTranslatable 记这个进程里 lyricfind 源取回过的逐行歌词:正文指纹(ytmusicTranslatableKey)→ 歌词 browseId。
// 只在内存:没记过的歌词(进程重启之前取回的、别的进程取回的)不走这一级。条数封顶 ytmusicTranslatableMax,
// 满了随手丢一条(map 遍历顺序不定),丢掉的那首只是少了这一级。
const ytmusicTranslatableMax = 1024

var (
	ytmusicTranslatableMu sync.Mutex
	ytmusicTranslatable   = map[[sha256.Size]byte]string{}
)

// ytmusicTranslationTimeout:第 0 级整体的时限(含换备用主机),到点当没有,交给后面几级。
var ytmusicTranslationTimeout = 6 * time.Second

// ytmusicTranslatableLines:LRC 里跟 lyricsTranslations 条目一一对应的那些行(正文非空、不是「♪」),去掉首尾空白,按顺序。
func ytmusicTranslatableLines(lyrics string) []string {
	var out []string
	for _, l := range parseLRCLines(lyrics) {
		if l.text != "♪" {
			out = append(out, l.text)
		}
	}
	return out
}

func ytmusicTranslatableKey(lines []string) [sha256.Size]byte {
	return sha256.Sum256([]byte(strings.Join(lines, "\n")))
}

// ytmusicRememberTranslatable 记下 lyricfind 源取回的这份逐行歌词和它的 browseId。
func ytmusicRememberTranslatable(lyrics, browseID string) {
	lines := ytmusicTranslatableLines(lyrics)
	if len(lines) == 0 || browseID == "" {
		return
	}
	k := ytmusicTranslatableKey(lines)
	ytmusicTranslatableMu.Lock()
	defer ytmusicTranslatableMu.Unlock()
	if _, exists := ytmusicTranslatable[k]; !exists && len(ytmusicTranslatable) >= ytmusicTranslatableMax {
		for old := range ytmusicTranslatable {
			delete(ytmusicTranslatable, old)
			break
		}
	}
	ytmusicTranslatable[k] = browseID
}

func ytmusicTranslatableBrowseID(lines []string) string {
	ytmusicTranslatableMu.Lock()
	defer ytmusicTranslatableMu.Unlock()
	return ytmusicTranslatable[ytmusicTranslatableKey(lines)]
}

// ytmusicTranslationsFor 是机翻链第 0 级:lyrics 是 lyricfind 源取回过的那份(ytmusicRememberTranslatable 记过)时,
// 问 YouTube Music 要它译成 target 的译文,返回「原文行 → 译文」,原文行是 parseLRCLines 给的正文。target 用
// myMemoryLangCode 的写法,hl 认同一套。没记过这份歌词、YouTube Music 在这个地区用不了、没问成、条数对不上都返回
// nil。译文本身还得再翻(lineNeedsTranslation)的行不收,交给后面几级:YouTube Music 当这行已经是目标语言时原样退回,
// 中英混排的繁体行常常只转成简体、英文原样留着。同一句出现几次只收第一份能用的。
func ytmusicTranslationsFor(ctx context.Context, lyrics, target string) map[string]string {
	if target == "" || ytmusicRegionBlockedNow(time.Now()) {
		return nil
	}
	lines := ytmusicTranslatableLines(lyrics)
	if len(lines) == 0 {
		return nil
	}
	browseID := ytmusicTranslatableBrowseID(lines)
	if browseID == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, ytmusicTranslationTimeout)
	defer cancel()
	got := ytmusicFetchTranslations(ctx, browseID, target)
	if len(got) != len(lines) {
		return nil
	}
	out := make(map[string]string, len(lines))
	for i, orig := range lines {
		if _, done := out[orig]; done {
			continue
		}
		if t := cleanYTMusicTranslation(orig, got[i]); t != "" && !lineNeedsTranslation(t, target) {
			out[orig] = t
		}
	}
	return out
}

// ytmusicFetchTranslations 取 browseId 那份歌词译成 hl 的译文,按 lyricsTranslations 的顺序。没问成返回 nil。
func ytmusicFetchTranslations(ctx context.Context, browseID, hl string) []string {
	body := ytmusicContext(ytmusicMobileClientName, ytmusicMobileClientVersion)
	if c, ok := body["context"].(map[string]any)["client"].(map[string]any); ok {
		c["hl"] = hl
	}
	body["continuation"] = ytmusicTranslationContinuation(browseID)
	raw, err := ytmusicPost(ctx, "browse", body, ytmusicCachedVisitorID())
	if err != nil || len(raw) == 0 {
		return nil
	}
	return ytmusicParseTranslations(raw)
}

// ytmusicTranslationContinuation 拼译文续页的 token:protobuf {80226972: {2: browseId, 3: "ugsCCAE%3D"}} 再 base64。
// 跟逐行歌词那一页(9.x 的 Android 身份)应答里 translationContinuationToken 给的是同一串。
func ytmusicTranslationContinuation(browseID string) string {
	inner := append(protoBytesField(2, []byte(browseID)), protoBytesField(3, []byte("ugsCCAE%3D"))...)
	return base64.URLEncoding.EncodeToString(protoBytesField(80226972, inner))
}

// protoBytesField 编一个 protobuf 长度定界字段(wire type 2)。
func protoBytesField(num uint64, payload []byte) []byte {
	b := binary.AppendUvarint(nil, num<<3|2)
	b = binary.AppendUvarint(b, uint64(len(payload)))
	return append(b, payload...)
}

// ytmusicParseTranslations 取续页应答 continuationContents.musicLyricsContinuation.lyricsTranslations 的译文。纯函数。
func ytmusicParseTranslations(raw []byte) []string {
	var resp struct {
		ContinuationContents struct {
			MusicLyricsContinuation struct {
				LyricsTranslations []struct {
					TranslatedLyricText string `json:"translatedLyricText"`
				} `json:"lyricsTranslations"`
			} `json:"musicLyricsContinuation"`
		} `json:"continuationContents"`
	}
	if json.Unmarshal(raw, &resp) != nil {
		return nil
	}
	items := resp.ContinuationContents.MusicLyricsContinuation.LyricsTranslations
	if len(items) == 0 {
		return nil
	}
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.TranslatedLyricText
	}
	return out
}

// cleanYTMusicTranslation 去掉译文里的零宽字符;原文行末不是句号时,再去掉译文末尾的一个句号(「。」或「.」,
// 省略号不动)。这家按整句补句号,其余几级和歌词原文行末都不带。
func cleanYTMusicTranslation(orig, tr string) string {
	tr = strings.TrimSpace(strings.Map(func(r rune) rune {
		switch r {
		case '\u200b', '\u200c', '\u200d', '\u2060', '\ufeff':
			return -1
		}
		return r
	}, tr))
	if strings.HasSuffix(orig, ".") || strings.HasSuffix(orig, "。") {
		return tr
	}
	if strings.HasSuffix(tr, "。") {
		return strings.TrimSuffix(tr, "。")
	}
	if strings.HasSuffix(tr, ".") && !strings.HasSuffix(tr, "..") {
		return strings.TrimSuffix(tr, ".")
	}
	return tr
}
