package main

import "time"

// spokenVerdictWait:QQ 音乐新的一条,App 对它是不是有声节目的结论最多等这么久(见 awaitsSpokenVerdict)。App 要先等这一首的
// 歌词缓存里有了 QQ 歌曲页、再问一次歌曲详情,实测一秒左右。
const spokenVerdictWait = 4 * time.Second

// awaitsSpokenVerdict:这一拍是 QQ 音乐、App 还没给出这一条是不是有声节目的结论,而且离开播还不到 spokenVerdictWait。
// 这期间正在播放和待播预取先等;歌词照常解析。见 02 章决策 118。纯函数,测试覆盖。
func awaitsSpokenVerdict(s snapshot, startedAt, now time.Time) bool {
	return s.SpokenPending && now.Sub(startedAt) < spokenVerdictWait
}

// playerMarksSpoken:播放器本机数据把这一首记成有声内容(酷狗:sqlite 那份队列里它是听书条目,见 kugouPlayingSongInfo)。
// 开播那一拍同步判,正在播放、待播预取之前就有结论,不等 App。跟 trackEnrichment 用同一组参数,结果走 playerCatalogIDsFor
// 的记忆,随后那次取 id 不再读一遍。见 02 章决策 195。
func playerMarksSpoken(s snapshot) bool {
	return s.Bundle == kugouMusicBundleID &&
		playerCatalogIDsFor(s.Bundle, s.Artist, s.Title, s.Album, s.lyricsDurationSecs()).spoken
}
