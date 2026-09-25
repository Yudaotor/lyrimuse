package main

import (
	"log"
	"os"
	"sync/atomic"
	"time"
)

// 配置热重读:改设置不再需要重启 collector。
//
// # 为什么改
//
// 这里原本是 `var features featureFlags` —— 启动时 loadFeatureFlags 赋值一次,运行期再也不变。
// 于是设置页每保存一次,App 就得 `launchctl kickstart -k` 把 collector 整个重启一遍才能生效。
// 那一下的真实代价实测是 **40~47 秒**:新进程要在 138MB 的 enrich 缓存之上跑完存量迁移、把 20046
// 个歌词文件全量导入导出,才会打出启动横幅、开始盯播放 —— 这段时间歌词与「正在播放」推送整个停摆。
// 而设置页那句「正在应用到后台服务…」只转 1~3 秒就收起(它把"launchd 报出了一个新 pid"当成完成),
// 于是用户看到的是"提示说应用完了、实际过了半分多钟才生效"。
//
// # 为什么以前只能逐键放行
//
// 在此之前是一套**白名单**:每支持一个键热更新,就要在 collector 侧单独写一份 Stat + 重读
// (lyricsourcesreload.go / lastfmexclude.go),再在 App 侧 CollectorRestartPolicy.hotReloadedKeys
// 里补上键名,两边对不齐就白白重启。35 个键里只放行了 9 个,而且**漏过**:接汽水音乐源时 Go 侧
// readLyricSources 读了 soda_lyrics、Swift 白名单没跟上,于是"取消勾选汽水"重启、取消别的源不重启,
// 不报错、只是慢。
//
// 逐键放行的前提其实并不成立 —— 逐个核实过 35 个键在 collector 里的消费方式,除 lyrics_dir 外
// **全部是运行期现读** `features().X`,没有一个在启动时被展开成别的包级状态。
// (`lyrics_source_mode` / `lyrics_source_order` 的老注释说它们"启动时展开进包级变量、决定走哪条
// 取词路径",核实下来不成立:它们只在 enrich.go 取词时现读。)所以真正的障碍从来不是"这些设置需要
// 重启",而是"features 这个变量本身不会变"。
//
// # 怎么改的
//
// 包级变量换成同名**函数** features(),内部是一份原子快照。保留 `features` 这个名字是刻意的:
// 旧写法 `features.X` 会直接编译失败,183 个读点、53 个赋值点一个都漏不掉 —— 靠编译器兜底。
//
// 读到的是**快照拷贝**,所以单次调用内前后一致;一轮解析中途改设置,最坏是这一轮里两次判定不一致
// (比如多查一个源),下一轮自然收敛,不写坏任何缓存 —— 这个取舍与 lyricsourcesreload.go 当初为
// lyrics_sources 定的口径相同,只是现在推广到了全部键。
//
// # 两个必须守住的边界
//
//  1. **lyrics_dir 换了要搬一次家**。它不是现读就完的键:换目录要先把新目录里的文件导入缓存,
//     再把 lyricsDir() 指过去、整份导出一遍。这一步放到后台 goroutine 里做(switchLyricsDir,
//     见 lyricsdirswitch.go),不挡住读快照的调用方。
//  2. **坏文件不许覆盖好配置**。热重读走 readFeatureFlags(不吞错),解析失败就保留当前快照。
//     用 loadFeatureFlags 会把"文件坏了一下"变成"用户所有设置当场重置成出厂值"。
//
// # 节流
//
// lyricsourcesreload.go 那套是每次调用都 Stat —— 它的读点稀疏(每首歌几次),这么做没问题。
// features() 有 183 个读点、还在 poller 的每轮里,不能每次都进内核。所以每
// featuresReloadInterval 最多探一次盘:抢到 CAS 的那个 goroutine 去 Stat,其余直接拿当前快照走。
const featuresReloadInterval = 1 * time.Second

var (
	featuresSnapshot  atomic.Pointer[featureFlags]
	featuresPath      atomic.Pointer[string]
	featuresCheckedAt atomic.Int64 // 上次探盘的时刻(UnixNano)
	featuresMTime     atomic.Int64
	featuresSize      atomic.Int64
)

// features 取这一刻生效的配置快照。
func features() featureFlags {
	maybeReloadFeatures()
	if p := featuresSnapshot.Load(); p != nil {
		return *p
	}
	return featureFlags{}
}

// setFeatures 直接换掉当前快照。启动时由 main() / 各 CLI 子命令调用;测试里也用它。
func setFeatures(f featureFlags) {
	featuresSnapshot.Store(&f)
}

// setFeaturesPath 登记 features.json 的位置,并把它当下的 mtime/size 作为基线 —— 之后这个文件
// 一变,下一次 features() 就会读到新值。
//
// **只有常驻进程登记**。各 CLI 子命令只 setFeatures、不登记路径,于是 maybeReloadFeatures
// 直接早退、行为与热重读上线之前逐字节一致:它们不长跑,没有"中途被改"这回事,反倒是多一次 Stat
// 都是白费。
func setFeaturesPath(path string) {
	if path == "" {
		featuresPath.Store(nil)
		return
	}
	p := path
	featuresPath.Store(&p)
	featuresCheckedAt.Store(time.Now().UnixNano())
	if st, err := os.Stat(path); err == nil {
		featuresMTime.Store(st.ModTime().UnixNano())
		featuresSize.Store(st.Size())
	}
}

func maybeReloadFeatures() {
	pp := featuresPath.Load()
	if pp == nil || *pp == "" {
		return // 没登记路径(CLI 子命令)= 不热重读
	}
	now := time.Now().UnixNano()
	last := featuresCheckedAt.Load()
	if now-last < int64(featuresReloadInterval) {
		return
	}
	// 只让一个 goroutine 去探盘,其余这一拍用当前快照 —— 配置晚 1 秒生效无所谓,
	// 183 个读点一起 Stat 才是问题。
	if !featuresCheckedAt.CompareAndSwap(last, now) {
		return
	}
	st, err := os.Stat(*pp)
	if err != nil {
		return // 文件暂时读不到(被换名的那一瞬间等)——保留当前快照,下一拍再看
	}
	mtime, size := st.ModTime().UnixNano(), st.Size()
	if mtime == featuresMTime.Load() && size == featuresSize.Load() {
		return
	}
	next, err := readFeatureFlags(*pp)
	if err != nil {
		// 保留当前快照。这里若退回默认值,一次坏读就等于把用户所有设置重置成出厂值。
		// mtime 照样推进:同一份坏文件不必每秒重试一遍,等它下次真被改写。
		featuresMTime.Store(mtime)
		featuresSize.Store(size)
		log.Printf("features: %s changed but is unreadable (%v) — keeping the settings currently in effect", *pp, err)
		return
	}
	prev := featuresSnapshot.Load()
	featuresMTime.Store(mtime)
	featuresSize.Store(size)
	featuresSnapshot.Store(&next)
	log.Printf("features: reloaded without a restart")
	if prev != nil && prev.LyricsDir != next.LyricsDir {
		go switchLyricsDir(next.LyricsDir)
	}
	// 译文语言换了:旧语言的机翻清掉(启动时那一遍管不到运行中的修改,见 invalidateStaleTranslations)。
	// 放后台:这里可能正被持着 enrichMu 的调用方经 features() 调到,而清理自己要拿那把锁。
	if prev != nil && prev.LyricsTranslationLanguage != next.LyricsTranslationLanguage {
		go reapplyTranslationLanguage()
	}
}
