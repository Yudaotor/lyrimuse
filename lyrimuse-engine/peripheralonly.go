package main

import "context"

// 周边字段补全只要封面、各平台链接、规范歌手名这些外围字段。条目已经有歌词(或手改过、判定过纯音乐)时,
// 这一轮选出的歌词反正不会被收下(adoptBackfilledLyrics),整套歌词搜索白跑。这种时候 ctx 上挂
// withPeripheralOnly,resolveTrackEnrichment 只单查网易云拿它的封面和链接,其余歌词源一个都不问。
// 外围字段里只有网易云那两项是搭歌词搜索的车拿到的,QQ / Apple / 规范歌手名本来就各查各的。见 09 章决策 108。

type peripheralOnlyKey struct{}

func withPeripheralOnly(ctx context.Context) context.Context {
	return context.WithValue(ctx, peripheralOnlyKey{}, true)
}

func peripheralOnly(ctx context.Context) bool {
	v, _ := ctx.Value(peripheralOnlyKey{}).(bool)
	return v
}

// peripheralBackfillSkipsLyrics:这一条做周边补全时要不要跳过歌词搜索。判据跟 adoptBackfilledLyrics
// 收不收这一轮歌词互为反面,两处必须同步改。
func peripheralBackfillSkipsLyrics(e enrichEntry) bool {
	return e.Lyrics != "" || e.ManualLyrics || e.Instrumental
}
