package main

import "time"

// spokenVerdictWait:QQ 音乐、酷我新的一条,是不是有声节目的结论最多等这么久(见 awaitsSpokenVerdict)。QQ 要等 App 先拿到
// 这一首的 QQ 歌曲页、再问一次歌曲详情,一秒左右;酷我是引擎问两次酷我的接口。
const spokenVerdictWait = 4 * time.Second

// awaitsSpokenVerdict:这一拍是 QQ 音乐、App 还没给出这一条是不是有声节目的结论,或者是酷我、引擎还在问(playerSpokenPending),
// 而且离开播还不到 spokenVerdictWait。这期间正在播放和待播预取先等;歌词照常解析。见 02 章决策 118、268。
func awaitsSpokenVerdict(s snapshot, startedAt, now time.Time) bool {
	if now.Sub(startedAt) >= spokenVerdictWait {
		return false
	}
	return s.SpokenPending || playerSpokenPending(s)
}

// playerMarksSpoken:播放器把这一首记成有声内容(酷狗:sqlite 那份队列里它是听书条目,见 kugouPlayingSongInfo;酷我:会话没报专辑、
// 酷我把它所在的专辑登记成长音频,见 kuwoSpokenVerdict);歌手栏装字幕的听书播放器(playerSubtitlesInArtist)放的整段都是有声内容。
// 开播那一拍同步判,正在播放、待播预取之前就有结论,不等 App;酷我的结论在后台问,没到之前见 playerSpokenPending。跟 trackEnrichment
// 用同一组参数,结果走 playerCatalogIDsFor 的记忆,随后那次取 id 不再读一遍。见 02 章决策 195、268。
func playerMarksSpoken(s snapshot) bool {
	if playerSubtitlesInArtist[s.Bundle] {
		return true
	}
	return (s.Bundle == kugouMusicBundleID || s.Bundle == kuwoMusicBundleID) &&
		playerCatalogIDsFor(s.Bundle, s.Artist, s.Title, s.Album, s.lyricsDurationSecs()).spoken
}

// playerSpokenPending:酷我这一首是不是有声内容还在后台问(kuwoSpokenVerdict)。
func playerSpokenPending(s snapshot) bool {
	return s.Bundle == kuwoMusicBundleID &&
		playerCatalogIDsFor(s.Bundle, s.Artist, s.Title, s.Album, s.lyricsDurationSecs()).spokenPending
}
