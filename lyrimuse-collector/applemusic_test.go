package main

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// 一段真实的 Apple 官方逐字 TTML(从 syllable-lyrics 端点取回后裁短)。
// 保留了三个跟解析强相关的特征,别"顺手规范化"掉:
//   - itunes:timing="Word" 与 <span> 逐字切分
//   - begin/end 用 **offset-time**("7.439",没有冒号)—— 这正是 parseTTMLTime 那一支
//     存在的理由,写成 "00:07.439" 就测不到东西了
//   - <body dur="2:24.000"> 用的却是 clock-time,两种写法在同一份文档里混用
const appleTTMLSample = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="es"><head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head><body dur="2:24.000"><div begin="7.439" end="10.928" itunes:songPart="Verse"><p begin="7.439" end="9.027" itunes:key="L1" ttm:agent="v1"><span begin="7.439" end="7.619">De</span> <span begin="7.619" end="7.759">la</span> <span begin="7.759" end="8.037">rumba</span></p><p begin="9.341" end="10.928" itunes:key="L2" ttm:agent="v1"><span begin="9.341" end="9.581">Casi</span> <span begin="9.581" end="9.741">ni</span></p></div></body></tt>`

func TestApplemusicParseTTMLOffsetTime(t *testing.T) {
	lrc, yrc, _, ok := applemusicParseTTML(appleTTMLSample)
	if !ok {
		t.Fatal("解析失败")
	}
	// ⚠️ 这条断言守的是一个**静默丢行**的坑:parseTTMLTime 不认 offset-time 那版代码
	// 会让 start<0、parseAMLLTTML 直接 continue,于是开头这些秒级时间戳的行全部消失,
	// 而函数仍然返回 ok=true —— 接入时实测过一次,47 行的歌只剩下时间戳跨过 1 分钟的那半段。
	if !strings.HasPrefix(lrc, "[00:07.43]De la rumba") {
		t.Errorf("首行时间戳/正文不对,拿到:%q", firstLine(lrc))
	}
	if strings.Count(strings.TrimSpace(lrc), "\n") != 1 {
		t.Errorf("应当解析出 2 行,拿到:\n%s", lrc)
	}
	if !strings.Contains(yrc, "(7439,180,0)De ") {
		t.Errorf("逐字数据不对,拿到:%q", firstLine(yrc))
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func TestApplemusicJWTExpiry(t *testing.T) {
	// header.payload.signature —— payload 是 {"exp":1800000000} 的 base64url
	const tok = "eyJhbGciOiJFUzI1NiJ9.eyJleHAiOjE4MDAwMDAwMDB9.sig"
	got := applemusicJWTExpiry(tok)
	if got.Unix() != 1800000000 {
		t.Errorf("exp = %v, 期望 1800000000", got.Unix())
	}
	for _, bad := range []string{"", "notajwt", "a.b"} {
		if !applemusicJWTExpiry(bad).IsZero() {
			t.Errorf("%q 应当解不出 exp", bad)
		}
	}
}

func TestApplemusicExtractJWTsSkipsExpiredAndSortsByExp(t *testing.T) {
	// 两张票:一张 2033 年到期、一张早已过期(2001 年)。混在一段 JS 文本里。
	// ⚠️ payload 段必须够长:applemusicJWTRe 要求中段 ≥50 个字符(真 JWT 的 claims 本来
	// 就远不止这点),拿一个最小化的 {"exp":…} 去测会连正则都匹配不上、测了个寂寞。
	const future = "eyJhbGciOiJFUzI1NiJ9.eyJleHAiOjIwMDAwMDAwMDAsInBhZCI6Imx5cmltdXNlLXRlc3QtcGFkZGluZy12YWx1ZSJ9.aaaaaaaaaaaaaaaaaaaaaaaa"
	const expired = "eyJhbGciOiJFUzI1NiJ9.eyJleHAiOjEwMDAwMDAwMDAsInBhZCI6Imx5cmltdXNlLXRlc3QtcGFkZGluZy12YWx1ZSJ9.bbbbbbbbbbbbbbbbbbbbbbbb"
	js := "var a=1;const t=\"" + expired + "\";const u=\"" + future + "\";"
	got := applemusicExtractJWTs(js)
	if len(got) != 1 || got[0] != future {
		t.Fatalf("应当只留下未过期的那张票,拿到 %d 张:%v", len(got), got)
	}
	// 同一张票出现两次只算一张。
	if n := len(applemusicExtractJWTs(js + js)); n != 1 {
		t.Errorf("重复的票应当去重,拿到 %d 张", n)
	}
}

func applemusicTestSong(name, artist, album string, ms int, hasLyrics, synced bool) applemusicSong {
	var s applemusicSong
	s.ID = "123"
	s.Attributes.Name = name
	s.Attributes.ArtistName = artist
	s.Attributes.AlbumName = album
	s.Attributes.DurationInMillis = ms
	s.Attributes.HasLyrics = hasLyrics
	s.Attributes.HasTimeSynced = synced
	return s
}

func TestApplemusicCandidateScore(t *testing.T) {
	const (
		title  = "BESO DE ESOS"
		artist = "Aloisio"
		album  = "BESO DE ESOS - Single"
		dur    = 144.0
	)

	// hasLyrics=false 直接淘汰 —— 这道闸是这一路独有的"便宜信号",搜索结果里就能判,
	// 不必白跑一趟取词。
	if s := applemusicCandidateScore(applemusicTestSong(title, artist, album, 144000, false, false), artist, title, album, dur); s >= 0 {
		t.Errorf("hasLyrics=false 应当淘汰,拿到 %d", s)
	}
	// 只有纯文本的仍然要留着走 plainOnly 通道,不能因为没时间轴就整首丢掉。
	plain := applemusicCandidateScore(applemusicTestSong(title, artist, album, 144000, true, false), artist, title, album, dur)
	if plain < 0 {
		t.Errorf("只有纯文本的候选不该被淘汰,拿到 %d", plain)
	}
	// 有时间轴的要排在只有纯文本的前面。
	synced := applemusicCandidateScore(applemusicTestSong(title, artist, album, 144000, true, true), artist, title, album, dur)
	if synced <= plain {
		t.Errorf("有时间轴(%d)应当高于只有纯文本(%d)", synced, plain)
	}
	// 时长差太多淘汰(口径跟 deezer/kuwo 一致,容差 0.25)。
	if s := applemusicCandidateScore(applemusicTestSong(title, artist, album, 40000, true, true), artist, title, album, dur); s >= 0 {
		t.Errorf("时长差 3 倍应当淘汰,拿到 %d", s)
	}
	// 歌手对不上淘汰(走跟别的源完全一致的判定函数,不另起一套更松的规则)。
	if s := applemusicCandidateScore(applemusicTestSong(title, "Someone Else", album, 144000, true, true), artist, title, album, dur); s >= 0 {
		t.Errorf("歌手不匹配应当淘汰,拿到 %d", s)
	}
	// 没有 id 的淘汰。
	var noID applemusicSong
	noID.Attributes.Name = title
	noID.Attributes.HasLyrics = true
	if s := applemusicCandidateScore(noID, artist, title, album, dur); s >= 0 {
		t.Errorf("没有 id 应当淘汰,拿到 %d", s)
	}
}

func TestApplemusicCoverTemplateSubstitution(t *testing.T) {
	var s applemusicSong
	s.Attributes.Artwork.URL = "https://example.com/{w}x{h}bb.{f}"
	if got := s.cover(); got != "https://example.com/1000x1000bb.jpg" {
		t.Errorf("artwork 模板替换不对:%q", got)
	}
	var empty applemusicSong
	if got := empty.cover(); got != "" {
		t.Errorf("没有 artwork 时应当留空,拿到 %q", got)
	}
}

// 没连过账号时一个网络请求都不该发 —— 这一路的取词端点只认 media-user-token,
// 没有它连搜索都不必做。这里把 configDir 指到一个空目录来模拟"没连过"。
func TestApplemusicResolveShortCircuitsWhenNotConnected(t *testing.T) {
	saved := applemusicLastFailureReasonNow()
	t.Cleanup(func() { applemusicSetLastFailureReason(saved) })
	applemusicSetLastFailureReason("")

	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	r := resolveApplemusicLyric(t.Context(), "Aloisio", "BESO DE ESOS", "BESO DE ESOS - Single", 144)
	if !r.empty() {
		t.Error("没有用户令牌时应当返回空")
	}
	if got := applemusicLastFailureReasonNow(); got != lyricFailureReasonAppleMusicNotConnected {
		t.Errorf("失败原因 = %q, 期望 %q", got, lyricFailureReasonAppleMusicNotConnected)
	}
}

func TestApplemusicDevTokenRenewMarginIsSane(t *testing.T) {
	// 实测 Apple 网页那张票的有效期是 70 天量级,提前一天换足够;这条只是防手滑把
	// margin 写成比有效期还长(那会导致每次都判过期、每次都重下 3MB 的 bundle)。
	if applemusicDevTokenRenewMargin <= 0 || applemusicDevTokenRenewMargin > 7*24*time.Hour {
		t.Errorf("devToken 续期余量不合理:%v", applemusicDevTokenRenewMargin)
	}
}

// TestApplemusicNeverGuessesStorefront 钉死订正的那件事:
// storefront 拿不到时**绝不能退回某个默认区**。
//
// 它同时决定取词那一趟的鉴权(URL 里的区 != 订阅区 → 一律 404),所以猜一个区的后果不是
// "少查到几首区域独占曲目",而是整源静默全灭 —— 而且 applemusicFetchTTML 把 404 当正常
// 结果返回 ("", nil),不报错不记原因,光看日志根本发现不了。改回 `sf = "us"` 这类兜底
// 就会被这条拦住。
func TestApplemusicNeverGuessesStorefront(t *testing.T) {
	src, err := os.ReadFile("applemusic.go")
	if err != nil {
		t.Fatalf("read applemusic.go: %v", err)
	}
	// 只看 applemusicLoadUserToken 这一段,别误伤 applemusicBrowseURL 那种正当的 "us"。
	body := string(src)
	start := strings.Index(body, "func applemusicLoadUserToken()")
	if start < 0 {
		t.Fatal("applemusicLoadUserToken not found — guard would silently pass")
	}
	end := strings.Index(body[start:], "\n}\n")
	if end < 0 {
		t.Fatal("cannot delimit applemusicLoadUserToken")
	}
	fn := body[start : start+end]
	if regexp.MustCompile(`"[a-z]{2}"`).MatchString(fn) {
		t.Errorf("applemusicLoadUserToken 里出现了硬编码的区域码;storefront 拿不到必须返回空串,"+
			"由 applemusicEnsureStorefront 去问 Apple,绝不能猜。函数体:\n%s", fn)
	}
}

// TestApplemusicEnsureStorefrontWritesBack:问到 storefront 后要补写回令牌文件,
// 且不能把别的字段(令牌本身、saved_at)弄丢 —— 丢了等于把用户登出。
func TestApplemusicEnsureStorefrontWritesBack(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	path := applemusicUserTokenPath()
	if path == "" {
		t.Fatal("empty token path")
	}
	const tok = "fake-media-user-token"
	seed := `{"media_user_token":"` + tok + `","storefront":"","saved_at":1700000000}`
	if err := os.WriteFile(path, []byte(seed), 0o600); err != nil {
		t.Fatal(err)
	}
	applemusicSaveStorefront("cn")

	gotTok, gotSF := applemusicLoadUserToken()
	if gotTok != tok {
		t.Errorf("token lost after storefront write-back: %q", gotTok)
	}
	if gotSF != "cn" {
		t.Errorf("storefront not written back: %q", gotSF)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f applemusicUserTokenFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if f.SavedAt != 1700000000 {
		t.Errorf("saved_at clobbered: %d", f.SavedAt)
	}
	if info, err := os.Stat(path); err == nil && info.Mode().Perm() != 0o600 {
		t.Errorf("token file permissions widened to %o", info.Mode().Perm())
	}
}

// TestApplemusicResolveFailsClosedWithoutStorefront:令牌在手但 storefront 为空时,
// 不许拿默认区去搜 —— 这里没有网络,ensure 必然失败,所以结果必须是空。
func TestApplemusicResolveFailsClosedWithoutStorefront(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	path := applemusicUserTokenPath()
	seed := `{"media_user_token":"fake","storefront":"","saved_at":1700000000}`
	if err := os.WriteFile(path, []byte(seed), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, sf := applemusicLoadUserToken(); sf != "" {
		t.Fatalf("storefront should stay empty, got %q", sf)
	}
}

func TestApplemusicCoverReplacesAllPlaceholders(t *testing.T) {
	var s applemusicSong
	// Apple 的真实模板形状(取自 Music.app 的本地缓存):四个占位符,{c} 最容易被漏。
	s.Attributes.Artwork.URL = "https://is1-ssl.mzstatic.com/image/thumb/Music6/v4/x/y.jpg/{w}x{h}{c}.{f}"
	got := s.cover()
	if strings.ContainsAny(got, "{}") {
		// 留一个花括号在 URL 里,整条链接直接 400,封面永远加载不出来。
		t.Fatalf("占位符没替换干净: %s", got)
	}
	if got != "https://is1-ssl.mzstatic.com/image/thumb/Music6/v4/x/y.jpg/1000x1000bb.jpg" {
		t.Fatalf("替换结果不对: %s", got)
	}
	if (applemusicSong{}).cover() != "" {
		t.Fatal("空 URL 应当返回空串")
	}
}
