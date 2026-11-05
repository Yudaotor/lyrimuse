package main

import (
	"context"
	"time"
)

// Apple Music 在放、目录说这条没有人声(applemusicCatalogNoVocals)时按纯音乐处理。播放侧的目录 id 要等锚点核对完
// (applecatalog.go:第一次见到这首时后台查一次目录、下一拍才写进提示),解析在放的这首时 Apple 那一路没拿到词就等锚点就绪
// 再问(waitPlayingAppleCatalogID),跟别的源并行等,不在开搜那一刻只读一次。预取、补空存下的没词条目开播时怎么补问见
// playernovocals.go。见 09 章决策 360。

// appleNoVocalsAnchorWait:等目录锚点的上限。锚点要一次目录查询加一拍(5 秒)。单测置 0。
var appleNoVocalsAnchorWait = 8 * time.Second

// appleNoVocalsPoll:等锚点时隔多久看一次提示。
var appleNoVocalsPoll = 250 * time.Millisecond

// waitPlayingAppleCatalogID:这首在播放侧记下的 Apple 目录 id。还没有时等锚点就绪;确定立不起锚点(本地导入的文件、
// 没报专辑名、目录元数据核对不上)或 ctx 结束时不等。
func waitPlayingAppleCatalogID(ctx context.Context, artist, title, album string) string {
	id, _ := playbackTrackIDsForRound(ctx, artist, title, album)
	deadline := time.Now().Add(appleNoVocalsAnchorWait)
	for id == "" && !appleCatalogCannotAnchor(title, album) && time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ""
		case <-time.After(appleNoVocalsPoll):
		}
		id, _ = playbackTrackIDsForRound(ctx, artist, title, album)
	}
	return id
}
