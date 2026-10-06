package main

import (
	"os"
	"strings"
	"testing"
)

// QQ 按歌名搜「等你下课」回来的前几条,顺序原样:原唱歌名带合作者署名,同样长的翻唱歌名一字不差。
func waitingForYouItems() []qqSearchItem {
	return []qqSearchItem{
		{Mid: "a", Singer: "周杰伦", Name: "等你下课 (with 杨瑞代)", Album: "等你下课", Interval: 270},
		{Mid: "b", Singer: "周杰伦", Name: "等你下课 (2021第十五届音乐盛典咪咕汇现场)", Interval: 263},
		{Mid: "c", Singer: "苏菲", Name: "等你下课", Album: "小苏菲", Interval: 269},
		{Mid: "d", Singer: "林凡", Name: "等你下课", Album: "林凡", Interval: 270},
	}
}

func peninsulaItems() []qqSearchItem {
	return []qqSearchItem{
		{Mid: "a", Singer: "周杰伦", Name: "半岛铁盒", Album: "八度空间", Interval: 319},
		{Mid: "b", Singer: "周杰伦", Name: "半岛铁盒 (Live)", Album: "The One演唱会", Interval: 363},
		{Mid: "c", Singer: "周杰伦", Name: "晴天", Album: "叶惠美", Interval: 269},
		{Mid: "d", Singer: "刘瑞琦", Name: "半岛铁盒", Album: "再次寻找周杰伦", Interval: 319},
	}
}

func TestPickInferredIdentity(t *testing.T) {
	if id, ok := pickInferredIdentity(waitingForYouItems(), "等你下课", 270.0); !ok || id.artist != "周杰伦" || id.album != "等你下课" {
		t.Errorf("排第一的原唱歌名带合作者署名也认它,不认后面歌名一字不差的翻唱,得到 %+v %v", id, ok)
	}
	if id, ok := pickInferredIdentity(peninsulaItems(), "半岛铁盒", 319.4); !ok || id.artist != "周杰伦" || id.album != "八度空间" {
		t.Errorf("排第一、时长差 0.4 秒:认出歌手和专辑,得到 %+v %v", id, ok)
	}
	live := peninsulaItems()
	live[0], live[1] = live[1], live[0]
	if id, ok := pickInferredIdentity(live, "半岛铁盒", 319.4); !ok || id.album != "八度空间" {
		t.Errorf("排在前面的 Live 版被版本闸挡掉,认下一条,得到 %+v %v", id, ok)
	}
	hot := peninsulaItems()
	hot[0], hot[2] = hot[2], hot[0]
	if id, ok := pickInferredIdentity(hot, "半岛铁盒", 319.4); !ok || id.artist != "周杰伦" || id.album != "八度空间" {
		t.Errorf("排在前面的别的歌被歌名闸挡掉,认下一条,得到 %+v %v", id, ok)
	}
	if _, ok := pickInferredIdentity(peninsulaItems(), "半岛铁盒", 321.0); !ok {
		t.Error("时长正好差 2 秒也算")
	}
	covered := append(peninsulaItems(), qqSearchItem{Mid: "e", Singer: "某翻唱", Name: "半岛铁盒", Interval: 300})
	for name, c := range map[string]struct {
		items []qqSearchItem
		dur   float64
	}{
		"排第一的时长差 2.1 秒":    {peninsulaItems(), 321.1},
		"排第一的对不上,后面的翻唱对得上": {covered, 300},
		"排第一的没报曲长":         {[]qqSearchItem{{Mid: "a", Singer: "周杰伦", Name: "半岛铁盒"}}, 319.4},
		"排第一的没报歌手":         {[]qqSearchItem{{Mid: "a", Singer: " ", Name: "半岛铁盒", Interval: 319}}, 319.4},
		"播放器没报时长":          {peninsulaItems(), 0},
		"没有搜到":             {nil, 319.4},
	} {
		if id, ok := pickInferredIdentity(c.items, "半岛铁盒", c.dur); ok {
			t.Errorf("%s:不该认出,得到 %+v", name, id)
		}
	}
}

func TestInferredIdentityWorthBackfill(t *testing.T) {
	if !inferredIdentityWorthBackfill(enrichEntry{}, "", "半岛铁盒", 319.4) {
		t.Error("歌手为空、有歌名和时长、还没认出来:值得补一次外围")
	}
	for name, c := range map[string]struct {
		e      enrichEntry
		artist string
		title  string
		dur    float64
	}{
		"播放器报了歌手": {enrichEntry{}, "周杰伦", "半岛铁盒", 319.4},
		"已经认出来了":  {enrichEntry{InferredArtist: "周杰伦"}, "", "半岛铁盒", 319.4},
		"没有歌名":    {enrichEntry{}, "", " ", 319.4},
		"不知道时长":   {enrichEntry{}, "", "半岛铁盒", 0},
	} {
		if inferredIdentityWorthBackfill(c.e, c.artist, c.title, c.dur) {
			t.Errorf("%s:不该为认身份补外围", name)
		}
	}
}

// 接线:播放器没报歌手时,按 QQ 的歌名搜索认身份;找封面、拼 QQ / Spotify 链接、查动态封面都改用认出来的那位(Apple
// 链接走封面那一步的匹配);外围补全把结果并回条目;播放时没认出来的补一次;认出来的身份不进 fields()(打卡载荷)。
func TestInferredIdentityWiring(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{
		"if id, ok := inferIdentityByTitle(ctx, title, durationSecs); ok {",
		"coverArtist, coverTitle, coverDuration := lookupArtist, title, durationSecs",
		"siblingAlbumCover(lookupArtist, title, coverAlbum)",
		"qqMusicURL(ctx, lookupArtist, title, album, durationSecs)",
		`neturl.QueryEscape(lookupArtist+" "+title)`,
		"e.fillMotionCover(ctx, lookupArtist, title, album)",
		"e.InferredArtist, e.InferredAlbum = fresh.InferredArtist, fresh.InferredAlbum",
		"(inferredIdentityWorthBackfill(e, artist, title, durationSecs) && peripheralBackfillWindowOpen(e))",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("enrich.go 里缺这一句接线:%s", want)
		}
	}
	start := strings.Index(src, "func (e enrichEntry) fields() map[string]string {")
	if start < 0 {
		t.Fatal("找不到 fields()")
	}
	end := start + strings.Index(src[start:], "\n}\n")
	if strings.Contains(src[start:end], "Inferred") {
		t.Error("认出来的歌手 / 专辑不该进 fields():那是中继和 ListenBrainz 的载荷,打卡照旧按播放器报的")
	}
}
