// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
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
// 成功查一次 MusicBrainz 就够了。空字符串是一个合法的缓存值,代表"查过 MusicBrainz,
// 确实没有可用的中文别名"(没查到这个人,或者置信度不够,或者查到了但没有中文别名),
// 避免对同一个歌手反复重新查询——跟 needsPeripheralBackfill 那条"外围字段缺失才短时
// 重试"的节流不是一回事:这里没有过期/重试机制,查一次永久生效,想让某个歌手重新查一遍
// 只能手动去这份缓存文件里删掉对应的 key(用法跟 lyrimuse-enrich-cache.json 一致)。
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
	data, err := json.Marshal(artistAliasCache)
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

func musicbrainzThrottle() {
	musicbrainzRateMu.Lock()
	defer musicbrainzRateMu.Unlock()
	if wait := musicbrainzMinIntervalBetweenCalls - time.Since(musicbrainzLastCall); wait > 0 {
		time.Sleep(wait)
	}
	musicbrainzLastCall = time.Now()
}

// canonicalArtistViaMusicBrainz 是 canonical_artist 解析链路里第一个被咨询的来源,
// 供 resolveTrackEnrichment(enrich.go)调用。只对"原始标签本身不含中文"的歌手生效
// (containsHan 判断,复用 match.go 的 cjkRatio)——已经是中文标签的没有"中英文两套
// 写法"这个问题需要解决,不必白白消耗 MusicBrainz 的请求额度。
func canonicalArtistViaMusicBrainz(rawArtist string) string {
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

	resolved := lookupMusicBrainzChineseAlias(rawArtist)

	artistAliasMu.Lock()
	artistAliasCache[rawArtist] = resolved
	artistAliasDirty = true
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
func resolveArtistIdentityMB(name, knownMbid string) mbArtistIdentity {
	name = strings.TrimSpace(name)
	if name == "" {
		return mbArtistIdentity{}
	}
	id := mbArtistIdentity{Mbid: knownMbid}
	if id.Mbid == "" {
		musicbrainzThrottle()
		var search mbSearchResponse
		searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(name) + "&fmt=json&limit=5"
		if err := mbGetJSON(searchURL, &search); err == nil && len(search.Artists) > 0 &&
			search.Artists[0].Score >= musicbrainzMinScore {
			id.Mbid = search.Artists[0].ID
		}
	}
	if id.Mbid != "" && !containsHan(name) {
		musicbrainzThrottle()
		var withAliases mbArtistWithAliases
		aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(id.Mbid) + "?inc=aliases&fmt=json"
		if err := mbGetJSON(aliasURL, &withAliases); err == nil {
			id.Zh = pickChineseAlias(withAliases.Aliases, withAliases.Country)
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
func lookupMusicBrainzChineseAlias(rawArtist string) string {
	musicbrainzThrottle()
	var search mbSearchResponse
	searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(rawArtist) + "&fmt=json&limit=5"
	if err := mbGetJSON(searchURL, &search); err != nil || len(search.Artists) == 0 {
		return ""
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return ""
	}

	musicbrainzThrottle()
	var withAliases mbArtistWithAliases
	aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(top.ID) + "?inc=aliases&fmt=json"
	if err := mbGetJSON(aliasURL, &withAliases); err != nil {
		return ""
	}
	return pickChineseAlias(withAliases.Aliases, withAliases.Country)
}

// ---- MB 主名:本名 ↔ 艺名互换的通用解法 ----

var (
	mbPrimaryNameMu    sync.Mutex
	mbPrimaryNameCache = map[string]string{}
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
func loadMBPrimaryNameCache(path string) {
	mbPrimaryNamePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = m
		mbPrimaryNameMu.Unlock()
		log.Printf("loaded %d cached MusicBrainz primary names from %s", len(m), path)
	}
}

func saveMBPrimaryNameCache() {
	mbPrimaryNameMu.Lock()
	if !mbPrimaryNameDirty || mbPrimaryNamePath == "" {
		mbPrimaryNameMu.Unlock()
		return
	}
	// 只序列化非空值 —— 见上面那段 ⚠️。
	keep := make(map[string]string, len(mbPrimaryNameCache))
	for k, v := range mbPrimaryNameCache {
		if v != "" {
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

// musicBrainzPrimaryArtistName 给出"MusicBrainz 上这位歌手的主名",仅当本地这个标签
// 确实是同一位歌手登记过的写法、而主名跟它不同名时才给;够不到条件一律返回空串。
//
// 2026-08-20 加。修的是这个实测案例:Apple Music 把《Hurry Up Tomorrow》整张专辑的歌手
// 标成 **Abel Tesfaye**(他 2025 年起用本名发行),而五个歌词源全部按 **The Weeknd**
// 索引 —— 原样查 0 条候选,换成 The Weeknd 五个源全有(最高 1162 分)。
//
// 现有两条兜底都够不到:artistAliasTable 是手工表(没登记就没有);
// canonicalArtistViaMusicBrainz 走的是**同一次** MB 查询,却只从别名里挑中文名、而且
// 要求 country ∈ CN/TW/HK/MO/SG(The Weeknd 是 CA)—— 那条规则是给"中文歌手的罗马化
// 写法"准备的,跟"本名 ↔ 艺名"是两件事。而那次查询本来就已经把主名拿回来了(搜索首条
// name="The Weeknd"、score=100),只是被丢掉没用。
//
// 为什么敢用搜索的首条命中:除了 musicbrainzMinScore(90)这道原有门槛,这里**额外**
// 要求本地标签逐字(normLoose)命中该艺人的主名或任一别名 —— 把"模糊搜到的第一个人"
// 收紧成"MB 明确登记过这个写法就是这个人"。差一点都返回空:闸门层的 artistMatches 在
// 别名轮里比的是**别名串**,拦不住"换成另一个人的名字、于是收下另一个人的同名歌"。
//
// 缓存:查到的落盘(自己一份 artist-primary-cache.json,不挤进 artist-alias-cache.json
// 的 map[string]string 或 artist-identity-cache.json 的语义里),查空的只留在内存。
// 为什么这么分,见 loadMBPrimaryNameCache 上面那段 ⚠️ —— 一次偶发的 MusicBrainz 限速
// 不该把一位歌手永久钉死在"没有别名"上。
func musicBrainzPrimaryArtistName(rawArtist string) string {
	raw := strings.TrimSpace(rawArtist)
	if raw == "" {
		return ""
	}
	mbPrimaryNameMu.Lock()
	if v, ok := mbPrimaryNameCache[raw]; ok {
		mbPrimaryNameMu.Unlock()
		return v
	}
	mbPrimaryNameMu.Unlock()

	resolved := lookupMusicBrainzPrimaryName(raw)

	mbPrimaryNameMu.Lock()
	mbPrimaryNameCache[raw] = resolved
	// 查空不算脏 —— 空值不落盘,下一个进程还能再试一次(见 saveMBPrimaryNameCache)。
	if resolved != "" {
		mbPrimaryNameDirty = true
	}
	mbPrimaryNameMu.Unlock()
	saveMBPrimaryNameCache()
	return resolved
}

func lookupMusicBrainzPrimaryName(raw string) string {
	musicbrainzThrottle()
	var search mbSearchResponse
	searchURL := "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(raw) + "&fmt=json&limit=5"
	if err := mbGetJSON(searchURL, &search); err != nil || len(search.Artists) == 0 {
		return ""
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return ""
	}
	// 主名就是本地这个写法 → 没什么可换的,省掉第二次请求。
	if normLoose(top.Name) == normLoose(raw) {
		return ""
	}
	musicbrainzThrottle()
	var withAliases mbArtistWithAliases
	aliasURL := "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(top.ID) + "?inc=aliases&fmt=json"
	if err := mbGetJSON(aliasURL, &withAliases); err != nil {
		return ""
	}
	primary := withAliases.Name
	if strings.TrimSpace(primary) == "" {
		primary = top.Name // 详情接口没给 name 时退回搜索结果里的那个
	}
	return mbPrimaryNameForRetry(primary, withAliases.Aliases, raw)
}

// mbPrimaryNameForRetry 是上面那个网络查询的**判据部分**,拆出来是为了能单测:
// 主名非空、跟本地标签不同名、且本地标签逐字命中主名或某条别名,才认。
//
// 别名的 type 在这里**不过滤**(Legal name / Search hint 一样算)—— 这跟
// pickChineseAlias 刻意排除它们不矛盾:那边是在挑"拿来当展示名的别名",身份证名当艺名
// 显示是错的;这边只是找证据回答"MB 认不认识这个写法就是这个人",登记成法定名/搜索提示
// 同样能作证(Abel Tesfaye 这案 MB 同时登了 Artist name「Abel Tesfaye」和 Legal name
// 「Abel Makkonen Tesfaye」,后者也该算命中)。
func mbPrimaryNameForRetry(primary string, aliases []mbAlias, raw string) string {
	primary = strings.TrimSpace(primary)
	raw = strings.TrimSpace(raw)
	if primary == "" || raw == "" {
		return ""
	}
	target := normLoose(raw)
	if normLoose(primary) == target {
		return ""
	}
	matched := false
	for _, al := range aliases {
		if normLoose(al.Name) == target {
			matched = true
			break
		}
	}
	if !matched {
		return ""
	}
	return primary
}

func mbGetJSON(url string, v any) error {
	req, err := http.NewRequest(http.MethodGet, url, nil)
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
