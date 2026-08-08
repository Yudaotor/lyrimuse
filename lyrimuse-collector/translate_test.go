package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseLRCLines(t *testing.T) {
	in := strings.Join([]string{
		"[by:someone]", // 元信息标签,没有时间戳 → 丢掉
		"[00:00.00] 作词 : Lenny Kravitz",
		"[00:20.94]我的生命",
		"[01:02]无小数的时间戳也要认",
		"[01:05:30]冒号做小数分隔符的变体",
		"[00:30.00]   ", // 正文为空 → 丢掉
		"没有时间戳的一行",
	}, "\n")
	got := parseLRCLines(in)
	want := []lrcLine{
		{"[00:00.00]", "作词 : Lenny Kravitz"},
		{"[00:20.94]", "我的生命"},
		{"[01:02]", "无小数的时间戳也要认"},
		{"[01:05:30]", "冒号做小数分隔符的变体"},
	}
	if len(got) != len(want) {
		t.Fatalf("解析出 %d 行,期望 %d 行: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("第 %d 行 = %+v, 期望 %+v", i, got[i], want[i])
		}
	}
}

// 分块不能把一行切开 —— 切开就没法跟行对上,整块都得作废。
func TestChunkForTranslationNeverSplitsALine(t *testing.T) {
	var texts []string
	for i := 0; i < 40; i++ {
		texts = append(texts, strings.Repeat("x", 30))
	}
	chunks := chunkForTranslation(texts)
	var flat []string
	for _, c := range chunks {
		joined := strings.Join(c, "\n")
		if len(joined) > translateMaxChunkChars {
			t.Errorf("有块超过上限: %d > %d", len(joined), translateMaxChunkChars)
		}
		flat = append(flat, c...)
	}
	if len(flat) != len(texts) {
		t.Fatalf("分块前后行数变了: %d → %d", len(texts), len(flat))
	}
	for i := range texts {
		if flat[i] != texts[i] {
			t.Fatalf("第 %d 行内容变了", i)
		}
	}
}

func TestChunkForTranslationOversizedSingleLine(t *testing.T) {
	long := strings.Repeat("y", translateMaxChunkChars+50)
	chunks := chunkForTranslation([]string{"短行", long, "另一短行"})
	// 超长行必须自己单独成块,不能被塞进别的块里把整块撑爆。
	for _, c := range chunks {
		if len(c) > 1 && len(strings.Join(c, "\n")) > translateMaxChunkChars {
			t.Errorf("超长行没有单独成块: %v", c)
		}
	}
}

func TestLooksLikeTargetLanguage(t *testing.T) {
	cases := []struct {
		name, lyrics, target string
		want                 bool
	}{
		{"纯中文歌 + 目标中文:跳过", "我们的时光 一起走过的日子", "zh-CN", true},
		{"中英混排的华语歌也算中文", "我们的时光 baby 一起走过", "zh-CN", true},
		{"纯英文歌:要翻", "The painful youth I've had", "zh-CN", false},
		{"日文歌:要翻(假名不是汉字,汉字不占多数)", "君のことが好きだから", "zh-CN", false},
		{"目标不是中文时一律不判,宁可多翻一次", "我们的时光", "en", false},
		{"空歌词", "", "zh-CN", false},
	}
	for _, c := range cases {
		if got := looksLikeTargetLanguage(c.lyrics, c.target); got != c.want {
			t.Errorf("%s: = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestMyMemoryLangCode(t *testing.T) {
	cases := map[string]string{
		"zh": "zh-CN", "zh-Hans": "zh-CN", "ZH-CN": "zh-CN",
		"zh-Hant": "zh-TW", "zh-TW": "zh-TW",
		"en": "en", "ja": "ja", "": "",
	}
	for in, want := range cases {
		if got := myMemoryLangCode(in); got != want {
			t.Errorf("myMemoryLangCode(%q) = %q, want %q", in, got, want)
		}
	}
}

func fakeMyMemory(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return srv
}

// 行数对不上时整块作废、回退原文 —— 这是这套逻辑里最要紧的一条:错位的译文比没有译文更糟。
func TestTranslateChunkLineCountMismatchFallsBackToSource(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		// 故意只回两行,而请求里是三行
		fmt.Fprint(w, `{"responseData":{"translatedText":"一\n二"},"responseStatus":200}`)
	})
	hc := srv.Client()
	lrc := "[00:01.00]one\n[00:02.00]two\n[00:03.00]three"
	res, err := machineTranslateLRCWithBase(context.Background(), hc, srv.URL, lrc, "zh-CN")
	if err != nil {
		t.Fatal(err)
	}
	// 三行全部回退成原文 → 每行译文都等于原文 → 全被跳过 → 没有译文,而不是错位的译文
	if res.lrc != "" {
		t.Errorf("行数对不上时应该没有译文,实际得到:\n%s", res.lrc)
	}
}

// 源语言等于目标语言时 MyMemory 把错误信息当译文返回,必须识别出来、不能写进 lyrics_tr。
func TestTranslateRejectsSameLanguageSentinel(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"responseData":{"translatedText":"PLEASE SELECT TWO DISTINCT LANGUAGES"},"responseStatus":200}`)
	})
	_, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		"[00:01.00]hello", "zh-CN")
	if err == nil {
		t.Error("哨兵串应该被当成失败,而不是当译文用")
	}
}

// 配额用尽的两种真实形态都要认出来:文档说的 quotaFinished,和实测真正返回的
// HTTP 429 + 警告文本。认错了会白烧重试次数,那首歌以后再也不会被翻。
func TestTranslateQuotaViaHTTP429(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		fmt.Fprint(w, `{"responseData":{"translatedText":""},"responseDetails":"MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY. NEXT AVAILABLE IN 15 HOURS"}`)
	})
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		"[00:01.00]hello", "zh-CN")
	if err != nil {
		t.Fatalf("429 应该被当成配额用尽而不是错误: %v", err)
	}
	if !res.quotaReached {
		t.Error("HTTP 429 + 警告文本没有被识别成配额用尽")
	}
}

func TestTranslateQuotaFinished(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"responseData":{"translatedText":"x"},"quotaFinished":true}`)
	})
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		"[00:01.00]hello", "zh-CN")
	if err != nil {
		t.Fatal(err)
	}
	if !res.quotaReached {
		t.Error("配额用尽应该被报上来,让调用方整体停下而不是继续撞")
	}
}

// 正常路径:译文沿用主歌词的时间戳,逐行对齐。
func TestTranslateKeepsSourceTimestamps(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = "译" + lines[i]
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	lrc := "[00:01.00]one\n[00:02.50]two\n[01:03.25]three"
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc, "zh-CN")
	if err != nil {
		t.Fatal(err)
	}
	want := "[00:01.00]译one\n[00:02.50]译two\n[01:03.25]译three"
	if res.lrc != want {
		t.Errorf("译文 =\n%s\n期望 =\n%s", res.lrc, want)
	}
}

func TestNeedsTranslationBackfill(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.Lyrics = true
	features.LyricsMachineTranslation = true
	features.LyricsTranslationLanguage = "zh"

	base := enrichEntry{Lyrics: "[00:01.00]hello world"}
	cases := []struct {
		name string
		e    enrichEntry
		want bool
	}{
		{"外语歌、没译文:补", base, true},
		{"已有社区译文:不动(社区翻译优于机翻)", func() enrichEntry { e := base; e.LyricsTr = "[00:01.00]你好"; return e }(), false},
		{"没有歌词:没得翻", enrichEntry{}, false},
		{"歌词本来就是中文:不翻(也躲开同语言哨兵)", enrichEntry{Lyrics: "[00:01.00]我们的时光"}, false},
		{"次数用尽", func() enrichEntry { e := base; e.TranslationRetryCount = translationBackfillMaxAttempts; return e }(), false},
		{"刚试过、还没到间隔", func() enrichEntry {
			e := base
			e.TranslationRetryCount = 1
			e.TranslationTS = time.Now().Unix()
			return e
		}(), false},
		{"间隔已过:再试", func() enrichEntry {
			e := base
			e.TranslationRetryCount = 1
			e.TranslationTS = time.Now().Unix() - int64(translationBackfillInterval/time.Second) - 1
			return e
		}(), true},
	}
	for _, c := range cases {
		if got := needsTranslationBackfill(c.e); got != c.want {
			t.Errorf("%s: = %v, want %v", c.name, got, c.want)
		}
	}

	features.LyricsMachineTranslation = false
	if needsTranslationBackfill(base) {
		t.Error("开关关掉时一律不翻")
	}
}

func jsonEscape(s string) (string, error) {
	b, err := json.Marshal(s)
	return string(b), err
}

// 每次请求都要带一个**不一样**的 de= —— MyMemory 的免费额度按邮箱分别计,固定一个就等于
// 没换。顺带钉住域名:example.com 是保留域,换成真实域名会有随机撞上真人邮箱的风险。
func TestRandomTranslateEmailIsDistinctAndReserved(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		e := randomTranslateEmail()
		if !strings.HasSuffix(e, "@example.com") {
			t.Fatalf("域名不是保留域: %q", e)
		}
		if local := strings.TrimSuffix(e, "@example.com"); len(local) < 12 {
			t.Fatalf("本地部分太短、随机性不够: %q", e)
		}
		if seen[e] {
			t.Fatalf("第 %d 次就撞了: %q", i, e)
		}
		seen[e] = true
	}
}

// 光有函数不够,得确认它真的被挂到请求上、而且逐块都换。
func TestTranslateChunkSendsFreshEmailEachRequest(t *testing.T) {
	var got []string
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.URL.Query().Get("de"))
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = "译" + lines[i]
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	// 拼一首长到必须切成多块的歌,才能验证"每块一个新邮箱"。
	var b strings.Builder
	for i := 0; i < 60; i++ {
		fmt.Fprintf(&b, "[00:%02d.00]%s\n", i, strings.Repeat("word ", 8))
	}
	if _, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL,
		strings.TrimRight(b.String(), "\n"), "zh-CN"); err != nil {
		t.Fatal(err)
	}
	if len(got) < 2 {
		t.Fatalf("只发了 %d 次请求,验证不了逐块换邮箱", len(got))
	}
	for i, e := range got {
		if !strings.Contains(e, "@example.com") {
			t.Fatalf("第 %d 次请求没带上邮箱: %q", i, e)
		}
	}
	for i := 1; i < len(got); i++ {
		if got[i] == got[i-1] {
			t.Fatalf("第 %d、%d 次请求用了同一个邮箱: %q", i-1, i, got[i])
		}
	}
}

// 这次改动的核心:一份**语言对不上**的已有译文不能再挡住机翻。
// 场景来源:网易云的社区译文固定是中文,用户把译文语言设成日语后,原来的"有译文就跳过"
// 让机翻永远没机会跑,日语用户只能一直看中文。
func TestTranslationUsableRespectsLanguage(t *testing.T) {
	cases := []struct {
		name   string
		e      enrichEntry
		target string
		want   bool
	}{
		{"没有译文", enrichEntry{}, "zh-CN", false},

		// 记了语言的:直接按语言比,不看内容。
		{"网易云中文译文 + 目标中文:用得上",
			enrichEntry{LyricsTr: "[00:01.00]你好", LyricsTrLang: "zh"}, "zh-CN", true},
		{"网易云中文译文 + 目标日语:用不上,该重翻",
			enrichEntry{LyricsTr: "[00:01.00]你好", LyricsTrLang: "zh"}, "ja", false},
		{"Musixmatch 日语译文 + 目标日语:用得上",
			enrichEntry{LyricsTr: "[00:01.00]こんにちは", LyricsTrLang: "ja"}, "ja", true},
		{"Musixmatch 日语译文 + 目标改成了中文:用不上",
			enrichEntry{LyricsTr: "[00:01.00]こんにちは", LyricsTrLang: "ja"}, "zh-CN", false},
		{"简繁也算不同语言",
			enrichEntry{LyricsTr: "[00:01.00]你好", LyricsTrLang: "zh-Hans"}, "zh-TW", false},

		// 没记语言的老条目:退回文本判别,只在能确定的方向上下判断。
		{"老条目中文译文 + 目标中文:用得上",
			enrichEntry{LyricsTr: "[00:01.00]我们的时光"}, "zh-CN", true},
		{"老条目中文译文 + 目标日语:看得出是中文,用不上",
			enrichEntry{LyricsTr: "[00:01.00]我们的时光"}, "ja", false},
		{"老条目非中文译文 + 目标日语:判不出,保守留着不重翻",
			enrichEntry{LyricsTr: "[00:01.00]Hello there"}, "ja", true},
		{"老条目非中文译文 + 目标中文:显然用不上",
			enrichEntry{LyricsTr: "[00:01.00]Hello there"}, "zh-CN", false},
	}
	for _, c := range cases {
		if got := translationUsable(c.e, c.target); got != c.want {
			t.Errorf("%s: = %v, want %v", c.name, got, c.want)
		}
	}
}

// 闸门层面走一遍同样的场景,确认 translationUsable 真的接进了 needsTranslationBackfill。
func TestNeedsTranslationBackfillIgnoresWrongLanguageTranslation(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.Lyrics = true
	features.LyricsMachineTranslation = true

	base := enrichEntry{
		Lyrics:       "[00:01.00]The painful youth I've had",
		LyricsTr:     "[00:01.00]我经历过的痛苦的青春",
		LyricsTrLang: "zh",
	}

	features.LyricsTranslationLanguage = "zh"
	if needsTranslationBackfill(base) {
		t.Error("目标是中文、已有中文译文时不该再翻一遍")
	}

	features.LyricsTranslationLanguage = "ja"
	if !needsTranslationBackfill(base) {
		t.Error("目标是日语、只有中文译文时必须让机翻接手 —— 这正是这次要修的")
	}
}

// 换了目标语言之后,上一门语言累计的失败次数不该继续挡着。
func TestNeedsTranslationBackfillResetsAttemptsOnLanguageChange(t *testing.T) {
	saved := features
	defer func() { features = saved }()
	features.Lyrics = true
	features.LyricsMachineTranslation = true
	features.LyricsTranslationLanguage = "ja"

	e := enrichEntry{
		Lyrics:                "[00:01.00]The painful youth I've had",
		TranslationRetryCount: translationBackfillMaxAttempts,
		TranslationTS:         time.Now().Unix(),
	}

	e.TranslationLang = "ja"
	if needsTranslationBackfill(e) {
		t.Error("同一个目标语言下次数用尽就该停手")
	}

	e.TranslationLang = "zh-CN" // 之前为中文失败了那么多次
	if !needsTranslationBackfill(e) {
		t.Error("换到日语后应该重新开始尝试,而不是背着中文那轮的失败次数")
	}

	e.TranslationLang = "" // 老条目没记语言:当成同一门语言,维持原有行为
	if needsTranslationBackfill(e) {
		t.Error("老条目不该因为没记语言就绕过次数上限")
	}
}
