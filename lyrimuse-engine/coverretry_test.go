package main

import (
	"context"
	"testing"
)

// fakeCoverRetry:假的补查调用,记下每次问了什么;have 里登记的「源|歌手|曲名」才给封面。
type fakeCoverRetry struct {
	calls []string
	have  map[string]string
	isrc  map[string]deezerTrack
}

func (f *fakeCoverRetry) lookups() coverRetryLookups {
	return coverRetryLookups{
		netease: func(_ context.Context, artist, title, _ string, _ float64) neteaseInfo {
			f.calls = append(f.calls, "netease|"+artist+"|"+title)
			return neteaseInfo{Cover: f.have["netease|"+artist+"|"+title], Album: "网易云专辑"}
		},
		apple: func(_ context.Context, artist, title, _ string, duration float64) appleMusicMatch {
			f.calls = append(f.calls, "apple|"+artist+"|"+title)
			if duration != 0 && title == "淘金小鎮" {
				f.calls = append(f.calls, "拆出来的曲名带了时长")
			}
			return appleMusicMatch{cover: f.have["apple|"+artist+"|"+title], album: "Apple 专辑"}
		},
		qq: func(_ context.Context, artist, title, _ string) (string, string) {
			f.calls = append(f.calls, "qq|"+artist+"|"+title)
			return f.have["qq|"+artist+"|"+title], ""
		},
		deezer: func(_ context.Context, isrc string) (deezerTrack, bool) {
			f.calls = append(f.calls, "deezer|"+isrc)
			t, ok := f.isrc[isrc]
			return t, ok
		},
	}
}

func dzTrack(artist, title, album, cover string) deezerTrack {
	var t deezerTrack
	t.Artist.Name, t.Title, t.Album.Title, t.Album.CoverXL = artist, title, album, cover
	return t
}

func TestRetryMissingCoverSplitsBilingualTitle(t *testing.T) {
	f := &fakeCoverRetry{have: map[string]string{"qq|周杰伦|淘金小鎮": "https://y.qq.com/cover.jpg"}}
	r, ok := retryMissingCover(context.Background(), f.lookups(), "周杰伦", "Gold Rush Town 淘金小鎮", "", 266, nil, nil)
	if !ok || r != (coverRetryResult{"https://y.qq.com/cover.jpg", "qq", ""}) {
		t.Fatalf("got %+v ok=%v, calls %v", r, ok, f.calls)
	}
	want := []string{"netease|周杰伦|淘金小鎮", "apple|周杰伦|淘金小鎮", "qq|周杰伦|淘金小鎮"}
	if len(f.calls) != len(want) {
		t.Fatalf("calls %v, want %v", f.calls, want)
	}
	for i := range want {
		if f.calls[i] != want[i] {
			t.Fatalf("calls %v, want %v", f.calls, want)
		}
	}
}

func TestRetryMissingCoverTriesArtistNamesFromTheDecision(t *testing.T) {
	d := &lyricsDecision{Candidates: []lyricsDecisionCandidate{
		{Source: "kugou", Score: 1186, Artist: "蒋雪儿Snow.J"},
		{Source: "netease", Score: 1168, Artist: "蒋雪儿Snow.J"},
		{Source: "lrclib", Score: -1, Artist: "别人"},
		{Source: "qq", Score: 900, Artist: "蒋雪儿"},
	}}
	names := coverRetryArtistNames(d, "蒋雪儿")
	if len(names) != 1 || names[0] != "蒋雪儿Snow.J" {
		t.Fatalf("names = %v", names)
	}
	f := &fakeCoverRetry{have: map[string]string{"netease|蒋雪儿Snow.J|半生雪": "https://p1.music.126.net/x.jpg"}}
	r, ok := retryMissingCover(context.Background(), f.lookups(), "蒋雪儿", "半生雪", "半生雪", 189, names, nil)
	if !ok || r != (coverRetryResult{"https://p1.music.126.net/x.jpg", "netease", "网易云专辑"}) {
		t.Fatalf("got %+v ok=%v, calls %v", r, ok, f.calls)
	}
	if f.calls[0] != "netease|蒋雪儿Snow.J|半生雪" {
		t.Fatalf("原样那一组不该再查: %v", f.calls)
	}
}

func TestCoverRetryArtistNamesCap(t *testing.T) {
	d := &lyricsDecision{Candidates: []lyricsDecisionCandidate{
		{Score: 3, Artist: "A"}, {Score: 2, Artist: "B"}, {Score: 1, Artist: "C"},
	}}
	if names := coverRetryArtistNames(d, "X"); len(names) != coverRetryMaxArtistNames {
		t.Fatalf("names = %v", names)
	}
	if coverRetryArtistNames(nil, "X") != nil {
		t.Fatal("没有判决时应为空")
	}
}

func TestRetryMissingCoverQueryCap(t *testing.T) {
	f := &fakeCoverRetry{}
	retryMissingCover(context.Background(), f.lookups(), "周杰伦", "Gold Rush Town 淘金小鎮", "", 266,
		[]string{"Jay Chou", "周杰倫"}, nil)
	if len(f.calls) != coverRetryMaxQueries*3 {
		t.Fatalf("问了 %d 次,上限 %d 组 × 3 源: %v", len(f.calls), coverRetryMaxQueries, f.calls)
	}
	for _, c := range f.calls {
		if c == "拆出来的曲名带了时长" {
			t.Fatal("拆出来的曲名应按未知时长查")
		}
	}
}

func TestRetryMissingCoverFallsBackToDeezerByISRC(t *testing.T) {
	f := &fakeCoverRetry{isrc: map[string]deezerTrack{
		"WRONG":        dzTrack("别人", "别的歌", "别的专辑", "https://cdn-images.dzcdn.net/images/cover/aa/1000x1000-000000-80-0-0.jpg"),
		"FRX282221199": dzTrack("蒋雪儿", "半生雪", "半生雪", "https://cdn-images.dzcdn.net/images/cover/bb/1000x1000-000000-80-0-0.jpg"),
	}}
	r, ok := retryMissingCover(context.Background(), f.lookups(), "蒋雪儿", "半生雪", "半生雪", 189, nil,
		[]string{"WRONG", "FRX282221199"})
	want := coverRetryResult{"https://cdn-images.dzcdn.net/images/cover/bb/1800x1800-000000-80-0-0.jpg", "deezer", "半生雪"}
	if !ok || r != want {
		t.Fatalf("got %+v ok=%v, calls %v", r, ok, f.calls)
	}
}

func TestRetryMissingCoverDeezerNeedsArtistOrTitle(t *testing.T) {
	f := &fakeCoverRetry{isrc: map[string]deezerTrack{
		"X": dzTrack("别人", "别的歌", "别的专辑", "https://cdn-images.dzcdn.net/images/cover/aa/1000x1000-000000-80-0-0.jpg"),
		"Y": dzTrack("Jay Chou", "Gold Rush Town", "Children of the Sun", "https://cdn-images.dzcdn.net/images/cover/cc/1000x1000-000000-80-0-0.jpg"),
	}}
	if _, ok := retryMissingCover(context.Background(), f.lookups(), "蒋雪儿", "半生雪", "", 0, nil, []string{"X"}); ok {
		t.Fatal("歌手、曲名都对不上的录音不该用")
	}
	r, ok := retryMissingCover(context.Background(), f.lookups(), "周杰伦", "Gold Rush Town 淘金小鎮", "", 0, nil, []string{"Y"})
	if !ok || r.source != "deezer" || r.album != "Children of the Sun" {
		t.Fatalf("曲名对得上应该用: %+v ok=%v", r, ok)
	}
}

func TestRetryMissingCoverNothingToTry(t *testing.T) {
	f := &fakeCoverRetry{}
	if _, ok := retryMissingCover(context.Background(), f.lookups(), "周杰伦", "晴天", "叶惠美", 269, nil, nil); ok || len(f.calls) != 0 {
		t.Fatalf("没有别的写法、没有 ISRC 时不该发请求: %v", f.calls)
	}
}
