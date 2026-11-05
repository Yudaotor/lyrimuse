package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// fixedTitle:不管哪种语言都是这个标题(测试里直接给标题字面量时用)。
func fixedTitle(s string) func(digestWords) string { return func(digestWords) string { return s } }

// 用语表跟共用样例 shared/testdata/notify/words.json 一字不差(App 的 Core `ReportWords` 读同一份对照)。
func TestDigestWordsMatchShared(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "shared", "testdata", "notify", "words.json"))
	if err != nil {
		t.Fatal(err)
	}
	var want map[digestLang]digestWords
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(digestWordTable, want) {
		t.Errorf("digestWordTable 跟 words.json 不一致")
	}
	// 每种语言都有简体那份的全部句子。
	for lang, w := range digestWordTable {
		for key := range digestWordTable[digestLangHans] {
			if _, ok := w[key]; !ok {
				t.Errorf("%s 缺 %s", lang, key)
			}
		}
	}
}

// 俄语式的 one / few / many(plural_rule 为 ru、uk)和别的语言的单复数,同 Core UILanguage.pluralCategory、ReportWords.count。
func TestDigestWordsPluralForm(t *testing.T) {
	counts := []int{0, 1, 2, 5, 11, 21, 22, 25, 111, 12, 14, 104}
	forms := func(w digestWords) string {
		var out []string
		for _, n := range counts {
			out = append(out, w.count("plays", n))
		}
		return strings.Join(out, "|")
	}
	ru := digestWords{"plays": "{n} other", "plays_one": "{n} one", "plays_few": "{n} few", "plays_many": "{n} many", "plural_rule": "ru"}
	if got, want := forms(ru), "0 many|1 one|2 few|5 many|11 many|21 one|22 few|25 many|111 many|12 many|14 many|104 few"; got != want {
		t.Errorf("俄语: %s, want %s", got, want)
	}
	en := digestWords{"plays": "{n} other", "plays_one": "{n} one", "plays_few": "{n} few", "plays_many": "{n} many"}
	if got, want := forms(en), "0 other|1 one|2 other|5 other|11 other|21 other|22 other|25 other|111 other|12 other|14 other|104 other"; got != want {
		t.Errorf("没有 plural_rule 的只有 1 是 one: %s, want %s", got, want)
	}
	uk := digestWords{"plays": "{n} other", "plays_one": "{n} one", "plays_few": "{n} few", "plays_many": "{n} many", "plural_rule": "uk"}
	if got, want := forms(uk), "0 many|1 one|2 few|5 many|11 many|21 one|22 few|25 many|111 many|12 many|14 many|104 few"; got != want {
		t.Errorf("乌克兰语(同俄语规则): %s, want %s", got, want)
	}
	noMany := digestWords{"plays": "{n} other", "plays_one": "{n} one", "plural_rule": "ru"}
	if got := noMany.count("plays", 5); got != "5 other" {
		t.Errorf("表里没有 _many 时用 key 本身: %s", got)
	}
}

func TestParseDigestLang(t *testing.T) {
	for in, want := range map[string]digestLang{"": digestLangHans, "zh-hans": digestLangHans, " ZH-HANT ": digestLangHant, "en": digestLangEn, "ja": digestLangJa, "ko": digestLangKo, "es": digestLangEs, "fr": digestLangFr, "de": digestLangDe, "it": digestLangIt, "pt-br": digestLangPtBR, " PT-BR ": digestLangPtBR, "vi": digestLangVi, " VI ": digestLangVi, "ru": digestLangRu, " RU ": digestLangRu, "uk": digestLangUk, " UK ": digestLangUk, "pl": digestLangHans} {
		if got := parseDigestLang(in); got != want {
			t.Errorf("parseDigestLang(%q) = %q, want %q", in, got, want)
		}
	}
	path := filepath.Join(t.TempDir(), "lyrimuse-features.json")
	if err := os.WriteFile(path, []byte(`{"report_language":"en"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := loadFeatureFlags(path).ReportLanguage; got != digestLangEn {
		t.Fatalf("features.json 里 App 写的 report_language 没用上: %q", got)
	}
}

// 英文、繁体的报告:标题、第一行、正文、排版标签都换成那种语言,歌名歌手名原样。
func TestDigestReportInOtherLanguages(t *testing.T) {
	d := richSample()
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangEn})
	now := time.Date(2026, 10, 20, 22, 5, 0, 0, time.Local)
	w := dw()
	d.PrevLabel = weeklyDigestPeriod(0, 7*24*3600).prevLabel // 上一期的叫法在取数时按当时的语言算好
	for got, want := range map[string]string{
		dailyDigestTitle(w, now, midnightOf(now)):                              "🎧 Today's Listening Report (Oct 20)",
		dailyDigestTitle(w, now, midnightOf(now).AddDate(0, 0, -1)):            "🎧 Yesterday's Listening Report (Oct 19)",
		calendarDigestTitle(w, calendarDigestMonthly, now):                     "📅 October 2026 Listening Digest",
		calendarDigestTitle(w, calendarDigestYearly, now):                      "🏆 2026 Listening Digest",
		calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel: "in September",
		digestSummaryLine(*d):                         "601 plays (vs. 883 the week before, ↓32%) · about 42 h 3 min",
		digestSummaryLine(digestStats{TotalPlays: 1}): "1 play",
		digestNewArtistsLine(*d):                      "44 new artists: Patti LaBelle, The Crane, 99 God and more",
	} {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
	body := digestBody(*d)
	for _, want := range []string{"\n\nTop artists:\n1. 方大同 (129)\n", "\n\nTop albums:\n1. Michael Jackson - Xscape (Deluxe) (30)\n"} {
		if !strings.Contains(body, want) {
			t.Errorf("正文缺 %q:\n%s", want, body)
		}
	}
	if brief := digestBodyStyled(*d, digestStyleBrief); !strings.Contains(brief, "\nTop artist: 方大同\n") || !strings.Contains(brief, "New artists (44): Patti LaBelle, The Crane, 99 God") {
		t.Errorf("精简按英文预设:\n%s", brief)
	}
	m := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformTelegram, URL: "TOKEN", ChatID: "42"}, richMessage()).body)
	if text, _ := m["text"].(string); !strings.Contains(text, "<b>Top artists</b>") ||
		m["reply_markup"].(map[string]any)["inline_keyboard"].([]any)[0].([]any)[0].(map[string]any)["text"] != "See the full chart on Last.fm" {
		t.Errorf("Telegram 排版用英文标签: %v", m)
	}

	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangHant})
	w = dw()
	if got := weeklyDigestTitle(w, digestSourceLastfm, time.Date(2026, 10, 11, 0, 0, 0, 0, time.Local).Unix(), time.Date(2026, 10, 18, 0, 0, 0, 0, time.Local).Unix()); got != "🎵 上週聽歌小結（10-11~10-18）" {
		t.Errorf("繁体周报标题: %q", got)
	}
	d.PrevLabel = weeklyDigestPeriod(0, 7*24*3600).prevLabel
	if got := digestSummaryLine(*d); got != "共播放 601 次（前一週 883，↓32%） · 約 42 小時 3 分" {
		t.Errorf("繁体第一行: %q", got)
	}
	if got := richFooter(d); got != "Lyrimuse · 資料來自 Last.fm" {
		t.Errorf("繁体来源: %q", got)
	}

	// 西语的月名取表里的 month_names,数量是 1 用单数。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangEs})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Resumen de escucha de octubre de 2026" {
		t.Errorf("西语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "en septiembre" {
		t.Errorf("西语上一期: %q", got)
	}
	if got := digestSummaryLine(digestStats{TotalPlays: 1}); got != "1 reproducción" {
		t.Errorf("西语单数: %q", got)
	}
	if got := w.count("plays", 0); got != "0 reproducciones" {
		t.Errorf("西语 0 用复数: %q", got)
	}

	// 法语的月报标题不写「de + 月名」(元音开头的月份要写成 d’),0 也用单数。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangFr})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Récap d’écoute\u00a0: octobre 2026" {
		t.Errorf("法语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "en septembre" {
		t.Errorf("法语上一期: %q", got)
	}
	if got := []string{w.count("plays", 0), w.count("plays", 1), w.count("plays", 2)}; strings.Join(got, "|") != "0 écoute|1 écoute|2 écoutes" {
		t.Errorf("法语单复数: %q", got)
	}

	// 德语:月名取表里的 month_names,0 用复数。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangDe})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Hörrückblick Oktober 2026" {
		t.Errorf("德语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "im September" {
		t.Errorf("德语上一期: %q", got)
	}
	if got := []string{w.count("plays", 0), w.count("plays", 1), w.count("plays", 2)}; strings.Join(got, "|") != "0 Wiedergaben|1 Wiedergabe|2 Wiedergaben" {
		t.Errorf("德语单复数: %q", got)
	}

	// 意大利语:月名小写、取表里的 month_names,0 用复数。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangIt})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Riepilogo di ascolto di ottobre 2026" {
		t.Errorf("意大利语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "a settembre" {
		t.Errorf("意大利语上一期: %q", got)
	}
	if got := []string{w.count("plays", 0), w.count("plays", 1), w.count("plays", 2)}; strings.Join(got, "|") != "0 ascolti|1 ascolto|2 ascolti" {
		t.Errorf("意大利语单复数: %q", got)
	}

	// 巴西葡语:月名小写、取表里的 month_names,0 跟法语一样用单数。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangPtBR})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Resumo de audição de outubro de 2026" {
		t.Errorf("巴西葡语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "em setembro" {
		t.Errorf("巴西葡语上一期: %q", got)
	}
	if got := []string{w.count("plays", 0), w.count("plays", 1), w.count("plays", 2)}; strings.Join(got, "|") != "0 reprodução|1 reprodução|2 reproduções" {
		t.Errorf("巴西葡语单复数: %q", got)
	}

	// 越南语:月份写数字(「tháng 10」),名词不分单复数(同日韩,表里没有 _one)。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangVi})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Tổng kết nghe nhạc tháng 10/2026" {
		t.Errorf("越南语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "tháng 9" {
		t.Errorf("越南语上一期: %q", got)
	}
	if got := []string{w.count("plays", 0), w.count("plays", 1), w.count("plays", 2)}; strings.Join(got, "|") != "0 lượt phát|1 lượt phát|2 lượt phát" {
		t.Errorf("越南语单复数: %q", got)
	}

	// 俄语:月名主格放 month_names(「за октябрь 2026」),数量按 one / few / many 选(plural_rule)。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangRu})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Итоги прослушиваний за октябрь 2026" {
		t.Errorf("俄语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "сентябрь" {
		t.Errorf("俄语上一期: %q", got)
	}
	var ru []string
	for _, n := range []int{0, 1, 2, 5, 11, 21, 22, 25, 111} {
		ru = append(ru, w.count("plays", n))
	}
	if got, want := strings.Join(ru, "|"), "0 прослушиваний|1 прослушивание|2 прослушивания|5 прослушиваний|11 прослушиваний|21 прослушивание|22 прослушивания|25 прослушиваний|111 прослушиваний"; got != want {
		t.Errorf("俄语单复数: %q", got)
	}
	if got := w.count("new_artists", 22); got != "22 новых артиста" {
		t.Errorf("俄语新歌手: %q", got)
	}

	// 乌克兰语:同俄语的 one / few / many 规则(plural_rule uk),月名主格(「за жовтень 2026」)。
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangUk})
	w = dw()
	if got := calendarDigestTitle(w, calendarDigestMonthly, now); got != "📅 Підсумки прослуховувань за жовтень 2026" {
		t.Errorf("乌克兰语月报标题: %q", got)
	}
	if got := calendarDigestPeriod(calendarDigestMonthly, now, now, false).prevLabel; got != "вересень" {
		t.Errorf("乌克兰语上一期: %q", got)
	}
	var uk []string
	for _, n := range []int{0, 1, 2, 5, 11, 12, 14, 21, 22, 25, 104, 111} {
		uk = append(uk, w.count("plays", n))
	}
	if got, want := strings.Join(uk, "|"), "0 прослуховувань|1 прослуховування|2 прослуховування|5 прослуховувань|11 прослуховувань|12 прослуховувань|14 прослуховувань|21 прослуховування|22 прослуховування|25 прослуховувань|104 прослуховування|111 прослуховувань"; got != want {
		t.Errorf("乌克兰语单复数: %q", got)
	}
	if got := w.count("new_artists", 5) + "|" + w.count("new_artists", 21) + "|" + w.count("new_artists", 22); got != "5 нових виконавців|21 новий виконавець|22 нові виконавці" {
		t.Errorf("乌克兰语新歌手: %q", got)
	}
}

// 切成英文以后推的报告:标题是英文,推送记录里认「同一期」的键仍是简体标题,同一期再推一次认得出已经推过。
func TestDigestPushKeepsHansKey(t *testing.T) {
	withNotifyLogForTest(t)
	var mu sync.Mutex
	var titles []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		_ = json.NewDecoder(r.Body).Decode(&m)
		mu.Lock()
		titles = append(titles, m["title"].(string))
		mu.Unlock()
	}))
	defer srv.Close()
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangEn})
	a := alerterFromConfig(&config{NotificationChannels: []notifyChannel{{ID: "wh", Platform: platformWebhook, URL: srv.URL, Enabled: true}}})
	now := time.Date(2026, 10, 20, 22, 5, 0, 0, time.Local)
	title := func(w digestWords) string { return dailyDigestTitle(w, now, midnightOf(now)) }
	if err := digestPush(a, notifyEventDaily, title, *richSample()); err != nil {
		t.Fatal(err)
	}
	e, ok := lastNotifyLogEntry(t)
	if len(titles) != 1 || titles[0] != "🎧 Today's Listening Report (Oct 20)" || !ok || e.Key != "🎧 今日听歌报告（10-20）" {
		t.Fatalf("titles=%v entry=%+v", titles, e)
	}
	if err := digestPush(a, notifyEventDaily, title, *richSample()); err != nil || len(titles) != 1 {
		t.Errorf("同一期再推一次应认出已经推过: err=%v titles=%v", err, titles)
	}
}

// reportLangCase 是共用样例 shared/testdata/notify/report-lang.json 的一条:preview.json 里的日报 / 周报样例按某种语言、
// 某一套内容拼出来的标题、第一行、纯文本正文、排版用的各段和新歌手那句。App 的 Core `NotificationPreview` 照同一份对拍。
type reportLangCase struct {
	Lang     string `json:"lang"`
	Kind     string `json:"kind"`
	Style    string `json:"style"`
	TopN     int    `json:"top_n"`
	Title    string `json:"title"`
	Summary  string `json:"summary"`
	Body     string `json:"body"`
	Sections []struct {
		Heading string   `json:"heading"`
		Title   string   `json:"title"`
		Lines   []string `json:"lines"`
	} `json:"sections"`
	NewLine string `json:"new_line"`
}

func reportLangCaseFor(t *testing.T, s notifyPreviewSample, lang digestLang, kind, style string, topN int) reportLangCase {
	t.Helper()
	useDigestFeatures(t, featureFlags{DigestTopN: topN, ReportLanguage: lang})
	w := dw()
	st := s.statsFor(kind, topN)
	if st.PrevPlays > 0 {
		st.PrevLabel = w["prev_week"]
	}
	now := time.Date(s.Now.Year, time.Month(s.Now.Month), s.Now.Day, s.Now.Hour, s.Now.Minute, 0, 0, time.Local)
	c := reportLangCase{Lang: string(lang), Kind: kind, Style: style, TopN: topN, Summary: digestSummaryLine(st), Body: digestBodyStyled(st, style)}
	if kind == "daily" {
		_, from, _ := dailyDigestTarget(now, defaultDigestPushMinutes)
		c.Title = dailyDigestTitle(w, now, from)
	} else {
		monday := time.Date(now.Year(), now.Month(), now.Day()-int((now.Weekday()+6)%7), 0, 0, 0, 0, time.Local)
		c.Title = weeklyDigestTitle(w, digestSourceListenBrainz, monday.AddDate(0, 0, -7).Unix(), monday.Unix())
	}
	d := &richDigest{digestStats: &st, style: style}
	for _, sec := range d.sections(func(s string) string { return s }) {
		c.Sections = append(c.Sections, struct {
			Heading string   `json:"heading"`
			Title   string   `json:"title"`
			Lines   []string `json:"lines"`
		}{sec.heading, sec.title, sec.lines})
	}
	c.NewLine = d.newLine()
	return c
}

// 三种语言 × 日报周报 × 三套内容拼出来的跟共用样例一字不差。LYRIMUSE_WRITE_REPORT_LANG=1 时按现在的实现重写样例
// (改了用语表以后用,写完逐条看一遍再提交)。
func TestDigestReportLangSample(t *testing.T) {
	s := loadNotifyPreviewSample(t)
	path := filepath.Join("..", "shared", "testdata", "notify", "report-lang.json")
	var got []reportLangCase
	for _, lang := range []digestLang{digestLangHans, digestLangHant, digestLangEn, digestLangJa, digestLangKo, digestLangEs, digestLangFr, digestLangDe, digestLangIt, digestLangPtBR, digestLangVi, digestLangRu, digestLangUk} {
		for _, kind := range []string{"daily", "weekly"} {
			for _, style := range []string{digestStyleFull, digestStyleBrief, digestStyleOverview} {
				got = append(got, reportLangCaseFor(t, s, lang, kind, style, 3))
			}
		}
	}
	if os.Getenv("LYRIMUSE_WRITE_REPORT_LANG") == "1" {
		b, _ := json.MarshalIndent(map[string]any{"cases": got}, "", "  ")
		if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var want struct {
		Cases []reportLangCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want.Cases) {
		for i := range got {
			if i < len(want.Cases) && !reflect.DeepEqual(got[i], want.Cases[i]) {
				t.Errorf("%s %s %s:\n got  %+v\n want %+v", got[i].Lang, got[i].Kind, got[i].Style, got[i], want.Cases[i])
			}
		}
		if len(got) != len(want.Cases) {
			t.Errorf("cases = %d, want %d", len(got), len(want.Cases))
		}
	}
}

// 换进去的歌名、歌手名里带 {n}、{name} 这类字样时原样留着,不被后面的名字再换一遍。
func TestDigestWordsFillOnce(t *testing.T) {
	w := digestWordsFor(digestLangHans)
	if got := w.f("item", "i", "1", "name", "Song {n} {name}", "n", "4"); got != "1. Song {n} {name}（4）" {
		t.Errorf("item = %q", got)
	}
	if got := w.f("pair", "artist", "A {name}", "name", "B"); got != "A {name} - B" {
		t.Errorf("pair = %q", got)
	}
}

// 精简那一段里没有歌手的专辑、歌曲只写名字(同 App 预览),不多出「 — 」。
func TestBriefTopOnesWithoutArtist(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	st := digestStats{TotalPlays: 5, TopAlbums: []digestTally{{Name: "X", Count: 5}}}
	secs := (&richDigest{digestStats: &st, style: digestStyleBrief}).sections(func(s string) string { return s })
	if len(secs) != 1 || len(secs[0].lines) != 1 || secs[0].lines[0] != "专辑：X · 5" {
		t.Errorf("%+v", secs)
	}
}

// 钉钉 / 飞书说消息里没有关键词、报告是英文写的:改用简体标题推一次纯文本;简体报告不重推。
func TestKeywordRejectedRetriesWithHansTitle(t *testing.T) {
	var mu sync.Mutex
	var texts []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m map[string]any
		_ = json.NewDecoder(r.Body).Decode(&m)
		text := ""
		if c, ok := m["text"].(map[string]any); ok {
			text, _ = c["content"].(string)
		}
		mu.Lock()
		texts = append(texts, text)
		mu.Unlock()
		if !strings.Contains(text, "听歌") {
			io.WriteString(w, `{"errcode":310000,"errmsg":"keywords not in content"}`)
			return
		}
		io.WriteString(w, `{"errcode":0,"errmsg":"ok"}`)
	}))
	defer srv.Close()
	ch := notifyChannel{ID: "dd", Platform: platformDingtalk, URL: srv.URL + "/robot/send?access_token=x", Enabled: true}
	msg := func() notifyMessage {
		d := richSample()
		return notifyMessage{Event: notifyEventDaily, Title: dw().f("title_today", "date", "Oct 20"), Body: digestBody(*d), Digest: d,
			Key: "🎧 今日听歌报告（10-20）"}
	}
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangEn})
	if r := pushToChannel(ch, msg()); !r.OK || len(texts) != 2 || !strings.HasPrefix(texts[1], "🎧 今日听歌报告（10-20）\n") {
		t.Fatalf("英文报告关键词没过应改用简体标题重推: ok=%v texts=%q", r.OK, texts)
	}
	texts = nil
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	m := msg()
	m.Title = "我的标题"
	if r := pushToChannel(ch, m); r.OK || len(texts) != 1 {
		t.Errorf("简体报告的关键词问题是用户自己的配置,不重推: ok=%v 次数=%d", r.OK, len(texts))
	}
}

// Server酱:标题截到 32 字、微信卡片摘要截到 64 字(英文标题会超)。
func TestServerChanClipsTitleAndShort(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2, ReportLanguage: digestLangEn})
	d := richSample()
	d.Truncated = true
	msg := notifyMessage{Event: notifyEventWeekly, Title: "🎵 Last Week's Listening Digest (Oct 20 – Oct 26)", Body: digestBody(*d), Digest: d}
	for _, formatted := range []bool{true, false} {
		nr, err := buildNotifyRequestAs(notifyChannel{Platform: platformServerChan, URL: "https://sctapi.ftqq.com/x.send"}, msg, formatted)
		if err != nil {
			t.Fatal(err)
		}
		form, _ := url.ParseQuery(string(nr.body))
		if n := len([]rune(form.Get("title"))); n > serverChanTitleMax || !strings.HasPrefix(form.Get("title"), "🎵 Last Week") {
			t.Errorf("formatted=%v title(%d) = %q", formatted, n, form.Get("title"))
		}
		if n := len([]rune(form.Get("short"))); n > serverChanShortMax {
			t.Errorf("formatted=%v short(%d) = %q", formatted, n, form.Get("short"))
		}
	}
}
