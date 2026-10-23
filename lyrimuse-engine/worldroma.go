package main

import (
	"context"
	"errors"
	"time"
	"unicode"
)

// 日 / 韩 / 中以外几种文字(西里尔、希腊、泰文、天城文、古木基文、泰米尔文、僧伽罗文)的读音也预生成进
// lyrics_roma,导出的 .roma.lrc 才有它们。读音本体在 lyrics-romanize(LyrimuseCore 的 WorldRomanization,
// 各按官方体系或 ISO 标准写),这里只管哪些条目要问、存量怎么补。见 10 章决策 50、10 章决策 51、10 章决策 52。

// worldReadingScripts:helper 会按标准出读音的文字。阿拉伯字母、希伯来字母不在里面(不写短元音,只用源自带的)。
var worldReadingScripts = []*unicode.RangeTable{
	unicode.Cyrillic, unicode.Greek, unicode.Thai, unicode.Devanagari, unicode.Gurmukhi, unicode.Tamil, unicode.Sinhala,
}

// worldReadingMinLetters:这些文字的字母少于这个数不起 helper —— 英文歌里一个希腊字母当装饰不值得起子进程。
const worldReadingMinLetters = 20

// hasWorldReadingScript:正文里这几种文字的字母够不够多,值得交给 helper 出读音。
func hasWorldReadingScript(lyrics string) bool {
	n := 0
	for _, r := range lyrics {
		if unicode.In(r, worldReadingScripts...) {
			n++
			if n >= worldReadingMinLetters {
				return true
			}
		}
	}
	return false
}

// worldRomaDelay:启动后等这么久再补,排在另外两道读音迁移后面。
const worldRomaDelay = 4 * time.Minute

// errWorldReadingsUnsupported:helper 回包没带 world_readings —— 它比引擎旧、还不会出这几种文字的读音,
// 回的「没什么可注音的」不能当真。
var errWorldReadingsUnsupported = errors.New("lyrics-romanize does not romanize the world scripts")

// worldRomaGenerator 是补存量时实际调用的 helper;测试换成假实现。跟 onDeviceRomanize 不同,找不到 helper、
// helper 比引擎旧都要报出来(迁移据此不记水位),不能当成「这首没什么可注音的」。
var worldRomaGenerator = func(lyrics, kana string) (string, error) {
	reply, err := runLyricsRomanize(romanizeRequest{Lyrics: lyrics, KanaDonor: kana})
	if err != nil {
		return "", err
	}
	return worldRomaFromReply(reply)
}

// worldRomaFromReply:不带 world_readings 是 errWorldReadingsUnsupported;ok:false(这首没什么可注音的)是空串。
func worldRomaFromReply(reply romanizeReply) (string, error) {
	if !reply.WorldReadings {
		return "", errWorldReadingsUnsupported
	}
	if !reply.OK {
		return "", nil
	}
	return reply.Roma, nil
}

// startWorldRomaBackfill:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startWorldRomaBackfill(ctx context.Context) {
	scope := migrationScopeOf(migrationWorldRoma, migrationWorldRomaVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(worldRomaDelay):
		}
		backfillWorldRoma(ctx, scope)
	}()
}

// isWorldRomaCandidate:没有读音、正文里这几种文字够多、用户没手改过、不是粤语或台语歌的条目。
func isWorldRomaCandidate(e enrichEntry) bool {
	if e.Lyrics.IsZero() || !e.LyricsRoma.IsZero() || e.ManualLyrics ||
		e.SongLanguage == songLanguageCantonese || e.SongLanguage == songLanguageHokkien {
		return false
	}
	return hasWorldReadingScript(e.Lyrics.String())
}

// backfillWorldRoma 是补存量的本体,返回补了几条。写回时正文还是当初那份、读音仍是空的才补(regenerateStoredRoma)。
func backfillWorldRoma(ctx context.Context, scope migrationScope) int {
	var items []storedRomaItem
	enrichMu.Lock()
	for k, e := range scope.entries() {
		if isWorldRomaCandidate(e) {
			items = append(items, storedRomaItem{key: k, lyrics: e.Lyrics.String(), kana: e.LyricsKana})
		}
	}
	enrichMu.Unlock()
	filled, complete := regenerateStoredRoma(ctx, items, storedRomaRegeneration{
		label:       "world romanization backfill",
		regenerate:  func(it storedRomaItem) (string, error) { return worldRomaGenerator(it.lyrics, it.kana) },
		unsupported: errWorldReadingsUnsupported,
	})
	if complete {
		scope.markDone(migrationWorldRoma, migrationWorldRomaVersion)
	}
	return filled
}
