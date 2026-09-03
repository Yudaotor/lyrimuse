package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 合唱串上送的三档(2026-09-03 起:all / first / smart)。
//
// 这一组钉的是:
//  1. **默认原样发整串** —— 依据是 ListenBrainz 文档要求合唱 credit "include them all",
//     以及 Navidrome 同名开关 Lastfm.ScrobbleFirstArtistOnly 默认也是 false。
//  2. first 档走 firstCreditedArtist(纯字符串判断,**不联网**),结果可复现。
//  3. smart 档在判定器为 nil(没配只读 api_key)时退化成原样发 —— 不能 panic、不能偷偷变成
//     first 档。联网判定本身的行为在 lastfmcollapse_test.go。
func TestResolveScrobbleArtist(t *testing.T) {
	saved := features.LastfmScrobbleArtistMode
	defer func() { features.LastfmScrobbleArtistMode = saved }()

	cases := []struct {
		name string
		mode string
		in   string
		want string
	}{
		{"默认:合唱串原样发整串", scrobbleArtistAll, "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
		{"默认:单人名原样", scrobbleArtistAll, "周杰伦", "周杰伦"},
		{"first:取第一位", scrobbleArtistFirst, "Khalil Fong & Fiona Sit", "Khalil Fong"},
		{"first:单人名不受影响", scrobbleArtistFirst, "周杰伦", "周杰伦"},
		// K/DA 那次真实事故:`/` 不能跟逗号顿号平级切,否则 `K/DA` 被劈成 `K`,
		// 而 `K` 在 Last.fm 是一个真实存在的无关歌手(见 firstCreditedArtist 的注释)。
		// 这里确认 first 档仍然走的是那套带守卫的判断,不是裸切。
		{"first:K/DA 不能被劈成 K", scrobbleArtistFirst, "K/DA", "K/DA"},
		{"smart 且判定器为 nil:原样发", scrobbleArtistSmart, "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
		{"空串三种模式都原样返回", scrobbleArtistFirst, "", ""},
		{"零值/未知档位当 all 处理", "", "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
	}
	for _, c := range cases {
		features.LastfmScrobbleArtistMode = c.mode
		if got := resolveScrobbleArtist(context.Background(), nil, c.in, "某首歌"); got != c.want {
			t.Errorf("%s: resolveScrobbleArtist(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

// features.json 的键名是两侧(Go / Swift)通过同一份文件交换的字符串,写错一个字母就是
// "设置里改了、collector 永远读不到",而且**不报错**。这里把 Go 侧的 json tag 和三个档位值
// 钉住;Swift 侧对应的是 FeatureFlagsFile 的 CodingKeys 和 LastfmScrobbleArtistMode 的
// rawValue(那边最容易漏)。同时钉住遗留二态开关的迁移:2026-08-31 ~ 09-03 之间写下的
// lastfm_scrobble_first_artist_only=true 必须读成 first,不能因为换了键就回到默认档。
func TestScrobbleArtistModeFlagRoundTrip(t *testing.T) {
	const key = "lastfm_scrobble_artist_mode"
	const legacy = "lastfm_scrobble_first_artist_only"

	cases := []struct {
		name string
		body string
		want string
	}{
		{"两个键都缺省 → all(默认发整串)", `{}`, scrobbleArtistAll},
		{"显式 all", `{"` + key + `":"all"}`, scrobbleArtistAll},
		{"显式 first", `{"` + key + `":"first"}`, scrobbleArtistFirst},
		{"显式 smart", `{"` + key + `":"smart"}`, scrobbleArtistSmart},
		{"非法值 → 退回默认 all", `{"` + key + `":"clever"}`, scrobbleArtistAll},
		{"非法值 + 遗留 true → 退回遗留迁移 first", `{"` + key + `":"clever","` + legacy + `":true}`, scrobbleArtistFirst},
		{"只有遗留 true → first(迁移)", `{"` + legacy + `":true}`, scrobbleArtistFirst},
		{"只有遗留 false → all", `{"` + legacy + `":false}`, scrobbleArtistAll},
		{"新键优先于遗留键", `{"` + key + `":"all","` + legacy + `":true}`, scrobbleArtistAll},
		{"新键 smart 时遗留 true 不干扰", `{"` + key + `":"smart","` + legacy + `":true}`, scrobbleArtistSmart},
	}
	for _, c := range cases {
		if got := loadFeatureFlagsFromJSON(t, c.body).LastfmScrobbleArtistMode; got != c.want {
			t.Errorf("%s: %s → %q, want %q", c.name, c.body, got, c.want)
		}
	}
}

// mirrorAsync 的总窗口:智能档要多给判定那份预算,其余档维持 8 秒 —— 判定最多两个请求,
// 不能把真正的写入挤掉。
func TestMirrorTimeoutBudget(t *testing.T) {
	saved := features.LastfmScrobbleArtistMode
	defer func() { features.LastfmScrobbleArtistMode = saved }()
	features.LastfmScrobbleArtistMode = scrobbleArtistAll
	if got := mirrorTimeout(); got != 8*time.Second {
		t.Errorf("all 档 mirrorTimeout = %v, want 8s", got)
	}
	features.LastfmScrobbleArtistMode = scrobbleArtistFirst
	if got := mirrorTimeout(); got != 8*time.Second {
		t.Errorf("first 档 mirrorTimeout = %v, want 8s", got)
	}
	features.LastfmScrobbleArtistMode = scrobbleArtistSmart
	if got := mirrorTimeout(); got != 8*time.Second+lastfmCollapseBudget {
		t.Errorf("smart 档 mirrorTimeout = %v, want %v", got, 8*time.Second+lastfmCollapseBudget)
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

// 短曲目闸(2026-09-03):Last.fm 官方规则 "longer than 30 seconds" 默认照做,用户显式打开
// features.ScrobbleShortTracks 才放行。三条不变量:曲长未知不拦;放行不影响半程规则(那在
// listenThreshold);恰好 30 秒按既有口径放行(跟官方 "> 30" 差这一秒,历史行为,别顺手改)。
func TestTooShortToScrobble(t *testing.T) {
	saved := features.ScrobbleShortTracks
	defer func() { features.ScrobbleShortTracks = saved }()

	cases := []struct {
		name  string
		allow bool
		dur   float64
		want  bool
	}{
		{"默认:20 秒拦", false, 20, true},
		{"默认:29.9 秒拦", false, 29.9, true},
		{"默认:恰好 30 秒放行(既有口径)", false, 30, false},
		{"默认:240 秒放行", false, 240, false},
		{"默认:曲长未知(0)不拦", false, 0, false},
		{"默认:曲长为负(坏数据)不拦", false, -1, false},
		{"开关开:20 秒放行", true, 20, false},
		{"开关开:3 秒也放行(半程规则另管)", true, 3, false},
		{"开关开:曲长未知不拦", true, 0, false},
	}
	for _, c := range cases {
		features.ScrobbleShortTracks = c.allow
		if got := tooShortToScrobble(c.dur); got != c.want {
			t.Errorf("%s: tooShortToScrobble(%v) = %v, want %v", c.name, c.dur, got, c.want)
		}
	}
}

// 键名 scrobble_short_tracks 两侧共用;缺省必须是 false —— 老配置没这个键,不能让用户历史里
// 突然多出一批短曲目。
func TestScrobbleShortTracksFlagRoundTrip(t *testing.T) {
	const key = "scrobble_short_tracks"
	if got := loadFeatureFlagsFromJSON(t, `{}`); got.ScrobbleShortTracks {
		t.Error("字段缺失时应为 false(短曲目不记)")
	}
	if got := loadFeatureFlagsFromJSON(t, `{"`+key+`":true}`); !got.ScrobbleShortTracks {
		t.Errorf("显式 true 没被读到 —— 键名可能写错了(应为 %q)", key)
	}
	if got := loadFeatureFlagsFromJSON(t, `{"`+key+`":false}`); got.ScrobbleShortTracks {
		t.Error("显式 false 应保持 false")
	}
}

// 回填复核也走同一条闸:开关关着时,日志里的短曲目记录不会被补上去;开着才补。
func TestPendingBackfillListensHonorsShortTrackFlag(t *testing.T) {
	savedFlag := features.ScrobbleShortTracks
	savedPath := listenLogPath
	defer func() { features.ScrobbleShortTracks = savedFlag; listenLogPath = savedPath }()
	listenLogPath = filepath.Join(t.TempDir(), "listens.jsonl")

	now := time.Now()
	uts := now.Add(-time.Hour).Unix()
	appendListenLogLine(listenLogLine{T: "l", V: listenLogSchemaVersion, UTS: uts, AR: "A", TI: "短曲", DUR: 20, AT: now.Unix()})
	appendListenLogLine(listenLogLine{T: "l", V: listenLogSchemaVersion, UTS: uts + 60, AR: "A", TI: "长曲", DUR: 200, AT: now.Unix()})

	features.ScrobbleShortTracks = false
	pending, _ := pendingBackfillListens(now)
	if len(pending) != 1 || pending[0].TI != "长曲" {
		t.Fatalf("开关关:应只剩长曲,got %+v", pending)
	}
	features.ScrobbleShortTracks = true
	pending, _ = pendingBackfillListens(now)
	if len(pending) != 2 {
		t.Fatalf("开关开:短曲也该进待补清单,got %+v", pending)
	}
}
