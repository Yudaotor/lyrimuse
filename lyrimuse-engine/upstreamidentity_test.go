package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// 登记表里的值跟代码里实际用的一样:改了常量没改登记表(和 VerifiedAt)这里就红。
func TestUpstreamIdentitiesMatchCode(t *testing.T) {
	src := func(file string) string {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	actual := map[string]string{
		"qq.go qqCommBase":                      fmt.Sprint(qqCommBase["cv"]),
		"qqfallback.go qqSearchComm":            fmt.Sprint(qqSearchComm["cv"]),
		"ytmusic.go ytmusicMobileClientVersion": ytmusicMobileClientVersion,
		"musixmatch.go musixmatchAppID":         musixmatchAppID,
		"migu.go miguJadeiteSignSalt":           miguJadeiteSignSalt[:8],
		"soda.go sodaSearchAID":                 sodaSearchAID,
		"kugousongpage.go kugouSearchSignSalt":  kugouSearchSignSalt[:8],
		"qqfallback.go qqLyricDownloadAt":       "",
		"qq.go qqSmartboxAt":                    "",
	}
	if strings.Contains(src("qqfallback.go"), `"version": {"15"}, "miniversion": {"82"}`) {
		actual["qqfallback.go qqLyricDownloadAt"] = "15/82"
	}
	if strings.Contains(src("qq.go"), "smartbox_new.fcg?_=1&cv=4747474&") {
		actual["qq.go qqSmartboxAt"] = "4747474"
	}
	if len(actual) != len(upstreamIdentities) {
		t.Fatalf("登记了 %d 项,这里核对 %d 项:新登记的也要在这里核对", len(upstreamIdentities), len(actual))
	}
	for _, u := range upstreamIdentities {
		got, ok := actual[u.Where]
		if !ok {
			t.Errorf("%s:没有核对它的那一行", u.Where)
			continue
		}
		if got != u.Value {
			t.Errorf("%s:代码里是 %q,登记的是 %q —— 改了值就把登记表和 VerifiedAt 一起更新", u.Where, got, u.Value)
		}
		if _, err := time.Parse("2006-01-02", u.VerifiedAt); err != nil {
			t.Errorf("%s:VerifiedAt %q 不是日期", u.Where, u.VerifiedAt)
		}
	}
}

// 超过 180 天没核对的列出来,没超的不列。
func TestStaleUpstreamIdentities(t *testing.T) {
	saved := upstreamIdentities
	t.Cleanup(func() { upstreamIdentities = saved })
	upstreamIdentities = []upstreamIdentity{{Name: "旧", Where: "a.go x", VerifiedAt: "2026-01-01"}, {Name: "新", Where: "b.go y", VerifiedAt: "2026-10-01"}}
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.Local)
	if got := staleUpstreamIdentities(now); len(got) != 1 || !strings.HasPrefix(got[0], "旧(2026-01-01") {
		t.Errorf("只列旧的那项: %v", got)
	}
	if stale, text := upstreamIdentitySummary(now); !stale || !strings.Contains(text, "1 项超过 180 天") {
		t.Errorf("摘要: %v %q", stale, text)
	}
}
