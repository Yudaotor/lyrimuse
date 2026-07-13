// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

type neteaseInfo struct {
	Cover, SongURL, Lyrics, Trans, Roma, YRC string
	// Artist 是网易云曲库里这首歌的官方歌手名(单一歌手才填,合唱/多歌手曲目留空——
	// 避免把本地"歌手A & 歌手B"的联合署名压缩成只剩其中一个)。用于统一同一歌手在历史
	// 记录里时而中文时而英文、时而全大写的写法(如 PRINCE/Prince、David Tao/陶喆)。
	Artist string
}

// neteaseCache 的 TTL 分级,呼应 enrichCache(enrich.go)的同一套设计:封面拿到了才算
// "拿全了"，给长 TTL；只拿到 SongURL+Lyrics 但 Cover 仍是空(多半是取封面那次请求单独
// 限流/超时)用短 TTL,让它有机会自愈——否则会永久遮蔽 enrichCache 自己的短 TTL 重试
// (enrichCache 过期后重新调这里,却直接命中这份"缺封面"的旧缓存,永远补不回封面)。
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

func resolveNeteaseInfo(artist, title, album string) neteaseInfo {
	cli := &http.Client{Timeout: 4 * time.Second}
	get := func(u string, v any) error {
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Referer", "https://music.163.com/")
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := cli.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		return json.NewDecoder(resp.Body).Decode(v)
	}

	// NetEase 搜索对词序/括号噪声敏感:带一堆 (feat.)/(with) 的完整标题常搜不到真曲、
	// 只回一堆热门歌兜底。用去括号标题查,不中再换一个词序(实测 "标题 歌手" 召回更好)。
	ct := stripParens(title)
	var queries []string
	// 老歌撞新翻唱/新演出版本同名时,纯"歌手+标题"召回率不够——王力宏《落叶归根》实测
	// 坐实:2007原专辑《改变自己》里的录音室版跟2025年《歌手》综艺里王力宏+单依纯合唱的
	// 同名新版本标题、歌手都能各自精确匹配,但 2007 原版在 NetEase 搜索排名极靠后(实测
	// offset 60~90 才出现,远超 pick() 能看到的候选窗口),pick() 只看到综艺合唱版这一条
	// "唯一候选"、没有察觉真正的原版根本不在候选集合里,选错了封面。带上本地专辑名一起
	// 查能大幅提升召回排名(实测同一首歌加上专辑名后原版直接排到第一位)——只在本地专辑名
	// 非空时才加这条查询、且放在最前面优先尝试,不影响本来就没有专辑信息的情形(如"大鱼"
	// 那种本地专辑名对不上/为空的正常单曲，见 pick 注释)。
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
		} `json:"album"`
	}
	// 选谁的封面/链接:同名歌里混着别歌手的翻唱/演奏/卡拉OK/同名他人歌。优先级:
	// ①歌名+歌手都匹配、且专辑分最高(专辑名 loose 相等=100 直接锁定正确专辑版本);
	// ②歌手名跨平台不一致但专辑强匹配(albumScore>0);③都无 → 返回空,不串错歌手。
	// 只信 byArtist(歌手名精确对上),不再有"歌手对不上、专辑名对上就认"的 byAlbum 兜底。
	// 实测坐实这条兜底能被反向利用:仿冒号可以把自己上传的"专辑名"字段直接抄成目标专辑名
	// (如某仿冒号把假的"I do 周杰倫to marry"单曲的专辑字段就填成周杰伦真实新专辑名"太阳
	// 之子",标题也做成含"I Do"子串来骗过 titleMatches),让专辑分打满分从而蒙混过关——
	// 这比 artistMatches 要防的"歌手名加个符号"更难防,专辑名可以被仿冒号无成本抄成任意
	// 值。官方曲库缺失时,宁可 pick() 返回空,让 resolveTrackEnrichment 退到 QQ 音乐兜底
	// (QQ 侧要求歌手名双重精确匹配,见 qqCoverFallback),也不要信一个只凭专辑名认亲的结果。
	// pick 分两步:①先把"歌手真的对上"的候选按标题精确/宽松分两档;②每档内部只有
	// 出现"不止一条"候选时才要求专辑分>0 才采信,单独一条候选时直接信它。
	// 为什么按"是否有歧义"分情况,而不是无脑要求专辑分>0:很多正常单曲在网易云上专辑名
	// 字段本就跟本地(Apple Music)写法不一致、甚至整个空着,这时候只有一条真人候选、没有
	// 竞争者,没道理因为专辑名对不上就弃用(实测坐实:周深《大鱼》官方版专辑名是空的,
	// 如果无脑要求专辑分>0 会被误杀)。但当同一首歌出现两条以上"歌手都是真人、标题都精确
	// 同名"的候选时,这就是网易云上确实存在多个实体版本(旧单曲发行版/后来收录进新专辑的
	// 版本等)的信号,这时候才需要专辑分>0 来确认选的是目标专辑对应的那个版本,选不出来
	// 宁可整体放弃、交给 QQ 音乐兜底,也不要矮子里拔将军选一个不确定对不对版本的候选
	// (实测坐实:《圣诞星(feat.杨瑞代)》网易云上有两条真人"周杰伦"精确同名候选,都是
	// 2023年发行的旧单曲,没有一条关联得上目标专辑"太阳之子";这首歌其他同专辑曲目在
	// 网易云上也是同样查无官方专辑版本,全部正确退到 QQ 音乐兜底,圣诞星理应同等对待)。
	pick := func(songs []neSong) *neSong {
		type cand struct {
			s  *neSong
			sc int
		}
		var exactCands, looseCands []cand
		for i := range songs {
			s := &songs[i]
			if !titleMatches(s.Name, title) {
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
		bestOf := func(cands []cand) *neSong {
			if len(cands) == 1 {
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
		// exactCands 优先,但"优先"到"没有 bestOf 选得出的",不能直接放弃——网易云上
		// 常年混着跟目标专辑无关、却标题恰好逐字同名的现场/盗版录音(如"Darling Nikki"
		// 这首歌,Syracuse 1985 live bootleg 也叫这个名,跟正版录音室版一样精确同名却对不上
		// 专辑),这类候选一多就会让 exactCands 内部因"有歧义+都对不上专辑"被 bestOf 拒绝、
		// 返回 nil——但 looseCands 里那条真正官方专辑版本(标题带"(Remaster)"等后缀、专辑分
		// 却明确对得上)本来是能唯一确定的,不该因为 exactCands 抢先返回 nil 就被连带放弃。
		// 实测坐实:Prince & The Revolution《Darling Nikki》——两条"Darling Nikki"精确
		// 同名的现场录音互相打平且专辑分都是 0,而"Darling Nikki (2015 Paisley Park
		// Remaster)"(专辑"Purple Rain (Deluxe Edition)",专辑分 100)明明在 looseCands
		// 里等着,却因为上面这条直接 return 被拦在门外,导致这首歌的网易云链接/封面都解析
		// 不出来。
		if len(exactCands) > 0 {
			if c := bestOf(exactCands); c != nil {
				return c
			}
		}
		if len(looseCands) > 0 {
			return bestOf(looseCands)
		}
		return nil
	}
	// 仅用于统一"歌手名怎么写"的兜底候选:歌名+专辑名都精确对上(albumScore=200)、且这批
	// 结果里只有唯一一条这样的候选,才采信它的歌手名——即便歌手名字面对不上查询词也认(比如
	// 查询用了罗马化/英文名"David Tao",网易云库里这首歌记的是"陶喆")。跟 pick() 分开、绝不
	// 影响封面/歌词选择:那条判定必须先核实歌手名(见 artistMatches 注释里 Jay Chou 的教训——
	// 版权下架的艺人满屏都是仿冒号,专辑名可以被仿冒号随意抄成目标专辑名蒙混过关)。这里放宽
	// 的代价只是"历史列表偶尔显示错一个名字"这种低风险的展示问题,跟"封面选错"完全不是一个
	// 量级,所以能接受;但仍要求"唯一候选"防止同名同专辑撞车时瞎选一个。
	// 繁简转换现在下沉到 normLoose/albumScore 本身(见 match.go 的 normLoose 注释),这里
	// 不用再手动转一遍——保留这条判据本身(歌名+专辑名都精确对上、且候选唯一才采信歌手名)。
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

	var chosen *neSong
	var nameOnlyArtist string
	for _, q := range queries {
		var r struct {
			Result struct {
				Songs []neSong `json:"songs"`
			} `json:"result"`
		}
		if err := get("https://music.163.com/api/search/get/web?type=1&limit=15&s="+neturl.QueryEscape(q), &r); err != nil {
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
	info := neteaseInfo{SongURL: fmt.Sprintf("https://music.163.com/song?id=%d", id)}
	// 只有本地(Apple Music)标签本身就是单一人名(没有 &/、/, 等分隔符)时,才尝试用
	// NetEase 这条数据统一拼写:哪怕 NetEase 把这首歌记成好几位歌手(如"陶喆、卢广仲"),
	// pick() 选中它已经证明其中恰好一位通过 artistMatches 核实等于本地这唯一一人——
	// 复用那次核实结果统一这一位的写法即可(实测坐实:漏了这步会导致"陶喆"在 feat.
	// 曲目里显示成原始标签"David Tao"，跟其他独唱曲目不一致)。
	// 但如果本地标签本来就是多人合credit(如"Prince & The Revolution"),就完全不碰、
	// 让 lbMeta 原样用本地标签——NetEase 对同一张专辑不同曲目的"合credit拆分"口径本就
	// 不统一(有的单曲只记 Prince、有的只记 The Revolution),拿这种残缺的单曲级别数据去
	// 顶替本地已经写全的多人credit,会悄悄丢人(实测坐实:Purple Rain 专辑好几首曲目被
	// 这样从"Prince & The Revolution"误伤成只剩"Prince"或只剩"The Revolution"，
	// 同一张专辑显示三种不同写法)。
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
	fetchBundle := func(songID int64) (lrc, tr, roma string) {
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
		}
		if err := get(fmt.Sprintf("https://music.163.com/api/song/lyric?id=%d&lv=-1&kv=-1&tv=-1&rv=-1", songID), &r); err != nil {
			return "", "", ""
		}
		return r.Lrc.Lyric, r.Tlyric.Lyric, r.Romalrc.Lyric
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
	if lrc, tr, roma := fetchBundle(id); isTimedLRC(lrc) {
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
