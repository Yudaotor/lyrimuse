package main

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
)

// learnedSourceArtistAlias 从本机 enrich 缓存里学"这个歌手在**歌词源那边**署什么名",
// 给 retryArtistIdentities 当一条纯本地、离线、零请求的别名来源(2026-09-09)。
//
// # 起因
//
// 用户报王子《1999 (Edit)》搜不到歌词。「王子」是 Prince 的中文译名 —— YouTube Music
// 这类播放器会把歌手名本地化,而九个歌词源里这首歌的署名一律是 "Prince"。实测对照:
//
//	王子   + 1999 (Edit)          → 九个源 0 条候选
//	王子   + 1999                 → 4 个源命中,但 kugou 只有 462 分
//	Prince + 1999 (Edit)          → 5 个源命中,kugou 1122 分(同一条候选,差 660 分)
//	王子   + Little Red Corvette  → 0 条候选(说明不是这一首特有)
//
// retryArtistIdentities 本来就有三条别名来源(MusicBrainz 中文名 / MB 全部登记写法 /
// QQ 歌手搜索建议),但对「王子」三条全部落空 —— MB 上 Prince 没登记这个中文别名,而
// 「王子」两个字太泛,QQ 那条也指不到他。
//
// 可这台机器上**答案本来就有**:同一个「王子」的另外两首歌
// (`王子|The Guilty Ones|`、`王子|Why You Wanna Treat Me So Bad?|`)早就解析成功过,
// 它们采纳的那条候选里源侧署名写得清清楚楚就是 "Prince"。这是本机真实验证过的映射,
// 比任何在线目录都可靠,而且不用发一个请求 —— 缺的只是"跨歌去看一眼"这一步:既有的
// lyricResolvedArtists(albumhint.go)只读**这首歌自己**那条,而搜不到歌词的歌恰恰
// 自己没有条目,于是形成自锁:要有条目才拿得到规范名,要有规范名才搜得到、才写得出条目。
//
// # 为什么只认"胜出候选的署名",不认 CanonicalArtist
//
// 这一档要回答的问题是"**拿什么字符串去搜歌词源**",所以证据必须是源自己吐出来的署名 ——
// 即 LyricsDecisionApplied 里胜出那条候选的 Artist。CanonicalArtist 回答的是另一个问题
// ("显示时统一用哪个写法"),而且它刻意偏中文(见 enrichEntry.CanonicalArtist 头注:
// "David Tao/陶喆 统一成 陶喆"、"能识别就用中文名"),拿它去搜英文源是南辕北辙;更糟的是
// 它会污染下面那道一致性判据 —— 同一歌手有的条目给 "Prince"、有的给「王子」,normLoose
// 之后不唯一,本来学得到的映射反而被判成歧义而放弃。**落选候选的 artist 同样不认**
// (网易云仿冒号那类会把错名带进来)。
//
// # 判据从严:宁可学不到,不可学错
//
// 学错的代价是把**别的歌手**的歌词配到这首歌上,比"搜不到"糟得多。所以:
//
//   - 同一歌手名下所有成功条目给出的署名,normLoose 之后必须**唯一**才用。「王子」既是
//     Prince 又是邱胜翊的用户,这里一律不猜。
//   - 跟本地标签自身相同的不算别名(它不提供任何新信息;retryArtistIdentities 的 add()
//     也会去重,这里提前挡掉只是省事)。
//   - 一致时返回原始写法里**字典序最小**的那个 —— Go 的 map 迭代顺序随机,不定序的话
//     "Prince" 和 "PRINCE" 这种同一 normLoose 的两种写法会每次启动学到不同的一个,
//     表现为"同一首歌有时搜得到有时搜不到"且复现不出来(09-07 在 siblingCoverLocked
//     踩过同一个坑,见 enrich.go 那边的注释)。
//
// # 已知边界
//
// 按 key 的歌手段**精确前缀**匹配,所以多人合credit 的本地标签("A & B")学不到 ——
// 调用方传进来的是 lyricPrimaryQueryArtist 截出的首歌手,跟完整标签对不上。放宽成包含
// 匹配会误伤(「王子」会命中「小王子」),不做。这一类由既有的首歌手变体轮自己处理。
//
// ⚠️ 自己取 enrichMu,**必须在不持有该锁时调用**(不可重入;09-07 那次 poll 循环冻死
// 11 分钟就是持锁期间又加锁来的)。当前唯一调用方 retryArtistIdentities 在兜底轮里跑,
// 那条链路上不持锁。全表扫描 4000+ 条只做字符串前缀比较,而且只有"前面几轮都没搜到"
// 时才会走到这里,不是热路径。
func learnedSourceArtistAlias(artist string) string {
	prefix := cleanMediaTag(artist)
	if prefix == "" {
		return ""
	}
	prefix += "|"
	self := normLoose(artist)

	enrichMu.Lock()
	var names []string
	distinct := map[string]bool{}
	for k, e := range enrichCache {
		if !strings.HasPrefix(k, prefix) {
			continue
		}
		name := winningCandidateArtist(e)
		if name == "" || normLoose(name) == self {
			continue
		}
		names = append(names, name)
		distinct[normLoose(name)] = true
	}
	enrichMu.Unlock()

	if len(distinct) != 1 {
		return "" // 一个都没学到,或者同一歌手指向两个不同的人 —— 都不猜
	}
	sort.Strings(names)
	return names[0]
}

// winningCandidateArtist 取"这条歌词最终采纳的那个候选,源那边把歌手署成什么名"。
// 跟 lyricResolvedArtists(albumhint.go)取的是同一份证据的同一个字段路径,只是那边
// 还额外要 CanonicalArtist、这边刻意不要(理由见 learnedSourceArtistAlias 头注)。
func winningCandidateArtist(e enrichEntry) string {
	d := e.LyricsDecisionApplied
	if d == nil || d.Winner == "" {
		return ""
	}
	for _, c := range d.Candidates {
		if c.Source == d.Winner {
			return strings.TrimSpace(c.Artist)
		}
	}
	return ""
}

// loadEnrichCacheReadOnly 把 enrich 缓存读进内存供**一次性子命令**查询
// (`collector search-lyrics`,即「联网搜索候选歌词」弹窗),2026-09-09 随
// learnedSourceArtistAlias 一起加 —— 那一档的全部证据就在这份缓存里,子进程不读它
// 这一档就恒为空,而"播放器把歌手名本地化了"恰恰是用户最会跑来手动搜一把的场景。
//
// # 刻意不复用 loadEnrichCache
//
// 那个是常驻 collector 的启动路径,带两个对子进程有害的副作用:
//
//  1. 它会 `enrichPath = path`。设了之后,进程里任何一处 saveEnrichCache 都会真的写盘 ——
//     子进程绝不该跟常驻实例抢写这份文件。saveEnrichCache 对空 enrichPath 直接 return,
//     所以**不设就是结构性安全**,不必依赖"我检查过这条链路上没有写入"这种一次性结论
//     (今天成立,明天有人在搜索链路里加一处 commit 就不成立了)。
//  2. 解析不动时它会 `os.Rename` 把原文件挪成 `.corrupt`。对常驻进程这是对的(否则整份
//     缓存再也写不进去);对一个只想查个歌手别名的子进程却是灾难 —— 万一撞上常驻实例
//     正在写、读到半截,用户几十 MB 的歌词缓存就被搬走了。这里读不出来就当没有,
//     少一档别名而已,绝不动用户的文件。
//
// 因此这里只做"读 + 解 + 塞进内存",一个错误分支都不额外处理。
func loadEnrichCacheReadOnly(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]enrichEntry
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		return
	}
	enrichMu.Lock()
	enrichCache = m
	enrichMu.Unlock()
}
