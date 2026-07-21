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
	"time"
)

// topArtistsCheckInterval：网页这块内容明确不需要实时,"每天更新一次就好"——不用像
// weeklyDigestCheckInterval(2小时)那么勤,一天检查一次即可,省掉绝大多数没意义的
// Last.fm/Deezer 调用。
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
		"period": {"overall"}, "limit": {strconv.Itoa(limit)},
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

// artistMergeNameKey 算"归并判定用"的归一化字符串——用户要求"简繁、中英、只要是同一个
// 人都算上,还有'&'之类的也算到第一个人上":
//  1. firstCreditedArtist:多人合credit(如"Prince & The Revolution")先取第一位,
//     不单独占一个歌手名额;
//  2. knownArtistAlias(match.go 的 artistAliasTable):已知的英文/罗马化艺名换成
//     本库常用中文名(比如"Dean Ting"→"丁世光");
//  3. toSimplified:繁体折成简体(比如"周杰倫"和"周杰伦"折成同一个键);
//  4. 大小写折叠。
//
// 四步做完算出的字符串一致就判定是同一个人。
func artistMergeNameKey(name string) string {
	first := firstCreditedArtist(name)
	if alias := knownArtistAlias(first); alias != "" {
		first = alias
	}
	return strings.ToLower(toSimplified(first))
}

// artistMergeDisplayName 是展示用的名字——步骤跟 artistMergeNameKey 前两步一致(合唱
// 取第一位、已知别名换成中文名),但不做 toSimplified/大小写折叠:那两步只是"判断是否
// 同一个人"内部用的归一化,不代表要悄悄篡改这个人在库里原本的书写(繁体来源就展示繁体,
// 不强制转简体)。
func artistMergeDisplayName(name string) string {
	first := firstCreditedArtist(name)
	if alias := knownArtistAlias(first); alias != "" {
		return alias
	}
	return first
}

// mergeAliasedArtists 把 Last.fm 统计里"同一个真人被拆成多条"的记录合并成一条,播放
// 次数相加。单一手段(只按名字键比较)覆盖不全某些情况——比如这次实测"Dean Ting"这条
// Last.fm 没能解析出 mbid、只有"丁世光"那条有——所以用两个信号一起判断"是不是同一个
// 人",任一信号命中就合并(并查集,允许链式传递:比如 A/B 因名字键相同合并、B/C 又因
// mbid 相同合并,最终 A/B/C 都算一个人):
//  1. artistMergeNameKey 相同(见其注释:合唱取第一位+已知别名+繁简折叠+大小写折叠);
//  2. Last.fm 自己解析出的 mbid(MusicBrainz ID)相同——这是 Last.fm 服务端自己的艺人
//     身份归并结果,能兜住名字键这条路径本身抓不到的情况(不在 artistAliasTable 里、
//     写法也没有明显对应关系的同一人),但不能替代名字键匹配——mbid 不是每条记录都有。
//
// 合并后按播放次数重新降序排列——合并可能改变名次,比如两条各自排第 6/7 名,合并后播放
// 次数相加就可能前移到第 4 名。
func mergeAliasedArtists(entries []lastfmChartEntry) []lastfmChartEntry {
	n := len(entries)
	nameKeys := make([]string, n)
	for i, e := range entries {
		nameKeys[i] = artistMergeNameKey(e.Name)
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
	for i := 0; i < n; i++ {
		for j := i + 1; j < n; j++ {
			sameName := nameKeys[i] != "" && nameKeys[i] == nameKeys[j]
			sameMbid := entries[i].Mbid != "" && entries[i].Mbid == entries[j].Mbid
			if sameName || sameMbid {
				union(i, j)
			}
		}
	}

	type bucket struct {
		name      string
		playCount int
	}
	buckets := make(map[int]*bucket, n)
	order := make([]int, 0, n)
	for i, e := range entries {
		root := find(i)
		b, ok := buckets[root]
		if !ok {
			b = &bucket{name: artistMergeDisplayName(e.Name)}
			buckets[root] = b
			order = append(order, root)
		}
		b.playCount += e.PlayCount
	}

	out := make([]lastfmChartEntry, 0, len(order))
	for _, root := range order {
		b := buckets[root]
		out = append(out, lastfmChartEntry{Name: b.name, PlayCount: b.playCount})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].PlayCount > out[j].PlayCount })
	return out
}

// resolveArtistAvatar 给一个歌手名找头像图——优先 QQ 音乐(qqSingerAvatar,这个项目
// 给中文内容一贯优先选的服务,免认证、且实测中英文歌手都有覆盖),查不到才退到 Deezer
// (deezerArtistAvatar)。2026-07-14 上线时最初只用了 Deezer(见下方注释,当时的理由是
// Last.fm 自己不提供真实头像),用户随后问"能不能用 Apple Music 的或者 QQ 音乐的头像"——
// Apple Music 官方头像数据只有付费 Apple Developer 账号才能拿到的 MusicKit 目录 API 才有
// (这个项目一直用免费的 iTunes Search API 查预览/封面,那个接口的 musicArtist 类型结果
// 没有任何图片字段,实测确认过),引入 MusicKit 需要新增付费开发者账号+JWT 签名基建,
// 成本明显高于收益,没有做;QQ 音乐则直接可行(复用现成的免认证 smartbox_new.fcg),
// 换成它当首选。
func resolveArtistAvatar(ctx context.Context, name string) string {
	if pic := qqSingerAvatar(name); pic != "" {
		return pic
	}
	return deezerArtistAvatar(ctx, name)
}

// deezerArtistAvatar 查 Deezer 的公开歌手搜索接口拿一张头像图——这次上线前实测确认过
// Last.fm 自己的 artist.getinfo 现在对所有歌手都返回同一张占位图(2019 年前后的已知
// API 变化,拿不到真实头像),Deezer 的 search/artist 不需要认证、且是按歌手实际区分的
// 真实图片,拿它当头像来源。查不到/查失败时返回空字符串——调用方不应该因为单个歌手
// 查图失败就放弃整批数据,前端对空头像也有兜底展示。现在是 resolveArtistAvatar 查不到
// QQ 音乐头像时的兜底,不再是首选。
func deezerArtistAvatar(ctx context.Context, name string) string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	u := "https://api.deezer.com/search/artist?limit=1&q=" + neturl.QueryEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var out struct {
		Data []struct {
			PictureMedium string `json:"picture_medium"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || len(out.Data) == 0 {
		return ""
	}
	return out.Data[0].PictureMedium
}

// topArtistsDigest 检查(至多每 topArtistsCheckInterval 一次)要不要重新计算"历史播放
// Top10歌手"并推给状态中继——用户明确说了这块内容不用实时、一天一次就够,所以挂在跟
// weeklyDigest 同样的 poll() 尾部、但用一个大得多的检查间隔,不会增加正常轮询的开销。
// 复用跟 weeklyDigest 同一套 Last.fm 凭证,没配置就整体跳过;还要求 StateRelayURL 已配置
// (数据要推给网页读的中继,没配这个推了也没地方读)。
//
// 2026-07-20:去掉了 features.TopArtistsDigest 这个额外开关——这三个凭据/地址字段
// 本来就是这个功能唯一需要的前置条件,那个开关只是叠加在上面的一层多余手动确认
// (desktop-lyrics 侧同步删掉了对应的手动 Toggle,见 AccountLinkingTab.swift)。
func (p *poller) topArtistsDigest(now time.Time) {
	if p.cfg.LastfmUser == "" || p.cfg.LastfmAPIKey == "" || p.cfg.StateRelayURL == "" {
		return
	}
	if !p.topArtistsLastCheckedAt.IsZero() && now.Sub(p.topArtistsLastCheckedAt) < topArtistsCheckInterval {
		return
	}
	p.topArtistsLastCheckedAt = now
	if last := p.topArtistsState.load(); last > 0 && now.Sub(time.Unix(last, 0)) < topArtistsCheckInterval {
		return // 磁盘上记录的上次成功推送还没满一天(比如刚重启,内存态丢了但磁盘状态还在)
	}

	entries, err := lastfmTopArtists(p.ctx, p.cfg.LastfmUser, p.cfg.LastfmAPIKey, topArtistsFetchPool)
	if err != nil || len(entries) == 0 {
		return
	}
	merged := mergeAliasedArtists(entries)
	if len(merged) > topArtistsN {
		merged = merged[:topArtistsN]
	}
	artists := make([]topArtistEntry, 0, len(merged))
	for _, e := range merged {
		artists = append(artists, topArtistEntry{
			Name: e.Name, PlayCount: e.PlayCount,
			Avatar: resolveArtistAvatar(p.ctx, e.Name),
		})
	}
	payload := map[string]any{"artists": artists, "updatedAt": now.Unix()}
	if err := postRelay(p.ctx, p.cfg, "/top-artists", payload); err != nil {
		return // 推失败就不存状态,下个检查周期(至多 24h 后)会自然重试,不会因为一次失败长期卡死
	}
	p.topArtistsState.save(now.Unix())
}
