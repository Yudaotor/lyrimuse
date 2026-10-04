package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// withoutMBThrottle:假的 MusicBrainz 应答不用等限速间隔。
func withoutMBThrottle(t *testing.T) {
	t.Helper()
	saved := musicbrainzMinIntervalBetweenCalls
	musicbrainzMinIntervalBetweenCalls = 0
	t.Cleanup(func() { musicbrainzMinIntervalBetweenCalls = saved })
}

// withArtistIdentityCache 换上一份身份缓存(不落盘),测试结束还原。
func withArtistIdentityCache(t *testing.T, m map[string]mbArtistIdentity) {
	t.Helper()
	withoutMBThrottle(t)
	artistIdentityMu.Lock()
	savedCache, savedPath, savedDirty := artistIdentityCache, artistIdentityPath, artistIdentityDirty
	artistIdentityCache, artistIdentityPath = m, ""
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		artistIdentityCache, artistIdentityPath, artistIdentityDirty = savedCache, savedPath, savedDirty
		artistIdentityMu.Unlock()
	})
}

func identityCacheSnapshot() map[string]mbArtistIdentity {
	artistIdentityMu.Lock()
	defer artistIdentityMu.Unlock()
	out := make(map[string]mbArtistIdentity, len(artistIdentityCache))
	for k, v := range artistIdentityCache {
		out[k] = v
	}
	return out
}

func TestRecheckArtistIdentities(t *testing.T) {
	withArtistIdentityCache(t, map[string]mbArtistIdentity{
		"Right Person": {Mbid: "mbid-right", Zh: "旧中文名"},
		"防弹少年团":        {Mbid: "mbid-kamikaze"},
		"FLO":          {Mbid: "mbid-rapper"},
		"Pei-Yu Hung":  {Mbid: "mbid-someone"}, // 手工表里的名字
		"Already":      {Mbid: "mbid-already", Checked: true},
	})
	calls := withFakeMBFetch(t, func(url string) ([]byte, error) {
		switch {
		case strings.Contains(url, "?query="):
			return []byte(`{"artists":[{"id":"mbid-kamikaze","name":"カミカゼ少年團","score":100}]}`), nil
		case strings.Contains(url, "mbid-right"):
			return []byte(`{"name":"Right Person","country":"TW","aliases":[{"name":"对的人","locale":"zh","type":"Artist name"}]}`), nil
		case strings.Contains(url, "mbid-kamikaze"):
			return []byte(`{"name":"カミカゼ少年團","country":"JP","aliases":[{"name":"Kamikaze boys"}]}`), nil
		case strings.Contains(url, "mbid-rapper"):
			return []byte(`{"name":"Flo Rida","country":"US","aliases":[{"name":"Flo-Rida"}]}`), nil
		case strings.Contains(url, "mbid-girlgroup"):
			return []byte(`{"name":"FLO","country":"GB","aliases":[]}`), nil
		}
		return nil, errors.New("unexpected " + url)
	})
	var asked []string
	lastfm := func(_ context.Context, name string) (string, error) {
		asked = append(asked, name)
		if name == "FLO" {
			return "mbid-girlgroup", nil
		}
		return "", nil
	}

	if left := recheckArtistIdentities(context.Background(), 10, lastfm); left != 0 {
		t.Errorf("应全部核完, 还剩 %d", left)
	}
	want := map[string]mbArtistIdentity{
		// 名字对得上:留下,中文名按现行规则重挑
		"Right Person": {Mbid: "mbid-right", Zh: "对的人", Checked: true},
		// 对不上、Last.fm 也没挂:重新搜,首条仍对不上名字,记成「查过、没有」
		"防弹少年团": {Checked: true},
		// 对不上、Last.fm 挂了另一个:改用 Last.fm 的
		"FLO": {Mbid: "mbid-girlgroup", Checked: true},
		// 手工表:中文名用表里的,不认缓存里那个 mbid
		"Pei-Yu Hung": {Zh: "洪佩瑜", Checked: true},
		"Already":     {Mbid: "mbid-already", Checked: true},
	}
	if got := identityCacheSnapshot(); !reflect.DeepEqual(got, want) {
		t.Errorf("核完的缓存:\n got  %+v\n want %+v", got, want)
	}
	for _, u := range *calls {
		if strings.Contains(u, "mbid-already") || strings.Contains(u, "mbid-someone") {
			t.Errorf("已核过的、手工表里的不该去问 MusicBrainz: %s", u)
		}
	}
	if !reflect.DeepEqual(asked, []string{"FLO", "Pei-Yu Hung", "防弹少年团"}) {
		t.Errorf("只有对不上的、手工表里的才问 Last.fm, got %v", asked)
	}

	*calls = nil
	if left := recheckArtistIdentities(context.Background(), 10, lastfm); left != 0 || len(*calls) != 0 {
		t.Errorf("核完之后再跑不该再发请求: left=%d calls=%v", left, *calls)
	}
	// 列出待核之后才被别处核过的条目,轮到它时不再核
	if !recheckArtistIdentity(context.Background(), "Already", lastfm) || len(*calls) != 0 {
		t.Errorf("核过的不该再核: calls=%v", *calls)
	}
}

func TestRecheckArtistIdentitiesUnanswered(t *testing.T) {
	legacy := func() map[string]mbArtistIdentity {
		return map[string]mbArtistIdentity{
			"A": {Mbid: "mbid-a"}, "B": {Mbid: "mbid-b"}, "C": {Mbid: "mbid-c"}, "D": {Mbid: "mbid-d"}, "E": {Mbid: "mbid-e"},
		}
	}
	// down 里的 mbid 回 503;按名字搜一律给一个对不上名字的首条,没问成的条目要是被拿去重新解析就会被改掉。
	fakeMB := func(down map[string]bool) {
		withFakeMBFetch(t, func(url string) ([]byte, error) {
			if strings.Contains(url, "?query=") {
				return []byte(`{"artists":[{"id":"mbid-z","name":"Z","score":100}]}`), nil
			}
			for _, n := range []string{"a", "b", "c", "d", "e", "z"} {
				if strings.Contains(url, "mbid-"+n) {
					if down["mbid-"+n] {
						return nil, &mbStatusError{url: url, status: http.StatusServiceUnavailable}
					}
					return []byte(`{"name":"` + strings.ToUpper(n) + `","aliases":[]}`), nil
				}
			}
			return nil, errors.New("unexpected " + url)
		})
	}

	// limit 是这一轮试核的条数:A 没问成、B 核完;没问成的原样留着
	withArtistIdentityCache(t, legacy())
	fakeMB(map[string]bool{"mbid-a": true})
	if left := recheckArtistIdentities(context.Background(), 2, nil); left != 4 {
		t.Errorf("还该剩 4 条, got %d", left)
	}
	got := identityCacheSnapshot()
	if got["A"] != (mbArtistIdentity{Mbid: "mbid-a"}) || !got["B"].Checked || got["C"].Checked {
		t.Errorf("没问成的原样留着、只核到 limit 条: %+v", got)
	}

	// 没问成的中间夹着核成的,连续失败数从头算
	withArtistIdentityCache(t, legacy())
	fakeMB(map[string]bool{"mbid-a": true, "mbid-c": true, "mbid-d": true})
	if left := recheckArtistIdentities(context.Background(), 10, nil); left != 3 || !identityCacheSnapshot()["E"].Checked {
		t.Errorf("B、E 该核完,只剩 A C D: left=%d %+v", left, identityCacheSnapshot())
	}

	// 连着 artistIdentityRecheckMaxFailures 条没问成就停下这一轮
	withArtistIdentityCache(t, legacy())
	fakeMB(map[string]bool{"mbid-a": true, "mbid-b": true, "mbid-c": true})
	if left := recheckArtistIdentities(context.Background(), 10, nil); left != 5 || identityCacheSnapshot()["D"].Checked {
		t.Errorf("A B C 连着没问成之后不该再核: left=%d %+v", left, identityCacheSnapshot())
	}

	// Last.fm 没问成:这一条不动
	withArtistIdentityCache(t, map[string]mbArtistIdentity{"X": {Mbid: "mbid-x"}})
	withFakeMBFetch(t, func(string) ([]byte, error) { return []byte(`{"name":"Somebody","aliases":[]}`), nil })
	lastfmDown := func(context.Context, string) (string, error) { return "", errors.New("timeout") }
	if left := recheckArtistIdentities(context.Background(), 10, lastfmDown); left != 1 {
		t.Errorf("Last.fm 没问成应留着, got left=%d", left)
	}
	if got := identityCacheSnapshot()["X"]; got != (mbArtistIdentity{Mbid: "mbid-x"}) {
		t.Errorf("Last.fm 没问成时缓存被改了: %+v", got)
	}
}

func TestArtistIdentityRecheckDigestInterval(t *testing.T) {
	withArtistIdentityCache(t, map[string]mbArtistIdentity{"B": {Mbid: "mbid-b"}})
	withFakeMBFetch(t, func(string) ([]byte, error) { return []byte(`{"name":"B","aliases":[]}`), nil })
	p := &poller{}
	env := digestEnv{ctx: context.Background(), cfg: &config{}}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	p.artistIdentityRecheckDigest(now, env)
	if !identityCacheSnapshot()["B"].Checked {
		t.Fatal("第一轮就该核")
	}
	withArtistIdentityCache(t, map[string]mbArtistIdentity{"B": {Mbid: "mbid-b"}})
	p.artistIdentityRecheckDigest(now.Add(artistIdentityRecheckInterval-time.Second), env)
	if identityCacheSnapshot()["B"].Checked {
		t.Error("没到间隔不该再核")
	}
	p.artistIdentityRecheckDigest(now.Add(artistIdentityRecheckInterval), env)
	if !identityCacheSnapshot()["B"].Checked {
		t.Error("到了间隔该接着核")
	}
}

func TestResolveArtistIdentityMBMarksChecked(t *testing.T) {
	withArtistIdentityCache(t, map[string]mbArtistIdentity{})
	withFakeMBFetch(t, func(url string) ([]byte, error) {
		if strings.Contains(url, "?query=") {
			return []byte(`{"artists":[{"id":"mbid-1","name":"Test Artist","score":100}]}`), nil
		}
		return []byte(`{"name":"Test Artist","aliases":[]}`), nil
	})
	resolveArtistIdentityMB("Test Artist", "")
	resolveArtistIdentityMB("Nobody Here", "")
	resolveArtistIdentityMB("Pei-Yu Hung", "")
	resolveArtistIdentityMB("Known", "mbid-known")
	for name, id := range identityCacheSnapshot() {
		if !id.Checked {
			t.Errorf("%s: 现行判据写下的条目要带 Checked: %+v", name, id)
		}
	}
}

func TestLastfmArtistMbid(t *testing.T) {
	useUnthrottledGuard(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	respond := func(status int, body string) {
		lastfmReadClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			q := r.URL.Query()
			if q.Get("method") != "artist.getInfo" || q.Get("autocorrect") != "0" || q.Get("artist") != "FLO" {
				t.Errorf("unexpected request: %s", r.URL.RawQuery)
			}
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
		})}
	}
	cases := []struct {
		status  int
		body    string
		want    string
		wantErr bool
	}{
		{200, `{"artist":{"name":"FLO","mbid":"6ecae756"}}`, "6ecae756", false},
		{200, `{"artist":{"name":"FLO"}}`, "", false},
		{200, `{"error":6,"message":"The artist you supplied could not be found"}`, "", false},
		{200, `{"error":29,"message":"Rate limit exceeded"}`, "", true},
		{500, `{}`, "", true},
	}
	for _, c := range cases {
		respond(c.status, c.body)
		got, err := lastfmArtistMbid(context.Background(), "k", "FLO")
		if got != c.want || (err != nil) != c.wantErr {
			t.Errorf("%d %s: got (%q, %v), want (%q, err=%v)", c.status, c.body, got, err, c.want, c.wantErr)
		}
	}
}

func TestArtistIdentityRecheckIsWired(t *testing.T) {
	src, err := os.ReadFile("digest.go")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(src, []byte("p.artistIdentityRecheckDigest(now, env)")) {
		t.Error("runDigests 里没有接补核")
	}
}
