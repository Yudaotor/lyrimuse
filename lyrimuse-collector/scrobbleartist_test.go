package main

import (
	"os"
	"path/filepath"
	"testing"
)

// 2026-08-31:合唱串处理从「联网条件式」(查 Last.fm 目录,查不到才折)改成静态开关。
//
// 这一组钉的是两件事:
//  1. **默认原样发整串** —— 依据是 ListenBrainz 文档要求合唱 credit "include them all",
//     以及 Navidrome 同名开关 Lastfm.ScrobbleFirstArtistOnly 默认也是 false。
//  2. 开关打开时走 firstCreditedArtist(纯字符串判断,**不联网**),结果可复现 ——
//     原实现同样的输入会因 Last.fm 目录状态/网络通断给出不同的艺人名,而 scrobble
//     落进 Last.fm 基本删不掉。
func TestResolveScrobbleArtist(t *testing.T) {
	saved := features.LastfmScrobbleFirstArtistOnly
	defer func() { features.LastfmScrobbleFirstArtistOnly = saved }()

	cases := []struct {
		name      string
		firstOnly bool
		in        string
		want      string
	}{
		{"默认:合唱串原样发整串", false, "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
		{"默认:单人名原样", false, "周杰伦", "周杰伦"},
		{"开关打开:取第一位", true, "Khalil Fong & Fiona Sit", "Khalil Fong"},
		{"开关打开:单人名不受影响", true, "周杰伦", "周杰伦"},
		// K/DA 那次真实事故:`/` 不能跟逗号顿号平级切,否则 `K/DA` 被劈成 `K`,
		// 而 `K` 在 Last.fm 是一个真实存在的无关歌手(见 firstCreditedArtist 的注释)。
		// 这里确认开关打开时仍然走的是那套带守卫的判断,不是裸切。
		{"开关打开:K/DA 不能被劈成 K", true, "K/DA", "K/DA"},
		{"空串两种模式都原样返回", true, "", ""},
	}
	for _, c := range cases {
		features.LastfmScrobbleFirstArtistOnly = c.firstOnly
		if got := resolveScrobbleArtist(c.in); got != c.want {
			t.Errorf("%s: resolveScrobbleArtist(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

// features.json 的键名是两侧(Go / Swift)通过同一份文件交换的字符串,写错一个字母就是
// "设置里改了、collector 永远读不到",而且**不报错**。这里把 Go 侧的 json tag 钉住;
// Swift 侧对应的是 FeatureFlagsFile 的 CodingKeys(那边最容易漏)。
func TestScrobbleFirstArtistOnlyFlagRoundTrip(t *testing.T) {
	const key = "lastfm_scrobble_first_artist_only"

	// 缺省(老配置没有这个键)必须解成 false —— 默认发整串,不能因为字段缺失就开始折叠。
	if got := loadFeatureFlagsFromJSON(t, `{}`); got.LastfmScrobbleFirstArtistOnly {
		t.Error("字段缺失时应为 false(原样发整串)")
	}
	if got := loadFeatureFlagsFromJSON(t, `{"`+key+`":true}`); !got.LastfmScrobbleFirstArtistOnly {
		t.Errorf("显式 true 没被读到 —— 键名可能写错了(应为 %q)", key)
	}
	if got := loadFeatureFlagsFromJSON(t, `{"`+key+`":false}`); got.LastfmScrobbleFirstArtistOnly {
		t.Error("显式 false 应保持 false")
	}
}

// 走**真实的** loadFeatureFlags(而不是自己另拼一套 json.Unmarshal):这个测试要钉的
// 恰恰是"键名/解析链路对不对",绕开真实入口就等于没测。
func loadFeatureFlagsFromJSON(t *testing.T, body string) featureFlags {
	t.Helper()
	path := filepath.Join(t.TempDir(), "features.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("写临时 features.json 失败: %v", err)
	}
	return loadFeatureFlags(path)
}

// 2026-08-31:Apple Music 那条路径(getAppleMusicState,JXA 直接 unmarshal)原来绕过了
// cleanMediaTag —— 标签里的 NBSP/零宽字符会原样进 Last.fm,在那边建出一个跟正常写法
// 肉眼完全一样、实际却是另一个实体的条目;而 enrichKey 那边又洗过,两边口径不一致。
//
// 这里直接测 cleanMediaTag 本身(getAppleMusicState 要跑 osascript,测不了),钉住
// "洗什么、不洗什么"——**洗 ≠ 改写**:只规范化不可见字符,绝不动可见内容。
func TestCleanMediaTagScope(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"NBSP 归一成普通空格", "Khalil\u00a0Fong", "Khalil Fong"},
		{"全角空格归一", "周杰伦\u3000七里香", "周杰伦 七里香"},
		{"零宽字符直接删掉", "Pri\u200bnce", "Prince"},
		{"BOM 删掉", "\ufeffPrince", "Prince"},
		{"连续空白折成一个", "A   B", "A B"},
		{"首尾空白去掉", "  Prince  ", "Prince"},
		// 以下都属于"可见内容",一个字都不能动 —— 这是跟 lbMeta 原样上送同一条原则。
		{"大小写不动", "PRINCE", "PRINCE"},
		{"合唱串不动", "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
		{"括号副题不动", "一口 (The Day You Left Me)", "一口 (The Day You Left Me)"},
		{"繁体不转简", "無所謂", "無所謂"},
		{"空串", "", ""},
	}
	for _, c := range cases {
		if got := cleanMediaTag(c.in); got != c.want {
			t.Errorf("%s: cleanMediaTag(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}
