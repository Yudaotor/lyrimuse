package main

import (
	"context"
	"image"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// 封面图本身的尺寸。地址里写着尺寸的(coverURLIntendedEdge 读得出)用不着它;读不出时(网易云曲库里的原图地址、
// Amazon 的 `_SX500_`、别的不带尺寸段的地址)取图头量一次短边,解出宽高就停,不下载整张图;本机文件(设备封面)
// 直接读。同一个地址给的图不变,量出来的按地址记在内存里,量不出的不记、下次再量。见 03 章决策 35。

const (
	// coverHeaderMaxBytes:量尺寸最多读这么多。JPEG 的宽高在 SOF 段,前面的 EXIF / ICC 段偶尔有几十 KB。
	coverHeaderMaxBytes = 512 << 10
	// coverEdgeMemoMax:记下的地址到这么多就整份清掉重记。
	coverEdgeMemoMax = 4096
)

var (
	coverEdgeMu   sync.Mutex
	coverEdgeMemo = map[string]int{}
)

// coverActualEdge:这张封面图的短边(像素),量不出返回 0。远程图要发一次请求,调用方不能持着 enrichMu。
func coverActualEdge(ctx context.Context, coverURL string) int {
	coverEdgeMu.Lock()
	n, ok := coverEdgeMemo[coverURL]
	coverEdgeMu.Unlock()
	if ok {
		return n
	}
	if n = measureCoverEdge(ctx, coverURL); n > 0 {
		coverEdgeMu.Lock()
		if len(coverEdgeMemo) >= coverEdgeMemoMax {
			coverEdgeMemo = map[string]int{}
		}
		coverEdgeMemo[coverURL] = n
		coverEdgeMu.Unlock()
	}
	return n
}

func measureCoverEdge(ctx context.Context, coverURL string) int {
	var r io.Reader
	switch {
	case strings.HasPrefix(coverURL, deviceArtworkURLPrefix):
		f, err := os.Open(strings.TrimPrefix(coverURL, deviceArtworkURLPrefix))
		if err != nil {
			noteFileErr("read", strings.TrimPrefix(coverURL, deviceArtworkURLPrefix), err)
			return 0
		}
		defer f.Close()
		r = f
	case strings.HasPrefix(coverURL, "https://"), strings.HasPrefix(coverURL, "http://"):
		cli := &http.Client{Timeout: 4 * time.Second}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, coverURL, nil)
		if err != nil {
			return 0
		}
		req.Header.Set("Referer", coverRequestReferer(coverURL))
		req.Header.Set("User-Agent", "Mozilla/5.0")
		resp, err := doHTTPTracked(cli, req)
		if err != nil {
			return 0
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return 0
		}
		r = resp.Body
	default:
		return 0
	}
	cfg, _, err := image.DecodeConfig(io.LimitReader(r, coverHeaderMaxBytes))
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 {
		return 0
	}
	return min(cfg.Width, cfg.Height)
}

// deviceCoverSmall:这张设备封面(本机文件)短边不到 deviceCoverTrustedMinEdge,值得找同一张图的清晰版。读的是图头,
// 量过的记着;不是本机文件、读不出的算不小。
func deviceCoverSmall(coverURL string) bool {
	if !strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		return false
	}
	n := coverActualEdge(context.Background(), coverURL)
	return n > 0 && n < deviceCoverTrustedMinEdge
}
