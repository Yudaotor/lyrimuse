package main

import "testing"

// Musixmatch 纯文本回退(2026-09-02,Charlie Musselwhite《Storm Warning》案)。
//
// 病灶:resolveMusixmatchLyric 原来只调 track.subtitle.get(带时间戳的字幕),拿不到就
// 当整个源没有。而 Musixmatch 把"有没有时间轴"和"有没有词"记成两个独立字段
// (has_subtitles / has_lyrics),凡是 `has_lyrics=1 / has_subtitles=0` 的歌,词就在
// track.lyrics.get 里躺着,我们从来不问。实测那首:subtitle 回 404,lyrics 回 616 字完整
// 歌词,而界面显示"八个源都没找到"。

// 剥离器:本项目这组身份(apic-appmobile + mac-ios-v2.0)实测**不带**水印,所以最要紧的
// 用例其实是反面的——**干净正文必须原样保留**,一个字都不能被"顺手清洗"掉。
func TestSanitizeMusixmatchPlainLyricsKeepsCleanBody(t *testing.T) {
	// 2026-09-02 真实抓取的形态(首尾各带一个引号是源站自己的转写风格,不是我们要清的东西)。
	clean := "\"I hear there's a storm warning\nMy baby blowin' back into town\n\nShe's got long wavy hair\nThunder in her hips\""
	if got := sanitizeMusixmatchPlainLyrics(clean); got != clean {
		t.Errorf("干净正文被改动了:\n原=%q\n后=%q", clean, got)
	}
}

func TestSanitizeMusixmatchPlainLyricsStripsNotice(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{
			// 星号围栏形态(web-desktop-app-v1.0 那组身份会带;本项目这组没见过,防御性剥离)。
			"星号围栏及其之后整段丢掉",
			"Line one\nLine two\n\n*******\nThis Lyrics is NOT for Commercial use\n*******\n(1409618012345)",
			"Line one\nLine two",
		},
		{
			"没有围栏、只有免责声明那句",
			"Line one\nthis lyrics is not for commercial use",
			"Line one",
		},
		{
			"围栏缺失、只剩尾部追踪号",
			"Line one\nLine two\n(1409618012345)",
			"Line one\nLine two",
		},
		{"尾部空行一并裁掉", "Line one\n\n\n", "Line one"},
		{"CRLF 换行要能处理", "Line one\r\nLine two\r\n*******\r\nfoo", "Line one\nLine two"},
		{"全是水印 → 空", "*******\nThis Lyrics is NOT for Commercial use\n*******", ""},
		{"空输入", "", ""},
	}
	for _, c := range cases {
		if got := sanitizeMusixmatchPlainLyrics(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// ⚠️ 剥离规则不能放宽:歌词正文里 `(2)`、`(x3)`、星号强调这类写法很常见,
// 误伤等于把真歌词吃掉。这组反例专门钉住"不该被当成水印"的形态。
func TestMusixmatchNoticeDetectionDoesNotOverreach(t *testing.T) {
	notNotice := []string{
		"(2)",        // 太短,不是追踪号
		"(chorus)",   // 括号里不是数字
		"(12345)",    // 只有 5 位,短于下限
		"*",          // 单个星号不算围栏
		"**",         // 两个也不算
		"*emphasis*", // 带星号但不是纯星号
		"She's got (2) hearts",
	}
	for _, ln := range notNotice {
		if musixmatchNoticeLine(ln) {
			t.Errorf("%q 不该被当成水印起点", ln)
		}
		if musixmatchTrackingNumberLine(ln) {
			t.Errorf("%q 不该被当成追踪号", ln)
		}
	}
	// 正例:确实该认出来的两种。
	for _, ln := range []string{"***", "*******", "  ****  ", "This Lyrics is NOT for Commercial use"} {
		if !musixmatchNoticeLine(ln) {
			t.Errorf("%q 应该被认成水印起点", ln)
		}
	}
	for _, ln := range []string{"(1409618012345)", "(123456)"} {
		if !musixmatchTrackingNumberLine(ln) {
			t.Errorf("%q 应该被认成追踪号", ln)
		}
	}
	// 整行内容被剥完之后,正文里合法的括号数字**不能**被尾部裁剪吃掉。
	body := "Line one\nShe counts (1234567) stars"
	if got := sanitizeMusixmatchPlainLyrics(body); got != body {
		t.Errorf("行内括号数字不该被裁:\n原=%q\n后=%q", body, got)
	}
}

// 搜索阶段那道 has_subtitles 闸门的放宽(2026-09-02)。
//
// ⚠️ 这组才是真正会回归的那段。第一版只把纯文本回退加在 resolveMusixmatchLyric 里,
// 而 musixmatchSearchTrackOnce 有一道 `if HasSubtitles != 1 { continue }` —— 目标曲目在
// **搜索阶段**就被跳过,回退是死代码。抽成 pickMusixmatchTrackRow 就是为了让这道闸门
// 能脱离网络被钉住。
func TestPickMusixmatchTrackRow(t *testing.T) {
	const artist, title = "Charlie Musselwhite", "Storm Warning"

	// 实测形态:目标曲目 has_lyrics=1 / has_subtitles=0,同名另一条是别的艺人。
	rows := []musixmatchTrackRow{
		{TrackID: 322223735, TrackName: "Storm Warning", ArtistName: "Charlie Musselwhite",
			AlbumName: "Look Out Highway", HasSubtitles: 0, HasLyrics: 1, TrackLength: 245},
		{TrackID: 999, TrackName: "Storm Warning", ArtistName: "Dynatones (featuring Charlie Musselwhite)",
			AlbumName: "Curtain Call", HasSubtitles: 0, HasLyrics: 0, TrackLength: 422},
	}
	got, ok := pickMusixmatchTrackRow(rows, artist, title)
	if !ok {
		t.Fatal("有词无时间轴的曲目必须能被挑出来(放宽前就是死在这一步)")
	}
	if got.trackID != 322223735 {
		t.Errorf("挑错了条目:trackID=%d", got.trackID)
	}
	if got.hasSubtitles {
		t.Error("这条没有时间轴,hasSubtitles 应为 false(调用方据此跳过 subtitle 请求)")
	}
	if got.durationSecs != 245 {
		t.Errorf("时长应透传:%v", got.durationSecs)
	}

	// **没放过头**:有时间轴的永远优先,哪怕它排在后面。
	mixed := []musixmatchTrackRow{
		{TrackID: 1, TrackName: "Storm Warning", ArtistName: artist, HasSubtitles: 0, HasLyrics: 1},
		{TrackID: 2, TrackName: "Storm Warning", ArtistName: artist, HasSubtitles: 1, HasLyrics: 1},
	}
	got, ok = pickMusixmatchTrackRow(mixed, artist, title)
	if !ok || got.trackID != 2 || !got.hasSubtitles {
		t.Errorf("有时间轴的必须优先,得到 ok=%v id=%d hasSubtitles=%v", ok, got.trackID, got.hasSubtitles)
	}

	// 身份闸不能因为放宽而失效:歌手对不上一律不要。
	wrongArtist := []musixmatchTrackRow{
		{TrackID: 3, TrackName: "Storm Warning", ArtistName: "Michael Burks", HasSubtitles: 0, HasLyrics: 1},
	}
	if _, ok := pickMusixmatchTrackRow(wrongArtist, artist, title); ok {
		t.Error("歌手对不上的候选不该被采纳")
	}

	// 两个字段都是 0(既没时间轴也没词)→ 没有可取的东西,不要。
	neither := []musixmatchTrackRow{
		{TrackID: 4, TrackName: "Storm Warning", ArtistName: artist, HasSubtitles: 0, HasLyrics: 0},
	}
	if _, ok := pickMusixmatchTrackRow(neither, artist, title); ok {
		t.Error("既无时间轴也无词的候选不该被采纳")
	}

	if _, ok := pickMusixmatchTrackRow(nil, artist, title); ok {
		t.Error("空结果不该返回命中")
	}
}
