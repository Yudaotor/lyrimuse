package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// withApplemusicCreds 把凭据指到临时目录(用户令牌 + 一份未过期的 developer token),Apple 这一路的进程内状态
// 在用例结束时还原。网络另由 withLRCLIBFake 接管(它把所有主机的请求都交给同一个处理函数)。
func withApplemusicCreds(t *testing.T, storefront string) {
	t.Helper()
	t.Setenv("LYRIMUSE_CONFIG_DIR", t.TempDir())
	user, _ := json.Marshal(applemusicUserTokenFile{MediaUserToken: "test-user-token", Storefront: storefront, SavedAt: time.Now().Unix()})
	if err := os.WriteFile(applemusicUserTokenPath(), user, 0o600); err != nil {
		t.Fatal(err)
	}
	dev, _ := json.Marshal(applemusicDevTokenFile{Token: "test-dev-token", Expiry: time.Now().Add(30 * 24 * time.Hour).Unix()})
	if err := os.WriteFile(applemusicDevTokenPath(), dev, 0o600); err != nil {
		t.Fatal(err)
	}
	applemusicDevTokenMu.Lock()
	savedTok, savedExp := applemusicDevToken, applemusicDevTokenExpires
	applemusicDevToken, applemusicDevTokenExpires = "", time.Time{}
	applemusicDevTokenMu.Unlock()
	applemusicEnglishTagMu.Lock()
	savedTags := applemusicEnglishTags
	applemusicEnglishTags = map[string]string{}
	applemusicEnglishTagMu.Unlock()
	savedFail := applemusicLastFailureReasonNow()
	t.Cleanup(func() {
		applemusicDevTokenMu.Lock()
		applemusicDevToken, applemusicDevTokenExpires = savedTok, savedExp
		applemusicDevTokenMu.Unlock()
		applemusicEnglishTagMu.Lock()
		applemusicEnglishTags = savedTags
		applemusicEnglishTagMu.Unlock()
		applemusicSetLastFailureReason(savedFail)
	})
}

// amTestSearchBody 拼一份 search 应答。
func amTestSearchBody(songs ...applemusicSong) string {
	var out struct {
		Results struct {
			Songs struct {
				Data []applemusicSong `json:"data"`
			} `json:"songs"`
		} `json:"results"`
	}
	out.Results.Songs.Data = songs
	b, _ := json.Marshal(out)
	return string(b)
}

func amTestSong(id, name, artist, album string, ms int, synced bool) applemusicSong {
	var s applemusicSong
	s.ID = id
	s.Attributes.Name, s.Attributes.ArtistName, s.Attributes.AlbumName = name, artist, album
	s.Attributes.DurationInMillis = ms
	s.Attributes.HasLyrics, s.Attributes.HasTimeSynced = true, synced
	return s
}

// amTestLyricsBody 把一份 TTML 包成 /lyrics、/syllable-lyrics 的应答。
func amTestLyricsBody(ttml string) string {
	b, _ := json.Marshal(map[string]any{"data": []map[string]any{{"attributes": map[string]string{"ttmlLocalizations": ttml}}}})
	return string(b)
}

const (
	amTestLineTTML = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Line"><body><div>` +
		`<p begin="1.0" end="2.0">first</p><p begin="3.0" end="4.0">second</p><p begin="5.0" end="6.0">third</p></div></body></tt>`
	amTestUntimedTTML = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="None"><body><div>` +
		`<p>第一句</p><p>&#160;第二句</p><p></p></div></body></tt>`
)

type amTestRecorder struct {
	mu   sync.Mutex
	hits []string
}

func (r *amTestRecorder) add(req *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := req.Host + " " + req.URL.Path
	if l := req.URL.Query().Get("l"); l != "" {
		h += "?l=" + l
	}
	r.hits = append(r.hits, h)
}

// count 数「主机 路径」以 prefix 开头、或(prefix 以 / 开头时)路径里含 prefix 的请求。
func (r *amTestRecorder) count(prefix string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, h := range r.hits {
		if strings.HasPrefix(h, prefix) || (strings.HasPrefix(prefix, "/") && strings.Contains(h, prefix)) {
			n++
		}
	}
	return n
}

// 搜索结果标着没有时间轴,逐字端点照样先问:那里可能有逐行时间轴。
func TestApplemusicAsksSyllableLyricsEvenWhenFlaggedUnsynced(t *testing.T) {
	withApplemusicCreds(t, "cn")
	rec := &amTestRecorder{}
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		rec.add(r)
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			return http.StatusOK, nil, amTestSearchBody(amTestSong("1", "I Am", "James Arthur", "Back from the Edge", 200000, false))
		case strings.HasSuffix(r.URL.Path, "/songs/1/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	r := resolveApplemusicLyric(qqRoundCtx(), "James Arthur", "I Am", "Back from the Edge", 200, "")
	if r.plainOnly || !isTimedLRC(r.lyrics) {
		t.Fatalf("逐字端点给了逐行时间轴,应当收下: plainOnly=%v lyrics=%q", r.plainOnly, r.lyrics)
	}
	if rec.count("/songs/1/lyrics") != 0 {
		t.Error("逐字端点有内容时不该再问 /lyrics")
	}
}

// 只有纯文本的 TTML(itunes:timing="None"):交出 plainOnly 候选,正文按行取出。逐字端点没有时才问 /lyrics。
func TestApplemusicPlainOnlyFromUntimedTTML(t *testing.T) {
	for _, c := range []struct {
		name           string
		syllable404    bool
		wantLyricsHits int
	}{
		{"逐字端点给了不带时间的", false, 0},
		{"逐字端点没有、/lyrics 给了", true, 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			withApplemusicCreds(t, "cn")
			rec := &amTestRecorder{}
			withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
				rec.add(r)
				switch {
				case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
					return http.StatusOK, nil, amTestSearchBody(amTestSong("2", "革命", "范逸臣", "无乐不作", 240000, false))
				case strings.HasSuffix(r.URL.Path, "/songs/2/syllable-lyrics"):
					if c.syllable404 {
						return http.StatusNotFound, nil, ""
					}
					return http.StatusOK, nil, amTestLyricsBody(amTestUntimedTTML)
				case strings.HasSuffix(r.URL.Path, "/songs/2/lyrics"):
					return http.StatusOK, nil, amTestLyricsBody(amTestUntimedTTML)
				}
				return http.StatusNotFound, nil, ""
			})
			r := resolveApplemusicLyric(qqRoundCtx(), "范逸臣", "革命", "无乐不作", 240, "")
			if !r.plainOnly || r.lyrics != "第一句\n第二句" {
				t.Fatalf("应当交出纯文本候选: plainOnly=%v lyrics=%q", r.plainOnly, r.lyrics)
			}
			if got := rec.count("/songs/2/lyrics"); got != c.wantLyricsHits {
				t.Errorf("/lyrics 问了 %d 次,期望 %d", got, c.wantLyricsHits)
			}
		})
	}
}

// 用户所在区的搜索挑不出候选:歌名带假名时到 jp 区搜原文,取词仍走用户所在区。
func TestApplemusicFallsBackToJPStorefrontForKana(t *testing.T) {
	withApplemusicCreds(t, "cn")
	rec := &amTestRecorder{}
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		rec.add(r)
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			return http.StatusOK, nil, amTestSearchBody(amTestSong("3", "Morphine", "椎名林檎", "Muzai Moratorium - Innocence Moratorium", 222000, true))
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/jp/search"):
			return http.StatusOK, nil, amTestSearchBody(amTestSong("3", "モルヒネ", "椎名林檎", "無罪モラトリアム", 222000, true))
		case r.URL.Path == "/v1/catalog/cn/songs/3/syllable-lyrics":
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	r := resolveApplemusicLyric(qqRoundCtx(), "椎名林檎", "モルヒネ", "無罪モラトリアム", 222, "")
	if r.empty() || r.title != "モルヒネ" {
		t.Fatalf("应当从 jp 区搜到、在 cn 区取到: title=%q lyrics=%q", r.title, r.lyrics)
	}
	if rec.count("/v1/catalog/jp/songs/") != 0 {
		t.Error("取词必须走用户所在区")
	}
}

// 本地歌手名是拉丁字母、所在区把它译成了中文:按这个区支持的英文再搜一次。
func TestApplemusicFallsBackToEnglishNames(t *testing.T) {
	withApplemusicCreds(t, "cn")
	rec := &amTestRecorder{}
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		rec.add(r)
		switch {
		case r.URL.Path == "/v1/storefronts/cn":
			return http.StatusOK, nil, `{"data":[{"attributes":{"defaultLanguageTag":"zh-Hans-CN","supportedLanguageTags":["zh-Hans-CN","en-GB"]}}]}`
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			if r.URL.Query().Get("l") == "en-GB" {
				return http.StatusOK, nil, amTestSearchBody(amTestSong("4", "Everytime", "Britney Spears", "In the Zone", 230000, true))
			}
			return http.StatusOK, nil, amTestSearchBody(amTestSong("4", "Everytime", "布兰妮·斯皮尔斯", "In the Zone", 230000, true))
		case r.URL.Path == "/v1/catalog/cn/songs/4/syllable-lyrics":
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	// 本地没有专辑名:三角验证不成立,所在区那条中文署名的候选过不了歌手闸。
	r := resolveApplemusicLyric(qqRoundCtx(), "Britney Spears", "Everytime", "", 230, "")
	if r.empty() || r.artist != "Britney Spears" {
		t.Fatalf("应当按英文再搜到: artist=%q lyrics=%q", r.artist, r.lyrics)
	}
	if rec.count("/v1/catalog/cn/search?l=en-GB") != 1 {
		t.Errorf("英文那次搜索应当恰好一次: %v", rec.hits)
	}
}

// 搜索与取词各自有备用主机,只在 5xx / 传输失败时换;取词的 404 是答了(这首没有这一种歌词)。
func TestApplemusicHostFallback(t *testing.T) {
	withApplemusicCreds(t, "cn")
	rec := &amTestRecorder{}
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		rec.add(r)
		switch {
		case r.Host == "amp-api.music.apple.com" && strings.HasSuffix(r.URL.Path, "/search"):
			return http.StatusServiceUnavailable, nil, ""
		case r.Host == "api.music.apple.com" && strings.HasSuffix(r.URL.Path, "/search"):
			return http.StatusOK, nil, amTestSearchBody(amTestSong("5", "Sorry", "方大同", "未来", 222000, true), amTestSong("6", "Sorry", "方大同", "未来", 222000, true))
		case r.Host == "amp-api.music.apple.com" && strings.HasSuffix(r.URL.Path, "/songs/5/syllable-lyrics"):
			return http.StatusBadGateway, nil, ""
		case r.Host == "amp-api-edge.music.apple.com" && strings.HasSuffix(r.URL.Path, "/songs/5/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	r := resolveApplemusicLyric(qqRoundCtx(), "方大同", "Sorry", "未来", 222, "")
	if r.empty() {
		t.Fatal("搜索与取词都应当从备用主机拿到")
	}
	if rec.count("api.music.apple.com /v1/catalog/cn/songs/") != 0 {
		t.Error("api.music.apple.com 取不了词,不该拿它取词")
	}
	if rec.count("amp-api-edge.music.apple.com /v1/catalog/cn/search") != 0 {
		t.Error("amp-api-edge 的搜索回空结果,不该拿它搜索")
	}
}

func TestApplemusicEnglishTagFrom(t *testing.T) {
	for _, c := range []struct {
		def       string
		supported []string
		want      string
	}{
		{"zh-Hans-CN", []string{"zh-Hans-CN", "en-GB"}, "en-GB"},
		{"ja", []string{"ja", "en-US"}, "en-US"},
		{"en-US", []string{"en-US", "es-MX"}, ""},
		{"ko", []string{"ko"}, ""},
	} {
		if got := applemusicEnglishTagFrom(c.def, c.supported); got != c.want {
			t.Errorf("applemusicEnglishTagFrom(%q, %v) = %q, want %q", c.def, c.supported, got, c.want)
		}
	}
}

func TestApplemusicFallbackSearches(t *testing.T) {
	applemusicEnglishTagMu.Lock()
	saved := applemusicEnglishTags
	applemusicEnglishTags = map[string]string{"cn": "en-GB", "jp": "en-US"}
	applemusicEnglishTagMu.Unlock()
	t.Cleanup(func() {
		applemusicEnglishTagMu.Lock()
		applemusicEnglishTags = saved
		applemusicEnglishTagMu.Unlock()
	})
	ctx := qqRoundCtx()
	for _, c := range []struct {
		sf, artist, title string
		want              []applemusicSearchVariant
	}{
		{"cn", "Britney Spears", "Everytime", []applemusicSearchVariant{{"cn", "en-GB"}}},
		{"cn", "方大同", "Sorry", nil},
		{"cn", "椎名林檎", "モルヒネ", []applemusicSearchVariant{{"jp", ""}}},
		{"cn", "back number", "ハッピーエンド", []applemusicSearchVariant{{"cn", "en-GB"}, {"jp", ""}}},
		{"cn", "IU", "밤편지", []applemusicSearchVariant{{"cn", "en-GB"}, {"kr", ""}}},
		{"jp", "椎名林檎", "モルヒネ", nil},
	} {
		got := applemusicFallbackSearches(ctx, c.sf, c.artist, c.title, "test-dev-token")
		if len(got) != len(c.want) {
			t.Errorf("%s %s - %s: got %v, want %v", c.sf, c.artist, c.title, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s %s - %s: got %v, want %v", c.sf, c.artist, c.title, got, c.want)
				break
			}
		}
	}
}

func TestApplemusicPlainLyrics(t *testing.T) {
	if got := applemusicPlainLyrics(amTestUntimedTTML); got != "第一句\n第二句" {
		t.Errorf("纯文本 = %q", got)
	}
	if got := applemusicPlainLyrics("not xml"); got != "" {
		t.Errorf("解不开的应当给空串, got %q", got)
	}
}

// 歌手写法对不上时的三角验证:收下的分数压在 100 以下,排在歌手对得上的(哪怕只有纯文本)后面。
func TestApplemusicCandidateScoreRecordingTriangle(t *testing.T) {
	tri := amTestSong("7", "曙光", "Tank Lu", "Fighting! 生存之道", 209000, true)
	got := applemusicCandidateScore(tri, "Tank", "曙光", "Fighting!生存之道", 209)
	if got < 0 || got >= 100 {
		t.Fatalf("三角验证收下的候选应在 0~99 分, got %d", got)
	}
	plain := amTestSong("8", "曙光", "Tank", "Fighting!生存之道", 209000, false)
	if s := applemusicCandidateScore(plain, "Tank", "曙光", "Fighting!生存之道", 209); s <= got {
		t.Errorf("歌手对得上的(%d)应排在三角验证收下的(%d)前面", s, got)
	}
	single := amTestSong("9", "Good Bye", "孝琳", "Good Bye - Single", 219000, true)
	if s := applemusicCandidateScore(single, "卫兰", "Good Bye", "Good Bye - Single", 219); s != -1 {
		t.Errorf("单曲、歌手毫无交集应淘汰, got %d", s)
	}
}

// 已经拿到一份纯文本时,后面标着没有时间轴的候选不再试,省掉白打的请求。
func TestApplemusicStopsAfterPlainWhenRestUnsynced(t *testing.T) {
	withApplemusicCreds(t, "cn")
	rec := &amTestRecorder{}
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		rec.add(r)
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			return http.StatusOK, nil, amTestSearchBody(
				amTestSong("10", "革命", "范逸臣", "无乐不作", 240000, false),
				amTestSong("11", "革命", "范逸臣", "精选", 240000, false))
		case strings.HasSuffix(r.URL.Path, "/songs/10/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestUntimedTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	r := resolveApplemusicLyric(qqRoundCtx(), "范逸臣", "革命", "无乐不作", 240, "")
	if !r.plainOnly || r.lyrics == "" {
		t.Fatalf("应当交出第一份纯文本: %+v", r)
	}
	if rec.count("/songs/11/") != 0 {
		t.Error("后面那条标着没有时间轴,不该再问")
	}
}
