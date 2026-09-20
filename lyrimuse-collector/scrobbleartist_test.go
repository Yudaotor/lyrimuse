package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 上送写法由三个布尔决定(features.LastfmMatchArtist / Track / FirstArtistOnly,
// 档位在 resolveLastfmMatch 那边就摊平了)。这里用 nil 匹配器跑,只考察**不联网的那一半**:
//
//  1. 三个布尔全 false(「原始」档)→ 歌手曲名一个字都不动。
//  2. 只开截断 → 纯字符串取第一位(firstCreditedArtist),结果可复现、不打网络。
//  3. **曲名永远不会被截断那一路碰**。
//  4. 匹配器为 nil(没配只读 api_key)时开着匹配也不能 panic,退化成原样。
func TestResolveScrobbleTags(t *testing.T) {
	cases := []struct {
		name                     string
		artist, track, firstOnly bool
		in                       string
		want                     string
	}{
		{"原始:合唱串原样发整串", false, false, false, "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
		{"原始:单人名原样", false, false, false, "周杰伦", "周杰伦"},
		{"只发第一位:取第一位", false, false, true, "Khalil Fong & Fiona Sit", "Khalil Fong"},
		{"只发第一位:单人名不受影响", false, false, true, "周杰伦", "周杰伦"},
		// K/DA 那次真实事故:`/` 不能跟逗号顿号平级切,否则 `K/DA` 被劈成 `K`,
		// 而 `K` 在 Last.fm 是一个真实存在的无关歌手(见 firstCreditedArtist 的注释)。
		// 这里确认截断那一路仍然走的是那套带守卫的判断,不是裸切。
		{"只发第一位:K/DA 不能被劈成 K", false, false, true, "K/DA", "K/DA"},
		{"匹配器为 nil:开着匹配也原样发", true, true, false, "Khalil Fong & Fiona Sit", "Khalil Fong & Fiona Sit"},
		// 匹配器为 nil 时匹配不成立 ⇒ 截断照样兜底(它本来就只在没匹配到时应用)。
		{"匹配器为 nil + 只发第一位:仍截断", true, true, true, "Khalil Fong & Fiona Sit", "Khalil Fong"},
		{"空串原样返回", false, false, true, "", ""},
	}
	for _, c := range cases {
		setMatch(t, lastfmMatchCustom, c.artist, c.track, c.firstOnly)
		gotArtist, gotTrack := resolveScrobbleTags(context.Background(), nil, c.in, "某首歌", 200)
		if gotArtist != c.want {
			t.Errorf("%s: 歌手 = %q, want %q", c.name, gotArtist, c.want)
		}
		if gotTrack != "某首歌" {
			t.Errorf("%s: 曲名被动了(%q)—— 截断那一路绝不该碰曲名", c.name, gotTrack)
		}
	}
}

// features.json 的键名是两侧(Go / Swift)通过同一份文件交换的字符串,写错一个字母就是
// "设置里改了、collector 永远读不到",而且**不报错**。这里把 Go 侧的 json tag、三个档位值
// 和**两级遗留迁移链**一起钉住;Swift 侧对应的是 FeatureFlagsFile 的 CodingKeys 和
// LastfmMatchMode 的 rawValue(那边最容易漏)。
//
// ⚠️ 迁移表的承诺是**行为逐字不变**:旧 smart → 智能、旧 all → 原始、
// 旧 first → 自定义且只开截断(⇒ 照旧不打网络)。这几条错一条,就是在老用户不知情的
// 情况下改了往 Last.fm 写的内容,而 scrobble 落进去基本删不掉。
func TestLastfmMatchModeFlagRoundTrip(t *testing.T) {
	const key = "lastfm_match_mode"
	const legacy = "lastfm_scrobble_artist_mode"
	const legacy2 = "lastfm_scrobble_first_artist_only"

	type want struct {
		mode                     string
		artist, track, firstOnly bool
	}
	cases := []struct {
		name string
		body string
		want want
	}{
		{"三个键都缺省 → 原始", `{}`, want{lastfmMatchRaw, false, false, false}},
		{"显式智能 → 歌手曲名都可改", `{"` + key + `":"smart"}`, want{lastfmMatchSmart, true, true, false}},
		{"显式原始", `{"` + key + `":"raw"}`, want{lastfmMatchRaw, false, false, false}},
		{"自定义:三个子项缺省一律 false(fail-closed)", `{"` + key + `":"custom"}`, want{lastfmMatchCustom, false, false, false}},
		{"自定义:只改曲名", `{"` + key + `":"custom","lastfm_match_track":true}`, want{lastfmMatchCustom, false, true, false}},
		{"自定义:只改歌手 + 截断", `{"` + key + `":"custom","lastfm_match_artist":true,"lastfm_match_first_artist_only":true}`, want{lastfmMatchCustom, true, false, true}},
		{"非法档位 → 退回默认原始", `{"` + key + `":"clever"}`, want{lastfmMatchRaw, false, false, false}},
		// 一级遗留:lastfm_scrobble_artist_mode。
		{"遗留 smart → 智能", `{"` + legacy + `":"smart"}`, want{lastfmMatchSmart, true, true, false}},
		{"遗留 all → 原始", `{"` + legacy + `":"all"}`, want{lastfmMatchRaw, false, false, false}},
		{"遗留 first → 自定义且只开截断(行为逐字不变)", `{"` + legacy + `":"first"}`, want{lastfmMatchCustom, false, false, true}},
		{"新键优先于一级遗留", `{"` + key + `":"raw","` + legacy + `":"smart"}`, want{lastfmMatchRaw, false, false, false}},
		{"非法新键 + 一级遗留 → 走遗留", `{"` + key + `":"clever","` + legacy + `":"first"}`, want{lastfmMatchCustom, false, false, true}},
		// 二级遗留:更早的二态开关。
		{"只有二级遗留 true → 自定义且只开截断", `{"` + legacy2 + `":true}`, want{lastfmMatchCustom, false, false, true}},
		{"只有二级遗留 false → 原始", `{"` + legacy2 + `":false}`, want{lastfmMatchRaw, false, false, false}},
		{"一级遗留优先于二级", `{"` + legacy + `":"all","` + legacy2 + `":true}`, want{lastfmMatchRaw, false, false, false}},
	}
	for _, c := range cases {
		f := loadFeatureFlagsFromJSON(t, c.body)
		got := want{f.LastfmMatchMode, f.LastfmMatchArtist, f.LastfmMatchTrack, f.LastfmMatchFirstArtistOnly}
		if got != c.want {
			t.Errorf("%s: %s → %+v, want %+v", c.name, c.body, got, c.want)
		}
	}
}

// mirrorAsync 的总窗口:**会联网匹配**时要多给判定那份预算(最多四个请求),不能把真正的
// 写入挤掉;不匹配就维持 8 秒。判据是两个布尔,不是档位 —— 「自定义只开截断」同样不联网。
func TestMirrorTimeoutBudget(t *testing.T) {
	setMatch(t, lastfmMatchRaw, false, false, false)
	if got := mirrorTimeout(); got != 8*time.Second {
		t.Errorf("原始档 mirrorTimeout = %v, want 8s", got)
	}
	setMatch(t, lastfmMatchCustom, false, false, true)
	if got := mirrorTimeout(); got != 8*time.Second {
		t.Errorf("只开截断时 mirrorTimeout = %v, want 8s(不联网)", got)
	}
	setMatch(t, lastfmMatchCustom, false, true, false)
	if got := mirrorTimeout(); got != 8*time.Second+lastfmCatalogBudget {
		t.Errorf("只改曲名时 mirrorTimeout = %v, want %v", got, 8*time.Second+lastfmCatalogBudget)
	}
	setMatch(t, lastfmMatchSmart, true, true, false)
	if got := mirrorTimeout(); got != 8*time.Second+lastfmCatalogBudget {
		t.Errorf("智能档 mirrorTimeout = %v, want %v", got, 8*time.Second+lastfmCatalogBudget)
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

// Apple Music 那条路径(getAppleMusicState,JXA 直接 unmarshal)原来绕过了
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

// 短曲目闸:Last.fm 官方规则 "longer than 30 seconds" 默认照做,用户显式打开
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
