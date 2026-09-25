// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"log/slog"
	"os"
	"sort"
	"sync"
	"time"
)

// 五条「直接读播放器客户端自己那份缓存」的快速路径(酷狗 / QQ 音乐 / 网易云 / 汽水 /
// Apple Music)共用这一套判据与上报。
//
// 这些路径全程 fail-soft:读不到就整条静默退回网络解析。这是对的 —— 没装那个播放器、
// 没登录过、客户端换了目录、客户端正在写导致这一拍读失败,全是常态,而这段代码**每首歌
// 都会走一遍**,无条件记日志就是每首刷一行。
//
// **但"被系统拒了"不在常态之列,它必须留下痕迹**。macOS 只让有「完全磁盘访问」的进程
// 读别的 App 的私有容器(`~/Library/Containers/<bundle id>/Data`),没有授权时这里恒返回
// EPERM。这种情况下快速路径是**装好了却一直哑着**,而 fail-soft 让它跟"用户压根没装那个
// 播放器"在日志里逐字节相同,没有任何东西提示该去授权 —— 实测某台机器上酷狗 / QQ 音乐 /
// 网易云三条因此从未命中过,直到授权后才开始工作。
//
// 所以判据收得很窄:**只认 `fs.ErrPermission`**,其余一概静默。窄是有意的 —— 这里要抓的是
// 那个"永远不会自己好、且只能靠授权解决"的状态,把偶发读失败也报出来会让这行诊断失去信噪比。
//
// 每个读取入口都要接:`os.Stat` 过了不代表 `os.ReadDir` 也过 —— TCC 允许 stat 一个目录
// 却拒绝列它的内容是**实际发生过的形态**(实测那行诊断里的错误是 `open …: operation not
// permitted`,来自 ReadDir 而非 Stat),只在 stat 那一支记日志会让这类拒绝继续无声无息。
//
// 哪几条需要授权由**路径在不在 `~/Library/Containers/` 下**决定,不是按播放器分:酷狗 /
// QQ 音乐 / 网易云在那底下(要授权),汽水(`Application Support/SodaMusic/`)与 Apple Music
// (`Caches/com.apple.Music/`)不在(不要)。别把这个判断硬编码成来源名单。

// localCacheAccessState 是设置页那三格「客户端缓存读不到」提示的数据源。
//
// 这个状态**必须由 collector 发布,App 不能自己去探测**:两者是两个进程,TCC 授权各自
// 独立,App 探得到不代表 collector 探得到(反之亦然)。真正走这条快速路径的是 collector,
// 所以只有它的结论算数。同 `scoringVersion` 不能在 Swift 侧硬编码是一个道理。
type localCacheAccessState struct {
	UpdatedAt int64 `json:"updatedAt"`
	// 当前被系统挡住的来源名。**只列尝试过的** —— 没听过那个播放器的用户这里是空的,
	// 界面因此什么都不显示(而不是显示一排"未知")。
	Denied []string `json:"denied"`
	// 当前确认读得到的来源名,与 Denied 互斥。设置页 / 引导页的「完全磁盘访问」那一行靠它
	// 显示「已授权」;两边都不在 = 还没试过,界面按「未确认」处理。
	Readable []string `json:"readable"`
}

var (
	localCacheDeniedMu sync.Mutex
	// 日志去重:同一来源的同一种拒绝只报第一次。
	localCacheDeniedReported = map[string]string{}
	// 当前被拒的来源集合,变了才写状态文件 —— 这几个函数每首歌都会被调到,
	// 无条件写盘就是每首一次 IO。
	localCacheDeniedNow   = map[string]bool{}
	localCacheReadableNow = map[string]bool{}
	localCacheAccessPath  string
)

// setLocalCacheAccessPath 由 main() 在拿到单实例锁之后调用。空路径 = 不发布状态(单测默认如此)。
func setLocalCacheAccessPath(path string) {
	localCacheDeniedMu.Lock()
	defer localCacheDeniedMu.Unlock()
	localCacheAccessPath = path
	// 进程刚起来,先把上一个进程留下的结论清掉:授权状态可能在两次运行之间被改过,
	// 留着旧文件会让界面显示一个已经不成立的提示,直到下次真正读过那个来源为止。
	if path != "" {
		_ = os.Remove(path)
	}
}

// noteLocalCacheDenied 只在 err 是「被系统拒绝」时记一行并发布状态。err 为 nil、或是任何
// 别的失败,都什么都不做 —— 所以调用点可以无脑放进既有的 fail-soft 守卫里,不必自己分类。
func noteLocalCacheDenied(source, path string, err error) {
	if err == nil || !errors.Is(err, fs.ErrPermission) {
		return
	}
	msg := err.Error()
	localCacheDeniedMu.Lock()
	repeated := localCacheDeniedReported[source] == msg
	localCacheDeniedReported[source] = msg
	changed := !localCacheDeniedNow[source] || localCacheReadableNow[source]
	localCacheDeniedNow[source] = true
	delete(localCacheReadableNow, source)
	if changed {
		writeLocalCacheAccessLocked()
	}
	localCacheDeniedMu.Unlock()
	if repeated {
		return
	}
	log.Printf("%s local: macOS is refusing access to the client cache at %s (%v) — "+
		"grant Full Disk Access to let this fast path work; lyrics still resolve over the network",
		source, path, err)
}

// noteLocalCacheReadable 是上面那个的对偶:真的读到了就把这个来源从"被拒"挪到"读得到"。
// 授权之后界面上的提示要能自己消失,靠的就是它。
func noteLocalCacheReadable(source string) {
	localCacheDeniedMu.Lock()
	defer localCacheDeniedMu.Unlock()
	if !localCacheDeniedNow[source] && localCacheReadableNow[source] {
		return
	}
	delete(localCacheDeniedNow, source)
	delete(localCacheDeniedReported, source)
	localCacheReadableNow[source] = true
	writeLocalCacheAccessLocked()
}

// writeLocalCacheAccessLocked:调用方必须已经握着 localCacheDeniedMu。
func writeLocalCacheAccessLocked() {
	if localCacheAccessPath == "" {
		return
	}
	state := localCacheAccessState{UpdatedAt: time.Now().Unix(), Denied: []string{}, Readable: []string{}}
	for source := range localCacheDeniedNow {
		state.Denied = append(state.Denied, source)
	}
	for source := range localCacheReadableNow {
		state.Readable = append(state.Readable, source)
	}
	// 排序只为让这份文件的内容对同一份状态是稳定的(map 遍历序每次都不同),免得
	// 读的一方以为状态变过。
	sort.Strings(state.Denied)
	sort.Strings(state.Readable)
	data, err := json.Marshal(state)
	if err != nil {
		return
	}
	if err := os.WriteFile(localCacheAccessPath, data, 0o644); err != nil {
		slog.Warn("local cache access: state write failed", "err", err)
	}
}
