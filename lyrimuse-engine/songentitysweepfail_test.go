package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

// 存量 ISRC 补扫:一批没问成等 backoff 再问同一批;同一个商店连续 tries 次没问成就不再问它,剩下的留给下一次,别的商店照问。
func TestRunISRCSweepJobsRetriesThenGivesUpPerStorefront(t *testing.T) {
	var jobs []isrcSweepJob
	for i := 0; i < isrcSweepBatch+1; i++ {
		jobs = append(jobs, isrcSweepJob{key: fmt.Sprintf("A|Song %03d|B", i), appleID: fmt.Sprint(1000 + i), storefront: "jp", durationSecs: 200, askApple: true})
	}
	jobs = append(jobs, isrcSweepJob{key: "A|Korea|B", appleID: "9", storefront: "kr", durationSecs: 200, askApple: true})
	var calls []string
	deps := isrcSweepDeps{
		apple: func(_ context.Context, sf string, ids []string) (map[string]appleCatalogSong, bool) {
			calls = append(calls, fmt.Sprintf("%s:%d", sf, len(ids)))
			switch {
			case sf == "jp" && len(calls) == 1:
				return nil, false // 第一批第一次没问成,再问一次就成
			case sf == "jp" && len(ids) == 1:
				return nil, false // 第二批一直没问成
			}
			return map[string]appleCatalogSong{}, true
		},
		tries: 3,
	}
	out, requests := runISRCSweepJobs(context.Background(), jobs, deps)
	want := []string{"jp:100", "jp:100", "jp:1", "jp:1", "jp:1", "kr:1"}
	if requests != len(want) || !reflect.DeepEqual(calls, want) {
		t.Fatalf("没问成的那批重问,连续 3 次就不再问这个商店: requests=%d calls=%v", requests, calls)
	}
	if !out[jobs[0].key].settled || out[jobs[isrcSweepBatch].key].settled || !out["A|Korea|B"].settled {
		t.Errorf("问成的记下,没问成的留给下一次,别的商店照问: first=%v last=%v kr=%v",
			out[jobs[0].key].settled, out[jobs[isrcSweepBatch].key].settled, out["A|Korea|B"].settled)
	}
}

// 正在放的那首当场补号只问一次 Apple,没问成隔 isrcPlaybackRetry 再试,不在后台连着重问。
func TestPlaybackISRCJobAsksAppleOnce(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{"A|Song|B": {AppleURL: "https://music.apple.com/cn/album/x/1?i=2", DurationSecs: 200}})
	saved := isrcSweepLiveDeps
	t.Cleanup(func() { isrcSweepLiveDeps = saved })
	calls := 0
	isrcSweepLiveDeps.apple = func(context.Context, string, []string) (map[string]appleCatalogSong, bool) {
		calls++
		return nil, false
	}
	isrcSweepLiveDeps.backoff = 0
	runPlaybackISRCJob(isrcSweepJob{key: "A|Song|B", appleID: "2", storefront: "cn", durationSecs: 200, askApple: true, applePlayer: true})
	if calls != 1 {
		t.Errorf("正在放的那首只问一次: %d", calls)
	}
	if isrcSweepLiveDeps.tries != catalogSweepMaxFailures {
		t.Errorf("启动后那一轮补扫照旧问 %d 次: %d", catalogSweepMaxFailures, isrcSweepLiveDeps.tries)
	}
}

// MusicBrainz 按 ISRC 问录音:404、400 是它明确说没有,算问成(不然连续几次就停、下一轮又从这个号问起);503、网络错误算没问成。
func TestLookupMBRecordingDefinitiveMiss(t *testing.T) {
	useTempSharedCooldown(t)
	savedInterval := musicbrainzMinIntervalBetweenCalls
	musicbrainzMinIntervalBetweenCalls = time.Millisecond
	t.Cleanup(func() { musicbrainzMinIntervalBetweenCalls = savedInterval })
	var reply func(url string) ([]byte, error)
	calls := withFakeMBFetch(t, func(url string) ([]byte, error) { return reply(url) })
	for _, c := range []struct {
		name   string
		reply  func(url string) ([]byte, error)
		ok     bool
		record mbISRCRecord
	}{
		{"404", func(url string) ([]byte, error) { return nil, &mbStatusError{url: url, status: http.StatusNotFound} }, true, mbISRCRecord{}},
		{"400", func(url string) ([]byte, error) { return nil, &mbStatusError{url: url, status: http.StatusBadRequest} }, true, mbISRCRecord{}},
		{"503", func(url string) ([]byte, error) {
			return nil, &mbStatusError{url: url, status: http.StatusServiceUnavailable}
		}, false, mbISRCRecord{}},
		{"网络", func(string) ([]byte, error) { return nil, errors.New("dial tcp: timeout") }, false, mbISRCRecord{}},
		{"一条录音", func(string) ([]byte, error) { return []byte(`{"recordings":[{"id":"rec-1"}]}`), nil }, true, mbISRCRecord{Recordings: 1, Recording: "rec-1"}},
	} {
		reply = c.reply
		rec, ok := lookupMBRecording(context.Background(), "USAAA1100001")
		if ok != c.ok || rec != c.record {
			t.Errorf("%s: ok=%v rec=%+v, want ok=%v rec=%+v", c.name, ok, rec, c.ok, c.record)
		}
	}
	if n := len(*calls); n != 5 || !strings.Contains((*calls)[0], "/isrc/USAAA1100001") {
		t.Errorf("每次都真去问: %v", *calls)
	}
}
