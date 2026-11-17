package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// kuwoCoverFixture:App 报酷我在放《至少还有你》(姚贝娜,专辑「大丈夫 电视剧原声带」),封面目录指到临时目录。返回目录和改 App
// 状态的函数。
func kuwoCoverFixture(t *testing.T) (dir string, publish func(mut func(*appStateRecord))) {
	t.Helper()
	savedArt, savedDir := deviceArtworkDir, kuwoCoverDirOverride
	t.Cleanup(func() { deviceArtworkDir, kuwoCoverDirOverride = savedArt, savedDir })
	deviceArtworkDir = t.TempDir()
	dir = t.TempDir()
	kuwoCoverDirOverride = dir
	stateDir := t.TempDir()
	statePath := filepath.Join(stateDir, "state.json")
	setAppPlaybackArtworkSource(newAppStateReader(statePath), filepath.Join(stateDir, "artwork"))
	t.Cleanup(func() { setAppPlaybackArtworkSource(nil, "") })
	seq := int64(0)
	publish = func(mut func(*appStateRecord)) {
		seq++
		rec := appSourceRec(os.Getpid(), 7, 1, "至少还有你", time.Now())
		rec.Seq = seq
		rec.Player = kuwoMusicBundleID
		rec.Track.Artist, rec.Track.Album = "姚贝娜", "大丈夫 电视剧原声带"
		rec.Track.Raw = appStateTags{Title: "至少还有你", Artist: "姚贝娜", Album: "大丈夫 电视剧原声带"}
		if mut != nil {
			mut(&rec)
		}
		writeAppStateFile(t, statePath, rec)
	}
	publish(nil)
	return dir, publish
}

// 酷我在放、App 报了专辑时,容器里「歌手 - 专辑.jpg」那张当这首的设备封面落盘;别的播放器、别的歌不取。
func TestKuwoLocalCoverBecomesDeviceCover(t *testing.T) {
	dir, publish := kuwoCoverFixture(t)
	art := makeTestJPEG(t, 300, 300)
	if err := os.WriteFile(filepath.Join(dir, "姚贝娜 - 大丈夫 电视剧原声带.jpg"), art, 0o644); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	got := deviceCoverURLIfFresh(ctx, true, kuwoMusicBundleID, "姚贝娜", "至少还有你")
	u, err := url.Parse(got)
	if got == "" || err != nil || u.Scheme != "file" {
		t.Fatalf("酷我容器里那张当设备封面: %q", got)
	}
	if b, err := os.ReadFile(u.Path); err != nil || !bytes.Equal(b, art) {
		t.Fatalf("落盘的就是容器里那张: err=%v", err)
	}
	if _, mime, ok := fetchNowPlayingArtwork(ctx, kuwoMusicBundleID, "姚贝娜", "至少还有你"); !ok || mime != "image/jpeg" {
		t.Fatalf("mime = %q ok=%v", mime, ok)
	}
	if got := deviceCoverURLIfFresh(ctx, false, kuwoMusicBundleID, "姚贝娜", "至少还有你"); got != "" {
		t.Errorf("不是新曲目不取: %q", got)
	}
	if _, _, ok := fetchNowPlayingArtwork(ctx, kuwoMusicBundleID, "姚贝娜", "千年等一回"); ok {
		t.Error("App 报的不是这一首不取")
	}
	publish(func(r *appStateRecord) { r.Player = qqMusicBundleID })
	if _, _, ok := fetchNowPlayingArtwork(ctx, qqMusicBundleID, "姚贝娜", "至少还有你"); ok {
		t.Error("别的播放器不读酷我的封面")
	}
}

// 没报专辑的不读「歌手 - .jpg」(同一位歌手别的没专辑的条目会盖掉它);原样那份专辑空时用 App 报的。
func TestKuwoLocalCoverNeedsAlbum(t *testing.T) {
	dir, publish := kuwoCoverFixture(t)
	art := makeTestJPEG(t, 300, 300)
	for _, name := range []string{"宝宝巴士 - .jpg", "宝宝巴士 - 睡前故事.jpg"} {
		if err := os.WriteFile(filepath.Join(dir, name), art, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	publish(func(r *appStateRecord) {
		r.Track.Title, r.Track.Artist, r.Track.Album = "晚安，小红伞", "宝宝巴士", ""
		r.Track.Raw = appStateTags{Title: "晚安，小红伞", Artist: "宝宝巴士"}
	})
	if _, _, ok := kuwoLocalCoverArtwork(kuwoMusicBundleID, "宝宝巴士", "晚安，小红伞"); ok {
		t.Error("没报专辑的不读只有歌手的那张")
	}
	publish(func(r *appStateRecord) {
		r.Track.Title, r.Track.Artist, r.Track.Album = "晚安，小红伞", "宝宝巴士", "睡前故事"
		r.Track.Raw = appStateTags{Title: "晚安，小红伞", Artist: "宝宝巴士"}
	})
	if _, _, ok := kuwoLocalCoverArtwork(kuwoMusicBundleID, "宝宝巴士", "晚安，小红伞"); !ok {
		t.Error("原样那份专辑空时用 App 报的专辑")
	}
}

// 不像封面的(太小、偏离正方形)、不是图的、名字带路径分隔符的都不取;App 自己交了封面时用 App 那份。
func TestKuwoLocalCoverRejects(t *testing.T) {
	dir, publish := kuwoCoverFixture(t)
	path := filepath.Join(dir, "姚贝娜 - 大丈夫 电视剧原声带.jpg")
	for name, data := range map[string][]byte{"太小": makeTestJPEG(t, 32, 32), "长方形": makeTestJPEG(t, 300, 200), "不是图": []byte("nope")} {
		if err := os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, _, ok := kuwoLocalCoverArtwork(kuwoMusicBundleID, "姚贝娜", "至少还有你"); ok {
			t.Errorf("%s的不取", name)
		}
	}
	for _, c := range [][2]string{{"AC/DC", "Back in Black"}, {"歌手", "a/b"}, {"歌手", ""}, {"", "专辑"}, {"歌手", "x\x00"}} {
		if got := kuwoCoverFileName(c[0], c[1]); got != "" {
			t.Errorf("kuwoCoverFileName(%q, %q) = %q", c[0], c[1], got)
		}
	}
	if got := kuwoCoverFileName(" 雷安娜&关正杰 ", "旧梦不须记"); got != "雷安娜&关正杰 - 旧梦不须记.jpg" {
		t.Errorf("文件名: %q", got)
	}
	own := makeTestJPEG(t, 600, 600)
	if err := os.WriteFile(path, makeTestJPEG(t, 300, 300), 0o644); err != nil {
		t.Fatal(err)
	}
	stateDir := t.TempDir()
	artPath := filepath.Join(stateDir, "artwork")
	if err := os.WriteFile(artPath, own, 0o644); err != nil {
		t.Fatal(err)
	}
	appPlaybackArtworkMu.Lock()
	r := appPlaybackArtworkReader
	appPlaybackArtworkMu.Unlock()
	setAppPlaybackArtworkSource(r, artPath)
	sum := sha256.Sum256(own)
	publish(func(rec *appStateRecord) {
		rec.Artwork = &appStateArtwork{SHA256: hex.EncodeToString(sum[:]), Mime: "image/jpeg", Bytes: len(own), PlaySeq: rec.Track.PlaySeq}
	})
	if b, _, ok := fetchNowPlayingArtwork(context.Background(), kuwoMusicBundleID, "姚贝娜", "至少还有你"); !ok || !bytes.Equal(b, own) {
		t.Error("App 交了封面时用 App 那份")
	}
}

// 封面目录在酷我的私有容器里,跟歌词、待播一样经 otherAppContainer 的完全磁盘访问闸取。
func TestKuwoCoverDirGoesThroughGate(t *testing.T) {
	saved := kuwoCoverDirOverride
	t.Cleanup(func() { kuwoCoverDirOverride = saved })
	kuwoCoverDirOverride = ""
	withFullDiskAccess(t, false)
	if d := kuwoCoverDir(); d != "" {
		t.Errorf("没有完全磁盘访问时不给容器路径: %q", d)
	}
	withFullDiskAccess(t, true)
	if d := kuwoCoverDir(); filepath.Base(d) != "HDPicture" {
		t.Errorf("有授权时是容器里的 HDPicture: %q", d)
	}
}
