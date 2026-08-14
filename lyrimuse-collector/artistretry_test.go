package main

import (
	"testing"
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

// 核心缺陷：MusicBrainz 查到的中文名以前只写进 CanonicalArtist 这个展示字段，
// 从不拿回去当检索词用。零候选重试唯一的备选身份是那张 5 条的手工表。
func TestRetryArtistIdentitiesUsesMusicBrainzName(t *testing.T) {
	withCachedAliases(t, map[string]string{"Faye Wong": "王菲"})

	got := retryArtistIdentities("Faye Wong")
	if len(got) != 1 || got[0] != "王菲" {
		t.Fatalf("MusicBrainz 查到的名字要能当检索词, got %v", got)
	}
}

// 手工表和 MusicBrainz 都有时，人工登记的排前面（那是本人公开、确凿无疑的艺名；
// MusicBrainz 是自动查询，覆盖广但偶有噪声）。
func TestRetryArtistIdentitiesPrefersHandTable(t *testing.T) {
	withCachedAliases(t, map[string]string{"david tao": "陶喆(MB版)"})

	got := retryArtistIdentities("david tao")
	if len(got) != 2 {
		t.Fatalf("两个来源都该出现, got %v", got)
	}
	if got[0] != "陶喆" {
		t.Errorf("手工登记的要排第一, got %v", got)
	}
	if got[1] != "陶喆(MB版)" {
		t.Errorf("MusicBrainz 的排第二, got %v", got)
	}
}

// 两个来源给出同一个名字时只搜一遍。
func TestRetryArtistIdentitiesDedupes(t *testing.T) {
	withCachedAliases(t, map[string]string{"david tao": "陶喆"})

	got := retryArtistIdentities("david tao")
	if len(got) != 1 || got[0] != "陶喆" {
		t.Fatalf("同一个名字不该搜两遍, got %v", got)
	}
}

// 别名跟原名实际是同一个（只差大小写/空格）时不该重试——那是拿同样的词再查一遍。
func TestRetryArtistIdentitiesSkipsOriginalName(t *testing.T) {
	withCachedAliases(t, map[string]string{"Prince": "  prince  "})

	if got := retryArtistIdentities("Prince"); len(got) != 0 {
		t.Fatalf("跟原名等价的不该进重试列表, got %v", got)
	}
}

// 中文歌手：canonicalArtistViaMusicBrainz 有 containsHan 守卫，直接返回空、不打网络；
// 手工表也没有对应项，所以列表是空的。
func TestRetryArtistIdentitiesEmptyForUnknownChineseArtist(t *testing.T) {
	if got := retryArtistIdentities("某个没登记过的歌手"); len(got) != 0 {
		t.Fatalf("没有任何备选身份时应为空, got %v", got)
	}
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
