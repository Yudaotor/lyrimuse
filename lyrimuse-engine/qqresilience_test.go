package main

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func resetQQSessionForTest(t *testing.T) {
	t.Helper()
	qqSessionMu.Lock()
	savedVal, savedAt, savedFailed := qqSessionVal, qqSessionAt, qqSessionFailedAt
	qqSessionVal, qqSessionAt, qqSessionFailedAt = qqSessionInfo{}, time.Time{}, time.Time{}
	qqSessionMu.Unlock()
	savedFetch := qqSessionFetch
	t.Cleanup(func() {
		qqSessionFetch = savedFetch
		qqSessionMu.Lock()
		qqSessionVal, qqSessionAt, qqSessionFailedAt = savedVal, savedAt, savedFailed
		qqSessionMu.Unlock()
	})
}

// 会话:失败不钉死,隔一段再试;拿到的缓存住,用满时限就换;调用方 ctx 取消不影响这次请求。
func TestQQEnsureSessionRetriesAndRefreshes(t *testing.T) {
	resetQQSessionForTest(t)
	calls, fail := 0, true
	qqSessionFetch = func(ctx context.Context) ([]byte, error) {
		calls++
		if ctx.Err() != nil {
			t.Error("会话请求不该跟着调用方 ctx 取消")
		}
		if fail {
			return nil, errors.New("offline")
		}
		return []byte(`{"session":{"uid":"1","sid":"sid-` + string(rune('0'+calls)) + `","userip":"1.1.1.1"}}`), nil
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if s := qqEnsureSession(cancelled); s.sid != "" || calls != 1 {
		t.Fatalf("第一次失败: %+v calls=%d", s, calls)
	}
	if qqEnsureSession(context.Background()); calls != 1 {
		t.Fatalf("退避期内不该再问: calls=%d", calls)
	}
	qqSessionMu.Lock()
	qqSessionFailedAt = time.Now().Add(-qqSessionRetryAfter - time.Second)
	qqSessionMu.Unlock()
	fail = false
	s := qqEnsureSession(context.Background())
	if s.sid == "" || calls != 2 {
		t.Fatalf("退避过后应当重新拿到: %+v calls=%d", s, calls)
	}
	if again := qqEnsureSession(context.Background()); again.sid != s.sid || calls != 2 {
		t.Fatalf("拿到的应当缓存: %+v calls=%d", again, calls)
	}
	qqSessionMu.Lock()
	qqSessionAt = time.Now().Add(-qqSessionMaxAge - time.Second)
	qqSessionMu.Unlock()
	if fresh := qqEnsureSession(context.Background()); fresh.sid == s.sid || calls != 3 {
		t.Fatalf("用满时限应当换一个: %+v calls=%d", fresh, calls)
	}
	// 换的时候没拿到:旧的照旧用着。
	fail = true
	qqSessionMu.Lock()
	qqSessionAt = time.Now().Add(-qqSessionMaxAge - time.Second)
	qqSessionMu.Unlock()
	if kept := qqEnsureSession(context.Background()); kept.sid == "" {
		t.Fatal("刷新失败时旧会话照旧用着")
	}
}

func TestQQLyricReplyAnswered(t *testing.T) {
	i := func(v int) *int { return &v }
	cases := []struct {
		code, retcode *int
		want          bool
	}{
		{nil, nil, true},
		{i(0), nil, true},
		{i(-1901), i(-1901), true},
		{i(-1310), nil, false},
		{nil, i(-1), false},
		{i(0), i(-1310), false},
	}
	for _, c := range cases {
		if got := qqLyricReplyAnswered(c.code, c.retcode); got != c.want {
			t.Errorf("code=%v retcode=%v: got %v", c.code, c.retcode, got)
		}
	}
}

// 网页整行接口答了拒绝码:不算「这首没词」,换主机 / 退网关接着问。
func TestQQLineLyricRejectedReplyIsNotAnAnswer(t *testing.T) {
	f := withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/lyric/fcgi-bin/fcg_query_lyric_new.fcg") {
			return http.StatusOK, `{"code":-1310,"msg":"risk"}`
		}
		if target == "u.y.qq.com/musicu:GetPlayLyricInfo" {
			return http.StatusOK, musicuOK(`{"lyric":"` + base64.StdEncoding.EncodeToString([]byte(qqTestLRC)) + `"}`)
		}
		return http.StatusNotFound, ""
	})
	res := resolveQQLyric(qqRoundCtx(), "m1")
	if res.trackFoundNoLyrics || res.lrc != qqTestLRC {
		t.Fatalf("拒绝码不是结论,应当退到网关拿到: %+v", res)
	}
	if f.count("shc.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg") == 0 {
		t.Error("应当换主机再问")
	}
}

// 标题搜索:有一个变体没问成就标 degraded。
func TestQQSearchSongsReportsDegraded(t *testing.T) {
	failing := true
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/soso/fcgi-bin/client_search_cp") || strings.HasPrefix(target, "u.y.qq.com/musicu:") {
			if failing {
				return http.StatusInternalServerError, ""
			}
			return http.StatusOK, `{"code":0,"data":{"song":{"list":[{"mid":"m1","name":"七里香","interval":299,"singer":[{"name":"周杰伦"}],"album":{"name":"七里香"}}]}}}`
		}
		if strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg") {
			return http.StatusOK, `{"code":0,"data":{"song":{"itemlist":[]}}}`
		}
		return http.StatusNotFound, ""
	})
	if _, degraded := qqSearchSongs(qqRoundCtx(), []string{"周杰伦 七里香 (Live)", "周杰伦 七里香"}, "七里香 (Live)"); !degraded {
		t.Error("搜索没问成应当标 degraded")
	}
	failing = false
	if items, degraded := qqSearchSongs(qqRoundCtx(), []string{"周杰伦 七里香"}, "七里香"); degraded || len(items) == 0 {
		t.Errorf("都问成了不该标 degraded: %v %+v", degraded, items)
	}
}

// QRC 有好几轨时只取第一轨的正文。
func TestExtractQRCLyricContentFirstTrackOnly(t *testing.T) {
	xml := `<QrcInfos><LyricInfo LyricCount="2">` + "\n" +
		`<Lyric_1 LyricType="1" LyricContent="[0,1000]a(0,500)say "hi"(500,500)"/>` + "\n" +
		`<Lyric_2 LyricType="3" LyricContent="[0,1000]b(0,1000)"/>` + "\n</LyricInfo></QrcInfos>"
	if got := extractQRCLyricContent(xml); got != `[0,1000]a(0,500)say "hi"(500,500)` {
		t.Fatalf("got %q", got)
	}
	single := `<Lyric_1 LyricType="1" LyricContent="[0,10]x(0,10)"/>` + "\n</LyricInfo>"
	if got := extractQRCLyricContent(single); got != "[0,10]x(0,10)" {
		t.Fatalf("单轨: %q", got)
	}
	if extractQRCLyricContent("<x/>") != "" {
		t.Fatal("没有正文时返回空")
	}
}
