package main

import (
	"encoding/json"
	"fmt"
	"hash/crc32"
	"log"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// 歌词缓存 key 的**唯一**构造点,以及把存量旧 key 归并过来的一次性迁移。
//
// 为什么需要归一化:key 一直是 `artist|title|album` 三段原样拼出来的,而**同一首歌在不同
// 播放器里歌名拼法不一样** —— 中文专辑尤其常见"中文名 + 括号里的英文译名"这种写法,
// Spotify 报 `不散的筵席（I Miss You）`,网易云/Apple Music 报 `不散的筵席`。于是同一首歌
// 存成两条,各自独立跑一遍全源搜索、各自选中不同的源:
//
//	丁世光|不散的筵席|神經志 The Journal              → netease,43 行时间戳,score 1107
//	丁世光|不散的筵席（I Miss You）|神經志 The Journal  → kugou, 83 行时间戳,score 1203
//
// 后果不只是"歌词管理里多一行"。两份歌词的**断行和时间轴根本不是一份东西**(43 行 vs
// 83 行,后者把每个短句单独成行),于是用哪个播放器听,歌词推进的节奏就不一样 ——
// 现象是"Spotify 的进度比 Apple Music 快"就是这么来的:位置读数两边都准到
// 40 毫秒以内(实测),真正不同的是**读到了两份不同的歌词**。而且选中哪一份纯看播放器怎么
// 拼歌名,跟引擎自己算出来的 lyrics_score 谁高谁低毫无关系 —— 这条更要命,等于把
// 已经算好的质量判断丢掉了。
//
// key 里的歌名是播放器原样的完整歌名,只做 cleanMediaTag(不可见空白/全角空格,跟 App 侧清洗播放器标签的 cleanTag
// 同一套规则)。上面那种同一首歌两种写法,靠查找时的兜底合在一条上(canonicalEnrichKey):带说明括号的写法先找旧规则
// (legacyEnrichKey,去掉结尾的译名/副标题括号)那条,不带的写法找去括号后相同的那条;括号里写的不一样的两种写法
// (「Song (#6)」「Song (#11)」)各是一条。见 09 章决策 264。
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
	// "慢板"/"快板"必须留在这张表里:漏掉的话归一化会把整段括号连着这个词一起
	// 剥掉,存进缓存的 key 变成不带曲速标注的裸标题——跟正式完整版撞成同一个 key
	// (例:周杰伦《不能说的秘密》电影原声带"Secret (慢板)"会撞上正式版《Secret》,而
	// "(慢板)"这版实际时长只有 68 秒,是电影原声带里单独收录的钢琴慢版重奏,跟正式版是
	// **两个不同的录音**;理由跟"版"字那条一致:剥掉会把两首不同的音频当成同一首)。
	"慢板", "快板",
	"现场", "伴奏", "翻唱", "重制", "修复", "版", "纯音乐", "前奏", "间奏",
	// 角色歌、偶像企划标的演唱版本(「ソロ・バージョン」「花柳香子ソロ」):各角色的独唱版、合唱版是不同的录音。
	"バージョン", "ヴァージョン", "ソロ",
	// 同一张碟里原唱的伴奏版(「(Off Vocal)」)、剪短的版本(「(Game Size)」「(TVサイズ)」)、重新编曲的版本
	// (「(IGNITED arrangement)」):伴奏版、编曲版跟原唱时长差不多,时长消歧(resolveEnrichKeyForDuration)分不开。
	"off vocal", "off-vocal", "offvocal", "オフボーカル", "オフ・ボーカル", "サイズ", "arrange",
}

// enrichKeyVersionWordTokens:前后都不是 ASCII 字母、数字、下划线时才算版本标记的词(「花柳香子 ver」「Solo」)。
// 当子串认会把 forever、never 里的 ver 也算上。Swift 侧 EnrichCacheKeys.versionWordTokens 同一张表、同一种认法。
var enrichKeyVersionWordTokens = []string{"ver", "solo", "size"}

// 只匹配**结尾**的一组括号。中间出现的括号不动:那种位置的括号更可能是歌名本身的一部分,
// 而结尾括号在各家曲库里几乎专门用来挂译名/版本标注。半角全角、圆括号方括号方头括号都收。
var enrichKeyTrailingBracket = regexp.MustCompile(`\s*[（(\[【]([^）)\]】]*)[）)\]】]\s*$`)

// enrichKey 是歌词缓存 key 的唯一构造点。所有会往 enrichCache 里写/查的地方都必须走它
// (trackEnrichment / 专辑预取 / 从 lyrics 文件导入),漏掉一处就会重新长出重复条目。查不到时的兜底见 canonicalEnrichKey。
func enrichKey(artist, title, album string) string {
	return cleanMediaTag(artist) + "|" + cleanMediaTag(title) + "|" + cleanMediaTag(album)
}

// legacyEnrichKey:旧规则的 key,歌名去掉结尾的译名/副标题括号(normEnrichTitle)。存量条目都是按它建的;按歌名记的
// 提示表(Spotify 曲目 id、播放侧曲目 id、电台曲长、MV 时长)写的一边是播放器原样的歌名、读的一边常是流水线里剥过括号的,
// 两边都按它算才对得上。
func legacyEnrichKey(artist, title, album string) string {
	return cleanMediaTag(artist) + "|" + normEnrichTitle(title) + "|" + cleanMediaTag(album)
}

// legacyOfEnrichKey:一条缓存 key 按旧规则算出来的样子(歌名里的时长变体位「~durN」照留);切不出三段时原样返回。按 key 记忆化。
func legacyOfEnrichKey(key string) string {
	legacyKeyMemoMu.RLock()
	v, ok := legacyKeyMemo[key]
	legacyKeyMemoMu.RUnlock()
	if ok {
		return v
	}
	if strings.Count(key, "|") < 2 {
		return key
	}
	artist, title, album := splitEnrichKey(key)
	suffix := enrichKeyDurationVariantRe.FindString(title)
	v = legacyEnrichKey(artist, strings.TrimSuffix(title, suffix), album)
	if suffix != "" {
		a, t, al := splitEnrichKey(v)
		v = a + "|" + t + suffix + "|" + al
	}
	legacyKeyMemoMu.Lock()
	if len(legacyKeyMemo) >= looseKeyMemoMax {
		legacyKeyMemo = map[string]string{}
	}
	legacyKeyMemo[key] = v
	legacyKeyMemoMu.Unlock()
	return v
}

var (
	legacyKeyMemoMu sync.RWMutex
	legacyKeyMemo   = map[string]string{}
)

// enrichLegacyClaimedByOther:旧规则那条条目已经是另一种带括号写法的(播放器原样报的歌名记在 Reported 里,跟 title 去括号后
// 相同、本身不同,而且 title 不在其中):「Song (#11)」不借「Song (#6)」放出来的那条。没记过原样写法的不算。纯函数。
func enrichLegacyClaimedByOther(e enrichEntry, title string) bool {
	title = cleanMediaTag(title)
	legacy := normEnrichTitle(title)
	other := false
	for _, r := range e.Reported {
		t := cleanMediaTag(r.Title)
		if t == title {
			return false
		}
		if t != "" && t != legacy && normEnrichTitle(t) == legacy {
			other = true
		}
	}
	return other
}

// normEnrichTitle 反复剥掉结尾的译名括号,碰到版本标记就停手。搜歌词、挑候选用的歌名另见 lyricSearchTitle。
func normEnrichTitle(title string) string {
	return trimTrailingBrackets(title, enrichKeyKeepsBracket)
}

// enrichKeyKeepsBracket:这段括号(inner 不带括号本身)里有版本标记,整段保留。
func enrichKeyKeepsBracket(inner string) bool {
	inner = strings.ToLower(inner)
	for _, w := range enrichKeyVersionWords {
		if strings.Contains(inner, w) {
			return true
		}
	}
	for _, w := range enrichKeyVersionWordTokens {
		if containsASCIIWord(inner, w) {
			return true
		}
	}
	return false
}

// containsASCIIWord:s 里有 w,而且紧挨着的前后一个字节都不是 ASCII 字母、数字或下划线(跟正则 \b 同一口径;汉字、
// 假名的 UTF-8 字节都在 0x80 以上,算边界)。
func containsASCIIWord(s, w string) bool {
	for i := 0; i <= len(s)-len(w); {
		j := strings.Index(s[i:], w)
		if j < 0 {
			return false
		}
		start, end := i+j, i+j+len(w)
		if (start == 0 || !isASCIIWordByte(s[start-1])) && (end == len(s) || !isASCIIWordByte(s[end])) {
			return true
		}
		i = start + 1
	}
	return false
}

func isASCIIWordByte(b byte) bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// trimTrailingBrackets 从结尾一层层剥括号,keep 说这一层要留就停。
//
// 循环而不是只剥一次:`歌名（译名）[Explicit]` 这种两层的写法真实存在。剥到空串就整个放弃
// —— 有些曲目的歌名**本身**就是一对括号(`(Interlude)`),剥完什么都不剩的结果显然是错的。
func trimTrailingBrackets(title string, keep func(inner string) bool) string {
	t := cleanMediaTag(title)
	for {
		m := enrichKeyTrailingBracket.FindStringSubmatchIndex(t)
		if m == nil {
			return t
		}
		if keep(t[m[2]:m[3]]) {
			return t
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
	bases := []string{plain, hashed}
	// 加长度上限之前导出的存量文件用的是截断前那个更长的名字(同 lyricsFilesOwnedBy):漏了它,留下的文件
	// 下次启动会被导入复活成重复条目。
	if untruncated := sanitizeLyricsFilenameUntruncated(key); untruncated != plain {
		bases = append(bases, untruncated)
	}
	names := make([]string, 0, len(lyricsFileSuffixes)*len(bases))
	for _, b := range bases {
		for _, suffix := range lyricsFileSuffixes {
			names = append(names, b+suffix)
		}
	}
	return names
}

// betterEnrichEntry 在两条要被合并的记录里挑留下来的那条。返回 true 表示 a 更值得留。
//
// 顺序是有讲究的:
//   - 人工修正过的永远赢。它是这套缓存里唯一删了就找不回来的东西(重新解析只会又抓到
//     当初那份不准的),见 ManualLyrics 字段注释。
//   - 其次"有歌词"压过"没歌词"——空条目留着毫无意义。
//   - 再次比 lyrics_score。这正是引擎自己那套全源打分的结论,而重复条目的问题恰恰
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
	// loser 的网易云封面出自 winner 判错过的那首时不收,主色跟着它(见 neteaselinkcheck.go)。
	rejectedNeteaseCover := loser.CoverSource == "netease" && neteaseResultRejected(winner, loser)
	if winner.CoverURL == "" && !rejectedNeteaseCover {
		winner.CoverURL, winner.CoverSource = loser.CoverURL, loser.CoverSource
		// 设备封面在网上的同一张图跟着这张封面走(它只对记下时那张封面作数,见 enrichEntry.PublicCoverFor)。
		winner.PublicCoverURL, winner.PublicCoverFor = loser.PublicCoverURL, loser.PublicCoverFor
	}
	if winner.AccentColor == "" && !rejectedNeteaseCover {
		winner.AccentColor = loser.AccentColor
	}
	if winner.NeteaseRejected == "" {
		winner.NeteaseRejected = loser.NeteaseRejected
	}
	if winner.NeteaseURL == "" && !neteaseResultRejected(winner, loser) {
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
	if winner.SpotifyTrackID == "" {
		winner.SpotifyTrackID = loser.SpotifyTrackID
	}
	mergeEntryISRCs(&winner, loser)
	if winner.KKBOXURL == "" {
		winner.KKBOXURL = loser.KKBOXURL
	}
	if winner.AmazonURL == "" {
		winner.AmazonURL = loser.AmazonURL
	}
	if winner.YouTubeMusicURL == "" {
		winner.YouTubeMusicURL = loser.YouTubeMusicURL
	}
	if winner.SodaURL == "" {
		winner.SodaURL = loser.SodaURL
	}
	for _, f := range []struct{ dst, src *string }{
		{&winner.SodaAlbumID, &loser.SodaAlbumID}, {&winner.SodaArtistID, &loser.SodaArtistID},
		{&winner.KKBOXAlbumID, &loser.KKBOXAlbumID}, {&winner.KKBOXArtistID, &loser.KKBOXArtistID},
		{&winner.AmazonAlbumASIN, &loser.AmazonAlbumASIN}, {&winner.AmazonArtistASIN, &loser.AmazonArtistASIN},
		{&winner.SpotifyAlbumID, &loser.SpotifyAlbumID}, {&winner.SpotifyArtistID, &loser.SpotifyArtistID},
		{&winner.YouTubeMusicArtistID, &loser.YouTubeMusicArtistID},
	} {
		if *f.dst == "" {
			*f.dst = *f.src
		}
	}
	if winner.YouTubeMusicAlbumLang == "" && loser.YouTubeMusicAlbumLang != "" {
		winner.YouTubeMusicAlbum, winner.YouTubeMusicMV, winner.YouTubeMusicAlbumLang, winner.YouTubeMusicAlbumRev =
			loser.YouTubeMusicAlbum, loser.YouTubeMusicMV, loser.YouTubeMusicAlbumLang, loser.YouTubeMusicAlbumRev
		winner.YouTubeMusicAlbumID = loser.YouTubeMusicAlbumID
	}
	if winner.YouTubeMusicAlbum == "" && !winner.YouTubeMusicMV && winner.YouTubeMusicAlbumLang == "" {
		winner.YouTubeMusicAlbum = loser.YouTubeMusicAlbum
	}
	if winner.CanonicalArtist == "" {
		winner.CanonicalArtist = loser.CanonicalArtist
	}
	if winner.DurationSecs == 0 {
		winner.DurationSecs = loser.DurationSecs
	}
	// 落选那条记下的原始写法,胜者没有的那几个播放器带过来。
	if len(loser.Reported) > 0 {
		reported := maps.Clone(winner.Reported)
		if reported == nil {
			reported = map[string]reportedName{}
		}
		for b, r := range loser.Reported {
			if _, ok := reported[b]; !ok && len(reported) < maxNotedPlayers {
				reported[b] = r
			}
		}
		winner.Reported = reported
	}
	// 落选那条记下的播放器报的歌曲 id,胜者没有的那几个播放器连同成对的专辑 id 带过来;同一首、胜者没记专辑的补上专辑。
	for _, b := range songSortedKeys(loser.PlayerSongIDs) {
		if s := winner.PlayerSongIDs[b]; s == "" || (s == loser.PlayerSongIDs[b] && winner.PlayerAlbumIDs[b] == "") {
			notePlayerSongLocked(&winner, b, loser.PlayerSongIDs[b], loser.PlayerAlbumIDs[b])
		}
	}
	// 两条都放过的播放器合在一起,上面补过来的 id 对应的播放器也记上。
	winner.Players = slices.Clone(winner.Players)
	for _, p := range loser.Players {
		notePlayerLocked(&winner, p)
	}
	notePlayersFromRecords(&winner)
	return winner
}

// staleExportKeys 列出一组里**导出文件必须删掉**的那些旧 key。只有"本来就叫归一化后这个
// 名字、而且正是胜出的那条"能留着自己的文件;其余(改了名的胜者、以及所有落选者)一律删,
// 由紧随其后的 exportLyricsFiles 用胜出条目重新写一份。
//
// 这个函数存在的全部理由:判据**不能**写成"k != newKey 才删",
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
	buckets := map[string][]string{}
	for k := range cache {
		artist, title, album := splitEnrichKey(k)
		if artist == "" && title == "" && album == "" {
			buckets[k] = append(buckets[k], k) // 拆不出三段的畸形 key,原样留着别动
			continue
		}
		nk := enrichKey(artist, title, album)
		buckets[nk] = append(buckets[nk], k)
	}
	// 时长报错 / 基条目猜错分出去的「~durN」并回基条目那一组(variantFoldsIntoBase),不过下面 splitByDuration 那道时长关,
	// 留哪一份按 betterEnrichEntry。见 09 章决策 251。
	folded := map[string]bool{}
	bucketKeys := make([]string, 0, len(buckets))
	for nk := range buckets {
		bucketKeys = append(bucketKeys, nk)
	}
	sort.Strings(bucketKeys)
	for _, vnk := range bucketKeys {
		base, isVariant := durationVariantBaseKey(vnk)
		if !isVariant || len(buckets[base]) == 0 {
			continue
		}
		var keep []string
		for _, k := range buckets[vnk] {
			if slices.ContainsFunc(buckets[base], func(b string) bool { return variantFoldsIntoBase(cache[k], cache[b]) }) {
				buckets[base] = append(buckets[base], k)
				folded[k] = true
			} else {
				keep = append(keep, k)
			}
		}
		if len(keep) == 0 {
			delete(buckets, vnk)
		} else {
			buckets[vnk] = keep
		}
	}

	groups := map[string][]string{}
	for nk, all := range buckets {
		var ks, foldedKs []string
		for _, k := range all {
			if folded[k] {
				foldedKs = append(foldedKs, k)
			} else {
				ks = append(ks, k)
			}
		}
		merge, standalone := splitByDuration(cache, nk, ks)
		if len(merge) > 0 {
			merge = append(merge, foldedKs...)
		} else {
			standalone = append(standalone, foldedKs...)
		}
		if len(merge) > 0 {
			groups[nk] = append(groups[nk], merge...)
		}
		for _, k := range standalone {
			groups[k] = append(groups[k], k)
		}
	}
	for _, ks := range groups {
		sort.Strings(ks)
	}
	return groups
}

// splitByDuration 是给"版本词清单必然漏词"这个问题加的硬兜底。enrichKeyVersionWords
// 是个关键词清单,永远会漏词(下一次可能是"钢琴版"/"acoustic"/随便什么词,清单只能
// 越补越长),但两个不同录音的时长几乎不可能碰巧一样 —— 拿时长再兜一道,清单漏词时
// 也不至于把两首不同的歌合并成一条。
//
// 判据复用 durationMismatch(>12% 才算数、任一方时长未知就放行),跟"同一首歌换了个
// 版本要不要重新搜"用的是同一把尺子,两处结论保持一致。
//
// nk 恰好等于组内某个旧 key 本身、但那条 entry 时长又跟其它成员冲突时("这个名字该归
// 谁"三方打架的边界情况),直接放弃整组合并 —— 宁可这一轮什么都不合并,也不要把冲突的
// 那条错塞进本该属于别人的名字里。
func splitByDuration(cache map[string]enrichEntry, nk string, ks []string) (merge, standalone []string) {
	if len(ks) == 1 {
		return ks, nil
	}
	sorted := append([]string(nil), ks...)
	sort.Strings(sorted)
	anchor := sorted[0]
	for _, k := range sorted[1:] {
		if betterEnrichEntry(cache[k], cache[anchor], k, anchor) {
			anchor = k
		}
	}
	anchorDur := cache[anchor].DurationSecs
	for _, k := range sorted {
		if durationMismatch(anchorDur, cache[k].DurationSecs) {
			if k == nk {
				return nil, ks
			}
			standalone = append(standalone, k)
			continue
		}
		merge = append(merge, k)
	}
	return merge, standalone
}

// maxEnrichKeyDurationVariants 是 resolveEnrichKeyForDuration 愿意尝试的消歧变体上限。
// 现实中一个 key 下同时挂着两个以上互不相容时长的"重名录音"极其罕见,这个上限只是
// 防止(理论上)无限增殖,不是预期会用满的正常路径。
const maxEnrichKeyDurationVariants = 8

// enrichKeyDurationVariant 给 key 的**标题段**追加一个序号后缀,构造第 n 个消歧变体。
//
// 后缀加在标题而不是简单拼在整个 key 末尾:key 是 splitEnrichKey 按前两个 "|" 切出
// artist|title|album 三段,"歌词管理"直接显示这三段(见 enrichKey 头注释)。拼在末尾
// 会落进 album 段,让用户在列表里看到一个混进了内部标记的专辑名;拼在标题段虽然也会
// 带出一点技术痕迹("Secret~dur2"),但至少不污染看起来该是"干净"的专辑名,而且这条
// 分支本来就只在**关键词清单漏词**这种边界情况下才会触发,不追求好看,追求的是这个
// 标记本身就是"该去补关键词清单了"的信号。
//
// 用序号而不是把时长本身编进后缀:实测时长读数有几百毫秒抖动(trackEnrichment 头注释),
// 编时长进 key 会让同一份录音因为读数差一点就长出新 key,反而破坏缓存;序号 + 每次都用
// durationMismatch 判兼容,才能做到"抖动内还是同一条,差太多才另开一条"。
func enrichKeyDurationVariant(key string, n int) string {
	artist, title, album := splitEnrichKey(key)
	return artist + "|" + fmt.Sprintf("%s~dur%d", title, n) + "|" + album
}

// resolveEnrichKeyForDuration 是同一个问题的第二道兜底 —— splitByDuration
// 挡的是"启动时合并存量 key",这里挡的是**实时**场景:第一次遇到某首歌时,它的标题
// 就直接被(清单没收录的)版本词坑剥成了跟另一首歌相同的 key,而那首歌是 trackEnrichment
// **首次**建条目,压根没有"合并"这一步可拦——单纯是 map 里已经有人占了这个 key。
//
// 判据跟 splitByDuration 同一把尺子(durationMismatch,>12% 才算数、任一方时长未知就
// 放行)。命中已有条目但时长对不上时,不覆盖它(会把两首歌的数据来回冲刷,见头注释同一份
// 危害),也不能假装没找到直接原地新建(会真的覆盖掉),而是依次找 ~dur2/~dur3/... 这些
// 消歧变体位:遇到时长兼容的就复用,遇到空位就停在那里当新 key。8 个变体位都跟当前时长
// 冲突(几乎不可能:同一个标题下同时存在 8 种互不相容时长的"重名录音")才放弃消歧、退回
// 原 key —— 宁可退化回旧行为(会覆盖),不要无限增殖变体位。
func resolveEnrichKeyForDuration(cache map[string]enrichEntry, key string, durationSecs float64) (string, enrichEntry, bool) {
	if e, ok := cache[key]; !ok || !durationMismatch(e.DurationSecs, durationSecs) {
		return key, e, ok
	}
	for n := 2; n <= maxEnrichKeyDurationVariants; n++ {
		vk := enrichKeyDurationVariant(key, n)
		e, ok := cache[vk]
		if !ok || !durationMismatch(e.DurationSecs, durationSecs) {
			return vk, e, ok
		}
	}
	return key, cache[key], true
}

// migrateEnrichKeys 把存量缓存迁到归一化 key 上,并清掉合并后不再对应任何条目的导出文件。
//
// 必须在 importLyricsFromFiles() **之前**跑。lyrics/ 里的文件是按文件**头部标签**反查
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

// backupEnrichKeyMergeGroups 把这一次要合并的组(不止一条的)原样写到 `<缓存>.keynorm-<时间>.bak`。
// 没有要合并的组(只改名)不写。调用方持 enrichMu。
func backupEnrichKeyMergeGroups(groups map[string][]string) error {
	losers := map[string]enrichEntry{}
	for _, olds := range groups {
		if len(olds) < 2 {
			continue
		}
		for _, k := range olds {
			losers[k] = enrichCache[k]
		}
	}
	if len(losers) == 0 {
		return nil
	}
	data, err := json.Marshal(losers)
	if err != nil {
		return err
	}
	path := enrichPath + ".keynorm-" + time.Now().Format("20060102-150405") + ".bak"
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	log.Printf("enrich key migration: backed up %d entries about to be merged to %s", len(losers), filepath.Base(path))
	return nil
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
			// 从内存导出,不复制盘上那份:盘上的主缓存是精简格式,落选那条的正文只在它的正文小文件里,
			// 而没有对应条目的小文件会在启动时被清掉 —— 复制出来的备份就缺了正是要留的那部分。
			if data, err := json.Marshal(enrichCache); err == nil {
				if err := os.WriteFile(backup, data, 0o644); err != nil {
					warnf("enrich key migration: backup failed (%v), aborting", err)
					return false
				}
				log.Printf("enrich key migration: backed up %d entries to %s", len(enrichCache), filepath.Base(backup))
			}
		} else if err == nil {
			// 最初那份已经在了(不覆盖它),这一次的合并另留一份:只存这一次要并到一起的那几组,每次各留各的 ——
			// 配置搬家带来别处的旧写法、清洗规则或版本词表改了,都会在以后的启动里触发新的合并。
			if err := backupEnrichKeyMergeGroups(groups); err != nil {
				warnf("enrich key migration: merge backup failed (%v), aborting", err)
				return false
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
		if winnerKey != nk {
			renameDecisionSidecar(winnerKey, nk) // 判决明细跟着 key 走(decisionstore.go);被并掉的留给启动清理
		}
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
	if dir := lyricsDir(); dir != "" {
		for k := range stale {
			for _, name := range enrichExportedFileNames(k) {
				// 挪进废纸篓而不是直接删:迁移排在导入之前,用户在 lyrics/ 里对这首的手改这时还没导进来。
				path := filepath.Join(dir, name)
				if _, err := os.Stat(path); err == nil {
					trashFile(path)
					removedFiles++
				}
			}
		}
	}

	log.Printf("enrich key migration: %d entries -> %d (%d renamed, %d merged away, %d stale files removed)",
		len(merged)+mergedAway, len(merged), renamed, mergedAway, removedFiles)
	enrichCache = merged
	canonicalMemoReset()
	enrichDirty = true
	return true
}
