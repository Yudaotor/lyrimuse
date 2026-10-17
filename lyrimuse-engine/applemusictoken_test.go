package main

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

// amTestSetDevToken 把内存里的 developer token 换成 tok(模拟别的请求刚换过票)。
func amTestSetDevToken(tok string) {
	applemusicDevTokenMu.Lock()
	applemusicDevToken, applemusicDevTokenExpires = tok, time.Now().Add(30*24*time.Hour)
	applemusicDevTokenMu.Unlock()
}

// 一轮里搜索途中换了票(这里由搜索应答时换上新票模拟):取词用当前那张,拿得到歌词,user token 不记被拒。
func TestApplemusicFetchUsesTokenRenewedDuringRound(t *testing.T) {
	withApplemusicCreds(t, "cn")
	rec := &amTestRecorder{}
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		rec.add(r)
		switch {
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			amTestSetDevToken("new-dev-token")
			return http.StatusOK, nil, amTestSearchBody(amTestSong("1", "I Am", "James Arthur", "Back from the Edge", 200000, true))
		case strings.HasSuffix(r.URL.Path, "/songs/1/syllable-lyrics"):
			if r.Header.Get("Authorization") != "Bearer new-dev-token" {
				return http.StatusUnauthorized, nil, ""
			}
			return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
		}
		return http.StatusNotFound, nil, ""
	})
	r := resolveApplemusicLyric(qqRoundCtx(), "James Arthur", "I Am", "Back from the Edge", 200, "", "")
	if !isTimedLRC(r.lyrics) {
		t.Fatalf("换票之后照样该拿到歌词: %+v", r)
	}
	if st := applemusicReadStatus(); st.RejectedAt != 0 {
		t.Fatal("毛病在 developer token 上,不该记 user token 被拒")
	}
	if n := rec.count("/songs/1/syllable-lyrics"); n != 1 {
		t.Errorf("取词一开始就该用当前的票,问了 %d 次", n)
	}
}

// 带旧票取词被 401:当前已经是新票,换上重发一次,不记被拒。
func TestApplemusicFetchTTMLRetriesWithCurrentDevToken(t *testing.T) {
	withApplemusicCreds(t, "cn")
	amTestSetDevToken("new-dev-token")
	f := withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		if r.Header.Get("Authorization") != "Bearer new-dev-token" {
			return http.StatusUnauthorized, nil, ""
		}
		return http.StatusOK, nil, amTestLyricsBody(amTestLineTTML)
	})
	defer func() {
		if n := len(f.requests()); n != 2 {
			t.Errorf("当前已经是新票:被拒一次、换上重发一次,不用再去核旧票,发了 %d 次", n)
		}
	}()
	ttml, err := applemusicFetchTTML(qqRoundCtx(), "cn", "1", "syllable-lyrics", "test-dev-token", "test-user-token")
	if err != nil || ttml == "" {
		t.Fatalf("换上当前的票应当拿到: %q %v", ttml, err)
	}
	if st := applemusicReadStatus(); st.RejectedAt != 0 {
		t.Fatal("不该记 user token 被拒")
	}
}

// developer token 打得通 catalog、带 user token 的请求仍被拒:是 user token 失效,照记。
func TestApplemusicFetchTTMLMarksUserTokenWhenDevTokenWorks(t *testing.T) {
	withApplemusicCreds(t, "cn")
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		if r.Header.Get("Media-User-Token") != "" {
			return http.StatusUnauthorized, nil, ""
		}
		return http.StatusOK, nil, amTestSearchBody()
	})
	if _, err := applemusicFetchTTML(qqRoundCtx(), "cn", "1", "syllable-lyrics", "test-dev-token", "test-user-token"); err == nil {
		t.Fatal("被拒应当报错")
	}
	if st := applemusicReadStatus(); st.RejectedAt == 0 {
		t.Fatal("developer token 没问题,应当记 user token 被拒")
	}
	if got := applemusicLastFailureReasonNow(); got != lyricFailureReasonAppleMusicTokenRejected {
		t.Errorf("失败原因 = %q", got)
	}
}

// developer token 自己也打不通、又换不到新票:说不清是不是 user token 的事,不记被拒。
func TestApplemusicFetchTTMLDoesNotBlameUserWhenDevTokenBroken(t *testing.T) {
	withApplemusicCreds(t, "cn")
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		if strings.HasPrefix(r.URL.Path, "/v1/") {
			return http.StatusUnauthorized, nil, ""
		}
		return http.StatusNotFound, nil, ""
	})
	applemusicDevTokenFailedAt = time.Time{}
	t.Cleanup(func() { applemusicDevTokenFailedAt = time.Time{} })
	if _, err := applemusicFetchTTML(qqRoundCtx(), "cn", "1", "syllable-lyrics", "test-dev-token", "test-user-token"); err == nil {
		t.Fatal("拿不到应当报错")
	}
	if st := applemusicReadStatus(); st.RejectedAt != 0 {
		t.Fatal("developer token 坏了,不该记 user token 被拒")
	}
}

// 晚回来的 401 只作废它带的那张票:当前已经换成新票时不动。
func TestApplemusicClearDevTokenOnlyClearsRejected(t *testing.T) {
	withApplemusicCreds(t, "cn")
	amTestSetDevToken("new-dev-token")
	applemusicClearDevToken("test-dev-token")
	if got := applemusicCachedDevToken(); got != "new-dev-token" {
		t.Fatalf("新票不该被清掉: %q", got)
	}
	applemusicClearDevToken("new-dev-token")
	if got := applemusicCachedDevToken(); got != "" {
		t.Fatalf("被拒的就是当前那张时应当清掉: %q", got)
	}
}

// 带 user token 正常答了(200 / 404):早先记下的失败原因撤掉。
func TestApplemusicFetchClearsFailureReason(t *testing.T) {
	withApplemusicCreds(t, "cn")
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) { return http.StatusNotFound, nil, "" })
	applemusicSetLastFailureReason(lyricFailureReasonAppleMusicNotConnected)
	if _, err := applemusicFetchTTML(qqRoundCtx(), "cn", "1", "lyrics", "test-dev-token", "test-user-token"); err != nil {
		t.Fatal(err)
	}
	if got := applemusicLastFailureReasonNow(); got != "" {
		t.Fatalf("正常答了应撤掉失败原因,还是 %q", got)
	}
}
