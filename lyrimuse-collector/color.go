// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"math"
	"net/http"
	"os"
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
func dominantColor(ctx context.Context, coverURL string) string {
	if coverURL == "" {
		return ""
	}
	accentMu.Lock()
	if v, ok := accentCache[coverURL]; ok {
		accentMu.Unlock()
		return v
	}
	accentMu.Unlock()
	c := resolveDominantColor(ctx, coverURL)
	if c != "" {
		accentMu.Lock()
		accentCache[coverURL] = c
		accentMu.Unlock()
	}
	return c
}

// deviceArtworkURLPrefix:trackEnrichment 传下来的设备直送封面,存的是本地文件路径
// (见 deviceartwork.go 的 saveDeviceArtwork),不是网易云/QQ 那种要发 HTTP 请求的
// 远程图。取主色不能沿用下面那套 CDN 缩图+doHTTPTracked 的逻辑,直接读本地文件。
const deviceArtworkURLPrefix = "file://"

func resolveDominantColor(ctx context.Context, coverURL string) string {
	img := loadCoverImage(ctx, coverURL)
	if img == nil {
		return ""
	}
	return dominantColorFromImage(img)
}

// loadCoverImage 把一个封面 URL(本地 file:// 或远程 CDN)取回来解成 image.Image。
//
// 2026-09-02 从 resolveDominantColor 里抽出来 —— 设备封面的清晰度判据
// (coverquality.go)也要取远程候选来比一次,而"哪个 CDN 该怎么降采样、要不要带
// Referer"这套知识只该有一份。抽的时候行为一字未改。
//
// ⚠️ **返回的远程图是降采样过的**(网易云 64y64、QQ 300),因为唯一的原始调用方是取色。
// 所以**绝不能拿它的解码尺寸去判"这个候选有多清晰"** —— 那会把一张 800×800 的候选读成
// 64px。清晰度判据(coverquality.go)因此改成从 URL 里读目标尺寸
// (`coverURLIntendedEdge`),只把这里返回的小图用于 8×8 感知指纹(那个尺度上降采样
// 无所谓)。2026-09-02 实现时真的先踩了这一脚:第一版用 `minEdge(解码结果)` 比大小,
// 判据恒成立、修复一次都不会触发。
func loadCoverImage(ctx context.Context, coverURL string) image.Image {
	if strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		data, err := os.ReadFile(strings.TrimPrefix(coverURL, deviceArtworkURLPrefix))
		if err != nil {
			return nil
		}
		img, _, err := image.Decode(bytes.NewReader(data))
		if err != nil {
			return nil
		}
		return img
	}
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
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, small, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Referer", referer)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	img, _, err := image.Decode(resp.Body) // 自动识别 JPEG/PNG
	if err != nil {
		return nil
	}
	return img
}

// dominantColorFromImage 是取色算法本体,从 resolveDominantColor 里抽出来——设备直送
// 封面(deviceartwork.go)手上已经是解好的 image.Image,不需要、也不应该再走一遍
// HTTP 下载那一段,两边共享这一份逐像素扫描逻辑。
func dominantColorFromImage(img image.Image) string {
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
