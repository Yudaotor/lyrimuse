// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"encoding/json"
	"net/http"
	neturl "net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// topArtistsCheckInterval：网页这块内容不需要实时,一天检查一次即可,省掉绝大多数
// 没意义的 Last.fm/Deezer 调用——不用像 weeklyDigestCheckInterval(2小时)那么勤。
const topArtistsCheckInterval = 24 * time.Hour

// topArtistsN 是最终展示的歌手数量,跟网页这次要展示的"Top10"直接对应。
const topArtistsN = 10

// topArtistsFetchPool：向 Last.fm 实际拉取的原始条目数,明显比 topArtistsN 多——同一个
// 真人有时会因为 Apple Music 标签用了不同的艺名写法(英文/罗马化 vs 中文舞台名,比如
// "Dean Ting"跟"丁世光",见 match.go 的 artistAliasTable)在 Last.fm 的统计里被计成两个
// "不同的歌手",归并去重(见 mergeAliasedArtists)之后条目会变少,不多拉一些池子就可能
// 凑不满 10 个。30 是"这个人的库大概率不会有 3 组以上这类别名同时挤在前 30"的经验值,
// 不做成动态"不够 10 个就再多拉一批"——真的出现这种极端情况,少于 10 个直接展示即可,
// 不值得为这个边界多一层复杂度。
const topArtistsFetchPool = 30

var topArtistsStatePath string

// topArtistsState 持久化"上次成功推送的时间戳",防重启后(内存态
// topArtistsLastCheckedAt 丢失)在同一天内重复计算——Deezer 的搜索接口没有公开的配额
// 说明,但仍按"能少查就少查"处理。跟 weeklyDigestState 是同一个持久化模式,这里存的是
// unix 秒而不是"已推送到哪一周"的边界值,故不复用同一个类型。
type topArtistsState struct{ path string }

func (s topArtistsState) load() int64 {
	if s.path == "" {
		return 0
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return 0
	}
	var v struct {
		LastAt int64 `json:"last_at"`
	}
	json.Unmarshal(b, &v)
	return v.LastAt
}

func (s topArtistsState) save(at int64) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastAt int64 `json:"last_at"`
	}{at})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

// topArtistEntry 是要推给网页的一条记录,只留展示要用的字段。
type topArtistEntry struct {
	Name      string `json:"name"`
	PlayCount int    `json:"playCount"`
	Avatar    string `json:"avatar"`
}

// lastfmTopArtists 拉指定用户的全时段(period=overall)Top N 歌手榜——跟 weekly.go 的
// lastfmWeeklyTopArtists 是姐妹接口(同一个 user.get*Chart 系列 API),复用同一个
// lastfmAPIGet helper,不用另起一套 HTTP 调用逻辑。
func lastfmTopArtists(ctx context.Context, user, apiKey string, limit int) ([]lastfmChartEntry, error) {
	return lastfmTopArtistsPeriod(ctx, user, apiKey, "overall", limit)
}

// lastfmTopArtistsPeriod 是带时段参数的版本 —— top-artists CLI 子命令(App 的 Last.fm
// 信息页)要按 7day/1month/12month/overall 查,原有的网页推送调用方固定用 overall。
func lastfmTopArtistsPeriod(ctx context.Context, user, apiKey, period string, limit int) ([]lastfmChartEntry, error) {
	var out struct {
		TopArtists struct {
			Artist []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Mbid      string `json:"mbid"`
			} `json:"artist"`
		} `json:"topartists"`
	}
	params := neturl.Values{
		"method": {"user.getTopArtists"}, "user": {user}, "api_key": {apiKey},
		"period": {period}, "limit": {strconv.Itoa(limit)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.TopArtists.Artist))
	for _, a := range out.TopArtists.Artist {
		pc, _ := strconv.Atoi(a.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: a.Name, PlayCount: pc, Mbid: a.Mbid})
	}
	return entries, nil
}

// artistMergeNameKey 算"归并判定用"的归一化字符串——简繁、中英文艺名、多人合唱都要
// 能判定成同一个人:
//  1. firstCreditedArtist:多人合credit(如"Prince & The Revolution")先取第一位,
//     不单独占一个歌手名额;
//  2. resolveGenericArtistCanonicalName(musicbrainz.go):已知的英文/罗马化艺名换成
//     本库常用中文名(比如"Dean Ting"→"丁世光")——2026-08-31 起从只查
//     knownArtistAlias(match.go 的 artistAliasTable)改成先试 MusicBrainz/QQ 音乐
//     两条通用机制,只有两条都查不到才落到手工表那两条真实残留案例,见其头注;
//  3. toSimplified:繁体折成简体(比如"周杰倫"和"周杰伦"折成同一个键);
//  4. 大小写折叠。
//
// 四步做完算出的字符串一致就判定是同一个人。
//
// ⚠️ 这是一次性批处理脚本(一天跑一次),不是打分热路径,可以放心让
// resolveGenericArtistCanonicalName 在缓存不命中时发起真实网络请求——不像
// isProbablyWrongLanguageLyrics 那样需要 resolvedArtistCJKHint 的纯读缓存约束。
func artistMergeNameKey(name string) string {
	first := firstCreditedArtist(name)
	if alias := resolveGenericArtistCanonicalName(context.Background(), first); alias != "" {
		first = alias
	}
	return strings.ToLower(toSimplified(first))
}

// artistMergeDisplayName 是展示用的名字——只做"已知别名换成中文名"这一步,不做
// toSimplified/大小写折叠:那两步只是"判断是否同一个人"内部用的归一化,不代表要悄悄篡改
// 这个人在库里原本的书写(繁体来源就展示繁体,不强制转简体)。
//
// ⚠️ 2026-08-17 去掉了原来第一步的 firstCreditedArtist(从合credit 串里猜第一个歌手)。
// 那一步会**凭空造出一个数据里根本没出现过的名字**:`firstCreditedArtist` 按分隔符切段,
// 而 `/` 既是常见分隔符、又可能是人名自身的一部分,于是 "K/DA" 被切成 ["K","DA"]、
// 显示成 **"K"** —— 一个不存在的歌手。实测(用户报):Top 榜里 "K/DA" 和
// "K/DA/Madison Beer/(G)I-DLE/Jaira Burns" 的**合并本身是对的**(两者的 nameKey 都塌缩
// 成 "k",次数正确相加),错的只有这个显示名。
//
// 现在的做法见 mergeAliasedArtists:显示名从**这一桶里真实出现过的成员名字**里挑
// (合credit 段数最少的那个),不再猜。合credit 串"不单独占一个歌手名额"这个目的由
// artistMergeNameKey(合并键)承担,跟显示名是两件事,那边照旧。
func artistMergeDisplayName(name string) string {
	if alias := resolveGenericArtistCanonicalName(context.Background(), name); alias != "" {
		return alias
	}
	return name
}

// mergeAliasedArtists 把 Last.fm 统计里"同一个真人被拆成多条"的记录合并成一条,播放
// 次数相加。单一手段(只按名字键比较)覆盖不全——有些记录解析不出 mbid、有些又不在
// artistAliasTable 里,所以用两个信号一起判断"是不是同一个人",任一信号命中就合并
// (并查集,允许链式传递:比如 A/B 因名字键相同合并、B/C 又因 mbid 相同合并,最终
// A/B/C 都算一个人):
//  1. artistMergeNameKey 相同(见其注释:合唱取第一位+已知别名+繁简折叠+大小写折叠);
//  2. Last.fm 自己解析出的 mbid(MusicBrainz ID)相同——是服务端自己的艺人身份归并
//     结果,能兜住名字键这条路径抓不到的情况,但不能替代名字键匹配——mbid 不是每条
//     记录都有。
//
// 合并后按播放次数重新降序排列——合并可能改变名次,比如两条各自排第 6/7 名,合并后播放
// 次数相加就可能前移到第 4 名。
// artistIdentityFn 把一个歌手名解析成 MusicBrainz 身份(mbid+中文名)。归并逻辑通过它
// 拿第三个合并信号,不关心背后是缓存还是联网——单测注入假函数,生产两档见
// cacheOnlyArtistIdentity / budgetedArtistIdentity。
type artistIdentityFn func(name, knownMbid string) mbArtistIdentity

// cacheOnlyArtistIdentity 只读缓存、绝不联网——给所有对延迟敏感的调用方
// (poll 循环里的 topArtistsDigest、App 统计页背后的 CLI 默认档)。缓存由
// warmArtistIdentityCache / 带预算的手动导出慢慢填,归并逐日收敛。
func cacheOnlyArtistIdentity(name, _ string) mbArtistIdentity {
	id, _ := cachedArtistIdentity(strings.TrimSpace(name))
	return id
}

// budgetedArtistIdentity 允许最多 budget 个**未缓存**名字走真实 MusicBrainz 解析
// (每个 ≤2 次请求、全局 1.1s 限速),超出预算的这一轮只吃缓存。并发安全:CLI 的
// -all-periods 模式四个时段共享同一份预算。
func budgetedArtistIdentity(budget int) artistIdentityFn {
	var mu sync.Mutex
	remaining := budget
	return func(name, knownMbid string) mbArtistIdentity {
		name = strings.TrimSpace(name)
		if name == "" {
			return mbArtistIdentity{}
		}
		if id, ok := cachedArtistIdentity(name); ok {
			return id
		}
		mu.Lock()
		if remaining <= 0 {
			mu.Unlock()
			return mbArtistIdentity{}
		}
		remaining--
		mu.Unlock()
		return resolveArtistIdentityMB(name, knownMbid)
	}
}

// warmArtistIdentityCache 后台预热身份缓存:按榜单顺序(播放次数降序,高频歌手优先)
// 解析前 budget 个未缓存的名字并落盘。给 topArtistsDigest 用——它在 poll 循环里同步跑,
// 绝不能被 MusicBrainz 限速卡住(每个名字最多 2×1.1s),所以归并本体只读缓存,预热放
// goroutine 里慢慢做,次日的归并自然吃到。
func warmArtistIdentityCache(entries []lastfmChartEntry, budget int) {
	resolve := budgetedArtistIdentity(budget)
	for _, e := range entries {
		first := firstCreditedArtist(e.Name)
		mbid := ""
		if strings.EqualFold(strings.TrimSpace(first), strings.TrimSpace(e.Name)) {
			// Last.fm 的 mbid 属于整条 credit 串;只有单人条目才能把它当作
			// 这个名字的已知身份传下去,合唱串的 mbid 不属于第一位歌手。
			mbid = e.Mbid
		}
		resolve(first, mbid)
	}
	saveArtistIdentityCache()
}

func mergeAliasedArtists(entries []lastfmChartEntry) []lastfmChartEntry {
	return mergeAliasedArtistsResolved(entries, cacheOnlyArtistIdentity)
}

func mergeAliasedArtistsResolved(entries []lastfmChartEntry, resolve artistIdentityFn) []lastfmChartEntry {
	n := len(entries)
	nameKeys := make([]string, n)
	ids := make([]mbArtistIdentity, n)
	for i, e := range entries {
		nameKeys[i] = artistMergeNameKey(e.Name)
		first := firstCreditedArtist(e.Name)
		mbid := ""
		if strings.EqualFold(strings.TrimSpace(first), strings.TrimSpace(e.Name)) {
			mbid = e.Mbid // 理由见 warmArtistIdentityCache 里同款判断
		}
		ids[i] = resolve(first, mbid)
	}

	parent := make([]int, n)
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(x int) int {
		for parent[x] != x {
			parent[x] = parent[parent[x]]
			x = parent[x]
		}
		return x
	}
	union := func(a, b int) {
		if ra, rb := find(a), find(b); ra != rb {
			parent[ra] = rb
		}
	}
	// 三个信号,任一相同即并(链式传递):①名字键(合唱取第一位+别名表+繁简+大小写);
	// ②mbid——Last.fm 自带的,或身份解析补上的("Leah Dou"和"窦靖童"名字键连不上、
	// Last.fm 只给了一边 mbid,只有两边都解析到同一个 MusicBrainz 艺人才并得上);
	// ③解析出的中文名的名字键——兜"A 解析出中文名、B 本来就用中文名"的组合。
	groups := map[string][]int{}
	addKey := func(k string, i int) {
		if k != "" {
			groups[k] = append(groups[k], i)
		}
	}
	for i, e := range entries {
		if nameKeys[i] != "" {
			addKey("n:"+nameKeys[i], i)
		}
		mbid := e.Mbid
		if mbid == "" {
			mbid = ids[i].Mbid
		}
		if mbid != "" {
			addKey("m:"+mbid, i)
		}
		if ids[i].Zh != "" {
			addKey("n:"+strings.ToLower(toSimplified(ids[i].Zh)), i)
		}
	}
	for _, idxs := range groups {
		for k := 1; k < len(idxs); k++ {
			union(idxs[0], idxs[k])
		}
	}

	// 每一桶的显示名从**桶里真实出现过的成员名字**里挑,挑"合credit 段数最少"的那个:
	// 同一个人常常同时以"本名"和"某首合唱的完整 credit 串"两种形态出现在榜单里
	// ("K/DA" 和 "K/DA/Madison Beer/(G)I-DLE/Jaira Burns"),段数最少的那个就是本名。
	// 段数相同就保持先遇到的那个 —— 输入按播放次数降序,等于取次数更多的那份写法。
	//
	// ⚠️ 刻意**不**从字符串里猜第一个歌手(原来 artistMergeDisplayName 干的事,见那边
	// 注释):`/` 既是分隔符又可能是人名的一部分,猜出来的 "K" 是个数据里不存在的名字。
	// 从成员里挑最坏情况也只是显示一个完整的合credit 串(那一桶里恰好没有本名条目时),
	// 而那至少是真实出现过的写法。
	type bucket struct {
		name      string
		nameParts int    // 上面那个名字的 artistCreditParts 段数,用来比较谁更像"本名"
		hanName   string // 桶里第一个(=播放最多的)单人中文成员名,见下面挑选注释
		zh        string // 身份解析给出的中文名(桶里没有任何中文成员名时的显示兜底)
		playCount int
	}
	buckets := make(map[int]*bucket, n)
	order := make([]int, 0, n)
	for i, e := range entries {
		root := find(i)
		display := artistMergeDisplayName(e.Name)
		parts := len(artistCreditParts(e.Name))
		b, ok := buckets[root]
		if !ok {
			b = &bucket{name: display, nameParts: parts}
			buckets[root] = b
			order = append(order, root)
		} else if parts < b.nameParts {
			b.name, b.nameParts = display, parts
		}
		// 中文成员名单独一条挑选轨:这个库的主体是华语音乐,同一个人有中文写法时
		// 中文就是"本库常用名"(2026-08-18 用户核对 Top100 的直接反馈——"窦靖童"和
		// "Leah Dou"合并后该显示前者)。⚠️ 只认**单人**写法(credit 段数 1):不加这个
		// 限制,"Michael Jackson"会被桶里一条 2 次播放的"Michael Jackson & 克里夫兰
		// 管弦乐团"顶掉——含汉字的合唱串说明不了这个人常用中文名,只说明某张发行的
		// 合作方是中文写法(首版实测翻车)。平手先到者(=播放多的写法)优先。
		if parts == 1 && containsHan(display) && b.hanName == "" {
			b.hanName = display
		}
		if b.zh == "" && ids[i].Zh != "" {
			b.zh = ids[i].Zh
		}
		b.playCount += e.PlayCount
	}

	out := make([]lastfmChartEntry, 0, len(order))
	for _, root := range order {
		b := buckets[root]
		name := b.name
		// 显示名优先级:桶里真实出现过的中文成员名 > 身份解析的中文名(桶里全是罗马
		// 写法时,如 "Ronghao Li"→"李荣浩") > 主轨挑出的名字。
		if b.hanName != "" {
			name = b.hanName
		} else if b.zh != "" {
			name = b.zh
		}
		out = append(out, lastfmChartEntry{Name: name, PlayCount: b.playCount})
	}
	// SliceStable:平分的歌手保持合并前的相对次序(合并前列表来自 Last.fm,本身有序),
	// sort.Slice 的不稳定性会让平分名次每次刷新随机跳(审阅指出)。
	sort.SliceStable(out, func(i, j int) bool { return out[i].PlayCount > out[j].PlayCount })
	return out
}

// resolveArtistAvatar 给一个歌手名找头像图——优先 QQ 音乐(qqSingerAvatar,这个项目
// 给中文内容一贯优先选的服务,免认证、且中英文歌手都有覆盖),查不到才退到 Deezer
// (deezerArtistAvatar)。Apple Music 官方头像数据只有付费 Apple Developer 账号才能
// 拿到的 MusicKit 目录 API 才有(这个项目一直用免费的 iTunes Search API 查预览/封面,
// 那个接口的 musicArtist 类型结果没有任何图片字段),引入 MusicKit 需要新增付费开发者
// 账号+JWT 签名基建,成本明显高于收益,未采用。
// 返回 (URL, definitive):definitive=true 表示"这是可负缓存的确定结论"(找到了,或
// 两条腿都正常应答且都说没有);false 表示至少一条腿是暂时故障,空结果不可信。
func resolveArtistAvatar(ctx context.Context, name string) (string, bool) {
	qqPic, qqDef := qqSingerAvatar(name)
	if qqPic != "" {
		return qqPic, true
	}
	dzPic, dzDef := deezerArtistAvatar(ctx, name)
	if dzPic != "" {
		return dzPic, true
	}
	// 两条腿都空:只有两边都是"正常应答查无此人"才算可负缓存的确定结论
	return "", qqDef && dzDef
}

// deezerArtistAvatar 查 Deezer 的公开歌手搜索接口拿一张头像图——Last.fm 自己的
// artist.getinfo 对所有歌手都返回同一张占位图,拿不到真实头像,而 Deezer 的
// search/artist 不需要认证、且是按歌手实际区分的真实图片。查不到/查失败时返回空
// 字符串——调用方不应该因为单个歌手查图失败就放弃整批数据,前端对空头像也有兜底展示。
// 现在是 resolveArtistAvatar 查不到 QQ 音乐头像时的兜底,不再是首选。
// 返回 (URL, definitive),语义同 qqSingerAvatar:false = 暂时故障,不可负缓存。
func deezerArtistAvatar(ctx context.Context, name string) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	u := "https://api.deezer.com/search/artist?limit=1&q=" + neturl.QueryEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", false
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var out struct {
		Data []struct {
			PictureMedium string `json:"picture_medium"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", false
	}
	if len(out.Data) == 0 {
		return "", true // 服务端明确说查无此人
	}
	return out.Data[0].PictureMedium, true
}

// topArtistsDigest 检查(至多每 topArtistsCheckInterval 一次)要不要重新计算"历史播放
// Top10歌手"并推给状态中继——这块内容不需要实时,所以挂在跟 weeklyDigest 同样的
// poll() 尾部、但用一个大得多的检查间隔,不会增加正常轮询的开销。复用跟 weeklyDigest
// 同一套 Last.fm 凭证,没配置就整体跳过;还要求 StateRelayURL 已配置(数据要推给网页读
// 的中继,没配这个推了也没地方读)。
func (p *poller) topArtistsDigest(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.lastfmBridgeAPIKey() == "" || p.cfg.StateRelayURL == "" {
		return
	}
	if !p.topArtistsLastCheckedAt.IsZero() && now.Sub(p.topArtistsLastCheckedAt) < topArtistsCheckInterval {
		return
	}
	p.topArtistsLastCheckedAt = now
	if last := p.topArtistsState.load(); last > 0 && now.Sub(time.Unix(last, 0)) < topArtistsCheckInterval {
		return // 磁盘上记录的上次成功推送还没满一天(比如刚重启,内存态丢了但磁盘状态还在)
	}

	entries, err := lastfmTopArtists(p.ctx, p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey(), topArtistsFetchPool)
	if err != nil || len(entries) == 0 {
		return
	}
	// 身份缓存预热放后台:这个函数在 poll 循环里**同步**跑(见下面头像那段注释),
	// MusicBrainz 全局 1.1s 限速、整池预热要 ~1 分钟,绝不能在这里等。归并本体只读
	// 缓存,今天没预热到的名字明天这一轮自然吃到——榜单一天才推一次,晚一天收敛无感。
	go warmArtistIdentityCache(entries, topArtistsFetchPool)
	merged := mergeAliasedArtists(entries)
	if len(merged) > topArtistsN {
		merged = merged[:topArtistsN]
	}
	// 头像并发取,不要串行。topArtistsDigest 是在轮询循环里**同步**调用的
	// (见 poller.go 里 p.topArtistsDigest(now) 那一行),而 resolveArtistAvatar 每次都是
	// 真实网络请求(先 QQ 音乐、失败再 Deezer)。串行 10 个的话,这一轮 poll 会被卡住十次
	// 网络往返的总时长 —— 期间这个 collector 什么都察觉不到:换歌、暂停、seek 都发现不了,
	// 刚开始播的那首也补不上元数据。(歌词行本身不会停:App 侧有自己的 20Hz fastTick,网页
	// 那边按最后一个锚点外推,所以这是"检测停摆"而不是"画面冻住"。)
	//
	// 成功路径下它至多一天跑一次:进程内的 topArtistsLastCheckedAt 是主节流,topArtistsState
	// 只是重启后的兜底。而 save() 只在 postRelay 成功之后才写(见下面),推送失败就没有时间戳
	// 落盘 —— 同一天再重启一次(每次保存 features 都会 kickstart collector,很常见)就会把这
	// 十次取头像重跑一遍。哪条路径下,那一次卡顿都是用户能直接感觉到的。
	//
	// 并发度压到 4 而不是全放开:这两个都是别人的公开接口,10 个请求同时砸过去没有必要,
	// 4 路已经把总耗时压到约四分之一。顺序必须保持(展示的是 Top10 排名),所以按下标写回
	// 预分配好的 slice,不用 append 竞争。
	artists := make([]topArtistEntry, len(merged))
	{
		var wg sync.WaitGroup
		sem := make(chan struct{}, 4)
		for i, e := range merged {
			wg.Add(1)
			go func(i int, name string, playCount int) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				avatar, _ := resolveArtistAvatar(p.ctx, name)
				artists[i] = topArtistEntry{
					Name: name, PlayCount: playCount,
					Avatar: avatar,
				}
			}(i, e.Name, e.PlayCount)
		}
		wg.Wait()
	}
	payload := map[string]any{"artists": artists, "updatedAt": now.Unix()}
	if err := postRelay(p.ctx, p.cfg, "/top-artists", payload); err != nil {
		return // 推失败就不存状态,下个检查周期(至多 24h 后)会自然重试,不会因为一次失败长期卡死
	}
	p.topArtistsState.save(now.Unix())
}
