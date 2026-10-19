package main

import (
	"context"
	"testing"
)

const (
	mxDead800  = "https://s.mxmcdn.net/images-storage/albums5/5/8/3/7/4/0/42047385_800_800.jpg"
	mxDead500  = "https://s.mxmcdn.net/images-storage/albums5/5/8/3/7/4/0/42047385_500_500.jpg"
	mxAlive800 = "https://s.mxmcdn.net/images-storage/albums2/5/0/2/9/1/0/42019205_800_800.jpg"
)

// stubMusixmatchCoverExists 换掉 HEAD 那一步,按 answers 答(不在里面的算网络出错),返回问过的地址。
func stubMusixmatchCoverExists(t *testing.T, answers map[string]bool) *[]string {
	t.Helper()
	asked := &[]string{}
	prev := musixmatchCoverExists
	musixmatchCoverExists = func(_ context.Context, u string) (bool, bool) {
		*asked = append(*asked, u)
		exists, ok := answers[u]
		return exists, ok
	}
	musixmatchCoverCheckMu.Lock()
	prevMemo := musixmatchCoverCheckMemo
	musixmatchCoverCheckMemo = map[string]bool{}
	musixmatchCoverCheckMu.Unlock()
	t.Cleanup(func() {
		musixmatchCoverExists = prev
		musixmatchCoverCheckMu.Lock()
		musixmatchCoverCheckMemo = prevMemo
		musixmatchCoverCheckMu.Unlock()
	})
	return asked
}

func TestMusixmatchCover500For(t *testing.T) {
	if got := musixmatchCover500For(mxDead800); got != mxDead500 {
		t.Errorf("800 档换成同一路径的 500 档: %q", got)
	}
	for _, u := range []string{mxDead500, "https://p1.music.126.net/a_800_800.jpg", ""} {
		if got := musixmatchCover500For(u); got != "" {
			t.Errorf("%q 不是 Musixmatch 的 800 档,应为空: %q", u, got)
		}
	}
}

func TestMusixmatchCheckedCover(t *testing.T) {
	asked := stubMusixmatchCoverExists(t, map[string]bool{mxDead800: false, mxAlive800: true})
	ctx := context.Background()
	if got := musixmatchCheckedCover(ctx, mxDead800); got != mxDead500 {
		t.Errorf("800 档取不到,用 500 档: %q", got)
	}
	if got := musixmatchCheckedCover(ctx, mxAlive800); got != mxAlive800 {
		t.Errorf("800 档取得到,照用: %q", got)
	}
	musixmatchCheckedCover(ctx, mxDead800)
	if len(*asked) != 2 {
		t.Errorf("同一个地址只问一次,实问 %v", *asked)
	}
	if got := musixmatchCheckedCover(ctx, mxDead500); got != mxDead500 || len(*asked) != 2 {
		t.Errorf("不是 800 档的不问: %q %v", got, *asked)
	}
	const unknown = "https://s.mxmcdn.net/images-storage/albums2/1/41606678_800_800.jpg"
	if got := musixmatchCheckedCover(ctx, unknown); got != unknown {
		t.Errorf("网络出错照旧用 800 档: %q", got)
	}
	musixmatchCheckedCover(ctx, unknown)
	if len(*asked) != 4 {
		t.Errorf("网络出错不记结论,下次再问: %v", *asked)
	}
}

func TestMusixmatchResultCover(t *testing.T) {
	asked := stubMusixmatchCoverExists(t, map[string]bool{mxDead800: false})
	ctx := context.Background()
	if got := musixmatchResultCover(ctx, musixmatchResult{cover: mxDead800}); got != mxDead800 || len(*asked) != 0 {
		t.Errorf("没拿到词的不核: %q %v", got, *asked)
	}
	if got := musixmatchResultCover(ctx, musixmatchResult{lrc: "[00:01.00]a", cover: mxDead800}); got != mxDead500 {
		t.Errorf("拿到词的核,取不到换 500 档: %q", got)
	}
	if got := musixmatchResultCover(ctx, musixmatchResult{instrumental: true, cover: mxDead800}); got != mxDead500 {
		t.Errorf("纯音乐断言同样核: %q", got)
	}
}

func TestRepairMusixmatchCovers(t *testing.T) {
	withTempMigrationState(t)
	stubMusixmatchCoverExists(t, map[string]bool{mxDead800: false, mxAlive800: true})
	const dead, alive, other = "宇多田光|Prisoner Of Love|HEART STATION", "宇多田光|Beautiful World|HEART STATION", "A|B|C"
	withEnrichCache(t, map[string]enrichEntry{
		dead:  {CoverURL: mxDead800, CoverSource: "musixmatch", CoverAlbum: "HEART STATION", AccentColor: "#000000"},
		alive: {CoverURL: mxAlive800, CoverSource: "musixmatch"},
		other: {CoverURL: "https://p1.music.126.net/x.jpg", CoverSource: "netease"},
	})
	scope := migrationScopeOf(migrationMusixmatchCovers, migrationMusixmatchCoversVersion)
	if n := repairMusixmatchCovers(context.Background(), scope); n != 1 {
		t.Fatalf("应改一条,实改 %d", n)
	}
	if e := enrichCache[dead]; e.CoverURL != mxDead500 || e.AccentColor != "" || e.CoverSource != "musixmatch" || e.CoverAlbum != "HEART STATION" {
		t.Errorf("取不到的换成 500 档、清掉主色,来源与专辑不动: %+v", e)
	}
	if enrichCache[alive].CoverURL != mxAlive800 || enrichCache[other].CoverURL != "https://p1.music.126.net/x.jpg" {
		t.Error("取得到的、别家的不动")
	}
	if !migrationDone(migrationMusixmatchCovers, migrationMusixmatchCoversVersion) {
		t.Error("全部问成了要记水位")
	}
}

func TestRepairMusixmatchCoversLeavesWatermarkWhenOffline(t *testing.T) {
	withTempMigrationState(t)
	stubMusixmatchCoverExists(t, map[string]bool{})
	withEnrichCache(t, map[string]enrichEntry{"A|B|C": {CoverURL: mxDead800, CoverSource: "musixmatch"}})
	scope := migrationScopeOf(migrationMusixmatchCovers, migrationMusixmatchCoversVersion)
	if n := repairMusixmatchCovers(context.Background(), scope); n != 0 || enrichCache["A|B|C"].CoverURL != mxDead800 {
		t.Errorf("没问成不改: %d", n)
	}
	if migrationDone(migrationMusixmatchCovers, migrationMusixmatchCoversVersion) {
		t.Error("没问成不记水位,下次启动再来")
	}
}
