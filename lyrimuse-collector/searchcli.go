package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

// runSearchLyricsCLI implements `collector search-lyrics -artist ... -title ...
// -album ... -duration ...`: a one-shot, no-persistent-server way for desktop-lyrics
// to let the user manually re-search lyric candidates for a specific song (its
// "歌词管理" window's "联网搜索候选歌词" feature). It reuses scoredLyricCandidatesStreaming
// (enrich.go) — the exact same NetEase/QQ/酷狗/Musixmatch/LRCLIB fetch-and-score logic the
// normal background auto-resolve path uses — so there is no second, drifting
// implementation of "how do we rank lyric sources" living in Swift.
//
// Prints one JSON object line (NDJSON, via repeated json.Encoder.Encode calls on the
// same stdout — each call already appends its own newline) per update instead of a
// single array at the end: the first line lands as soon as the first source answers,
// each later line is the full best-known-so-far ranked list including whichever
// sources have answered by then (see fetchScoredLyricCandidatesStreaming's onUpdate
// comment for why it's the whole list every time, not just the newly-arrived source),
// and the last line printed is the final result. Each line is a searchLyricsUpdate —
// not a bare candidates array (2026-08-02 changed from bare array to this wrapper) —
// so the networkLooksDown signal can ride along with the candidates without a second,
// out-of-band channel. LyricsSearchService.swift reads stdout line by line as the
// process runs (not just at exit) and replaces its displayed list with each line's
// contents — that's the "陆陆续续出来" behavior instead of waiting for everything (or
// the 20s deadline) before showing anything. Never touches enrich-cache.json (that only
// happens if/when desktop-lyrics's existing EnrichCacheStore.saveEdit persists whichever
// candidate the user picks).
func runSearchLyricsCLI(args []string) {
	fs := flag.NewFlagSet("search-lyrics", flag.ExitOnError)
	artist := fs.String("artist", "", "track artist")
	title := fs.String("title", "", "track title")
	album := fs.String("album", "", "track album")
	duration := fs.Float64("duration", 0, "track duration in seconds (for duration-match scoring)")
	// -pick:除了候选列表,再按**自动解析那一套规则**(pickLyricCandidate)选出冠军,附在最后
	// 那行 stdout 的 pick 字段里。给「歌词管理」的「重新自动匹配」按钮用 —— 冠军必须由 Go
	// 这边算:pickLyricCandidate 带一个设置分支(顺序优先模式取的是"配置顺序里第一个
	// Score>=0",不是最高分),在 Swift 侧自己取 max(score) 会跟自动决策给出不同答案,于是
	// 手动匹配的结果会被下一轮自愈路径换掉 —— 自己跟自己打架。
	pick := fs.Bool("pick", false, "also decide a winner with the automatic resolve rules (pickLyricCandidate)")
	// -current-source:这首歌眼下生效的歌词源。只给 -pick 用,复刻 rescoreDecidable 那道闸:
	// 当前源这一轮没应答时不敢下结论(它可能本来就是最优的,只是这次超时了),避免一次偶发的
	// 部分应答把用户降级到更差的一份。
	currentSource := fs.String("current-source", "", "the lyric source in effect now (for the -pick decidability guard)")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("search-lyrics: %v", err)
	}
	if *title == "" {
		fmt.Fprintln(os.Stderr, "search-lyrics: -title is required")
		os.Exit(2)
	}

	// main() 的正常启动流程会在这之后才 loadFeatureFlags(...),但这条 CLI 子命令走的是
	// os.Args[1]=="search-lyrics" 的提前分支、马上 return,永远不会执行到那一行——
	// features 这个包级变量在这里还是零值(LyricsSources 是 nil map)。手动搜索要遵循
	// "歌词"设置里的"歌词来源"开关,所以这里必须按跟 main() 完全一致的默认路径规则自己
	// 加载一遍,不然下面过滤时 nil map 对任何 key 取值都是 false,会把五个源全部误判成
	// "没启用"、直接返回空列表。
	home, err := os.UserHomeDir()
	if err == nil {
		cfgPath := filepath.Join(home, ".config", clientName, "config.json")
		features = loadFeatureFlags(filepath.Join(filepath.Dir(cfgPath), clientName+"-features.json"))
		// 同理,MusicBrainz 的歌手别名缓存也得自己加载一遍。2026-08-15 起
		// retryArtistIdentities 会在没查到可用候选时拿 canonical 名再搜一次,而
		// artistAliasPath 为空的话这份缓存既不读也不写 —— 每开一次"搜索候选歌词"
		// 弹窗都要重新打一次 MusicBrainz(它自己还有节流,直接体现为用户多等)。
		loadArtistAliasCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-artist-alias-cache.json"))
		// 同理,MB 主名那份也要读 —— 这条 CLI 每次都是新进程,不读的话每开一次弹窗都要
		// 重打一次 MusicBrainz,撞上限速(1 req/s 按 IP,而节流是进程内的)就等于这轮
		// 别名兜底整个失效:表现是"同一首歌第一遍搜 0 条、再搜一遍就有"。
		loadMBPrimaryNameCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-artist-primary-cache.json"))
		// Apple 目录锚点那份也读:手动搜索走的是独立进程,不读的话
		// appleCatalogSearchIdentities 恒为空,「联网搜索候选歌词」拿不到常驻实例已经
		// 攒下的权威署名,名次又会跟自动决策对不上(跟 nativeLyricSource 那个坑同型)。
		loadAppleCatalogCache(filepath.Join(filepath.Dir(cfgPath), clientName+"-apple-catalog-cache.json"))
		// ⚠️ 2026-08-21 补:main() 在 loadFeatureFlags 之后紧跟着有这一行,而这条 CLI 子命令
		// 在那之前就 return 了 —— 于是 match.go 里那个包级 nativeLyricSource 一直是空串,
		// "与当前播放器同源 +250"(match.go 的 sameSourceAsPlayer 档)在手动搜索里**恒为 0**。
		// 后果不是"少一点分"而是排序口径不同:冠亚军分差中位只有 22 分、74% 的歌 ≤40 分,
		// 250 分足以翻盘(qq 与 kugou 的分差常年只有 9 分)。所以在此之前,「联网搜索候选歌词」
		// 展示的名次跟 collector 自动决策的名次对不上,用 QQ/网易云/酷狗 听歌的用户尤其明显。
		// -pick 要拿这套规则选冠军,这个差异必须先补掉。
		nativeLyricSource = playerNativeLyricSource(features.Player)
	}

	// 跟 enrich.go 的 resolveTrackEnrichment 同一个理由:NetEase/QQ/酷狗/LRCLIB 的
	// 搜索索引是简体中文,本地 Apple Music 标签若是繁体(比如"周杰倫"),繁体原文直接
	// 发起搜索请求会查不到任何候选——这个 CLI 子命令是 desktop-lyrics"联网搜索候选
	// 歌词"功能唯一的数据来源,不经过 resolveTrackEnrichment,必须单独转换一遍,不能
	// 指望那边的修复覆盖到这里。
	sArtist, sTitle, sAlbum := toSimplified(*artist), toSimplified(*title), toSimplified(*album)
	enc := json.NewEncoder(os.Stdout)
	var appleTitle, appleAlbum string
	// 只在最后那行带上(赋值发生在收尾的 emit 之前),流式的中间行不带 —— 冠军要等所有源
	// 都到齐才有意义。
	var finalPick *searchLyricsPick
	emit := func(_ neteaseInfo, results []scoredLyricCandidateResult, done, total int) {
		// networkLooksDown() 2026-08-02 补上——之前每行 stdout 只是候选数组本身,五个源
		// 都没查到时 desktop-lyrics 只能显示一句笼统的"都没找到",分不清是这首歌真的没有
		// 网络歌词,还是网络整体不通导致五个源的请求全部发不出去。见 networkobs.go 的
		// 注释,这里额外带上这个信号,让前端能区分这两种情况、给出不同的提示文案。
		update := searchLyricsUpdate{
			Candidates:       filterEnabledLyricSources(results),
			NetworkLooksDown: networkLooksDown(),
			SourcesDone:      done,
			SourcesTotal:     total,
			AppleTitle:       appleTitle,
			AppleAlbum:       appleAlbum,
			Pick:             finalPick,
		}
		for _, r := range results {
			if r.Instrumental {
				update.Instrumental = true
				update.LegacyLrclibInstrumental = true // 过渡期,见字段注释
			}
		}
		if err := enc.Encode(update); err != nil {
			log.Fatalf("search-lyrics: encode results: %v", err)
		}
	}
	_, results := scoredLyricCandidatesStreaming(sArtist, sTitle, sAlbum, *duration, emit)
	// 苹果侧元数据:搜索里的 applecover goroutine 用同一组关键词查过、通常已写热
	// appleURLCache(同 key)。这里**只读缓存**——查无此歌时它不写缓存,真去查会在
	// "这轮搜索结束了"那行之前同步重跑一整轮 CN+US 搜索,把收尾挂住几秒(2026-08-12 审阅);
	// 这两个字段是给下一轮评测攒的数据,缺一次无妨,不值得让用户等。
	appleMatch := appleMusicMatchCachedOnly(sArtist, sTitle, sAlbum)
	appleTitle, appleAlbum = appleMatch.title, appleMatch.album
	// 只在 -pick 时才去读缓存文件:另一颗按钮(纯搜索候选)用不到这个事实。
	noCurrentLyrics := false
	if *pick && home != "" {
		cachePath := filepath.Join(home, ".config", clientName, clientName+"-enrich-cache.json")
		if empty, known := lyricsEmptyInCacheFile(cachePath, *artist, *title, *album); known {
			noCurrentLyrics = empty
		}
	}
	if *pick {
		// 跟 rescoreLyrics(enrich.go)逐行对齐:同一个 pickLyricCandidate、同一个
		// rescoreDecidable、同一份 seen/responded、同一个 buildLyricsDecision。调用方按
		// 这些字段写缓存,写出来的形状就跟自动 rescore 写的一模一样(那条路径是这个仓库
		// 里唯一经受过考验的"重新选一次歌词"实现)。
		picked := pickLyricCandidate(results)
		p := &searchLyricsPick{
			ScoringVersion: lyricsScoringVersion,
			// ⚠️ 这里**必须去缓存里读真相**,不能用 `*currentSource == ""` 推断
			// "这条没有歌词"。2026-08-22 对抗性复核抓到的反例:
			// EnrichCacheStore.saveEdit 的 source 参数默认 nil,而「歌词管理」里那颗
			// 「保存修改」正是 `saveEdit(key:lyrics:tr:roma:)`(不传 source)——它会
			// `removeValue(forKey: "lyrics_source")`,导出的 .lrc 也不带 [source:],
			// 于是**每一条用户手改过的条目**都是「有歌词 + lyrics_source 为空」,
			// summary.lyricsSource 传过来就是空串。照推断走的话,这道闸会对手改条目
			// 一律放行,让冠军覆盖掉人工修正过的正文(那份内容删了找不回来)。
			//
			// 当初那个"294 条里 0 例外"的测量取样取错了:现役缓存里手改条目是 0 条 ——
			// 因为老库那 33 条手改记录同一天早些时候刚被移走。在一个恰好没有反例的
			// 数据集上做的测量,证明不了不变量。
			//
			// 读不出来(known=false)时按最保守的那一支走,行为等同改动之前。
			Decidable:            rescoreDecidable(results, *currentSource, noCurrentLyrics),
			SourcesSeen:          lyricSourcesWithCandidates(results),
			SourcesResponded:     lyricSourcesResponded(results),
			ResolvedDurationSecs: *duration,
			Mode:                 features.LyricsSourceMode,
		}
		if picked != nil {
			p.Winner = picked.Source
			p.WinnerScore = picked.Score
		}
		// 决策存档:只在"可判"时写,理由跟 rescoreLyrics 里那段一样 —— 当前源没应答的那一轮
		// 没有做出任何决定,拿它盖掉上一份完整评估的证据是纯损失。
		//
		// ⚠️ Applied 这里给的是**近似值**:CLI 看不到缓存里的正文,只能按"冠军是否换了源"判,
		// 于是"同源但换了内容"会被算成 false。调用方(EnrichCacheStore 那条采纳路径)知道真相,
		// **必须覆写它** —— 不覆写的话「解析决策」弹窗会把 false 渲染成「评估后维持原状」,
		// 跟结果行说的"已换成一份"直接打架(2026-08-21 用户实测撞到过)。
		if p.Decidable {
			d := buildLyricsDecision(lyricsDecisionPathManualRematch, sArtist, sTitle, sAlbum, *duration,
				results, picked, picked != nil && picked.Source != *currentSource)
			if raw, err := json.Marshal(d); err == nil {
				p.DecisionJSON = string(raw)
			}
		}
		finalPick = p
	}
	// 保底再打印一次最终结果——通常这跟 emit 在最后一个源到达时已经打过的那一行内容
	// 完全一样(纯防御性的重复),唯一真正需要它的场景是:20 秒兜底超时在第一个源都还
	// 没回来时就已经触发(五个源全部异常缓慢),这种极端情况下循环里的 emit 一次都没
	// 被调用过,不能让 Swift 那边一行 stdout 都收不到、误判成"进程没有任何输出"。
	// 这一行代表"这轮搜索结束了",所以进度直接报满 —— 即便是 20 秒兜底超时提前收场,
	// 也不该让弹窗停在 3/5 让人以为还在查(真正"还在查"由进程是否退出决定,见 Swift 侧)。
	emit(neteaseInfo{}, results, enabledLyricSourceCount(), enabledLyricSourceCount())
}

// searchLyricsUpdate 是 search-lyrics 每行 stdout 输出的实际结构——2026-08-02 从裸
// candidates 数组改成这个包一层的对象,好让 networkLooksDown 这个信号跟候选列表一起
// 传给 Swift 那边,不用另开一条带外的信息通道。字段名用大写导出是 encoding/json
// 序列化的要求,LyricsSearchService.swift 那边按同样的字段名(小写开头,Swift 惯例)
// 解码。
type searchLyricsUpdate struct {
	Candidates       []scoredLyricCandidateResult `json:"candidates"`
	NetworkLooksDown bool                         `json:"networkLooksDown"`
	// 歌词源的完成进度,给弹窗显示 (X/Y)——语义见 lyricSearchUpdateFunc 的注释。
	SourcesDone  int `json:"sourcesDone"`
	SourcesTotal int `json:"sourcesTotal"`
	// 2026-08-12 起的透传字段,给下一轮打分维度评测攒数据(Swift 端不认识就忽略,无影响):
	// AppleTitle/AppleAlbum:iTunes(第六方,不与五歌词源共享曲库)匹配到的歌名/专辑名,
	// 只在最终那行输出上带(拿的是搜索过程中 applecover goroutine 已写热的同 key 缓存,
	// 不多打网络);Instrumental:有源明确说这首歌是纯音乐(独立字段,不再只靠
	// Score:-1 哨兵行传递,消费端能与普通 reject 可靠区分)。
	AppleTitle string `json:"appleTitle,omitempty"`
	AppleAlbum string `json:"appleAlbum,omitempty"`
	// Instrumental:有源明确断言"这首本来就没有词"。2026-08-22 从 lrclibInstrumental 改名 ——
	// 这个信号的来源早就不只 lrclib 了:2026-08-20 加了网易云的 pureMusic/占位正文,
	// 2026-08-22 又加了 QQ 的占位断言(见第 09 章「纯音乐标记的三个来源」),字段名一直没跟上。
	Instrumental bool `json:"instrumental,omitempty"`
	// LegacyLrclibInstrumental 是**过渡期**的同值别名,只为兜住一件事:collector 和 App 是
	// 两个独立部署的二进制(lyrimuse-collector/build.sh 只换 collector、不重建 App),所以
	// 换了 collector 之后跑的可能还是旧 App —— 旧 App 只认 lrclibInstrumental 这个 key,
	// 单方面改名会让「有源明确说这首是纯音乐」这类文案在重建 App 之前静默退化成
	// 「这一轮没有一个能用的候选」。
	//
	// ⚠️ **删除条件**:App 侧带着「优先读 instrumental、缺失才退回 lrclibInstrumental」那段
	// 解码(LyricsSearchService.RawSearchUpdate)重新构建并安装之后,这个字段就可以删掉。
	// 它是唯一的存在理由,别让它长住。
	LegacyLrclibInstrumental bool `json:"lrclibInstrumental,omitempty"`
	// 只有 -pick 且只有最后那行才有(见 searchLyricsPick)。
	Pick *searchLyricsPick `json:"pick,omitempty"`
}

// searchLyricsPick 是 -pick 模式下"按自动解析规则重选一次"的结论,给「歌词管理」的
// 「重新自动匹配」按钮用。字段是照 rescoreLyrics 实际写进 enrichEntry 的那一套挑的,
// 调用方(EnrichCacheStore.rematchAdopt)按它写缓存,写出来的形状跟自动 rescore 一致。
//
// 为什么冠军非要 Go 这边算:pickLyricCandidate 有设置分支 —— 顺序优先模式取的是"用户
// 配置顺序里第一个 Score>=0 的源",不是最高分;而且它还要过 features.LyricsSources 的
// 启用过滤、跳掉 Score<0 的废候选(五源全废时自动路径一个字都不写)。这三条在 Swift 侧
// 复制一遍就是第二份会漂的决策规则,而漂的表现是"手动匹配完,下一拍自愈路径又给换了"。
type searchLyricsPick struct {
	// 冠军的源;空串 = 一个能用的候选都没有(全被判废/全没搜到),调用方**不许**退回
	// "取第一条",那会把一份明确不可用的歌词写进去。
	Winner      string `json:"winner,omitempty"`
	WinnerScore int    `json:"winnerScore"`
	// 写进 lyrics_scoring_version:不写这个,下次播放时 needsLyricsRescore 会立刻再跑一遍
	// (首次判定不受 1 小时节流约束)。必须跟 lyrics_score 成对写 —— 只写版本不写分数,
	// retry 的比较基准会变成 0,"严格更高才替换"那道闸等于被拆掉。
	ScoringVersion int `json:"scoringVersion"`
	// 复刻 rescoreDecidable:当前源这一轮没应答时为 false,调用方应当**什么都不改**并如实
	// 告诉用户"这轮 X 源没应答,没有换"。
	Decidable            bool     `json:"decidable"`
	SourcesSeen          []string `json:"sourcesSeen,omitempty"`
	SourcesResponded     []string `json:"sourcesResponded,omitempty"`
	ResolvedDurationSecs float64  `json:"resolvedDurationSecs,omitempty"`
	// smart / priority —— 结果文案如实说明这轮按哪套规则选的(设置页那个「匹配算法」)。
	Mode string `json:"mode,omitempty"`
	// lyricsDecision 的 JSON 原文。传字符串而不是嵌套对象:调用方要把它原样塞进
	// enrich-cache.json 的 lyrics_decision 字段,走字符串就不需要在 Swift 侧再镜像一遍
	// 这个结构(镜像就会漂),解析成 [String: Any] 直接写回即可。
	DecisionJSON string `json:"decisionJSON,omitempty"`
}

// filterEnabledLyricSources drops candidates from sources the user disabled via
// the "歌词"设置's "歌词来源" toggles (features.LyricsSources) — mirrors
// pickLyricCandidate's filtering for the automatic resolve path, so manual search
// and automatic resolve now agree on which sources are in play. Falls back to
// returning everything unfiltered only if features.LyricsSources somehow ended up
// empty (should not happen in practice — loadFeatureFlags always resolves it to
// all-four-enabled when unset, see resolveLyricsSources — this is just a safety
// net against showing zero candidates instead of trusting a genuinely-empty map).
//
// 顺带把 Instrumental 标记条目也过滤掉(2026-08-03 补上)——那不是一条真的候选歌词,
// 是"lrclib 说这首歌是纯音乐"这个信号借 scored 列表搭车传出来的(见
// scoredLyricCandidateResult.Instrumental 定义处的注释),"歌词管理"的手动搜索弹窗
// 只该看到真正可以点选采用的候选,不该多出一行歌词是空的、点了也没用的候选。
func filterEnabledLyricSources(results []scoredLyricCandidateResult) []scoredLyricCandidateResult {
	filtered := make([]scoredLyricCandidateResult, 0, len(results))
	for _, r := range results {
		if r.Instrumental {
			continue
		}
		if len(features.LyricsSources) > 0 && !features.LyricsSources[r.Source] {
			continue
		}
		filtered = append(filtered, r)
	}
	return filtered
}

// lyricsEmptyInCacheFile 只读地回答一句:enrich 缓存里这首歌现在**有没有歌词**。
//
// 为什么不复用 loadEnrichCache:那个会设 enrichPath(等于给这个一次性进程开了写权限)、
// 解析失败时还会把用户的缓存文件改名成 .corrupt。这条路径只想读一个字段,不该有任何
// 副作用。
//
// 返回 known=false 表示"问不出来"(文件读不了/解析不动),调用方必须按**最保守**的那一支走。
// key 不存在算 empty=true:那就是一首还没被解析过的新歌,本来就没有歌词。
//
// ⚠️ key 用**原样**标签算(enrichKey 内部只做 cleanMediaTag/normEnrichTitle,不做繁简转换),
// 所以这里传的必须是命令行原参数,不是 toSimplified 之后那三个。
func lyricsEmptyInCacheFile(path, artist, title, album string) (empty bool, known bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return false, false
	}
	var m map[string]struct {
		Lyrics string `json:"lyrics"`
	}
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		return false, false
	}
	e, ok := m[enrichKey(artist, title, album)]
	if !ok {
		return true, true
	}
	return e.Lyrics == "", true
}
