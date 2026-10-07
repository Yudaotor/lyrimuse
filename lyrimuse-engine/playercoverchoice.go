package main

import (
	"context"
	"log"
	"slices"
	"strings"
)

// 播放器自带的封面当这首的封面(cover_source=player)。见 03 章决策 33。
//
// playerCoverURLFor 读到的是当前播放器从它本机数据里给这首记下的那张专辑图,身份跟设备封面一样由播放器自己保证,
// 但往往比它交给系统的那份清晰(KKBOX 交给系统的恒为 150×150)。三处用它:
//   - 设备封面要顶掉现有封面时,先看它是不是跟设备封面同一张图、更清晰(playerCoverOverDevice);
//   - 网易云 / Apple / QQ / 同专辑邻居都没给出封面、设备封面也还没到时,直接用它(applyDeviceOrPlayerCover);
//   - 存量的小设备封面换成它,本机播放器数据里按歌名记着的也算(upgradeSmallDeviceCover)。

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

// deviceCoverUpgradeTried:这次启动里哪些条目已经试过把小设备封面换成播放器自带的那张(trackEnrichment 换歌那一拍判)。
// 调用方持有 enrichMu。
var deviceCoverUpgradeTried = map[string]bool{}

// localPlayerCovers:本机播放器数据里按歌名记着的这首的封面 —— KKBOX 客户端缓存的单曲详情、网易云客户端曲库,不看现在
// 哪个播放器在放;都没有返回空。只用来给小设备封面找同一张图的清晰版(upgradeSmallDeviceCover 比过是同一张图
// 才换)。要读别的 App 的本机文件,调用方不能持着 enrichMu。包级变量:单测换成桩(TestMain 里默认没有)。
var localPlayerCovers = func(artist, title, album string, durationSecs float64) []string {
	var out []string
	if c := kkboxPlayingInfoFor(artist, title, durationSecs).cover; c != "" {
		out = append(out, c)
	}
	if c := neteaseLocalCoverURL(artist, title, album, durationSecs); c != "" {
		out = append(out, c)
	}
	return out
}

// coverCandidate:一张拿来跟小设备封面比的封面,和换上之后记成的来源。
type coverCandidate struct{ url, source string }

// decisionCoverCandidatesMax:各源候选自带的封面最多比这么多张(每张要取一次缩图)。
const decisionCoverCandidatesMax = 6

// candidateCoverURLOK:候选自带的封面地址能不能用 —— 只认 https(这张要存进缓存、给 App 外面用)。包级变量:单测换成认本机文件。
var candidateCoverURLOK = func(u string) bool { return strings.HasPrefix(u, "https://") }

// decisionCandidateCovers:这首歌词判决里各源候选自带的封面(去重,最多 decisionCoverCandidatesMax 张),来源记各自的源名。
// 只拿来给小设备封面找同一张图的清晰版:身份由跟设备封面比对保证,不看这条候选是不是这首歌。判决的明细存在旁路文件里时
// 要读一次文件,调用方不能持着 enrichMu。见 03 章决策 36。
func decisionCandidateCovers(key string, d *lyricsDecision) []coverCandidate {
	d = withDecisionDetails(key, d)
	if d == nil {
		return nil
	}
	var out []coverCandidate
	for _, c := range d.Candidates {
		if !candidateCoverURLOK(c.CoverURL) || slices.ContainsFunc(out, func(x coverCandidate) bool { return x.url == c.CoverURL }) {
			continue
		}
		if out = append(out, coverCandidate{c.CoverURL, c.Source}); len(out) == decisionCoverCandidatesMax {
			break
		}
	}
	return out
}

// winnerCandidateCover:歌词胜出的那个源自带的封面,它报的专辑名跟本地逐字对上(albumScore 200)才给,只认 https;返回封面、
// 源名、它报的专辑名。三源、同专辑邻居、设备封面、播放器自带的都没给出封面时拿它兜底。见 03 章决策 36。
func winnerCandidateCover(d *lyricsDecision, album string) (cover, source, coverAlbum string) {
	if d == nil || d.Winner == "" || strings.TrimSpace(album) == "" {
		return "", "", ""
	}
	for _, c := range d.Candidates {
		if c.Source != d.Winner || c.Score <= 0 {
			continue
		}
		if candidateCoverURLOK(c.CoverURL) && albumScore(c.Album, album) == 200 {
			return c.CoverURL, c.Source, c.Album
		}
		break
	}
	return "", "", ""
}

// upgradeSmallDeviceCover:存量的小设备封面(deviceCoverURL)换成同一张图的清晰版 —— 依次试 ctx 上这一拍在放的播放器给的、
// 本机播放器数据里按歌名记着的(localPlayerCovers)、这首歌词判决里各源候选自带的(decisionCandidateCovers),头一张跟设备
// 封面是同一张图、更清晰的就用,判据同 playerCoverOverDevice。前两种记成 player,候选的记成那个源。返回换没换。
// trackEnrichment 换歌那一拍和后台补封面(coversweep.go)用;调用方先占上 enrichInflight,这里收工时放掉。
func upgradeSmallDeviceCover(ctx context.Context, key, deviceCoverURL, artist, title, album string,
	durationSecs float64) bool {
	defer func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	}()
	var candidates []coverCandidate
	add := func(url, source string) {
		if url != "" && !slices.ContainsFunc(candidates, func(c coverCandidate) bool { return c.url == url }) {
			candidates = append(candidates, coverCandidate{url, source})
		}
	}
	add(playerCoverFor(ctx), "player")
	for _, c := range localPlayerCovers(artist, title, album, durationSecs) {
		add(playerCoverDisplayURL(c), "player")
	}
	enrichMu.Lock()
	decision := enrichCache[key].LyricsDecision
	enrichMu.Unlock()
	for _, c := range decisionCandidateCovers(key, decision) {
		add(c.url, c.source)
	}
	var chosen coverCandidate
	for _, c := range candidates {
		if playerCoverOverDeviceWith(c.url, deviceCoverURL, "", func(device, candidate string) bool {
			return deviceCoverOverridesCandidate(ctx, device, candidate)
		}) != "" {
			chosen = c
			break
		}
	}
	if chosen.url == "" {
		return false
	}
	cover := chosen.url
	accent := ""
	if webRelayConfigured() {
		accent = dominantColor(ctx, cover)
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	// 这段时间里条目被删了、还在首次解析,或者封面已经换过了:不写。
	if !ok || enrichProvisional[key] || e.CoverSource != "device" || e.CoverURL != deviceCoverURL {
		enrichMu.Unlock()
		return false
	}
	e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor = cover, chosen.source, album, accent
	enrichCache[key] = e
	enrichDirty = true
	enrichMu.Unlock()
	if cur := enrichPlayingKey.Load(); !coverSweepSaveDeferred(ctx) || (cur != nil && *cur == key) {
		// 后台补封面那一遍攒着存(见 coversweep.go);正在播的这首照常当场存。
		requestEnrichSaveFor(key)
	}
	log.Printf("cover: %q device artwork gives way to the same picture from %s: %s", key, chosen.source, cover)
	if enrichNotify != nil {
		select {
		case enrichNotify <- struct{}{}:
		default:
		}
	}
	return true
}
