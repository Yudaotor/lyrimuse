// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"fmt"
	"image"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
)

var (
	accentMu    sync.Mutex
	accentCache = map[string]string{}
)

// dominantColor samples a vibrant accent color (hex) from a cover image so the
// web can tint the card to match the album. Cached per cover URL; fetches a tiny
// 64x64 variant for a cheap decode.
func dominantColor(coverURL string) string {
	if coverURL == "" {
		return ""
	}
	accentMu.Lock()
	if v, ok := accentCache[coverURL]; ok {
		accentMu.Unlock()
		return v
	}
	accentMu.Unlock()
	c := resolveDominantColor(coverURL)
	if c != "" {
		accentMu.Lock()
		accentCache[coverURL] = c
		accentMu.Unlock()
	}
	return c
}

func resolveDominantColor(coverURL string) string {
	small := coverURL
	referer := "https://music.163.com/"
	if strings.Contains(coverURL, "music.126.net") || strings.Contains(coverURL, "music.127.net") {
		if i := strings.Index(small, "?param="); i >= 0 {
			small = small[:i]
		}
		small += "?param=64y64" // 网易云 CDN 支持按需缩图,省流量
	} else if strings.Contains(coverURL, "qq.com") {
		// 网易云那套 ?param=WxH 对 QQ 域名无效(会被原样忽略),QQ 的尺寸档在**路径**里 ——
		// 所以降采样要改路径,见 qqCoverAtEdge。2026-08-24 起存下来的 QQ 封面是 800x800
		// (歌词窗口那张大卡要的),而取一个主色用不着 800:降回 300 少下 150KB。
		// Referer 一并给上:QQ 音乐图床按 Referer 防盗链,给错了才可能被拒。
		// 见 qqCoverFallback:网易云曲库缺失该艺人时的兜底封面。
		small = qqCoverAtEdge(small, "300")
		referer = "https://y.qq.com/"
	}
	cli := &http.Client{Timeout: 4 * time.Second}
	req, err := http.NewRequest(http.MethodGet, small, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Referer", referer)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	img, _, err := image.Decode(resp.Body) // 自动识别 JPEG/PNG
	if err != nil {
		return ""
	}
	b := img.Bounds()
	var wr, wg, wb, wsum float64 // saturation-weighted (favors vibrant color)
	var ar, ag, ab, n float64    // plain average (fallback for grey covers)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			r16, g16, b16, _ := img.At(x, y).RGBA()
			r, g, bl := float64(r16>>8), float64(g16>>8), float64(b16>>8)
			ar, ag, ab, n = ar+r, ag+g, ab+bl, n+1
			mx := math.Max(r, math.Max(g, bl))
			mn := math.Min(r, math.Min(g, bl))
			sat := 0.0
			if mx > 0 {
				sat = (mx - mn) / mx
			}
			w := sat * sat
			wr, wg, wb, wsum = wr+r*w, wg+g*w, wb+bl*w, wsum+w
		}
	}
	if n == 0 {
		return ""
	}
	var r, g, bl float64
	if wsum > 0.5 {
		r, g, bl = wr/wsum, wg/wsum, wb/wsum
	} else {
		r, g, bl = ar/n, ag/n, ab/n
	}
	// 直接用取色算出来的原值,不做强制转 HSL 提亮/提饱和度——哪怕某些灰调封面(如
	// Parade 的老照片)算出来的强调色不够醒目也接受,优先忠于封面本身的色调。
	return fmt.Sprintf("#%02x%02x%02x", int(r+0.5), int(g+0.5), int(bl+0.5))
}
