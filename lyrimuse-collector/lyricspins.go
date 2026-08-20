package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"
)

// 「已校准」曲目 = 用户手动调过这首歌的歌词时间轴(App 侧 LyricsOffsetStore 里存了非零
// 校正值)。这类曲目**不再自动重选歌词源** —— 语义跟 ManualLyrics(手动改过歌词内容)
// 并列,两者都是"用户已经亲手把这首歌弄对了,后台别再自作主张"。
//
// 为什么必须有这道闸:校正值是绑在**这一份歌词内容**上的(key 里含 lyrics+lyricsYRC 的
// SHA256 指纹,见 Swift 侧 LyricsOffsetStore.trackKey),后台一旦把歌词换成另一份,指纹
// 变、校正值查不到,用户一句句听出来的那几百毫秒当场作废,而且界面上毫无痕迹。
// 2026-08-20 实测坐实这不是理论风险:那台机器 14 条校正记录里 13 条已经因为"内容换过"
// 或"条目没了"而失联;而 qq 与 kugou 的分差常年只有 9 分(约 1330 分里的 0.7%,时间戳
// 行数完全相同),任何一次重搜都可能翻盘换源。
//
// 为什么单独一个文件、不放进 enrichCache:
//  1. collector 在内存里持有整份 enrichCache 并会整份写回磁盘。App 直接往那个 JSON 里塞
//     字段会被下一次 saveEnrichCache 覆盖,想安全就得重启 collector(理由见 Swift 侧
//     EnrichCacheStore.delete 的长注释)—— 而校正值是在菜单栏里按一下就变一次的东西,
//     每按一次重启一遍 collector 不可接受(launchd 还有 minimum runtime = 10 的惩罚)。
//  2. 这份文件只有几行:App 侧写、collector 侧读,mtime 一变就重读,不需要任何重启。
//
// key 用的是 enrichKey(归一化后的 artist|title|album),跟 enrichCache 同一套 —— 刻意
// **不是** LyricsOffsetStore 那个含内容指纹的 key:pin 要保护的是"这首歌",而内容指纹
// 恰恰是会变的那一半,拿它当 pin 的身份等于"内容一换 pin 也失效",正好把要防的事情放过去。
type lyricsPinsFile struct {
	Version int `json:"version"`
	// enrichKey -> 记下这条 pin 的 unix 秒。时间戳纯给人看(`cat` 一眼能看出哪首是什么
	// 时候校准的),collector 只关心键在不在,不读值 —— 刻意不在这里存校正毫秒数:那份
	// 值的权威源是 App 的 UserDefaults,复制一份到这里只会多一处会漂的状态。
	Pins map[string]int64 `json:"pins"`
}

var (
	// 由 main() 跟其余缓存路径一起设定;为空(一次性 CLI 子命令那些提前返回的分支)时
	// lyricsPinned 一律返回 false。
	lyricsPinsPath  string
	lyricsPinsMu    sync.Mutex
	lyricsPins      map[string]bool
	lyricsPinsMTime time.Time
	lyricsPinsSize  int64
	lyricsPinsRead  bool
)

// lyricsPinned 判断这个 enrich key 是否被用户校准过时间轴。
//
// 每次调用只 Stat 一下文件,mtime 或大小任一变了才重新读整份。为什么不像 features/
// artistAlias 那些缓存一样"启动时读一次":那样一来,用户刚在菜单栏按了几下「提前」的
// 那首歌,在 collector 重启前完全不受保护 —— 而那恰恰是最需要它生效的一刻(校准完
// 接着放这首歌,正好触发 needsLyricsRetry)。这道判定挂在 trackEnrichment 分发后台任务
// 的路径上,每首歌播放时最多跑几次,一次 Stat 的开销可以忽略。
func lyricsPinned(key string) bool {
	if lyricsPinsPath == "" || key == "" {
		return false
	}
	lyricsPinsMu.Lock()
	defer lyricsPinsMu.Unlock()
	st, err := os.Stat(lyricsPinsPath)
	if err != nil {
		// 文件还不存在(从没校准过任何一首歌)是正常状态、不是错误:清掉内存态,一律不 pin。
		// 也覆盖了"用户刚点了『清空全部时间轴校正』把文件删掉"这一步。
		lyricsPins, lyricsPinsRead = nil, true
		lyricsPinsMTime, lyricsPinsSize = time.Time{}, 0
		return false
	}
	if !lyricsPinsRead || !st.ModTime().Equal(lyricsPinsMTime) || st.Size() != lyricsPinsSize {
		lyricsPins = readLyricsPins(lyricsPinsPath)
		lyricsPinsMTime, lyricsPinsSize, lyricsPinsRead = st.ModTime(), st.Size(), true
	}
	return lyricsPins[key]
}

// readLyricsPins 读整份 pin 文件。解析失败一律当"没有任何 pin",而不是 panic 或沿用上
// 一次的内存态:这份文件是 App 写的,读坏了最坏的后果是这一轮该保护的没保护到(下一次
// 写入会把 mtime 推新、自然重试),而沿用旧内存态会让"清空"这个动作在坏文件下永久不生效。
func readLyricsPins(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var f lyricsPinsFile
	if err := json.Unmarshal(data, &f); err != nil {
		log.Printf("lyrics pins: cannot parse %s, treating as empty: %v", path, err)
		return nil
	}
	out := make(map[string]bool, len(f.Pins))
	for k := range f.Pins {
		if k != "" {
			out[k] = true
		}
	}
	return out
}
