package main

import (
	"encoding/base64"
	"encoding/json"
	"testing"
)

func deezerTrackFromJSON(t *testing.T, raw string) deezerTrack {
	t.Helper()
	var tr deezerTrack
	if err := json.Unmarshal([]byte(raw), &tr); err != nil {
		t.Fatalf("解析测试用的搜索结果失败: %v", err)
	}
	return tr
}

// synchronizedLines → 逐行 LRC。形状是 2026-09-13 从 pipe.deezer.com 真实响应里 dump 出来的
// (Joseph Kamel《Crash》64 行):只认 lrcTimestamp + line 同时非空的行。Deezer 用空 line
// 表示间奏,原样拼进去会变成一堆空行——那会拉低 lines 这一项的分,还会在歌词面上留白。
func TestDeezerBuildLRC(t *testing.T) {
	raw := `[
		{"lrcTimestamp":"[00:00.00]","line":"200 sur le compteur"},
		{"lrcTimestamp":"[00:01.41]","line":""},
		{"lrcTimestamp":"","line":"没有时间戳的行"},
		{"lrcTimestamp":"[00:02.99]","line":"  Est-ce que ça nous fait peur  "}
	]`
	var lines []deezerSyncLine
	if err := json.Unmarshal([]byte(raw), &lines); err != nil {
		t.Fatalf("解析 synchronizedLines 失败: %v", err)
	}
	want := "[00:00.00]200 sur le compteur\n[00:02.99]Est-ce que ça nous fait peur\n"
	if got := deezerBuildLRC(lines); got != want {
		t.Fatalf("拼出来的 LRC 不对:\n got=%q\nwant=%q", got, want)
	}
	// 一行都拼不出来时给空串,调用方据此走纯文本回退,不会把空串当成"有歌词"。
	if got := deezerBuildLRC([]deezerSyncLine{{LRCTimestamp: "[00:01.00]", Line: "   "}}); got != "" {
		t.Fatalf("全是空正文时应当返回空串,得到 %q", got)
	}
}

// 身份闸 + 时长闸。身份判定用的是跟别的源完全一致的三个函数,这里只钉"接上了";时长那档
// 是 Deezer 比 migu 多出来的一道(搜索结果自带 duration),口径与 kuwo 一致(容差 0.25)。
func TestDeezerCandidateScore(t *testing.T) {
	original := deezerTrackFromJSON(t, `{"id":3877025581,"title":"Crash","duration":165,
		"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 164); got < 0 {
		t.Fatalf("原版应当通过,得到 %d", got)
	}
	// 时长几乎相等 → 拿到接近满额的时长加分(100 + ~50)。
	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 164); got < 140 {
		t.Fatalf("时长几乎相等时应当拿到高额时长加分,得到 %d", got)
	}
	// 本地不知道时长 → 该项不参与,只剩身份闸的基础分。
	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 0); got != 100 {
		t.Fatalf("本地时长未知时应当只有基础分 100,得到 %d", got)
	}

	// 时长差超过容差 → 淘汰(把 165s 的原版配到 88s 的节选版那类错配)。
	if got := deezerCandidateScore(original, "Joseph Kamel", "Crash", "Crash - Single", 88); got >= 0 {
		t.Fatalf("时长差超出容差应当淘汰,得到 %d", got)
	}
	// 歌手对不上 → 淘汰。
	other := deezerTrackFromJSON(t, `{"id":1,"title":"Crash","duration":165,
		"artist":{"name":"Charli xcx"},"album":{"title":"CRASH"}}`)
	if got := deezerCandidateScore(other, "Joseph Kamel", "Crash", "Crash - Single", 164); got >= 0 {
		t.Fatalf("歌手对不上应当淘汰,得到 %d", got)
	}
	// 版本限定词对不上 → 淘汰(现场版不能顶原版)。
	live := deezerTrackFromJSON(t, `{"id":2,"title":"Crash (Live)","duration":165,
		"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(live, "Joseph Kamel", "Crash", "Crash - Single", 164); got >= 0 {
		t.Fatalf("版本限定词对不上应当淘汰,得到 %d", got)
	}
	// ⚠️ 反过来钉住一个**既有缺口**(不是这个源引入的,也不在这次改动的范围里):
	// distinctRecordingVersionTags 只收英文 + 中文版本词,法语的「(Version acoustique)」
	// 认不出来 —— 而 Deezer 的法语曲库恰恰常年把 acoustic 版这么标。它今天能过闸,
	// 靠的不是 acoustic 家族那条豁免(sameRecordingExtraTagWhitelist),而是根本没被
	// 识别成版本词。真要修得动 match.go 的通用词表(影响全部源的打分口径),先量再改。
	acoustique := deezerTrackFromJSON(t, `{"id":4074630991,"title":"Crash (Version acoustique)","duration":165,
		"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(acoustique, "Joseph Kamel", "Crash", "Crash - Single", 164); got < 0 {
		t.Fatalf("现状是认不出法语版本词、照常通过;这条一旦变红说明词表补了法语,把这段注释一起更新: %d", got)
	}
	// 没有 id 的条目 → 淘汰(后面取词没法发请求)。
	noID := deezerTrackFromJSON(t, `{"title":"Crash","duration":165,"artist":{"name":"Joseph Kamel"},"album":{"title":"Crash"}}`)
	if got := deezerCandidateScore(noID, "Joseph Kamel", "Crash", "Crash - Single", 164); got >= 0 {
		t.Fatalf("没有 id 应当淘汰,得到 %d", got)
	}
}

// 「这首歌没有歌词」的识别 —— 这是**正常结果**不是失败,认出来才不会往失败原因里记、
// 不会惊动熔断。2026-09-13 实测原文(Jungeli《Juste un peu》、Suzane《SLT》)。
func TestDeezerIsLyricsNotFound(t *testing.T) {
	real := `[{"message":"Lyrics does not exists","type":"LyricsNotFoundError","path":["track","lyrics"]}]`
	if !deezerIsLyricsNotFound(real) {
		t.Fatal("实测原文应当被认成「这首没有歌词」")
	}
	if !deezerIsLyricsNotFound(`[{"type":"LyricsNotFoundError"}]`) {
		t.Fatal("只有 type 也要认出来")
	}
	if deezerIsLyricsNotFound(`[{"message":"Unauthorized","type":"AuthenticationError"}]`) {
		t.Fatal("认证失败不是「没有歌词」—— 那一支要清掉 JWT 重试,别混")
	}
	if deezerIsLyricsNotFound("") {
		t.Fatal("没有错误时不该认成「没有歌词」")
	}
}

// GraphQL / 公开 API 成功时 errors 字段是空数组,失败时才有内容。
func TestDeezerHasError(t *testing.T) {
	for _, empty := range []string{"", "null", "[]", "{}", "  []  "} {
		if deezerHasError([]byte(empty)) {
			t.Fatalf("%q 应当算「没有错误」", empty)
		}
	}
	if !deezerHasError([]byte(`[{"type":"LyricsNotFoundError"}]`)) {
		t.Fatal("有内容时应当算有错误")
	}
}

// 匿名 JWT 自带 exp,用它决定什么时候换票;解不出来时调用方退保守 TTL。**不校验签名**
// ——我们不是这张票的验证方,读错了最坏只是多换一次。
func TestDeezerJWTExpiry(t *testing.T) {
	// {"exp":1789300000,"unlogged":true} 的 base64url(去掉了 padding,跟真实 JWT 一样)
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"exp":1789300000,"unlogged":true}`))
	jwt := "header." + payload + ".sig"
	if got := deezerJWTExpiry(jwt); got.Unix() != 1789300000 {
		t.Fatalf("exp 没读对: %v", got)
	}
	for _, bad := range []string{"", "只有一段", "header.!!!不是base64!!!.sig", "header." + base64.RawURLEncoding.EncodeToString([]byte(`{"unlogged":true}`)) + ".sig"} {
		if got := deezerJWTExpiry(bad); !got.IsZero() {
			t.Fatalf("%q 应当解不出 exp,得到 %v", bad, got)
		}
	}
}

// 封面取最大档,没有 cover_xl 时退到 cover_big;两个都没有就留空(交给 Apple 封面兜底)。
func TestDeezerTrackCover(t *testing.T) {
	xl := deezerTrackFromJSON(t, `{"album":{"cover_xl":"https://x/1000x1000.jpg","cover_big":"https://x/500x500.jpg"}}`)
	if got := xl.cover(); got != "https://x/1000x1000.jpg" {
		t.Fatalf("应当优先取 cover_xl,得到 %q", got)
	}
	big := deezerTrackFromJSON(t, `{"album":{"cover_big":"https://x/500x500.jpg"}}`)
	if got := big.cover(); got != "https://x/500x500.jpg" {
		t.Fatalf("没有 cover_xl 时应当退到 cover_big,得到 %q", got)
	}
	none := deezerTrackFromJSON(t, `{"album":{}}`)
	if got := none.cover(); got != "" {
		t.Fatalf("都没有时应当留空,得到 %q", got)
	}
}
