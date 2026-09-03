package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 合唱串上送的「智能」档(features.LastfmScrobbleArtistMode == scrobbleArtistSmart):
// 拿 Last.fm 自己的编目当白名单,决定 "汪苏泷 & 荷莉" 这种合唱署名要不要在提交前收敛成
// 第一位艺人。
//
// # 为什么要有这一档
//
// 一条 scrobble 只能记一个艺人(Last.fm 版主原话:"cannot add one scrobble with a
// featured artist to both artists")。播放器报的 "A & B" 原样提交,匹配不到任何编目条目时
// Last.fm 会现场造一个只有你一个听众的"影子"艺人/曲目页——没有 mbid、没有专辑、时长 0。
// 结果不是"两个人都记上",而是**两个人都没记上**。「全部」档接受这个代价,「只发第一位」
// 档则会把 Hall & Oates、Michael Jackson & Janet Jackson(《Scream》在编目里就是合体条目、
// 带 mbid)这类正规署名也拆坏。这一档介于两者之间:**只对影子条目动手,对正规条目一个
// 字节都不动**。这跟 Last.fm 官方纠错规范(support.last.fm topic 197)第 9/10 条是同一个
// 判断:"Only map to such joint artist names if a full release exists under the joint
// name",拿不准时 "prefer mapping to the more prominently credited artist"。
//
// # 判定(两步,顺序即守卫)
//
//  1. 按原样的「合唱串 + 歌名」查一次 track.getInfo(autocorrect=1)。**已被编目收录**
//     (有 mbid,或听众数 ≥ lastfmCatalogListenersMin,或有时长)→ keep,原样发,永久。
//  2. 没收录,再查一次「第一位歌手 + 歌名」。**折叠目标已被收录** → collapse,发第一位,
//     永久;目标也没收录 → defer,维持原样,lastfmCollapseDeferRecheck 之后允许重查。
//
// 第 2 步是 2026-09-03 重做时新加的:原实现(2026-08-07 ~ 08-31)只做第 1 步,"查不到就折"
// —— 折进一个 Last.fm 也不认识的名字,等于把影子从合体页挪到单人页,收益不确定;更要紧的是
// 它是 firstCreditedArtist 之外的第二道防线:切错头(K/DA → K 那次真实事故)时,「K」名下
// 不会有这首歌被正规收录,第 2 步查不到,不折。
//
// # 为什么每首歌只判一次、结论永久
//
// 原实现按 30 天 TTL 重查,被删掉的理由之一就是"结果不可复现":听众数在阈值附近的条目会随
// 时间翻面,同一首歌两次运行发出不同的艺人名,而 scrobble 落进 Last.fm 基本删不掉。现在
// keep / collapse 一旦得出就不再重查——"已收录"不会变成"未收录",而"折过一次"之后再翻回
// 整串只会把用户自己的历史劈成两半。唯一允许重查的是 defer(两边都没收录):那是"暂时判不了"
// 而不是结论,目标条目以后被收录了就该折。要强制重判,删缓存文件(lastfmCollapsePath)。
//
// # 失败即维持原样、且不缓存
//
// 网络/限流/5xx/坏 JSON/非 "not found" 的 API 错误一律返回原串、不写缓存 —— 折叠不可逆,
// 默认行为必须是"维持现状";而一次偶发失败也不该把这条记录钉死。原实现就是这么做的,
// 删它时的"限流/超时会走进查不到分支"那条理由其实没成立,见 docs/features/12 §4。
//
// # now-playing 与 scrobble 的一致性
//
// 两条路径共用同一份缓存,同一首歌的第二次判定必然命中缓存,所以正常情况下两者发的是同一
// 个名字。**唯一**可能不一致的情形:now-playing 那次查询失败(维持原样、不缓存),几分钟后
// scrobble 那次查成功并判 collapse。此时以 scrobble 为准——它是永久记录,now-playing 只是
// 几分钟的瞬时状态;这是刻意的取舍,不是漏洞。
//
// # 预算
//
// 每次判定最多两个 GET,单个 lastfmCollapseProbeTimeout、合计 lastfmCollapseBudget;
// mirrorAsync 在智能档下把总窗口加大同样的量(mirrorTimeout),写入那 8 秒不被挤占。
// 结论永久缓存,同一首歌反复播放不再打网络。
const (
	// 无 mbid 时,听众数 ≥ 这个值视为编目里的正规条目。2026-08-07 实测:影子条目的听众数是
	// 1~180,编目里最冷门的正规合体条目(《Scream Louder (Flyte Tyme Remix)》)是 597 且带 mbid。
	lastfmCatalogListenersMin = 500
	// defer(两边都没收录)多久之后允许重查。keep / collapse 永不重查(见头注)。
	lastfmCollapseDeferRecheck = 90 * 24 * time.Hour
	// 一次判定(最多两个请求)的总预算。
	lastfmCollapseBudget = 6 * time.Second
	// 单个 track.getInfo 的上限。collector 直连(不走系统代理)实测 p50 0.4 s,4 s 够用;
	// 查不动时本来就退回"按原样提交",宁可判不出也不能把提交本身拖死。
	lastfmCollapseProbeTimeout = 4 * time.Second
)

// lastfmCollapsePath 由 main.go / backfillcli.go 跟其它落盘路径一起设置;空 = 不落盘(单测)。
var lastfmCollapsePath string

type collapseVerdict string

const (
	// 合唱串已被编目收录:原样发,永久。
	verdictKeep collapseVerdict = "keep"
	// 合唱串未收录、第一位歌手名下这首歌已收录:发第一位,永久。
	verdictCollapse collapseVerdict = "collapse"
	// 两边都未收录:暂维持原样,lastfmCollapseDeferRecheck 之后重查。
	verdictDefer collapseVerdict = "defer"
)

// lastfmCatalogProbe 是一次 track.getInfo 的判据留痕 —— 写进缓存文件是为了让人能事后
// 核对"当时为什么这么判",不参与之后的判断(结论一旦得出就按 Verdict 走)。
type lastfmCatalogProbe struct {
	// 200 且不是 "Track not found"。
	Found      bool   `json:"found"`
	MBID       string `json:"mbid,omitempty"`
	Listeners  int    `json:"listeners"`
	DurationMS int    `json:"duration_ms"`
}

// catalogued 判"这是编目里的正规条目"。三个信号任一成立即可 —— 都是影子条目不会有的东西:
// mbid 来自 MusicBrainz 关联,时长来自编目元数据(scrobble 带的 duration 参数不会写进编目),
// 听众数够多说明不是一两个人的私有写法。
func (p lastfmCatalogProbe) catalogued() bool {
	return p.Found && (p.MBID != "" || p.Listeners >= lastfmCatalogListenersMin || p.DurationMS > 0)
}

type lastfmCollapseDecision struct {
	Verdict collapseVerdict `json:"verdict"`
	// Artist 是判定后应该提交的艺人名(keep/defer = 原串,collapse = 第一位)。
	Artist string `json:"artist"`
	TS     int64  `json:"ts"`
	// 判据留痕,只写不读。
	Joint   *lastfmCatalogProbe `json:"joint,omitempty"`
	Primary *lastfmCatalogProbe `json:"primary,omitempty"`
}

// lastfmArtistCollapser 按上面的判据决定一条 scrobble 该用哪个艺人名。
// 缓存键是 "艺人串\n歌名" —— 收录情况是**按曲目**的,同一个合唱串在不同歌上完全可能一个是
// 正规条目、一个是影子条目,不能只按艺人名缓存。
type lastfmArtistCollapser struct {
	apiKey  string // 只读用的 api_key:track.getInfo 不需要签名/session key
	baseURL string // 可注入,单测用;空则用 Last.fm 正式端点
	hc      *http.Client

	mu    sync.Mutex
	cache map[string]lastfmCollapseDecision
}

func newLastfmArtistCollapser(apiKey string) *lastfmArtistCollapser {
	if apiKey == "" {
		return nil
	}
	c := &lastfmArtistCollapser{
		apiKey: apiKey,
		hc:     &http.Client{Timeout: lastfmCollapseProbeTimeout},
		cache:  map[string]lastfmCollapseDecision{},
	}
	c.load()
	return c
}

// resolve 返回这条提交应该用的艺人名。任何一步不确定都返回原串 —— 折叠不可逆,默认行为
// 必须是"维持现状"。nil 接收者(没配只读 api_key)整体退化成原样返回。
func (c *lastfmArtistCollapser) resolve(ctx context.Context, artist, track string) string {
	if c == nil {
		return artist
	}
	trimmed := strings.TrimSpace(artist)
	if trimmed == "" || strings.TrimSpace(track) == "" {
		return artist
	}
	// 不是合唱串(切不出第二段,含 "周杰伦、" 这种结尾带分隔符的单人名、以及 K/DA 这种
	// 头部不像名字的 `/`)就直接返回,不打网络。firstCreditedArtist 切不开时返回原串本身。
	primary := firstCreditedArtist(trimmed)
	if primary == "" || primary == trimmed {
		return artist
	}

	key := trimmed + "\n" + track
	if d, ok := c.lookup(key, time.Now()); ok {
		return d.Artist
	}

	ctx, cancel := context.WithTimeout(ctx, lastfmCollapseBudget)
	defer cancel()
	joint, err := c.probe(ctx, trimmed, track)
	if err != nil {
		// 查不动(限流/网络/Last.fm 抽风)时不缓存也不折叠:下次再判,别把一次偶发失败
		// 变成一个永久的错误决定。
		log.Printf("lastfm smart artist: lookup %q / %q failed: %v (keeping as-is, not cached)", trimmed, track, err)
		return artist
	}
	if joint.catalogued() {
		c.store(key, lastfmCollapseDecision{Verdict: verdictKeep, Artist: trimmed, Joint: &joint})
		log.Printf("lastfm smart artist: keep %q / %q (joint credit is catalogued: %s)", trimmed, track, joint.summary())
		return trimmed
	}
	target, err := c.probe(ctx, primary, track)
	if err != nil {
		log.Printf("lastfm smart artist: target lookup %q / %q failed: %v (keeping as-is, not cached)", primary, track, err)
		return artist
	}
	if target.catalogued() {
		c.store(key, lastfmCollapseDecision{Verdict: verdictCollapse, Artist: primary, Joint: &joint, Primary: &target})
		log.Printf("lastfm smart artist: %q -> %q for %q (joint credit not catalogued: %s; target catalogued: %s)",
			trimmed, primary, track, joint.summary(), target.summary())
		return primary
	}
	c.store(key, lastfmCollapseDecision{Verdict: verdictDefer, Artist: trimmed, Joint: &joint, Primary: &target})
	log.Printf("lastfm smart artist: defer %q / %q (neither joint nor %q is catalogued; keeping as-is, recheck after %s)",
		trimmed, track, primary, lastfmCollapseDeferRecheck)
	return trimmed
}

func (p lastfmCatalogProbe) summary() string {
	if !p.Found {
		return "not found"
	}
	return fmt.Sprintf("mbid=%q listeners=%d duration_ms=%d", p.MBID, p.Listeners, p.DurationMS)
}

// probe 查一次「艺人 + 歌名」在 Last.fm 编目里的收录情况。返回 error 表示**没查成**(网络、
// 限流、5xx、坏 JSON、非 not-found 的 API 错误),调用方必须当"不知道"处理;"Track not found"
// 是确定的答案(Found=false),不是错误。
func (c *lastfmArtistCollapser) probe(ctx context.Context, artist, track string) (lastfmCatalogProbe, error) {
	q := neturl.Values{}
	q.Set("method", "track.getInfo")
	q.Set("api_key", c.apiKey)
	q.Set("format", "json")
	q.Set("artist", artist)
	q.Set("track", track)
	// autocorrect=1 让 Last.fm 先套一遍它自己的纠错表再查 —— 纠错后能命中正规条目的就不该
	// 被我们再折叠一次(提交时 Last.fm 会套同一张表,落点一样)。
	q.Set("autocorrect", "1")

	base := c.baseURL
	if base == "" {
		base = "https://ws.audioscrobbler.com/2.0/"
	}
	ctx, cancel := context.WithTimeout(ctx, lastfmCollapseProbeTimeout)
	defer cancel()
	// ⚠️ 不用 q.Encode():Last.fm 的 GET 端点会对 query value 多解一次码,含加号的歌名走标准
	// 编码必然 error 6 —— 而这里 error 6 的语义正是"没收录 → 可能折叠",查错了就是把正规合体
	// 署名折坏(2026-08-22 真实事故,见 lastfmGetQuery)。
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+lastfmGetQuery(q), nil)
	if err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("build request: %w", err)
	}
	resp, err := doHTTPTracked(c.hc, req)
	if err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("get track info: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		Track struct {
			MBID      string `json:"mbid"`
			Listeners string `json:"listeners"`
			Duration  string `json:"duration"`
		} `json:"track"`
		Error   int    `json:"error"`
		Message string `json:"message"`
	}
	// 先解 body 再看状态码:Last.fm 的 API 错误多以 200 + {"error":N} 返回,偶尔也带 4xx;
	// 两种形态下 "Track not found" 都是确定答案,其余非 200 才是"没查成"。
	decodeErr := json.NewDecoder(resp.Body).Decode(&body)
	if body.Error == 6 && strings.Contains(strings.ToLower(body.Message), "not found") {
		return lastfmCatalogProbe{Found: false}, nil
	}
	if resp.StatusCode != http.StatusOK {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo status %d", resp.StatusCode)
	}
	if decodeErr != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("decode track.getInfo: %w", decodeErr)
	}
	if body.Error != 0 {
		// 其它 error 6(参数问题)、29(限流)、8/11/16(服务端)…都不是"没收录",不能当结论用。
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo error %d: %s", body.Error, body.Message)
	}
	p := lastfmCatalogProbe{Found: true, MBID: body.Track.MBID}
	// 听众数/时长:字段缺失按 0(Last.fm 对影子条目就是这么给的);字段**在但解析不出**
	// 说明应答形态跟预期不符,信号不可信 —— 当"没查成",不缓存。这两个数字是判"收录"的
	// 依据,读错了偏向的是折叠(0 → 像影子),而折叠不可逆,宁可这一次判不出。
	if p.Listeners, err = atoiOrZero(body.Track.Listeners); err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo listeners %q: %w", body.Track.Listeners, err)
	}
	if p.DurationMS, err = atoiOrZero(body.Track.Duration); err != nil {
		return lastfmCatalogProbe{}, fmt.Errorf("track.getInfo duration %q: %w", body.Track.Duration, err)
	}
	return p, nil
}

// atoiOrZero:空串 → 0,nil;其余必须是整数。
func atoiOrZero(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	return strconv.Atoi(s)
}

// lookup 只认三个已知 verdict;defer 到期、或老格式/损坏条目(没有 verdict)都当未命中重查。
func (c *lastfmArtistCollapser) lookup(key string, now time.Time) (lastfmCollapseDecision, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d, ok := c.cache[key]
	if !ok {
		return d, false
	}
	switch d.Verdict {
	case verdictKeep, verdictCollapse:
		return d, true
	case verdictDefer:
		return d, now.Sub(time.Unix(d.TS, 0)) <= lastfmCollapseDeferRecheck
	default:
		return d, false
	}
}

func (c *lastfmArtistCollapser) store(key string, d lastfmCollapseDecision) {
	d.TS = time.Now().Unix()
	c.mu.Lock()
	c.cache[key] = d
	snapshot := make(map[string]lastfmCollapseDecision, len(c.cache))
	for k, v := range c.cache {
		snapshot[k] = v
	}
	c.mu.Unlock()
	c.save(snapshot)
}

func (c *lastfmArtistCollapser) load() {
	if lastfmCollapsePath == "" {
		return
	}
	data, err := os.ReadFile(lastfmCollapsePath)
	if err != nil {
		return // 首次运行没有这个文件是正常的
	}
	var m map[string]lastfmCollapseDecision
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("lastfm smart artist: cache unreadable, starting empty: %v", err)
		return
	}
	// 2026-08 的老格式条目没有 verdict(那版按 30 天 TTL 重查),不认、丢掉重判 —— 那批判定
	// 只做了第 1 步,没有目标核查,不能直接升格成永久结论。
	for k, d := range m {
		switch d.Verdict {
		case verdictKeep, verdictCollapse, verdictDefer:
		default:
			delete(m, k)
		}
	}
	c.mu.Lock()
	c.cache = m
	c.mu.Unlock()
}

func (c *lastfmArtistCollapser) save(snapshot map[string]lastfmCollapseDecision) {
	if lastfmCollapsePath == "" {
		return
	}
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		log.Printf("lastfm smart artist: marshal cache: %v", err)
		return
	}
	// 先写临时文件再 rename,跟 saveEnrichCache 同一个理由(半截文件不能被下次读到);
	// 临时名带 pid,免得常驻 collector 和 backfill 子命令互相覆盖。
	tmp := fmt.Sprintf("%s.tmp.%d", lastfmCollapsePath, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		log.Printf("lastfm smart artist: write cache: %v", err)
		return
	}
	if err := os.Rename(tmp, lastfmCollapsePath); err != nil {
		log.Printf("lastfm smart artist: rename cache: %v", err)
		_ = os.Remove(tmp)
	}
}
