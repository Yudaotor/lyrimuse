// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"fmt"
	"hash/crc32"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// 歌词缓存 key 的**唯一**构造点,以及把存量旧 key 归并过来的一次性迁移。
//
// 为什么需要归一化:key 一直是 `artist|title|album` 三段原样拼出来的,而**同一首歌在不同
// 播放器里歌名拼法不一样** —— 中文专辑尤其常见"中文名 + 括号里的英文译名"这种写法,
// Spotify 报 `不散的筵席（I Miss You）`,网易云/Apple Music 报 `不散的筵席`。于是同一首歌
// 存成两条,各自独立跑一遍五源搜索、各自选中不同的源:
//
//	丁世光|不散的筵席|神經志 The Journal              → netease,43 行时间戳,score 1107
//	丁世光|不散的筵席（I Miss You）|神經志 The Journal  → kugou, 83 行时间戳,score 1203
//
// 后果不只是"歌词管理里多一行"。两份歌词的**断行和时间轴根本不是一份东西**(43 行 vs
// 83 行,后者把每个短句单独成行),于是用哪个播放器听,歌词推进的节奏就不一样 ——
// 2026-08-14 用户报的"Spotify 的进度比 Apple Music 快"就是这么来的:位置读数两边都准到
// 40 毫秒以内(实测),真正不同的是**读到了两份不同的歌词**。而且选中哪一份纯看播放器怎么
// 拼歌名,跟 collector 自己算出来的 lyrics_score 谁高谁低毫无关系 —— 这条更要命,等于把
// 已经算好的质量判断丢掉了。
//
// 归一化只做两件事,刻意保守:
//  1. cleanMediaTag —— 不可见空白/全角空格,跟 media-control 入口那道清洗同一套规则。
//  2. 去掉歌名结尾**括号里的译名/副标题**。
//
// 明确**不做**的:不转小写、不折繁简。这两样都会污染显示 —— 缓存条目里根本没有单独的
// title/artist/album 字段,"歌词管理"列表显示的就是 key 拆出来的那三段,转了小写就会看到
// "神经志 the journal"。大小写差异另有 canonicalEnrichKey 在查询时兜底(见那边注释),
// 是既有的、够用的处理。

// 括号里出现这些词,说明它标的是**另一个录音版本**,不是译名 —— 必须保留,合并了就是把
// 两首不同的音频当成同一首。默认行为是"去掉",这份清单是唯一的例外表,所以宁可写长。
//
// interlude/intro/outro 这几个尤其不能漏:它们是独立成轨的短片段,跟同名正式曲目是两个
// 录音。实测这张《神經志 The Journal》里就同时存在 `The Girl In Red (Interlude)` 和
// `Interlude : The Girl In Red` 两种拼法 —— 去掉括号会得到 `The Girl In Red`,而那可能是
// 另一首完整曲目。
var enrichKeyVersionWords = []string{
	"remix", "mix", "live", "acoustic", "instrumental", "inst", "demo", "cover",
	"remaster", "version", "ver.", "edit", "extended", "radio", "karaoke",
	"reprise", "feat", "ft.", "featuring", "session", "mono", "stereo", "dub",
	"unplugged", "acappella", "a cappella",
	"interlude", "intro", "outro", "skit", "prelude", "overture",
	"现场", "伴奏", "翻唱", "重制", "修复", "版", "纯音乐", "前奏", "间奏",
}

// 只匹配**结尾**的一组括号。中间出现的括号不动:那种位置的括号更可能是歌名本身的一部分,
// 而结尾括号在各家曲库里几乎专门用来挂译名/版本标注。半角全角、圆括号方括号方头括号都收。
var enrichKeyTrailingBracket = regexp.MustCompile(`\s*[（(\[【]([^）)\]】]*)[）)\]】]\s*$`)

// enrichKey 是歌词缓存 key 的唯一构造点。所有会往 enrichCache 里写/查的地方都必须走它
// (trackEnrichment / 专辑预取 / 从 lyrics 文件导入),漏掉一处就会重新长出重复条目。
func enrichKey(artist, title, album string) string {
	return cleanMediaTag(artist) + "|" + normEnrichTitle(title) + "|" + cleanMediaTag(album)
}

// normEnrichTitle 反复剥掉结尾的译名括号,碰到版本标记就停手。
//
// 循环而不是只剥一次:`歌名（译名）[Explicit]` 这种两层的写法真实存在。剥到空串就整个放弃
// —— 有些曲目的歌名**本身**就是一对括号(`(Interlude)`),剥完什么都不剩的结果显然是错的。
func normEnrichTitle(title string) string {
	t := cleanMediaTag(title)
	for {
		m := enrichKeyTrailingBracket.FindStringSubmatchIndex(t)
		if m == nil {
			return t
		}
		inner := strings.ToLower(t[m[2]:m[3]])
		for _, w := range enrichKeyVersionWords {
			if strings.Contains(inner, w) {
				return t // 版本标记,保留整段括号
			}
		}
		stripped := strings.TrimSpace(t[:m[0]])
		if stripped == "" {
			return t
		}
		t = stripped
	}
}

// enrichExportedFileNames 列出一个 key 在 lyrics/ 下**可能**占用的全部文件名:普通名 4 个
// + 带消歧哈希后缀的 4 个。跟 Swift 侧 EnrichCacheKeys.exportedFileNames 逐一对应,理由见
// 那边注释(碰撞组里的 key 在磁盘上只有带后缀的那份)。
func enrichExportedFileNames(key string) []string {
	plain := sanitizeLyricsFilename(key)
	hashed := fmt.Sprintf("%s~%06x", plain, crc32.ChecksumIEEE([]byte(key))&0xFFFFFF)
	names := make([]string, 0, len(lyricsFileSuffixes)*2)
	for _, suffix := range lyricsFileSuffixes {
		names = append(names, plain+suffix, hashed+suffix)
	}
	return names
}

// betterEnrichEntry 在两条要被合并的记录里挑留下来的那条。返回 true 表示 a 更值得留。
//
// 顺序是有讲究的:
//   - 人工修正过的永远赢。它是这套缓存里唯一删了就找不回来的东西(重新解析只会又抓到
//     当初那份不准的),见 ManualLyrics 字段注释。
//   - 其次"有歌词"压过"没歌词"——空条目留着毫无意义。
//   - 再次比 lyrics_score。这正是 collector 自己那套五源打分的结论,而重复条目的问题恰恰
//     是"选哪份跟分数无关、只看播放器怎么拼歌名"。按分数选,等于把本来就该生效的判断补上。
//   - 最后按 TS 更新的赢,再不行按 key 字典序 —— 只为让结果**确定**,不受 map 遍历顺序影响
//     (Go 的 map 每次进程重启顺序都随机,不定死的话同一份数据两次迁移可能选出不同赢家)。
func betterEnrichEntry(a, b enrichEntry, aKey, bKey string) bool {
	if a.ManualLyrics != b.ManualLyrics {
		return a.ManualLyrics
	}
	if (a.Lyrics != "") != (b.Lyrics != "") {
		return a.Lyrics != ""
	}
	if a.LyricsScore != b.LyricsScore {
		return a.LyricsScore > b.LyricsScore
	}
	if (a.LyricsYRC != "") != (b.LyricsYRC != "") {
		return a.LyricsYRC != ""
	}
	if a.TS != b.TS {
		return a.TS > b.TS
	}
	return aKey < bKey
}

// mergePeripheralInto 把 loser 身上 winner 缺的**外围**字段补过去。
//
// 只补外围(封面/主色/各平台链接/官方歌手名/时长),歌词那一组字段一个都不碰 ——
// Lyrics/LyricsTr/LyricsRoma/LyricsYRC/LyricsSource/分数/语言/manual 是**一整套互相咬合的
// 东西**:译文的断行是跟着它自己那份歌词走的,把 loser 的译文贴到 winner 的歌词上,时间轴
// 直接错位。宁可让 winner 缺译文 —— needsTranslationBackfill 会自己补回来。
//
// 漏掉某个外围字段的代价也有限:needsPeripheralBackfill 本来就在盯着这些字段,缺了会自动
// 重新补一次。这是这里敢用"逐个字段显式写"而不是反射的底气。
func mergePeripheralInto(winner, loser enrichEntry) enrichEntry {
	if winner.CoverURL == "" {
		winner.CoverURL, winner.CoverSource = loser.CoverURL, loser.CoverSource
	}
	if winner.AccentColor == "" {
		winner.AccentColor = loser.AccentColor
	}
	if winner.NeteaseURL == "" {
		winner.NeteaseURL = loser.NeteaseURL
	}
	if winner.AppleURL == "" {
		winner.AppleURL = loser.AppleURL
	}
	if winner.QQURL == "" {
		winner.QQURL = loser.QQURL
	}
	if winner.SpotifyURL == "" {
		winner.SpotifyURL = loser.SpotifyURL
	}
	if winner.CanonicalArtist == "" {
		winner.CanonicalArtist = loser.CanonicalArtist
	}
	if winner.DurationSecs == 0 {
		winner.DurationSecs = loser.DurationSecs
	}
	return winner
}

// staleExportKeys 列出一组里**导出文件必须删掉**的那些旧 key。只有"本来就叫归一化后这个
// 名字、而且正是胜出的那条"能留着自己的文件;其余(改了名的胜者、以及所有落选者)一律删,
// 由紧随其后的 exportLyricsFiles 用胜出条目重新写一份。
//
// ⚠️ 2026-08-14 实测踩到的坑,这个函数存在的全部理由:第一版的判据是"k != newKey 才删",
// 于是**落选**条目只要它的 key 恰好等于归一化后的 key(带译名的那条胜出时必然如此),它的
// .lrc 就被留在盘上;紧接着 importLyricsFromFiles 按文件头部标签算出同一个 key,把落选那份
// 正文又盖回胜出条目上 —— 得到一条 lyrics_score/lyrics_source 记着胜者、正文却是败者的
// 自相矛盾记录。落选条目的文件必须无条件删掉,跟它叫什么名字无关。
func staleExportKeys(newKey, winnerKey string, olds []string) []string {
	out := make([]string, 0, len(olds))
	for _, k := range olds {
		if k == winnerKey && k == newKey {
			continue
		}
		out = append(out, k)
	}
	return out
}

// planEnrichKeyMigration 把当前缓存里的 key 按归一化结果分组,返回"新 key → 这一组的旧
// key(已排序)"。纯函数,好测;真正改内存/删文件的是下面的 migrateEnrichKeys。
func planEnrichKeyMigration(cache map[string]enrichEntry) map[string][]string {
	groups := map[string][]string{}
	for k := range cache {
		artist, title, album := splitEnrichKey(k)
		if artist == "" && title == "" && album == "" {
			groups[k] = append(groups[k], k) // 拆不出三段的畸形 key,原样留着别动
			continue
		}
		nk := enrichKey(artist, title, album)
		groups[nk] = append(groups[nk], k)
	}
	for _, ks := range groups {
		sort.Strings(ks)
	}
	return groups
}

// migrateEnrichKeys 把存量缓存迁到归一化 key 上,并清掉合并后不再对应任何条目的导出文件。
//
// ⚠️ 必须在 importLyricsFromFiles() **之前**跑。lyrics/ 里的文件是按文件**头部标签**反查
// key 的(不看文件名),合并之后同一个 key 会同时对应两份内容不同的文件,import 遍历 map
// 的顺序又是随机的 —— 不先把落选的那份文件删掉,条目内容会在每次重启时随机在两份歌词之间
// 反复横跳。删掉之后,紧跟其后的 exportLyricsFiles() 会用胜出条目重新写出新文件名那一份。
//
// 幂等:归一化过的 key 再算一次还是它自己,没有任何一组需要改动时直接返回,不写盘不备份。
func migrateEnrichKeys() {
	// saveEnrichCache 自己会取 enrichMu,必须等下面这步把锁放掉之后再调,否则死锁。
	if applyEnrichKeyMigration() {
		saveEnrichCache()
	}
}

// applyEnrichKeyMigration 自己取锁做完内存态的归并,返回"有没有真的改过东西"。落盘交给
// 调用方,理由见 migrateEnrichKeys 里那行注释。
func applyEnrichKeyMigration() bool {
	enrichMu.Lock()
	defer enrichMu.Unlock()

	groups := planEnrichKeyMigration(enrichCache)
	needsWork := false
	for nk, olds := range groups {
		if len(olds) > 1 || olds[0] != nk {
			needsWork = true
			break
		}
	}
	if !needsWork {
		return false
	}

	// 动手前留一份原始缓存。合并会丢掉落选那条的歌词正文(这正是合并的含义),而这是本仓
	// 唯一一处会主动丢弃已解析歌词的地方 —— 留个后悔药。只在备份还不存在时写:重复迁移
	// 不该把最初那份原始数据覆盖掉。
	if enrichPath != "" {
		backup := enrichPath + ".pre-keynorm.bak"
		if _, err := os.Stat(backup); os.IsNotExist(err) {
			if data, err := os.ReadFile(enrichPath); err == nil {
				if err := os.WriteFile(backup, data, 0o644); err != nil {
					log.Printf("enrich key migration: backup failed (%v), aborting", err)
					return false
				}
				log.Printf("enrich key migration: backed up %d entries to %s", len(enrichCache), filepath.Base(backup))
			}
		}
	}

	merged := make(map[string]enrichEntry, len(groups))
	stale := map[string]bool{} // 需要删掉导出文件的旧 key
	renamed, mergedAway := 0, 0
	for nk, olds := range groups {
		winnerKey := olds[0]
		for _, k := range olds[1:] {
			if betterEnrichEntry(enrichCache[k], enrichCache[winnerKey], k, winnerKey) {
				winnerKey = k
			}
		}
		e := enrichCache[winnerKey]
		for _, k := range olds {
			if k == winnerKey {
				continue
			}
			e = mergePeripheralInto(e, enrichCache[k])
			mergedAway++
			// 说"丢掉哪条、留下哪条",不写成 "merging X into N":落选条目的 key 常常**正好
			// 等于**归一化后的 N(带译名的那条胜出时必然如此),那样打出来两边字符串一模一样,
			// 看着像个空操作。
			log.Printf("enrich key migration: dropping %q (source=%s score=%d) in favour of %q",
				k, enrichCache[k].LyricsSource, enrichCache[k].LyricsScore, winnerKey)
		}
		merged[nk] = e
		for _, k := range staleExportKeys(nk, winnerKey, olds) {
			stale[k] = true
			if k == winnerKey {
				renamed++
			}
		}
		if len(olds) > 1 {
			log.Printf("enrich key migration: %q kept %s (source=%s score=%d manual=%v)",
				nk, winnerKey, e.LyricsSource, e.LyricsScore, e.ManualLyrics)
		}
	}

	removedFiles := 0
	if lyricsDir != "" {
		for k := range stale {
			for _, name := range enrichExportedFileNames(k) {
				if err := os.Remove(filepath.Join(lyricsDir, name)); err == nil {
					removedFiles++
				}
			}
		}
	}

	log.Printf("enrich key migration: %d entries -> %d (%d renamed, %d merged away, %d stale files removed)",
		len(merged)+mergedAway, len(merged), renamed, mergedAway, removedFiles)
	enrichCache = merged
	enrichDirty = true
	return true
}
