// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// 把「设备直送封面」托管到状态中继上,让这台机器**外面**的消费者也能加载它(2026-09-02)。
//
// ## 要修的是什么
//
// 2026-08-31 起 deviceartwork.go 会把 media-control 直送的封面落到本机
// `~/.config/lyrimuse/artwork/<sha>.jpg`,并把 `cover_url` 写成
// `file:///Users/<用户名>/.config/lyrimuse/artwork/<sha>.jpg`。对本机 App 这是纯升级
// (封面身份由"读取时刻"保证,比按文字去网易云/Apple/QQ 猜准得多,见 deviceartwork.go 头注)。
//
// 问题在于这个值被**原样带出了这台机器**:
//
//   - relay.go 的 relayState 把它当 artwork 推给网页。浏览器不可能读别人机器上的本地
//     文件,表现是网页封面整个空白(2026-09-02 用户报「为什么我的网页上没有封面了」)。
//     更隐蔽的是网页那条 iTunes 兜底的闸写的是 `if (!art)` —— `file://…` 是个**非空**
//     字符串,顺利绕过这道闸,于是兜底根本不触发,直接把 file:// 塞进 <img src>。
//   - lb.go 把它写进提交给 ListenBrainz 的 `additional_info.cover_url`。既是彻头彻尾的
//     无用数据,又把本机用户名和目录结构发到了公开的第三方服务上。
//
// 撞上的规模不小:实测本机 90 条曲目的封面是这种形态(占有封面条目的 3.5%),而且**每播
// 一首新歌就多一条** —— 最近在听的那批基本全中,体感就是"网页封面没了"。
//
// ## 为什么是"把图传上去",不是"退回远程封面"
//
// 退回网易云/QQ 那张远程封面看着更省事,但办不到:`resolveTrackEnrichment` 和
// `applyDeviceCoverUpgrade` 都是**直接覆盖** `CoverURL`,而 `coverSwapAllowed` 又规定
// `old.CoverSource == "device"` 一律不再换源 —— 旧的远程封面 URL 已经被永久覆盖掉了
// (核过那 90 条,剩下的 http 链接全是歌曲**页面**链接,一个封面图 URL 都没留)。
//
// 而且就算留着也不该退:设备直送这张才是对版的那张,退回去等于让网页显示一张可能挂错的
// 封面(deviceartwork.go 头注记着 QQ 那张挂错封面的真实案例)。所以走"托管原图":网页和
// App 看到的是同一张,且一定对。
//
// ## 省 KV 写额度是这套设计的硬约束
//
// 中继是 Cloudflare Worker + KV,**免费版 1000 写/天**,而 /push 播放中每几秒就写一次,
// 这份额度本来就紧张(见 state-worker/src/index.js 头注)。所以:
//   - 键是**内容寻址**的(sha = 图内容 sha256 前 8 字节,落盘时就是按它命名的),同一张
//     专辑封面被多首曲目共用只存一份(实测 90 条曲目只对应 31 张图);
//   - 上传前先 HEAD 问一句"传过没有",命中就一个字节都不写(读额度 100k/天,便宜得多);
//   - Worker 侧再兜一层:已存在就直接返回 existed,不写。
//
// 内容寻址还顺带让 GET 可以发 immutable 长缓存,边缘缓存吃掉几乎所有读。

const (
	// artworkRelayPath 跟 state-worker 的路由前缀逐字一致,改一边必须改另一边。
	artworkRelayPath = "/artwork/"
	// artworkMaxUploadBytes 跟 Worker 侧的 ART_MAX_BYTES 对齐。本机实测 31 张图平均
	// 111 KB、最大 238 KB,1 MB 是"明显传错了东西"的量级,不是正常封面会碰到的线。
	artworkMaxUploadBytes = 1024 * 1024
	// artworkUploadRetryAfter:传失败之后多久才准再试。没有这道闸的话,lbMeta 每次轮询
	// (播放中每几秒一次)都会重新排一次上传 —— 中继挂了或者写额度爆了的时候,就成了
	// 每几秒一次的无效重试。
	artworkUploadRetryAfter = 5 * time.Minute
	// artworkSweepGap:启动补传时每张之间的间隔,避免刚起来就对中继来一串并发请求。
	artworkSweepGap = 300 * time.Millisecond
)

// 中继地址/令牌。跟 deviceArtworkDir / enrichPath 一样在 main.go 里一次性设好
// (这个仓库里"进程级单例配置"的既有写法),空串 = 这条功能整体关闭。
var (
	artworkRelayURL   string
	artworkRelayToken string
)

var (
	artworkMu sync.Mutex
	// artworkUploaded 是"这个 sha 在中继上已经确认存在"。进程内存,重启后为空 ——
	// 重启后靠 HEAD 重新确认(便宜),不靠落盘的标记文件(那玩意会跟中继真实状态漂开)。
	artworkUploaded = map[string]bool{}
	artworkInflight = map[string]bool{}
	// artworkNextRetry 是失败后的冷却期,见 artworkUploadRetryAfter。
	artworkNextRetry = map[string]time.Time{}
)

// deviceArtworkRef 认出"这是本机设备直送封面的 file:// URL",并拆出内容 sha 和本地路径。
//
// 判据刻意收得很紧(前缀 + 文件名必须是 16 位十六进制 + 后缀必须是 .jpg/.png),因为
// 认错的代价是不对称的:认不出只是这一张封面在网页上退回 iTunes 兜底,而**误把别的
// file:// 当成设备封面**会把本机路径当 sha 发出去。
func deviceArtworkRef(coverURL string) (sha, path string, ok bool) {
	if !strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		return "", "", false
	}
	path = strings.TrimPrefix(coverURL, deviceArtworkURLPrefix)
	ext := strings.ToLower(filepath.Ext(path))
	if ext != ".jpg" && ext != ".png" {
		return "", "", false
	}
	stem := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	if !isHex16(stem) {
		return "", "", false
	}
	return stem, path, true
}

// isHex16 —— saveDeviceArtwork 用 sha256 前 8 字节命名,十六进制正好 16 位。
func isHex16(s string) bool {
	if len(s) != 16 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func artworkContentType(path string) string {
	if strings.EqualFold(filepath.Ext(path), ".png") {
		return "image/png"
	}
	return "image/jpeg"
}

// artworkPublicURL 是这张图在中继上的对外地址。带后缀纯粹是为了让 URL 看起来像张图
// (有些 unfurler 会看扩展名);Worker 侧解析时会把后缀去掉,真正的类型存在 KV metadata 里。
func artworkPublicURL(sha, path string) string {
	return strings.TrimRight(artworkRelayURL, "/") + artworkRelayPath + sha + strings.ToLower(filepath.Ext(path))
}

// webSafeCoverURL 把一个要**离开这台机器**的 cover_url 换成外面真能加载的形态。
//
// 三条出口,都是刻意的:
//   - 不是 file:// → 原样返回(网易云/Apple/QQ 的远程封面本来就能加载)。
//   - 设备封面且已确认传上去了 → 换成中继上的 https 地址。
//   - 其余一切情况 → **返回空串**。包括"还没传上去"和"认不出的 file://"。
//
// ⚠️ 最后这条是这次修复的核心:宁可让网页暂时没有封面(它自己会退回 iTunes 兜底,
// 见 web/index.html 的 artworkFor),也**绝不能把 file:// 原样透传出去** —— 那正是
// 这个 bug 本身,而且它还会绕过网页那条 `if (!art)` 的兜底闸。
//
// "还没传上去"这一档会顺手把上传排上;下一次推送(播放中每几秒一次)就带上真 URL 了。
func webSafeCoverURL(coverURL string) string {
	if coverURL == "" || !strings.HasPrefix(coverURL, deviceArtworkURLPrefix) {
		return coverURL
	}
	sha, path, ok := deviceArtworkRef(coverURL)
	if !ok || artworkRelayURL == "" {
		return ""
	}
	artworkMu.Lock()
	uploaded := artworkUploaded[sha]
	artworkMu.Unlock()
	if uploaded {
		return artworkPublicURL(sha, path)
	}
	scheduleArtworkUpload(sha, path)
	return ""
}

// scheduleArtworkUpload 起一个后台上传。调用方是 lbMeta(每次轮询都会走到),所以这里
// 必须廉价且幂等:同一个 sha 同时只有一个在飞,失败的进冷却期。
func scheduleArtworkUpload(sha, path string) {
	artworkMu.Lock()
	if artworkInflight[sha] || time.Now().Before(artworkNextRetry[sha]) {
		artworkMu.Unlock()
		return
	}
	artworkInflight[sha] = true
	artworkMu.Unlock()

	go func() {
		err := ensureArtworkUploaded(context.Background(), sha, path)
		artworkMu.Lock()
		delete(artworkInflight, sha)
		if err == nil {
			artworkUploaded[sha] = true
		} else {
			artworkNextRetry[sha] = time.Now().Add(artworkUploadRetryAfter)
		}
		artworkMu.Unlock()
		if err != nil {
			log.Printf("artwork relay: %s 上传失败(%v 内不再重试): %v", sha, artworkUploadRetryAfter, err)
		}
	}()
}

// ensureArtworkUploaded 确保这张图在中继上存在。先 HEAD 后 POST。
//
// ⚠️ HEAD 这一步不是可有可无的优化:artworkUploaded 只活在内存里,重启后是空的,没有
// 这一问的话每次 collector 重启都会把整个 artwork/ 目录重传一遍 —— 而 KV 免费版只有
// 1000 写/天,读却有 100k/天。
func ensureArtworkUploaded(ctx context.Context, sha, path string) error {
	if artworkRelayURL == "" {
		return fmt.Errorf("artwork relay: 未配置中继地址")
	}
	url := artworkPublicURL(sha, path)
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	if req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil); err == nil {
		if resp, err := doHTTPTracked(http.DefaultClient, req); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		// HEAD 本身失败(网络/中继没这个路由)不算错:往下走照样试一次 POST,
		// 真不行会在那边报出来。
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > artworkMaxUploadBytes {
		return fmt.Errorf("artwork %s: %d 字节,不在允许范围内", sha, len(data))
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", artworkContentType(path))
	req.Header.Set("x-token", artworkRelayToken)
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("artwork upload %s: status %d", sha, resp.StatusCode)
	}
	return nil
}

// sweepDeviceArtwork 启动时把 artwork/ 目录里已有的图补传一遍。
//
// 为什么需要它:webSafeCoverURL 那条懒加载只覆盖"接下来又播到的歌"。存量那 90 条曲目
// (31 张图)如果不补,网页上的历史/最近播放会一直缺封面,直到那首歌恰好又被播一次。
//
// 顺序执行 + 每张之间留个间隔:这是启动路径,不该刚起来就对中继来一串并发请求;而且
// 绝大多数轮次里每一张都会在 HEAD 那步命中,整个扫描就是几十次廉价的读。
func sweepDeviceArtwork(ctx context.Context) {
	if artworkRelayURL == "" || deviceArtworkDir == "" {
		return
	}
	entries, err := os.ReadDir(deviceArtworkDir)
	if err != nil {
		return // 目录不存在 = 还没有任何设备封面,不是错误
	}
	uploaded, failed, skipped := 0, 0, 0
	for _, ent := range entries {
		if ctx.Err() != nil {
			return
		}
		if ent.IsDir() {
			continue
		}
		path := filepath.Join(deviceArtworkDir, ent.Name())
		sha, _, ok := deviceArtworkRef(deviceArtworkURLPrefix + path)
		if !ok {
			skipped++
			continue
		}
		artworkMu.Lock()
		done := artworkUploaded[sha]
		artworkMu.Unlock()
		if done {
			continue
		}
		if err := ensureArtworkUploaded(ctx, sha, path); err != nil {
			failed++
			log.Printf("artwork relay: 补传 %s 失败: %v", sha, err)
		} else {
			artworkMu.Lock()
			artworkUploaded[sha] = true
			artworkMu.Unlock()
			uploaded++
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(artworkSweepGap):
		}
	}
	if uploaded > 0 || failed > 0 {
		log.Printf("artwork relay: 启动补传完成(确认 %d 张、失败 %d、跳过 %d)", uploaded, failed, skipped)
	}
}
