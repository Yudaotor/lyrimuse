package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"
	"unicode"
)

// 存量里早先预生成、读音算法改过之后已经过时的读音,按现在的算法重算。
//
// App 优先显示 lyrics_roma,导出的 .roma.lrc 也是它;预生成的那份不重算,就一直停在生成那天的算法上。
// 只换我们自己生成的:手改过的(manual_lyrics)、粤语歌(读音只认粤拼)、台语歌(不标读音)整条跳过;其余交给 helper 判
// (stale_roma:逐行跟现算比,八成以上一字不差才算,见 LyricsRomanization.refreshedGeneratedRomanization),歌词源给的
// 对不上、原样不动。helper 判过才在回包里带 stale_checked,比引擎旧的 helper 不认这个入参,不带就不换。其余流程同
// koreanroma.go(后台、锁外调 helper,写回时正文和读音都还是当初那份才换,没跑完不记水位)。见 10 章决策 43。

// staleRomaDelay:启动后等这么久再开始,排在韩文那道迁移后面,不跟启动后第一轮解析抢资源。
const staleRomaDelay = 3 * time.Minute

// errStaleCheckUnsupported:helper 回了 ok 却没带 stale_checked —— 它没判「是不是过时的预生成」,回的读音不能拿来换。
var errStaleCheckUnsupported = errors.New("lyrics-romanize did not check stale_roma")

// staleRomaRegenerator 是迁移实际调用的 helper;测试换成假实现。
var staleRomaRegenerator = onDeviceRegenerateStaleRoma

// onDeviceRegenerateStaleRoma:stored 是早先预生成、已经过时的那份,就返回按现在的算法重算的读音;不是返回空串。
// 找不到 helper、helper 没判,返回错误,迁移据此不记水位。
// kanaDonor 是条目借来的假名标注(LyricsKana),重算按它标。
func onDeviceRegenerateStaleRoma(lyrics, stored, kanaDonor string) (string, error) {
	if lyrics == "" || stored == "" {
		return "", nil
	}
	reply, err := runLyricsRomanize(romanizeRequest{Lyrics: lyrics, StaleRoma: stored, KanaDonor: kanaDonor})
	if err != nil {
		return "", err
	}
	return staleRomaFromReply(reply)
}

// staleRomaFromReply:ok:false(不是过时的预生成)是空串;ok 却没带 stale_checked 是 errStaleCheckUnsupported。
func staleRomaFromReply(reply romanizeReply) (string, error) {
	if !reply.OK {
		return "", nil
	}
	if !reply.StaleChecked {
		return "", errStaleCheckUnsupported
	}
	return reply.Roma, nil
}

// startStaleGeneratedRomaMigration:常驻进程启动后调。范围照迁移水位定(migrationScopeOf),这一轮不用扫就什么都不做。
func startStaleGeneratedRomaMigration(ctx context.Context) {
	scope := migrationScopeOf(migrationStaleGeneratedRoma, migrationStaleGeneratedRomaVersion)
	if scope.skip() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(staleRomaDelay):
		}
		migrateStaleGeneratedRoma(ctx, scope)
	}()
}

// isStaleRomaCandidate:有读音、正文里有假名 / 谚文 / 汉字、用户没手改过、不是粤语或台语歌的条目值得问 helper。
func isStaleRomaCandidate(e enrichEntry) bool {
	if e.Lyrics.IsZero() || e.LyricsRoma.IsZero() || e.ManualLyrics ||
		e.SongLanguage == songLanguageCantonese || e.SongLanguage == songLanguageHokkien {
		return false
	}
	return strings.ContainsFunc(e.Lyrics.String(), func(r rune) bool {
		return unicode.In(r, unicode.Hiragana, unicode.Katakana, unicode.Hangul, unicode.Han)
	})
}

// migrateStaleGeneratedRoma 是迁移本体,返回换了几条。
func migrateStaleGeneratedRoma(ctx context.Context, scope migrationScope) int {
	var items []storedRomaItem
	enrichMu.Lock()
	for k, e := range scope.entries() {
		if isStaleRomaCandidate(e) {
			items = append(items, storedRomaItem{key: k, lyrics: e.Lyrics.String(), roma: e.LyricsRoma.String(), kana: e.LyricsKana})
		}
	}
	enrichMu.Unlock()
	replaced, complete := regenerateStoredRoma(ctx, items, storedRomaRegeneration{
		label:       "stale generated romanization",
		regenerate:  func(it storedRomaItem) (string, error) { return staleRomaRegenerator(it.lyrics, it.roma, it.kana) },
		unsupported: errStaleCheckUnsupported,
	})
	if complete {
		scope.markDone(migrationStaleGeneratedRoma, migrationStaleGeneratedRomaVersion)
	}
	return replaced
}

// storedRomaRegeneration:一道「把存着的读音交给 helper 判、该换就换」的存量迁移。
type storedRomaRegeneration struct {
	label       string
	regenerate  func(storedRomaItem) (string, error)
	unsupported error // helper 不认这道迁移的入参:后面每一条结果都一样,不再一条条白问
}

// kana 是条目借来的假名标注;写回时它也得还是当初那份。
type storedRomaItem struct{ key, lyrics, roma, kana string }

// regenerateStoredRoma 把候选逐条交给 helper,该换的换掉,返回换了几条、是不是全部问成也存成了(调用方据此记水位)。
// helper 是子进程,锁外调;写回时正文和读音都还是当初读到的那份才换(期间被重评分、手改过的不动)。找不到 helper、
// 调用出错、中途收到退出信号、换完没存成都算没跑完。
func regenerateStoredRoma(ctx context.Context, items []storedRomaItem, m storedRomaRegeneration) (int, bool) {
	fresh := make(map[string]string)
	complete := true
	failed := 0
	for _, it := range items {
		if ctx.Err() != nil {
			complete = false
			break
		}
		roma, err := m.regenerate(it)
		if err != nil {
			complete = false
			failed++
			if failed == 1 {
				warnf("%s: helper failed key=%q: %v", m.label, it.key, err)
			}
			if errors.Is(err, errRomanizeHelperMissing) || errors.Is(err, m.unsupported) {
				break
			}
			continue
		}
		if roma != "" && roma != it.roma {
			fresh[it.key] = roma
		}
	}

	var replaced []string
	enrichMu.Lock()
	for _, it := range items {
		roma, ok := fresh[it.key]
		if !ok {
			continue
		}
		e, ok := enrichCache[it.key]
		if !ok || !e.Lyrics.EqualString(it.lyrics) || !e.LyricsRoma.EqualString(it.roma) || e.LyricsKana != it.kana {
			continue
		}
		e.LyricsRoma = bt(roma)
		enrichCache[it.key] = e
		replaced = append(replaced, it.key)
	}
	if len(replaced) > 0 {
		enrichDirty = true // 不置脏 saveEnrichCache 不写盘
	}
	enrichMu.Unlock()
	if len(replaced) > 0 {
		if err := saveEnrichCacheChecked(); err != nil {
			// 换好的留在内存里、脏标记已还原,之后哪一次保存成功都会写下;水位不记,下次启动再核一遍。
			warnf("%s: save failed regenerated=%d: %v", m.label, len(replaced), err)
			complete = false
		}
		exportLyricsFilesFor(replaced...)
	}
	slog.Info(m.label+": done", "candidates", len(items), "regenerated", len(replaced),
		"failed", failed, "complete", complete)
	return len(replaced), complete
}
