package main

import (
	"context"
	"testing"
	"time"
)

// 往 MusicBrainz 别名缓存里预置条目，让 canonicalArtistViaMusicBrainz 走缓存命中分支，
// 测试期间**不会发出任何网络请求**。用完恢复原样，别污染同包的其它测试。
func withCachedAliases(t *testing.T, entries map[string]string) {
	t.Helper()
	artistAliasMu.Lock()
	saved := make(map[string]string, len(artistAliasCache))
	for k, v := range artistAliasCache {
		saved[k] = v
	}
	savedDirty := artistAliasDirty
	for k, v := range entries {
		artistAliasCache[k] = v
	}
	artistAliasMu.Unlock()

	t.Cleanup(func() {
		artistAliasMu.Lock()
		artistAliasCache = saved
		artistAliasDirty = savedDirty
		artistAliasMu.Unlock()
	})
}

// 往 MusicBrainz 主名/别名缓存(musicBrainzArtistAliases 用的那份,mbPrimaryNameCache)
// 里预置条目，让它走缓存命中分支、测试期间**不会发出任何网络请求**——不传的 key 默认
// 预置成 nil(等于"查过,没有别的候选"),否则下面几个测试会在 retryArtistIdentities
// 第三步撞上真实 MusicBrainz 网络请求:2026-08-30 那次把 musicBrainzArtistAliases 从
// "只给一个主名"扩成"给全部已登记写法"之后，同一个真实歌手(比如王菲/Faye Wong)在真实
// MusicBrainz 数据里往往登记了不止一个别名(Shirley Wong / Vương Phi / 王靖雯……)，
// 不隔离掉这条真实网络查询，这些测试断言的具体候选数量会跟着 MusicBrainz 的真实数据
// 变、甚至跟着网络限速抖动，属于该隔离而没隔离。用完恢复原样，别污染同包的其它测试。
func withCachedMBAliases(t *testing.T, entries map[string][]string) {
	t.Helper()
	mbPrimaryNameMu.Lock()
	saved := make(map[string][]string, len(mbPrimaryNameCache))
	for k, v := range mbPrimaryNameCache {
		saved[k] = v
	}
	savedDirty := mbPrimaryNameDirty
	for k, v := range entries {
		mbPrimaryNameCache[k] = v
	}
	mbPrimaryNameMu.Unlock()

	t.Cleanup(func() {
		mbPrimaryNameMu.Lock()
		mbPrimaryNameCache = saved
		mbPrimaryNameDirty = savedDirty
		mbPrimaryNameMu.Unlock()
	})
}

// 核心缺陷：MusicBrainz 查到的中文名以前只写进 CanonicalArtist 这个展示字段，
// 从不拿回去当检索词用。零候选重试唯一的备选身份是那张 5 条的手工表。
func TestRetryArtistIdentitiesUsesMusicBrainzName(t *testing.T) {
	withCachedAliases(t, map[string]string{"Faye Wong": "王菲"})
	withCachedMBAliases(t, map[string][]string{"Faye Wong": nil})
	withCachedQQArtistNames(t, map[string]string{"Faye Wong": ""})

	got := retryArtistIdentities(context.Background(), "Faye Wong")
	if len(got) != 1 || got[0] != "王菲" {
		t.Fatalf("MusicBrainz 查到的名字要能当检索词, got %v", got)
	}
}

// 三个来源给出同一个名字时只搜一遍。
func TestRetryArtistIdentitiesDedupes(t *testing.T) {
	withCachedAliases(t, map[string]string{"david tao": "陶喆"})
	withCachedMBAliases(t, map[string][]string{"david tao": {"陶喆"}})
	withCachedQQArtistNames(t, map[string]string{"david tao": "陶喆"})

	got := retryArtistIdentities(context.Background(), "david tao")
	if len(got) != 1 || got[0] != "陶喆" {
		t.Fatalf("同一个名字不该搜两遍, got %v", got)
	}
}

// artistAliasTable 那张手工表 2026-08-30 从这条路径退休了(见 retryArtistIdentities
// 头注)——即便某个歌手在表里登记过,三条通用来源都查空时,retryArtistIdentities 也不该
// 再回退去翻那张表拿结果,免得两套机制在这条路径上并存、表内容跟通用查询真实数据分歧时
// 更难查。"david tao" 是手工表里确实登记过的真实条目(对应"陶喆"),这里故意验证它
// **不再**出现——三个来源都显式缓存成查空,隔离掉真实网络请求。
func TestRetryArtistIdentitiesDoesNotFallBackToHandTable(t *testing.T) {
	withCachedAliases(t, map[string]string{"david tao": ""}) // canonicalArtistViaMusicBrainz 查空
	withCachedMBAliases(t, map[string][]string{"david tao": nil})
	withCachedQQArtistNames(t, map[string]string{"david tao": ""})

	if got := retryArtistIdentities(context.Background(), "david tao"); len(got) != 0 {
		t.Fatalf("手工表已经从这条路径退休,不该再出现在结果里, got %v", got)
	}
}

// 别名跟原名实际是同一个（只差大小写/空格）时不该重试——那是拿同样的词再查一遍。
func TestRetryArtistIdentitiesSkipsOriginalName(t *testing.T) {
	withCachedAliases(t, map[string]string{"Prince": "  prince  "})
	withCachedMBAliases(t, map[string][]string{"Prince": nil})
	withCachedQQArtistNames(t, map[string]string{"Prince": ""})

	if got := retryArtistIdentities(context.Background(), "Prince"); len(got) != 0 {
		t.Fatalf("跟原名等价的不该进重试列表, got %v", got)
	}
}

// 中文歌手：canonicalArtistViaMusicBrainz 有 containsHan 守卫，直接返回空、不打网络；
// 手工表也没有对应项。musicBrainzArtistAliases 缓存命中("某个没登记过的歌手"确实
// 不存在，模拟一次真实查询查空后的缓存状态),所以列表是空的。
func TestRetryArtistIdentitiesEmptyForUnknownChineseArtist(t *testing.T) {
	withCachedMBAliases(t, map[string][]string{"某个没登记过的歌手": nil})
	if got := retryArtistIdentities(context.Background(), "某个没登记过的歌手"); len(got) != 0 {
		t.Fatalf("没有任何备选身份时应为空, got %v", got)
	}
}

// 2026-08-31 加第三条 QQ 音乐来源(cachedQQArtistCanonicalName)——MusicBrainz 两条都
// 查空时,QQ 歌手搜索建议应该能顶上,成为重试列表里唯一的候选(那英真实案例:MusicBrainz
// 对"Na Ying"排第一的是查不到中文别名的结果,QQ 反而查得到"那英")。
func TestRetryArtistIdentitiesFallsBackToQQ(t *testing.T) {
	withCachedAliases(t, map[string]string{"Na Ying": ""})
	withCachedMBAliases(t, map[string][]string{"Na Ying": nil})
	withCachedQQArtistNames(t, map[string]string{"Na Ying": "那英"})

	got := retryArtistIdentities(context.Background(), "Na Ying")
	if len(got) != 1 || got[0] != "那英" {
		t.Fatalf("MusicBrainz 都查空时应该用 QQ 查到的名字, got %v", got)
	}
}

// 本地标签恰好已经是常用名(方大同)时，knownArtistAlias 单方向查(只认"英文 → 常用名")
// 找不到——这条不该再靠手工登记反向表救回来，musicBrainzArtistAliases 这条通用查询
// 本身就该够用，对任何歌手都成立，不需要事先登记。实测案例见 musicBrainzArtistAliases
// 头注：方大同《Lovers Policy》(专辑《15》，五源真实标题是《情胜策略》)本地标签是
// "方大同"时七个源全空，标签是"Khalil Fong"时 knownArtistAlias 一步换回"方大同"、
// 标题反查轮顺利找到；这个测试锁定反过来(从"方大同"出发)也能靠通用查询换到
// "Khalil Fong"，不依赖任何手工登记。命中 MusicBrainz 的真实数据、发起真实网络请求
// (跟同文件里 TestRetryArtistIdentitiesUsesMusicBrainzName 等测试同一个前提)。
func TestRetryArtistIdentitiesGenericMusicBrainzReverseDirection(t *testing.T) {
	const artist = "方大同"
	hit := func() bool {
		for _, s := range retryArtistIdentities(context.Background(), artist) {
			if normLoose(s) == normLoose("Khalil Fong") {
				return true
			}
		}
		return false
	}
	if hit() {
		return // 命中，这条测试的正事就完成了
	}
	// ⚠️ 没命中时**必须先清掉进程内缓存再重试**:musicBrainzArtistAliases 把"这次查空"也写进
	// mbPrimaryNameCache(只是不落盘),所以同一个进程里再查一次拿到的是那个空结果,重试等于
	// 白重试 —— 这一条是 2026-09-03 实测踩出来的:第一版守卫只在事后探一次 MB,结果探针拿到
	// 200、而真查询早一秒钟撞上 503 已经把空值缓存下来了,测试照样红。
	mbPrimaryNameMu.Lock()
	delete(mbPrimaryNameCache, artist)
	mbPrimaryNameMu.Unlock()
	// 没命中时**先分清是谁的问题**（2026-09-03 加）:MusicBrainz 没答（超时/503）是对方的事，
	// 答了但没给出这个别名才是回归。混在一起报 FAIL 的代价是实测过的：那天 `go test ./...`
	// 因为这一条红了，逐层量下来发现是 MB 自己在过载 —— DNS 正常、TCP 443 0.33s 连上、HTTP
	// 回 503 且正文写着 "The MusicBrainz web server is currently busy"，配额头还剩
	// x-ratelimit-remaining: 447/1200（没超配额），而且是间歇的（隔 2 秒连打 5 次全 200，
	// 其中一次 7.3s —— 客户端超时是 6s，慢过就算失败）。
	//
	// 这种红会**吃掉整个测试套件的信号价值**:那次为了确认"这条红不是我这轮改动造成的"，
	// 要单独核实到网络层；下一个人更可能直接忽略它，连带忽略掉一条真问题。
	if err := musicBrainzAnswering(); err != nil {
		t.Skipf("MusicBrainz 这一刻没给出可用响应(%v)，跳过 —— 这条测试按设计打真实网络，"+
			"对方过载/限速时它的红不代表本仓库有回归；要复现请稍后重跑", err)
	}
	// 对方在答话:给这条真实查询第二次机会(第一次可能正好撞上它的过载卸载,实测 503 是
	// 间歇的 —— 同一分钟里连打 5 次全 200，其中一次 7.3s，而客户端超时是 6s)。
	if hit() {
		return
	}
	t.Fatalf("通用 MusicBrainz 查询应该能换回国际艺名，不需要手工登记(MB 这一刻是答话的，"+
		"两次查询都没给出 Khalil Fong)")
}

// musicBrainzAnswering 探一次 MusicBrainz 到底答不答话。**只在上面那条断言即将失败时调用**，
// 所以正常绿的时候不多打任何请求（MB 的限速是 1 req/s 按 IP 算，能省就省）。
//
// 刻意走生产同一条 `mbGetJSON`：User-Agent（MB 强制要求，不带直接 403）、6 秒超时、
// 非 200 一律当错误、审计日志 —— 这些都不该在测试里再抄一份，抄了就会跟生产漂开。
func musicBrainzAnswering() error {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := musicbrainzThrottle(ctx); err != nil {
		return err
	}
	// 最轻的一次查询，只看"它答不答"，不看答什么。
	var sink struct {
		Count int `json:"count"`
	}
	return mbGetJSON(ctx, "https://musicbrainz.org/ws/2/artist?query=a&fmt=json&limit=1", &sink)
}

// 往 QQ 歌手名缓存里预置条目，让 cachedQQArtistCanonicalName 走缓存命中分支，测试期间
// **不会发出任何网络请求**——2026-08-31 retryArtistIdentities 加了第三条 QQ 音乐来源
// 之后，不隔离这条真实网络查询的话，上面几个测试断言的候选列表会跟着 QQ 的真实搜索
// 建议变（甚至像 Prince 那样命中一条毫不相关的歌手，见 qqArtistCanonicalName 头注）。
func withCachedQQArtistNames(t *testing.T, entries map[string]string) {
	t.Helper()
	qqArtistNameMu.Lock()
	saved := make(map[string]string, len(qqArtistNameCache))
	for k, v := range qqArtistNameCache {
		saved[k] = v
	}
	savedDirty := qqArtistNameDirty
	for k, v := range entries {
		qqArtistNameCache[k] = v
	}
	qqArtistNameMu.Unlock()

	t.Cleanup(func() {
		qqArtistNameMu.Lock()
		qqArtistNameCache = saved
		qqArtistNameDirty = savedDirty
		qqArtistNameMu.Unlock()
	})
}

// 触发重试的判据是"有没有能用的候选"，不是"有没有候选"。
// Score < 0 是一票否决标记（不是逐行时间戳 / 语言对不上 / 整份只有署名行……），
// 不是"分低"。五个源都答了但全被判废时，以前 len(results)>0 会让重试根本不触发。
func TestHasUsableLyricCandidate(t *testing.T) {
	cases := []struct {
		name string
		in   []scoredLyricCandidateResult
		want bool
	}{
		{"空列表", nil, false},
		{"全被判废", []scoredLyricCandidateResult{{Score: -1}, {Score: -1}}, false},
		{"有一条能用", []scoredLyricCandidateResult{{Score: -1}, {Score: 120}}, true},
		{"零分也算能用", []scoredLyricCandidateResult{{Score: 0}}, true},
	}
	for _, c := range cases {
		if got := hasUsableLyricCandidate(c.in); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
