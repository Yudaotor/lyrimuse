package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// publishAppArtwork 写一份 App 播放状态:这一首(歌名原样)和它的封面。
func publishAppArtwork(t *testing.T, statePath, artPath, title, artist string) {
	t.Helper()
	art := makeTestJPEG(t, 150, 150)
	if err := os.WriteFile(artPath, art, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(art)
	rec := appSourceRec(os.Getpid(), 4, 1, title, time.Now())
	rec.Track.Artist, rec.Track.Raw.Artist = artist, artist
	rec.Artwork = &appStateArtwork{SHA256: hex.EncodeToString(sum[:]), Mime: "image/jpeg", Bytes: len(art), PlaySeq: 4}
	writeAppStateFile(t, statePath, rec)
}

func withAppArtworkSource(t *testing.T) (statePath, artPath string) {
	t.Helper()
	savedDir := deviceArtworkDir
	t.Cleanup(func() { deviceArtworkDir = savedDir })
	deviceArtworkDir = t.TempDir()
	dir := t.TempDir()
	statePath, artPath = filepath.Join(dir, "state.json"), filepath.Join(dir, "artwork")
	setAppPlaybackArtworkSource(newAppStateReader(statePath), artPath)
	t.Cleanup(func() { setAppPlaybackArtworkSource(nil, "") })
	return statePath, artPath
}

// App 报的歌名带着结尾的译名括号,引擎这边是剥过的那份:照样认得出是这一首、取得到设备封面。
func TestDeviceCoverMatchesTitleWithStrippedBracket(t *testing.T) {
	statePath, artPath := withAppArtworkSource(t)
	const full = "小幸运 (电影《我的少女时代》主题曲)"
	stripped := normEnrichTitle(full)
	if stripped == full {
		t.Fatalf("前提:引擎会剥掉这个括号,得到 %q", stripped)
	}
	publishAppArtwork(t, statePath, artPath, full, "田馥甄")
	if url := deviceCoverURLIfFresh(context.Background(), true, "com.apple.Music", "田馥甄", stripped); !strings.HasPrefix(url, "file://") {
		t.Fatalf("剥过括号的歌名也要认得出这一首: %q", url)
	}
	if _, _, ok := appPlaybackTrackPlay("com.apple.Music", "田馥甄", stripped); !ok {
		t.Fatal("起播记录同样按剥过的歌名认")
	}
	if url := deviceCoverURLIfFresh(context.Background(), true, "com.apple.Music", "田馥甄", "别的歌"); url != "" {
		t.Fatalf("别的歌照旧不取: %q", url)
	}
}

// 晚到设备封面:收尾那一步拿到的是转过简体、折过引号的查询写法,照样认这一首。
func TestLateDeviceCoverMatchesQueryForm(t *testing.T) {
	statePath, artPath := withAppArtworkSource(t)
	const artist, title = "周杰倫", "晴天’s Day"
	rec := appSourceRec(os.Getpid(), 4, 1, title, time.Now())
	rec.Track.Artist, rec.Track.Raw.Artist = artist, artist
	writeAppStateFile(t, statePath, rec)
	late := withLateDeviceCover(context.Background(), "com.apple.Music", artist, title)
	publishAppArtwork(t, statePath, artPath, title, artist)
	qa, qt, _ := searchQueryFields(artist, title, "")
	if qa == artist && qt == title {
		t.Fatalf("前提:查询写法跟原样不同,得到 %q %q", qa, qt)
	}
	if url := lateDeviceCover(late, qa, qt); !strings.HasPrefix(url, "file://") {
		t.Fatalf("查询写法也认这一首: %q", url)
	}
	if url := lateDeviceCover(late, qa, "别的歌"); url != "" {
		t.Fatalf("别的写法照旧不取: %q", url)
	}
}

// 设备封面沉降那几档:首次解析还没提交时等它落定,不白用一档;到期还没有就放弃。
func TestWaitForCommittedEntry(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{})
	savedWait, savedPoll := deviceCoverCommitWait, deviceCoverCommitPoll
	savedProv := enrichProvisional
	t.Cleanup(func() {
		deviceCoverCommitWait, deviceCoverCommitPoll = savedWait, savedPoll
		enrichMu.Lock()
		enrichProvisional = savedProv
		enrichMu.Unlock()
	})
	deviceCoverCommitWait, deviceCoverCommitPoll = 2*time.Second, 5*time.Millisecond
	const key = "A|song|x"
	enrichMu.Lock()
	enrichProvisional = map[string]bool{key: true}
	enrichCache[key] = enrichEntry{}
	enrichMu.Unlock()
	done := make(chan bool, 1)
	go func() { done <- waitForCommittedEntry(context.Background(), key) }()
	enrichMu.Lock()
	delete(enrichProvisional, key)
	enrichMu.Unlock()
	if !<-done {
		t.Fatal("提交之后该等到")
	}
	deviceCoverCommitWait = 20 * time.Millisecond
	if waitForCommittedEntry(context.Background(), "A|never|x") {
		t.Fatal("一直没有的条目到期放弃")
	}
	enrichMu.Lock()
	enrichProvisional[key] = true
	enrichMu.Unlock()
	if waitForCommittedEntry(context.Background(), key) {
		t.Fatal("一直是先上屏那份(首次解析还没提交):到期放弃,不当成落定")
	}
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "if !waitForCommittedEntry(ctx, key) {\n\t\t\treturn\n\t\t}\n\t\tif deviceCoverUpgradePass(ctx, key, artist, title, album, bundleID) {") {
		t.Fatal("settleDeviceCover 每一档先等首次解析提交")
	}
}

// 合并条目:封面、来源、封面专辑、主色一套搬;自己有封面只缺主色时,只借同一张封面的主色。
func TestMergePeripheralMovesCoverAsASet(t *testing.T) {
	loser := enrichEntry{CoverURL: "https://a/x.jpg", CoverSource: "apple", CoverAlbum: "Album A", AccentColor: "#111111"}
	got := mergePeripheralInto(enrichEntry{}, loser)
	if got.CoverURL != loser.CoverURL || got.CoverSource != "apple" || got.CoverAlbum != "Album A" || got.AccentColor != "#111111" {
		t.Fatalf("没有封面的一方整套接过来: %+v", got)
	}
	own := mergePeripheralInto(enrichEntry{CoverURL: "https://b/y.jpg"}, loser)
	if own.AccentColor != "" || own.CoverAlbum != "" {
		t.Fatalf("自己有另一张封面:不借别的封面的主色和专辑: %+v", own)
	}
	same := mergePeripheralInto(enrichEntry{CoverURL: "https://a/x.jpg"}, loser)
	if same.AccentColor != "#111111" {
		t.Fatalf("同一张封面:借主色: %+v", same)
	}
}

// 专辑页:中国区没有这一页时再试美区,美区取到就照常解析,不记成没有动态封面。
func TestMotionCoverPageFallsBackToUSStorefront(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/us/91" {
			fmt.Fprint(w, motionCoverPage("91"))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	oldURL, oldPath := motionCoverPageURL, motionCoverPath
	motionCoverPageURL = func(id int64, sf string) string { return fmt.Sprintf("%s/%s/%d", srv.URL, sf, id) }
	motionCoverMu.Lock()
	motionCoverPath = ""
	motionCoverUnavailableStreak = 0
	delete(motionCoverCache, "91")
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		motionCoverPageURL = oldURL
		motionCoverMu.Lock()
		motionCoverPath = oldPath
		delete(motionCoverCache, "91")
		motionCoverMu.Unlock()
	})
	mc, done := motionCoverFor(91)
	if !done || mc.Master == "" {
		t.Fatalf("美区有这一页:应解析出动态封面, done=%v mc=%+v", done, mc)
	}
}

// 官方封面查空(中国区、美区都没给):按这一轮没查成算,不记成「查过了、目录里没有」,身份留空、不判核不上。
func TestMotionCoverAlbumArtworkEmptyIsNotPersisted(t *testing.T) {
	var asked []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = append(asked, r.URL.Query().Get("country"))
		fmt.Fprint(w, `{"resultCount":0,"results":[]}`)
	}))
	defer srv.Close()
	oldLookup, oldPath := itunesCollectionLookupURL, motionCoverPath
	itunesCollectionLookupURL = srv.URL
	motionCoverMu.Lock()
	motionCoverPath = ""
	motionCoverCache["92"] = motionCover{Master: "https://mvod/x.m3u8", Checked: true}
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		itunesCollectionLookupURL = oldLookup
		motionCoverMu.Lock()
		motionCoverPath = oldPath
		delete(motionCoverCache, "92")
		motionCoverMu.Unlock()
	})
	art, done := motionCoverAlbumArtworkFor(context.Background(), 92)
	if art != "" || done {
		t.Fatalf("查空按没查成算, art=%q done=%v", art, done)
	}
	if strings.Join(asked, ",") != "cn,us" {
		t.Fatalf("中国区查空再查美区,实际问了 %v", asked)
	}
	motionCoverMu.Lock()
	checked := motionCoverCache["92"].AlbumArtworkChecked
	motionCoverMu.Unlock()
	if checked {
		t.Fatal("查空不记下,下次再查")
	}
	if got := motionCoverIdentityFor(context.Background(), 92, "https://cover/x.jpg"); got != motionIdentityUndecided {
		t.Fatalf("查空不当定论,身份待定: %v", got)
	}
}
