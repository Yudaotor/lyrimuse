package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// MusicBrainz 是 canonical_artist 解析链路里按"这个人是谁"直接查的一层:不依赖某一首曲目在网易云/QQ 搜不搜得到,
// 同一歌手的各首歌能统一成同一个写法(按曲目匹配会有成有败,一张专辑里个别几首漏成原始标签)。手工表
// artistAliasTable 排在它前面(见 canonicalArtistViaMusicBrainz);它查不到或没有把握时,网易云/QQ 按曲目匹配兜底。

// artistAliasCache:原始歌手标签(本地播放器给的,英文/罗马化)→ MusicBrainz 查到的中文别名,按歌手缓存。
// 空字符串是内存里的合法值,表示"查了,没有可用的中文别名",同一进程内不再查。空值不落盘:查空常是偶发限速
// (503),落盘就把这位歌手永久钉死在"没有别名"上,下一次进程启动还应该能重查(同 mbPrimaryNameCache)。
var (
	artistAliasMu    sync.Mutex
	artistAliasCache = map[string]string{}
	// artistAliasFailedUntil:这位歌手的中文名刚才没问成,到这个时刻之前不再问(只在内存里)。
	artistAliasFailedUntil = map[string]time.Time{}
	artistAliasPath        string // 落盘路径；空则只用内存不持久化
	artistAliasDirty       bool
)

// loadArtistAliasCache/saveArtistAliasCache 跟 loadEnrichCache/saveEnrichCache
// (enrich.go)同一套持久化模式(整份 map 序列化、临时文件+原子改名落盘),只是这份缓存
// 小得多——只有"曾经查过 MusicBrainz 的原始歌手标签"这一个维度,不是按曲目,数据量级
// 是"不同歌手数"而不是"不同曲目数"。
func loadArtistAliasCache(path string) {
	artistAliasPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		artistAliasMu.Lock()
		artistAliasCache = m
		artistAliasMu.Unlock()
		noteCacheLoaded(path, fmt.Sprintf("%d artist aliases", len(m)))
	}
}

// artistAliasRetryAfter:中文名没问成之后多久再问。
const artistAliasRetryAfter = 10 * time.Minute

func saveArtistAliasCache() {
	artistAliasMu.Lock()
	if !artistAliasDirty || artistAliasPath == "" {
		artistAliasMu.Unlock()
		return
	}
	// 只序列化非空值,理由见 artistAliasCache。
	keep := make(map[string]string, len(artistAliasCache))
	for k, v := range artistAliasCache {
		if v != "" {
			keep[k] = v
		}
	}
	path := artistAliasPath
	artistAliasDirty = false
	artistAliasMu.Unlock()
	mergeMissingFromDisk(path, keep, func(v string) bool { return v != "" })
	data, err := json.Marshal(keep)
	if err != nil {
		return
	}
	if err := writeFileAtomic(path, data); err != nil {
		slog.Error("save artist alias cache", "err", err)
	}
}

// musicbrainzMinIntervalBetweenCalls:MusicBrainz 对匿名调用方的限速建议(约 1 请求/秒,
// https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)。查询量小,一把全局互斥锁串行化、
// 不够间隔就 sleep 补足即可。单测用假应答时置 0(withoutMBThrottle)。
var musicbrainzMinIntervalBetweenCalls = 1100 * time.Millisecond

// musicbrainzSharedMaxWait:跨进程窗口还要等超过这么久,就说明是被 503 停手了,这次不发。
const musicbrainzSharedMaxWait = 3 * time.Second

// musicbrainzThrottledPause:MusicBrainz 回 503 / 429 时,所有进程一起停多久(响应没给 Retry-After 时),封顶一分钟。
const musicbrainzThrottledPause = 10 * time.Second

var (
	musicbrainzRateMu   sync.Mutex
	musicbrainzLastCall time.Time
)

// musicbrainzThrottle 排队等限速间隔;ctx 被取消就提前返回 ctx.Err()。没等到间隔就返回时不更新
// musicbrainzLastCall:这次不会真的发请求,不占限速名额。
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
	// 跨进程:App、引擎子命令也打 MusicBrainz,同一个出口 IP 合起来算限额。共享窗口记的是「下一个请求最早
	// 什么时候能发」:没到就等,等太久(被 503 停手)这次不发;发之前把窗口往后推一个间隔。
	now := time.Now()
	if until := sharedCooldownUntilFresh(sharedCooldownMusicBrainz, now); !until.IsZero() {
		wait := until.Sub(now)
		if wait > musicbrainzSharedMaxWait {
			return errHostGuarded
		}
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	musicbrainzLastCall = time.Now()
	publishSharedCooldown("musicbrainz.org", sharedCooldownMusicBrainz, musicbrainzLastCall.Add(musicbrainzMinIntervalBetweenCalls))
	return nil
}

// musicbrainzPauseFor:回 503 / 429 时停多久。Retry-After 给了秒数就按它(封顶一分钟),没给按 musicbrainzThrottledPause。纯函数。
func musicbrainzPauseFor(retryAfter string) time.Duration {
	if secs, err := strconv.Atoi(strings.TrimSpace(retryAfter)); err == nil && secs > 0 {
		return min(time.Duration(secs)*time.Second, time.Minute)
	}
	return musicbrainzThrottledPause
}

// artistCanonicalCacheOnly:为真时 canonicalArtistViaMusicBrainz / cachedQQArtistCanonicalName 只读缓存、绝不联网
// (查不到就当没有,也不往缓存写空值)。给 `lyrimuse-engine top-artists`(App 统计页背后那条 CLI)的默认档用:
// 那个进程没加载别名缓存,逐个非中文歌手名真查 MusicBrainz(1.1 s 限速)+ QQ 会跑一两分钟,撞上 App 侧 25 s 的
// 看门狗。CLI 的 -mb-budget 0 承诺只读缓存、毫秒级返回,canonical 名这一步也守这个承诺;归并仍有 mbid 身份缓存
// 和名字键两路信号。
var artistCanonicalCacheOnly bool

// canonicalArtistViaMusicBrainz 给 resolveTrackEnrichment(enrich.go)查 canonical_artist:先查手工表,再查
// MusicBrainz 的中文别名。只对原始标签本身不含中文的歌手生效(containsHan):已经是中文标签的没有中英文两套写法要统一。
func canonicalArtistViaMusicBrainz(ctx context.Context, rawArtist string) string {
	rawArtist = strings.TrimSpace(rawArtist)
	if rawArtist == "" || containsHan(rawArtist) {
		return ""
	}
	// 合唱串不查:整串拿去搜,搜到其中哪一位就记成哪一位,会把合唱缩成一个人。缓存里早年按整串存下的条目也不读。
	if !expectsCanonicalArtist(rawArtist) {
		return ""
	}

	// 手工表排在 MusicBrainz 前面:表里那几条恰恰是 MB 查错人的(「Lexie Liu」MB 给的是另一个人「刘昱妤」),
	// 让 MB 先答就拦不住。命中时把缓存里的值也纠正过来 —— App 的歌手归并(LocalArtistAliases)直接读这份缓存,
	// 早先落盘的错值不改掉,两个人就一直被并在一起。
	if v := knownArtistAlias(rawArtist); v != "" {
		artistAliasMu.Lock()
		if artistAliasCache[rawArtist] != v {
			artistAliasCache[rawArtist] = v
			artistAliasDirty = true
		}
		artistAliasMu.Unlock()
		saveArtistAliasCache()
		return v
	}

	artistAliasMu.Lock()
	if v, ok := artistAliasCache[rawArtist]; ok {
		artistAliasMu.Unlock()
		return v
	}
	if until, failed := artistAliasFailedUntil[rawArtist]; failed && time.Now().Before(until) {
		artistAliasMu.Unlock()
		return ""
	}
	artistAliasMu.Unlock()
	if artistCanonicalCacheOnly {
		return "" // 见 artistCanonicalCacheOnly:不联网、不写空值
	}

	resolved, err := lookupMusicBrainzChineseAlias(ctx, rawArtist)
	if err != nil {
		// 没问成(限流、超时、共享冷却里被拦、调用方取消):不写缓存 —— 写进去就是这个常驻进程余下的生命周期里
		// 这位歌手都「没有中文名」。退避一段再试,免得每首歌都白排一次限速队列;调用方取消的不退避。
		if ctx.Err() == nil {
			artistAliasMu.Lock()
			artistAliasFailedUntil[rawArtist] = time.Now().Add(artistAliasRetryAfter)
			artistAliasMu.Unlock()
		}
		return ""
	}

	artistAliasMu.Lock()
	delete(artistAliasFailedUntil, rawArtist)
	artistAliasCache[rawArtist] = resolved
	// 查空不算脏:空值不落盘,下一次进程还能再试一次(见 artistAliasCache)。
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
// 跟上面 artistAliasCache(只存中文别名字符串,给 canonical_artist 链路)是两份缓存:归并需要的是身份(mbid)。
// "Leah Dou"和"窦靖童"名字键完全不同、Last.fm 又只给其中一条 mbid,只有把两个名字各自解析到同一个
// MusicBrainz 艺人,并查集才连得上。中文名(Zh)顺手一起存:榜单里只有罗马名的中文歌手("Ronghao Li")
// 靠它显示成中文。
//
// 缓存语义与 artistAliasCache 一致:查一次永久生效,没有 mbid 也是合法缓存("查过,没结果"),
// 想重查只能手动删缓存文件里的 key。Checked 为假的条目是早先的判据写下的,由 recheckArtistIdentities
// (identityrecheck.go)按现行判据补核。
type mbArtistIdentity struct {
	Mbid string `json:"mbid,omitempty"`
	Zh   string `json:"zh,omitempty"`
	// Checked:这条是按现行判据得出的(resolveArtistIdentityMB 写的,或补核时留下的)。
	Checked bool `json:"checked,omitempty"`
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
		noteFileErr("read", path, err)
		return
	}
	var m map[string]mbArtistIdentity
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		artistIdentityMu.Lock()
		artistIdentityCache = m
		artistIdentityMu.Unlock()
		noteCacheLoaded(path, fmt.Sprintf("%d artist identities", len(m)))
	}
}

// artistIdentitySaveMu 把「拍快照 → 并盘上 → 写盘」整段串起来:两次存盘并发时,先拍的旧快照不能后落盘。
var artistIdentitySaveMu sync.Mutex

func saveArtistIdentityCache() {
	artistIdentitySaveMu.Lock()
	defer artistIdentitySaveMu.Unlock()
	artistIdentityMu.Lock()
	if !artistIdentityDirty || artistIdentityPath == "" {
		artistIdentityMu.Unlock()
		return
	}
	keep := make(map[string]mbArtistIdentity, len(artistIdentityCache))
	for k, v := range artistIdentityCache {
		keep[k] = v
	}
	path := artistIdentityPath
	artistIdentityDirty = false
	artistIdentityMu.Unlock()
	// 先并盘上的:手动跑 `top-artists -mb-budget N` 查到的条目,不能被常驻进程下一次整份写回盖掉(同 saveArtistAliasCache)。
	mergeMissingFromDisk(path, keep, func(mbArtistIdentity) bool { return true })
	data, err := json.Marshal(keep)
	if err != nil {
		return
	}
	if err := writeFileAtomic(path, data); err != nil {
		slog.Error("save artist identity cache", "err", err)
	}
}

func cachedArtistIdentity(name string) (mbArtistIdentity, bool) {
	artistIdentityMu.Lock()
	defer artistIdentityMu.Unlock()
	id, ok := artistIdentityCache[name]
	return id, ok
}

func storeArtistIdentity(name string, id mbArtistIdentity) {
	artistIdentityMu.Lock()
	artistIdentityCache[name] = id
	artistIdentityDirty = true
	artistIdentityMu.Unlock()
}

// resolveArtistIdentityMB 联网解析一个歌手名的身份并写缓存。knownMbid 非空时(Last.fm 已给出 mbid)跳过搜索、
// 只在需要中文名时补一次别名查询;否则先搜(置信度门槛同 musicbrainzMinScore)。中文名只对名字本身不含汉字的
// 条目去查。每次调用最多 2 个 MusicBrainz 请求,受 musicbrainzThrottle 全局限速。
// 调用方是 topartists.go(Top 歌手榜归并),不在可取消的解析链路上,所以用 context.Background()。
func resolveArtistIdentityMB(name, knownMbid string) mbArtistIdentity {
	name = strings.TrimSpace(name)
	if name == "" {
		return mbArtistIdentity{}
	}
	ctx := context.Background()
	id := mbArtistIdentity{Mbid: knownMbid}
	// 手工表里的名字不去搜:那几条正是 MB 把人认错的(见 artistAliasTable 头注),搜出来的 mbid 属于别人,
	// 永久落盘之后「歌手来自哪里」、App 歌手页的跳转都会指到那个人。中文名直接用表里的;Last.fm 给了 mbid 就留着。
	if v := knownArtistAlias(name); v != "" {
		id.Zh, id.Checked = v, true
		storeArtistIdentity(name, id)
		return id
	}
	// 任何一步没问成(限速被拒、网络失败、共享窗口停手)就只返回、不写缓存:缓存查一次永久生效,
	// 把「没问成」写成「查过、没有」会把这位歌手永久钉在没有身份上。
	// 走 mbGetJSONShared:同一个名字的搜索 / 别名请求跟中文名、主名那两条路径逐字相同,响应缓存里有就不再排队。
	verified := id.Mbid != "" // Last.fm 给的 mbid 就是这条榜单记录自己的身份
	var withAliases mbArtistWithAliases
	aliasesFor := "" // withAliases 是哪个 mbid 的
	if id.Mbid == "" {
		var search mbSearchResponse
		if err := mbGetJSONShared(ctx, mbArtistSearchURL(name), &search); err != nil {
			return id
		}
		if len(search.Artists) > 0 && search.Artists[0].Score >= musicbrainzMinScore {
			top := search.Artists[0]
			aliasURL := mbArtistAliasesURL(top.ID)
			if err := mbGetJSONShared(ctx, aliasURL, &withAliases); err != nil {
				return id
			}
			aliasesFor = top.ID
			// 分数高不等于是这个人(「David Tao」排到过一位德国音乐人头上):本地写法得是这位艺人的主名或
			// 登记过的别名才收,同 mbAliasCandidatesForRetry 的判据。
			if mbNameBelongsToArtist(top.Name, withAliases.Aliases, name) {
				id.Mbid, verified = top.ID, true
			}
		}
	}
	if verified && id.Mbid != "" && !containsHan(name) {
		if aliasesFor != id.Mbid {
			aliasURL := mbArtistAliasesURL(id.Mbid)
			if err := mbGetJSONShared(ctx, aliasURL, &withAliases); err != nil {
				return id
			}
		}
		id.Zh = pickChineseAlias(withAliases.Aliases, withAliases.Country)
	}
	id.Checked = true
	storeArtistIdentity(name, id)
	return id
}

// mbNameBelongsToArtist:本地写法是不是这位艺人的主名或登记过的别名(按 normLoose 比)。
func mbNameBelongsToArtist(primary string, aliases []mbAlias, raw string) bool {
	target := normLoose(raw)
	if target == "" {
		return false
	}
	if normLoose(primary) == target {
		return true
	}
	for _, al := range aliases {
		if normLoose(al.Name) == target {
			return true
		}
	}
	return false
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
	// Type 用来挡"不是艺名"的别名:MusicBrainz 给艺名歌手也登记
	// 中文**法定名**(实测 ØZI 有一条 type="Legal name" 的「陳奕凡」),拿它当显示名
	// 等于把艺人改叫回身份证名。只拒绝确定不该用的类型(Legal name/Search hint),
	// 不做"只收 Artist name"的白名单——真实数据里 type 可能缺失(卢广仲那条连 locale
	// 都没有),白名单会把这类合法别名一并误杀。
	Type string `json:"type"`
}

type mbArtistWithAliases struct {
	// Country 是这次收紧判定的关键字段(加,见 pickChineseAlias 注释)。
	Country string `json:"country"`
	// Name 是这位歌手在 MusicBrainz 上的**主名**(艺人页标题那个)。加,
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
// 不能只看"含汉字且 locale 不是 ja"就直接采纳第一条:这会把欧美艺人面向中文
// 市场的译名也当成规范名——Michael Jackson 在 MusicBrainz 上就有一条 `迈克尔·杰克逊`
// (locale=yue_Hans_CN、type=Artist name、primary=true),按这条判据会被误采纳。
//
// 判据只能用艺人所属地区(country),不能用别名自己的 type/primary:Michael Jackson
// 那条中文别名的 type 同样是 "Artist name"、primary 同样是 true,跟
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

// musicbrainzMinScore 是"认为搜索命中的确实是这个歌手"的置信度门槛——实测
// 坐实:精确/近似命中(比如"Crowd Lu"搜到盧廣仲本人)是 100 分,不相关的宽泛匹配(比如
// 按姓氏"Lu"单字搜到一堆不相关艺人)只有 50~56 分左右,90 留了一点余量但仍然足够严格,
// 避免把搜索词的宽泛匹配误认成确切命中。
const musicbrainzMinScore = 90

// lookupMusicBrainzChineseAlias 查一位歌手的中文名:按原始标签整体全文搜艺人(不加 artist:"..." 字段限定,
// 对夹杂罗马化拼音 / 英文艺名的搜索词召回更高),命中且置信度够高时再取这个艺人的别名列表,用 pickChineseAlias 挑。
// error 只回答「这一次查成没有」:没搜到、首条不够可信、没有合适的中文别名都是查成了的空结果(nil error),
// 可以缓存;请求本身没成才返回 error。
func lookupMusicBrainzChineseAlias(ctx context.Context, rawArtist string) (string, error) {
	var search mbSearchResponse
	if err := mbGetJSONShared(ctx, mbArtistSearchURL(rawArtist), &search); err != nil {
		return "", err
	}
	if len(search.Artists) == 0 {
		return "", nil
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return "", nil
	}

	var withAliases mbArtistWithAliases
	aliasURL := mbArtistAliasesURL(top.ID)
	if err := mbGetJSONShared(ctx, aliasURL, &withAliases); err != nil {
		return "", err
	}
	return pickChineseAlias(withAliases.Aliases, withAliases.Country), nil
}

// mbArtistSearchURL:按名字搜艺人的地址。几处按名字搜的都经这里拼,同一个名字拼出的地址逐字相同,
// 响应缓存(mbGetJSONShared)才共享得上。名字按 Lucene 语法转义:MusicBrainz 的 query 参数是 Lucene 查询,
// 「AC/DC」「(G)I-DLE」「P!nk」里的特殊字符不转义会改变查询语义,可能回 400(每次都被当成没问成、反复重试),
// 也可能首条命中别人。
func mbArtistSearchURL(name string) string {
	return "https://musicbrainz.org/ws/2/artist/?query=" + neturl.QueryEscape(mbLuceneEscape(name)) + "&fmt=json&limit=5"
}

// mbArtistAliasesURL:按 mbid 取主名、地区和别名的地址。几处都经这里拼,理由同 mbArtistSearchURL。
func mbArtistAliasesURL(mbid string) string {
	return "https://musicbrainz.org/ws/2/artist/" + neturl.PathEscape(mbid) + "?inc=aliases&fmt=json"
}

// mbLuceneEscape 在 Lucene 查询语法的特殊字符前加反斜杠。
func mbLuceneEscape(s string) string {
	const special = `+-&|!(){}[]^"~*?:\/`
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(special, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// ---- MB 主名:本名 与 艺名互换的通用解法 ----

var (
	mbPrimaryNameMu    sync.Mutex
	mbPrimaryNameCache = map[string][]string{}
	// mbLookupFailedUntil:"这位歌手刚刚没查成"的负缓存,歌手原始标签 → 退避到期时刻。
	// 跟 mbPrimaryNameCache 共用 mbPrimaryNameMu,不另开一把锁。
	mbLookupFailedUntil = map[string]time.Time{}
	mbPrimaryNamePath   string // 空 = 只用内存不持久化(单测/一次性子命令)
	mbPrimaryNameDirty  bool
)

// loadMBPrimaryNameCache/saveMBPrimaryNameCache 跟 loadArtistAliasCache 同一套持久化(整份 map 序列化、
// 临时文件 + 原子改名),只落盘查到了的条目,查空的只留在内存里:这条路径的失败几乎都是暂时的 ——
// MusicBrainz 按 IP 限速 1 req/s,而 musicbrainzThrottle 只管本进程,常驻引擎、手动搜索 CLI、测试进程各自计时,
// 谁都不知道别人刚打过,撞上限速就是 503、lookup 返回空。空值落盘会把这位歌手永久钉死在"没有别名"上,
// 而这条兜底是"所有源一条候选都没有"时的最后一招。
//
// 值是 []string(一个歌手可能有多个候选写法,见 musicBrainzArtistAliases)。旧格式文件的值是裸字符串
// (`{"Khalil Fong":"方大同"}`):新格式解码失败时按旧格式再试一次、每个字符串包成单元素切片;落盘只写新格式。
func loadMBPrimaryNameCache(path string) {
	mbPrimaryNamePath = path
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return
	}
	var m map[string][]string
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = m
		mbPrimaryNameMu.Unlock()
		noteCacheLoaded(path, fmt.Sprintf("%d MusicBrainz primary names", len(m)))
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
		noteCacheLoaded(path, fmt.Sprintf("%d MusicBrainz primary names (legacy format)", len(m)))
	}
}

func saveMBPrimaryNameCache() {
	mbPrimaryNameMu.Lock()
	if !mbPrimaryNameDirty || mbPrimaryNamePath == "" {
		mbPrimaryNameMu.Unlock()
		return
	}
	// 只序列化非空值,理由见 loadMBPrimaryNameCache。
	keep := make(map[string][]string, len(mbPrimaryNameCache))
	for k, v := range mbPrimaryNameCache {
		if len(v) > 0 {
			keep[k] = v
		}
	}
	path := mbPrimaryNamePath
	mbPrimaryNameDirty = false
	mbPrimaryNameMu.Unlock()
	mergeMissingFromDisk(path, keep, func(v []string) bool { return len(v) > 0 })
	data, err := json.Marshal(keep)
	if err != nil {
		return
	}
	if err := writeFileAtomic(path, data); err != nil {
		slog.Error("save musicbrainz primary name cache", "err", err)
	}
}

// mbLookupFailureTTL 是"刚刚没查成"的退避时长。短了收不住(别名轮一轮接一轮,几秒内就会再撞上来),
// 长了又会让一次偶发限速把这位歌手长时间钉在"没有别名"上。
//
// 跟"查空"分开处置:
//   - 查成了、但 MB 确实没登记别名(err == nil、resolved 为空)→ 写进内存缓存,本进程内不再查;
//     不落盘,换个进程还能再试(见 loadMBPrimaryNameCache)。
//   - 根本没查成(限速/5xx/超时)→ 内存缓存一个字都不写,只记这里的退避到期时刻。
const mbLookupFailureTTL = 10 * time.Minute

// mbLookupInFailureBackoff 报告这位歌手是不是还在"刚刚没查成"的退避窗口里。
func mbLookupInFailureBackoff(raw string, now time.Time) bool {
	mbPrimaryNameMu.Lock()
	defer mbPrimaryNameMu.Unlock()
	return now.Before(mbLookupFailedUntil[raw])
}

// noteMBLookupFailure 记下一次"没查成"。
//
// ctx 取消不算:那是用户主动取消了这次解析(enrichcancel.go),不是 MusicBrainz 的
// 毛病 —— 跟 lyricSourceBreaker.observeWith 里对 context.Canceled 的处理同一条理由。
// 记了的话,用户取消一次就让这位歌手白白退避 10 分钟。
func noteMBLookupFailure(raw string, err error, now time.Time) {
	if errors.Is(err, context.Canceled) {
		return
	}
	mbPrimaryNameMu.Lock()
	mbLookupFailedUntil[raw] = now.Add(mbLookupFailureTTL)
	mbPrimaryNameMu.Unlock()
}

// musicBrainzArtistAliases 给出"MusicBrainz 上这位歌手的其它已登记写法",仅当本地这个标签确实是同一位歌手
// 登记过的写法才给;够不到条件返回 nil。补的是「本名 ↔ 艺名」「中文名 ↔ 英文名」这类换名(Apple Music 标本名
// Abel Tesfaye、歌词源全按 The Weeknd 索引),见 09 章「检索前处理」的歌手别名重试。
//
// 不管搜到的主名是否等于本地标签,都取完整别名列表:主名恰好就是本地标签时(MB 把方大同的主名登记成「方大同」),
// 有用的写法(Khalil Fong)在别名列表里。候选判据见 mbAliasCandidatesForRetry。
//
// 缓存:查到的落盘(artist-primary-cache.json),查空的只留在内存,没查成的(限速/5xx/超时/ctx 取消)连内存都不写、
// 只记退避(mbLookupFailureTTL)。
func musicBrainzArtistAliases(ctx context.Context, rawArtist string) []string {
	aliases, _ := musicBrainzArtistAliasesChecked(ctx, rawArtist)
	return aliases
}

// errMBLookupBackoff:这位歌手刚刚没查成,还在 mbLookupFailureTTL 的退避窗口里,这次没发请求。
var errMBLookupBackoff = errors.New("musicbrainz: lookup in failure backoff")

// musicBrainzArtistAliasesChecked 同 musicBrainzArtistAliases,但把「没查成」如实报出来:
// err != nil = 这一刻不知道这位歌手有哪些别名(限速/5xx/超时/退避中),**不是**「没有别名」。
// 要据此下永久结论的调用方(Last.fm 编目匹配)必须区分这两种情况 —— 别名缺了就可能漏掉
// 真正的条目,拿残缺的候选集判出来的结论不能落盘。
func musicBrainzArtistAliasesChecked(ctx context.Context, rawArtist string) ([]string, error) {
	raw := strings.TrimSpace(rawArtist)
	if raw == "" {
		return nil, nil
	}
	mbPrimaryNameMu.Lock()
	if v, ok := mbPrimaryNameCache[raw]; ok {
		mbPrimaryNameMu.Unlock()
		return v, nil
	}
	mbPrimaryNameMu.Unlock()

	// 刚刚没查成的,在 mbLookupFailureTTL 内直接放弃:不发请求,也不排 musicbrainzThrottle 那把 1.1 秒的全局锁。
	// 这条路径挂在别名轮的构造阶段(enrich.go 的 retryArtistIdentities),MusicBrainz 持续限速时不退避的话,
	// 每一轮别名都会卡在那把锁上,直接计进等歌词的时间里。
	if mbLookupInFailureBackoff(raw, time.Now()) {
		return nil, errMBLookupBackoff
	}

	resolved, err := lookupMusicBrainzArtistAliases(ctx, raw)
	if err != nil {
		// 对方没答(限速/5xx/超时/ctx 取消)时连内存缓存都不写:那只说明这一刻没查成,不是这位歌手没有别的写法;
		// 写了的话一次偶发 503 就把他在常驻进程余下的生命周期里钉死成"无别名"。只记退避,每个 TTL 最多再查一次。
		noteMBLookupFailure(raw, err, time.Now())
		return nil, err
	}

	mbPrimaryNameMu.Lock()
	delete(mbLookupFailedUntil, raw) // 查成了就把退避记录清掉
	mbPrimaryNameCache[raw] = resolved
	// 查空不算脏 —— 空值不落盘,下一个进程还能再试一次(见 saveMBPrimaryNameCache)。
	if len(resolved) > 0 {
		mbPrimaryNameDirty = true
	}
	mbPrimaryNameMu.Unlock()
	saveMBPrimaryNameCache()
	return resolved, nil
}

// resolvedArtistCJKHint 给 isProbablyWrongLanguageLyrics 用,只读窥探
// artistAliasCache/mbPrimaryNameCache/qqArtistNameCache 这三份缓存——本次 resolve
// 链路里别的步骤(CanonicalArtist 解析走 canonicalArtistViaMusicBrainz/
// cachedQQArtistCanonicalName;别名重试走 retryArtistIdentities→
// musicBrainzArtistAliases/cachedQQArtistCanonicalName)有没有已经查到过这位歌手的
// 中文写法。
//
// 刻意不发起新的网络请求(不接受 ctx)——这个函数被 isProbablyWrongLanguageLyrics
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

// resolveGenericArtistCanonicalName 把一个罕见 / 罗马化的歌手标签换成本库惯用的中文或常用名。canonical_artist 兜底
// (resolveTrackEnrichment)和 Top 歌手榜归并(topartists.go 的 artistMergeNameKey / artistMergeDisplayName)共用这套顺序:
//
//  1. artistAliasTable(match.go)手工表:放在最前面,表里留的正是通用机制会查错人的案例(QQ 音乐搜「Wanting」
//     第一条是无关的「婉婷」),排在后面就轮不到它纠正。
//  2. canonicalArtistViaMusicBrainz:MusicBrainz 的中文别名(有 country 门槛,欧美艺人的中文译名不会被当成规范名,
//     见 pickChineseAlias)。
//  3. cachedQQArtistCanonicalName:QQ 音乐的歌手搜索建议,补 MusicBrainz 查不到或查错人的(david tao、lexie liu)。
//
// 不用 musicBrainzArtistAliases:它的返回值没有 country / locale,补不上 pickChineseAlias 那道门槛,直接当展示名
// 会把欧美艺人的中文译名带进来。这一层的结果直接写进展示字段,标准比别名重试轮严。调用方各自还有更强的信号
// 排在前面(enrich.go 先试网易云 / QQ 对这一首曲目的匹配结果)。
func resolveGenericArtistCanonicalName(ctx context.Context, rawArtist string) string {
	// 合唱串没有统一歌手名(理由同 canonicalArtistViaMusicBrainz),QQ 歌手搜索那一步也不问。
	if !expectsCanonicalArtist(rawArtist) {
		return ""
	}
	if v := knownArtistAlias(rawArtist); v != "" {
		return v
	}
	if v := canonicalArtistViaMusicBrainz(ctx, rawArtist); v != "" {
		return v
	}
	return cachedQQArtistCanonicalName(rawArtist)
}

// cachedGenericArtistCanonicalName 是 resolveGenericArtistCanonicalName 的只读缓存版：三步的
// 顺序与判据逐条相同，缓存不命中就当没有，不联网、不写缓存。两边改动必须同步。
func cachedGenericArtistCanonicalName(rawArtist string) string {
	if !expectsCanonicalArtist(rawArtist) {
		return ""
	}
	if v := knownArtistAlias(rawArtist); v != "" {
		return v
	}
	if v := cachedMusicBrainzCanonicalName(rawArtist); v != "" {
		return v
	}
	return qqArtistCanonicalNameFromCache(rawArtist)
}

// cachedMusicBrainzCanonicalName 只读 canonicalArtistViaMusicBrainz 的缓存，判据同它。
func cachedMusicBrainzCanonicalName(rawArtist string) string {
	rawArtist = strings.TrimSpace(rawArtist)
	if rawArtist == "" || containsHan(rawArtist) {
		return ""
	}
	artistAliasMu.Lock()
	defer artistAliasMu.Unlock()
	return artistAliasCache[rawArtist]
}

// lookupMusicBrainzArtistAliases 的 error 只回答"这一次查成没有":ctx 被取消、MB 超时/限速/5xx 都算没查成,
// 跟"查成了、MB 那边确实没登记别的写法"(返回 nil, nil)分开,上层据此决定写不写缓存(musicBrainzArtistAliasesChecked)。
func lookupMusicBrainzArtistAliases(ctx context.Context, raw string) ([]string, error) {
	var search mbSearchResponse
	if err := mbGetJSONShared(ctx, mbArtistSearchURL(raw), &search); err != nil {
		return nil, err
	}
	if len(search.Artists) == 0 {
		return nil, nil // 查成了,MB 那边没有这个人
	}
	top := search.Artists[0]
	if top.Score < musicbrainzMinScore {
		return nil, nil // 查成了,但首条命中不够可信
	}
	// 不再在这里因为"主名==本地标签"就提前返回,理由见函数头注——那个短路会让
	// 方大同这类"MB 主名本身就是本地标签"的歌手永远够不到下面的别名列表。
	var withAliases mbArtistWithAliases
	aliasURL := mbArtistAliasesURL(top.ID)
	if err := mbGetJSONShared(ctx, aliasURL, &withAliases); err != nil {
		return nil, err
	}
	primary := withAliases.Name
	if strings.TrimSpace(primary) == "" {
		primary = top.Name // 详情接口没给 name 时退回搜索结果里的那个
	}
	return mbAliasCandidatesForRetry(primary, withAliases.Aliases, raw), nil
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
//     `alias.Primary`:这个字段不可靠(The Weeknd 本人那条 "The Weeknd" 别名
//     primary=false,反而是从没用过的
//     日文别名 primary=true;硬按 primary 过滤会把真正该换的名字滤掉)。只排除
//     Legal name/Search hint:那两类不太可能是音乐平台索引用的写法,收进来大概率
//     白跑一轮网络请求,而 retryArtistIdentities 的上游调用方会对每个候选各发起一次
//     完整的全源搜索。
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
	body, err := mbGetBody(ctx, url)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

// mbGetBody 发一次 GET、返回 200 的响应体。不排 musicbrainzThrottle,调用方自己排。
func mbGetBody(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	// MusicBrainz 要求所有调用方在 User-Agent 里标明身份(应用名+版本+联系方式),不带
	// 这个头容易被限流/拒绝,见上面 Rate Limiting 文档链接。
	req.Header.Set("User-Agent", fmt.Sprintf("%s/%s (+https://github.com/Yudaotor/lyrimuse)", clientName, clientVersion))
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := doHTTPTracked(client, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusServiceUnavailable || resp.StatusCode == http.StatusTooManyRequests {
		// 按 IP 限速被拒:写进共享窗口,App 和其它引擎进程一起停手。
		publishSharedCooldown("musicbrainz.org", sharedCooldownMusicBrainz, time.Now().Add(musicbrainzPauseFor(resp.Header.Get("Retry-After"))))
	}
	if resp.StatusCode != http.StatusOK {
		return nil, &mbStatusError{url: url, status: resp.StatusCode}
	}
	return io.ReadAll(io.LimitReader(resp.Body, mbResponseMaxBytes))
}

// mbStatusError:MusicBrainz 回了非 200。带上状态码,调用方才分得清「确定没有」(404 / 400)和「这次没问成」(503、5xx)。
type mbStatusError struct {
	url    string
	status int
}

func (e *mbStatusError) Error() string {
	return fmt.Sprintf("musicbrainz %s: status %d", e.url, e.status)
}

// mbDefinitiveMiss:这次失败是 MusicBrainz 明确说「没有这个」(mbid 不存在 / 已失效是 404,请求本身不成立是 400)。
// 这种结论可以记下,重试也不会变;503 / 超时这类才该等会儿再问。
func mbDefinitiveMiss(err error) bool {
	var se *mbStatusError
	return errors.As(err, &se) && (se.status == http.StatusNotFound || se.status == http.StatusBadRequest)
}

// 歌手查询的响应缓存:同一个网址在 mbResponseTTL 内只真正请求一次。
//
// 找中文名(lookupMusicBrainzChineseAlias)和找别名(lookupMusicBrainzArtistAliases)对同一位
// 歌手发的是**完全相同**的两个请求(按名字搜、再取别名),而两条路径的结果缓存各管各的
// (artistAliasCache / mbPrimaryNameCache),互相用不上;MusicBrainz 限速 1.1 秒一次,
// 每位新歌手就白排两个队。两条路径都走 mbGetJSONShared,第二条直接拿第一条的响应。
// 见 11 章决策 33。
//
// 只存 200 的响应体;没查成的不存 —— 跟两条路径"没查成不写结果缓存"同一个口径,
// 一次偶发 503 不该在 TTL 内挡住重试。只在内存里,不落盘。
const (
	mbResponseTTL      = 30 * time.Minute
	mbResponseMaxItems = 256
	mbResponseMaxBytes = 4 << 20
)

type mbCachedResponse struct {
	body []byte
	at   time.Time
}

var (
	mbResponseMu    sync.Mutex
	mbResponseCache = map[string]mbCachedResponse{}
	// mbFetchBody 是真正发请求的那一步,单测替换它来数请求次数。
	mbFetchBody = mbGetBody
)

func mbCachedBody(url string, now time.Time) ([]byte, bool) {
	mbResponseMu.Lock()
	defer mbResponseMu.Unlock()
	c, ok := mbResponseCache[url]
	if !ok || now.Sub(c.at) >= mbResponseTTL {
		return nil, false
	}
	return c.body, true
}

// mbStoreBody 存一份响应。满了先清过期的,还满就丢最旧的那一条。
func mbStoreBody(url string, body []byte, now time.Time) {
	mbResponseMu.Lock()
	defer mbResponseMu.Unlock()
	if len(mbResponseCache) >= mbResponseMaxItems {
		oldestURL, oldestAt := "", now
		for u, c := range mbResponseCache {
			if now.Sub(c.at) >= mbResponseTTL {
				delete(mbResponseCache, u)
				continue
			}
			if c.at.Before(oldestAt) {
				oldestURL, oldestAt = u, c.at
			}
		}
		if len(mbResponseCache) >= mbResponseMaxItems && oldestURL != "" {
			delete(mbResponseCache, oldestURL)
		}
	}
	mbResponseCache[url] = mbCachedResponse{body: body, at: now}
}

// mbGetJSONShared:缓存命中就直接解码,不排 musicbrainzThrottle、不发请求;没命中才排队、
// 请求、解码成功后存下。排队时 ctx 被取消,返回的就是 ctx.Err()(跟直接调 musicbrainzThrottle
// 时一样)。
func mbGetJSONShared(ctx context.Context, url string, v any) error {
	if body, ok := mbCachedBody(url, time.Now()); ok {
		return json.Unmarshal(body, v)
	}
	if err := musicbrainzThrottle(ctx); err != nil {
		return err
	}
	body, err := mbFetchBody(ctx, url)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, v); err != nil {
		return err
	}
	mbStoreBody(url, body, time.Now())
	return nil
}
