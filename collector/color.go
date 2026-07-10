// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
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
		// QQ 音乐图床按 Referer 防盗链;T002R300x300 路径本身已是缩略图,不用再拼缩放参数
		// (网易云那套 ?param=WxH 对 QQ 域名无效,会被原样忽略、多下点流量但不影响正确性,
		// Referer 给错了才可能被拒)。见 qqCoverFallback:网易云曲库缺失该艺人时的兜底封面。
		referer = "https://y.qq.com/"
	}
	cli := &http.Client{Timeout: 4 * time.Second}
	req, err := http.NewRequest(http.MethodGet, small, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Referer", referer)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := cli.Do(req)
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
	// 保证强调色在深色卡片上清晰:转 HSL、强制最低饱和度 + 合适亮度。灰调封面(如 Parade
	// 的老照片)原本算出浑浊灰(#5a5b52),在深底上进度条/歌词看不清;提饱和+提亮后变成
	// 一个可辨的、贴合封面色调的鲜亮色。
	r, g, bl = ensureVivid(r, g, bl)
	return fmt.Sprintf("#%02x%02x%02x", int(r+0.5), int(g+0.5), int(bl+0.5))
}

// ensureVivid raises a muddy/dark color to a saturated, mid-light one (via HSL:
// s≥0.5, l∈[0.55,0.66]) so it stands out on the dark card. Inputs/outputs 0–255.
func ensureVivid(r, g, bl float64) (float64, float64, float64) {
	h, s, l := rgbToHSL(r/255, g/255, bl/255)
	if s < 0.5 {
		s = 0.5
	}
	if l < 0.55 {
		l = 0.55
	} else if l > 0.66 {
		l = 0.66
	}
	nr, ng, nb := hslToRGB(h, s, l)
	return nr * 255, ng * 255, nb * 255
}

func rgbToHSL(r, g, b float64) (h, s, l float64) {
	mx := math.Max(r, math.Max(g, b))
	mn := math.Min(r, math.Min(g, b))
	l = (mx + mn) / 2
	d := mx - mn
	if d == 0 {
		return 0, 0, l // 纯灰:色相未定义,记 0(红),后续会被强制饱和成可辨色
	}
	if l > 0.5 {
		s = d / (2 - mx - mn)
	} else {
		s = d / (mx + mn)
	}
	switch mx {
	case r:
		h = (g - b) / d
		if g < b {
			h += 6
		}
	case g:
		h = (b-r)/d + 2
	default:
		h = (r-g)/d + 4
	}
	h /= 6
	return h, s, l
}

func hslToRGB(h, s, l float64) (r, g, b float64) {
	if s == 0 {
		return l, l, l
	}
	var q float64
	if l < 0.5 {
		q = l * (1 + s)
	} else {
		q = l + s - l*s
	}
	p := 2*l - q
	hue := func(t float64) float64 {
		if t < 0 {
			t += 1
		}
		if t > 1 {
			t -= 1
		}
		switch {
		case t < 1.0/6:
			return p + (q-p)*6*t
		case t < 1.0/2:
			return q
		case t < 2.0/3:
			return p + (q-p)*(2.0/3-t)*6
		default:
			return p
		}
	}
	return hue(h + 1.0/3), hue(h), hue(h - 1.0/3)
}
