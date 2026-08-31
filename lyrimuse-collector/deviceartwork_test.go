package main

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"
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

func makeTestPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode test png: %v", err)
	}
	return buf.Bytes()
}

// decodeDeviceArtwork 的质量门槛——见其头注(Arc 播 Apple Music 网页版《Immortal》
// 那次真实案例:媒体自己上送的封面是 140x140、方形,过这两条门槛完全没问题)。
func TestDecodeDeviceArtworkQuality(t *testing.T) {
	t.Run("正常尺寸方形_通过", func(t *testing.T) {
		img, ok := decodeDeviceArtwork(makeTestJPEG(t, 300, 300))
		if !ok || img == nil {
			t.Fatalf("300x300 方形图应该通过质量检查, got ok=%v", ok)
		}
	})

	t.Run("太小_不通过", func(t *testing.T) {
		if _, ok := decodeDeviceArtwork(makeTestJPEG(t, 16, 16)); ok {
			t.Error("16x16(占位图典型尺寸,低于 deviceArtworkMinEdge)应该被拒绝")
		}
	})

	t.Run("Web端常见小尺寸封面_通过", func(t *testing.T) {
		// 2026-08-31 真实案例:Arc/Edge 播 Apple Music 网页版《Immortal》时,MediaSession
		// API 实际上送的就是这个尺寸——不是占位图,是真封面,必须放行(这条用例就是当初
		// deviceArtworkMinEdge 从 200 订正到 64 的直接依据,别再改回去)。
		if _, ok := decodeDeviceArtwork(makeTestJPEG(t, 120, 120)); !ok {
			t.Error("120x120 是真实观测到的 MediaSession 封面尺寸,不应该被拒绝")
		}
	})

	t.Run("边长刚好等于下限_通过", func(t *testing.T) {
		if _, ok := decodeDeviceArtwork(makeTestJPEG(t, deviceArtworkMinEdge, deviceArtworkMinEdge)); !ok {
			t.Error("边长刚好等于 deviceArtworkMinEdge 应该通过(边界含)")
		}
	})

	t.Run("明显不是正方形_不通过", func(t *testing.T) {
		if _, ok := decodeDeviceArtwork(makeTestJPEG(t, 600, 200)); ok {
			t.Error("600x200(长宽比严重偏离正方形,像 banner 不像封面)应该被拒绝")
		}
	})

	t.Run("长宽比在容差内_通过", func(t *testing.T) {
		// 300 vs 280: (300-280)/300 = 6.7%,在 deviceArtworkMaxAspectSkew(15%)容差内。
		if _, ok := decodeDeviceArtwork(makeTestJPEG(t, 300, 280)); !ok {
			t.Error("6.7% 的长宽差应该在容差内,不该被拒绝")
		}
	})

	t.Run("PNG格式也支持", func(t *testing.T) {
		if _, ok := decodeDeviceArtwork(makeTestPNG(t, 300, 300)); !ok {
			t.Error("PNG 格式的封面应该也能正常解码通过")
		}
	})

	t.Run("损坏数据_不通过", func(t *testing.T) {
		if _, ok := decodeDeviceArtwork([]byte("not an image")); ok {
			t.Error("非图片数据应该解码失败")
		}
	})

	t.Run("空数据_不通过", func(t *testing.T) {
		if _, ok := decodeDeviceArtwork(nil); ok {
			t.Error("空字节应该解码失败")
		}
	})
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
