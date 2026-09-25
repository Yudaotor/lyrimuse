package main

import (
	"context"
	"encoding/json"
	"fmt"
	"image"
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
// 。Apple Music
// 从 iOS 16 / macOS 13 起给**一部分**专辑配了循环动态封面,资源是公开的,这个文件负责把它找出来
// 记进 enrich 缓存;选档、下载、播放在 App 侧(LyrimuseCore/MotionCoverManifest.swift +
// lyrimuse/MotionCoverStore.swift)。
//
// **发现路径**(全部在 Prince《Timeless》= collectionId 6773830957 上实测):
//
//	GET https://music.apple.com/{storefront}/album/x/{collectionID}
//	  到 <script type="application/json" id="serialized-server-data"> 里是一份标准 JSON(实测 109 KB)
//	  到 …/videoArtwork/dictionary/motionDetailSquare = { "video": <master m3u8>, "previewFrame": {…} }
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
//     的子树里找到 `storeAdamID == 目标 ID` 才认。实测这一页只有 1 个 videoArtwork
//     节点(路径 `data/0/data/sections/0/items/0/videoArtwork`,相关推荐位不带动态封面),这道
//     校验是防将来页面结构变化把邻居专辑的资源喂进来。
//  3. **"查过了但没有"必须落盘**。覆盖率很低(抽 10 张专辑只 3 张有),不记住"这张
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
	// Master:方形(1:1)那份的 master m3u8 地址。App 侧据它选档 到 取 variant 到 下单文件。
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
	// AlbumArtwork:这张专辑在 Apple **目录**里的官方静态封面 URL 模板(同 PreviewFrame 一样带
	// `{w}x{h}bb.{f}` 占位),取自 iTunes lookup 的 artworkUrl100。专辑身份核验用它,见
	// motionCoverAlbumIdentityMatches。按需才查(motionCoverAlbumArtworkFor),不是每张都有。
	//
	// **别改成从专辑页上取**(videoArtwork 同级的那个 `artwork`)。看着是同一页、零成本,
	// 实测它**不一定是专辑封面**:XLOV《I,God》那一格就是动画首帧本身(拿它"核身份"等于把
	// 首帧比对再做一遍),Taylor Swift《folklore》那一格是一张编辑推荐图,只有《Midnights》
	// 碰巧是真封面。目录 lookup 给的才是 Music*/….jpg 那张真正的专辑封面。
	AlbumArtwork string `json:"album_artwork,omitempty"`
	// AlbumArtworkChecked:AlbumArtwork 查过了(查到了、或目录里确实没有都算)。为空而这一位
	// 为 false = 还没查过,不代表没有。
	AlbumArtworkChecked bool `json:"album_artwork_checked,omitempty"`
	// Checked:这个 ID 查过了。见文件头 3。
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

// motionCoverFingerprintMaxDistance:动态封面首帧比对**专用**的阈值,不跟
// `coverFingerprintMaxDistance`(给"设备封面 vs 远程候选"那条链路用,见 coverquality.go)
// 共用——两条链路的"正例该有多松"并不一样,同一个常量服务两个判据只是巧合,不该假设它们
// 必须同步涨跌。
//
// 12 是拿真实动态封面专辑重新量出来的,不是沿用旧值:
//   - 已确认匹配的记录(98 条全量,不是抽样):距离 0～8,均值 2.3;
//   - Apple 官方静态封面 vs 官方动态首帧的干净对照(60 张专辑,不掺我们自己封面源的噪声):
//     54 张里 50 张 ≤10,3 张真的是别的问题(见下)、1 张是 11——跟下面「贴纸/光效」那条
//     独立测到的《Lover》完全一致(两种图源量出来都是 11,不是抽样噪声);
//   - 跨专辑的反例:本机 77 对合成跨专辑对照量到的最小值是 **14**。
//     这一行原来写的是“17(XLOV)起步”—— XLOV《I,God》**不是反例**:两张图是同一张设计,
//     动画首帧是上色版、静态封面是压银浮雕版。也就是说正例(17)跟反例(14 起)在这个
//     度量上**本来就重叠**。所以别再往上调这个阈值去救漏判 —— 它们分不开;
//     这一类靠并联的另一道度量(专辑身份核验)来救,见 decideMotionCover。
//
// 也就是说 0～8 正例、11 是官方给动态首帧叠了贴纸/光效之类装饰(比如 Taylor Swift
// 《Lover》)导致的合理误差、17 起才是真的换错专辑,阈值 12 卡在 11 和 17 中间,比原来的
// 10(卡在 10 和 17 中间,只差 1 就把 11 这一类真实例误杀)更贴合现在看到的数据。
//
// 60 张里另外那 3 张(1 张真反例 + 2 张距离 41 的同一张专辑两个版本)不是阈值能解决的:
// 后两张查出来是 Apple 给这条动态封面做了"揭幕特效"——真实视频前十秒是逐渐聚拢的九宫格
// 拼贴,首帧(=previewFrame)距离静态封面 41,可播到中段(视频时长过半)时已经收拢成跟
// 静态封面逐位相同(距离 0)。这一类"首帧不代表定妆画面"的坑,不管阈值调多大都救不回来
// (41 已经在真实反例的区间里),只能不靠 previewFrame 判——见 fillMotionCover 里
// viaAnchor 那条分支,以及 Swift 侧 MotionCoverStore 下载完之后用视频中段真实帧的终审。
const motionCoverFingerprintMaxDistance = 12

// motionCoverMatchesCover:**这段动画画的就是这张封面吗**(用户提的判据:
// 「可以确保动态的封面就是原本那个匹配到的封面,只是给它扩展成动态吗」)。
//
// 这是这条链路对**文字匹配来的专辑 ID**(见 fillMotionCover 的"来路②")的安全底座,也是它
// 敢把专辑 ID 的来路放宽的唯一原因。之前的做法是"只认已校验的目录锚点、绝不按文字匹配猜
// 专辑",覆盖面因此被压在「Apple Music 播的目录曲目」这一档;而真正要防的从来不是"专辑 ID
// 猜错"本身,是"**画面跟用户看到的封面不是一张**"。直接比图像就把这件事从"身份对不对"
// (靠文字匹配,会错)变成"是不是同一张图"(客观可验)。
//
// 判据复用 `coverquality.go` 那套 8×8 均值哈希,阈值用上面这个专属的
// `motionCoverFingerprintMaxDistance`,校准依据见那个常量的注释。
//
// 返回两位:matched 是比对结论,verified 是"这一轮到底有没有真的比成"。取不到图(网络失败 /
// 模板不认 / 解码失败)时 matched 恒 false、**verified 也是 false**——调用方(fillMotionCover)
// 靠 verified 区分"真的比过、两张图确实不是同一张"(该把结论钉死)和"网络抖了一下,这轮没
// 比成"(不该钉死,得留给下次重试)。之前这两种情况共用同一个 false,取图失败
// 被当成了"没通过"永久写进 MotionCoverChecked,一次 CDN 限流就能把一条本该动的记录永久
// 判成"没有动态封面"——实测 Prince《Musicology》专辑坐实过这个缺口。
func motionCoverMatchesCover(ctx context.Context, previewTmpl, coverURL string) (matched, verified bool) {
	url := motionCoverPreviewSizedURL(previewTmpl)
	if url == "" || coverURL == "" {
		return false, false
	}
	previewImg := loadCoverImage(ctx, url)
	if previewImg == nil {
		return false, false
	}
	coverImg := loadCoverImage(ctx, coverURL)
	if coverImg == nil {
		return false, false
	}
	d, ok := motionCoverSameArtwork(previewImg, coverImg)
	if !ok {
		log.Printf("motion-cover: preview/cover fingerprint distance %d, skipping", d)
		return false, true
	}
	return true, true
}

// motionCoverBorderCrop:第二次机会里四边各去掉多少。
//
// 8% 是量出来的:Apple 给一部分专辑的 previewFrame **四周压了一圈暗角/黑边**,而静态封面
// 没有 —— 同一张图因此被 8×8 均值哈希判成两张(实测 Omar Apollo《Ivory》:原图距离 16,
// 去掉四边 8% 之后是 0)。4% 和 6% 去不干净(6、8),10% / 12% 也行但开始啃掉真实画面。
const motionCoverBorderCrop = 0.08

// motionCoverCroppedMaxDistance:第二次机会的门槛,**比第一次严**。
//
// 别跟 motionCoverFingerprintMaxDistance(12)取齐。多给一次机会就是多一次让真反例
// 蒙混过关的机会,所以第二次必须换来更高的把握。8 是按本机全量量出来的:77 对已确认正例
// 去边后中位 1 / p90 8,77 对跨专辑反例去边后**最小 14** —— 8 落在两者之间,离反例那一侧
// 还有 6 的余量(第一道 12 对反例只有 2)。
const motionCoverCroppedMaxDistance = 8

// motionCoverSameArtwork:这两张图是不是同一张封面。返回判定用的那个距离和结论。
//
// 两道:先整图比,过不了再**把四边各去掉 8% 重比一次**、且门槛收到 8。第二道补的是
// "同一张图、但预览帧多一圈暗角"这一类(见 motionCoverBorderCrop);它救不了、也**不该**
// 救另一类——Apple 给某些专辑的动态封面用的是同一次拍摄的**另一种版式**(满幅原图 vs
// 带标题和曲目表的方版,实测 Taylor Swift《Midnights》:整图 34、去边 36),那跟"换错专辑"
// 在这套判据下数值上分不开,只能维持拒绝。
func motionCoverSameArtwork(previewImg, coverImg image.Image) (int, bool) {
	d := coverFingerprintDistance(coverFingerprint(previewImg), coverFingerprint(coverImg))
	if d <= motionCoverFingerprintMaxDistance {
		return d, true
	}
	c := coverFingerprintDistance(
		coverFingerprint(cropBorderFraction(previewImg, motionCoverBorderCrop)),
		coverFingerprint(cropBorderFraction(coverImg, motionCoverBorderCrop)))
	if c <= motionCoverCroppedMaxDistance {
		return c, true
	}
	return d, false
}

// cropBorderFraction 取中心那块(四边各按比例去掉)。拿不到 SubImage 的实现(理论上的
// 自定义 image.Image)原样返回 —— 那时第二道退化成跟第一道同一个结果,不会误判成"同一张"。
func cropBorderFraction(img image.Image, frac float64) image.Image {
	b := img.Bounds()
	dx, dy := int(float64(b.Dx())*frac), int(float64(b.Dy())*frac)
	if b.Dx()-2*dx < 8 || b.Dy()-2*dy < 8 {
		return img
	}
	type subImager interface {
		SubImage(image.Rectangle) image.Image
	}
	if si, ok := img.(subImager); ok {
		return si.SubImage(image.Rect(b.Min.X+dx, b.Min.Y+dy, b.Max.X-dx, b.Max.Y-dy))
	}
	return img
}

// motionCoverIdentity:专辑身份核验的结果(见 motionCoverAlbumIdentityMatches)。
type motionCoverIdentity int

const (
	motionIdentityNotAsked  motionCoverIdentity = iota // 首帧已经比过了,没必要问
	motionIdentityConfirmed                            // 这条封面就是 Apple 这张专辑的官方封面
	motionIdentityRejected                             // 核过了,不是
	motionIdentityUndecided                            // 这一轮没查成(取图/抓页失败)
)

// motionCoverDecision:这条记录跟这段动画的最终裁决。
type motionCoverDecision int

const (
	motionDecisionPending        motionCoverDecision = iota // 这一轮定不了:什么都不落,留给下一次
	motionDecisionReject                                    // 核对过了,这条不配这段动画
	motionDecisionAccept                                    // 放行;App 侧照常做中段帧终审
	motionDecisionAcceptIdentity                            // 放行;身份已核验,App 侧跳过终审
)

// decideMotionCover:首帧比对、专辑身份核验、专辑 ID 来路三件事合起来,这段动画配不配这条记录。
//
// 两道图像判据是**并联**的,任一道过就放行:
//
//   - **首帧比对**(frameMatched):动画首帧像不像这条记录的封面。便宜、命中率高,但它是个
//     代理判据 —— Apple 把同一张封面做成另一种呈现时它必然判错:满幅原图 vs 带标题曲目表的
//     方版(Taylor Swift《Midnights》,34)、上色版 vs 压银浮雕版(XLOV《I,God》,17)。
//   - **专辑身份核验**(identity):这条记录的封面是不是 Apple 这张专辑的官方封面。它直接回答
//     真正要防的那个问题("专辑 ID 会不会是文字匹配错的"),对动画本身长什么样免疫。身份
//     确认了,动画的归属就没有疑问 —— 所以这一支放行时 App 侧**跳过**中段帧终审
//     (motionDecisionAcceptIdentity):那道终审用的是同一个代理判据,会把刚确认的身份再否掉。
//
// viaAnchor(专辑 ID 来自已校验的目录锚点)时身份本来就确定,两道都没过也放行,但只是
// motionDecisionAccept —— 交给 App 侧用视频中段真实帧终审,治"首帧是揭幕特效"那一类
// (实测 Ariana Grande《Positions (Deluxe)》:首帧距离 41,中段 0)。
//
// 没锚点、首帧没过、身份这一轮又没查成时必须是 Pending 而不是 Reject:Reject 会落
// MotionCoverChecked、从此不再核对,一次抓页失败就会被钉成"这条没有动态封面"。
func decideMotionCover(frameMatched bool, identity motionCoverIdentity, viaAnchor bool) motionCoverDecision {
	switch {
	case frameMatched:
		return motionDecisionAccept
	case identity == motionIdentityConfirmed:
		return motionDecisionAcceptIdentity
	case viaAnchor:
		return motionDecisionAccept
	case identity == motionIdentityUndecided:
		return motionDecisionPending
	default:
		return motionDecisionReject
	}
}

// motionCoverIdentityMaxDistance:专辑身份核验的门槛(整图 8×8 均值哈希,**不给**去边那种
// 第二次机会)。
//
// 这里比的是两张**静态**封面(这条记录在用的那张 vs Apple 官方专辑封面),同一张专辑的两份
// 本该几乎逐位相同。本机实测 132 张专辑:封面 vs **自己**专辑的官方封面中位 0 / p90 2,
// 76 张里 72 张 ≤8;封面 vs **别的**专辑的官方封面最小 12 / 中位 31,132 对里 0 对 ≤8。
// 8 落在两者之间的空档里。别为了救那 4/76 往上调:它们是不同地区/版本的专辑美术
// (陈绮贞几张),而这一支是**放行**动画、还让 App 跳过终审,宁可少救。那几条仍走首帧那一道。
const motionCoverIdentityMaxDistance = 8

// motionCoverAlbumIdentityMatches:这条记录的封面,是不是 Apple 这张专辑的**官方静态封面**。
//
// matched/verified 两态,口径同 motionCoverMatchesCover:取不到图 = verified false(这一轮
// 没核成,别钉死结论)。模板为空(页面上压根没有这张专辑的官方封面)= 核过了、没核上。
func motionCoverAlbumIdentityMatches(ctx context.Context, artworkTmpl, coverURL string) (matched, verified bool) {
	if artworkTmpl == "" {
		return false, true
	}
	if coverURL == "" {
		return false, false
	}
	// 官方封面的模板跟 previewFrame 是同一种 `{w}x{h}bb.{f}` 形态,换真地址用同一个函数。
	official := loadCoverImage(ctx, motionCoverPreviewSizedURL(artworkTmpl))
	if official == nil {
		return false, false
	}
	cover := loadCoverImage(ctx, coverURL)
	if cover == nil {
		return false, false
	}
	d := coverFingerprintDistance(coverFingerprint(official), coverFingerprint(cover))
	if d > motionCoverIdentityMaxDistance {
		log.Printf("motion-cover: album artwork/cover fingerprint distance %d > %d, identity not confirmed",
			d, motionCoverIdentityMaxDistance)
		return false, true
	}
	return true, true
}

// motionCoverIdentityFor:把"取官方封面模板 + 比对"两步合成一个四态结果。
func motionCoverIdentityFor(ctx context.Context, albumID int64, coverURL string) motionCoverIdentity {
	tmpl, done := motionCoverAlbumArtworkFor(ctx, albumID)
	if !done {
		return motionIdentityUndecided
	}
	matched, verified := motionCoverAlbumIdentityMatches(ctx, tmpl, coverURL)
	switch {
	case !verified:
		return motionIdentityUndecided
	case matched:
		return motionIdentityConfirmed
	default:
		return motionIdentityRejected
	}
}

// motionCoverAlbumArtworkFor:取这张专辑在 Apple 目录里的官方静态封面模板(身份核验用)。
//
// 按需才查:只有"这张专辑确有动画、首帧比对又没过"时才走到这里,量级是个位数张专辑,查一次
// 就记进 motion 缓存(AlbumArtworkChecked),不重复问。第二个返回值同 motionCoverFor:
// false = 这一轮没查成(在飞 / 请求失败),调用方别据此钉死结论。
//
// 只补 AlbumArtwork / AlbumArtworkChecked,**不动** Master 等:那些已经被 enrich 记录引用着。
func motionCoverAlbumArtworkFor(ctx context.Context, collectionID int64) (string, bool) {
	if collectionID <= 0 {
		return "", false
	}
	key := fmt.Sprint(collectionID)
	motionCoverMu.Lock()
	c, ok := motionCoverCache[key]
	if !ok {
		// 调用方只在 motionCoverFor 刚给出定论之后才来问,缓存里没有说明被并发清掉了 ——
		// 这一轮别凭空造一条(造出来的条目 Master 为空,会被读成"这张专辑没有动画")。
		motionCoverMu.Unlock()
		return "", false
	}
	if c.AlbumArtworkChecked {
		motionCoverMu.Unlock()
		return c.AlbumArtwork, true
	}
	motionCoverMu.Unlock()

	art, ok := itunesCollectionArtwork(ctx, collectionID, motionCoverStorefront)
	if !ok {
		return "", false
	}
	motionCoverMu.Lock()
	cur, still := motionCoverCache[key]
	if still {
		cur.AlbumArtwork = art
		cur.AlbumArtworkChecked = true
		motionCoverCache[key] = cur
		motionCoverDirty = true
	}
	motionCoverMu.Unlock()
	saveMotionCoverCache()
	return art, true
}

// itunesArtworkSizeRE:Apple artwork URL 尾部那一段尺寸,如 `/100x100bb.jpg`。
var itunesArtworkSizeRE = regexp.MustCompile(`/\d+x\d+bb\.[a-z]+$`)

// itunesCollectionArtwork:一张专辑在 Apple 目录里的官方封面,换成 `{w}x{h}bb.{f}` 模板。
// 第二个返回值 false = 请求失败(这一轮没查成);true 而串为空 = 查到了,但目录里没有这张
// 或没给封面。
//
// 必须核 wrapperType 与 collectionId:同一个 id 空间里还有曲目 / 艺人,拿错了就是拿别的
// 东西的图来核身份。尾部尺寸认不出来时原样保留 —— 100px 的图对 8×8 均值哈希也够用。
func itunesCollectionArtwork(ctx context.Context, collectionID int64, country string) (string, bool) {
	u := fmt.Sprintf("https://itunes.apple.com/lookup?id=%d&country=%s", collectionID, country)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", false
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := doHTTPTracked(&http.Client{Timeout: 6 * time.Second}, req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var out struct {
		Results []itunesCollectionResult `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", false
	}
	return pickCollectionArtwork(out.Results, collectionID), true
}

// itunesCollectionResult:lookup 结果里身份核验要用的那三个字段。
type itunesCollectionResult struct {
	WrapperType   string `json:"wrapperType"`
	CollectionID  int64  `json:"collectionId"`
	ArtworkURL100 string `json:"artworkUrl100"`
}

// pickCollectionArtwork:从 lookup 结果里挑出**这张专辑**的封面并换成模板。纯函数,单测钉着。
func pickCollectionArtwork(results []itunesCollectionResult, collectionID int64) string {
	for _, r := range results {
		if r.WrapperType != "collection" || r.CollectionID != collectionID || r.ArtworkURL100 == "" {
			continue
		}
		if itunesArtworkSizeRE.MatchString(r.ArtworkURL100) {
			return itunesArtworkSizeRE.ReplaceAllString(r.ArtworkURL100, "/{w}x{h}bb.{f}")
		}
		return r.ArtworkURL100
	}
	return ""
}

// motionCoverFreshResultAppliesTo:fresh 的动态封面核对结论,是不是可以挪给一条**已存在**
// 的记录(retainedCoverURL 是它最终留用的那张封面,已经过 coverSwapAllowed 的换封面判定)。
//
// fillMotionCover 比对的是 fresh 自己这一轮解析出来的封面(fresh.CoverURL),不是调用方
// 最终留用的那张——backfillPeripheralFields 的 coverSwapAllowed 完全可能判定"不换封面",
// 这时 retainedCoverURL 还是旧值,fresh 算出来的结论描述的是另一张图,不能挪用:挪了就会
// 把"对着另一张图核对过"的结论错配成"这条记录核对过了",之后 motionCoverWorthBackfill
// 直接放弃、再也不会用这条记录真正在用的封面重新核对(实测 M!LK《Bakuretsu Aishiteru》
// 就是这样卡住的:重新拿它现在的封面去核对,距离只有 1,该匹配上)。
func motionCoverFreshResultAppliesTo(retainedCoverURL string, fresh enrichEntry) bool {
	return fresh.CoverURL == retainedCoverURL
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

// motionCoverWorthBackfill:这条**已存在**的记录值不值得为了动态封面再补一次。
//
// 为什么需要它:`fillMotionCover` 挂在 `resolveTrackEnrichment` 尾巴上,而那个函数对已存在的
// 条目只由 `backfillPeripheralFields` 一条路调用 —— 也就是说存量条目要想拿到 motion 字段,
// 必须先有人**判定它值得补**。不加这一条的话,缓存里已有的条目(本机实测 4820 条,motion 字段
// 一条都没有)永远等不到动态封面,除非删缓存重解析。这是 ls-Alex 交叉核对时点出来的。
//
// **只读缓存、绝不发请求**:它跑在判断"值不值得补"的那一刻、还攥着 enrichMu,联网会把整条
// 播放路径拖住。锁顺序因此是单向的 enrichMu 到 {appleCatalogMu, motionCoverMu} —— 这两个包
// 都不碰 enrichCache/enrichMu(核过),不存在反向嵌套。
//
// 判据是**三态**的,这是关键:
//   - 这条已经有 master 了 到 不用补;
//   - 拿不到已校验的目录专辑 ID(不是 Apple Music 目录曲目 / 锚点还没建立)到 补也补不出来,
//     别浪费那 5 次机会;
//   - motion 缓存里**压根没查过这张专辑** 到 值得补一次(查完就落进下面两态之一);
//   - 查过了:缓存里有 master 到 算缺(等着被写进这条记录);缓存里是"查过了没有" 到 **不算缺**。
//
// 最后那半条是刻意的,理由跟 `missingQQMids` 那条注释同源:动态封面的覆盖率只有三成上下,
// 把"这张专辑就是没有"也算成缺,那七成条目会白重试 5 轮、每轮把开着的歌词源全部重查一遍。
// motionCoverNeedsRecheckAgainstOwnCover:backfillPeripheralFields 跑完这一轮之后,这条
// 记录的动态封面结论是不是**一位都没落下** —— 既没有地址,也没有"查过了"。
//
// 是的话就得拿它自己那张封面补算一次(recheckMotionCoverAgainstCurrentCover),否则它会
// 永远停在"没查过"。这不是罕见分支:`freshApplies`(motionCoverFreshResultAppliesTo)
// 对**设备直送封面**恒为假 —— backfill 给 resolveTrackEnrichment 传的 deviceCoverURL 恒为
// 空串,fresh 解析出来的 cover_url 永远不可能是那张 file:// 图。
//
// 反过来三种情形都不补,免得白发请求:fresh 的结论已经落到这张封面上了、这条已经有动态
// 封面了、这条已经核对过了(那一位存在的全部意义就是防重复核对)。
func motionCoverNeedsRecheckAgainstOwnCover(freshApplies bool, e enrichEntry) bool {
	return !freshApplies && e.MotionCoverURL == "" && !e.MotionCoverChecked
}

// motionCoverAlbumHasKnownVideo:这条记录所属的专辑,**本地缓存里已经确认**有动态封面。
//
// 跟 motionCoverWorthBackfill 的区别只有一处,但正是关键:专辑还没查过时它回 false
// (那个回 true)。所以它**一个请求都不发**,纯查本地两份缓存,可以拿来在全量扫描里筛出
// "值得为它发两次 HTTP"的那一小撮,而不必对整份缓存无差别重验。
func motionCoverAlbumHasKnownVideo(e enrichEntry, title, album string) bool {
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
	return cached && mc.Master != ""
}

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
// 节点确实属于它(见文件头 2)。解析不出来返回零值 + false —— 调用方据此记"这张没有"。
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
	// 这一页 videoArtwork 旁边还挂着一个 `artwork`,**别拿它当专辑封面**,见 AlbumArtwork 字段注释。
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
