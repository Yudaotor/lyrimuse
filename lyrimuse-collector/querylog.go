package main

import (
	"context"
	"slices"
	"sync"
)

// 一轮歌词解析**实际问出去的查询词**的记录(借鉴清单 V1,2026-09-12)。
//
// 背景:决策存档 lyricsDecision 里原本只有**一组** query_artist/query_title/query_album ——
// 就是首轮那一组。而 scoredLyricCandidatesStreaming 一轮下来最多会换五种问法:
//   ①首轮(本地标签)                                  ②「署名 - 曲名」拆分重入(决策 53)
//   ③别名轮(五级来源,且只查缺着的那几个源)             ④首歌手变体轮(合credit 截首位)
//   ⑤标题反查轮(title-from-album / -from-artist-search)
// 这些痕迹此前**只有胜者恰好来自反查轮时**才靠 retry_method/corrected_title 留下一点。
// 实测本机全库 4390 条存档:retry_method 非空只有 9 条(0.2%),query_artist 与缓存 key 里
// 歌手写法不同的 212 条(4.8%)—— 也就是说"我到底拿哪些词、问了哪几个源"基本不可见。
//
// 而 09 章里五条真实的"搜不到 / 配错了",根因**全部**是问错了词:决策 45(YouTube Music 把
// 艺人名本地化成中文)、决策 53(搬运频道把歌手写在曲名里)、王灏儿=JW、异体字那条、
// 打上花火被反查成《春雷》。每一条当时都只能靠翻 collector 日志或本地复现来定位。
// 决策 45/53 那两次的排查笔记里写得很直白:"存档里只有 winner/candidates 时,想知道
// 库里还有多少条是这么来的完全无从下手"—— retry_method 就是为此加的,这里只是把同一个
// 思路从"胜者那一条的来路"推广到"整轮的提问记录"。
//
// ⚠️ 与 lyricsDecision 的三条铁律一致:**只写不读** —— 解析逻辑的任何分支都不许拿它当
// 输入。它也不参与打分,所以不需要 bump lyricsScoringVersion。
//
// 走 ctx 而不是改函数签名,理由同 lyricSourceRound(sourcebreaker.go):
// fetchScoredLyricCandidatesStreaming 的签名被 searchcli.go / 自动解析两条路径共用,
// 为一个纯记录字段把参数从 6 个串到 4 层深处不值得。没挂收集器时(单测、老调用点)
// record 是空操作,行为逐字节不变。

// lyricQueryReason* 是一条查询记录的来路。空字符串 = 首轮(按本地标签直接问)。
// ⚠️ 新增一条**必须同时**在 App 侧 LyricsDecisionSheet.queryReasonLabel 那个 switch 里补
// 中文译名 —— 那边 default 是"原样显示原始值",漏了就是界面上直接印一个英文串给用户看
// (2026-08-21 决策路径译名就这么漏过一次)。lyricQueryReasons 那个测试守着这份清单。
const (
	lyricQueryReasonPrimary      = ""                         // 首轮:本地标签原样
	lyricQueryReasonTitleSplit   = "title-split"              // 「署名 - 曲名」拆分重入
	lyricQueryReasonAliasRescue  = "alias-rescue"             // 别名轮:一个可用候选都没有
	lyricQueryReasonAliasRoma    = "alias-roma"               // 别名轮:缺罗马音/语种信号
	lyricQueryReasonAliasMissing = "alias-missing"            // 别名轮:某几个源没给出候选
	lyricQueryReasonPrimaryVar   = "primary-artist-variant"   // 合credit 截首位歌手
	lyricQueryReasonTitleAlbum   = "title-from-album"         // 标题反查:浏览专辑曲目表
	lyricQueryReasonTitleSearch  = "title-from-artist-search" // 标题反查:歌手泛搜
	// 标题反查:Apple 原产地商店的规范曲名(2026-09-12)。前两条都拿**本地标题**当输入,
	// 本地标题本身是罗马字/被本地化过的时候它们结构上就够不到,见 appleStorefrontCanonicalTitle。
	lyricQueryReasonTitleStorefront = "title-from-apple-storefront"
)

// lyricQueryReasons 是上面那八条(不含首轮的空串)的清单,给测试用。
func lyricQueryReasons() []string {
	return []string{
		lyricQueryReasonTitleSplit,
		lyricQueryReasonAliasRescue,
		lyricQueryReasonAliasRoma,
		lyricQueryReasonAliasMissing,
		lyricQueryReasonPrimaryVar,
		lyricQueryReasonTitleAlbum,
		lyricQueryReasonTitleSearch,
		lyricQueryReasonTitleStorefront,
	}
}

// lyricQueryLogMax:一条存档最多留多少组查询词。正常一轮在 10 组以内(首轮 1 + 拆分 1 +
// 别名最多 4 + 变体最多 3 + 反查 1),这个上限纯粹是防"别名表异常膨胀"把存档撑大 ——
// 存档的第一条铁律是只存元数据,一条候选才 200~400 字节,查询记录不该比它还重。
// 超出后**丢弃后来的**而不是滚动覆盖:前几组才是回答"首轮问的对不对"的关键。
const lyricQueryLogMax = 24

// lyricQueryRecord:一组真正发出去的查询词,以及这一组只问了哪几个源。
type lyricQueryRecord struct {
	Artist string `json:"artist"`
	Title  string `json:"title,omitempty"`
	// Reason:这一组是哪一轮问的,取值见上面 lyricQueryReason* 常量;空 = 首轮。
	Reason string `json:"reason,omitempty"`
	// Sources:这一轮**只**问了这几个源(别名轮的 withLyricSourceOnly 定向重查)。
	// 空 = 没有限制,问的是当时所有启用且不在冷却里的源。
	Sources []string `json:"sources,omitempty"`
}

type lyricQueryLog struct {
	mu      sync.Mutex
	records []lyricQueryRecord
}

type lyricQueryLogKey struct{}
type lyricQueryReasonKey struct{}

// withLyricQueryLog 挂一个收集器到 ctx 上。三处写缓存点 + 手动搜索 CLI 各自挂一个,
// 跟 withLyricSourceRound 同一个位置、同一个生命周期(一轮解析)。
func withLyricQueryLog(ctx context.Context) (context.Context, *lyricQueryLog) {
	l := &lyricQueryLog{}
	return context.WithValue(ctx, lyricQueryLogKey{}, l), l
}

func lyricQueryLogFrom(ctx context.Context) *lyricQueryLog {
	if ctx == nil {
		return nil
	}
	l, _ := ctx.Value(lyricQueryLogKey{}).(*lyricQueryLog)
	return l
}

// withLyricQueryReason 给"接下来这一次抓取"标注来路。每个重试轮的调用点各自显式设一次;
// 内层继承外层的值(拆分重入那一轮内部再跑别名轮时,别名轮会自己覆盖成 alias-*)。
func withLyricQueryReason(ctx context.Context, reason string) context.Context {
	return context.WithValue(ctx, lyricQueryReasonKey{}, reason)
}

func lyricQueryReasonFrom(ctx context.Context) string {
	if ctx == nil {
		return lyricQueryReasonPrimary
	}
	r, _ := ctx.Value(lyricQueryReasonKey{}).(string)
	return r
}

// record 由 fetchScoredLyricCandidatesStreaming 在入口调一次 —— 那里是**所有**轮次唯一的
// 实际发起点(首轮 / 拆分重入 / 别名轮 / 变体轮 / 反查轮全都经过它),所以不会漏记,
// 也不用在五个调用点各写一遍。sources 会拷一份:调用方传进来的是 ctx 上那个共享名单。
func (l *lyricQueryLog) record(artist, title, reason string, sources []string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.records) >= lyricQueryLogMax {
		return
	}
	rec := lyricQueryRecord{Artist: artist, Title: title, Reason: reason}
	if len(sources) > 0 {
		rec.Sources = append([]string(nil), sources...)
	}
	// 同一组(词 + 来路 + 源名单)问两遍是没有意义的记录 —— 变体轮里"首歌手"和
	// retryArtistIdentities 给出的第一个别名可能恰好相同,dedupeArtistIdentities 管不到
	// 跨轮的重复。相邻去重就够,不必全表扫。
	if n := len(l.records); n > 0 && sameLyricQueryRecord(l.records[n-1], rec) {
		return
	}
	l.records = append(l.records, rec)
}

func sameLyricQueryRecord(a, b lyricQueryRecord) bool {
	if a.Artist != b.Artist || a.Title != b.Title || a.Reason != b.Reason || len(a.Sources) != len(b.Sources) {
		return false
	}
	for i := range a.Sources {
		if a.Sources[i] != b.Sources[i] {
			return false
		}
	}
	return true
}

// queries 返回这一轮记下的全部查询词(拷贝,调用方可以随便改)。
func (l *lyricQueryLog) queries() []lyricQueryRecord {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.records) == 0 {
		return nil
	}
	return append([]lyricQueryRecord(nil), l.records...)
}

// sortedLyricSourceOnly 把 ctx 上那份"只查这几个源"的名单(withLyricSourceOnly 挂的
// map[string]bool)摊成**定序**切片。必须定序:map 迭代顺序是随机的,直接落进决策存档
// 会让同一轮解析每次序列化出不同的 JSON —— 存档是给人逐条比对用的,顺序抖动等于噪音。
// 排序基准用 lyricSourceNames(源的规范顺序,跟"歌词来源"设置项、候选构造顺序同一份),
// 不用字典序 —— 界面上列出来的顺序应当跟别处一致。
func sortedLyricSourceOnly(ctx context.Context) []string {
	only := lyricSourceOnlyFrom(ctx)
	if len(only) == 0 {
		return nil
	}
	out := make([]string, 0, len(only))
	for _, s := range lyricSourceNames {
		if only[s] {
			out = append(out, s)
		}
	}
	// 名单里出现了 lyricSourceNames 之外的名字(理论上不会,但别静默丢掉证据)。
	for s := range only {
		if !slices.Contains(lyricSourceNames, s) {
			out = append(out, s)
		}
	}
	return out
}
