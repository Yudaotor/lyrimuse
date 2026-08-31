package main

import "testing"

// pickQQArtistCanonicalName 的判据——见 qqArtistCanonicalName 头注(2026-08-31,
// David Tao/Lexie Liu 通用命中案例 + Prince/Wanting 两个反例)。
func TestPickQQArtistCanonicalName(t *testing.T) {
	cases := []struct {
		suggestion, rawArtist, want, why string
	}{
		{"陶喆", "David Tao", "陶喆", "含汉字且跟输入不同,采纳"},
		{"刘柏辛Lexie", "Lexie Liu", "刘柏辛Lexie", "含汉字(即便混着拉丁字母),采纳"},
		{"Prince", "Prince", "", "不含汉字,直接没有信息增量"},
		// 婉婷/曲婉婷这个反例本身不是这个函数能判断出来的(两条建议都含汉字,函数
		// 拿不到"是不是同一个人"这个额外信息)——真正的防线是 qqArtistCanonicalName
		// 只取第一条、以及 artistAliasTable 手工登记优先于通用机制,这里只测这个
		// 纯函数自身的判据没有回归。
		{"婉婷", "Wanting", "婉婷", "含汉字且跟输入不同,函数本身没有能力识别这是另一个人"},
		{"", "Some Artist", "", "空建议"},
		{"  ", "Some Artist", "", "空白建议"},
		{"Kun", "Kun", "", "建议原样等于输入(忽略大小写),没有信息增量"},
		{"kun", "Kun", "", "建议跟输入只差大小写,视为同一个,没有信息增量"},
	}
	for _, c := range cases {
		if got := pickQQArtistCanonicalName(c.suggestion, c.rawArtist); got != c.want {
			t.Errorf("pickQQArtistCanonicalName(%q, %q) = %q, want %q (%s)",
				c.suggestion, c.rawArtist, got, c.want, c.why)
		}
	}
}

// 查空**不落盘**、查到才落盘——跟 artistAliasCache/mbPrimaryNameCache 同一条规则、
// 同一个理由(见 saveArtistAliasCache 前的 ⚠️)。
func TestQQArtistNameCachePersistsOnlyHits(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/qq-artist.json"

	savedCache, savedPath, savedDirty := qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty
	defer func() {
		qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty = savedCache, savedPath, savedDirty
	}()

	qqArtistNamePath = path
	qqArtistNameCache = map[string]string{
		"David Tao": "陶喆", // 查到了
		"Prince":    "",   // 查空(第一条建议不含汉字)
	}
	qqArtistNameDirty = true
	saveQQArtistNameCache()

	qqArtistNameCache = map[string]string{}
	loadQQArtistNameCache(path)
	if got := qqArtistNameCache["David Tao"]; got != "陶喆" {
		t.Errorf("查到的那条没被持久化:got %q", got)
	}
	if _, ok := qqArtistNameCache["Prince"]; ok {
		t.Error("查空的那条落盘了")
	}

	// 没有路径时(单测/一次性子命令)不写任何文件,也不该 panic。
	qqArtistNamePath = ""
	qqArtistNameDirty = true
	saveQQArtistNameCache()
}

// cachedQQArtistCanonicalName 的 containsHan 守卫 + 缓存命中分支:已经是中文标签的
// 不必查,缓存命中的不发网络请求。
func TestCachedQQArtistCanonicalNameGuardsAndCacheHit(t *testing.T) {
	savedCache, savedPath, savedDirty := qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty
	defer func() {
		qqArtistNameCache, qqArtistNamePath, qqArtistNameDirty = savedCache, savedPath, savedDirty
	}()
	qqArtistNamePath = ""

	if got := cachedQQArtistCanonicalName("陶喆"); got != "" {
		t.Errorf("已经是中文标签的不该查:got %q", got)
	}
	if got := cachedQQArtistCanonicalName(""); got != "" {
		t.Errorf("空输入应返回空:got %q", got)
	}

	qqArtistNameCache = map[string]string{"Cached Artist": "缓存艺人"}
	if got := cachedQQArtistCanonicalName("Cached Artist"); got != "缓存艺人" {
		t.Errorf("缓存命中应直接返回,不该发起网络请求:got %q", got)
	}
}
