package main

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// 本地收听日志 —— 把"算数的收听"里**还没进 Last.fm 的那些**追加到磁盘,供之后回填。
//
// ⚠️ 当前的写入条件(两条,满足其一才写,别照标题想当然):
//
//  1. 没连 Last.fm(`p.lfm == nil`)—— 常规路径,见下面 2026-08-13 那段收窄。
//  2. 连了 Last.fm 但**这一条确定没写进去**(镜像失败,见 poller.go 的
//     recordFailedMirror,2026-08-30 加)。
//
// 换句话说:一个一直连着账号、且网络一直正常的用户,这份日志会是**空的**,那是对的。
//
// 为什么需要:2026-08-13 之前,一次完成的收听只会流向三个地方(applySubmitOutcome):
// 镜像到 Last.fm、提交到 ListenBrainz、推给网页中继 —— 三个**全都需要先配好账号**。
// 外加一个 recordRecentMacListen,但那只是内存里的 24 小时去重缓冲(poller.go 那边有
// 说明),进程重启即清空、磁盘上没有任何痕迹。
//
// 后果:一个先用了一周、之后才连 Last.fm 的用户,那一周的收听**从来没落过盘**,连不上
// 也补不回来 —— 不是"存了没发",是压根没存。这个文件就是补上这一环:把没提交出去的
// 记下来,等账号连上之后再决定要不要补提交(见 §回填,那部分单独实现)。
//
// ⚠️ 这段开头原来写的是"**不依赖任何账号**地把每一次收听追加到磁盘"+"先无条件记下来",
// 那是 2026-08-13 收窄**之前**的行为。旧结论留在文件最显眼的位置、新结论埋在下面第 ~96
// 行,2026-08-30 通盘梳理时坐实这误导过判断,故改成开头就把当前条件讲清楚。
//
// ⚠️ 它记不回**本功能上线之前**的收听。那些数据不存在,任何"补回来"的说法都是假的。
//
// ## 格式:JSON Lines,只追加,永不改已写下的字节
//
// 一行一条,`t` 区分行类型。选 append-only 而不是"一个大 JSON 整体重写"(仓库里
// enrich cache / persistedTTLSet 都是后者)的理由:这份日志按播放次数增长、而且每首歌
// 播完都要写一次,整体重写会随历史变长越来越贵;而追加一行永远是常数开销。代价是读的
// 时候要自己折叠(同一 uts 的收听行 + 回执行),那是读侧一次性的成本。
//
// 字段名刻意压到两三个字母:这文件会长到上万行,`artist`/`timestamp` 这种拼法纯属浪费。
type listenLogLine struct {
	// 行类型:"l" = 一次收听;"s" = 一条 Last.fm 提交回执(回填功能写,见下)。
	T string `json:"t"`
	// 行级 schema 版本。以后加字段时老行仍能读 —— 不做整文件版本头,那需要读-改-写。
	V int `json:"v"`
	// 收听开始的 Unix 秒(UTC)。**主键** —— Last.fm 的 track.scrobble 用它当
	// timestamp[i],ListenBrainz 那边也是用同一个值,三方对得上。
	UTS int64 `json:"uts"`
	// 艺人名:存**播放器报的原始标签**。
	//
	// 2026-08-31 起这条更简单了 —— 上送本身就是原样发原始标签(见 lb.go 的 lbMeta),
	// 所以日志里存的跟发出去的是同一个东西。唯一可能的差异是合唱串开关
	// (resolveScrobbleArtist,纯静态判断),回填走同一个函数,结果必然一致。
	// 原注释提到的 lastfmCollapse.resolve 那套联网折叠已随同一次改动删除。
	AR string `json:"ar"`
	TI string `json:"ti"`
	AL string `json:"al,omitempty"`
	// 曲长(秒)。Last.fm 的 duration[i] 是选填但能显著提升编目匹配;更重要的用途是回填
	// 时能**本地复核**一遍 listenThreshold/minTrackSecs 规则,不必信任日志一定干净。
	DUR float64 `json:"dur,omitempty"`
	// 写盘时刻(不是收听时刻)。纯审计用:能认出"曲长 291 秒、uts 在三天前、日志却是刚写的"
	// 这类时钟异常或补写。
	AT int64 `json:"at"`
	// M=1 表示**这条在记录的那一刻就已经通过正常路径镜像给 Last.fm 了**,回填必须跳过它。
	//
	// 2026-08-13 靠 dry-run 抓到:少了这个字段,一个**已经连着** Last.fm 的用户,日志里每
	// 一条都会被判成"待回填"—— 点一次回填就把自己刚听的歌全部重复提交一遍,而 scrobble
	// 落进 Last.fm 基本删不掉。正常路径走的是 mirrorScrobbleTracked,它压根不碰这份日志,
	// 所以"日志里有没有回执行"完全无法反映这个事实,必须在写入时就记下来。
	//
	// ⚠️ **现在已经不再写入这个字段了**(2026-08-13 收窄之后 appendListen 压根不设 M,
	// 全仓没有任何写点;只有 backfill.go 还在**读**)。盘上所有 m=1 都是老版本留下的。
	// 原来这里写的是「取值就是写入那一刻 p.lfm != nil」「凭据死掉那段时间的收听会被记成
	// M=1、从此不再回填」—— 那是旧行为,照它去日志里找 m:1 一条也找不到,会反推出「流程
	// 正常」这个错结论,而真相是那段时间**一行都没写**。
	//
	// 凭据判死那个窗口现在由 recordFailedMirror 兜住了(2026-08-30):判死时照样留痕,
	// 用户重新授权后能靠回填补回来,不必再接受「漏补一条」这个代价。
	M int `json:"m,omitempty"`
}

const listenLogSchemaVersion = 1

var (
	listenLogPath string
	listenLogMu   sync.Mutex
)

// 体量控制:超过 listenLogMaxLines 就压缩到 listenLogKeepLines(丢掉最旧的)。
//
// 数量级参考:一个每天听 40 首的重度用户一年约 1.5 万行,一行 ~110 字节 → 1.6 MB。
// 上限定在 4 万行(约 4.4 MB、两年半)——远超"先用一阵再连账号"这个场景需要的跨度,
// 而回填本身只关心最近这段没提交的部分。
//
// 压缩是整文件重写(读全部 → 留后 N 行 → tmp+rename),所以刻意只在**启动时**做一次,
// 不在每次追加时检查:那会把"追加是常数开销"这个前提毁掉。
const (
	listenLogMaxLines  = 40000
	listenLogKeepLines = 30000
)

// initListenLog 记下路径并做一次体量压缩。启动时调用一次。
func initListenLog(path string) {
	listenLogMu.Lock()
	listenLogPath = path
	listenLogMu.Unlock()
	compactListenLog()
}

// appendListen 追加一条收听 —— 只记"**没能进 Last.fm 的**"那些,供之后回填。
//
// 失败只记日志、不影响调用方:这条记录是为了将来能补提交,写不进去顶多是少补一首,
// 不该让它影响当下这次播放的其它处理。
//
// ⚠️ 调用方只有两种情况该调它:
//
//  1. **当前没有在往 Last.fm 提交**(p.lfm == nil)—— 常规路径,见下面 2026-08-13 那段。
//  2. **提交了但确定没写进去**(recordFailedMirror,2026-08-30 加)—— 镜像失败时补一条,
//     否则这次收听三处都不留痕、永久消失(理由见 recordFailedMirror 的注释)。这一条
//     不破坏下面"不写死数据"的初衷:只有真失败才写,成功路径依旧一行不写。
//
// ⚠️ 并发:第 2 种情况是从 mirrorAsync 的 goroutine 调进来的,所以这个函数(经
// appendListenLogLine 的 listenLogMu)必须保持自带锁、且**不碰任何 poller 状态**。
//
// 2026-08-13 二次收窄:原来是无条件写、再用 M 字段标记"这条当时已经镜像过了"。改成
// 只在没连账号时写,理由有两条:
//
//   - 这份日志的**唯一**用途就是"补上没提交的那段"。一直连着账号的用户写进去的每一行
//     都是注定不会被用到的死数据,却要一直占盘、一直参与折叠计算。
//   - 少一个需要两处保持一致的状态位。M 那条路径正是靠 dry-run 才发现算错的
//     (已连账号的人日志里每条都被判成待补),从源头不写反而更难错。
//
// M 字段的**读取**逻辑保留(见 pendingBackfillListens):老版本已经写下的 m=1 行还在盘上。
func appendListen(artist, title, album string, uts int64, durationSecs float64) {
	if uts <= 0 || title == "" {
		return
	}
	appendListenLogLine(listenLogLine{
		T: "l", V: listenLogSchemaVersion, UTS: uts,
		AR: artist, TI: title, AL: album,
		DUR: durationSecs, AT: time.Now().Unix(),
	})
}

func appendListenLogLine(line listenLogLine) {
	listenLogMu.Lock()
	defer listenLogMu.Unlock()
	if listenLogPath == "" {
		return
	}
	data, err := json.Marshal(line)
	if err != nil {
		log.Printf("listen log: marshal failed: %v", err)
		return
	}
	// collector 全仓库只有 lyricsexport.go 建过目录,而 loadConfig 容忍 config.json
	// 不存在 —— 也就是说这个目录不一定已经在了,自己建一次。
	if err := os.MkdirAll(filepath.Dir(listenLogPath), 0o755); err != nil {
		log.Printf("listen log: mkdir failed: %v", err)
		return
	}
	// 0600:里面没有凭据,但一整份听歌历史本身就是隐私。
	f, err := os.OpenFile(listenLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("listen log: open failed: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(data, '\n')); err != nil {
		log.Printf("listen log: write failed: %v", err)
	}
}

// readListenLog 读出全部行。调用方自己折叠(见 listenLogLine 的注释)。
//
// 解析不了的行**跳过而不是报错**:这是 append-only 文件,断电/磁盘满可能留下一行截断的
// JSON,为了那一行放弃整份历史是最坏的选择。
func readListenLog() []listenLogLine {
	listenLogMu.Lock()
	path := listenLogPath
	listenLogMu.Unlock()
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil // 文件还不存在是正常情况(从没听过歌)
	}
	defer f.Close()

	var out []listenLogLine
	sc := bufio.NewScanner(f)
	// 默认 64KB 上限对单行 JSON 绰绰有余,但显式给足,免得某天有超长专辑名把整份日志读断。
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	bad := 0
	for sc.Scan() {
		raw := sc.Bytes()
		if len(raw) == 0 {
			continue
		}
		var line listenLogLine
		if err := json.Unmarshal(raw, &line); err != nil {
			bad++
			continue
		}
		out = append(out, line)
	}
	if bad > 0 {
		log.Printf("listen log: skipped %d unparseable line(s)", bad)
	}
	return out
}

// compactListenLog 行数超上限时丢掉最旧的那批。启动时调一次,见常量注释。
func compactListenLog() {
	lines := readListenLog()
	if len(lines) <= listenLogMaxLines {
		return
	}
	keep := lines[len(lines)-listenLogKeepLines:]

	listenLogMu.Lock()
	defer listenLogMu.Unlock()
	tmp := listenLogPath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("listen log: compact open failed: %v", err)
		return
	}
	w := bufio.NewWriter(f)
	for _, line := range keep {
		data, err := json.Marshal(line)
		if err != nil {
			continue
		}
		w.Write(append(data, '\n'))
	}
	if err := w.Flush(); err != nil {
		f.Close()
		os.Remove(tmp)
		log.Printf("listen log: compact flush failed: %v", err)
		return
	}
	f.Close()
	// tmp+rename:跟 persistedTTLSet.save 同一个套路,中途崩溃不会留下半份日志。
	if err := os.Rename(tmp, listenLogPath); err != nil {
		os.Remove(tmp)
		log.Printf("listen log: compact rename failed: %v", err)
		return
	}
	log.Printf("listen log: compacted %d lines -> %d", len(lines), len(keep))
}
