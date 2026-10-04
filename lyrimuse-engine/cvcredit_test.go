package main

import (
	"context"
	"reflect"
	"testing"
)

// CV 括号的各种写法拆出同一套结构;不是 CV 括号的原样留在段落里。
func TestParseCVCredit(t *testing.T) {
	cases := []struct {
		in                        string
		actors, characters, other []string
	}{
		{"角色甲(CV:声优甲)", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲（CV：声优甲）", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲 (CV. 声优甲)", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲(cv.声优甲)", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲（ＣＶ：声优甲）", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲(CV 声优甲)", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲(CV声优甲)", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色 甲(CV:声优 甲)", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"Chara A (CV: Seiyuu A)", []string{"Seiyuu A"}, []string{"Chara A"}, nil},
		{"角色甲(CV:声优甲) & 角色乙(CV:声优乙)", []string{"声优甲", "声优乙"}, []string{"角色甲", "角色乙"}, nil},
		{"角色甲(CV:声优甲)&角色乙(CV:声优乙)", []string{"声优甲", "声优乙"}, []string{"角色甲", "角色乙"}, nil},
		{"角色甲(CV:声优甲)、角色乙(CV:声优乙)、角色丙(CV:声优丙)", []string{"声优甲", "声优乙", "声优丙"}, []string{"角色甲", "角色乙", "角色丙"}, nil},
		{"角色甲 (CV.声优甲), 角色乙 (CV.声优乙) & 角色丙 (CV.声优丙)", []string{"声优甲", "声优乙", "声优丙"}, []string{"角色甲", "角色乙", "角色丙"}, nil},
		{"组合名, 角色甲 (CV:声优甲) & 角色乙 (CV:声优乙)", []string{"声优甲", "声优乙"}, []string{"角色甲", "角色乙"}, []string{"组合名"}},
		{"角色甲(CV.声优甲) & 组合名", []string{"声优甲"}, []string{"角色甲"}, []string{"组合名"}},
		{"组合名/角色甲(CV:声优甲)、角色乙(CV:声优乙)", []string{"声优甲", "声优乙"}, []string{"角色甲", "角色乙"}, []string{"组合名"}},
		{"组合名(CV.声优甲・声优乙・声优丙)", []string{"声优甲", "声优乙", "声优丙"}, []string{"组合名"}, nil},
		{"组合名(CV:声优甲、cv.声优乙、cv.声优丙)", []string{"声优甲", "声优乙", "声优丙"}, []string{"组合名"}, nil},
		{"组合名(CV.声优甲･声优乙･声优丙)", []string{"声优甲", "声优乙", "声优丙"}, []string{"组合名"}, nil},
		{"「角色甲」（CV：声优甲）", []string{"声优甲"}, []string{"角色甲"}, nil},
		{"角色甲 with 组合名(cv.声优甲 with 声优乙)", []string{"声优甲", "声优乙"}, []string{"组合名"}, []string{"角色甲"}},
		{"角色甲(CV:M・A・O)", []string{"M・A・O"}, []string{"角色甲"}, nil},
		{"Unit -GRAC&E-, 角色甲 (CV.声优甲)", []string{"声优甲"}, []string{"角色甲"}, []string{"Unit -GRAC&E-"}},
		{"AB/CD & 角色甲(CV:声优甲)", []string{"声优甲"}, []string{"角色甲"}, []string{"AB/CD"}},
		{"(CV:声优甲)", []string{"声优甲"}, nil, nil},
		{"角色甲(CV:声优甲), 角色乙(CV:声优甲)", []string{"声优甲"}, []string{"角色甲", "角色乙"}, nil},
	}
	for _, c := range cases {
		got, ok := parseCVCredit(c.in)
		if !ok {
			t.Errorf("%q 该认成 CV 署名", c.in)
			continue
		}
		if !reflect.DeepEqual(got.actors, c.actors) || !reflect.DeepEqual(got.characters, c.characters) || !reflect.DeepEqual(got.others, c.other) {
			t.Errorf("%q = actors %q characters %q others %q, 要 %q %q %q", c.in, got.actors, got.characters, got.others, c.actors, c.characters, c.other)
		}
	}
}

// 普通括号、名字里的 CV 字母、括号里没写名字、括号没闭合都不当 CV 署名。
func TestParseCVCreditRejects(t *testing.T) {
	for _, in := range []string{
		"歌手(Alias)",
		"歌手（别名）",
		"CVLTE",
		"Band (CVLTE)",
		"角色甲(CV)",
		"角色甲(CV:)",
		"角色甲(CV:声优甲",
		"角色甲 CV:声优甲",
		"",
	} {
		if c, ok := parseCVCredit(in); ok {
			t.Errorf("%q 不该认成 CV 署名: %+v", in, c)
		}
	}
}

// 换名重查从 CV 署名里拿第一位声优、第一个不带 CV 的名字;多人时不把每一位都列出来,也不拿角色名。
func TestCVRetryIdentities(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"角色甲(CV:声优甲)", []string{"声优甲"}},
		{"角色 甲(CV:声优 甲)", []string{"声优甲"}},
		{"角色甲(CV:声优甲) & 角色乙(CV:声优乙) & 角色丙(CV:声优丙)", []string{"声优甲"}},
		{"角色甲(CV.声优甲) & 组合名", []string{"声优甲", "组合名"}},
		{"组合名, 角色甲 (CV:声优甲) & 角色乙 (CV:声优乙)", []string{"声优甲", "组合名"}},
		{"(CV:声优甲)", []string{"声优甲"}},
		{"歌手(Alias)", nil},
		{"歌手甲 & 歌手乙", nil},
	}
	for _, c := range cases {
		if got := identityNames(cvRetryIdentities(c.in)); !reflect.DeepEqual(got, c.want) {
			t.Errorf("cvRetryIdentities(%q) = %q, 要 %q", c.in, got, c.want)
		}
	}
}

// retryArtistIdentities 对 CV 署名先给声优和团体,不再给 hanOnlyPortion 取的半截汉字。
func TestRetryArtistIdentitiesCVCredit(t *testing.T) {
	for artist, want := range map[string][]string{
		"来栖 翔(CV.下野 紘) & 组合名": {"下野紘", "组合名"},
		"山城 恋(CV:花澤 香菜)":      {"花澤香菜"},
	} {
		withEnrichCache(t, nil)
		withCachedAliases(t, map[string]string{artist: ""})
		withCachedMBAliases(t, map[string][]string{artist: nil})
		withCachedQQArtistNames(t, map[string]string{artist: ""})
		if got := retryArtistIdentities(context.Background(), artist); !reflect.DeepEqual(got, want) {
			t.Errorf("retryArtistIdentities(%q) = %q, 要 %q", artist, got, want)
		}
	}
}

// 歌手比对:CV 署名对得上它写明的声优、角色(全角括号也算),对得上源里按声优列的合唱名单;反过来源里是 CV 署名、
// 本地只写声优也对得上。两边都是 CV 署名时要有一对角色和声优都相同:同一位声优唱的另一个角色、同一个角色换了声优、
// 同一团体的另几位成员都对不上。别的人、仿冒写法仍然对不上;不带 CV 的括号里的名字按同一位演唱者的另一个名字算
// (见 artistnameform.go)。
func TestArtistMatchesCVCredit(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"角色甲(CV:声优甲)", "声优甲", true},
		{"声优甲", "角色甲(CV:声优甲)", true},
		{"角色甲（CV：声优甲）", "角色甲", true},
		{"角色甲(CV:声优 甲)", "声优甲", true},
		{"角色甲(CV:声优甲) & 角色乙(CV:声优乙)", "声优乙", true},
		{"声优甲/声优乙", "角色甲(CV:声优甲)、角色乙(CV:声优乙)", true},
		{"角色甲(CV:声优甲)", "角色乙(CV:声优甲)", false},
		{"角色甲(CV:声优甲)", "角色甲(CV:声优乙)", false},
		{"组合名, 角色甲(CV:声优甲)", "组合名, 角色乙(CV:声优乙)", false},
		{"角色甲(CV:声优甲)、角色乙(CV:声优乙)", "角色甲(CV:声优甲)", true},
		{"角色甲 (CV: 声优 甲)", "角色甲(CV:声优甲)", true},
		{"「角色甲」（CV：声优甲）", "角色甲(CV:声优甲)", true},
		{"组合名(CV.声优甲･声优乙)", "组合名(CV.声优甲・声优乙)", true},
		{"(CV:声优甲)", "角色甲(CV:声优甲)", true},
		{"角色甲(CV:声优甲)", "声优乙", false},
		{"角色甲(CV:声优甲)", "声优甲-", false},
		{"角色甲 (声优甲)", "声优甲", true},
		{"角色甲 (声优甲)", "声优乙", false},
	}
	for _, c := range cases {
		if got := artistMatches(c.a, c.b); got != c.want {
			t.Errorf("artistMatches(%q, %q) = %v, 要 %v", c.a, c.b, got, c.want)
		}
		if got := lyricSourceArtistMatches(c.a, c.b); got != c.want {
			t.Errorf("lyricSourceArtistMatches(%q, %q) = %v, 要 %v", c.a, c.b, got, c.want)
		}
	}
}

// 每个带 CV 括号的段配出「角色 + 声优」:一段里的每一位声优各一对,括号前没写角色的那一对角色为空,不带 CV 的段不配。
func TestParseCVCreditPairs(t *testing.T) {
	cases := []struct {
		in   string
		want []cvPair
	}{
		{"角色甲(CV:声优甲)、角色乙(CV:声优乙)", []cvPair{{"角色甲", "声优甲"}, {"角色乙", "声优乙"}}},
		{"组合名(CV.声优甲・声优乙)", []cvPair{{"组合名", "声优甲"}, {"组合名", "声优乙"}}},
		{"组合名, 角色甲 (CV:声优甲) & 角色乙 (CV:声优乙)", []cvPair{{"角色甲", "声优甲"}, {"角色乙", "声优乙"}}},
		{"(CV:声优甲)", []cvPair{{"", "声优甲"}}},
		{"角色甲(CV:声优甲)(CV:声优乙)", []cvPair{{"角色甲", "声优甲"}, {"角色甲", "声优乙"}}},
		{"角色甲(CV:声优甲)、角色乙(CV:声优甲)", []cvPair{{"角色甲", "声优甲"}, {"角色乙", "声优甲"}}},
		{"角色\x00甲(CV:声优甲)", []cvPair{{"角色甲", "声优甲"}}},
	}
	for _, c := range cases {
		got, ok := parseCVCredit(c.in)
		if !ok || !reflect.DeepEqual(got.pairs, c.want) {
			t.Errorf("parseCVCredit(%q).pairs = %q (ok=%v), 要 %q", c.in, got.pairs, ok, c.want)
		}
	}
}

// 同一串署名换一种分隔写法(顿号、逗号、&、斜杠、全角标点,播放器把多位歌手拼成一串时常见的几种),拆出来的结构一样,
// 互相也对得上。
func TestParseCVCreditSeparatorsEquivalent(t *testing.T) {
	forms := []string{
		"角色甲(CV:声优甲)、角色乙(CV:声优乙)、角色丙(CV:声优丙)",
		"角色甲 (CV: 声优甲), 角色乙 (CV: 声优乙), 角色丙 (CV: 声优丙)",
		"角色甲(CV.声优甲), 角色乙(CV.声优乙) & 角色丙(CV.声优丙)",
		"角色甲(CV:声优甲)/角色乙(CV:声优乙)/角色丙(CV:声优丙)",
		"角色甲（CV：声优甲），角色乙（CV：声优乙）＆角色丙（CV：声优丙）",
		"角色甲(cv:声优甲)&角色乙(cv:声优乙)&角色丙(cv:声优丙)",
	}
	want, ok := parseCVCredit(forms[0])
	if !ok {
		t.Fatalf("%q 该认成 CV 署名", forms[0])
	}
	for _, f := range forms[1:] {
		got, ok := parseCVCredit(f)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("%q = %+v, 要跟 %q 一样: %+v", f, got, forms[0], want)
		}
		if !artistMatches(f, forms[0]) || !lyricSourceArtistMatches(f, forms[0]) {
			t.Errorf("%q 跟 %q 该对得上", f, forms[0])
		}
	}
}

// 从 CV 署名里拆出的名字只用来检索和比对:换名重查不往歌手别名、主名、QQ 歌手名缓存里写任何东西,也不碰歌词缓存;
// 往 Last.fm 发的首位歌手、展示用的首位署名、「该不该有统一歌手名」的判断都按原串,不会变成声优名。
func TestCVCreditRetrievalLeavesIdentityAlone(t *testing.T) {
	const artist = "天堂真矢(CV:富田麻帆)、星見純那(CV:佐藤日向)"
	withEnrichCache(t, map[string]enrichEntry{})
	withCachedAliases(t, map[string]string{artist: ""})
	withCachedMBAliases(t, map[string][]string{artist: nil})
	withCachedQQArtistNames(t, map[string]string{artist: ""})
	snapshot := func() (map[string]string, map[string][]string, map[string]string, bool, bool, bool, int) {
		artistAliasMu.Lock()
		a := make(map[string]string, len(artistAliasCache))
		for k, v := range artistAliasCache {
			a[k] = v
		}
		ad := artistAliasDirty
		artistAliasMu.Unlock()
		mbPrimaryNameMu.Lock()
		m := make(map[string][]string, len(mbPrimaryNameCache))
		for k, v := range mbPrimaryNameCache {
			m[k] = v
		}
		md := mbPrimaryNameDirty
		mbPrimaryNameMu.Unlock()
		qqArtistNameMu.Lock()
		q := make(map[string]string, len(qqArtistNameCache))
		for k, v := range qqArtistNameCache {
			q[k] = v
		}
		qd := qqArtistNameDirty
		qqArtistNameMu.Unlock()
		return a, m, q, ad, md, qd, len(enrichCache)
	}
	a0, m0, q0, ad0, md0, qd0, e0 := snapshot()
	got := retryArtistIdentities(context.Background(), artist)
	if want := []string{"富田麻帆"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("retryArtistIdentities(%q) = %q, 要 %q", artist, got, want)
	}
	a1, m1, q1, ad1, md1, qd1, e1 := snapshot()
	if !reflect.DeepEqual(a0, a1) || !reflect.DeepEqual(m0, m1) || !reflect.DeepEqual(q0, q1) || ad0 != ad1 || md0 != md1 || qd0 != qd1 || e0 != e1 {
		t.Error("换名重查不该写任何歌手别名缓存或歌词缓存")
	}
	if got := firstCreditedArtist(artist); got != "天堂真矢(CV:富田麻帆)" {
		t.Errorf("firstCreditedArtist = %q, 要原串的第一段", got)
	}
	if got := artistCreditPrimary(artist); got != "天堂真矢(CV:富田麻帆)" {
		t.Errorf("artistCreditPrimary = %q, 要原串的第一段", got)
	}
	if expectsCanonicalArtist(artist) {
		t.Error("多人 CV 署名不该被当成单一歌手去配统一歌手名")
	}
	if got := firstCreditedArtist("角色甲(CV:声优甲)"); got != "角色甲(CV:声优甲)" {
		t.Errorf("单人 CV 署名的 firstCreditedArtist = %q, 要原串", got)
	}
}
