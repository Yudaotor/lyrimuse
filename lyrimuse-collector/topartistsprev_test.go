package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 榜单升降(-with-previous):上一期按同一套合并对齐名次。对不上的后果是整排误标「新」,
// 或者把同一个人的名次差算错。

func TestPreviousMergedRanks(t *testing.T) {
	cur := []lastfmChartEntry{{Name: "Alpha"}, {Name: "beta"}, {Name: "Gamma"}}
	prev := []lastfmChartEntry{{Name: "Beta"}, {Name: "Delta"}, {Name: "alpha"}, {Name: "ALPHA"}}
	got := previousMergedRanks(cur, prev, strings.ToLower)
	if want := []int{3, 1, 0}; got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Errorf("got %v, want %v(按名字键对齐,重复键取靠前的,找不到为 0)", got, want)
	}
	if got := previousMergedRanks(cur, nil, strings.ToLower); got[0] != 0 || len(got) != 3 {
		t.Errorf("上一期为空时全是 0: %v", got)
	}
}

func TestTopArtistsCLIWithPrevious(t *testing.T) {
	useCLIConfigDir(t, map[string]string{"lastfm_user": "someone", "lastfm_api_key": "read-key"})
	savedCacheOnly, savedIdentity, savedAlias, savedQQ := artistCanonicalCacheOnly, artistIdentityPath, artistAliasPath, qqArtistNamePath
	t.Cleanup(func() {
		artistCanonicalCacheOnly, artistIdentityPath, artistAliasPath, qqArtistNamePath = savedCacheOnly, savedIdentity, savedAlias, savedQQ
	})
	useUnthrottledGuard(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	const day = int64(24 * 3600)
	current := `{"topartists":{"artist":[{"name":"周杰伦","playcount":"50"},{"name":"Alpha","playcount":"40"},{"name":"Beta","playcount":"30"}]}}`
	reply := func(status int, body string) (*http.Response, error) {
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	}
	lastfmReadClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		if q.Get("method") == "user.getTopArtists" {
			return reply(200, current)
		}
		from, _ := strconv.ParseInt(q.Get("from"), 10, 64)
		to, _ := strconv.ParseInt(q.Get("to"), 10, 64)
		switch (to - from + day/2) / day {
		case 7: // 上一周:Alpha 第 1、周杰倫(繁体)第 2,Beta 没进榜
			return reply(200, `{"weeklyartistchart":{"artist":[{"name":"Alpha","playcount":"9"},{"name":"周杰倫","playcount":"8"}]}}`)
		case 30: // 上个月一条收听都没有
			return reply(200, `{"weeklyartistchart":{"artist":[]}}`)
		default: // 上一年取数失败
			return reply(500, `{}`)
		}
	})}

	out := captureStdout(t, func() { runTopArtistsCLI([]string{"-all-periods", "-with-previous", "-limit", "3"}) })

	var got map[string]topArtistsPeriodOutput
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("stdout 不是约定的形状: %v %q", err, out)
	}
	week := got["7day"]
	if week.Previous == nil || week.Previous.Listens != 17 || week.Previous.To-week.Previous.From != 7*day {
		t.Fatalf("近 7 天应带上一周窗口与收听数: %+v", week.Previous)
	}
	if now := time.Now().Unix(); week.Previous.To > now-7*day+60 || week.Previous.To < now-7*day-60 {
		t.Errorf("上一期应在本期之前紧挨着: to=%d", week.Previous.To)
	}
	wantRanks := map[string]int{"周杰伦": 2, "Alpha": 1, "Beta": 0}
	for _, row := range week.Rows {
		if row.PrevRank == nil || *row.PrevRank != wantRanks[row.Name] {
			t.Errorf("%s 的上一期名次应是 %d, got %v", row.Name, wantRanks[row.Name], row.PrevRank)
		}
	}
	month := got["1month"]
	if month.Previous == nil || month.Previous.Listens != 0 {
		t.Errorf("上个月没有收听应带 listens=0 的窗口: %+v", month.Previous)
	}
	for _, row := range month.Rows {
		if row.PrevRank != nil {
			t.Errorf("上一期没有收听时不给名次: %s %v", row.Name, *row.PrevRank)
		}
	}
	if got["12month"].Previous != nil || len(got["12month"].Rows) != 3 {
		t.Errorf("上一期取数失败:本期照出、不带上一期: %+v", got["12month"])
	}
	if got["overall"].Previous != nil || got["overall"].Rows[0].PrevRank != nil {
		t.Errorf("全部没有上一期: %+v", got["overall"])
	}
}
