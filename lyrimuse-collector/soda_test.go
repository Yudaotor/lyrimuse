package main

import (
	"encoding/json"
	"testing"
)

// 真实响应片段(方大同《Sorry》,track_id 6705555863068739585,实抓)。
// 格式是 `[行始ms,行长ms]<字内偏移ms,字长ms,0>字` —— 跟解密后的酷狗 KRC 正文逐字节同构,
// 所以归一化直接复用 krcToLRC / krcToYRC,见 soda.go 头注。
const sodaTestLyricContent = `[19650,6850]<0,370,0>当<680,370,0>我<1640,210,0>回<1850,200,0>头<3840,230,0>发<4070,220,0>现<5520,370,0>是<6480,370,0>我
[27410,6970]<0,370,0>伤<720,370,0>你<2400,330,0>最<2730,320,0>多<3840,370,0>欠<4640,370,0>你<5560,370,0>最<6600,370,0>多
[50050,2400]<0,320,0>I'm <320,290,0>so <610,1790,0>sorry`

func sodaTestResponse(content string) sodaSeoTrackResponse {
	var r sodaSeoTrackResponse
	r.Lyric.Content = content
	r.SeoTrack.Track.ID = "6705555863068739585"
	r.SeoTrack.Track.Name = "Sorry"
	r.SeoTrack.Track.Duration = 222653
	r.SeoTrack.Track.Artists = []struct {
		Name string `json:"name"`
	}{{Name: "方大同"}}
	r.SeoTrack.Track.Album.Name = "未来"
	r.SeoTrack.Track.Album.URLCover.URI = "tos-cn-v-2774c002/abc"
	return r
}

func TestSodaParseSeoTrack(t *testing.T) {
	got, noLyrics, broken := sodaParseSeoTrack(sodaTestResponse(sodaTestLyricContent))
	if noLyrics || broken {
		t.Fatalf("正常样本被判成 noLyrics=%v broken=%v", noLyrics, broken)
	}
	if got.empty() {
		t.Fatal("真实样本解析成空")
	}
	// 逐行:行头毫秒换成 [mm:ss.xx]、字标记全部剥掉。
	wantFirstLRC := "[00:19.65]当我回头发现是我"
	if firstLine(got.lyrics) != wantFirstLRC {
		t.Errorf("逐行首句 = %q, want %q", firstLine(got.lyrics), wantFirstLRC)
	}
	// 逐字:字内**偏移**要换算成绝对时间(行始 19650 + 偏移 680 = 20330),
	// 尖括号换成 YRCParser 的圆括号。算错的话整首歌的逐字填色会从第二个字起就偏。
	wantFirstYRC := "[19650,6850](19650,370,0)当(20330,370,0)我(21290,210,0)回(21500,200,0)头(23490,230,0)发(23720,220,0)现(25170,370,0)是(26130,370,0)我"
	if firstLine(got.yrc) != wantFirstYRC {
		t.Errorf("逐字首句 = %q, want %q", firstLine(got.yrc), wantFirstYRC)
	}
	if got.title != "Sorry" || got.artist != "方大同" || got.album != "未来" {
		t.Errorf("元信息 = %q/%q/%q", got.title, got.artist, got.album)
	}
	// 时长是毫秒,换算成秒才能喂给打分的时长闸;不换算的话 222653 秒会让每条候选都吃满罚分。
	if got.durationSecs != 222.653 {
		t.Errorf("durationSecs = %v, want 222.653", got.durationSecs)
	}
	if got.cover != sodaImageBase+"tos-cn-v-2774c002/abc~"+sodaImageTemplate+"-"+sodaCoverTransform {
		t.Errorf("cover = %q", got.cover)
	}
}

// 歌词实测在**顶层** lyric.content,seo_track.lyric 恒空;两处都读是因为接口两种形态
// 都出现过。这条钉住"顶层优先、空了才回落"的次序。
func TestSodaParseSeoTrackPrefersTopLevelLyric(t *testing.T) {
	r := sodaTestResponse("")
	r.SeoTrack.Lyric.Content = sodaTestLyricContent
	if got, _, _ := sodaParseSeoTrack(r); got.empty() {
		t.Error("顶层为空时应当回落到 seo_track.lyric")
	}
	r2 := sodaTestResponse(sodaTestLyricContent)
	r2.SeoTrack.Lyric.Content = "[0,1000]<0,100,0>兜底不该被用到"
	got, _, _ := sodaParseSeoTrack(r2)
	if firstLine(got.lyrics) != "[00:19.65]当我回头发现是我" {
		t.Errorf("顶层有内容时不该用兜底那份: %q", firstLine(got.lyrics))
	}
}

// 没有计时行的响应必须当成"没有候选"——口径同 krcToLRC 里那条守卫:一份只剩头部标签的
// 壳会被上游当成拿到候选、不再回落别的源。
//
// 这一类要判成 **trackFoundNoLyrics(曲库里有、没给词)**,不是 broken:曲目本身
// 在响应里,端点是好的。判成 broken 会让一首没词的歌把整个源报成失效。
func TestSodaParseSeoTrackRejectsUntimed(t *testing.T) {
	for _, content := range []string{"", "   ", "[ti:只有头没有正文]", "没有任何时间戳的纯文本"} {
		got, noLyrics, broken := sodaParseSeoTrack(sodaTestResponse(content))
		if !got.empty() {
			t.Errorf("content=%q 应判空,却给出了候选", content)
		}
		if !noLyrics || broken {
			t.Errorf("content=%q 应判 trackFoundNoLyrics, got noLyrics=%v broken=%v", content, noLyrics, broken)
		}
	}
}

// 端点改了形状(连曲目 id 都没有)必须跟"这首歌没词"分开 —— 这是 SEO 端点最可能的失效
// 形态:照样回 200、JSON 解得动、字段缺失变零值。混在一起就是静默退化成"汽水一直没歌词"。
func TestSodaParseSeoTrackDetectsBrokenShape(t *testing.T) {
	r := sodaTestResponse(sodaTestLyricContent)
	r.SeoTrack.Track.ID = ""
	got, noLyrics, broken := sodaParseSeoTrack(r)
	if !broken {
		t.Error("响应里没有 track id 时应判 broken")
	}
	if noLyrics {
		t.Error("broken 不该同时报 trackFoundNoLyrics —— 那是两种不同的结局")
	}
	if !got.empty() {
		t.Error("broken 时不该给出候选")
	}
	// 空响应(整个 JSON 都不是这个形状)同理。
	if _, _, broken := sodaParseSeoTrack(sodaSeoTrackResponse{}); !broken {
		t.Error("空响应应判 broken")
	}
}

func TestSodaCoverURL(t *testing.T) {
	if got := sodaCoverURL("", nil, ""); got != "" {
		t.Errorf("空 uri 应给空串, got %q", got)
	}
	// 接口实抓的 url_cover 形态:不带 `~模板-处理参数` 的地址回 400。
	got := sodaCoverURL("tos-cn-v-2774c002/o84FFAQDnBofxEsFEAAq6CEhtB8yfcWggZEUBF",
		[]string{"https://p3-luna.douyinpic.com/img/", "https://p6-luna.douyinpic.com/img/"}, "tplv-b829550vbb")
	want := "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/o84FFAQDnBofxEsFEAAq6CEhtB8yfcWggZEUBF~tplv-b829550vbb-resize:800:800.jpg"
	if got != want {
		t.Errorf("cover = %q, want %q", got, want)
	}
	if got := sodaCoverURL("  tos/x  ", nil, ""); got != sodaImageBase+"tos/x~"+sodaImageTemplate+"-"+sodaCoverTransform {
		t.Errorf("缺 urls / template_prefix 时应用兜底值, got %q", got)
	}
	if got := sodaCoverURL("tos/x", []string{"http://insecure/", "https://p6-luna.douyinpic.com/img"}, "tplv-other"); got != "https://p6-luna.douyinpic.com/img/tos/x~tplv-other-"+sodaCoverTransform {
		t.Errorf("应取第一个 https 前缀并补斜杠, got %q", got)
	}
	for u, want := range map[string]bool{
		"https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc":                                    true,
		"https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/abc~tplv-b829550vbb-resize:800:800.jpg": false,
		"https://p2.music.126.net/x.jpg":                                                             false,
		"":                                                                                           false,
	} {
		if got := sodaCoverNeedsTransform(u); got != want {
			t.Errorf("sodaCoverNeedsTransform(%q) = %v, want %v", u, got, want)
		}
	}
}

// 真实搜索结果(搜「方大同 Sorry」,实抓)。第 2 条是 Live 版、第 5 条是同名的另一位歌手 ——
// 这正是"不能只信汽水自己的排序"的依据,见 soda.go 搜索那一节的头注。
func sodaTestSearchItems() []sodaSearchItem {
	return []sodaSearchItem{
		{ID: "6705555863068739585", Name: "Sorry", Artist: "方大同", Album: "未来", Duration: 222.653},
		{ID: "6705064630726690818", Name: "Sorry [Live 08]", Artist: "方大同", Album: "Khalil Fong [Wonderland Live]", Duration: 228.973},
		{ID: "6705117561870092289", Name: "Love Song", Artist: "方大同", Album: "Love Song", Duration: 269.293},
		{ID: "6732403105419233281", Name: "Sorry", Artist: "Justin Bieber", Album: "Purpose - Deluxe", Duration: 200.787},
	}
}

func TestSodaCandidateScoreGates(t *testing.T) {
	items := sodaTestSearchItems()
	const (
		artist = "方大同"
		title  = "Sorry"
		album  = "未来"
		dur    = 222.653
	)
	// 正版:三道闸全过,时长几乎一致 → 分数最高。
	if got := sodaCandidateScore(items[0], artist, title, album, dur); got <= 100 {
		t.Errorf("正版应当拿到时长加分, got %d", got)
	}
	// 别的歌:标题闸挡掉。
	if got := sodaCandidateScore(items[2], artist, title, album, dur); got != -1 {
		t.Errorf("Love Song 应当被标题闸淘汰, got %d", got)
	}
	// 同名不同歌手:歌手闸挡掉 —— 搜索结果里真的有这一条,不挡就会把 Justin Bieber 的
	// 歌词安到方大同这首上。
	if got := sodaCandidateScore(items[3], artist, title, album, dur); got != -1 {
		t.Errorf("同名不同歌手应当被歌手闸淘汰, got %d", got)
	}
	// 时长差太多:即便名字对得上也淘汰。
	far := items[0]
	far.Duration = dur * 2
	if got := sodaCandidateScore(far, artist, title, album, dur); got != -1 {
		t.Errorf("时长差一倍应当被淘汰, got %d", got)
	}
	// 本地时长未知时不拿时长卡人(别的源同口径)。
	if got := sodaCandidateScore(far, artist, title, album, 0); got != 100 {
		t.Errorf("本地时长未知时应当只看身份闸, got %d", got)
	}
}

// 名次表:正版排第一。Live 版能不能留下取决于版本限定词判据,不在这条守卫的范围内 ——
// 这里只钉"正版必须是第一个被试的"。
func TestSodaRankCandidatesPutsExactVersionFirst(t *testing.T) {
	ids := sodaRankCandidates(sodaTestSearchItems(), "方大同", "Sorry", "未来", 222.653)
	if len(ids) == 0 {
		t.Fatal("正版应当留在名次表里")
	}
	if ids[0] != "6705555863068739585" {
		t.Errorf("名次表第一个应当是正版, got %s", ids[0])
	}
	for _, id := range ids {
		if id == "6732403105419233281" {
			t.Error("同名不同歌手不该出现在名次表里")
		}
	}
}

func TestSodaParseSearchTakesTracksGroupOnly(t *testing.T) {
	// 用 JSON 造响应而不是手写匿名结构体:响应结构加字段时这里不用跟着改。
	// 非 tracks 组(同一个响应里还会回歌手/专辑/歌单)必须整组跳过。
	const raw = `{"result_groups":[
		{"id":"artists","data":[{"entity":{"track":{"id":"should-be-skipped","name":"不该出现"}}}]},
		{"id":"tracks","data":[{"entity":{"track":{"id":"123","name":"Sorry","duration":222653,
			"album":{"name":"未来"},"preview":{"start":120960,"duration":60001}}}}]}]}`
	var body sodaSearchResponse
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatalf("解析失败: %v", err)
	}

	got := sodaParseSearch(body)
	if len(got) != 1 || got[0].ID != "123" {
		t.Fatalf("只该摘 tracks 组, got %+v", got)
	}
	if got[0].Duration != 222.653 {
		t.Errorf("时长该从毫秒换成秒, got %v", got[0].Duration)
	}
	if got[0].PreviewStartMs != 120960 || got[0].PreviewDurationMs != 60001 {
		t.Errorf("试听段要带出来(sodapreview.go 用), got %+v", got[0])
	}
}
