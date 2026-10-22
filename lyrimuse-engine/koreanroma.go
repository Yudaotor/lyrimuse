package main

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode"
)

// 存量韩文罗马音换成按读音的版本。
//
// 韩文罗马音由 lyrics-romanize 按读音写(사랑해 → saranghae,见 LyrimuseCore 的 KoreanRomanization);
// 缓存里早先预生成、写进 lyrics_roma 的是旧版 ICU 逐字母转写(salanghae)。App 优先显示 lyrics_roma,
// 导出的 .roma.lrc 也是它,不重算就一直停在旧版。
//
// 只换我们自己生成的那份:用户手改过的条目(manual_lyrics)整条跳过;其余交给 helper 判是不是旧版
// (legacy_korean_roma,按含谚文的正文行逐行跟 ICU 转写比),歌词源给的对不上、原样不动。helper 判过才在回包里
// 带 legacy_checked,不带(比引擎旧的 helper 不认这个入参,会照常回一份罗马音)就不换。helper 是子进程,放后台、
// 锁外调;写回时正文和罗马音都还是当初读到的那份才换(期间被重评分、手改过的不动)。找不到 helper、调用出错、
// 中途收到退出信号、换完没存成都不记水位,下次启动再跑。见 10 章决策 33。

// legacyKoreanRomaDelay:启动后等这么久再开始,不跟启动后第一轮解析抢资源。
const legacyKoreanRomaDelay = 2 * time.Minute

// errLegacyCheckUnsupported:helper 回了 ok 却没带 legacy_checked —— 它没判「是不是旧版」,回的罗马音不能拿来换。
var errLegacyCheckUnsupported = errors.New("lyrics-romanize did not check legacy_korean_roma")

// legacyKoreanRomaRegenerator 是迁移实际调用的 helper;测试换成假实现。
var legacyKoreanRomaRegenerator = onDeviceRegenerateLegacyKoreanRoma

// onDeviceRegenerateLegacyKoreanRoma:stored 是旧版韩文读音给这份正文算出来的,就返回按读音重算的罗马音;
// 不是就返回空串。找不到 helper、helper 没判,返回错误,迁移据此不记水位。
func onDeviceRegenerateLegacyKoreanRoma(lyrics, stored string) (string, error) {
	if lyrics == "" || stored == "" {
		return "", nil
	}
	reply, err := runLyricsRomanize(romanizeRequest{Lyrics: lyrics, LegacyKoreanRoma: stored})
	if err != nil {
		return "", err
	}
	return legacyRomaFromReply(reply)
}

// legacyRomaFromReply:ok:false(不是旧版、没产出)是空串;ok 却没带 legacy_checked 是 errLegacyCheckUnsupported。
func legacyRomaFromReply(reply romanizeReply) (string, error) {
	if !reply.OK {
		return "", nil
	}
	if !reply.LegacyChecked {
		return "", errLegacyCheckUnsupported
	}
	return reply.Roma, nil
}

// startLegacyKoreanRomaMigration:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startLegacyKoreanRomaMigration(ctx context.Context) {
	scope := migrationScopeOf(migrationLegacyKoreanRoma, migrationLegacyKoreanRomaVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(legacyKoreanRomaDelay):
		}
		migrateLegacyKoreanRoma(ctx, scope)
	}()
}

// isLegacyKoreanRomaCandidate:有罗马音、正文里有谚文、用户没手改过的条目值得问 helper;是不是旧版由 helper 判。
func isLegacyKoreanRomaCandidate(e enrichEntry) bool {
	return !e.Lyrics.IsZero() && !e.LyricsRoma.IsZero() && !e.ManualLyrics &&
		strings.ContainsFunc(e.Lyrics.String(), func(r rune) bool { return unicode.Is(unicode.Hangul, r) })
}

// migrateLegacyKoreanRoma 是迁移本体,返回换了几条。
func migrateLegacyKoreanRoma(ctx context.Context, scope migrationScope) int {
	var items []storedRomaItem
	enrichMu.Lock()
	for k, e := range scope.entries() {
		if isLegacyKoreanRomaCandidate(e) {
			items = append(items, storedRomaItem{key: k, lyrics: e.Lyrics.String(), roma: e.LyricsRoma.String()})
		}
	}
	enrichMu.Unlock()
	replaced, complete := regenerateStoredRoma(ctx, items, storedRomaRegeneration{
		label:       "legacy korean romanization",
		regenerate:  func(it storedRomaItem) (string, error) { return legacyKoreanRomaRegenerator(it.lyrics, it.roma) },
		unsupported: errLegacyCheckUnsupported,
	})
	if complete {
		scope.markDone(migrationLegacyKoreanRoma, migrationLegacyKoreanRomaVersion)
	}
	return replaced
}
