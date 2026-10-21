package main

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"net/http"
	neturl "net/url"
	"strings"
	"testing"
)

// petitWord 的测试写法:{起点, 终点, 字}。
type petitTestWord struct {
	start, end int
	text       string
}

// petitTestWSY 拼一份逐字那一档的 lyricsData(base64 的 XML)。
func petitTestWSY(lines ...[]petitTestWord) string {
	var b strings.Builder
	fmt.Fprintf(&b, "<wsy><linenum>%d</linenum>", len(lines))
	for _, ws := range lines {
		var text strings.Builder
		for _, w := range ws {
			text.WriteString(w.text)
		}
		fmt.Fprintf(&b, "<line><linestring>%s</linestring><wordnum>%d</wordnum>", text.String(), len(ws))
		for _, w := range ws {
			fmt.Fprintf(&b, "<word><starttime>%d</starttime><chanum>1</chanum><endtime>%d</endtime><wordstring>%s</wordstring></word>",
				w.start, w.end, w.text)
		}
		b.WriteString("</line>")
	}
	b.WriteString("</wsy>")
	return base64.StdEncoding.EncodeToString([]byte(b.String()))
}

// petitChars 把一句按字切开,从 start 起每个字 dur 毫秒。
func petitChars(start, dur int, s string) []petitTestWord {
	var out []petitTestWord
	for _, r := range s {
		out = append(out, petitTestWord{start, start + dur, string(r)})
		start += dur
	}
	return out
}

var petitTestSync = petitTestWSY(
	petitChars(1000, 200, "過ぎてゆくんだ"),
	petitChars(5000, 200, "今日も"),
	petitChars(9000, 200, "この寿命の"),
	petitChars(13000, 200, "通りに"),
)

// withPetitFake:withKugouFakeReq 加上把轮换位置归零(用例之间不互相影响)。
func withPetitFake(t *testing.T, handle func(r *http.Request, target string) (int, string)) *kgFake {
	t.Helper()
	saved := petitClientIdx.Load()
	petitClientIdx.Store(0)
	t.Cleanup(func() { petitClientIdx.Store(saved) })
	return withKugouFakeReq(t, handle)
}

func petitTestSong(id, title, artist, album string, durMs int, lyricsType, official, data string) string {
	return fmt.Sprintf("<song><lyricsId>%s</lyricsId><title>%s</title><artist>%s</artist><album>%s</album>"+
		"<duration>%d</duration><lyricsType>%s</lyricsType><isOfficial>%s</isOfficial><postUserName>someone</postUserName>"+
		"<lyricsData>%s</lyricsData></song>", id, title, artist, album, durMs, lyricsType, official, data)
}

func petitTestResponse(songs ...string) string {
	return "<?xml version='1.0' encoding='UTF-8' ?><response><status>00000000</status><songs><matchedCount>" +
		fmt.Sprint(len(songs)) + "</matchedCount>" + strings.Join(songs, "") + "</songs></response>"
}

func TestPetitBuildLyrics(t *testing.T) {
	data := petitTestWSY(
		[]petitTestWord{{1000, 1200, "君"}, {1200, 1400, "を"}, {1300, 1500, "待"}},
		[]petitTestWord{{3000, 3050, "B"}, {3050, 3100, "y"}, {3100, 3200, " "}, {3200, 3250, "m"}, {3250, 3300, "y"}},
		[]petitTestWord{{2000, 2100, "早"}},
		[]petitTestWord{{5000, 5100, " "}},
		[]petitTestWord{{7000, 7100, "終"}, {7100, 7200, "わ"}, {7200, 7300, "り"}},
	)
	lrc, yrc := petitBuildLyrics(data)
	if want := "[00:01.00]君を待\n[00:03.00]By my\n[00:05.00]\n[00:07.00]終わり\n"; lrc != want {
		t.Errorf("LRC:\n%s\n期望:\n%s", lrc, want)
	}
	lines := strings.Split(yrc, "\n")
	if len(lines) != 3 {
		t.Fatalf("YRC 应有 3 行(早于上一行的、只有空白的丢掉): %q", yrc)
	}
	if want := "[1000,500](1000,200,0)君(1200,100,0)を(1300,200,0)待"; lines[0] != want {
		t.Errorf("后一个字早于前一个字的终点时截短前一个: %q", lines[0])
	}
	if want := "[3000,300](3000,200,0)By (3200,100,0)my"; lines[1] != want {
		t.Errorf("连着的英文字母并成一个词、空格并进前一个词: %q", lines[1])
	}
	if lrc, yrc := petitBuildLyrics("not base64!"); lrc != "" || yrc != "" {
		t.Error("解不开时两个都是空串")
	}
}

func TestPetitPlainText(t *testing.T) {
	data := base64.StdEncoding.EncodeToString([]byte("一行目\r\n二行目\r\n"))
	if got := petitPlainText(data); got != "一行目\n二行目" {
		t.Errorf("petitPlainText = %q", got)
	}
}

func TestPetitCandidateScoreGates(t *testing.T) {
	song := func(title, artist, album string, durMs int, lyricsType, official string) petitSong {
		return petitSong{LyricsID: "1", Title: title, Artist: artist, Album: album, Duration: fmt.Sprint(durMs),
			LyricsType: lyricsType, IsOfficial: official}
	}
	const artist, title, album, dur = "Mrs. GREEN APPLE", "ライラック", "ライラック - Single", 288.0
	base := petitCandidateScore(song(title, artist, "ライラック", 288100, "3", "0"), artist, title, album, dur)
	if base < 0 {
		t.Fatal("同名同歌手、时长对得上应过闸")
	}
	for name, s := range map[string]petitSong{
		"歌名对不上":     song("青と夏", artist, "ライラック", 288100, "3", "1"),
		"歌手对不上":     song(title, "BLANKEY JET CITY", "ライラック", 288100, "3", "1"),
		"现场版":       song(title+" (Live)", artist, "ライラック", 288100, "3", "1"),
		"时长差超过 8 秒": song(title, artist, "ライラック", 297000, "3", "1"),
		"没有 id":     {Title: title, Artist: artist, LyricsType: "3"},
		"罗马字版":      song(title+"(romaji)", artist, "ライラック", 288100, "3", "0"),
	} {
		if petitCandidateScore(s, artist, title, album, dur) >= 0 {
			t.Errorf("%s: 应淘汰", name)
		}
	}
	official := petitCandidateScore(song(title, artist, "ライラック", 288100, "3", "1"), artist, title, album, dur)
	if official <= base {
		t.Errorf("时长对得上的官方同步应排在用户上传前面: official=%d user=%d", official, base)
	}
	farOfficial := petitCandidateScore(song(title, artist, "ライラック", 290500, "3", "1"), artist, title, album, dur)
	if farOfficial >= base {
		t.Errorf("时长差过 1 秒的官方同步不是这一条录音,不再优先: official=%d user=%d", farOfficial, base)
	}
	if line := petitCandidateScore(song(title, artist, "ライラック", 288100, "2", "0"), artist, title, album, dur); line >= base {
		t.Errorf("逐字的排在只有逐行的前面: line=%d word=%d", line, base)
	}
	line := petitCandidateScore(song(title, artist, "ライラック", 288100, "2", "0"), artist, title, album, dur)
	if plain := petitCandidateScore(song(title, artist, "ライラック", 288100, "1", "0"), artist, title, album, dur); plain >= line {
		t.Errorf("逐行的排在只有纯文本的前面: plain=%d line=%d", plain, line)
	}
}

func TestPetitQueriesDedupe(t *testing.T) {
	got := petitQueries("ライラック", "Mrs. GREEN APPLE", "ライラック")
	if len(got) != 2 || got[0] != [2]string{"ライラック", "Mrs. GREEN APPLE"} || got[1] != [2]string{"ライラック", ""} {
		t.Errorf("先带歌手、再只按歌名,原样歌名没被清理时不重复: %v", got)
	}
	if got := petitQueries("Song", "", "Song (Remastered)"); len(got) != 2 || got[1][0] != "Song (Remastered)" {
		t.Errorf("没有歌手时不重复、歌名被清理过时再按原样搜: %v", got)
	}
}

// 搜索给的第一名是用户上传(自带正文),官方那份排在后面、要按 id 另取:选官方那份。
func TestResolvePetitLyricPrefersOfficial(t *testing.T) {
	var searches []string
	var fetched []string
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		if !strings.HasSuffix(target, "/api/GetPetitLyricsData.php") {
			return http.StatusNotFound, ""
		}
		_ = r.ParseForm()
		if r.Form.Get("clientAppId") == "" || r.Form.Get("terminalType") == "" {
			return http.StatusOK, `<response><status>8150f001</status></response>`
		}
		if id := r.Form.Get("key_lyricsId"); id != "" {
			fetched = append(fetched, id)
			return http.StatusOK, petitTestResponse(petitTestSong("2", "ライラック", "Mrs. GREEN APPLE", "ライラック", 288100, "3", "1", petitTestSync))
		}
		searches = append(searches, r.Form.Get("key_title")+"|"+r.Form.Get("key_artist")+"|"+r.Form.Get("key_duration"))
		user := petitTestWSY(petitChars(3000, 200, "別の"), petitChars(6000, 200, "時間軸"), petitChars(9000, 200, "です"))
		return http.StatusOK, petitTestResponse(
			petitTestSong("1", "ライラック", "Mrs. GREEN APPLE", "ライラック", 288100, "3", "0", user),
			petitTestSong("2", "ライラック", "Mrs. GREEN APPLE", "ライラック", 288100, "3", "1", ""),
			petitTestSong("3", "ライラック", "BLANKEY JET CITY", "ライラック", 288000, "3", "1", ""),
		)
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := resolvePetitLyric(ctx, "Mrs. GREEN APPLE", "ライラック", "ライラック - Single", 288)
	if len(searches) != 1 || searches[0] != "ライラック|Mrs. GREEN APPLE|288000" {
		t.Errorf("先按歌名 + 第一位歌手 + 毫秒时长搜一次就够: %v", searches)
	}
	if len(fetched) != 1 || fetched[0] != "2" {
		t.Errorf("只按 id 取没带正文的那条: %v", fetched)
	}
	if !strings.Contains(r.lyrics, "過ぎてゆくんだ") || r.yrc == "" || r.plainOnly {
		t.Errorf("应选官方那份逐字: %+v", r)
	}
	if r.durationSecs != 288.1 || r.album != "ライラック" {
		t.Errorf("时长、专辑取这份歌词登记的: %+v", r)
	}
	if !sub.complete(ctx) {
		t.Error("都问成了,结果是完整的")
	}
}

// 带歌手一条都没过闸时只按歌名再搜;官方那份取词 502 时退到下一名,但这份结果不算完整。
func TestResolvePetitLyricTitleOnlyAndFailedFetch(t *testing.T) {
	var searches []string
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		if r.Form.Get("key_lyricsId") == "5" {
			return http.StatusBadGateway, ""
		}
		searches = append(searches, r.Form.Get("key_artist"))
		if r.Form.Get("key_artist") != "" {
			return http.StatusOK, petitTestResponse()
		}
		return http.StatusOK, petitTestResponse(
			petitTestSong("4", "Lemon", "米津玄師", "Lemon", 255000, "3", "0", petitTestSync),
			petitTestSong("5", "Lemon", "米津玄師", "Lemon", 255000, "3", "1", ""),
		)
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := resolvePetitLyric(ctx, "米津玄師", "Lemon", "Lemon", 255)
	if len(searches) != 2 || searches[0] != "米津玄師" || searches[1] != "" {
		t.Errorf("带歌手没结果时只按歌名再搜: %q", searches)
	}
	if r.lyrics == "" || r.yrc == "" {
		t.Fatalf("官方那份取不到时用下一名的逐字: %+v", r)
	}
	if sub.complete(ctx) {
		t.Error("有一份没问成,结果不算完整、不进缓存")
	}
}

// 过闸的都只有逐行(加密的那档):名次最高的那份按纯文本再取一次,交 plainOnly。
func TestResolvePetitLyricPlainFallback(t *testing.T) {
	var types []string
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		if id := r.Form.Get("key_lyricsId"); id != "" {
			types = append(types, id+":"+r.Form.Get("lyricsType"))
			plain := base64.StdEncoding.EncodeToString([]byte("一行目\r\n二行目"))
			return http.StatusOK, petitTestResponse(petitTestSong(id, "GOD_i", "Number_i", "GOD_i", 215000, "1", "1", plain))
		}
		return http.StatusOK, petitTestResponse(
			petitTestSong("7", "GOD_i", "Number_i", "GOD_i", 215000, "2", "1", "TUhEUk9CSlQ="),
			petitTestSong("8", "GOD_i", "Number_i", "GOD_i", 215000, "2", "0", ""),
		)
	})
	r := resolvePetitLyric(qqRoundCtx(), "Number_i", "GOD_i", "GOD_i - Single", 215)
	if len(types) != 1 || types[0] != "7:1" {
		t.Errorf("逐行那档不按 id 取逐字,只把第一名按纯文本取一次: %v", types)
	}
	if !r.plainOnly || r.lyrics != "一行目\n二行目" {
		t.Errorf("交纯文本: %+v", r)
	}
}

func TestResolvePetitLyricStatusErrorIsEmpty(t *testing.T) {
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		return http.StatusOK, `<response><status>8150f001</status></response>`
	})
	if r := resolvePetitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 213); r.lyrics != "" {
		t.Errorf("status 不是成功时什么都不给: %+v", r)
	}
}

func TestRankLyricSourceResultsPetitLyrics(t *testing.T) {
	var lines [][]petitTestWord
	for i := 0; i < 20; i++ {
		lines = append(lines, petitChars((10+i*10)*1000, 300, "歌詞の一行"))
	}
	lrc, yrc := petitBuildLyrics(petitTestWSY(lines...))
	var got *scoredLyricCandidateResult
	for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, map[string]lyricSourceResult{
		"petitlyrics": {source: "petitlyrics", lyr: lrc, yrc: yrc, srcDur: 220, matchTitle: "Song", matchArtist: "Artist"},
	}) {
		if c.Source == "petitlyrics" {
			c := c
			got = &c
		}
	}
	if got == nil || !got.HasWordTiming || got.LyricsYRC == "" {
		t.Fatalf("逐字应装进候选: %+v", got)
	}
}

// 官方的纯文本、逐行分数排在用户上传的逐字前面时,逐字照样只在带逐字的那几份里取。
func TestResolvePetitLyricWordAmongLowerRanked(t *testing.T) {
	var fetched []string
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		if id := r.Form.Get("key_lyricsId"); id != "" {
			fetched = append(fetched, id+":"+r.Form.Get("lyricsType"))
			return http.StatusOK, petitTestResponse(petitTestSong(id, "ヴァンパイア", "DECO*27", "ヴァンパイア", 178000, "3", "0", petitTestSync))
		}
		return http.StatusOK, petitTestResponse(
			petitTestSong("11", "ヴァンパイア", "DECO*27", "MANNEQUIN", 178000, "1", "1", ""),
			petitTestSong("12", "ヴァンパイア", "DECO*27", "ヴァンパイア", 178300, "2", "1", ""),
			petitTestSong("13", "ヴァンパイア", "DECO*27", "ヴァンパイア", 178200, "1", "1", ""),
			petitTestSong("14", "ヴァンパイア", "DECO*27", "ヴァンパイア", 178200, "3", "0", ""),
		)
	})
	r := resolvePetitLyric(qqRoundCtx(), "DECO*27", "ヴァンパイア", "ヴァンパイア - Single", 178)
	if len(fetched) != 1 || fetched[0] != "14:3" {
		t.Errorf("只取带逐字的那份: %v", fetched)
	}
	if r.plainOnly || r.yrc == "" {
		t.Errorf("应拿到逐字: %+v", r)
	}
}

func TestPetitCacheKeyedByDurationAndComplete(t *testing.T) {
	var searches int
	failFetch := true
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		if r.Form.Get("key_lyricsId") != "" {
			if failFetch {
				return http.StatusBadGateway, ""
			}
			return http.StatusOK, petitTestResponse(petitTestSong("2", "アイドル", "YOASOBI", "アイドル", 213300, "3", "1", petitTestSync))
		}
		searches++
		return http.StatusOK, petitTestResponse(
			petitTestSong("1", "アイドル", "YOASOBI", "アイドル", 213300, "3", "0", petitTestSync),
			petitTestSong("2", "アイドル", "YOASOBI", "アイドル", 213300, "3", "1", ""),
		)
	})
	petitMu.Lock()
	saved := petitCache
	petitCache = map[string]petitResult{}
	petitMu.Unlock()
	t.Cleanup(func() {
		petitMu.Lock()
		petitCache = saved
		petitMu.Unlock()
	})
	if r := petitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 213); r.lyrics == "" {
		t.Fatal("官方那份取不到时用第二名的逐字")
	}
	n := searches
	petitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 213)
	if searches == n {
		t.Error("有一份没问成的结果不进缓存,第二次要重搜")
	}
	failFetch = false
	petitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 213)
	n = searches
	petitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 213)
	if searches != n {
		t.Errorf("同一时长、问齐了的第二次应命中缓存, searches %d -> %d", n, searches)
	}
	if r := petitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 180); searches == n || r.lyrics != "" {
		t.Errorf("差 33 秒的另一版不能拿 213 秒那份的结果: searches=%d r=%+v", searches, r)
	}
}

// status 不是成功时,哪怕应答里带着曲目也不用;纯文本那一趟回来的不是纯文本(只有逐行的加密档)时不交。
func TestResolvePetitLyricStatusAndPlainType(t *testing.T) {
	body := petitTestResponse(petitTestSong("1", "アイドル", "YOASOBI", "アイドル", 213300, "3", "1", petitTestSync))
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		return http.StatusOK, strings.Replace(body, "<status>00000000</status>", "<status>8150f001</status>", 1)
	})
	if r := resolvePetitLyric(qqRoundCtx(), "YOASOBI", "アイドル", "アイドル", 213); r.lyrics != "" {
		t.Errorf("status 不是成功时不用应答里的曲目: %+v", r)
	}
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		if id := r.Form.Get("key_lyricsId"); id != "" {
			return http.StatusOK, petitTestResponse(petitTestSong(id, "GOD_i", "Number_i", "GOD_i", 215000, "2", "1", "TUhEUk9CSlQ="))
		}
		return http.StatusOK, petitTestResponse(petitTestSong("7", "GOD_i", "Number_i", "GOD_i", 215000, "2", "1", "TUhEUk9CSlQ="))
	})
	if r := resolvePetitLyric(qqRoundCtx(), "Number_i", "GOD_i", "GOD_i", 215); r.lyrics != "" {
		t.Errorf("纯文本那一趟回的不是纯文本时不交: %+v", r)
	}
}

// petitTestLineSync 拼一份逐行那一档(base64):times 是百分之一秒,按 id(开关打开时先对调)异或;slot 是每行文字槽宽。
func petitTestLineSync(times []int, id uint16, swap bool, slot int) string {
	n := len(times)
	raw := make([]byte, petitLineTimesOff+2*n+slot*n)
	copy(raw, "MHDROBJT")
	copy(raw[0x2c:], "MLRCOBJT")
	if swap {
		raw[petitLineKeySwitchOff] = 1
	}
	binary.LittleEndian.PutUint16(raw[petitLineKeyOff:], id)
	binary.LittleEndian.PutUint32(raw[petitLineCountOff:], uint32(n))
	binary.LittleEndian.PutUint16(raw[petitLineSlotOff:], uint16(slot))
	key := petitLineKey(id, swap)
	for i, cs := range times {
		binary.LittleEndian.PutUint16(raw[petitLineTimesOff+2*i:], uint16(cs)^key)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

func TestPetitLineKey(t *testing.T) {
	if petitLineKey(0xcd4c, false) != 0xcd4c {
		t.Error("开关没开时保护号就是密钥")
	}
	for in, want := range map[uint16]uint16{0x000c: 0x0030, 0x0030: 0x000c, 0x00c0: 0x0300, 0x0300: 0x00c0, 0x0c00: 0x3000, 0x3000: 0x0c00, 0xc003: 0xc003} {
		if got := petitLineKey(in, true); got != want {
			t.Errorf("petitLineKey(%#04x) = %#04x,期望 %#04x", in, got, want)
		}
	}
}

func TestPetitLineTimes(t *testing.T) {
	data := petitTestLineSync([]int{0, 506, 787, 65000, 100}, 0xcd4c, true, 64)
	ms, ok := petitLineTimes(data)
	if !ok {
		t.Fatal("合法的逐行应解得开")
	}
	want := []int{0, 5060, 7870, 650000, (65536 + 100) * 10}
	if fmt.Sprint(ms) != fmt.Sprint(want) {
		t.Errorf("时间 = %v,期望 %v(后一行比前一行小是绕了一圈)", ms, want)
	}
	raw, _ := base64.StdEncoding.DecodeString(data)
	for name, bad := range map[string][]byte{
		"长度跟行数对不上": raw[:len(raw)-1],
		"头不对":      append([]byte("XHDROBJT"), raw[8:]...),
		"太短":       raw[:0x40],
	} {
		if _, ok := petitLineTimes(base64.StdEncoding.EncodeToString(bad)); ok {
			t.Errorf("%s: 不该解", name)
		}
	}
}

func TestPetitZipLines(t *testing.T) {
	if got := petitZipLines([]int{1000, 2000, 3000}, "一\r\n\r\n三\r\n\r\n"); got != "[00:01.00]一\n[00:02.00]\n[00:03.00]三\n" {
		t.Errorf("末尾空行去掉、中间空行占一个时间: %q", got)
	}
	if got := petitZipLines([]int{1000, 2000}, "一\n二\n三"); got != "" {
		t.Errorf("行数对不上不配: %q", got)
	}
}

// 过闸的只有逐行:时间和纯文本两趟取,逐行配成 LRC;配不上(行数不同)时退成纯文本,纯文本不再取第二次。
func TestResolvePetitLyricLineSync(t *testing.T) {
	for _, c := range []struct {
		name  string
		text  string
		plain bool
	}{
		{"行数对得上", "一行目\r\n二行目\r\n三行目\r\n四行目", false},
		{"行数对不上", "一行目\r\n二行目", true},
	} {
		var fetched []string
		withPetitFake(t, func(r *http.Request, target string) (int, string) {
			_ = r.ParseForm()
			if id := r.Form.Get("key_lyricsId"); id != "" {
				lt := r.Form.Get("lyricsType")
				fetched = append(fetched, id+":"+lt)
				if lt == petitTypePlain {
					return http.StatusOK, petitTestResponse(petitTestSong(id, "GOD_i", "Number_i", "GOD_i", 215000, "1", "1",
						base64.StdEncoding.EncodeToString([]byte(c.text))))
				}
				return http.StatusOK, petitTestResponse(petitTestSong(id, "GOD_i", "Number_i", "GOD_i", 215000, "2", "1",
					petitTestLineSync([]int{135, 545, 787, 1084}, 0xa4ce, true, 64)))
			}
			return http.StatusOK, petitTestResponse(
				petitTestSong("21", "GOD_i", "Number_i", "GOD_i", 215000, "1", "1", ""),
				petitTestSong("22", "GOD_i", "Number_i", "GOD_i", 215000, "2", "1", ""),
			)
		})
		r := resolvePetitLyric(qqRoundCtx(), "Number_i", "GOD_i", "GOD_i - Single", 215)
		if c.plain {
			if !r.plainOnly || r.lyrics == "" {
				t.Errorf("%s: 退成纯文本: %+v", c.name, r)
			}
			continue
		}
		if r.plainOnly || !strings.HasPrefix(r.lyrics, "[00:01.35]一行目\n[00:05.45]二行目\n") {
			t.Errorf("%s: 应配成逐行 LRC: %+v", c.name, r)
		}
		if len(fetched) != 2 {
			t.Errorf("%s: 时间和纯文本各取一次: %v", c.name, fetched)
		}
	}
}

// 当前那组的编号被作废或主机 5xx 时换下一组,换过去之后一直用它;参数错不换;每组至多一次。
func TestPetitPostRotatesClients(t *testing.T) {
	var hits []string
	reject := map[string]string{}
	withPetitFake(t, func(r *http.Request, target string) (int, string) {
		_ = r.ParseForm()
		host := strings.TrimSuffix(strings.TrimPrefix(target, "https://"), "/api/GetPetitLyricsData.php")
		hits = append(hits, host+":"+r.Form.Get("clientAppId")+":"+r.Form.Get("terminalType"))
		switch reject[host] {
		case "client":
			return http.StatusOK, `<response><status>8170f003</status></response>`
		case "502":
			return http.StatusBadGateway, ""
		case "param":
			return http.StatusOK, `<response><status>8150f001</status></response>`
		}
		return http.StatusOK, petitTestResponse()
	})
	post := func() error {
		_, err := petitPost(qqRoundCtx(), neturl.Values{"key_title": {"x"}})
		return err
	}
	reject["p1.petitlyrics.com"] = "client"
	if err := post(); err != nil || fmt.Sprint(hits) != "[p1.petitlyrics.com:p1110417:10 p0.petitlyrics.com:p1232089:4]" {
		t.Fatalf("编号被作废时换下一组: err=%v hits=%v", err, hits)
	}
	hits = nil
	if err := post(); err != nil || fmt.Sprint(hits) != "[p0.petitlyrics.com:p1232089:4]" {
		t.Errorf("换过去之后一直用它: err=%v hits=%v", err, hits)
	}
	hits = nil
	reject["p0.petitlyrics.com"] = "502"
	if err := post(); err != nil || fmt.Sprint(hits) != "[p0.petitlyrics.com:p1232089:4 on.petitlyrics.com:on354007:0]" {
		t.Errorf("5xx 时换下一组: err=%v hits=%v", err, hits)
	}
	hits = nil
	reject["on.petitlyrics.com"] = "param"
	if err := post(); err == nil || len(hits) != 1 {
		t.Errorf("参数错不换: err=%v hits=%v", err, hits)
	}
	hits = nil
	reject["on.petitlyrics.com"] = "client"
	if err := post(); err == nil || len(hits) != 3 {
		t.Errorf("三组都不行时每组至多一次、报错: err=%v hits=%v", err, hits)
	}
}
