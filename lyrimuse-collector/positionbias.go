package main

import (
	"encoding/json"
	"log"
	"math"
	"os"
	"sync"
	"time"
)

// App → collector 的「位置偏置」文件(2026-09-09,用户拍板「collector 复用 App 量出的偏置」)。
//
// Spotify 给歌曲发 now-playing 常晚 ~2s 而 elapsedTime 仍是 0,之后整首歌 MediaRemote 的每笔读数
// 都从这个晚打的锚点外推、恒定落后 ~2s。App 侧(LocalPlaybackSource / SpotifyPositionProbe)开播
// 2.5s 后问一次 Spotify 自己的钟,把量到的差折进整曲偏置 —— 悬浮窗那边由此准了;而这里推给
// 状态中继(网页 / 飞书预览)的 progress 走的是同一条 media-control 外推(playingPositionSecs),
// 该慢多少还慢多少。两边各量一次是重复劳动(再 fork 一个 osascript、结果还可能差几十毫秒),
// 所以由 App 把它量到的偏置写成一个小 JSON,这里每轮读一次、条件全对得上就扣掉。
//
// 文件:~/.config/lyrimuse/lyrimuse-position-bias.json(Swift 侧 PositionBiasFile.fileName,
// 字段名两边逐字节一致,见 positionBiasRecord 的 json tag)。App 在偏置变化时整份原子重写;
// 这边**不删**它 —— 它是状态不是信号(跟 enrich-cancel 那个一次性请求文件不同)。
//
// 什么时候扣(positionBiasApplies,纯函数、有测试):
//   - 同一个播放器、同一首(artist / title 逐字节相等 —— 两边都是 media-control 原始标签,同源);
//   - 偏置对着的锚点还是当前这个锚点(anchor_elapsed 与快照原始 elapsedTime 差 ≤1ms):Spotify
//     暂停 / 拖动后重发的锚点是准的,偏置随之失效 —— 跟 Swift 侧 biasSurvivesAnchor 同一条判据,
//     这样即便 App 还没来得及重写文件,这边也已经停扣;
//   - 偏置是在这个锚点打好**之后**量的(written_at ≥ 锚点时间戳 − 1s):同一首歌隔天再放、锚点又是
//     0@新时刻,旧文件不能再套上;
//   - 文件不超过 6 小时(兜底:App 没在跑时遗留的文件不该永远生效)。
//
// 符号跟 Swift 侧一致:reported = raw − bias,负偏置 = 锚点落后真声,扣掉等于往前补。
type positionBiasRecord struct {
	Artist        string   `json:"artist"`
	Title         string   `json:"title"`
	BundleID      string   `json:"bundle_id"`
	AnchorElapsed *float64 `json:"anchor_elapsed"`
	BiasSecs      float64  `json:"bias_secs"`
	WrittenAtMs   int64    `json:"written_at_ms"`
}

const (
	// 偏置对着的锚点与当前锚点的 elapsedTime 最多差多少还算同一个(与 Swift biasSurvivesAnchor 的 0.001 一致)。
	positionBiasAnchorToleranceSecs = 0.001
	// written_at 允许比锚点时间戳早多少:锚点时间戳只有整秒,App 量偏置最早也在锚点后 ~2.5s,1s 余量足够。
	positionBiasAnchorSlack = time.Second
	// 文件年龄上限(兜底)。
	positionBiasMaxAge = 6 * time.Hour
)

var (
	positionBiasPath string
	positionBiasMu   sync.Mutex
	// 上一次真正扣过的 (key, bias),只用来把日志压成"变化时一行"。
	positionBiasLastLoggedKey  string
	positionBiasLastLoggedBias float64
)

func setPositionBiasPath(path string) {
	positionBiasPath = path
}

// readPositionBiasRecord 读文件;不存在 / 解析失败都当没有(大多数轮次没有 Spotify 在放,文件多半是
// 上一首的,不打日志刷屏)。
func readPositionBiasRecord(path string) (positionBiasRecord, bool) {
	var rec positionBiasRecord
	if path == "" {
		return rec, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return rec, false
	}
	if err := json.Unmarshal(data, &rec); err != nil {
		return rec, false
	}
	return rec, true
}

// positionBiasApplies 判这份记录能不能套在当前这份快照上。纯函数,测试直接覆盖。
// anchorTS 为零值表示快照没有可解析的锚点时间戳 —— 那就没法证明偏置是这个锚点之后量的,不扣。
func positionBiasApplies(rec positionBiasRecord, artist, title, bundleID string, anchorElapsed float64, anchorTS, now time.Time) bool {
	if rec.BiasSecs == 0 || rec.AnchorElapsed == nil {
		return false
	}
	if rec.BundleID != bundleID || rec.Artist != artist || rec.Title != title {
		return false
	}
	if math.Abs(*rec.AnchorElapsed-anchorElapsed) > positionBiasAnchorToleranceSecs {
		return false
	}
	if anchorTS.IsZero() {
		return false
	}
	written := time.UnixMilli(rec.WrittenAtMs)
	if written.Before(anchorTS.Add(-positionBiasAnchorSlack)) {
		return false
	}
	if now.Sub(written) > positionBiasMaxAge || written.After(now.Add(positionBiasAnchorSlack)) {
		return false
	}
	return true
}

// currentPositionBias 给 fetchRawMediaControlState 用:当前快照该扣多少。anchorTSString 是 media-control
// 原始的 timestamp 字段(RFC3339 整秒)。
func currentPositionBias(artist, title, bundleID string, anchorElapsed float64, anchorTSString string, now time.Time) (float64, bool) {
	rec, ok := readPositionBiasRecord(positionBiasPath)
	if !ok {
		return 0, false
	}
	var anchorTS time.Time
	if anchorTSString != "" {
		if t, err := time.Parse(time.RFC3339, anchorTSString); err == nil {
			anchorTS = t
		}
	}
	if !positionBiasApplies(rec, artist, title, bundleID, anchorElapsed, anchorTS, now) {
		return 0, false
	}
	key := artist + "|" + title
	positionBiasMu.Lock()
	changed := key != positionBiasLastLoggedKey || rec.BiasSecs != positionBiasLastLoggedBias
	if changed {
		positionBiasLastLoggedKey, positionBiasLastLoggedBias = key, rec.BiasSecs
	}
	positionBiasMu.Unlock()
	if changed {
		log.Printf("position bias from app: %+.3fs applied to %q (anchor elapsed %.3f)", -rec.BiasSecs, key, anchorElapsed)
	}
	return rec.BiasSecs, true
}
