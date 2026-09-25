package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
)

// 启动期存量迁移的「已完成水位」。
//
// 为什么需要:有些迁移做的是**存量规整** —— 把全库扫一遍改成新形态,改完就稳定了,而运行期
// 写入的新数据在各自的链路上已经是新形态。这类迁移原本每次进程启动都全量重跑一遍。实测
// migrateLyricTimelines 在 6952 条缓存上要 **9~10 秒**,连跑两轮第二轮 0 条改动 —— 纯无用功。
//
// 而 collector 重启得很频繁(App 重建、「歌词管理」改完 kickstart、崩溃拉起),每次都要付这
// 一笔。用户侧的现象是"刚重启那阵子歌词要等一两分钟才出来":实测一次冷启动从 SIGTERM 到歌词
// 出现 106 秒,其中 **47 秒**花在打出 "starting" 之前 —— 那段时间进程活着、却一行日志都没有,
// 排查时完全是黑盒(所以顺带给那一段加了分步计时,见 main.go)。
//
// 水位按**迁移名 + 版本号**记。改了那道迁移的算法就把版本号 +1,存量会被重扫一遍。
//
// 只有同时满足这两条的迁移才配用它:
//
//  1. **幂等** —— 对同一份数据重复跑结果不变;否则"跳过"就不是省时间,是改行为。
//  2. **运行期已在源头做了同样的事** —— 否则新写进来的数据会被永远跳过。
//     反例:migrateYRCWhitespaceTokens 看着像一次性存量清洗(它的头注也这么写),实测却每次
//     启动都还能捞到十来条新的(源头 richsyncToYRC 的归并没盖全),它就**不能**加水位闸。
//     好在它只要 0.5 秒,不加也无所谓 —— 把闸留给真正贵的那道。
//
// 引入外来数据的两个入口 —— adoptEnrichRestore(配置搬家,别的机器导出的决策数据)与
// importLyricsFromFiles(用户手改 lyrics/ 里的文件)—— 会主动作废水位,让这一轮照常全量跑。
// 两者在 main.go 里都排在这些迁移**之前**,顺序天然成立。
//
// 路径没设时(各 CLI 子命令就不设)migrationDone 恒为 false、markMigrationDone 是空操作,
// 行为与加这层之前逐字节一致 —— 水位是常驻进程的启动优化,不是语义的一部分。
//
// 那么 CLI 子命令改完缓存、常驻进程带着旧水位重启,会不会漏掉该做的迁移?对现有这几个
// 不会,逐个看过:backfill-roma 与 regenerate-jyutping 改的是 LyricsRoma 的**内容**,
// 不动 Lyrics / LyricsYRC 的时间轴结构,而 migrateLyricTimelines 只在行级轴与逐字轴
// 打架时才重挂(罗马音是被动跟着 remap 走的);search-lyrics 手动选定写的是
// manual_lyrics,那类条目这道迁移本来就整条跳过。
// 将来若有 CLI 会改 Lyrics / LyricsYRC 本身,它得自己调 invalidateMigrationState ——
// 这条判断是**按当下这几个子命令的行为**下的,不是这套机制自带的保证。
var (
	migrationStateMu   sync.Mutex
	migrationStatePath string
	migrationState     map[string]int
)

const (
	// migrationLyricTimelines:migrateLyricTimelines 的水位名。
	migrationLyricTimelines = "lyric_timelines"
	// migrationLyricTimelinesVersion:改了 rehangLRCOnYRC / wordTimingContradictsLRC 的
	// 判据就 +1 —— 存量会被重扫一遍,否则老数据永远停在旧算法的结果上。
	migrationLyricTimelinesVersion = 1

	// migrationQRCLeftoverTokens:修 qrcToYRC 旧实现漏转的残缺两数字词条(qrcleftovertokens.go)。
	// 源头已改成按标记位置切分,不会再产生,所以是真正一次性的。
	migrationQRCLeftoverTokens        = "qrc_leftover_tokens"
	migrationQRCLeftoverTokensVersion = 1

	// migrationYRCWhitespace:纯空白词条归并(yrcwhitespace.go)。
	// 它是在 qrcToYRC / krcToYRC 两个出口都补上源头归并**之后**才够格加水位闸的 ——
	// 在那之前每解析一首新歌就又产生一批,这道"迁移"跑了 39 次也收敛不了(日志实测:
	// 最近两次只隔 22 分钟、分别修 14 条和 13 条)。加闸前先确认源头还在做这件事。
	migrationYRCWhitespace        = "yrc_whitespace"
	migrationYRCWhitespaceVersion = 1
)

// loadMigrationState 读水位文件。文件不存在 / 解不出来都当作"一道都没跑过",照常全量跑 ——
// 这一层最坏的失效方式必须是"多跑一遍",不能是"少跑一遍"。
func loadMigrationState(path string) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	migrationStatePath = path
	migrationState = map[string]int{}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var got map[string]int
	if err := json.Unmarshal(data, &got); err != nil {
		log.Printf("migration state: %s unreadable (%v), re-running every startup migration", path, err)
		return
	}
	migrationState = got
}

// migrationDone:这道迁移的这个版本跑过了吗。
func migrationDone(name string, version int) bool {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath == "" {
		return false
	}
	return migrationState[name] >= version
}

// markMigrationDone 记下水位并立刻落盘 —— 落盘失败只记一行日志:代价是下次启动多跑一遍,
// 不值得让它影响启动流程。
func markMigrationDone(name string, version int) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath == "" {
		return
	}
	if migrationState == nil {
		migrationState = map[string]int{}
	}
	if migrationState[name] == version {
		return
	}
	migrationState[name] = version
	saveMigrationStateLocked()
}

// invalidateMigrationState 作废全部水位:有外来数据进了缓存,这一轮的存量迁移必须照常跑。
func invalidateMigrationState(why string) {
	migrationStateMu.Lock()
	defer migrationStateMu.Unlock()
	if migrationStatePath == "" || len(migrationState) == 0 {
		return
	}
	log.Printf("migration state: cleared (%s) — startup migrations will run in full this round", why)
	migrationState = map[string]int{}
	saveMigrationStateLocked()
}

func saveMigrationStateLocked() {
	data, err := json.Marshal(migrationState)
	if err != nil {
		return
	}
	if err := os.WriteFile(migrationStatePath, data, 0o644); err != nil {
		log.Printf("migration state: save failed (%v) — next startup will re-run the migrations", err)
	}
}
