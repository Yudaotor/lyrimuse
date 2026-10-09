package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
)

// 启动期存量迁移的「已完成水位」。
//
// 为什么需要:有些迁移做的是**存量规整** —— 把全库扫一遍改成新形态,改完就稳定了,而运行期
// 写入的新数据在各自的链路上已经是新形态。这类迁移原本每次进程启动都全量重跑一遍。实测
// migrateLyricTimelines 在 6952 条缓存上要 **9~10 秒**,连跑两轮第二轮 0 条改动 —— 纯无用功。
//
// 而引擎重启得很频繁(App 重建、「歌词管理」改完 kickstart、崩溃拉起),每次都要付这
// 一笔。用户侧的现象是"刚重启那阵子歌词要等一两分钟才出来":实测一次冷启动从 SIGTERM 到歌词
// 出现 106 秒,其中 **47 秒**花在打出 "starting" 之前 —— 那段时间进程活着、却一行日志都没有,
// 排查时完全是黑盒(所以顺带给那一段加了分步计时,见 main.go)。
//
// 水位按**迁移名 + 版本号**记。改了那道迁移的算法就把版本号 +1,存量会被重扫一遍。
//
// 只有同时满足这两条的迁移才配用它:
//
//  1. **幂等** —— 对同一份数据重复跑结果不变;否则"跳过"就不是省时间,是改行为。
//  2. **运行期已在源头做了同样的事** —— 否则新写进来的数据会被永远跳过。
//     反例:migrateYRCWhitespaceTokens 看着像一次性存量清洗(它的头注也这么写),实测却每次
//     启动都还能捞到十来条新的(源头 richsyncToYRC 的归并没盖全),它就**不能**加水位闸。
//     好在它只要 0.5 秒,不加也无所谓 —— 把闸留给真正贵的那道。
//
// 引入外来数据的两个入口在 main.go 里都排在这些迁移**之前**,顺序天然成立。adoptEnrichRestore(配置搬家,
// 别的机器导出的决策数据)进来的是一整批,作废全部水位,这一轮照常全量跑;importLyricsFromFiles(用户手改
// lyrics/ 里的文件)只改写了那几条,已经跑过的迁移这一轮只补扫它们,见 recheckMigrationsFor。
//
// 路径没设时(各 CLI 子命令就不设)migrationDone 恒为 false、markMigrationDone 与 recheckMigrationsFor
// 是空操作,行为与加这层之前逐字节一致 —— 水位是常驻进程的启动优化,不是语义的一部分。
//
// 那么 CLI 子命令改完缓存、常驻进程带着旧水位重启,会不会漏掉该做的迁移?search-lyrics 手动选定写的是
// manual_lyrics,那类条目这道迁移本来就整条跳过。
// 将来若有 CLI 会改 Lyrics / LyricsYRC 本身,它得自己调 invalidateMigrationState ——
// 这条判断是**按当下这几个子命令的行为**下的,不是这套机制自带的保证。
var (
	migrationStateMu   sync.Mutex
	migrationStatePath string
	migrationState     map[string]int
	// 见 recheckMigrationsFor:补扫开始前的那份水位(磁盘上已经作废,内存里留着),和这一轮要补扫的条目。
	migrationRecheck     map[string]int
	migrationRecheckKeys []string
)

const (
	// migrationLyricTimelines:migrateLyricTimelines 的水位名。
	migrationLyricTimelines = "lyric_timelines"
	// migrationLyricTimelinesVersion:改了 rehangLRCOnYRC / wordTimingContradictsLRC 的
	// 判据就 +1 —— 存量会被重扫一遍,否则老数据永远停在旧算法的结果上。
	migrationLyricTimelinesVersion = 1

	// migrationQRCLeftoverTokens:修 qrcToYRC 旧实现漏转的残缺两数字词条(qrcleftovertokens.go)。
	// 源头已改成按标记位置切分,不会再产生,所以是真正一次性的。
	// v2:修不动的(还剩两数字词条的)清掉逐字、交给扫库 / 重评重新取,见 qrcleftovertokens.go。
	migrationQRCLeftoverTokens        = "qrc_leftover_tokens"
	migrationQRCLeftoverTokensVersion = 2
	// migrationKRCNegativeOffsets:修 krcToYRC 旧实现漏转的负偏移逐字标记(krcnegativeoffsets.go)。源头已经认负号,
	// 不会再产生,所以是一次性的。
	migrationKRCNegativeOffsets        = "krc_negative_offsets"
	migrationKRCNegativeOffsetsVersion = 1

	// migrationYRCWhitespace:纯空白词条归并(yrcwhitespace.go)。
	// 它是在 qrcToYRC / krcToYRC 两个出口都补上源头归并**之后**才够格加水位闸的 ——
	// 在那之前每解析一首新歌就又产生一批,这道"迁移"跑了 39 次也收敛不了(日志实测:
	// 最近两次只隔 22 分钟、分别修 14 条和 13 条)。加闸前先确认源头还在做这件事。
	migrationYRCWhitespace        = "yrc_whitespace"
	migrationYRCWhitespaceVersion = 1
	// migrationHokkienSongLanguage:存量台语歌补记 SongLanguage、清掉普通话拼音(hokkien.go)。
	// 改了 lyricsLookHokkien 的判据就 +1。
	migrationHokkienSongLanguage        = "hokkien_song_language"
	migrationHokkienSongLanguageVersion = 2
	// migrationNeteaseCoverURLs:存量网易云封面 `?param=WxH` 换成 neteaseCoverQuery(netease.go)。
	// 改 neteaseCoverQuery 的写法就 +1。
	migrationNeteaseCoverURLs        = "netease_cover_urls"
	migrationNeteaseCoverURLsVersion = 1
	// migrationLyricEntities:存量歌词正文的字符实体解一层(lyricentities.go)。新抓取的在 rank 那道门口解,
	// 运行期不再产生;没有水位的话每次启动都再解一层,`&amp;amp;apos;` 两次启动就变成 `'`,正文每变一次
	// App 按内容指纹存的单曲偏移就失效一次。
	migrationLyricEntities        = "lyric_entities"
	migrationLyricEntitiesVersion = 1
	// migrationLyricLineEndings:存量歌词的换行统一成 LF、去掉开头的 BOM(lyriclineendings.go)。新抓取的在 rank
	// 那道门口统一,运行期不再产生;lyrics/ 文件夹导入进来的外来数据只在改写过的那几条上补扫一遍。
	migrationLyricLineEndings        = "lyric_line_endings"
	migrationLyricLineEndingsVersion = 1
	// migrationUntranslatedMachineLines:存量机翻里外文原样没动的行(untranslatedmachine.go)。新翻出来的在各级出口
	// 就不收,运行期不再产生。改了 lineTranslated 的判据就 +1。
	migrationUntranslatedMachineLines        = "untranslated_machine_lines"
	migrationUntranslatedMachineLinesVersion = 1
	// migrationUnneededMachineLines:存量机翻里现在不会再送翻的行(untranslatedmachine.go dropUnneededLines)。新翻的在
	// 送翻选行就不收,运行期不再产生。改了送翻选行(selectTranslationWork 和它用的判据)就 +1。
	// v2:从只看文字系统改成整套送翻选行,抬头、署名、拟声词、唱名也算。
	migrationUnneededMachineLines        = "unneeded_machine_lines"
	migrationUnneededMachineLinesVersion = 2
	// migrationLegacyKoreanRoma:存量里早先预生成的韩文罗马音(ICU 逐字母转写)换成按读音的(koreanroma.go)。
	// 运行期新生成的已经是按读音的,运行期不再产生。改了「是不是旧版」的判据就 +1。
	migrationLegacyKoreanRoma        = "legacy_korean_roma"
	migrationLegacyKoreanRomaVersion = 1
	// migrationTonelessCantoneseRoma:存量粤语歌里没标声调的罗马音换成带声调的粤拼(jyutping.go)。运行期在源头
	// 已经这样做,不再产生。改了 lacksJyutpingTones 的判据就 +1。
	migrationTonelessCantoneseRoma        = "toneless_cantonese_roma"
	migrationTonelessCantoneseRomaVersion = 1
	// migrationKuwoSharedStampTranslation:存量酷我正文里挂在下一句时间戳上的烘入译文行(bakedtranslation.go)。
	// 新抓的在候选装配处就摘,运行期不再产生。改了 splitSharedStampTranslation 的判据就 +1。
	migrationKuwoSharedStampTranslation        = "kuwo_shared_stamp_translation"
	migrationKuwoSharedStampTranslationVersion = 1
	// migrationInstrumentalPlaceholder:存量里正文只有纯音乐占位和署名的条目标上纯音乐(instrumentalplaceholder.go)。
	// 新解析的在打分时判废(isCreditOnlyLRC),运行期不再产生。改了 isInstrumentalPlaceholderLyric 的判据就 +1。
	migrationInstrumentalPlaceholder        = "instrumental_placeholder"
	migrationInstrumentalPlaceholderVersion = 1
)

// loadMigrationState 读水位文件。文件不存在 / 解不出来都当作"一道都没跑过",照常全量跑 ——
// 这一层最坏的失效方式必须是"多跑一遍",不能是"少跑一遍"。
func loadMigrationState(path string) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	migrationStatePath = path
	migrationState = map[string]int{}
	migrationRecheck, migrationRecheckKeys = nil, nil
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var got map[string]int
	if err := json.Unmarshal(data, &got); err != nil {
		log.Printf("migration state: %s unreadable (%v), re-running every startup migration", path, err)
		return
	}
	migrationState = got
}

// migrationDone:这道迁移的这个版本跑过了吗。
func migrationDone(name string, version int) bool {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath == "" {
		return false
	}
	return migrationState[name] >= version
}

// migrationScope:一道带水位的迁移这一轮要扫多大范围。迁移用它代替直接问 migrationDone。
type migrationScope struct {
	all  bool     // 水位没到:全库
	keys []string // 水位到了,但这几条这一轮被 lyrics/ 文件夹改写过:只补扫它们
}

// migrationScopeOf:水位到了、没有要补扫的 → 整道跳过;水位到了、有要补扫的 → 只扫那几条;
// 水位没到(没跑过、改了算法升了版本号、整体作废了)→ 全库。
func migrationScopeOf(name string, version int) migrationScope {
	if migrationDone(name, version) {
		return migrationScope{}
	}
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath != "" && migrationRecheck[name] >= version {
		return migrationScope{keys: migrationRecheckKeys}
	}
	return migrationScope{all: true}
}

// skip:这一轮整道跳过。
func (s migrationScope) skip() bool { return !s.all && len(s.keys) == 0 }

// entries:要扫的条目。全库时就是 enrichCache 本身;补扫时是那几条的拷贝(已经不在缓存里的不算),改动照旧
// 写回 enrichCache[k]。调用方持 enrichMu。
func (s migrationScope) entries() map[string]enrichEntry {
	if s.all {
		return enrichCache
	}
	sub := make(map[string]enrichEntry, len(s.keys))
	for _, k := range s.keys {
		if e, ok := enrichCache[k]; ok {
			sub[k] = e
		}
	}
	return sub
}

// markMigrationDone 记下水位并立刻落盘 —— 落盘失败只记一行日志:代价是下次启动多跑一遍,
// 不值得让它影响启动流程。
func markMigrationDone(name string, version int) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath == "" {
		return
	}
	if migrationState == nil {
		migrationState = map[string]int{}
	}
	if migrationState[name] == version {
		return
	}
	migrationState[name] = version
	saveMigrationStateLocked()
}

// recheckMigrationsFor:外来数据只进了这几条(lyrics/ 文件夹改写了它们)。已经跑过的迁移这一轮不全库重扫、
// 只补扫这几条 —— 其余条目还是上次跑完时的形态。为一个手改的文件把全库再扫一遍,实测近一万条缓存要十几秒
// (机器忙时三十多秒),而这一段跑完之前引擎还没开始盯播放(见 main.go)。水位没到的迁移照常全量跑。
//
// 磁盘上的水位跟 invalidateMigrationState 一样当场作废,内存里那份挪进 migrationRecheck;每道迁移补扫完,
// 由它自己的 markMigrationDone 写回去。补扫到一半进程被杀,下次启动读到的是作废的水位、全量跑 —— 这一层
// 最坏的失效方式仍然只是多跑一遍。
func recheckMigrationsFor(keys []string, why string) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath == "" || len(keys) == 0 || len(migrationState)+len(migrationRecheck) == 0 {
		return
	}
	log.Printf("migration state: %s — startup migrations that already ran re-check only those entries this round", why)
	if migrationRecheck == nil {
		migrationRecheck = map[string]int{}
	}
	for name, v := range migrationState {
		migrationRecheck[name] = max(migrationRecheck[name], v)
	}
	migrationRecheckKeys = append(migrationRecheckKeys, keys...)
	migrationState = map[string]int{}
	saveMigrationStateLocked()
}

// invalidateMigrationState 作废全部水位:有外来数据进了缓存,这一轮的存量迁移必须照常跑。
func invalidateMigrationState(why string) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	// 补扫一并作废,全量跑已经包含那几条。要排在下面的早退之前:补扫期间内存里的水位是空的。
	migrationRecheck, migrationRecheckKeys = nil, nil
	if migrationStatePath == "" || len(migrationState) == 0 {
		return
	}
	log.Printf("migration state: cleared (%s) — startup migrations will run in full this round", why)
	migrationState = map[string]int{}
	saveMigrationStateLocked()
}

func saveMigrationStateLocked() {
	data, err := json.Marshal(migrationState)
	if err != nil {
		return
	}
	if err := os.WriteFile(migrationStatePath, data, 0o644); err != nil {
		warnf("migration state: save failed (%v) — next startup will re-run the migrations", err)
	}
}
