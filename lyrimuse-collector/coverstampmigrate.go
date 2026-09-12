package main

import "log"

// 存量「借来的封面被盖上归属戳」清洗(2026-09-07)。
//
// # 修的是什么
//
// `cover_album` 这个字段回答的是"这张封面在**来源平台上**属于哪张专辑",它是 App 侧
// 唯一有资格**越过 Last.fm 自带图**的那一档(`localAlbumVerifiedCovers`,判据见
// `EnrichCacheReader.coverAlbumVerified`)的凭据,也是 collector 侧 `coverNeedsAlbumCheck`
// 判"这张封面要不要复查"的凭据。
//
// QQ 那一档**从不回传专辑名**,所以 `qqCoverFallback` 选中的封面刻意把 `cover_album`
// 清空 —— 图有用,但不认领归属。可 2026-09-07 之前,`siblingAlbumCover` 把这样一张图借给
// 同专辑其它曲目时,调用方会盖上 `cover_album = album`:一次借用把"未认领归属"升级成了
// "逐字对上专辑"。两层后果:App 侧错图顶掉 Last.fm 那张对的图(用户报的
// 《Michael》/「Hold My Hand (with Akon)」就是这么显示成 QQ 的《The Ultimate Collection》
// 白底金色剪影的),collector 侧撞上 200 分从此不再复查、错误被永久冻住。
//
// 借用侧的修法见 `siblingAlbumCover` 头注(分两档 + 回传归属可信度)。这个迁移负责把
// **已经盖下去的戳**擦掉:本机实测 386 条(占缓存 4068 条的 9.5%)。
//
// # 为什么只擦戳、不顺手把封面换掉
//
// 这里完全能顺手做:`siblingAlbumCover` 是纯内存扫描、不发请求,实测那 386 条里 79 条同
// 专辑有 device 邻居可借。但 `cover_url` 一换,`accent_color` 就成了"从上一张图算出来的
// 主色"——而重算要联网取图(`dominantColor`),不该在启动迁移里做;清空它又会让网页那侧
// 短时间掉配色。仓库既有的纪律是"封面四件套一起判、不出现新封面配旧主色"
// (见 `backfillPeripheralFields` 那段)。
//
// 所以换封面交给既有的自愈路径:`coverCanUpgradeToVerifiedSibling` 让这类条目在**下次
// 被播到**时重解析一次,那条路径本来就会把封面、主色、cover_album 一起写对。擦掉戳这一步
// 本身已经把用户看得见的那个症状修好了 —— 归属不再作假,Last.fm 的对图立刻赢回来。
//
// # 幂等
//
// 擦完之后 qq 档的 `cover_album` 恒为空,再跑一遍一条都不匹配、不落盘。修好之后新产生的
// qq 档也不会再被盖戳(见借用侧),所以这个迁移**不需要**版本标记就能长期留着。
func migrateBorrowedCoverAlbums() {
	enrichMu.Lock()
	cleared := 0
	for k, e := range enrichCache {
		// 只认 qq 档:那是唯一"来源不回传专辑名、因此永远不该有 cover_album"的一档。
		// device 的戳由播放时刻本身保证、netease/apple 的戳是源自己报的专辑名,都是真的。
		if e.CoverSource != "qq" || e.CoverAlbum == "" {
			continue
		}
		e.CoverAlbum = ""
		enrichCache[k] = e
		cleared++
	}
	total := len(enrichCache)
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("cover stamp migration: cleared borrowed cover_album on %d/%d qq-sourced entries", cleared, total)
		saveEnrichCache()
	}
}
