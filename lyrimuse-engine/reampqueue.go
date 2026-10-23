package main

import (
	"encoding/json"
	"sync"
)

// reAMP 的播放列表:App 读它退出时存的 playlist.m3u(运行中不写),按认当前这首那一套换好歌名歌手,连同菜单里的随机 / 循环一起交来
// (App 侧 ReampPlaylist,形状同 Pine 那份 pineQueueReply)。当前这首按完整路径在里面找,找不到(这一轮换过列表)退回同专辑预取。
// 随机:菜单读得到就按它,读不到才按换歌行为推断。没有单曲循环;列表循环放到最后接回开头。见 02 章决策 175。

// reampQueueAsk 让 App 读一次列表。单测替换它。
var reampQueueAsk = func() (string, bool) {
	return askApp(appQueryRequest{Kind: appQueryReampQueue}, appQueryScriptTimeout)
}

var (
	reampPlayOrderMu   sync.Mutex
	reampPlayOrderLast queueOrder
)

func reampUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	out, ok := reampQueueAsk()
	if !ok {
		return nil, false
	}
	var q pineQueueReply
	if json.Unmarshal([]byte(out), &q) != nil || len(q.Tracks) == 0 {
		return nil, false
	}
	// App 交的是完整路径,当前这首也按完整路径认;待播的文件就是这一行。
	for i := range q.Tracks {
		q.Tracks[i].path = q.Tracks[i].File
	}
	pos := pineCurrentIndex(q.Tracks, localFileCurrentPath(artist, title), artist, title)
	if pos < 0 {
		return nil, false
	}
	reampPlayOrderMu.Lock()
	shuffled, _ := reampPlayOrderLast.observeWrapping(pineQueueID(q.Tracks), pos, len(q.Tracks))
	reampPlayOrderMu.Unlock()
	switch q.Repeating {
	case "shuffle":
		shuffled = true
	case "off", "all":
		shuffled = false
	}
	return pineListUpcoming(q.Tracks, pos, n, shuffled, q.Repeating == "all")
}
