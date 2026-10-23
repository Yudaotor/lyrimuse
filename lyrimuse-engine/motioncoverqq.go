package main

import (
	"context"
	"encoding/json"
	"log"
	"regexp"
	"strings"
)

// QQ 音乐的专辑动态封面:Apple 那边没有动态封面时,按这条记下的 QQ 专辑 mid 问专辑详情的 `basicInfo.dynamicCoverVid`
// (不登录拿得到,本机抽 80 张专辑 4 张有)。画面是 3:4 竖幅、无音轨、4~20 秒,中间就是方形的专辑封面,上下是色带或延伸的
// 画面;歌词窗口封面卡按 1:1 铺满裁中间。视频地址带签名、约 6 小时过期,所以只记 vid:动态封面地址写成 `qqmv:<vid>`,
// App 下载时再换成 mp4 地址(MotionCoverStore)。
//
// 只核专辑身份:QQ 这张专辑的官方方图跟这条在用的封面是同一张(≤ motionCoverIdentityMaxDistance)才放行,App 跳过中段帧
// 终审(竖幅画面整帧比方图本来就比不准)。专辑的结论按 `qq:<mid>` 记进动态封面那张缓存表,跟 Apple 的专辑 ID 不会撞。
// 见 03 章决策 67。

// qqMotionCoverScheme:动态封面地址里 QQ 那一种的前缀,后面是 vid。App 侧按它认(MotionCoverStore)。
const qqMotionCoverScheme = "qqmv:"

var qqAlbumMidShape = regexp.MustCompile(`^[0-9A-Za-z]{10,20}$`)

// qqMotionCoverKey:QQ 专辑在动态封面缓存表里的键。
func qqMotionCoverKey(mid string) string { return "qq:" + mid }

// qqAlbumDynamicCoverVid:专辑详情应答 → dynamicCoverVid;没有为 ""。形状不对为 false。纯函数,单测覆盖。
func qqAlbumDynamicCoverVid(data json.RawMessage) (string, bool) {
	var d struct {
		BasicInfo *struct {
			DynamicCoverVid string `json:"dynamicCoverVid"`
		} `json:"basicInfo"`
	}
	if json.Unmarshal(data, &d) != nil || d.BasicInfo == nil {
		return "", false
	}
	return strings.TrimSpace(d.BasicInfo.DynamicCoverVid), true
}

// qqAlbumDetailFetch 问一次专辑详情。单测替换它。
var qqAlbumDetailFetch = func(ctx context.Context, mid string) (json.RawMessage, error) {
	return qqMusicuPost(ctx, "GetAlbumDetail", "music.musichallAlbum.AlbumInfoServer", map[string]any{"albumMid": mid}, qqCommBase)
}

// qqMotionCoverInflight:正在问的 QQ 专辑。受 motionCoverMu 保护。
var qqMotionCoverInflight = map[string]bool{}

// qqMotionCoverFor:这张 QQ 专辑的动态封面(`qqmv:<vid>`,没有为 "")。第二个返回值同 motionCoverFor:false = 这一轮没查成
// (在飞、请求失败、应答形状不对),调用方别据此钉死结论。查过的结论落盘,不再问。
func qqMotionCoverFor(ctx context.Context, mid string) (string, bool) {
	if !qqAlbumMidShape.MatchString(mid) {
		return "", false
	}
	key := qqMotionCoverKey(mid)
	motionCoverMu.Lock()
	if c, ok := motionCoverCache[key]; ok {
		motionCoverMu.Unlock()
		return c.Master, true
	}
	if qqMotionCoverInflight[mid] {
		motionCoverMu.Unlock()
		return "", false
	}
	qqMotionCoverInflight[mid] = true
	motionCoverMu.Unlock()
	defer func() {
		motionCoverMu.Lock()
		delete(qqMotionCoverInflight, mid)
		motionCoverMu.Unlock()
	}()

	data, err := qqAlbumDetailFetch(ctx, mid)
	if err != nil {
		infoFailf("motion-cover: qq album %s detail failed: %v", mid, err)
		return "", false
	}
	vid, ok := qqAlbumDynamicCoverVid(data)
	if !ok {
		infoFailf("motion-cover: qq album %s detail has no basicInfo", mid)
		return "", false
	}
	mc := motionCover{Checked: true}
	if vid != "" {
		mc.Master = qqMotionCoverScheme + vid
	}
	motionCoverMu.Lock()
	motionCoverCache[key] = mc
	motionCoverDirty = true
	motionCoverMu.Unlock()
	saveMotionCoverCache()
	if vid != "" {
		log.Printf("motion-cover: qq album %s has motion artwork", mid)
	}
	return mc.Master, true
}

// qqMotionCoverUnasked:这条已经核过、没有动态封面(对着现在这张封面),记着 QQ 专辑 mid,而那张 QQ 专辑还没问过 —— Apple
// 那支先于 QQ 这支核出「没有」的存量条目,播到时值得按 QQ 再核一次(trackEnrichment)。只读缓存、不发请求。
// 调用方可以持有 enrichMu(锁顺序 enrichMu → motionCoverMu)。
func qqMotionCoverUnasked(e enrichEntry) bool {
	if !e.MotionCoverChecked || e.MotionCoverURL != "" || e.MotionCoverFor != e.CoverURL || !qqAlbumMidShape.MatchString(e.QQAlbumMid) {
		return false
	}
	motionCoverMu.Lock()
	defer motionCoverMu.Unlock()
	_, asked := motionCoverCache[qqMotionCoverKey(e.QQAlbumMid)]
	return !asked
}

// qqMotionCoverOfficialURL:QQ 专辑官方方图的地址。单测替换它。
var qqMotionCoverOfficialURL = qqAlbumCoverURL

// qqMotionCoverIdentity:这条在用的封面是不是 QQ 这张专辑的官方方图。取不到图为 motionIdentityUndecided。
func qqMotionCoverIdentity(ctx context.Context, mid, coverURL string) motionCoverIdentity {
	if coverURL == "" {
		return motionIdentityUndecided
	}
	official := loadCoverImage(ctx, qqMotionCoverOfficialURL(mid))
	if official == nil {
		return motionIdentityUndecided
	}
	cover := loadCoverImage(ctx, coverURL)
	if cover == nil {
		return motionIdentityUndecided
	}
	d := coverFingerprintDistance(coverFingerprint(official), coverFingerprint(cover))
	if d > motionCoverIdentityMaxDistance {
		log.Printf("motion-cover: qq album %s artwork/cover fingerprint distance %d > %d, identity not confirmed",
			mid, d, motionCoverIdentityMaxDistance)
		return motionIdentityRejected
	}
	return motionIdentityConfirmed
}

// motionVerdictFromQQ:Apple 那支没有给这条动态封面时按 QQ 专辑再核,返回有没有定论(同 motionVerdictFromAlbum)。
// appleChecked:Apple 那支核出了「没有」(而不是根本没有专辑 ID 可核)—— QQ 这边也没有 mid 可核时,前者记「核过、没有」,
// 后者照旧整组清掉。
func (e *enrichEntry) motionVerdictFromQQ(ctx context.Context, appleChecked bool) bool {
	mid := e.QQAlbumMid
	if !qqAlbumMidShape.MatchString(mid) {
		if appleChecked {
			e.recordMotionVerdict("", "", false)
		} else {
			e.clearMotionVerdict()
		}
		return true
	}
	master, done := qqMotionCoverFor(ctx, mid)
	if !done {
		return false
	}
	if master == "" {
		e.recordMotionVerdict("", "", false)
		return true
	}
	switch qqMotionCoverIdentity(ctx, mid, e.CoverURL) {
	case motionIdentityUndecided:
		return false
	case motionIdentityConfirmed:
		e.recordMotionVerdict(master, "", true)
	default:
		e.recordMotionVerdict("", "", false)
	}
	return true
}
