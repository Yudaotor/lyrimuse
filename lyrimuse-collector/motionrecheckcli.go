package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
)

// `collector recheck-motion-cover [-apply]` —— 扫描整份 enrich 缓存,把"这一条已经查过
// 动态封面、结论是没有"的记录,用它**当前**的 cover_url 重新校验一次。
//
// 为什么需要它:applyDeviceCoverUpgrade 已经联动了(见
// recheckMotionCoverAfterDeviceCoverUpgrade),但那条路径只在 CoverSource**从非 device
// 变成 device 那一刻**触发一次——已经是 CoverSource=="device" 的存量记录不会再经过那条
// 升级路径,永远等不到重新校验的机会。这条命令就是补这批存量的一次性清理,实测
// (Prince《Musicology》):同一张专辑两首歌 cover_url 现在字节完全相同、专辑本身确有
// 动态封面,但先解析的那首因为当时 cover_url 还是网易云给的封面、校验没通过,
// MotionCoverChecked 从此锁死;后来 cover_url 被设备直送版本覆盖,却没人再给它一次机会。
//
// 全量复用 fillMotionCover 这同一份生产逻辑(不是另写一套比对代码),保真:
//   - motionCoverFor(albumID) 读的是本地 lyrimuse-motion-cover-cache.json,专辑早就
//     查过的直接命中缓存,不重新抓 Apple 专辑页;
//   - motionCoverMatchesCover 才会真发两次 HTTP(取当前 cover_url 与官方首帧算指纹),
//     开销是"这条记录值不值得算一次 8×8 均值哈希",不是"重新发现整个专辑"。
//
// 三条跟 retranslate-repeated 一致的约束:只挑会受益的条目(MotionCoverChecked 且
// MotionCoverURL 为空)、dry-run 默认、-apply 才真写且要求常驻实例已停(否则它下一次
// 整份保存会把这边刚改的东西原样盖回来)。
func runRecheckMotionCoverCLI(args []string) {
	fs := flag.NewFlagSet("recheck-motion-cover", flag.ExitOnError)
	apply := fs.Bool("apply", false, "真正写回缓存;不加就是预演,只打印计划")
	key := fs.String("key", "", `只重验这一条("歌手|歌名|专辑"),忽略下面的批量扫描条件——见 -key 的说明`)
	if err := fs.Parse(args); err != nil {
		log.Fatalf("recheck-motion-cover: %v", err)
	}

	if configDir() == "" {
		log.Fatalf("recheck-motion-cover: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cfgDir := configDir()

	if *apply && !ensureExclusiveForDedupe(cfgDir) {
		fmt.Fprintln(os.Stderr, "拒绝执行:collector 正在运行(或锁文件不可用)。")
		fmt.Fprintln(os.Stderr, "请先停掉常驻实例再跑:launchctl bootout gui/$UID/com.lyrimuse.collector")
		os.Exit(1)
	}

	loadEnrichCache(filepath.Join(cfgDir, clientName+"-enrich-cache.json"))
	os.Exit(runRecheckMotionCover(*apply, *key))
}

// -key 补的是比"已经 checked=true 卡住"更早一步的坑:device 封面的记录只有在
// `applyDeviceCoverUpgrade` 升级封面来源**那一刻**才会经 `recheckMotionCoverAfterDeviceCoverUpgrade`
// 校验一次;之后 `backfillPeripheralFields` 每一轮重新解析出来的 `fresh.CoverURL` 几乎必然
// 不是那张 device 封面(它传的 deviceCoverURL 恒为空,理由见 resolveTrackEnrichment 参数注释),
// `motionCoverFreshResultAppliesTo` 因此正确地拒绝把结论挪给这条记录——但连带的后果是
// `MotionCoverChecked` 永远停在**没查过**(不是"查过没有"),既不进上面那条批量扫描的
// 命中条件,也没有任何自然重试路径会再碰它。这是设计上的死角,不是一次性网络抖动,
// 只能手动点名重验。批量扫描条件刻意不跟着放宽:那会让全量 device 封面记录(数以千计)
// 每次都被扫进去重新发两次 HTTP,这条命令的定位是"点名重验一条",不是新增一条自动巡检。
func runRecheckMotionCover(apply bool, onlyKey string) int {
	if onlyKey != "" {
		return runRecheckMotionCoverOne(apply, onlyKey)
	}
	enrichMu.Lock()
	var keys []string
	for k, e := range enrichCache {
		if e.MotionCoverChecked && e.MotionCoverURL == "" {
			keys = append(keys, k)
		}
	}
	enrichMu.Unlock()
	sort.Strings(keys) // 输出顺序稳定,方便人工核对

	fmt.Printf("扫描完成:%d 条命中(已查过动态封面、结论是没有,值得用当前封面重验一次)\n\n", len(keys))

	ctx := context.Background()
	changed, unchanged, failed := 0, 0, 0
	for _, key := range keys {
		switch recheckOneMotionCoverKey(ctx, apply, key) {
		case "changed":
			changed++
		case "unchanged":
			unchanged++
		case "failed":
			failed++
		}
	}
	if apply && changed > 0 {
		saveEnrichCache()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s:%d 条翻案,%d 条结论不变,%d 条失败", verb, changed, unchanged, failed)
	if !apply {
		fmt.Print("(加 -apply 才真写)")
	}
	fmt.Println()
	if failed > 0 {
		return 1
	}
	return 0
}

// runRecheckMotionCoverOne:-key 的入口,只处理点名的这一条,不跑上面那条批量扫描。
func runRecheckMotionCoverOne(apply bool, key string) int {
	enrichMu.Lock()
	_, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok {
		fmt.Printf("缓存里没有这一条:%q\n", key)
		return 1
	}
	result := recheckOneMotionCoverKey(context.Background(), apply, key)
	if apply && result == "changed" {
		saveEnrichCache()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s", verb)
	if !apply {
		fmt.Print("(加 -apply 才真写)")
	}
	fmt.Println()
	if result == "failed" {
		return 1
	}
	return 0
}

// recheckOneMotionCoverKey 对一条记录重验一次、打印过程,返回它落在哪一类
// ("changed"/"unchanged"/"failed",空串是"写回时条目已被删掉"这一个不计入三类汇总的边缘情况,
// 跟原来批量循环里那条 `continue` 不计数是同一行为)。全量复用 fillMotionCover 这同一份生产
// 逻辑,不是另写一套比对代码——理由见文件头注。
func recheckOneMotionCoverKey(ctx context.Context, apply bool, key string) string {
	enrichMu.Lock()
	e, ok := enrichCache[key]
	enrichMu.Unlock()
	if !ok {
		fmt.Printf("── %s\n   跳过:缓存里没有这一条\n", key)
		return "failed"
	}
	_, title, album := splitEnrichKey(key)
	if title == "" {
		fmt.Printf("── %s\n   跳过:key 不是 \"歌手|歌名|专辑\" 三段\n", key)
		return "failed"
	}
	e.MotionCoverChecked = false
	e.fillMotionCover(ctx, title, album)
	fmt.Printf("── %s\n", key)
	switch {
	case !e.MotionCoverChecked:
		// 这一轮没查成(在飞/请求失败)——不算失败,下次自然再来。
		fmt.Println("   跳过:这一轮没查成(网络/限流),保持原样,下次还会再试")
		return "unchanged"
	case e.MotionCoverURL == "":
		fmt.Println("   确认:这条记录确实没有动态封面(结论不变)")
		return "unchanged"
	default:
		fmt.Printf("   翻案:补上动态封面 %s\n", abbrev(e.MotionCoverURL, 96))
	}
	if !apply {
		return "changed"
	}
	enrichMu.Lock()
	cur, still := enrichCache[key]
	if !still {
		// 这期间被"歌词管理"删掉了——不要把它复活回去,跟 backfillPeripheralFields 同款。
		enrichMu.Unlock()
		fmt.Println("   写回时这条已不在缓存里,跳过")
		return ""
	}
	cur.MotionCoverChecked = e.MotionCoverChecked
	cur.MotionCoverURL = e.MotionCoverURL
	cur.MotionPreviewURL = e.MotionPreviewURL
	enrichCache[key] = cur
	enrichDirty = true
	enrichMu.Unlock()
	fmt.Println("   已写入")
	return "changed"
}
