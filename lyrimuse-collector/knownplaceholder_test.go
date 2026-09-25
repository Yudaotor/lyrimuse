package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func withKnownPlaceholders(t *testing.T, entries []knownPlaceholder) {
	t.Helper()
	saved := knownPlaceholderArtwork
	knownPlaceholderArtwork = entries
	t.Cleanup(func() { knownPlaceholderArtwork = saved })
}

func placeholderEntryFor(data []byte) knownPlaceholder {
	h := sha256.Sum256(data)
	return knownPlaceholder{byteCount: len(data), sha256Hex: hex.EncodeToString(h[:]), player: "test"}
}

// 两侧指纹必须逐条相同:只改一边的话,App 不挂那张图、collector 却把它存成永久封面(或反过来)。
func TestKnownPlaceholderArtworkMatchesSwift(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/KnownPlaceholderArtwork.swift")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`Entry\(byteCount:\s*(\d+),\s*sha256Hex:\s*"([0-9a-f]{64})"`)
	var swift, goSide []string
	for _, m := range re.FindAllStringSubmatch(string(src), -1) {
		swift = append(swift, m[1]+"|"+m[2])
	}
	for _, p := range knownPlaceholderArtwork {
		goSide = append(goSide, strings.Join([]string{strconv.Itoa(p.byteCount), p.sha256Hex}, "|"))
	}
	sort.Strings(swift)
	sort.Strings(goSide)
	if len(swift) == 0 || strings.Join(swift, ",") != strings.Join(goSide, ",") {
		t.Fatalf("两侧占位图登记表不一致:\n Swift %v\n Go    %v", swift, goSide)
	}
}

func TestIsKnownPlaceholderArtwork(t *testing.T) {
	placeholder := []byte("built-in placeholder bytes")
	withKnownPlaceholders(t, []knownPlaceholder{placeholderEntryFor(placeholder)})
	if !isKnownPlaceholderArtwork(placeholder) {
		t.Fatal("登记过的字节要认出来")
	}
	sameSize := []byte("built-in placeholder bytez")
	if isKnownPlaceholderArtwork(sameSize) {
		t.Fatal("字节数相同、内容不同的真封面不能误认")
	}
	if isKnownPlaceholderArtwork(append(placeholder, 'x')) {
		t.Fatal("字节数不同的直接放行")
	}
}

func TestIsKnownPlaceholderCoverURL(t *testing.T) {
	placeholder := []byte("built-in placeholder bytes")
	entry := placeholderEntryFor(placeholder)
	withKnownPlaceholders(t, []knownPlaceholder{entry})
	stem := entry.sha256Hex[:16]
	for url, want := range map[string]bool{
		"file:///tmp/artwork/" + stem + ".jpg":       true,
		"file:///tmp/artwork/" + stem + ".png":       true,
		"file:///tmp/artwork/0123456789abcdef.jpg":   false,
		"https://p1.music.126.net/" + stem + ".jpg":  false,
		"file:///tmp/artwork/" + stem[:15] + "0.jpg": false,
	} {
		if got := isKnownPlaceholderCoverURL(url); got != want {
			t.Errorf("%s: got %v want %v", url, got, want)
		}
	}
}

// 已经存成 device 封面的占位图清掉封面四件套,别的字段、别的条目一个不动。
func TestMigrateKnownPlaceholderCovers(t *testing.T) {
	placeholder := []byte("built-in placeholder bytes")
	entry := placeholderEntryFor(placeholder)
	withKnownPlaceholders(t, []knownPlaceholder{entry})
	stuck := enrichKey("吴若希", "越难越爱", "")
	fine := enrichKey("Other", "Song", "")
	placeholderURL := "file:///tmp/artwork/" + entry.sha256Hex[:16] + ".jpg"
	setUpEnrichEditTest(t, map[string]enrichEntry{
		stuck: {CoverURL: placeholderURL, CoverSource: "device", CoverAlbum: "A", AccentColor: "#112233", Lyrics: "[00:01.00]词", TS: 5},
		fine:  {CoverURL: "file:///tmp/artwork/0123456789abcdef.jpg", CoverSource: "device", AccentColor: "#445566", TS: 6},
	})
	migrateKnownPlaceholderCovers()
	e, _ := cacheEntry(t, stuck)
	if e.CoverURL != "" || e.CoverSource != "" || e.CoverAlbum != "" || e.AccentColor != "" {
		t.Fatalf("占位图封面四件套要一起清: %+v", e)
	}
	if e.Lyrics != "[00:01.00]词" || e.TS != 5 {
		t.Fatalf("封面以外的字段不能动: %+v", e)
	}
	if f, _ := cacheEntry(t, fine); f.CoverURL == "" || f.AccentColor != "#445566" {
		t.Fatalf("真封面不能被清: %+v", f)
	}
	disk, err := os.ReadFile(enrichPath)
	if err != nil || strings.Contains(string(disk), placeholderURL) {
		t.Fatalf("清完要落盘 err=%v", err)
	}
}

// 取设备封面要行为测试得起一个 media-control,按源码钉住:占位图判定排在落盘之前。
func TestDeviceCoverURLIfFreshRejectsKnownPlaceholder(t *testing.T) {
	src, err := os.ReadFile("deviceartwork.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func deviceCoverURLIfFresh(")
	if i < 0 {
		t.Fatal("找不到 deviceCoverURLIfFresh")
	}
	body = body[i:]
	check, save := strings.Index(body, "isKnownPlaceholderArtwork(data)"), strings.Index(body, "saveDeviceArtwork(data")
	if check < 0 || save < 0 || check > save {
		t.Fatal("deviceCoverURLIfFresh 要在落盘之前拦下登记在案的占位图")
	}
}
