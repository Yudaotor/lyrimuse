package main

import (
	"context"
	"reflect"
	"testing"
)

// 2026-08-05 实测排查坐实的真实 bug 的回归测试:欧美艺人在 MusicBrainz 上的中文别名
// 只是面向中文市场的译名,不该被当成 canonical_artist —— 用户反馈"历史里 Michael
// Jackson 显示成迈克尔·杰克逊,跟之前的英文名不一致"。详见 pickChineseAlias 的注释。
func TestPickChineseAlias(t *testing.T) {
	// 下面每组别名/地区都是照真实 MusicBrainz API 返回抄的(实测查过这三个艺人)。
	mjAliases := []mbAlias{
		{Name: "迈克尔·杰克逊", Locale: "yue_Hans_CN"},
		{Name: "迈克尔·杰克逊", Locale: "zh_Hans"},
	}
	chanAliases := []mbAlias{
		{Name: "陈柏宇", Locale: "zh_Hans"},
		{Name: "陳柏宇", Locale: "zh_Hant"},
	}
	douAliases := []mbAlias{
		{Name: "窦靖童", Locale: "zh_Hans"},
	}

	cases := []struct {
		label   string
		aliases []mbAlias
		country string
		want    string
	}{
		// 核心回归:美国艺人的中文译名必须被拒绝。注意它的 type/primary 跟下面港台
		// 艺人完全一样(实测坐实),所以只能靠 country 区分,见 pickChineseAlias 注释。
		{"美国艺人(Michael Jackson)的中文译名不采纳", mjAliases, "US", ""},
		{"英国艺人同理", mjAliases, "GB", ""},
		// 中文圈艺人:中文名确实是本人的名字,照常采纳。
		{"香港艺人(陈柏宇)采纳中文名", chanAliases, "HK", "陈柏宇"},
		{"大陆艺人(窦靖童)采纳中文名", douAliases, "CN", "窦靖童"},
		{"台湾/澳门/新加坡同属中文圈", chanAliases, "TW", "陈柏宇"},
		{"新加坡(华语歌手常见归属)", chanAliases, "SG", "陈柏宇"},
		// country 缺失时保守放弃,交给后面的网易云那一层接手(见函数注释)。
		{"country 缺失时不采纳", chanAliases, "", ""},
		// 大小写/空白不该影响判定。
		{"country 小写也认", chanAliases, "hk", "陈柏宇"},
		{"country 带空白也认", chanAliases, " HK ", "陈柏宇"},
		// 繁体别名会被转成简体(既有行为,不能因为这次改动丢掉)。
		{"繁体别名转简体", []mbAlias{{Name: "陳柏宇", Locale: "zh_Hant"}}, "HK", "陈柏宇"},
		// 日文 locale 的汉字别名仍要跳过(既有行为)。
		{"日文 locale 别名跳过", []mbAlias{{Name: "日本語名", Locale: "ja"}}, "HK", ""},
		{"没有任何含汉字别名", []mbAlias{{Name: "Some Latin Name", Locale: "en"}}, "HK", ""},
		{"空别名列表", nil, "HK", ""},
		// 2026-08-18 实测翻车:ØZI(TW)在 MusicBrainz 有一条 type="Legal name" 的
		// 「陳奕凡」,拿它当显示名等于把艺人改叫回身份证名。法定名/搜索提示要跳过,
		// 但后面正经的艺名别名照常采纳。
		{"法定名别名跳过", []mbAlias{{Name: "陳奕凡", Locale: "zh_Hant", Type: "Legal name"}}, "TW", ""},
		{"搜索提示别名跳过", []mbAlias{{Name: "某搜索词", Type: "Search hint"}}, "TW", ""},
		{"跳过法定名后仍采纳后面的艺名", []mbAlias{
			{Name: "陳奕凡", Locale: "zh_Hant", Type: "Legal name"},
			{Name: "街巷", Locale: "zh_Hant", Type: "Artist name"},
		}, "TW", "街巷"},
	}
	for _, c := range cases {
		if got := pickChineseAlias(c.aliases, c.country); got != c.want {
			t.Errorf("%s: pickChineseAlias(...) = %q, want %q", c.label, got, c.want)
		}
	}
}

// 查空**不落盘**、查到才落盘(2026-08-30)——跟 mbPrimaryNameCache 那条同一条规则、同一个
// 理由(见 TestMBPrimaryNameCachePersistsOnlyHits 的注释)。这份缓存原来是"查一次永久
// 生效,空值也当确定结果落盘",那英《微笑着离去》真撞上了:MusicBrainz 恰好限速 503,
// 空结果被永久钉在 "Na Ying" 名下,之后不管 MusicBrainz 是否恢复都不会再重查。
func TestArtistAliasCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/alias.json"

	savedCache, savedPath, savedDirty := artistAliasCache, artistAliasPath, artistAliasDirty
	defer func() {
		artistAliasCache, artistAliasPath, artistAliasDirty = savedCache, savedPath, savedDirty
	}()

	artistAliasPath = path
	artistAliasCache = map[string]string{
		"David Tao": "陶喆", // 查到了
		"Na Ying":   "",   // 查空(可能只是被限速,见上面头注)
	}
	artistAliasDirty = true
	saveArtistAliasCache()

	artistAliasCache = map[string]string{}
	loadArtistAliasCache(path)
	if got := artistAliasCache["David Tao"]; got != "陶喆" {
		t.Errorf("查到的那条没被持久化:got %q", got)
	}
	if _, ok := artistAliasCache["Na Ying"]; ok {
		t.Error("查空的那条落盘了 —— 一次偶发限速会被永久钉死")
	}

	// 没有路径时(单测/一次性子命令)不写任何文件,也不该 panic。
	artistAliasPath = ""
	artistAliasDirty = true
	saveArtistAliasCache()
}

// canonicalArtistViaMusicBrainz 写缓存那一步:查空只留在内存(供同一进程内不重复查询),
// 不标记为脏、不触发落盘。
func TestCanonicalArtistViaMusicBrainzCacheHitSkipsNetwork(t *testing.T) {
	savedCache, savedPath, savedDirty := artistAliasCache, artistAliasPath, artistAliasDirty
	defer func() {
		artistAliasCache, artistAliasPath, artistAliasDirty = savedCache, savedPath, savedDirty
	}()

	artistAliasPath = ""
	artistAliasCache = map[string]string{"Cached Artist": "缓存艺人"}
	artistAliasDirty = false

	if got := canonicalArtistViaMusicBrainz(context.Background(), "Cached Artist"); got != "缓存艺人" {
		t.Errorf("缓存命中应直接返回,不该发起网络请求:got %q", got)
	}
	if !reflect.DeepEqual(artistAliasCache, map[string]string{"Cached Artist": "缓存艺人"}) {
		t.Errorf("缓存命中不该修改缓存内容:got %v", artistAliasCache)
	}
}

// resolveGenericArtistCanonicalName 必须先查 artistAliasTable 再试通用机制,不能反过来
// ——2026-08-31 真实bug:"Wanting"的 QQ 歌手搜索建议第一条是"婉婷"(查证过是另一个人,
// 见 qqArtistCanonicalName 头注),如果通用机制排在手工表前面,会先给出这个错误答案、
// 手工表里登记的"曲婉婷"根本没有机会生效。这里用缓存直接模拟"QQ 查到了(错误的)结果"
// 这个状态,断言手工表登记过的名字仍然赢。
func TestResolveGenericArtistCanonicalNamePrefersHandTableOverGenericMisfire(t *testing.T) {
	savedQQCache, savedQQPath, savedQQDirty := qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty
	savedAlias := artistAliasCache
	defer func() {
		qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty = savedQQCache, savedQQPath, savedQQDirty
		artistAliasCache = savedAlias
	}()
	qqArtistNamePath = ""
	artistAliasCache = map[string]string{}
	// 模拟 QQ 已经查到(错误的)"婉婷"并缓存住了这个状态。
	qqArtistNameCache = map[string]string{"wanting": "婉婷"}

	if got := resolveGenericArtistCanonicalName(context.Background(), "wanting"); got != "曲婉婷" {
		t.Errorf("手工表应该优先于通用机制的(错误)结果:got %q, want 曲婉婷", got)
	}
}
