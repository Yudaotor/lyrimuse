package main

import "strings"

// radioStationCard 判「这一份载荷是电台的台卡,不是一首歌」。
//
// 电台起播时系统会先把**台名当一首歌**推过来,持续几十秒(实测 2026-09-10 开台到第一首歌之间
// 33.4 秒)。形态是 title=台名、artist 空 —— 实测三例:`|petal radio|`、`|NCT 127|`、`|YEONJUN|`
// (enrich key 是 `歌手|歌名|专辑`,所以第一段空的就是没有歌手)。
//
// 不拦的话它会被当成一首歌:去网络搜一轮歌词、搜不到、再把这条空壳永久写进磁盘缓存,污染
// 「歌词管理」列表 —— 用户 2026-09-11 报的就是这个(「第一次开始播放一个电台时……还是会被当成
// 一首歌去搜索,然后显示"暂无歌词"」)。发现时缓存里已经攒了 6 条,无一例外没搜到歌词。
//
// 判据只用「电台 + 没有歌手」。真曲目两样俱全(实测所有真歌都带歌手),而缺歌手时歌词搜索本来
// 也几乎不可能命中,所以这道闸即便偶尔误伤一首"电台上没报歌手的真歌",代价也只是少搜一次。
// **只对电台生效**:本地文件缺标签同样会没有歌手,那条路不在这次改动范围内。
//
// Swift 侧同一件事在 `RadioStationCard.stationName`(那边还要从台卡里取台名和台标),两边的
// 判据必须同义:那边认「title / artist 恰好一个为空」,包含这里这一种。
func radioStationCard(radio bool, artist, title string) bool {
	return radio && strings.TrimSpace(artist) == "" && strings.TrimSpace(title) != ""
}
