package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- Apple Music 动态封面(motion artwork)----
//
// 2026-09-09 用户:「帮我看看怎么把我们的封面搞成 applemusic 里面的那种会动的效果」。Apple Music
// 从 iOS 16 / macOS 13 起给**一部分**专辑配了循环动态封面,资源是公开的,这个文件负责把它找出来
// 记进 enrich 缓存;选档、下载、播放在 App 侧(LyrimuseCore/MotionCoverManifest.swift +
// lyrimuse/MotionCoverStore.swift)。
//
// **发现路径**(全部 2026-09-09 在 Prince《Timeless》= collectionId 6773830957 上实测):
//
//	GET https://music.apple.com/{storefront}/album/x/{collectionID}
//	  → <script type="application/json" id="serialized-server-data"> 里是一份标准 JSON(实测 109 KB)
//	  → …/videoArtwork/dictionary/motionDetailSquare = { "video": <master m3u8>, "previewFrame": {…} }
//
// slug 那一段可以直接写死成 `x`——Apple 只按 ID 定位,实测 HTTP 200。不需要 developer token、
// cookie、Referer;返回的 master m3u8 同样是公开的(见 MotionCoverManifest 头注里的实测清单)。
// 另有 `tallVideoArtwork`(3:4 竖版 `motionDetailTall`),我们只要方的那份。
//
// **三个必须守住的边界**:
//
//  1. **只按目录专辑 ID 查,不按文字匹配**。ID 来自已校验的 Apple 目录锚点
//     (`appleCatalogAlbumIDFor`,即 media-control 那个 uniqueIdentifier 经 iTunes lookup 拿到的
//     collectionId)。刻意**不**退到"用 artist/album 去 iTunes search 猜一个专辑 ID"——那正是
//     03 章反复踩过的"同名不同版本"坑,而这里猜错的后果是**给这首歌配上另一张专辑的动态封面**,
//     比没有动态封面糟得多。代价是覆盖面收在"Apple Music 播放目录曲目"这一档,这是刻意的。
//  2. **拿到的节点要属于目标专辑**。`parseMotionCover` 找到 `videoArtwork` 之后,还要在它父节点
//     的子树里找到 `storeAdamID == 目标 ID` 才认。2026-09-09 实测这一页只有 1 个 videoArtwork
//     节点(路径 `data/0/data/sections/0/items/0/videoArtwork`,相关推荐位不带动态封面),这道
//     校验是防将来页面结构变化把邻居专辑的资源喂进来。
//  3. **"查过了但没有"必须落盘**。覆盖率很低(2026-09-09 抽 10 张专辑只 3 张有),不记住"这张
//     没有"的话同一专辑的每首歌都会重抓一次 330 KB 的页面。所以缓存条目用 `Checked` 标记而
//     不是"有值才存"——跟 `appleCatalogMisses` 那条"刻意不落盘"相反,理由也不同:那边查空可能
//     只是网络抖动,而"这张专辑没做动态封面"是个稳定事实。Apple 后来补做了怎么办?删掉缓存
//     文件重来即可(它跟 apple-catalog 那份一样是纯派生数据)。
const (
	// motionCoverStorefront:查哪个商店。跟 appleCatalogLookup 的 `country=cn` 保持一致 ——
	// 同一台机器上这两条路描述的是同一个用户的同一个 Apple 商店,分开配只会漂。
	motionCoverStorefront = "cn"
	// motionCoverTimeout:抓一次专辑页的超时。页面实测 330 KB,给得比 lookup(5s)宽一档。
	motionCoverTimeout = 12 * time.Second
	// motionCoverMaxPageBytes:页面读取上限。正常 ~330 KB,留一个数量级余量;超了就当解析失败,
	// 免得某天 Apple 返回一个巨大的东西把内存吃掉。
	motionCoverMaxPageBytes = 8 << 20
)

// motionCover:一张专辑的动态封面资源。空 Master + Checked=true 表示"查过了,这张没有"。
type motionCover struct {
	// Master:方形(1:1)那份的 master m3u8 地址。App 侧据它选档 → 取 variant → 下单文件。
	// 刻意存 master 而不是直接存最终那个 .mp4:选哪一档取决于**要画多大**,那是 App 才知道的事。
	Master string `json:"master,omitempty"`
	// PreviewFrame:静态首帧图的 URL **模板**(尾部带 `{w}x{h}bb.{f}` 占位,跟 Apple 的 artwork
	// URL 同一种形态)。两个用处:动态封面还没下好时先铺这一帧;以及它本身就是一张按专辑 ID
	// 精确定位的高清静态封面(实测 3840²,`1200x1200bb.jpg` 226 KB / `3840x3840bb.jpg` 2.65 MB),
	// 比 03 章那条"按歌名在缓存里匹配"的高清替代更权威。
	PreviewFrame string `json:"preview_frame,omitempty"`
	// BgColor / TextColor1:Apple 给这张封面的官方配色(十六进制,不带 #)。项目现在的强调色是
	// 自己算均值(03 章第 4 节),这两个值留着给将来校准用,现在只记不用。
	BgColor   string `json:"bg_color,omitempty"`
	TextColor string `json:"text_color,omitempty"`
	// Checked:这个 ID 查过了。见文件头 ⚠️ 3。
	Checked bool `json:"checked"`
}

var (
	motionCoverMu       sync.Mutex
	motionCoverCache    = map[string]motionCover{} // key = 十进制 collection id
	motionCoverPath     string                     // 空 = 只用内存(单测/一次性子命令)
	motionCoverDirty    bool
	motionCoverInflight = map[int64]bool{}
)

// loadMotionCoverCache / saveMotionCoverCache:整份 map 序列化 + 临时文件原子改名,跟
// loadAppleCatalogCache 同一套。
func loadMotionCoverCache(path string) {
	motionCoverMu.Lock()
	motionCoverPath = path
	motionCoverMu.Unlock()
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var m map[string]motionCover
	if err := json.Unmarshal(data, &m); err == nil && m != nil {
		motionCoverMu.Lock()
		motionCoverCache = m
		motionCoverMu.Unlock()
		withMotion := 0
		for _, v := range m {
			if v.Master != "" {
				withMotion++
			}
		}
		log.Printf("cache: loaded %d motion-cover entries (%d with video) from %s", len(m), withMotion, path)
	}
}

func saveMotionCoverCache() {
	motionCoverMu.Lock()
	if !motionCoverDirty || motionCoverPath == "" {
		motionCoverMu.Unlock()
		return
	}
	data, err := json.Marshal(motionCoverCache)
	motionCoverDirty = false
	path := motionCoverPath
	motionCoverMu.Unlock()
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
	}
}

// motionCoverFor:取这张专辑的动态封面资源。缓存命中(包括"查过了没有")直接返回,不发请求。
//
// 第二个返回值是"这个 ID 已经有定论"——`false` 表示这一轮没查成(在飞、或者请求失败),调用方
// 该原样跳过,下一首歌再试。
func motionCoverFor(collectionID int64) (motionCover, bool) {
	if collectionID <= 0 {
		return motionCover{}, false
	}
	key := fmt.Sprint(collectionID)
	motionCoverMu.Lock()
	if c, ok := motionCoverCache[key]; ok {
		motionCoverMu.Unlock()
		return c, true
	}
	if motionCoverInflight[collectionID] {
		motionCoverMu.Unlock()
		return motionCover{}, false
	}
	motionCoverInflight[collectionID] = true
	motionCoverMu.Unlock()

	defer func() {
		motionCoverMu.Lock()
		delete(motionCoverInflight, collectionID)
		motionCoverMu.Unlock()
	}()

	page, err := fetchAlbumPage(collectionID)
	if err != nil {
		// 请求失败**不写缓存**:跟"这张没有"是两件事,下次还该再试。
		log.Printf("motion-cover: album %d fetch failed: %v", collectionID, err)
		return motionCover{}, false
	}
	mc, _ := parseMotionCover(page, key)
	mc.Checked = true

	motionCoverMu.Lock()
	motionCoverCache[key] = mc
	motionCoverDirty = true
	motionCoverMu.Unlock()
	// 立刻落盘,跟 appleCatalogLookup 一样:这份缓存最重要的作用是"别为同一张专辑反复抓
	// 330 KB 的页面",进程被杀之前没写盘就白查了。
	saveMotionCoverCache()
	if mc.Master != "" {
		log.Printf("motion-cover: album %d has motion artwork", collectionID)
	}
	return mc, true
}

// motionCoverPreviewSide:拿首帧去比指纹时用的边长。
//
// 600 不是随手取的:aHash 之前先被 loadCoverImage 降到 64px 见方,再大只是白下字节;而 600
// 又是这个项目里各源封面的常见档(网易云 800 / QQ 800 / Apple 600),同档比同档最稳。
const motionCoverPreviewSide = 600

// motionCoverPreviewSizedURL 把 previewFrame 的模板换成真地址。
//
// Apple 给的是 `…/{w}x{h}bb.{f}` 这种占位模板(跟它的 artwork URL 同一种形态)。模板不认就
// 原样返回 —— 调用方拿它去下载,下不到就当校验失败,不会误判成"同一张"。
func motionCoverPreviewSizedURL(tmpl string) string {
	if tmpl == "" {
		return ""
	}
	side := fmt.Sprint(motionCoverPreviewSide)
	r := strings.NewReplacer("{w}", side, "{h}", side, "{f}", "jpg")
	return r.Replace(tmpl)
}

// motionCoverMatchesCover:**这段动画画的就是这张封面吗**(2026-09-10,用户提的判据:
// 「可以确保动态的封面就是原本那个匹配到的封面,只是给它扩展成动态吗」)。
//
// 这是整条链路的**安全底座**,也是它敢把专辑 ID 的来路放宽的唯一原因。之前的做法是"只认
// 已校验的目录锚点、绝不按文字匹配猜专辑",覆盖面因此被压在「Apple Music 播的目录曲目」
// 这一档;而真正要防的从来不是"专辑 ID 猜错"本身,是"**画面跟用户看到的封面不是一张**"。
// 直接比图像就把这件事从"身份对不对"(靠文字匹配,会错)变成"是不是同一张图"(客观可验)。
//
// 判据复用 `coverquality.go` 那套 8×8 均值哈希 + `coverFingerprintMaxDistance`(10)——
// 它的阈值本来就是拿真实封面校准出来的(正例 0、反例 17～39)。2026-09-10 用 5 张真有动态
// 封面的专辑又量了一遍,数据比校准时更宽松:
//
//	首帧 vs Apple 标准封面        距离 1 / 2 / 2 / 1
//	首帧 vs 我们实际显示那张(网易云) 距离 1 / 3 / 2   ← **跨源同样成立**
//	跨专辑对照(16 组)             距离 19 … 34
//
// 也就是说 3 ↔ 19 之间是空的,阈值 10 落在空隙正中。跨源那三行尤其关键:我们实际铺的封面
// 多半来自网易云或 QQ,而它跟 Apple 的首帧仍然判为同一张。
//
// 取不到图(网络失败 / 模板不认 / 解码失败)一律返回 false —— 宁可这首没有动态封面,也不能
// 在没核对过的情况下放行。
func motionCoverMatchesCover(ctx context.Context, previewTmpl, coverURL string) bool {
	url := motionCoverPreviewSizedURL(previewTmpl)
	if url == "" || coverURL == "" {
		return false
	}
	previewImg := loadCoverImage(ctx, url)
	if previewImg == nil {
		return false
	}
	coverImg := loadCoverImage(ctx, coverURL)
	if coverImg == nil {
		return false
	}
	d := coverFingerprintDistance(coverFingerprint(previewImg), coverFingerprint(coverImg))
	if d > coverFingerprintMaxDistance {
		log.Printf("motion-cover: preview/cover fingerprint distance %d > %d, skipping",
			d, coverFingerprintMaxDistance)
		return false
	}
	return true
}

// motionCoverAlbumIDFromAppleURL 从 enrich 记下的 apple_music_url 里抠出专辑 ID。
//
// 形态(本机缓存实测,2934 条里 100% 是这个样子):
//
//	https://music.apple.com/cn/album/aim-high/1474635060?i=1474635079&uo=4
//	                                          ^^^^^^^^^^ collectionId
//
// 这条路是给**非 Apple Music 播放器**用的:那些歌拿不到 media-control 的 uniqueIdentifier
// 锚点,但只要 collector 解析歌词时给它匹配上了 Apple 条目,这个链接就在。它的可信度不如
// 目录锚点(来自 searchAppleMusicMatch 的文字匹配,03 章决策 #16 那次错位就是它),所以
// **必须**配 motionCoverMatchesCover 那道图像校验才能用 —— 单独用它会把错配带进动画。
func motionCoverAlbumIDFromAppleURL(appleURL string) int64 {
	m := appleAlbumIDInURLRE.FindStringSubmatch(appleURL)
	if len(m) != 2 {
		return 0
	}
	id, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil || !appleCatalogPlausibleID(id) {
		return 0
	}
	return id
}

var appleAlbumIDInURLRE = regexp.MustCompile(`/album/[^/]*/(\d+)`)

// motionCoverWorthBackfill:这条**已存在**的记录值不值得为了动态封面再补一次(2026-09-09)。
//
// 为什么需要它:`fillMotionCover` 挂在 `resolveTrackEnrichment` 尾巴上,而那个函数对已存在的
// 条目只由 `backfillPeripheralFields` 一条路调用 —— 也就是说存量条目要想拿到 motion 字段,
// 必须先有人**判定它值得补**。不加这一条的话,缓存里已有的条目(本机实测 4820 条,motion 字段
// 一条都没有)永远等不到动态封面,除非删缓存重解析。这是 ls-Alex 2026-09-09 交叉核对时点出来的。
//
// **只读缓存、绝不发请求**:它跑在判断"值不值得补"的那一刻、还攥着 enrichMu,联网会把整条
// 播放路径拖住。锁顺序因此是单向的 enrichMu → {appleCatalogMu, motionCoverMu} —— 这两个包
// 都不碰 enrichCache/enrichMu(核过),不存在反向嵌套。
//
// 判据是**三态**的,这是关键:
//   - 这条已经有 master 了 → 不用补;
//   - 拿不到已校验的目录专辑 ID(不是 Apple Music 目录曲目 / 锚点还没建立)→ 补也补不出来,
//     别浪费那 5 次机会;
//   - motion 缓存里**压根没查过这张专辑** → 值得补一次(查完就落进下面两态之一);
//   - 查过了:缓存里有 master → 算缺(等着被写进这条记录);缓存里是"查过了没有" → **不算缺**。
//
// 最后那半条是刻意的,理由跟 `missingQQMids` 那条注释同源:动态封面的覆盖率只有三成上下,
// 把"这张专辑就是没有"也算成缺,那七成条目会白重试 5 轮、每轮把开着的歌词源全部重查一遍。
func motionCoverWorthBackfill(e enrichEntry, title, album string) bool {
	if e.MotionCoverURL != "" || e.MotionCoverChecked {
		return false
	}
	// 两条来路跟 fillMotionCover 一致(锚点优先、退到 apple_music_url),否则非 Apple Music
	// 播的存量条目连 backfill 的门都进不来。
	albumID, ok := appleCatalogAlbumIDFor(title, album)
	if !ok {
		albumID = motionCoverAlbumIDFromAppleURL(e.AppleURL)
	}
	if albumID <= 0 {
		return false
	}
	motionCoverMu.Lock()
	defer motionCoverMu.Unlock()
	mc, cached := motionCoverCache[fmt.Sprint(albumID)]
	if !cached {
		return true
	}
	return mc.Master != ""
}

func fetchAlbumPage(collectionID int64) ([]byte, error) {
	u := fmt.Sprintf("https://music.apple.com/%s/album/x/%d", motionCoverStorefront, collectionID)
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	// 这一页对 UA 敏感:裸 Go 默认 UA 拿回来的是另一套(实测阶段用的是 Safari 串),照抄一份
	// 桌面 Safari 的 UA,拿到的就是网页版真正渲染用的那份 serialized-server-data。
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "+
		"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
	resp, err := doHTTPTracked(&http.Client{Timeout: motionCoverTimeout}, req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("http %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, motionCoverMaxPageBytes))
}

// serializedServerData:那段内嵌 JSON 的定位。刻意用最窄的一条正则只把 script 的内容抠出来,
// 之后一律交给 encoding/json —— 页面里的 JSON 字符串带 `/` 这类转义,自己拿正则去抠字段
// 值会踩转义(实测原文里 URL 的斜杠全是 `/`)。
var serializedServerDataRE = regexp.MustCompile(
	`(?s)<script type="application/json" id="serialized-server-data">(.*?)</script>`)

// parseMotionCover 从专辑页里解出方形动态封面。wantID 是目标专辑的十进制 ID,用来确认拿到的
// 节点确实属于它(见文件头 ⚠️ 2)。解析不出来返回零值 + false —— 调用方据此记"这张没有"。
func parseMotionCover(page []byte, wantID string) (motionCover, bool) {
	m := serializedServerDataRE.FindSubmatch(page)
	if m == nil {
		return motionCover{}, false
	}
	var root any
	if err := json.Unmarshal(m[1], &root); err != nil {
		return motionCover{}, false
	}
	node := findVideoArtwork(root, wantID)
	if node == nil {
		return motionCover{}, false
	}
	dict, _ := node["dictionary"].(map[string]any)
	sq, _ := dict["motionDetailSquare"].(map[string]any)
	video, _ := sq["video"].(string)
	if video == "" {
		return motionCover{}, false
	}
	out := motionCover{Master: video}
	if pf, ok := sq["previewFrame"].(map[string]any); ok {
		out.PreviewFrame, _ = pf["url"].(string)
		out.BgColor, _ = pf["bgColor"].(string)
		out.TextColor, _ = pf["textColor1"].(string)
	}
	return out, true
}

// findVideoArtwork:在整棵 JSON 里找 `videoArtwork`,并要求它**属于** wantID 那张专辑 ——
// 判据是"从根到它的路径上,某个祖先的子树里出现了 storeAdamID == wantID"。
//
// 实现成"先找到候选的父节点、再在父节点子树里搜 ID",而不是照着
// `data/0/data/sections/0/items/0/videoArtwork` 这条实测路径硬走:那条路径是这一版页面的样子,
// 写死等于把解析绑在 Apple 的前端结构上。
func findVideoArtwork(root any, wantID string) map[string]any {
	var found map[string]any
	var walk func(v any)
	walk = func(v any) {
		if found != nil {
			return
		}
		switch t := v.(type) {
		case map[string]any:
			if va, ok := t["videoArtwork"].(map[string]any); ok && len(va) > 0 {
				// t 是 videoArtwork 的父节点(那个 item)。它的子树里该带着自己的专辑 ID。
				if subtreeHasAdamID(t, wantID) {
					found = va
					return
				}
			}
			for _, x := range t {
				walk(x)
			}
		case []any:
			for _, x := range t {
				walk(x)
			}
		}
	}
	walk(root)
	return found
}

// subtreeHasAdamID:子树里有没有 `storeAdamID == want`(Apple 的 JSON 里它是字符串)。
// 顺带认 `id` —— 同一份数据里两个键都出现过,认一个漏一个不值得。
func subtreeHasAdamID(v any, want string) bool {
	switch t := v.(type) {
	case map[string]any:
		for k, x := range t {
			if (k == "storeAdamID" || k == "id") && x == any(want) {
				return true
			}
			if subtreeHasAdamID(x, want) {
				return true
			}
		}
	case []any:
		for _, x := range t {
			if subtreeHasAdamID(x, want) {
				return true
			}
		}
	}
	return false
}
