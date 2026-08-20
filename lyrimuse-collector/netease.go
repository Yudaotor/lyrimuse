// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

type neteaseInfo struct {
	Cover, SongURL, Lyrics, Trans, Roma, YRC string
	// DurationSecs:网易云曲库里这首歌自报的时长(秒),0=没拿到。2026-08-12 起透传给
	// 候选(sourceReportedDurationSecs),不参与打分,先攒评测数据。
	DurationSecs float64
	// Artist 是网易云曲库里这首歌的官方歌手名(单一歌手才填,合唱/多歌手曲目留空——
	// 避免把本地"歌手A & 歌手B"的联合署名压缩成只剩其中一个)。用于统一同一歌手在历史
	// 记录里时而中文时而英文、时而全大写的写法(如 PRINCE/Prince、David Tao/陶喆)。
	Artist string
	// Title/Album 是这首歌在网易云曲库里实际匹配到的歌名/专辑名,取自 pick() 选中的
	// chosen(候选 neSong)。主要给"搜索候选歌词"弹窗展示用(用户想知道这个候选具体
	// 对应哪首歌/哪张专辑,不是只看"netease"这个来源名);Album 另外**参与封面选源**
	// (见 enrich.go 的 preferAppleCoverOverNetease:网易云这张封面属于另一次发行时,
	// 改用 Apple 那张对得上专辑的)—— 但两者都不参与 pick() 自己的匹配/打分。
	// 跟 Artist 不同,这两个字段不做"是否单一歌手"之类的过滤,原样如实展示网易云曲库
	// 里的名字。
	Title, Album string
	// AlbumID 是 Album 那张专辑在网易云的 id,0=没拿到。只给同专辑预取用
	// (见 neteaseAlbumTracks)。跟 Title/Album 一样取自 pick() 选中的 chosen。
	AlbumID int64
	// PureMusic:网易云明确说这首歌是**纯音乐**。2026-08-20 加。
	//
	// 歌词接口对纯音乐会在顶层给 `pureMusic: true`,正文则是「作曲 : X」+
	// 「纯音乐,请欣赏」两行占位(实测 LoL 原声带 id=30431011)。这两行过不了
	// isTimedLRC 的三行门槛,所以 Lyrics 留空、网易云连一条候选都不产生 —— 而
	// "查过了、确实没有词"和"这首本来就没有词"在 UI 上是两句不同的话(「无歌词」vs
	// 「纯音乐」)。这个字段就是把后者那个明确结论带出来,跟 lrclib 的 instrumental
	// 标记汇到同一处(见 enrich.go 的 instrumentalMarker)。
	PureMusic bool
}

// neteaseCache 是这个文件自己内部的网络请求结果缓存(避免短时间内重复打网易云的接口),
// 跟 enrichCache(enrich.go)是两回事、各自独立——enrichCache 里一条歌只要解析出结果就
// 永久生效,不再有整体过期这回事;这里的 TTL 分级只管"多久内不用重新问网易云要一次数据"。
// 封面拿到了才算"拿全了"，给长 TTL；只拿到 SongURL+Lyrics 但 Cover 仍是空(多半是取封面
// 那次请求单独限流/超时)用短 TTL,让它有机会自愈——否则会永久遮蔽 enrich.go 那边
// backfillPeripheralFields 的外围字段重试(重试时调到这里,却直接命中这份"缺封面"的
// 旧缓存,永远补不回封面)。
const (
	neteaseCacheTTL        = 30 * 24 * time.Hour
	neteaseCacheTTLNoCover = 10 * time.Minute
)

type neteaseCacheEntry struct {
	info neteaseInfo
	ts   int64
}

var (
	neteaseMu    sync.Mutex
	neteaseCache = map[string]neteaseCacheEntry{}
)

// neteaseLookup returns a China-reachable album cover URL (p*.music.126.net) and
// the NetEase song page URL for a track. The album is used to disambiguate: the
// same song appears on many NetEase albums (originals, compilations, "This Is
// It"…), so picking songs[0] blindly grabs the wrong cover. Cached per
// artist|title|album; only cached once the song id is found.
func neteaseLookup(artist, title, album string) neteaseInfo {
	if title == "" {
		return neteaseInfo{}
	}
	// 版权已从网易云整体下架、曲库里只剩仿冒号的艺人(见 isNeteaseImpersonatorRidden 注释)——
	// 这类艺人的搜索结果哪怕标题、歌手名字面都"匹配"上了也必然是仿冒号(真人官方版本根本
	// 不在库里),pick() 的标题/歌手名校验拦不住这种情况。这里直接整个跳过网易云、不发任何
	// 请求,让上层 enrich.go 退到 QQ 音乐兜底(QQ 侧要求歌手名双重精确匹配,不受此影响)。
	if isNeteaseImpersonatorRidden(artist) {
		return neteaseInfo{}
	}
	key := artist + "|" + title + "|" + album
	now := time.Now().Unix()
	neteaseMu.Lock()
	if e, ok := neteaseCache[key]; ok {
		ttl := int64(neteaseCacheTTL / time.Second)
		if e.info.Cover == "" {
			ttl = int64(neteaseCacheTTLNoCover / time.Second)
		}
		if now-e.ts < ttl {
			neteaseMu.Unlock()
			return e.info
		}
	}
	neteaseMu.Unlock()

	info := resolveNeteaseInfo(artist, title, album)
	// 只缓存"拿到实质内容"的结果:找到歌但封面+歌词都空(多半被限流)不缓存,以免遮蔽
	// enrich 的短 TTL 自愈——否则下次重解析命中这份空缓存、永远补不回封面/歌词。
	if info.SongURL != "" && (info.Cover != "" || info.Lyrics != "") {
		neteaseMu.Lock()
		neteaseCache[key] = neteaseCacheEntry{info: info, ts: now}
		neteaseMu.Unlock()
	}
	return info
}

// neteaseSearch 发一次搜索,主端点被限流时换备用端点再试一次。
//
// 2026-08-09 实测:网易云的限流是**按端点分桶**的 —— 短时间内多查几十次之后
// /api/search/get/web 稳定回 code 405,而同一刻 /api/search/get 照常返回 200,两者的
// 响应结构完全一致(result.songs[] 里 name/id/artists/album/duration 都在)。
//
// 只有一个端点的时候,一撞上限流这个源就整个哑掉,而它是唯一给译文和罗马音的源;结果还会
// 被永久缓存(缓存没有 TTL)。多一个桶不是为了跑得更快,是为了在被限的那几分钟里仍然有
// 一条路走通。
func neteaseSearch(get func(string, any) error, q string, out any) error {
	escaped := neturl.QueryEscape(q)
	err := get("https://music.163.com/api/search/get/web?type=1&limit=30&s="+escaped, out)
	if err == nil {
		return nil
	}
	return get("https://music.163.com/api/search/get?type=1&limit=30&s="+escaped, out)
}

// isNeteasePureMusicLyric 判断这份 lrc 是不是"纯音乐占位"而不是真歌词。
//
// 顶层 pureMusic 标记是主判据,这个是**备份**:网易云自己的数据不齐,实测同一批曲目里
// 有的条目只有正文占位、没有那个顶层字段。
//
// 占位文案复用 match.go 已有的 neteaseInstrumentalPlaceholderMarker(那边的
// isCreditOnlyLRC 拿它判"这份不是真歌词"、直接判废)—— 同一个事实两处别各写一份。
// 这里做的是**另一件事**:把"判废"升级成"得出结论"。判据刻意收紧成「整份只有占位 +
// 可选的署名行」,任何一句真歌词都让它不成立,免得把歌词里恰好唱到"纯音乐"的句子误判。
func isNeteasePureMusicLyric(lrc string) bool {
	if strings.TrimSpace(lrc) == "" {
		return false
	}
	hasPlaceholder := false
	for _, line := range strings.Split(lrc, "\n") {
		body := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if body == "" {
			continue
		}
		if strings.Contains(body, neteaseInstrumentalPlaceholderMarker) {
			hasPlaceholder = true
			continue
		}
		// 署名行(作曲/作词/编曲…)允许共存 —— 纯音乐条目基本都带一行作曲。
		if isCreditLine(body) {
			continue
		}
		return false // 有真正的歌词内容
	}
	return hasPlaceholder
}

func resolveNeteaseInfo(artist, title, album string) neteaseInfo {
	cli := &http.Client{Timeout: 4 * time.Second}
	get := func(u string, v any) error {
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		// ⚠️ 网易云限流时**照样回 HTTP 200**,把拒绝写在 body 的 code 字段里(实测
		// 2026-08-09:短时间内连发几十次搜索之后,/api/search/get/web 稳定返回
		// {"result":{},"code":405},而同一刻 /api/search/get 仍然正常 —— 是按端点分桶的
		// 应用层限流,不是封 IP)。
		//
		// 只看 HTTP 状态码的话,这份响应会被解成"零首歌",跟"这首歌网易云真的没有"完全
		// 分不开。后果不是少一条候选那么轻:这一轮的结果会被**永久缓存**(缓存没有 TTL),
		// 而网易云是唯一提供译文和罗马音的源 —— 一次几分钟的限流,能让那段时间里解析的
		// 歌永远缺译文。当成错误返回之后,这个源就不会被记进 LyricsSourcesSeen,
		// needsLyricsRetry 才有机会在之后重搜(见那边的 missing 判断)。
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return err
		}
		var probe struct {
			Code int `json:"code"`
		}
		// code 缺省(有些端点不带这个字段)时是 0,不当作错误。
		if err := json.Unmarshal(body, &probe); err == nil && probe.Code != 0 && probe.Code != 200 {
			return fmt.Errorf("netease api code %d", probe.Code)
		}
		return json.Unmarshal(body, v)
	}

	// NetEase 搜索对词序/括号噪声敏感:带一堆 (feat.)/(with) 的完整标题常搜不到真曲、
	// 只回一堆热门歌兜底。用去括号标题查,不中再换一个词序(实测 "标题 歌手" 召回更好)。
	//
	// ⚠️ 这里**故意不走 searchTitleVariants**,是唯一一个不走的源 —— 别把它"顺手统一"过去。
	// 那个函数里的"版本限定词 → 原样标题优先"守卫是给 kugou/QQ/Musixmatch 准备的,因为
	// 那三个源是**取第一条通过校验的候选就收工**,搜索词一偏就直接定死在错版本上。而下面
	// 的 pick() 是**扫完 10 条结果再排序挑**(精确同名 exactCands 优先于宽松 looseCands,
	// 再按专辑分),版本选择由排序负责,不依赖搜索词的写法。
	//
	// 2026-08-09 实测坐实:把这里也改成"版本限定词原样优先"之后,14 首带 (Live)/
	// (Original Version)/(reprise) 的歌,网易云拿到的候选曲名**一条都没变**(分数的整齐
	// -50 是另一次改动删掉来源加分造成的,与此无关),白白多打最多 2 次请求 —— 而网易云
	// 恰恰是五个源里最容易被限流的那个(HTTP 200 + body code 405)。所以改回来。
	ct := stripParens(title)
	var queries []string
	// 老歌撞新翻唱/新演出版本同名时,纯"歌手+标题"召回率不够——真正想要的旧版本可能在
	// NetEase 搜索排名里靠后,掉出 pick() 能看到的候选窗口,导致只看到新版本这一条"唯一
	// 候选"而选错了封面。带上本地专辑名一起查能大幅提升召回排名——只在本地专辑名非空时才
	// 加这条查询、且放在最前面优先尝试,不影响本来就没有专辑信息的情形(如"大鱼"那种本地
	// 专辑名对不上/为空的正常单曲，见 pick 注释)。
	if album != "" {
		queries = append(queries, artist+" "+ct+" "+album)
	}
	queries = append(queries, artist+" "+ct)
	if ct != title {
		queries = append(queries, artist+" "+title) // 保留原始作为补充
	}
	queries = append(queries, ct+" "+artist)
	type neSong = struct {
		ID      int64  `json:"id"`
		Name    string `json:"name"`
		Artists []struct {
			Name string `json:"name"`
		} `json:"artists"`
		Album struct {
			Name string `json:"name"`
			// ID:专辑 id。给"提前解析同专辑其它曲目"用 —— 拿的是 **pick() 选中的这首歌
			// 自己所属**的专辑,不是拿专辑名去另搜一次,所以天然不会撞上同名专辑/精选集
			// (实测搜 "Michael Jackson Bad",前三条全是套装:King of Pop 48 首、
			// The Collection 76 首,原专辑排到第 13 条)。
			ID int64 `json:"id"`
		} `json:"album"`
		// Duration:搜索结果自带的曲长(毫秒)。透传给候选,不参与本文件内的任何挑选逻辑。
		Duration float64 `json:"duration"`
	}
	// 选谁的封面/链接:同名歌里混着别歌手的翻唱/演奏/卡拉OK/同名他人歌。优先级:
	// ①歌名+歌手都匹配、且专辑分最高(专辑名 loose 相等=100 直接锁定正确专辑版本);
	// ②歌手名跨平台不一致但专辑强匹配(albumScore>0);③都无 → 返回空,不串错歌手。
	// 只信 byArtist(歌手名精确对上),不再有"歌手对不上、专辑名对上就认"的 byAlbum 兜底——
	// 专辑名字段能被仿冒号无成本抄成任意值(比 artistMatches 要防的"歌手名加个符号"更难防),
	// 官方曲库缺失时宁可 pick() 返回空,让 resolveTrackEnrichment 退到 QQ 音乐兜底(QQ 侧
	// 要求歌手名双重精确匹配,见 qqCoverFallback),也不要信一个只凭专辑名认亲的结果。
	// pick 分两步:①先把"歌手真的对上"的候选按标题精确/宽松分两档;②每档内部只有
	// 出现"不止一条"候选时才要求专辑分>0 才采信,单独一条候选时直接信它。
	// 按"是否有歧义"分情况,而不是无脑要求专辑分>0:很多正常单曲在网易云上专辑名字段本就
	// 跟本地(Apple Music)写法不一致、甚至整个空着,这时候只有一条真人候选、没有竞争者,
	// 没道理因为专辑名对不上就弃用。但当同一首歌出现两条以上"歌手都是真人、标题都精确同名"
	// 的候选时,说明网易云上确实存在多个实体版本(旧单曲发行版/后来收录进新专辑的版本等),
	// 这时候才需要专辑分>0 来确认选的是目标专辑对应的版本,选不出来宁可整体放弃、交给
	// QQ 音乐兜底,也不要矮子里拔将军选一个不确定对不对版本的候选。
	pick := func(songs []neSong) *neSong {
		type cand struct {
			s  *neSong
			sc int
		}
		var exactCands, looseCands []cand
		for i := range songs {
			s := &songs[i]
			if !lyricTitleAccepted(s.Name, title) {
				continue
			}
			artistMatch := false
			for _, a := range s.Artists {
				if artistMatches(a.Name, artist) {
					artistMatch = true
					break
				}
			}
			if !artistMatch {
				continue
			}
			sc := albumScore(s.Album.Name, album)
			if normLoose(s.Name) == normLoose(title) {
				exactCands = append(exactCands, cand{s, sc})
			} else {
				looseCands = append(looseCands, cand{s, sc})
			}
		}
		// strict:looseCands 传 true——这批候选标题本身就带着"(Extended)"/"(Live)"/
		// "(Instrumental)"这类版本限定词,天然就是"另一个版本",唯一候选也不能免检直接信。
		// exactCands 传 false,保留"唯一精确同名候选、专辑名对不上也认"的既有行为,不能收紧。
		bestOf := func(cands []cand, strict bool) *neSong {
			if len(cands) == 1 && !(strict && album != "" && cands[0].sc == 0) {
				return cands[0].s // 唯一候选,没有歧义,直接信
			}
			// 多条候选(有歧义)→ 要求专辑分>0 才采信,选分最高的;都是0就整体放弃。
			var best *neSong
			bestSc := 0
			for _, c := range cands {
				if album != "" && c.sc == 0 {
					continue
				}
				if best == nil || c.sc > bestSc {
					best, bestSc = c.s, c.sc
				}
			}
			return best
		}
		// exactCands 优先,但优先到"没有 bestOf 选得出的"时不能直接放弃返回 nil——网易云上
		// 常年混着跟目标专辑无关、却标题恰好逐字同名的现场/盗版录音,这类候选一多就会让
		// exactCands 内部因"有歧义+都对不上专辑"被 bestOf 拒绝返回 nil;但 looseCands 里
		// 那条真正官方专辑版本(标题带"(Remaster)"等后缀、专辑分却明确对得上)本来是能唯一
		// 确定的,不该因为 exactCands 抢先返回 nil 就被连带放弃。
		if len(exactCands) > 0 {
			if c := bestOf(exactCands, false); c != nil {
				return c
			}
		}
		// looseCands 的"唯一候选直接信"不能像 exactCands 一样无条件生效——"查询词带上
		// 本地专辑名"这条优化(见上面 queries 构造处注释)可能让网易云的搜索排序把其它候选
		// 挤出结果窗口,只剩一条恰好通过标题/歌手校验、实为错误版本的候选,造成"看似唯一、
		// 其实只是被这次查询词意外筛剩下"的假象。looseCands 天然都是"标题带版本限定词"的
		// 候选(不然早被分进 exactCands 了),比 exactCands 更容易出现这种假象,所以收紧成
		// "本地有专辑名时,唯一候选也必须专辑分>0 才采信",专辑分对不上就整体放弃、交给
		// QQ 音乐兜底(宁可没有,也不要错,跟这个函数其它几处判断同一个原则)。
		if len(looseCands) > 0 {
			return bestOf(looseCands, true)
		}
		return nil
	}
	// 仅用于统一"歌手名怎么写"的兜底候选:歌名+专辑名都精确对上(albumScore=200)、且这批
	// 结果里只有唯一一条这样的候选,才采信它的歌手名——即便歌手名字面对不上查询词也认(比如
	// 查询用了罗马化/英文名,网易云库里这首歌记的是中文名)。跟 pick() 分开、绝不影响封面/
	// 歌词选择:那条判定必须先核实歌手名(见 artistMatches 注释——版权下架的艺人满屏都是
	// 仿冒号,专辑名可以被仿冒号随意抄成目标专辑名蒙混过关)。这里放宽的代价只是"历史列表
	// 偶尔显示错一个名字"这种低风险的展示问题,跟"封面选错"不是一个量级,所以能接受;但
	// 仍要求"唯一候选"防止同名同专辑撞车时瞎选一个。繁简转换已下沉到 normLoose/albumScore
	// 本身(见 match.go 的 normLoose 注释),这里不用再手动转一遍。
	nameOnlyMatch := func(songs []neSong) string {
		var found string
		n := 0
		for i := range songs {
			s := &songs[i]
			if normLoose(s.Name) != normLoose(title) || albumScore(s.Album.Name, album) < 200 || len(s.Artists) != 1 {
				continue
			}
			n++
			found = s.Artists[0].Name
		}
		if n == 1 {
			return found
		}
		return ""
	}

	// limit=30:"带专辑名"这条查询词(queries 第一条)对某些歌曲的检索排序反而有害——
	// 正确候选可能压根没出现在其结果里,加大它的 limit 也无济于事;但"不带专辑名"的兜底
	// 查询词(queries 第二条)在 limit=30 时能捞到这条本来就存在、只是排得靠后的正确候选。
	// 不需要为"带专辑名"那条单独做排除/回退,它找不到东西时自然不会返回任何可用候选,
	// 后续查询词的结果照常生效(见下面 chosen 只在 albumScore 更高时才覆盖的逻辑)。
	var chosen *neSong
	var nameOnlyArtist string
	for _, q := range queries {
		var r struct {
			Result struct {
				Songs []neSong `json:"songs"`
			} `json:"result"`
		}
		if err := neteaseSearch(get, q, &r); err != nil {
			continue
		}
		if c := pick(r.Result.Songs); c != nil {
			// 专辑名完全相等(albumScore=200)已是最优,直接采用;否则继续尝试下个查询看能否
			// 更好——注意 100 分只是"宽松包含"(可能是重发/纪念版),不能当作已经够好而提前退出。
			if chosen == nil || albumScore(c.Album.Name, album) > albumScore(chosen.Album.Name, album) {
				chosen = c
			}
			if albumScore(c.Album.Name, album) >= 200 {
				break
			}
		}
		// 跟 chosen 分支同样的道理(见下方注释):本地标签本来就是多人合credit时不用这条
		// 兜底,避免用只记了其中一位的 NetEase 单曲数据悄悄丢掉本地已经写全的合作者。
		// isNeteaseImpersonatorRidden(artist) 时也跳过——见该函数注释,这类艺人网易云
		// 官方曲库整体缺失,任何"标题+专辑名精确匹配"的候选先天就是仿冒号,nameOnlyMatch
		// 的"歌手名字面对不上也认"这条规则对他们而言等于直接采信仿冒号的署名。
		if nameOnlyArtist == "" && len(artistCreditParts(artist)) < 2 && !isNeteaseImpersonatorRidden(artist) {
			nameOnlyArtist = nameOnlyMatch(r.Result.Songs)
		}
	}
	if chosen == nil {
		if nameOnlyArtist != "" {
			return neteaseInfo{Artist: nameOnlyArtist} // 只拿到统一歌手名用的信号,不给封面/歌词
		}
		return neteaseInfo{} // 三种查询都没可信匹配 → 不给封面,别串错歌
	}
	id := chosen.ID
	info := neteaseInfo{
		SongURL:      fmt.Sprintf("https://music.163.com/song?id=%d", id),
		Title:        chosen.Name,
		Album:        chosen.Album.Name,
		AlbumID:      chosen.Album.ID,
		DurationSecs: chosen.Duration / 1000,
	}
	// 只有本地(Apple Music)标签本身就是单一人名(没有 &/、/, 等分隔符)时,才尝试用
	// NetEase 这条数据统一拼写:pick() 选中候选已经证明其中恰好一位通过 artistMatches 核实
	// 等于本地这唯一一人,复用那次核实结果统一这一位的写法即可。
	// 但如果本地标签本来就是多人合credit(如"Prince & The Revolution"),就完全不碰、
	// 让 lbMeta 原样用本地标签——NetEase 对同一张专辑不同曲目的"合credit拆分"口径本就
	// 不统一(有的单曲只记其中一位),拿这种残缺的单曲级别数据去顶替本地已经写全的多人
	// credit,会悄悄丢人。
	if len(artistCreditParts(artist)) < 2 {
		for _, a := range chosen.Artists {
			if artistMatches(a.Name, artist) {
				info.Artist = a.Name
				break
			}
		}
	}
	var dr struct {
		Songs []struct {
			Album struct {
				PicURL string `json:"picUrl"`
			} `json:"album"`
		} `json:"songs"`
	}
	if err := get(fmt.Sprintf("https://music.163.com/api/song/detail?ids=[%d]", id), &dr); err == nil && len(dr.Songs) > 0 && dr.Songs[0].Album.PicURL != "" {
		info.Cover = dr.Songs[0].Album.PicURL + "?param=600y600"
	}
	// 带时间轴的 LRC 歌词，网页跟实时进度条同步高亮滚动。一次老接口就能拿齐原文(lrc)+
	// 中文翻译(tlyric)+罗马音(romalrc)，三者时间轴对齐；逐字(yrc，词级)走 v1 接口、只有
	// 部分歌有。只在确有时间戳时带上；同一首歌各版本歌词相同，选中版本无词时退到其它同名版本。
	fetchBundle := func(songID int64) (lrc, tr, roma string, pureMusic bool) {
		var r struct {
			Lrc struct {
				Lyric string `json:"lyric"`
			} `json:"lrc"`
			Tlyric struct {
				Lyric string `json:"lyric"`
			} `json:"tlyric"`
			Romalrc struct {
				Lyric string `json:"lyric"`
			} `json:"romalrc"`
			// 纯音乐标记,见 neteaseInfo.PureMusic。2026-08-20 补上 —— 在此之前这个字段
			// 压根不在结构体里,信号在解码那一步就丢了。
			PureMusic bool `json:"pureMusic"`
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric?id=%d&lv=-1&kv=-1&tv=-1&rv=-1", songID), &r); err != nil {
			return "", "", "", false
		}
		return r.Lrc.Lyric, r.Tlyric.Lyric, r.Romalrc.Lyric, r.PureMusic
	}
	fetchYRC := func(songID int64) string {
		var r struct {
			Yrc struct {
				Lyric string `json:"lyric"`
			} `json:"yrc"`
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric/v1?id=%d&yv=-1", songID), &r); err != nil {
			return ""
		}
		if y := r.Yrc.Lyric; strings.Contains(y, "[") && len(y) < 40000 {
			return y
		}
		return ""
	}
	lrc, tr, roma, pureMusic := fetchBundle(id)
	// 纯音乐这个结论跟"有没有可用歌词"分开记:占位正文过不了 isTimedLRC,Lyrics 会留空,
	// 而"留空"本身分不出"这首没词"和"没查到词"。见 neteaseInfo.PureMusic。
	info.PureMusic = pureMusic || isNeteasePureMusicLyric(lrc)
	if isTimedLRC(lrc) {
		info.Lyrics = lrc
		if isTimedLRC(tr) {
			info.Trans = tr
		}
		if isTimedLRC(roma) {
			info.Roma = roma
		}
		info.YRC = fetchYRC(id) // 逐字，无则空串，前端退回行级
	}
	return info
}

// neteaseAlbumTracks 按专辑 id 列出这张专辑的全部曲目,给"提前解析同专辑其它曲目"用。
//
// ⚠️ 必须带 Cookie: os=pc。2026-08-14 实测:不带 cookie 时这个端点会**间歇性**返回
// HTTP 200 + body {"code":-462,"message":"请绑定手机后再试哦~"}(9 次里中 5 次,同一个
// 专辑 id 有时通有时不通,是反爬闸门不是"这张专辑要登录");带上之后 9/9 全通。HTTP 状态
// 码始终是 200,所以只看 status 会把拒绝解成"这张专辑零首歌" —— 跟本文件 resolveNeteaseInfo
// 里那个 code 守卫同一个坑,同一个修法。
//
// 备用端点 /api/v1/album/{id} 的 shape 不同(曲目在顶层 songs 而不是 album.songs),两种
// 都吃。网易云是**按端点分桶**限流的(见 resolveNeteaseInfo 里那段注释),主端点被限时
// 备用桶往往还通。
func neteaseAlbumTracks(albumID int64) ([]albumTrack, bool) {
	if albumID <= 0 {
		return nil, false
	}
	cli := &http.Client{Timeout: 6 * time.Second}
	type neAlbumSong struct {
		Name     string  `json:"name"`
		Duration float64 `json:"duration"` // 毫秒
		Artists  []struct {
			Name string `json:"name"`
		} `json:"artists"`
	}
	var payload struct {
		Code  int `json:"code"`
		Album struct {
			Name  string        `json:"name"`
			Size  int           `json:"size"`
			Songs []neAlbumSong `json:"songs"`
		} `json:"album"`
		Songs []neAlbumSong `json:"songs"` // /api/v1/album/{id} 把曲目放在顶层
	}
	fetch := func(u string) bool {
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return false
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		req.Header.Set("Cookie", "os=pc") // 见函数注释,少了它会间歇性被 -462 拦掉
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return false
		}
		payload = struct {
			Code  int `json:"code"`
			Album struct {
				Name  string        `json:"name"`
				Size  int           `json:"size"`
				Songs []neAlbumSong `json:"songs"`
			} `json:"album"`
			Songs []neAlbumSong `json:"songs"`
		}{}
		if json.NewDecoder(resp.Body).Decode(&payload) != nil {
			return false
		}
		// code 非 200/0 一律当失败(-462 就走这里),别把限流解成"零首歌"。
		return payload.Code == 0 || payload.Code == 200
	}
	if !fetch(fmt.Sprintf("https://music.163.com/api/album/%d", albumID)) {
		if !fetch(fmt.Sprintf("https://music.163.com/api/v1/album/%d", albumID)) {
			return nil, false
		}
	}
	songs := payload.Album.Songs
	if len(songs) == 0 {
		songs = payload.Songs
	}
	if len(songs) == 0 {
		return nil, false
	}
	out := make([]albumTrack, 0, len(songs))
	for _, s := range songs {
		if s.Name == "" {
			continue
		}
		// 合唱曲目 artists 是数组,按 " & " 拼回去 —— 跟本地标签"歌手A & 歌手B"的写法
		// 对齐,别压缩成第一位(压缩会让 enrich 的 key 跟真播到这首歌时算出来的对不上,
		// 预取的结果白存)。
		names := make([]string, 0, len(s.Artists))
		for _, a := range s.Artists {
			if a.Name != "" {
				names = append(names, a.Name)
			}
		}
		out = append(out, albumTrack{
			title:    s.Name,
			artist:   strings.Join(names, " & "),
			duration: s.Duration / 1000, // 网易云给的是毫秒
		})
	}
	return out, len(out) > 0
}
