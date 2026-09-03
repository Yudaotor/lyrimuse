// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// 2026-07-30:canonical_artist 原来完全靠 resolveTrackEnrichment 里"按这一首曲目去
// 网易云/QQ 搜、用搜索结果自带的歌手名"这条路径——问题是这是按曲目独立匹配的,同一个
// 歌手的不同曲目可能各自匹配成功或失败(实测坐实:卢广仲《100種生活》专辑 6 首歌,
// 5 首通过网易云匹配成功统一成了"卢广仲",唯独"无敌铁金刚"这一首匹配失败,原始标签
// "Crowd Lu"就漏网了)。MusicBrainz 是按"这个人是谁"直接查、不依赖某一首具体曲目搜不
// 搜得到,能从根上解决"同一歌手的曲目各自独立匹配、有成有败"这个问题——这里作为
// canonical_artist 解析链路第一个被咨询的来源,查到就直接用;查不到/没有把握,原有的
// 网易云/QQ 按曲目匹配、以及最后手工登记的 artistAliasTable,依次接棒兜底,不会因为
// MusicBrainz 覆盖不到某个冷门歌手就比现状更差。

// artistAliasCache 是"原始歌手标签(本地播放器给的标签,英文/罗马化)→ MusicBrainz 查到
// 的中文别名"的持久化缓存,按歌手整体缓存,不按曲目——同一个歌手不管有多少首歌,只需要
// 成功查一次 MusicBrainz 就够了。空字符串是内存里的合法值,代表"这次查了,没有可用的
// 中文别名",避免同一进程内对同一个歌手反复重新查询。
//
// ⚠️ 2026-08-30 订正:空字符串**不再落盘持久化**。原设计(查一次永久生效,查空也当成
// "确认没有"写进文件)在 mbPrimaryNameCache 加的时候就已经指出过风险(见那边的头注),
// 当时没有回头改这份更老的缓存——这次真的撞上了:那英《微笑着离去》本地标签罗马化成
// "Na Ying",查询当口 MusicBrainz 恰好限速返回 503,lookupMusicBrainzChineseAlias 拿到
// 的是"这次没查到"而不是"这个人真的没有中文别名",却被原样当成确定结果永久写进了
// lyrimuse-artist-alias-cache.json,之后不管 MusicBrainz 是否恢复,这个歌手都被钉死在
// "没有别名"上,只能手动删缓存文件里的 key 才能重查。现在跟 mbPrimaryNameCache 用同一条
// 规则:只有查到非空结果才落盘,查空的只留在内存里(同一进程内不重复打这次请求,但下一次
// 进程启动/重跑会有机会用一次新的 MusicBrainz 请求重新确认)。
var (
	artistAliasMu    sync.Mutex
	artistAliasCache = map[string]string{}
	artistAliasPath  string // 落盘路径；空则只用内存不持久化
	artistAliasDirty bool
)

// loadArtistAliasCache/saveArtistAliasCache 跟 loadEnrichCache/saveEnrichCache
// (enrich.go)同一套持久化模式(整份 map 序列化、临时文件+原子改名落盘),只是这份缓存
// 小得多——只有"曾经查过 MusicBrainz 的原始歌手标签"这一个维度,不是按曲目,数据量级
// 是"不同歌手数"而不是"不同曲目数"。
func loadArtistAliasCache(path string) {
	artistAliasPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		artistAliasMu.Lock()
		artistAliasCache = m
		artistAliasMu.Unlock()
		log.Printf("loaded %d cached artist aliases from %s", len(m), path)
	}
}

func saveArtistAliasCache() {
	artistAliasMu.Lock()
	if !artistAliasDirty || artistAliasPath == "" {
		artistAliasMu.Unlock()
		return
	}
	// 只序列化非空值 —— 见上面那段 ⚠️,空值不该把一次偶发的 MusicBrainz 限速/失败
	// 永久钉死成"确认没有别名"。
	keep := make(map[string]string, len(artistAliasCache))
	for k, v := range artistAliasCache {
		if v != "" {
			keep[k] = v
		}
	}
	data, err := json.Marshal(keep)
	artistAliasDirty = false
	artistAliasMu.Unlock()
	if err != nil {
		return
	}
	tmp := artistAliasPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, artistAliasPath); err != nil {
		log.Printf("save artist alias cache: %v", err)
	}
}

// musicbrainzMinIntervalBetweenCalls 是 MusicBrainz 官方对匿名调用方的礼貌限速建议
// (约 1 请求/秒,见 https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)——这个
// 查询极少发生(只在第一次见到一个原始标签不含中文字符、且这个标签之前没查过的歌手时
// 才会触发一次,查过之后不管成不成功都永久缓存,不会重复查),用一把全局互斥锁串行化+
// 必要时 sleep 补足间隔就够了,不需要更复杂的令牌桶实现。
const musicbrainzMinIntervalBetweenCalls = 1100 * time.Millisecond

var (
	musicbrainzRateMu   sync.Mutex
	musicbrainzLastCall time.Time
)

// musicbrainzThrottle 现在接受 ctx——排队等待限速间隔时,一旦 ctx 被取消(用户手动取消
// 了这次"searching"占位)就提前中止等待、把 ctx.Err() 报给调用方,不再傻等满整个间隔。
// 没等到间隔到期就返回时不去更新 musicbrainzLastCall,因为这次调用不会真的发请求出去,
// 不占用这个限速名额。
func musicbrainzThrottle(ctx context.Context) error {
	musicbrainzRateMu.Lock()
	defer musicbrainzRateMu.Unlock()
	if wait := musicbrainzMinIntervalBetweenCalls - time.Since(musicbrainzLastCall); wait > 0 {
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	musicbrainzLastCall = time.Now()
	return nil
}

// canonicalArtistViaMusicBrainz 是 canonical_artist 解析链路里第一个被咨询的来源,
// 供 resolveTrackEnrichment(enrich.go)调用。只对"原始标签本身不含中文"的歌手生效
// (containsHan 判断,复用 match.go 的 cjkRatio)——已经是中文标签的没有"中英文两套
// 写法"这个问题需要解决,不必白白消耗 MusicBrainz 的请求额度。
// artistCanonicalCacheOnly:为真时 canonicalArtistViaMusicBrainz / cachedQQArtistCanonicalName
// 只读缓存、绝不联网(查不到就当没有,也不往缓存写空值)。给 `collector top-artists`(App 统计页
// 背后那条 CLI)的默认档用——2026-09-03 实测:artistMergeNameKey 2026-08-31 起走
// resolveGenericArtistCanonicalName,而 CLI 进程既没加载别名缓存、又对 4 个时段 × 30 条里每个
// 非中文歌手名都真查 MusicBrainz(全局 1.1 s 限速)+ QQ,一次跑 1 分 49 秒,App 侧 25 s 看门狗必然
// 把它杀掉 → 歌手榜永远是"加载失败"。CLI 的 -mb-budget 0 本来就承诺"只读缓存不联网、毫秒级",
// 这里让 canonical 名那一步也遵守同一个承诺;归并仍有 mbid 身份缓存 + 名字键两路信号。
var artistCanonicalCacheOnly bool

func canonicalArtistViaMusicBrainz(ctx context.Context, rawArtist string) string {
	rawArtist = strings.TrimSpace(rawArtist)
	if rawArtist == "" || containsHan(rawArtist) {
		return ""
	}

	artistAliasMu.Lock()
	if v, ok := artistAliasCache[rawArtist]; ok {
		artistAliasMu.Unlock()
		return v
	}
	artistAliasMu.Unlock()
	if artistCanonicalCacheOnly {
		return "" // 见 artistCanonicalCacheOnly:不联网、不写空值
	}

	resolved := lookupMusicBrainzChineseAlias(ctx, rawArtist)

	artistAliasMu.Lock()
	artistAliasCache[rawArtist] = resolved
	// 查空不算脏 —— 空值不落盘,下一次进程还能再试一次(见上面 saveArtistAliasCache 前的
	// ⚠️ 说明)。
	if resolved != "" {
		artistAliasDirty = true
	}
	artistAliasMu.Unlock()
	saveArtistAliasCache()
	return resolved
}

// containsHan 判断字符串是否至少包含一个中日韩表意文字——用来判断"这个歌手的原始
// 标签本身是不是已经是中文",是的话就没有"中英文两套写法需要统一"这个问题。复用
// match.go 的 cjkRatio(对着一个不含 LRC 时间戳的普通歌手名字符串调用它是安全的空操作,
// 时间戳剥离那一步不会匹配到任何内容)。
func containsHan(s string) bool {
	return cjkRatio(s) > 0
}

// ---- 歌手身份缓存(mbid+中文名),给 Top 歌手榜的通用归并用 ----
//
// 跟上面 artistAliasCache(只存中文别名字符串,给 canonical_artist 链路)是两份缓存:
// 归并需要的是**身份**(mbid)——"Leah Dou"和"窦靖童"名字键完全不同、Last.fm 又只给
// 其中一条 mbid,只有把两个名字各自解析到同一个 MusicBrainz 艺人,并查集才连得上
// (2026-08-18 用户核对 Top100 导出,坐实 8 对这类漏合并)。中文名(Zh)顺手一起存:
// 榜单里只有罗马名的中文歌手("Ronghao Li")靠它显示成中文。
//
// 缓存语义与 artistAliasCache 一致:查一次永久生效,零值也是合法缓存("查过,没结果"),
// 想重查只能手动删缓存文件里的 key。
type mbArtistIdentity struct {
	Mbid string `json:"mbid,omitempty"`
	Zh   string `json:"zh,omitempty"`
}

var (
	artistIdentityMu    sync.Mutex
	artistIdentityCache = map[string]mbArtistIdentity{}
	artistIdentityPath  string // 空 = 只用内存不持久化(单测)
	artistIdentityDirty bool
)

func loadArtistIdentityCache(path string) {
	artistIdentityPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]mbArtistIdentity
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		artistIdentityMu.Lock()
		artistIdentityCache = m
		artistIdentityMu.Unlock()
		log.Printf("loaded %d cached artist identities from %s", len(m), path)
	}
}

func saveArtistIdentityCache() {
	artistIdentityMu.Lock()
	if !artistIdentityDirty || artistIdentityPath == "" {
		artistIdentityMu.Unlock()
		return
	}
	data, err := json.Marshal(artistIdentityCache)
	artistIdentityDirty = false
	artistIdentityMu.Unlock()
	if err != nil {
		return
	}
	tmp := artistIdentityPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, artistIdentityPath); err != nil {
		log.Printf("save artist identity cache: %v", err)
	}
}

func cachedArtistIdentity(name string) (mbArtistIdentity, bool) {
	artistIdentityMu.Lock()
	defer artistIdentityMu.Unlock()
	id, ok := artistIdentityCache[name]
	return id, ok
}

// resolveArtistIdentityMB 联网解析一个歌手名的身份并写缓存。knownMbid 非空时(Last.fm
// 已给出 mbid)跳过搜索、只在需要中文名时补一次别名查询;否则先搜(置信度门槛与
// canonical_artist 那条链同一个 musicbrainzMinScore)。中文名只对"名字本身不含汉字"的
// 条目去查——已是中文名的,归并展示直接用它,不必多花一次请求。
// 每次调用最多 2 个 MusicBrainz 请求,受 musicbrainzThrottle 全局限速。
//
// ⚠️ 这个函数由 topartists.go(Top 歌手榜的一次性归并脚本)调用,不在 enrich.go 那条
// "可手动取消的 searching 占位"解析链路上——本次改动的 ctx 只从 canonicalArtistViaMusicBrainz/
// musicBrainzPrimaryArtistName 两个入口往下穿,topartists.go 那边没有、也不需要 ctx 可传,
// 所以这里的签名不变,内部对 musicbrainzThrottle/mbGetJSON 的调用用 context.Background()
// (不可取消,但行为跟改动前完全一致)。
func resolveArtistIdentityMB(name, knownMbid string) mbArtistIdentity {
	name = strings.TrimSpace(name)
	if name == "" {
		return mbArtistIdentity{}
	}
	ctx := context.Background()
	id := mbArtistIdentity{Mbid: knownMbid}
	if id.Mbid == "" {
		if err := musicbrainzThrottle(ctx); err == nil {
			var search mbSearchResponse
			searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(name) + "&fmt=json&limit=5"
			if err := mbGetJSON(ctx, searchURL, &search); err == nil && len(search.Artists) > 0 &&
				search.Artists[0].Score >= musicbrainzMinScore {
				id.Mbid = search.Artists[0].ID
			}
		}
	}
	if id.Mbid != "" && !containsHan(name) {
		if err := musicbrainzThrottle(ctx); err == nil {
			var withAliases mbArtistWithAliases
			aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(id.Mbid) + "?inc=aliases&fmt=json"
			if err := mbGetJSON(ctx, aliasURL, &withAliases); err == nil {
				id.Zh = pickChineseAlias(withAliases.Aliases, withAliases.Country)
			}
		}
	}
	artistIdentityMu.Lock()
	artistIdentityCache[name] = id
	artistIdentityDirty = true
	artistIdentityMu.Unlock()
	return id
}

// mbSearchResponse/mbArtistWithAliases 只取用得到的字段,完整字段列表见 MusicBrainz
// API 文档(https://musicbrainz.org/doc/MusicBrainz_API)。
type mbSearchResponse struct {
	Artists []struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Score int    `json:"score"`
	} `json:"artists"`
}

type mbAlias struct {
	Name   string `json:"name"`
	Locale string `json:"locale"`
	// Type 用来挡"不是艺名"的别名(2026-08-18):MusicBrainz 给艺名歌手也登记
	// 中文**法定名**(实测 ØZI 有一条 type="Legal name" 的「陳奕凡」),拿它当显示名
	// 等于把艺人改叫回身份证名。只拒绝确定不该用的类型(Legal name/Search hint),
	// 不做"只收 Artist name"的白名单——真实数据里 type 可能缺失(卢广仲那条连 locale
	// 都没有),白名单会把这类合法别名一并误杀。
	Type string `json:"type"`
}

type mbArtistWithAliases struct {
	// Country 是这次收紧判定的关键字段(2026-08-05 加,见 pickChineseAlias 注释)。
	Country string `json:"country"`
	// Name 是这位歌手在 MusicBrainz 上的**主名**(艺人页标题那个)。2026-08-20 加,
	// 给 musicBrainzPrimaryArtistName 用 —— 本名/艺名互换那一类问题要的正是它。
	Name    string    `json:"name"`
	Aliases []mbAlias `json:"aliases"`
}

// 中文圈地区——只有这些地区的艺人,MusicBrainz 上那条中文别名才是"他本人的名字";
// 其它地区(尤其欧美)艺人的中文别名只是面向中文市场的译名,不该拿来当规范名。
var chineseSpeakingCountries = map[string]bool{
	"CN": true, "TW": true, "HK": true, "MO": true, "SG": true,
}

// pickChineseAlias 从别名列表里挑出该采用的中文名,挑不到返回空串。纯函数,有单测。
//
// ⚠️ 2026-08-05 修的真实 bug:原来这里只要"含汉字且 locale 不是 ja"就直接采纳第一条,
// 结果把欧美艺人的中文译名也当成了规范名——实测 Michael Jackson 在 MusicBrainz 上就有
// 一条 `迈克尔·杰克逊`(locale=yue_Hans_CN、type=Artist name、primary=true),于是所有
// 新解析的 MJ 曲目历史里都显示成"迈克尔·杰克逊",跟同一批老缓存里的英文名不一致。
//
// 判据只能用艺人所属地区(country),不能用别名自己的 type/primary:实测坐实
// Michael Jackson 那条中文别名的 type 同样是 "Artist name"、primary 同样是 true,跟
// 陈柏宇(HK,中文名确实是本名)那条一模一样,靠别名自身字段完全区分不开。
//
// country 缺失时一律不采纳——保守选择,代价很小:canonical_artist 是一条四层解析链,
// 这里放弃之后网易云那一层会接手,而真正的中文歌手在网易云本来就返回中文名。
func pickChineseAlias(aliases []mbAlias, country string) string {
	if !chineseSpeakingCountries[strings.ToUpper(strings.TrimSpace(country))] {
		return ""
	}
	for _, al := range aliases {
		// 仍然排除明确标了日文 locale 的别名(日文汉字别名不是中文名)。
		if al.Locale == "ja" {
			continue
		}
		// 法定名/搜索提示不是艺名,理由见 mbAlias.Type 的注释。
		if al.Type == "Legal name" || al.Type == "Search hint" {
			continue
		}
		if containsHan(al.Name) {
			return toSimplified(al.Name)
		}
	}
	return ""
}

// musicbrainzMinScore 是"认为搜索命中的确实是这个歌手"的置信度门槛——2026-07-30 实测
// 坐实:精确/近似命中(比如"Crowd Lu"搜到盧廣仲本人)是 100 分,不相关的宽泛匹配(比如
// 按姓氏"Lu"单字搜到一堆不相关艺人)只有 50~56 分左右,90 留了一点余量但仍然足够严格,
// 避免把搜索词的宽泛匹配误认成确切命中。
const musicbrainzMinScore = 90

// lookupMusicBrainzChineseAlias 查一次 MusicBrainz 的 artist 搜索(按原始标签整体做
// 全文搜索,不加 artist:"..." 这种字段限定语法——2026-07-30 实测坐实全文搜索比字段
// 限定搜索召回率更高,后者对夹杂罗马化拼音/英文艺名的搜索词经常一个都搜不到),命中且
// 置信度够高时再取一次这个艺人的别名列表,从别名里挑一个中文名(优先跳过明确标了日文
// locale 的别名,防止把日文汉字别名误当中文——2026-07-30 实测这份别名列表里"卢广仲"
// 这条本身没有标 locale,不能简单按 locale==zh 过滤,只能反过来排除确定不是中文的)。
// 任何一步失败/没有结果都返回空字符串,不重试、不报错——这条路径只是 canonical_artist
// 解析链路的第一层,查不到时 resolveTrackEnrichment 现有的网易云/QQ 逻辑会接手。
func lookupMusicBrainzChineseAlias(ctx context.Context, rawArtist string) string {
	if err := musicbrainzThrottle(ctx); err != nil {
		return ""
	}
	var search mbSearchResponse
	searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(rawArtist) + "&fmt=json&limit=5"
	if err := mbGetJSON(ctx, searchURL, &search); err != nil || len(search.Artists) == 0 {
		return ""
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return ""
	}

	if err := musicbrainzThrottle(ctx); err != nil {
		return ""
	}
	var withAliases mbArtistWithAliases
	aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(top.ID) + "?inc=aliases&fmt=json"
	if err := mbGetJSON(ctx, aliasURL, &withAliases); err != nil {
		return ""
	}
	return pickChineseAlias(withAliases.Aliases, withAliases.Country)
}

// ---- MB 主名:本名 ↔ 艺名互换的通用解法 ----

var (
	mbPrimaryNameMu    sync.Mutex
	mbPrimaryNameCache = map[string][]string{}
	mbPrimaryNamePath  string // 空 = 只用内存不持久化(单测/一次性子命令)
	mbPrimaryNameDirty bool
)

// loadMBPrimaryNameCache/saveMBPrimaryNameCache 跟 loadArtistAliasCache 同一套持久化
// 模式(整份 map 序列化、临时文件+原子改名),但有一条**关键差别**:
//
// ⚠️ 只落盘**查到了**的条目,查空的一律只留在内存里。
//
// 理由是这条路径的失败几乎都是暂时性的:MusicBrainz 限速是按 IP、1 req/s,而
// musicbrainzThrottle() 是**进程内**的节流 —— 常驻 collector、手动搜索那个一次性 CLI、
// 还有跑测试的进程各自计时,谁都不知道别人刚打过。撞上限速就是 503,lookup 返回空。
// 要是把这个空也永久写进文件(artistAliasCache 就是那么做的,见它注释里"想重查只能手动
// 删缓存文件里的 key"),一次偶发限速会把这位歌手**永久**钉死在"没有别名"上,而这条兜底
// 恰恰是"五个源一条候选都没有"时最后的救命绳。
//
// 2026-08-20 实测反馈坐实了这个形态:同一首歌手动搜索第一遍 0 条、原样再搜一遍就出 5 条。
//
// ⚠️ 2026-08-30:值的类型从单个 string 改成 []string(见 musicBrainzArtistAliases 头注,
// 一个歌手现在可能有不止一个候选写法)。磁盘上已有的旧格式文件(值是裸字符串,比如
// `{"Khalil Fong":"方大同"}`)解码成新类型会直接失败——不能让用户已经攒下的缓存
// 因为一次格式升级就整份作废,加一段兜底:新格式解码失败时退回旧格式尝试一次,查到的
// 每个字符串包成单元素切片。只影响加载,落盘永远只写新格式,旧文件被下一次写入自然
// 升级掉。
func loadMBPrimaryNameCache(path string) {
	mbPrimaryNamePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string][]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = m
		mbPrimaryNameMu.Unlock()
		log.Printf("loaded %d cached MusicBrainz primary names from %s", len(m), path)
		return
	}
	var legacy map[string]string
	if err := json.Unmarshal(data, &legacy); err == nil && legacy != nil {
		m = make(map[string][]string, len(legacy))
		for k, v := range legacy {
			if v != "" {
				m[k] = []string{v}
			}
		}
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = m
		mbPrimaryNameMu.Unlock()
		log.Printf("loaded %d cached MusicBrainz primary names from %s (legacy format)", len(m), path)
	}
}

func saveMBPrimaryNameCache() {
	mbPrimaryNameMu.Lock()
	if !mbPrimaryNameDirty || mbPrimaryNamePath == "" {
		mbPrimaryNameMu.Unlock()
		return
	}
	// 只序列化非空值 —— 见上面那段 ⚠️。
	keep := make(map[string][]string, len(mbPrimaryNameCache))
	for k, v := range mbPrimaryNameCache {
		if len(v) > 0 {
			keep[k] = v
		}
	}
	data, err := json.Marshal(keep)
	mbPrimaryNameDirty = false
	mbPrimaryNameMu.Unlock()
	if err != nil {
		return
	}
	tmp := mbPrimaryNamePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, mbPrimaryNamePath); err != nil {
		log.Printf("save musicbrainz primary name cache: %v", err)
	}
}

// musicBrainzArtistAliases 给出"MusicBrainz 上这位歌手的其它已登记写法",仅当本地
// 这个标签确实是同一位歌手登记过的写法才给;够不到条件返回 nil。
//
// 2026-08-20 加(当时叫 musicBrainzPrimaryArtistName,只给单个"主名")。修的是这个
// 实测案例:Apple Music 把《Hurry Up Tomorrow》整张专辑的歌手标成 **Abel Tesfaye**
// (他 2025 年起用本名发行),而五个歌词源全部按 **The Weeknd** 索引 —— 原样查 0 条
// 候选,换成 The Weeknd 五个源全有(最高 1162 分)。
//
// 现有两条兜底都够不到:artistAliasTable 是手工表(没登记就没有);
// canonicalArtistViaMusicBrainz 走的是**同一次** MB 查询,却只从别名里挑中文名、而且
// 要求 country ∈ CN/TW/HK/MO/SG(The Weeknd 是 CA)—— 那条规则是给"中文歌手的罗马化
// 写法"准备的,跟"本名 ↔ 艺名"是两件事。而那次查询本来就已经把主名拿回来了(搜索首条
// name="The Weeknd"、score=100),只是被丢掉没用。
//
// ⚠️ 2026-08-30 订正:原来"搜到的主名跟本地标签相同就直接返回空、省掉第二次请求"这条
// 优化本身问错了问题。实测案例:方大同《Lovers Policy》(专辑《15》,五源真实标题是
// 《情胜策略》)。MusicBrainz 上这位歌手的**主名本身登记的就是"方大同"**(不是
// "Khalil Fong")——本地标签恰好已经是"方大同"时,旧逻辑一看"主名==本地标签"就地
// 返回空,永远没机会往下翻别名列表拿到"Khalil Fong"这条真正有用的候选;反过来本地
// 标签是"Khalil Fong"时,搜到的主名"方大同"跟它不同,才会继续走到别名列表那一步、
// 靠 knownArtistAlias 手工表更快地换到同一个结论。同一份 MusicBrainz 数据,只因为
// 搜索方向不同就有一半概率被提前放弃——该问的是"除了本地标签,MB 还登记过哪些确凿的
// 写法",不是"主名是不是恰好换了个字符串"。现在无论主名是否等于本地标签,都会继续
// 取完整别名列表,把**除本地标签自己以外**、Type 是 "Artist name" 的主名/别名全部
// 作为候选返回(不止一个——方大同这个案例本身就在别名列表里明确登记了"Khalil Fong")。
//
// 为什么敢用搜索的首条命中:除了 musicbrainzMinScore(90)这道原有门槛,这里**额外**
// 要求本地标签逐字(normLoose)命中该艺人的主名或任一别名 —— 把"模糊搜到的第一个人"
// 收紧成"MB 明确登记过这个写法就是这个人"。差一点都返回 nil:闸门层的 artistMatches
// 在别名轮里比的是**别名串**,拦不住"换成另一个人的名字、于是收下另一个人的同名歌"。
//
// 缓存:查到的落盘(自己一份 artist-primary-cache.json,不挤进 artist-alias-cache.json
// 的 map[string]string 或 artist-identity-cache.json 的语义里),查空的只留在内存。
// 为什么这么分,见 loadMBPrimaryNameCache 上面那段 ⚠️ —— 一次偶发的 MusicBrainz 限速
// 不该把一位歌手永久钉死在"没有别名"上。
func musicBrainzArtistAliases(ctx context.Context, rawArtist string) []string {
	raw := strings.TrimSpace(rawArtist)
	if raw == "" {
		return nil
	}
	mbPrimaryNameMu.Lock()
	if v, ok := mbPrimaryNameCache[raw]; ok {
		mbPrimaryNameMu.Unlock()
		return v
	}
	mbPrimaryNameMu.Unlock()

	resolved := lookupMusicBrainzArtistAliases(ctx, raw)

	mbPrimaryNameMu.Lock()
	mbPrimaryNameCache[raw] = resolved
	// 查空不算脏 —— 空值不落盘,下一个进程还能再试一次(见 saveMBPrimaryNameCache)。
	if len(resolved) > 0 {
		mbPrimaryNameDirty = true
	}
	mbPrimaryNameMu.Unlock()
	saveMBPrimaryNameCache()
	return resolved
}

// resolvedArtistCJKHint 给 isProbablyWrongLanguageLyrics 用,只读窥探
// artistAliasCache/mbPrimaryNameCache/qqArtistNameCache 这三份缓存——本次 resolve
// 链路里别的步骤(CanonicalArtist 解析走 canonicalArtistViaMusicBrainz/
// cachedQQArtistCanonicalName;别名重试走 retryArtistIdentities→
// musicBrainzArtistAliases/cachedQQArtistCanonicalName)有没有已经查到过这位歌手的
// 中文写法。
//
// ⚠️ 刻意不发起新的网络请求(不接受 ctx)——这个函数被 isProbablyWrongLanguageLyrics
// 在打分的热路径上同步调用,不该让一次打分变成一次隐性网络请求。命中与否取决于"运气":
// 如果这位歌手在本次 resolve 里因为别的原因已经查过,这里就能用上;第一次见到、后面
// 也没有别的步骤触发查询,这里只能返回空。三份缓存都命中不了时,mergeLyricCandidateRounds
// 那次"合并两轮结果后重新打分"仍然是最终的救命机会——别名重试轮(retryArtistIdentities)
// 本身就会触发上面那几个查询,查到后缓存就有了,重新打分时这里就能命中。
func resolvedArtistCJKHint(rawArtist string) string {
	artistAliasMu.Lock()
	if v := artistAliasCache[rawArtist]; v != "" {
		artistAliasMu.Unlock()
		return v
	}
	artistAliasMu.Unlock()

	qqArtistNameMu.Lock()
	if v := qqArtistNameCache[rawArtist]; v != "" {
		qqArtistNameMu.Unlock()
		return v
	}
	qqArtistNameMu.Unlock()

	mbPrimaryNameMu.Lock()
	defer mbPrimaryNameMu.Unlock()
	for _, v := range mbPrimaryNameCache[rawArtist] {
		if containsHan(v) {
			return v
		}
	}
	return ""
}

// resolveGenericArtistCanonicalName 是"给一个罕见/罗马化的歌手标签,换一个本库惯用的
// 中文/常用名"这件事的通用实现——canonical_artist 兜底(resolveTrackEnrichment)和
// Top 歌手榜归并(topartists.go 的 artistMergeNameKey/artistMergeDisplayName)共用
// 同一套优先级,取代原来两处各自"MusicBrainz 查不到就落到 artistAliasTable 手工表"
// 的写法:
//
//  1. canonicalArtistViaMusicBrainz:MusicBrainz 的中文别名(country 门槛收紧过,
//     不会把欧美艺人的中文译名误当规范名——2026-08-05 那个 Michael Jackson 展示成
//     "迈克尔·杰克逊"的真实bug就是这道门槛修的,见 pickChineseAlias 头注)。
//  2. cachedQQArtistCanonicalName:QQ 音乐自己的歌手搜索建议——覆盖 MusicBrainz 查不到、
//     或者查错成另一个同名艺人的场景(实测坐实:david tao 被 MB 排到一个无关的德国
//     音乐人头上,lexie liu 被 MB 认成"刘昱妤",QQ 两个都查对)。
//
// ⚠️ 刻意不用 musicBrainzArtistAliases(retryArtistIdentities 用的那条通用查询)—— 那份
// 返回值没有 country/locale 信息,没法在这一层补 pickChineseAlias 那道门槛,直接拿来当
// 展示名会把 Michael Jackson 那个 2026-08-05 的真实bug重新引入(她的 MusicBrainz 别名
// 列表里确实登记着"迈克尔·杰克逊",type="Artist name",不区分 country 的话会被当成
// 规范名)。retryArtistIdentities 场景下这种误差可以接受(只是多打一轮不会命中的搜索,
// 后面 mergeLyricCandidateRounds 的打分会把不对版的候选筛掉),但这里是**直接写进展示
// 字段**,标准必须更严。像"utada"(不带 Hikaru 的短写法)这类因此查不到的案例,留在
// artistAliasTable 手工登记,见其头注。
//
// artistAliasTable(match.go)那几条手工登记**放在最前面查**,不是最后兜底——2026-08-31
// 把原来 23 条手工表逐条核对之后,剩下的残留案例不只是"两边都查不到",还有"QQ 音乐会
// 查到,但查到的是另一个人"这种更危险的情况(实测:"Wanting"第一条建议是无关歌手
// "婉婷",真正的曲婉婷反而是第二条——见 qqArtistCanonicalName 头注)。这种案例如果表
// 排在通用机制后面,通用机制会先给出错误答案、根本轮不到表来纠正。手工表这几条都是人工
// 核实过的确凿结果,理应有最高优先级,不存在"查错了反而更信手工表"这种顾虑。
//
// 调用方各自还有更强的信号排在这整条通用兜底前面(比如 enrich.go 那边会先试网易云/QQ
// 曲库对**这一首具体曲目**的匹配结果,那是比这里更强的证据)。
func resolveGenericArtistCanonicalName(ctx context.Context, rawArtist string) string {
	if v := knownArtistAlias(rawArtist); v != "" {
		return v
	}
	if v := canonicalArtistViaMusicBrainz(ctx, rawArtist); v != "" {
		return v
	}
	return cachedQQArtistCanonicalName(rawArtist)
}

func lookupMusicBrainzArtistAliases(ctx context.Context, raw string) []string {
	if err := musicbrainzThrottle(ctx); err != nil {
		return nil
	}
	var search mbSearchResponse
	searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(raw) + "&fmt=json&limit=5"
	if err := mbGetJSON(ctx, searchURL, &search); err != nil || len(search.Artists) == 0 {
		return nil
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return nil
	}
	// ⚠️ 不再在这里因为"主名==本地标签"就提前返回,理由见函数头注——那个短路会让
	// 方大同这类"MB 主名本身就是本地标签"的歌手永远够不到下面的别名列表。
	if err := musicbrainzThrottle(ctx); err != nil {
		return nil
	}
	var withAliases mbArtistWithAliases
	aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(top.ID) + "?inc=aliases&fmt=json"
	if err := mbGetJSON(ctx, aliasURL, &withAliases); err != nil {
		return nil
	}
	primary := withAliases.Name
	if strings.TrimSpace(primary) == "" {
		primary = top.Name // 详情接口没给 name 时退回搜索结果里的那个
	}
	return mbAliasCandidatesForRetry(primary, withAliases.Aliases, raw)
}

// mbAliasCandidatesForRetry 是上面那个网络查询的**判据部分**,拆出来是为了能单测,
// 分两步:
//
//  1. 先问"MB 认不认识 raw 这个写法就是这个人"——主名或任一别名逐字(normLoose)命中
//     才算数,不过滤别名 type(Legal name / Search hint 一样算)。这跟 pickChineseAlias
//     刻意排除它们不矛盾:那边是在挑"拿来当展示名的别名",身份证名当艺名显示是错的;
//     这边只是找证据回答"MB 认不认识这个写法",登记成法定名/搜索提示同样能作证
//     (Abel Tesfaye 这案 MB 同时登了 Artist name「Abel Tesfaye」和 Legal name
//     「Abel Makkonen Tesfaye」,后者也该算命中)。命中不了直接返回 nil——闸门层的
//     artistMatches 拦不住"换成另一个人的名字、于是收下另一个人的同名歌"。
//  2. 命中之后,把**除 raw 自己以外**、Type 是 "Artist name" 的主名 + 别名全部收集
//     成候选返回(不止一个,顺着别名列表原有顺序,去重)——这一步**不**再要求
//     `alias.Primary`:实测方大同/The Weeknd 两个真实案例都证明这个字段不可靠
//     (The Weeknd 本人那条 "The Weeknd" 别名 primary=false,反而是从没用过的
//     日文别名 primary=true;硬按 primary 过滤会把真正该换的名字滤掉)。只排除
//     Legal name/Search hint:那两类不太可能是音乐平台索引用的写法,收进来大概率
//     白跑一轮网络请求,而 retryArtistIdentities 的上游调用方会对每个候选各发起一次
//     完整的七源搜索。
func mbAliasCandidatesForRetry(primary string, aliases []mbAlias, raw string) []string {
	primary = strings.TrimSpace(primary)
	raw = strings.TrimSpace(raw)
	if primary == "" || raw == "" {
		return nil
	}
	target := normLoose(raw)
	matched := normLoose(primary) == target
	if !matched {
		for _, al := range aliases {
			if normLoose(al.Name) == target {
				matched = true
				break
			}
		}
	}
	if !matched {
		return nil
	}
	seen := map[string]bool{target: true}
	var out []string
	add := func(name string) {
		name = strings.TrimSpace(name)
		if name == "" {
			return
		}
		k := normLoose(name)
		if seen[k] {
			return
		}
		seen[k] = true
		out = append(out, name)
	}
	add(primary)
	for _, al := range aliases {
		if al.Type != "Artist name" {
			continue
		}
		add(al.Name)
	}
	return out
}

func mbGetJSON(ctx context.Context, url string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	// MusicBrainz 要求所有调用方在 User-Agent 里标明身份(应用名+版本+联系方式),不带
	// 这个头容易被限流/拒绝,见上面 Rate Limiting 文档链接。
	req.Header.Set("User-Agent", fmt.Sprintf("%s/%s (+https://github.com/Yudaotor/lyrimuse)", clientName, clientVersion))
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := doHTTPTracked(client, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("musicbrainz %s: status %d", url, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}
