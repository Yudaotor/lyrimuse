package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// 「这张封面已经确认在中继上」的落盘记录。
//
// ## 为什么加
//
// artworkUploaded 原本只活在进程内存里、重启即空,于是 sweepDeviceArtwork 每次启动都把
// artwork/ 目录整个 HEAD 一遍。实测:本机 713 张图、重启 17 次 ≈ 1.2 万次 KV 读,
// 全是在重问同一批早就确认过的图(日志里那一串 `startup backfill done confirmed=703`)。
// 读额度 100k/天虽然撑得住,但这是纯浪费;而且 HEAD 之后跟着的 POST 会真的吃写额度,
// 写只有 1000/天。
//
// ## 为什么不是简单地把内存搬到磁盘
//
// artworkrelay.go 里原来那句注释拒绝落盘的理由是「标记文件会跟中继真实状态漂开」——
// 这条顾虑是对的(中继侧 KV 被清、换账号、换 namespace,本地记录都不会知道),所以这里
// 给每条确认记一个**时间戳**,并留三道口子把漂移关在有界的窗口里:
//   - 超过 artworkConfirmTTL 的条目不再算数,启动时照旧 HEAD 重新确认一遍;
//   - 中继地址变了(换成自己的 worker / 换账号)整份作废 —— 旧确认对新中继毫无意义;
//   - 文件读坏/解析失败当作空,退回改动前的全量 HEAD 行为,不是致命错。
//
// 代价是:中继侧在 TTL 内被清空的话,这些图在网页上会拿到 404,网页退回 iTunes 兜底封面
// (webSafeCoverURL 头注里那条既有的兜底),下一次 TTL 到期后自愈。这是拿「一周内可能有
// 封面缺口」换「每次重启省几百次 KV 操作」,在免费版额度这么紧的前提下是划算的。
const artworkConfirmTTL = 7 * 24 * time.Hour

// artworkConfirmFlushEvery:补传扫描里每确认这么多张就落一次盘。不等扫完再写的理由是
// 扫一遍 713 张 × artworkSweepGap(300ms) ≈ 3.5 分钟,而开发期 collector 一天重启十几次
// (实测 17 次),只在结尾落盘的话扫描常常还没跑完就被打断、一条都存不下来,
// 这个修复等于不存在。25 张一落盘 = 整轮 29 次本地写,可以忽略。
const artworkConfirmFlushEvery = 25

var (
	// artworkConfirmPath 由 main.go 一次性设好(跟 forwardedPath 等同一处)。空 = 不落盘,
	// 行为完全退回改动前:纯内存集合 + 每次启动全量 HEAD。
	artworkConfirmPath string

	artworkConfirmMu    sync.Mutex
	artworkConfirmAt    = map[string]int64{} // sha -> 确认时刻(unix 秒)
	artworkConfirmDirty bool
	artworkConfirmPend  int // 自上次落盘以来新确认的张数,见 artworkConfirmFlushEvery
)

// artworkRelayKey 是记录里用来认"还是同一个中继"的那个值。必须跟 artworkPublicURL
// 一样把尾部斜杠削掉 —— 否则配置里多打一个 "/" 就会被判成换了中继,每次启动都把记录
// 整份丢掉、退回全量 HEAD,而且只在日志里留一行,很难注意到。
func artworkRelayKey() string { return strings.TrimRight(artworkRelayURL, "/") }

// artworkConfirmFile 是落盘形态。relay 一起存:换中继时整份作废(见头注)。
type artworkConfirmFile struct {
	Relay     string           `json:"relay"`
	Confirmed map[string]int64 `json:"confirmed"`
}

// loadArtworkConfirmed 读回确认记录并把**没过期的**那些灌进 artworkUploaded ——
// 补传扫描据此跳过它们,这正是省下来的那几百次 HEAD。
//
// 必须在 sweepDeviceArtwork 之前调用(main.go 里紧挨着)。任何一步不顺(没有文件、解析
// 失败、中继换了)都安静地当作"没有记录",退回改动前的全量 HEAD 行为。
func loadArtworkConfirmed() {
	// 没配状态中继(绝大多数用户:只用本机悬浮歌词、不搭自己的网页中继)时整条路不存在,
	// 这里一步都不该走 —— 跟 sweepDeviceArtwork 同一道门。不加这道门的话有两个实际后果:
	// ① 每次启动白读一次盘;② 用户曾经配过、后来删掉地址时,旧记录会被判成"中继地址变了"
	// 并在日志里反复喊一句 `... → ""`,看上去像出了错。
	if artworkRelayURL == "" || artworkConfirmPath == "" {
		return
	}
	b, err := os.ReadFile(artworkConfirmPath)
	if err != nil {
		return // 首次运行,不是错
	}
	var f artworkConfirmFile
	if err := json.Unmarshal(b, &f); err != nil {
		log.Printf("artwork relay: confirmation record unreadable, treating it as empty "+
			"and confirming every cover by HEAD this time: %v", err)
		return
	}
	if f.Relay != artworkRelayKey() {
		log.Printf("artwork relay: relay address changed (%q -> %q), dropping the whole confirmation record",
			f.Relay, artworkRelayKey())
		return
	}
	cutoff := time.Now().Add(-artworkConfirmTTL).Unix()
	artworkConfirmMu.Lock()
	artworkMu.Lock()
	fresh, stale := 0, 0
	for sha, at := range f.Confirmed {
		if at < cutoff {
			stale++
			continue
		}
		artworkConfirmAt[sha] = at
		artworkUploaded[sha] = true
		fresh++
	}
	artworkMu.Unlock()
	artworkConfirmMu.Unlock()
	if fresh > 0 || stale > 0 {
		log.Printf("artwork relay: confirmation record loaded fresh=%d stale=%d (stale ones are re-confirmed by HEAD)",
			fresh, stale)
	}
}

// markArtworkConfirmed 记下"这个 sha 此刻确认在中继上"。只落到内存,攒够
// artworkConfirmFlushEvery 张才真写盘;扫描收尾处由 flushArtworkConfirmed 兜底。
func markArtworkConfirmed(sha string) {
	// 同上那道门。当前所有调用点都已经在"配了中继"的分支里,这里再判一次是为了让
	// "没配中继 = 这个文件一个字节都不写"成为本文件自己的不变量,不依赖调用方维持。
	if artworkRelayURL == "" || artworkConfirmPath == "" || sha == "" {
		return
	}
	artworkConfirmMu.Lock()
	artworkConfirmAt[sha] = time.Now().Unix()
	artworkConfirmDirty = true
	artworkConfirmPend++
	due := artworkConfirmPend >= artworkConfirmFlushEvery
	artworkConfirmMu.Unlock()
	if due {
		flushArtworkConfirmed()
	}
}

// flushArtworkConfirmed 把确认记录写盘(tmp + rename,跟 persistedTTLSet.save 同一个套路:
// 中途崩溃不会留下半份文件)。没有新东西就什么都不做。
func flushArtworkConfirmed() {
	if artworkConfirmPath == "" {
		return
	}
	artworkConfirmMu.Lock()
	if !artworkConfirmDirty {
		artworkConfirmMu.Unlock()
		return
	}
	// 顺手丢掉过期条目,免得这份文件跟着听歌量无限长大。
	cutoff := time.Now().Add(-artworkConfirmTTL).Unix()
	snapshot := make(map[string]int64, len(artworkConfirmAt))
	for sha, at := range artworkConfirmAt {
		if at < cutoff {
			delete(artworkConfirmAt, sha)
			continue
		}
		snapshot[sha] = at
	}
	artworkConfirmDirty, artworkConfirmPend = false, 0
	artworkConfirmMu.Unlock()

	data, err := json.Marshal(artworkConfirmFile{Relay: artworkRelayKey(), Confirmed: snapshot})
	if err != nil {
		return
	}
	tmp := artworkConfirmPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, artworkConfirmPath); err != nil {
		log.Printf("save %s: %v", filepath.Base(artworkConfirmPath), err)
	}
}
