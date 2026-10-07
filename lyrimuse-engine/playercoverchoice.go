package main

import (
	"context"
	"log"
	"strings"
)

// 播放器自带的封面当这首的封面(cover_source=player)。见 03 章决策 33。
//
// playerCoverURLFor 读到的是当前播放器从它本机数据里给这首记下的那张专辑图,身份跟设备封面一样由播放器自己保证,
// 但往往比它交给系统的那份清晰(KKBOX 交给系统的恒为 150×150)。三处用它:
//   - 设备封面要顶掉现有封面时,先看它是不是跟设备封面同一张图、更清晰(playerCoverOverDevice);
//   - 网易云 / Apple / QQ / 同专辑邻居都没给出封面、设备封面也还没到时,直接用它(applyDeviceOrPlayerCover);
//   - 存量的小设备封面换成它(upgradeDeviceCoverToPlayerCover)。

// playerCoverDisplayURL:当这首的封面用哪一档。KKBOX 记下的是 600 档(给 App 外面用),要画到歌词窗口的大卡上换成 1000 档:
// 图床按路径里的 fit 档出图,超过原图是放大的;coverURLIntendedEdge 从「1000x1000」读得出尺寸。别家原样用。
func playerCoverDisplayURL(cover string) string {
	if strings.Contains(cover, "i.kfs.io/") {
		return kkboxCoverAtEdge(cover, "1000")
	}
	return cover
}

// kkboxCoverAtEdge:KKBOX 图床地址末尾的 `/fit/<宽>x<高>.jpg` 换成 edge 档;不是这个形状的原样返回。
func kkboxCoverAtEdge(cover, edge string) string {
	i := strings.LastIndex(cover, "/fit/")
	if i < 0 || !strings.HasSuffix(cover, ".jpg") || !strings.Contains(cover, "i.kfs.io/") {
		return cover
	}
	return cover[:i] + "/fit/" + edge + "x" + edge + ".jpg"
}

type playerCoverKey struct{}

// withPlayerCover:这一拍读到的、正在放的播放器给这首记下的封面,交给首次解析、设备封面、外围补全这几条后台任务。
func withPlayerCover(ctx context.Context, cover string) context.Context {
	if cover == "" {
		return ctx
	}
	return context.WithValue(ctx, playerCoverKey{}, cover)
}

// playerCoverFor:ctx 上挂着的播放器自带封面,已换成当封面用的那一档;没有为 ""。
func playerCoverFor(ctx context.Context) string {
	cover, _ := ctx.Value(playerCoverKey{}).(string)
	return playerCoverDisplayURL(cover)
}

// playerCoverOverDevice:设备封面要顶掉现有封面(current)时,播放器自带的那张跟设备封面是同一张图、而且更清晰,就返回它;
// 否则返回 "",照旧用设备封面。判据就是 deviceCoverOverridesCandidate 那张表:同一张图拿清晰的,不是同一张身份优先。
// 要读本地图、取远程图比对,调用方不能持着 enrichMu。
func playerCoverOverDevice(ctx context.Context, deviceCoverURL, current string) string {
	return playerCoverOverDeviceWith(playerCoverFor(ctx), deviceCoverURL, current,
		func(device, candidate string) bool { return deviceCoverOverridesCandidate(ctx, device, candidate) })
}

// playerCoverOverDeviceWith 是 playerCoverOverDevice 的判定,比对由调用方给(单测不取图)。
func playerCoverOverDeviceWith(cover, deviceCoverURL, current string, overrides func(device, candidate string) bool) string {
	if cover == "" || cover == current || overrides(deviceCoverURL, cover) {
		return ""
	}
	return cover
}

// applyDeviceOrPlayerCover 是 finishTrackEnrichment 收尾的封面取舍:上面按文字匹配挑出来的结果(e.CoverURL)、设备封面、
// 播放器自带的封面。要取图比对,调用方不能持着 enrichMu。
//
// 设备直送的封面身份由"读取时刻本身"保证,顶掉按文字匹配择优选出来的结果——不是"再比一次谁的分更高",是这件事本身
// 不需要再猜了。CoverAlbum 写本地这份 album(不是任何源自己报的专辑名):这份封面从一开始就是照着**这次播放**给的,天然对版。
// 这一顶**不是无条件的**:浏览器 MediaSession 给的封面常常只有 120×120(App 交设备封面的边长下限故意压到 64 就是为了
// 不漏掉它们,见 CoverArtReplacementGate.deviceArtworkMinEdge),歌词窗口那张大卡要画到 ~560px。判据不是"谁更大"
// (那会把"设备那张 120px 是**对的**、远端那张高清是**挂错的**"这种情形反过来),而是"两张图是不是同一张"——同一张就拿
// 高清那份,不一样就身份优先。完整判据表见 coverquality.go 头注。
func applyDeviceOrPlayerCover(ctx context.Context, e *enrichEntry, deviceCoverURL, album string) {
	if deviceCoverURL == "" {
		if e.CoverURL == "" {
			if cover := playerCoverFor(ctx); cover != "" {
				e.CoverURL, e.CoverSource, e.CoverAlbum = cover, "player", album
			}
		}
		return
	}
	if !deviceCoverOverridesCandidate(ctx, deviceCoverURL, e.CoverURL) {
		return
	}
	if cover := playerCoverOverDevice(ctx, deviceCoverURL, e.CoverURL); cover != "" {
		e.CoverURL, e.CoverSource, e.CoverAlbum = cover, "player", album
		return
	}
	// 顶掉的候选跟设备封面是同一张图时留下它的地址,给 App 外面用(见 devicePublicCover)。
	if public := devicePublicCover(ctx, deviceCoverURL, e.CoverURL); public != "" {
		e.PublicCoverURL, e.PublicCoverFor = public, deviceCoverURL
	}
	e.CoverURL, e.CoverSource, e.CoverAlbum = deviceCoverURL, "device", album
}

// playerCoverUpgradeTried:这次启动里哪些条目已经试过把设备封面换成播放器自带的那张(trackEnrichment 换歌那一拍判)。
// 调用方持有 enrichMu。
var playerCoverUpgradeTried = map[string]bool{}

// upgradeDeviceCoverToPlayerCover:存量的设备封面(deviceCoverURL)换成 ctx 上那张播放器自带的封面,判据同
// playerCoverOverDevice:同一张图、更清晰才换。trackEnrichment 在换歌那一拍起,占着 enrichInflight。
func upgradeDeviceCoverToPlayerCover(ctx context.Context, key, deviceCoverURL, album string) {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	cover := playerCoverOverDevice(ctx, deviceCoverURL, "")
	if cover == "" {
		return
	}
	accent := ""
	if webRelayConfigured() {
		accent = dominantColor(ctx, cover)
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	// 这段时间里条目被删了、还在首次解析,或者封面已经换过了:不写。
	if !ok || enrichProvisional[key] || e.CoverSource != "device" || e.CoverURL != deviceCoverURL {
		enrichMu.Unlock()
		return
	}
	e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = cover, "player", album, accent
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	requestEnrichSaveFor(key)
	log.Printf("cover: %q device artwork gives way to the player's own cover %s", key, cover)
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
}
