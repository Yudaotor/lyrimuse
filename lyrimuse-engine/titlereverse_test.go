package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func newTestTitleSpec(samples []string) (*titleReverseSpec, context.Context) {
	ctx, cancel := context.WithCancel(context.Background())
	return &titleReverseSpec{samples: samples, done: make(chan struct{}), cancel: cancel}, ctx
}

func TestTitleReverseSpecTake(t *testing.T) {
	s, _ := newTestTitleSpec([]string{"a", "b"})
	go func() {
		time.Sleep(30 * time.Millisecond)
		s.corrected, s.method, s.artist, s.fetched = "正确曲名", "title-from-album", "歌手", true
		close(s.done)
	}()
	got := s.take([]string{"a", "b"})
	if got == nil || got.corrected != "正确曲名" || !got.fetched {
		t.Fatalf("样本一样:应等它跑完并用它的结果, got %+v", got)
	}

	s2, ctx2 := newTestTitleSpec([]string{"a"})
	if s2.take([]string{"a", "changed"}) != nil {
		t.Fatal("样本变了不该用提前跑的结果")
	}
	select {
	case <-ctx2.Done():
	case <-time.After(time.Second):
		t.Fatal("样本变了应当取消提前跑的那一轮")
	}

	var none *titleReverseSpec
	if none.take(nil) != nil {
		t.Fatal("没提前跑时返回 nil")
	}
	none.stop() // nil 上调用是空操作
}

// 接线守卫:救急时提前跑标题反查;反查那一步样本一致就用它的结果。
func TestTitleReverseSpecIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, n := range []string{
		"defer func() { titleSpec.stop() }()",
		"if rescue {\n\t\t\ttitleSpec = startTitleReverseSpec(ctx, artist, title, album, durationSecs, lyricSamplesForStorefront(results),\n\t\t\t\ttrustedRecordingISRC(artist, title, album, durationSecs, results))",
		"spec := titleSpec.take(samples)",
		"correctedTitle, retryMethod, titleArtist = titleReverseLookup(ctx, artist, title, album, durationSecs, samples,\n\t\t\t\ttrustedRecordingISRC(artist, title, album, durationSecs, results))",
		"if spec != nil && spec.fetched {",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}

func TestBilingualTitleHanPart(t *testing.T) {
	cases := []struct{ artist, title, want string }{
		{"周杰伦", "Children of the Sun 太陽之子", "太陽之子"},
		{"周杰伦", "Gold Rush Town 淘金小鎮", "淘金小鎮"},
		{"曹格", "Supermarket 超级市场", "超级市场"},
		{"卢广仲", "Que te pasa 你在干嘛？", "你在干嘛？"},
		// 中文在前不认
		{"丁世光", "日出 The Dawn", ""},
		{"茄子蛋", "请问你敢欲做我的 Girlfriend?", ""},
		// 拉丁段是版本词 / 以合作署名词结尾
		{"周杰伦", "Remix 稻香", ""},
		{"某歌手", "Love Song feat. 周杰伦", ""},
		{"某歌手", "Love Song x 周杰伦", ""},
		// 汉字段只有一个字 / 就是歌手名
		{"某歌手", "I Love 你", ""},
		{"周杰伦", "Jay 周杰伦", ""},
		// 括号、破折号、数字、多于两段
		{"周杰伦", "Children of the Sun 太陽之子 (Live)", ""},
		{"某歌手", "Hello - 你好", ""},
		{"某歌手", "Room 1203 房间", ""},
		{"某歌手", "One 一二 Two 三四", ""},
		// 只有一种文字
		{"某歌手", "太陽之子", ""},
		{"某歌手", "Children of the Sun", ""},
		{"某歌手", "", ""},
	}
	for _, c := range cases {
		if got := bilingualTitleHanPart(c.artist, c.title); got != c.want {
			t.Errorf("bilingualTitleHanPart(%q, %q) = %q, want %q", c.artist, c.title, got, c.want)
		}
	}
}

// 曲名自带正式写法的两种形状不联网:ctx 已取消,走到联网反查就什么都拿不到。
func TestTitleReverseLookupRewritesWithoutNetwork(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	for _, c := range []struct{ artist, title, want, method string }{
		{"BUMP OF CHICKEN", "BUMP OF CHICKEN『天体観測』", "天体観測", lyricQueryReasonTitleSplit},
		{"周杰伦", "Children of the Sun 太陽之子", "太陽之子", lyricQueryReasonTitleBilingual},
	} {
		got, method, titleArtist := titleReverseLookup(ctx, c.artist, c.title, "", 272, nil, "")
		if got != c.want || method != c.method || titleArtist != c.artist {
			t.Errorf("titleReverseLookup(%q, %q) = %q %q %q, want %q %q %q", c.artist, c.title, got, method, titleArtist, c.want, c.method, c.artist)
		}
	}
}

// 标题反查用的署名:原串和它的别名,合唱 / feat. 署名时再加首歌手和首歌手的别名;去重、保持顺序。
func TestTitleReverseArtists(t *testing.T) {
	saved := titleReverseAliases
	t.Cleanup(func() { titleReverseAliases = saved })
	aliases := map[string][]string{"Khalil Fong": {"方大同"}, "方大同": {"Khalil Fong"}}
	titleReverseAliases = func(_ context.Context, a string) []string { return aliases[a] }
	for in, want := range map[string][]string{
		"Khalil Fong feat. Hanggai": {"Khalil Fong feat. Hanggai", "Khalil Fong", "方大同"},
		"方大同":                       {"方大同", "Khalil Fong"},
		"周杰伦":                       {"周杰伦"},
		"Khalil Fong & Fiona Sit":   {"Khalil Fong & Fiona Sit", "Khalil Fong", "方大同"},
	} {
		got := titleReverseArtists(context.Background(), in)
		if strings.Join(got, "|") != strings.Join(want, "|") {
			t.Errorf("titleReverseArtists(%q) = %v, 要 %v", in, got, want)
		}
	}
}
