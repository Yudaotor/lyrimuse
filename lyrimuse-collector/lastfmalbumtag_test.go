package main

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// Apple 给单曲 / EP 的专辑名带「 - Single」「 - EP」后缀,Last.fm 把带不带后缀的当成两张专辑。
// 曲名按 Last.fm 编目写法发时(智能档、自定义档开了曲名匹配)剥掉它;曲名原样发时专辑名也原样。
func TestTrimSingleOrEPSuffix(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Emi The Dream Catcher #1 - Single", "Emi The Dream Catcher #1"},
		{"太热爱 - EP", "太热爱"},
		{"It's Ū - single", "It's Ū"},
		{"Happy End - ep", "Happy End"},
		{"  玻璃 - Single  ", "玻璃"},
		// 只认结尾那两个固定后缀,别的连字符后缀一律不碰。
		{"Rock With You - Single Version", "Rock With You - Single Version"},
		{"Changes - Live", "Changes - Live"},
		{"Singles", "Singles"},
		{"The EP Collection", "The EP Collection"},
		// 去掉后什么都不剩就原样返回,不能发一个空专辑名。
		{" - Single", " - Single"},
		{"", ""},
	}
	for _, c := range cases {
		if got := trimSingleOrEPSuffix(c.in); got != c.want {
			t.Errorf("trimSingleOrEPSuffix(%q) = %q, want %q", c.in, got, c.want)
		}
		// 判后缀和剥后缀是同一套规则:剥得动的,albumHintIsSingleOrEP 必须认。
		if trimmed := trimSingleOrEPSuffix(c.in); trimmed != c.in && !albumHintIsSingleOrEP(c.in) {
			t.Errorf("%q 被剥了后缀,但 albumHintIsSingleOrEP 不认它 —— 两处后缀表对不上", c.in)
		}
	}
}

func TestLastfmAlbumTagFollowsTrackMatching(t *testing.T) {
	const album = "清楚点 - Single"
	cases := []struct {
		name                     string
		mode                     string
		artist, track, firstOnly bool
		want                     string
	}{
		{"智能档", lastfmMatchSmart, true, true, false, "清楚点"},
		{"自定义:曲名匹配开", lastfmMatchCustom, false, true, false, "清楚点"},
		{"自定义:只开歌手匹配 + 截断,曲名原样", lastfmMatchCustom, true, false, true, album},
		{"原始档", lastfmMatchRaw, false, false, false, album},
	}
	for _, c := range cases {
		setMatch(t, c.mode, c.artist, c.track, c.firstOnly)
		if got := lastfmAlbumTag(album); got != c.want {
			t.Errorf("%s: lastfmAlbumTag = %q, want %q", c.name, got, c.want)
		}
	}
}

// 三个出口(正在播放、当场 scrobble、回填)真的发出去的 album 参数都经过同一个函数。
func TestLastfmAlbumTagAppliedOnAllThreeWritePaths(t *testing.T) {
	var mu sync.Mutex
	var forms []url.Values
	s := newLastfmScrobbler("key", "secret", "sk")
	s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		mu.Lock()
		forms = append(forms, form)
		mu.Unlock()
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: http.Header{}}, nil
	})}
	ctx := context.Background()

	check := func(label, field, want string) {
		t.Helper()
		mu.Lock()
		defer mu.Unlock()
		if len(forms) == 0 {
			t.Fatalf("%s: 没有发出请求", label)
		}
		if got := forms[len(forms)-1].Get(field); got != want {
			t.Errorf("%s: %s = %q, want %q", label, field, got, want)
		}
	}

	setMatch(t, lastfmMatchSmart, true, true, false)
	_ = s.updateNowPlaying(ctx, "方大同", "Emi The Dream Catcher #1", "Emi The Dream Catcher #1 - Single", 200)
	check("智能档 正在播放", "album", "Emi The Dream Catcher #1")
	_ = s.scrobble(ctx, "方大同", "Emi The Dream Catcher #1", "Emi The Dream Catcher #1 - Single", 1790000000, 200)
	check("智能档 当场 scrobble", "album", "Emi The Dream Catcher #1")
	_, _ = s.scrobbleBatch(ctx, []listenLogLine{{T: "l", AR: "王以太", TI: "太热爱", AL: "太热爱 - EP", UTS: 1790000000, DUR: 200}})
	check("智能档 回填", "album[0]", "太热爱")

	setMatch(t, lastfmMatchRaw, false, false, false)
	_ = s.scrobble(ctx, "方大同", "Emi The Dream Catcher #1", "Emi The Dream Catcher #1 - Single", 1790000000, 200)
	check("原始档 当场 scrobble", "album", "Emi The Dream Catcher #1 - Single")
	_, _ = s.scrobbleBatch(ctx, []listenLogLine{{T: "l", AR: "王以太", TI: "太热爱", AL: "太热爱 - EP", UTS: 1790000000, DUR: 200}})
	check("原始档 回填", "album[0]", "太热爱 - EP")
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
