// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"context"
	"image"
	"log"
	"strings"
)

// 设备直送封面的「清晰度」判据(2026-09-02)。
//
// ## 要修的是什么
//
// 用户报「这首歌这里的封面这么糊清晰度很低」(Bruno Mars 的《24K Magic》)。查出来的形态
// 很干净 —— **同一张专辑的其它 8 首都是 800×800,只有标题曲拿到了一张 120×120**:
//
//	Bruno Mars|24K Magic|24K Magic          cover_source=device   本地 file://…,120×120、7 KB
//	Bruno Mars|Chunky|24K Magic             cover_source=netease  …?param=800y800
//	Bruno Mars|Finesse|24K Magic            cover_source=netease  …?param=800y800
//	(其余 6 首同上)
//
// 歌词窗口那个槽位在 Retina 下要画到 ~560px,120px 放大约 4.7 倍,就是那个糊。
//
// 成因是两条刻意的设计叠在一起:
//  1. `deviceArtworkMinEdge = 64` —— 下限故意压得很低,注释里写明了理由:「Arc/Edge 播
//     Apple Music 网页版时 MediaSession 实际上送的封面就是 120x120,收紧到 200 就是在挡
//     真实数据」。所以浏览器给的小缩略图会被照单收下。
//  2. `resolveTrackEnrichment` 里设备封面**无条件顶掉**网易云/Apple/QQ/同专辑邻居那一整套
//     结果,`coverSwapAllowed` 又规定 `cover_source == "device"` 一律不再换源 —— 于是这张
//     120×120 **永远不会被自动替换**。
//
// ## ⚠️ 为什么不能简单地"分辨率不够就不用设备封面"
//
// 那会把 8-31 那个功能**要修的 bug 放回来**。原案例(Michael Jackson《Workin' Day and
// Night (Immortal Version)》)里,设备给的那张 120×120 是**对的**,而 QQ 那张高清图是
// **挂错的**(QQ 自己那张专辑记录挂成了另一张专辑的封面,25 首曲目全部同一个错 URL)。
// 单看分辨率就选,等于每次都把对的换成错的。
//
// ## 所以判据是"两张图是不是同一张",不是"谁更大"
//
// 设备封面的价值在**身份**(它就是这一刻这个 App 自己吐出来的,不靠文字匹配去猜);
// 远程候选的价值在**分辨率**。两者不冲突的前提是它们其实是同一张图 —— 那就该拿高清那份。
// 于是:
//
//	设备图边长 >= deviceCoverTrustedMinEdge          → 直接顶掉(快路径,不取图不比较)
//	没有远程候选                                     → 直接顶掉(没有更好的选择)
//	远程候选不比设备图大                             → 直接顶掉(换了也没好处)
//	两张图**感知上是同一张**                         → **保留远程那份高清**(既对版又清晰)
//	两张图不一样                                     → 顶掉(身份优先,认这个糊 —— Immortal 那档)
//
// 最后两条正是这次修复的全部内容:把"谁对"和"谁清晰"这两件事分开判,而不是让一条规则
// 同时承担两个互相矛盾的职责。
//
// 代价:设备图偏小、且存在远程候选时,多一次取图 + 一次 8×8 指纹比较。只发生在换曲那一刻
// (deviceCoverURL 非空只在 poller 确认新曲目时,见 resolveTrackEnrichment 参数注释),
// 而那一轮本来就要取一次图算主色。

// deviceCoverTrustedMinEdge:设备直送封面达到这个边长就直接采信、不再跟远程候选比。
//
// 300 的来处:歌词窗口那张大卡在 Retina 下画到 ~560px,而这个项目存下来的 QQ 封面是
// 800×800(见 color.go 里 qqCoverAtEdge 那段注释,"歌词窗口那张大卡要的")。300 往上
// 放大不到 2 倍,肉眼已经不构成"糊"这个投诉;120 那一档放大 4.7 倍才是问题。
// 刻意**不**设成 560:那会让一大批本来够用的设备封面白白多走一次取图+比较。
const deviceCoverTrustedMinEdge = 300

// coverFingerprintSide:指纹的边长。8×8 = 64 个灰度均值,是 aHash 的标准尺寸 ——
// 对"同一张图、不同分辨率/不同 JPEG 质量"极其稳定(实测见 coverquality_test.go 里那组
// 真实数据),对"两张不同的封面"又分得很开。
const coverFingerprintSide = 8

// coverFingerprintMaxDistance:判"同一张图"的汉明距离上限(满分 64)。
//
// ⚠️ 这个值是**拿真实数据校准出来的**,不是拍脑袋(2026-09-02):
//   - 正例:用户那张 120×120 的设备封面 vs 同专辑邻居的网易云 800×800(同一张图)
//     → 距离 **0**(指纹逐位相同,尽管一张 120px、另一张被 loadCoverImage 降到 64px ——
//     这也正是 coverFingerprint 必须用箱式取平均、不能取最近邻的实证)
//   - 反例:缓存里随机抽的 8 张真实的**其它专辑**封面 → 距离 **17 … 39**,无一误判
//
// 两档之间有巨大的空隙(0 ↔ 17),10 落在空隙里、离正例 10、离最近的反例 7,不是卡在某个
// 样本边上的脆弱阈值。
const coverFingerprintMaxDistance = 10

// coverFingerprint 算 aHash:缩到 8×8 灰度,每格跟全图均值比,大于均值置 1。
//
// 缩放用**箱式取平均**(把源图按格子切块、块内所有像素取平均),不是取最近邻单点 ——
// 后者对高分辨率图只采 64 个像素点,同一张图的 120px 版和 800px 版会采到完全不同的
// 内容,距离飘得没法用。
func coverFingerprint(img image.Image) uint64 {
	if img == nil {
		return 0
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= 0 || h <= 0 {
		return 0
	}
	cells := make([]float64, coverFingerprintSide*coverFingerprintSide)
	for cy := 0; cy < coverFingerprintSide; cy++ {
		for cx := 0; cx < coverFingerprintSide; cx++ {
			x0 := b.Min.X + w*cx/coverFingerprintSide
			x1 := b.Min.X + w*(cx+1)/coverFingerprintSide
			y0 := b.Min.Y + h*cy/coverFingerprintSide
			y1 := b.Min.Y + h*(cy+1)/coverFingerprintSide
			// 边长小于 8 时某些格子会退化成空区间,至少取一个像素。
			if x1 <= x0 {
				x1 = x0 + 1
			}
			if y1 <= y0 {
				y1 = y0 + 1
			}
			var sum float64
			var n float64
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					r, g, bb, _ := img.At(x, y).RGBA()
					// Rec. 601 亮度,跟 dominantColorFromImage 那边取灰度的口径无关
					// (那个算主色、这个算结构),各自独立。
					sum += 0.299*float64(r>>8) + 0.587*float64(g>>8) + 0.114*float64(bb>>8)
					n++
				}
			}
			if n > 0 {
				cells[cy*coverFingerprintSide+cx] = sum / n
			}
		}
	}
	var mean float64
	for _, v := range cells {
		mean += v
	}
	mean /= float64(len(cells))
	var hash uint64
	for i, v := range cells {
		if v > mean {
			hash |= 1 << uint(i)
		}
	}
	return hash
}

// coverFingerprintDistance 是两个指纹的汉明距离(0…64)。
func coverFingerprintDistance(a, b uint64) int {
	x := a ^ b
	n := 0
	for x != 0 {
		x &= x - 1
		n++
	}
	return n
}

// coverImagesLikelySame:两张图感知上是不是同一张封面。
func coverImagesLikelySame(a, b image.Image) bool {
	if a == nil || b == nil {
		return false
	}
	fa, fb := coverFingerprint(a), coverFingerprint(b)
	// 全 0 / 全 1 是退化指纹(纯色图、或者算失败),不该被当成"跟谁都一样"。
	if fa == 0 || fb == 0 {
		return false
	}
	return coverFingerprintDistance(fa, fb) <= coverFingerprintMaxDistance
}

func minEdge(img image.Image) int {
	if img == nil {
		return 0
	}
	b := img.Bounds()
	if b.Dx() < b.Dy() {
		return b.Dx()
	}
	return b.Dy()
}

// coverURLIntendedEdge 从封面 URL 里读出"这个 URL 会给多大的图"。
//
// ⚠️ 为什么不直接下载下来量:`loadCoverImage` 是给取色用的,**返回的远程图已经降采样**
// (网易云 64y64、QQ 300),拿它的解码尺寸判清晰度会把一张 800×800 的候选读成 64px,
// 判据恒成立、修复一次都不会触发(2026-09-02 实现时真踩了这一脚)。而这三家 CDN 的
// 目标尺寸本来就明写在 URL 里,读它不用发任何请求。
//
// 认不出来返回 0,调用方按"证不出候选更好"保守处理(保留设备封面)。
func coverURLIntendedEdge(coverURL string) int {
	u := strings.TrimSpace(coverURL)
	if u == "" {
		return 0
	}
	// 网易云:`?param=800y800`(也见过 `?param=800x800`)。
	if i := strings.Index(u, "?param="); i >= 0 {
		spec := u[i+len("?param="):]
		if j := strings.IndexAny(spec, "&#"); j >= 0 {
			spec = spec[:j]
		}
		for _, sep := range []string{"y", "x"} {
			if k := strings.Index(spec, sep); k > 0 {
				if n := atoiSafe(spec[:k]); n > 0 {
					return n
				}
			}
		}
		if n := atoiSafe(spec); n > 0 {
			return n
		}
		return 0
	}
	// QQ:尺寸档在**路径**里(见 color.go 的 qqCoverAtEdge),形如 `/300x300/` 或
	// `…_300.jpg`。Apple(mzstatic)是 `/300x300bb.jpg`。两者都用"找 NxN 片段"覆盖。
	if n := edgeFromNxNSegment(u); n > 0 {
		return n
	}
	return 0
}

// edgeFromNxNSegment 在 URL 里找形如 `300x300` 的片段,返回 300。取**最后一个**匹配
// (路径前段可能有别的带 x 的 id 串,尺寸档通常紧贴文件名)。
func edgeFromNxNSegment(u string) int {
	best := 0
	for i := 0; i < len(u); i++ {
		if u[i] != 'x' && u[i] != 'X' {
			continue
		}
		// 往左收数字
		l := i
		for l > 0 && u[l-1] >= '0' && u[l-1] <= '9' {
			l--
		}
		// 往右收数字
		r := i + 1
		for r < len(u) && u[r] >= '0' && u[r] <= '9' {
			r++
		}
		if l == i || r == i+1 {
			continue
		}
		a, b := atoiSafe(u[l:i]), atoiSafe(u[i+1:r])
		// 只认正方形档位:封面 CDN 的尺寸档都是 NxN,这样不会把随便一个 `12x34` 当尺寸。
		if a > 0 && a == b {
			best = a
		}
	}
	return best
}

func atoiSafe(s string) int {
	if s == "" || len(s) > 5 {
		return 0
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
		n = n*10 + int(s[i]-'0')
	}
	return n
}

// deviceCoverDecision 是上面那张表的可测实现:给定设备封面和远程候选,回答"设备封面
// 该不该顶掉候选",以及一句能进日志的理由。
//
// candidateEdge 由调用方从 URL 读出(见 coverURLIntendedEdge),不从 loadImage 的结果
// 量 —— 理由见那个函数的注释。loadImage 注入进来只为让这条规则跑得了单测:判据本身
// 不该为了测试去发真实 HTTP 请求。
func deviceCoverDecision(
	deviceImg image.Image, candidateURL string, candidateEdge int,
	loadImage func(string) image.Image,
) (override bool, reason string) {
	if deviceImg == nil {
		// 解不出来的设备图压根不该走到这儿(saveDeviceArtwork 之前就过了质量检查),
		// 真到了就别拿它换掉候选。
		return false, "设备封面解不出来"
	}
	edge := minEdge(deviceImg)
	if edge >= deviceCoverTrustedMinEdge {
		return true, "设备封面够清晰"
	}
	if strings.TrimSpace(candidateURL) == "" {
		return true, "没有远程候选"
	}
	if candidateEdge <= 0 {
		// 认不出候选的目标尺寸 → 证不出它更好 → 保守保留设备封面(退回改动前的行为)。
		return true, "候选尺寸认不出来"
	}
	if candidateEdge <= edge {
		return true, "远程候选不比设备封面大"
	}
	// 到这儿才需要真的取图 —— 只为算 8×8 感知指纹,降采样过的小图完全够用。
	cand := loadImage(candidateURL)
	if cand == nil {
		return true, "远程候选取不到/解不出来"
	}
	if coverImagesLikelySame(deviceImg, cand) {
		// 既对版又清晰 —— 这一档就是这次修复要拿到的结果。
		return false, "同一张图,改用更清晰的远程候选"
	}
	// Immortal 那一档:远程那张更大但**不是同一张**,身份优先,认这个糊。
	return true, "远程候选是另一张图,保留设备封面"
}

// deviceCoverUpgradable 回答"这份已经定案的设备封面,能不能让位给这个远程候选"——
// `coverSwapAllowed` 的 device 分支用它,也是存量低分辨率设备封面的自愈通路。
//
// 语义是 `deviceCoverOverridesCandidate` 的**反面**:顶不掉候选 ⇔ 可以升级成候选。
// 两个方向共用同一份判据,不各写一遍(那就等着两边哪天不一样)。
//
// ⚠️ 设备封面文件缺失/解不出来时这里返回 true(允许换成远程候选)——那种情况下本地这张
// 已经是坏的,留着它没有任何好处。见 deviceCoverDecision 的 `deviceImg == nil` 那一档。
//
// 包级**变量**而不是函数:`coverSwapAllowed` 的既有单测(coveralbum_test.go)用的是
// "device.jpg" 这种假 URL,真跑判据会去发 HTTP 请求;做成变量好让那些用例替换成桩,
// 保持纯函数式的单测不碰网络。
var deviceCoverUpgradable = func(deviceCoverURL, candidateURL string) bool {
	return !deviceCoverOverridesCandidate(context.Background(), deviceCoverURL, candidateURL)
}

// deviceCoverOverridesCandidate 是 resolveTrackEnrichment 用的入口:真的去取图。
func deviceCoverOverridesCandidate(ctx context.Context, deviceCoverURL, candidateURL string) bool {
	deviceImg := loadCoverImage(ctx, deviceCoverURL)
	override, reason := deviceCoverDecision(
		deviceImg, candidateURL, coverURLIntendedEdge(candidateURL),
		func(u string) image.Image { return loadCoverImage(ctx, u) })
	if !override {
		// 只在"没有顶掉"时记一句 —— 那是这次修复真正生效的时刻,而且很罕见,不会刷屏。
		log.Printf("cover: 设备封面 %dpx 让位给远程候选 %dpx(%s)",
			minEdge(deviceImg), coverURLIntendedEdge(candidateURL), reason)
	}
	return override
}
