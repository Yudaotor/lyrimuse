// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"flag"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const (
	clientName    = "applemusic-nowplaying"
	clientVersion = "0.1.0"

	pollInterval      = 5 * time.Second
	playingNowRefresh = 60 * time.Second
	// 未缓存新歌:开播时挂起首条 playing_now,最多等这么久让 enrich 解析出歌词再发
	// (LB 只认换曲那条,歌词须在首条;enrichNotify 通常更早触发)。
	pnPendingMax = 8 * time.Second
	// media-control 连续读空(nullStreak≥3)会被当作"停播"清空当前曲目、终结 session；若这其实
	// 只是短暂假死、同一首歌很快又重新读到,在这个宽限期内续接旧 session(而非清零重开),避免
	// 一次连续收听被假死切成两段、各自达到阈值后向 LB 提交两条 listen。
	nullResumeGraceWindow = 60 * time.Second
	submitTimeout         = 15 * time.Second
	// 单次提交超时：playing_now 失败无妨(≤playingNowRefresh 会再发)，快超时保持 poll 循环
	// 灵敏(暂停/切歌能及时反映)；single(完成收听)丢了就永久少一条，用更长超时并重试。
	playingNowTimeout = 8 * time.Second
	singleTimeout     = 12 * time.Second
	singleMaxTries    = 2
	// Ignore accrual gaps larger than this (sleep, stream restarts).
	maxAccrualGapSecs = 60.0
	// Standard scrobble rule: half the track or 4 minutes, whichever is less.
	listenCapSecs = 240.0
	// Tracks shorter than this are never submitted as listens.
	minTrackSecs = 30.0
	// LB rejects any single listen larger than 10240 bytes. Lyrics (esp. word-level
	// yrc) are the only large fields; cap their combined size well under that, with
	// room left for cover/links/progress + JSON overhead.
	lyricBudgetBytes = 8000
)

func main() {
	log.SetFlags(log.LstdFlags)
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("resolve home dir: %v", err)
	}
	cfgPath := flag.String("config", filepath.Join(home, ".config", clientName, "config.json"), "config file path")
	dryRun := flag.Bool("dry-run", false, "log submissions instead of calling ListenBrainz")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if cfg.Token == "" && !*dryRun {
		log.Fatalf("missing ListenBrainz token: set listenbrainz_token in %s or LISTENBRAINZ_TOKEN env", *cfgPath)
	}
	// 曲目元信息缓存落盘在 config 同目录，重启后不重解析同一首歌。
	loadEnrichCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cache.json"))
	forwardedPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-forwarded.json")
	lfmMirroredPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-mirrored.json")
	weeklyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lastfm-weekly.json")

	lb := &lbClient{root: cfg.APIRoot, token: cfg.Token, hc: &http.Client{}, dryRun: *dryRun, alerter: newAlerter(cfg.BarkURL)}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("%s %s starting (media-control: %s, bundles: %v, dry-run: %v)",
		clientName, clientVersion, cfg.MediaControlPath, cfg.BundleIDs, *dryRun)
	if err := run(ctx, cfg, lb); err != nil && ctx.Err() == nil {
		log.Fatalf("run: %v", err)
	}
}
