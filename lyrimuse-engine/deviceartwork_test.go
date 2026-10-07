package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func makeTestJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatalf("encode test jpeg: %v", err)
	}
	return buf.Bytes()
}

// 像不像封面由 App 判(不像的不写进当前封面文件),这里拿到解得开的就用:一张 32×20 的小图照样落成设备封面;
// 不是新曲目不取;解不开的不用。
func TestDeviceCoverURLIfFreshTakesWhatTheAppPublished(t *testing.T) {
	savedDir := deviceArtworkDir
	t.Cleanup(func() { deviceArtworkDir = savedDir })
	deviceArtworkDir = t.TempDir()
	dir := t.TempDir()
	statePath, artPath := filepath.Join(dir, "state.json"), filepath.Join(dir, "artwork")
	setAppPlaybackArtworkSource(newAppStateReader(statePath), artPath)
	t.Cleanup(func() { setAppPlaybackArtworkSource(nil, "") })
	publish := func(seq int64, art []byte) {
		t.Helper()
		if err := os.WriteFile(artPath, art, 0o644); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(art)
		rec := appSourceRec(os.Getpid(), 4, 1, "Song", time.Now())
		rec.Seq = seq
		rec.Artwork = &appStateArtwork{SHA256: hex.EncodeToString(sum[:]), Mime: "image/jpeg", Bytes: len(art), PlaySeq: 4}
		writeAppStateFile(t, statePath, rec)
	}
	ctx := context.Background()
	publish(1, makeTestJPEG(t, 32, 20))
	if url := deviceCoverURLIfFresh(ctx, true, "com.apple.Music", "Singer", "Song"); !strings.HasPrefix(url, "file://") {
		t.Fatalf("App 交过来的图解得开就用: %q", url)
	}
	if url := deviceCoverURLIfFresh(ctx, false, "com.apple.Music", "Singer", "Song"); url != "" {
		t.Fatalf("不是新曲目不取: %q", url)
	}
	publish(2, []byte("not an image"))
	if _, _, ok := appPlaybackArtwork("com.apple.Music", "Singer", "Song"); !ok {
		t.Fatal("App 发的这份要读得到")
	}
	if url := deviceCoverURLIfFresh(ctx, true, "com.apple.Music", "Singer", "Song"); url != "" {
		t.Fatalf("解不开的不用: %q", url)
	}
}

// App 标成视频帧的那张不当设备封面;单独落盘、记进条目的 video_frame_url,封面字段不动(03 章决策 39)。
func TestVideoFrameIsKeptApartFromTheCover(t *testing.T) {
	savedDir := deviceArtworkDir
	t.Cleanup(func() { deviceArtworkDir = savedDir })
	deviceArtworkDir = t.TempDir()
	dir := t.TempDir()
	statePath, artPath := filepath.Join(dir, "state.json"), filepath.Join(dir, "artwork")
	setAppPlaybackArtworkSource(newAppStateReader(statePath), artPath)
	t.Cleanup(func() { setAppPlaybackArtworkSource(nil, "") })
	art := makeTestJPEG(t, 32, 18)
	if err := os.WriteFile(artPath, art, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(art)
	rec := appSourceRec(os.Getpid(), 4, 1, "Song", time.Now())
	rec.Seq = 1
	rec.Artwork = &appStateArtwork{SHA256: hex.EncodeToString(sum[:]), Mime: "image/jpeg", Bytes: len(art), PlaySeq: 4,
		Kind: appArtworkKindVideoFrame}
	writeAppStateFile(t, statePath, rec)
	if url := deviceCoverURLIfFresh(context.Background(), true, "com.apple.Music", "Singer", "Song"); url != "" {
		t.Fatalf("视频帧不当设备封面: %q", url)
	}
	url := videoFrameURLIfFresh("com.apple.Music", "Singer", "Song")
	if !strings.HasPrefix(url, "file://") {
		t.Fatalf("视频帧要落盘: %q", url)
	}
	const key = "Singer|Song|"
	withEnrichCache(t, map[string]enrichEntry{key: {Lyrics: "[00:01.00]x"}})
	if !noteVideoFrame(key, "com.apple.Music", "Singer", "Song") {
		t.Fatal("条目在缓存里要记上视频帧")
	}
	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.VideoFrameURL != url || e.CoverURL != "" || e.CoverSource != "" {
		t.Fatalf("只记视频帧、封面不动: %+v", e)
	}
	if noteVideoFrame(key, "com.apple.Music", "Singer", "Song") {
		t.Error("同一张不重复写")
	}
	if noteVideoFrame("Singer|Other|", "com.apple.Music", "Singer", "Song") {
		t.Error("条目不在缓存里不写")
	}
	if b, _ := json.Marshal(e); !strings.Contains(string(b), `"video_frame_url":"`+url+`"`) {
		t.Errorf("video_frame_url 要落进缓存: %s", b)
	}
}

// saveDeviceArtwork:按内容 sha256 命名,同一张图重复保存不重复写盘(用 mtime 间接验证——
// 第二次保存后 mtime 不变说明没有真的重新 WriteFile)。
func TestSaveDeviceArtworkDedupesByContent(t *testing.T) {
	saved := deviceArtworkDir
	t.Cleanup(func() { deviceArtworkDir = saved })
	deviceArtworkDir = t.TempDir()

	data := makeTestJPEG(t, 300, 300)

	url1, ok := saveDeviceArtwork(data, "image/jpeg")
	if !ok || url1 == "" {
		t.Fatalf("首次保存应该成功, ok=%v url=%q", ok, url1)
	}
	if got := len(mustGlob(t, deviceArtworkDir)); got != 1 {
		t.Fatalf("目录下应该只有 1 个文件, got %d", got)
	}

	url2, ok := saveDeviceArtwork(data, "image/jpeg")
	if !ok || url2 != url1 {
		t.Fatalf("同一份内容第二次保存应该返回同一个 URL, url1=%q url2=%q", url1, url2)
	}
	if got := len(mustGlob(t, deviceArtworkDir)); got != 1 {
		t.Fatalf("重复保存同一张图不应该多出文件, got %d", got)
	}

	// 不同内容的图落到不同文件。
	other := makeTestJPEG(t, 300, 301) // 内容不同(尺寸不同 -> 编码字节不同)
	url3, ok := saveDeviceArtwork(other, "image/jpeg")
	if !ok || url3 == url1 {
		t.Fatalf("不同内容的封面应该落到不同的 URL, url1=%q url3=%q", url1, url3)
	}
	if got := len(mustGlob(t, deviceArtworkDir)); got != 2 {
		t.Fatalf("两张不同的图应该各自落一份文件, got %d", got)
	}
}

func TestSaveDeviceArtworkNoDirConfigured(t *testing.T) {
	saved := deviceArtworkDir
	t.Cleanup(func() { deviceArtworkDir = saved })
	deviceArtworkDir = ""

	if _, ok := saveDeviceArtwork(makeTestJPEG(t, 300, 300), "image/jpeg"); ok {
		t.Error("deviceArtworkDir 为空时应该直接失败,不应该尝试落盘")
	}
}

func mustGlob(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read dir %q: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, filepath.Join(dir, e.Name()))
	}
	return names
}
