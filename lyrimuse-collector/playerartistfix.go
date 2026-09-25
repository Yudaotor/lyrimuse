package main

import (
	"encoding/json"
	"log/slog"
	"os"
	"sync"
	"time"
)

// App 与 collector 的「这个播放器报的署名不可信,真署名是这个」状态通道。
//
// # 为什么需要它
//
// 两个进程各自读 media-control(collector 走 getState、App 走 MediaControlClient),
// 所以同一份脏署名两边都会拿到。而歌词缓存的 key 是 `artist|title|album`:collector
// 用纠正后的署名写进去,App 用播放器报的脏署名去查,`EnrichCacheReader.looseMatch`
// 只折平空格 / 大小写 / 繁简 —— 折不平两个**完全不同**的署名,于是 App 再也查不到
// collector 刚写好的那条歌词。
//
// 所以纠正这件事**不能只做一半**:改了 collector 不同步 App,歌词会从"能显示但
// 歌手名是歌词"变成"压根不显示",比不改更糟。
//
// # 为什么由 collector 发布
//
// 真署名要从播放器自己的私有容器里读(见 kugoulyricartist.go),而**读播放器容器是
// collector 的活** —— App 侧一处都没有,那是一条既有的分层边界。两个进程的 TCC 授权
// 也各自独立,让 App 自己去读会得出跟 collector 不同的结论,而"两边一致"正是这条通道
// 存在的全部理由。同 localcachefs.go 那份状态只能由 collector 发布是同一个道理。
//
// 只读通道:collector 只写,App 只读。
type playerArtistFixState struct {
	UpdatedAt int64 `json:"updatedAt"`
	// Bundle / Title 是这条纠正的适用范围。App 拿当前快照比对,对不上就不用 ——
	// 换歌那一刻两个进程不同步是常态(轮询节奏本来就不一样)。
	//
	// 不拿时长一起比:两边虽然读的是同一份载荷,但各自还有电台 / MV 那些改写时长的
	// 分支,多一个条件只多一种对不上的方式,而"同名同曲长的另一首歌"本来就得靠曲名撞。
	Bundle string `json:"bundle"`
	Title  string `json:"title"`
	Artist string `json:"artist"`
	// FixedTitle:曲名也要换时的真曲名,空 = 曲名不动。Title 仍是播放器原样报的那个(适用范围)。
	// 只有信任进来的其他播放器会用到(见 trustedlyricartist.go)。
	FixedTitle string `json:"fixedTitle,omitempty"`
	// StableField:这个播放器哪个字段装着身份、不跟歌词变。空 = title(酷狗与多数情形:歌词在
	// artist 里);"artist" = 歌词在 title 里,这时适用范围改按 RawArtist 比(title 每句都变,
	// 拿它当范围只对得上一拍),Title 留空。播放器级,跟 Unreliable 一起跨重启保留。
	StableField string `json:"stableField,omitempty"`
	// RawArtist:StableField 为 "artist" 时的适用范围 —— 播放器原样报的 artist。
	RawArtist string `json:"rawArtist,omitempty"`
	// Order:collector 认出来的身份字段排列("songFirst" / "artistFirst"),只给 collector 重启恢复用,
	// App 不读。播放器级,跨重启保留。
	Order string `json:"order,omitempty"`
	// Unreliable:这个播放器**被实际观测到**拿别的东西冒充署名。
	//
	// 跟上面三项不同,它是**播放器级**的:哪个 App 会干这事跨进程重启不会变,变的只是
	// "此刻在放哪一首"。所以启动时只清掉曲目那两项、把它留下 —— 否则重启后的第一首歌里
	// App 不知道这个播放器的署名不可信,曲目身份又会带上署名抖几次,封面照样被丢
	// (见 MediaControlSnapshot.identityKey)。
	Unreliable bool `json:"unreliable"`
}

var (
	playerArtistFixMu   sync.Mutex
	playerArtistFixPath string
	playerArtistFixLast playerArtistFixState
)

// setPlayerArtistFixPath 由 setLyricsFillPaths 调用。空路径 = 不发布(单测默认如此)。
//
// 文件里留下的播放器级结论要同时恢复进 collector 自己的判定(restoreKugouArtistPoisonConfirmed):
// App 读到 unreliable 就会等这一首的纠正、没到之前把歌手位清空,而 collector 只有判定成立时才给
// 每一首发布纠正。只恢复文件不恢复判定,署名本来就干净的歌永远等不到纠正,App 那边一直没有歌手。
func setPlayerArtistFixPath(path string) {
	// 恢复判定必须在放开 playerArtistFixMu 之后做:kugouFixedArtist 持着 kugouLyricArtistMu
	// 调 publishPlayerArtistFix,锁序是 kugou → fix,反过来会死锁。
	switch prev := setPlayerArtistFixPathLocked(path); prev.Bundle {
	case "":
	case kugouMusicBundleID:
		restoreKugouArtistPoisonConfirmed()
	default:
		// 锁序同上:trustedFixedTrack 持着 trustedLyricArtistMu 调 publishPlayerTrackFix。
		restoreTrustedLyricArtistConfirmed(prev.Bundle, prev.StableField, prev.Order)
	}
}

// setPlayerArtistFixPathLocked 返回保留下来的播放器级结论(只含播放器级字段),没有就是零值。
func setPlayerArtistFixPathLocked(path string) playerArtistFixState {
	playerArtistFixMu.Lock()
	defer playerArtistFixMu.Unlock()
	playerArtistFixPath = path
	playerArtistFixLast = playerArtistFixState{}
	if path == "" {
		return playerArtistFixState{}
	}
	// 上一个进程记的**曲目**作不得数:那时在放哪一首无从得知,而 App 按 bundle + 曲名比对,
	// 陈旧记录正好能撞上同一首歌。但"哪个播放器不可信"要留下 —— 理由见 Unreliable 字段。
	prev := readPlayerArtistFixLocked(path)
	if !prev.Unreliable || prev.Bundle == "" {
		_ = os.Remove(path)
		return playerArtistFixState{}
	}
	kept := playerArtistFixState{Bundle: prev.Bundle, Unreliable: true, StableField: prev.StableField, Order: prev.Order}
	writePlayerArtistFixLocked(kept)
	return kept
}

// readPlayerArtistFixLocked 读上一个进程留下的那份。读不到 / 解析不了都返回零值,
// 调用方按"没有结论"处理。
func readPlayerArtistFixLocked(path string) playerArtistFixState {
	raw, err := os.ReadFile(path)
	if err != nil {
		return playerArtistFixState{}
	}
	var prev playerArtistFixState
	if err := json.Unmarshal(raw, &prev); err != nil {
		return playerArtistFixState{}
	}
	return prev
}

// writePlayerArtistFixLocked 落盘并记下这一份,供去重比对。调用方必须持有锁。
func writePlayerArtistFixLocked(next playerArtistFixState) {
	stamped := next
	stamped.UpdatedAt = time.Now().Unix()
	data, err := json.Marshal(stamped)
	if err != nil {
		return
	}
	if err := os.WriteFile(playerArtistFixPath, data, 0o644); err != nil {
		slog.Warn("player artist fix: state write failed", "err", err)
		return
	}
	playerArtistFixLast = next
}

// publishPlayerArtistFix 发布一条纠正。同一条重复发布不写盘 —— 这个函数每首歌每一拍
// 都会被调到。
//
// unreliable 只在播放器级结论成立(kugouArtistPoisonConfirmed)时传 true:App 把它当成「这个
// 播放器的每一首都要等纠正」,只凭这一首的弱证据写成 true,一次误判就会扩散到之后每一首。
func publishPlayerArtistFix(bundle, title, artist string, unreliable bool) {
	publishPlayerTrackFix(playerArtistFixState{Bundle: bundle, Title: title, Artist: artist, Unreliable: unreliable})
}

// publishPlayerTrackFix 发布一条完整的纠正(信任进来的其他播放器用,见 trustedlyricartist.go)。
// 适用范围要有一个:Title,或 StableField 为 "artist" 时的 RawArtist。UpdatedAt 由这里盖。
func publishPlayerTrackFix(next playerArtistFixState) {
	scoped := next.Title != "" || (next.StableField == "artist" && next.RawArtist != "")
	if next.Bundle == "" || next.Artist == "" || !scoped {
		return
	}
	next.UpdatedAt = 0
	playerArtistFixMu.Lock()
	defer playerArtistFixMu.Unlock()
	if playerArtistFixPath == "" {
		return
	}
	if next == playerArtistFixLast {
		return
	}
	writePlayerArtistFixLocked(next)
	slog.Info("player artist fix: published", "bundle", next.Bundle, "title", next.Title, "artist", next.Artist,
		"fixed_title", next.FixedTitle, "stable_field", next.StableField, "raw_artist", next.RawArtist)
}
