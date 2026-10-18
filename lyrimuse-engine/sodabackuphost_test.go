package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
)

// 汽水搜索:主用主机答了、结果里没有对得上的那条时,允许问备用主机的几条路再问一次 beta-luna;首次解析不问。
func TestSodaSearchAsksBackupHostWhenPrimaryHasNoMatch(t *testing.T) {
	seo, err := json.Marshal(sodaTestResponse(sodaTestLyricContent))
	if err != nil {
		t.Fatal(err)
	}
	const (
		primary = "https://api.qishui.com/luna/search/track"
		backup  = "https://beta-luna.douyin.com/luna/search/track"
	)
	fresh := func(t *testing.T, primaryStatus int) *kgFake {
		savedSearch, savedLyrics := sodaSearchCache, sodaCache
		sodaSearchCache, sodaCache = map[string]sodaSearchCacheEntry{}, map[string]sodaResult{}
		t.Cleanup(func() { sodaSearchCache, sodaCache = savedSearch, savedLyrics })
		return withKugouFake(t, func(target string) (int, string) {
			switch target {
			case primary:
				return primaryStatus, `{"result_groups":[{"id":"tracks","data":[{"entity":{"track":{"id":"71","name":"Sorry Mix","artists":[{"name":"方大同"}],"duration":160000}}}]}]}`
			case backup:
				return http.StatusOK, `{"result_groups":[{"id":"tracks","data":[{"entity":{"track":{"id":"72","name":"Sorry","artists":[{"name":"方大同"}],"album":{"name":"未来"},"duration":222653}}}]}]}`
			case "https://beta-luna.douyin.com/luna/h5/seo_track":
				return http.StatusOK, string(seo)
			}
			return http.StatusNotFound, ""
		})
	}

	f := fresh(t, http.StatusOK)
	if r, _ := sodaLyricBySearch(qqRoundCtx(), "方大同", "Sorry", "未来", 222.6); !r.empty() {
		t.Error("首次解析不问备用主机,主用主机那份对不上就是没有")
	}
	if f.count(backup) != 0 {
		t.Error("首次解析不该问 beta-luna")
	}

	for name, ctx := range map[string]context.Context{
		"后台重试": withLyricSearchBackupHosts(qqRoundCtx()),
		"手动搜索": withManualLyricSearch(qqRoundCtx()),
	} {
		f := fresh(t, http.StatusOK)
		if r, _ := sodaLyricBySearch(ctx, "方大同", "Sorry", "未来", 222.6); r.empty() {
			t.Errorf("%s: 该从 beta-luna 搜到、取到词", name)
		}
		if f.count(primary) != 1 || f.count(backup) != 1 {
			t.Errorf("%s: 两个主机各问一次, 实际 %d / %d", name, f.count(primary), f.count(backup))
		}
	}

	// 主用主机没问成时 tryEach 已经换过 beta-luna,不再多问一次。
	f = fresh(t, http.StatusBadGateway)
	if r, _ := sodaLyricBySearch(withLyricSearchBackupHosts(qqRoundCtx()), "方大同", "Sorry", "未来", 222.6); r.empty() {
		t.Error("主用主机没问成时该从 beta-luna 拿到")
	}
	if f.count(backup) != 1 {
		t.Errorf("beta-luna 只该问一次, 实际 %d", f.count(backup))
	}
}

// 升级重试与规则换版重选(含手动重新匹配)一进来就挂上标记;首次解析那条路不挂。
func TestLyricSearchBackupHostsOnlyOnBackgroundPaths(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	for _, sig := range []string{"func retryLyricsUpgradeWith(", "func rescoreLyricsWith("} {
		i := strings.Index(s, sig)
		if i < 0 {
			t.Fatalf("找不到 %s", sig)
		}
		body := s[i:]
		if j := strings.Index(body, "\n}\n"); j > 0 {
			body = body[:j]
		}
		if !strings.Contains(body[:min(len(body), 600)], "ctx = withLyricSearchBackupHosts(ctx)") {
			t.Errorf("%s 开头该挂 withLyricSearchBackupHosts", sig)
		}
	}
	if n := strings.Count(s, "withLyricSearchBackupHosts("); n != 2 {
		t.Errorf("enrich.go 里只该有这两处挂标记, 实际 %d 处", n)
	}
}
