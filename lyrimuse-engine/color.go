package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
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
// 从 resolveDominantColor 里抽出来 —— 设备封面的清晰度判据
// (coverquality.go)也要取远程候选来比一次,而"哪个 CDN 该怎么降采样、要不要带
// Referer"这套知识只该有一份。抽的时候行为一字未改。
//
// **返回的远程图是降采样过的**(网易云 64y64、QQ 300),因为唯一的原始调用方是取色。
// 所以**绝不能拿它的解码尺寸去判"这个候选有多清晰"** —— 那会把一张 800×800 的候选读成
// 64px。清晰度判据(coverquality.go)因此改成从 URL 里读目标尺寸
// (`coverURLIntendedEdge`),只把这里返回的小图用于 8×8 感知指纹(那个尺度上降采样
// 无所谓)。 别用 `minEdge(解码结果)` 比大小:那样判据恒成立、修复一次都不会触发。
func loadCoverImage(ctx context.Context, coverURL string) image.Image {
	if strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		data, err := os.ReadFile(strings.TrimPrefix(coverURL, deviceArtworkURLPrefix))
		if err != nil {
			return nil
		}
		img, err := decodeCoverImage(data)
		if err != nil {
			return nil
		}
		return img
	}
	small := coverURL
	if strings.Contains(coverURL, "music.126.net") || strings.Contains(coverURL, "music.127.net") {
		if i := strings.Index(small, "?"); i >= 0 {
			small = small[:i] // 摘掉 ?param= 或 neteaseCoverQuery 那一串
		}
		small += "?param=64y64" // 网易云 CDN 支持按需缩图,省流量
	} else if strings.Contains(coverURL, "qq.com") {
		// 网易云那套 ?param=WxH 对 QQ 域名无效(会被原样忽略),QQ 的尺寸档在**路径**里 ——
		// 所以降采样要改路径,见 qqCoverAtEdge。存下来的 QQ 封面是 800x800
		// (歌词窗口那张大卡要的),而取一个主色用不着 800:降回 300 少下 150KB。
		// 见 qqCoverFallback:网易云曲库缺失该艺人时的兜底封面。
		small = qqCoverAtEdge(small, "300")
	} else if strings.Contains(coverURL, "i.kfs.io/") {
		// KKBOX 图床按路径里的 fit 档出图,取色、比指纹 64 档就够。
		small = kkboxCoverAtEdge(small, "64")
	}
	cli := &http.Client{Timeout: 4 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, small, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Referer", coverRequestReferer(coverURL))
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(cli, req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, coverImageMaxBytes+1))
	if err != nil || len(data) > coverImageMaxBytes {
		return nil
	}
	img, err := decodeCoverImage(data) // 自动识别 JPEG/PNG
	if err != nil {
		return nil
	}
	return img
}

// coverRequestReferer:取封面图时带的 Referer。QQ 音乐图床按 Referer 防盗链,给错了才可能被拒,给 y.qq.com;别的给
// 网易云的(网易云图床要,别家不看)。loadCoverImage 取缩图、coverActualEdge 量尺寸共用。
func coverRequestReferer(coverURL string) string {
	if strings.Contains(coverURL, "qq.com") {
		return "https://y.qq.com/"
	}
	return "https://music.163.com/"
}

// 封面解码的上限。设备封面来自播放器 / 网页的 MediaSession,远程候选来自各家 CDN,都不是我们控制的:几十 KB 的
// PNG 就能声明一张 8000² 的图,解码当场分配几百 MB,之后取色、感知指纹还要逐像素再扫一遍。真实封面最大 3000²
// (Apple 原图档),4096² 留足余量。
const (
	coverImageMaxPixels = 4096 * 4096
	coverImageMaxBytes  = 16 << 20
)

// decodeCoverImage 先只读图头拿尺寸,超过像素上限就不解码。
func decodeCoverImage(data []byte) (image.Image, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > coverImageMaxPixels {
		return nil, fmt.Errorf("cover image %dx%d exceeds the decode limit", cfg.Width, cfg.Height)
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	return img, err
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
