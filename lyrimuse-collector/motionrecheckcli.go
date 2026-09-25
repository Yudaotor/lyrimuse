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
// 为什么需要它:自动路径(applyDeviceCoverUpgrade 与 backfillPeripheralFields 末尾,都走
// recheckMotionCoverAgainstCurrentCover)只在"封面刚换身份"或"这条还没有任何结论"时才起。
// 已经 MotionCoverChecked==true、结论是"没有"的存量记录不在那两条路上——那一位就是用来
// 防重复查的,自动路径不该、也不会去动它。这条命令是给这批存量的一次性清理,实测
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
// 三条约束:只挑会受益的条目(见 runRecheckMotionCover 里
// 那两条命中条件)、dry-run 默认、-apply 才真写且要求常驻实例已停(否则它下一次整份保存
// 会把这边刚改的东西原样盖回来)。
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
	// 这份也必须加载。不加载的话 motionCoverFor 对每一张专辑都当"没查过",逐张
	// 重抓 330 KB 的专辑页(还因为 motionCoverPath 为空而存不下来);而
	// motionCoverAlbumHasKnownVideo 更是会对全表回 false,下面第②条命中条件直接哑掉。
	loadMotionCoverCache(filepath.Join(cfgDir, clientName+"-motion-cover-cache.json"))
	if !*apply {
		// 预演不落任何盘:核验时可能要补抓专辑页(见 motionCoverAlbumArtworkFor),那会写
		// motion 缓存;常驻实例这时还开着,两边各写各的整份 map 只会互相覆盖。
		motionCoverMu.Lock()
		motionCoverPath = ""
		motionCoverMu.Unlock()
	}
	os.Exit(runRecheckMotionCover(*apply, *key))
}

// -key:只重验点名的这一条,绕开下面两条命中条件。留着是为了排查——手里已经有一条可疑
// 的 key 时,不必为它跑一遍全量扫描。
func runRecheckMotionCover(apply bool, onlyKey string) int {
	if onlyKey != "" {
		return runRecheckMotionCoverOne(apply, onlyKey)
	}
	enrichMu.Lock()
	var keys []string
	for k, e := range enrichCache {
		if e.MotionCoverURL != "" {
			continue
		}
		_, title, album := splitEnrichKey(k)
		switch {
		case e.MotionCoverChecked:
			// ① 查过了、结论是"这条没有"。值得拿它**现在**的封面再问一次:当初比对用的
			//    可能是一张后来被换掉的封面(见文件头注那个 Prince《Musicology》实测)。
			keys = append(keys, k)
		case motionCoverAlbumHasKnownVideo(e, title, album):
			// ② 一位结论都没有,而这张专辑**本地缓存里已确认**有动态封面 —— 说明它卡在了
			//    那条"fresh 的结论落不到这张封面上"的死角里(见
			//    recheckMotionCoverAgainstCurrentCover 头注)。自动路径现在会自愈,但只在
			//    这首歌下一次被播到时;这里是给存量的一次性清理。
			//    判据必须是 motionCoverAlbumHasKnownVideo 而**不是** motionCoverWorthBackfill:
			//    后者对"专辑还没查过"也回 true,那会把几千条记录扫进来,每条都去抓一次
			//    330 KB 的专辑页——这条命令的定位是清理死角,不是代替日常 backfill。
			keys = append(keys, k)
		}
	}
	enrichMu.Unlock()
	sort.Strings(keys) // 输出顺序稳定,方便人工核对

	fmt.Printf("扫描完成:%d 条命中(结论是没有、或卡在没结论,值得用当前封面重验一次)\n\n", len(keys))

	ctx := context.Background()
	changed, recorded, unchanged, failed := 0, 0, 0, 0
	for _, key := range keys {
		switch recheckOneMotionCoverKey(ctx, apply, key) {
		case "changed":
			changed++
		case "recorded":
			recorded++
		case "unchanged":
			unchanged++
		case "failed":
			failed++
		}
	}
	if apply && changed+recorded > 0 {
		saveEnrichCache()
	}
	verb := "预演"
	if apply {
		verb = "完成"
	}
	fmt.Printf("\n%s:%d 条翻案,%d 条首次定案,%d 条结论不变,%d 条失败",
		verb, changed, recorded, unchanged, failed)
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
	if apply && (result == "changed" || result == "recorded") {
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
	hadVerdict := e.MotionCoverChecked
	e.MotionCoverChecked = false
	e.fillMotionCover(ctx, title, album)
	fmt.Printf("── %s\n", key)
	result := "changed"
	switch {
	case !e.MotionCoverChecked:
		// 这一轮没查成(在飞/请求失败)——不算失败,下次自然再来。
		fmt.Println("   跳过:这一轮没查成(网络/限流),保持原样,下次还会再试")
		return "unchanged"
	case e.MotionCoverURL == "":
		if hadVerdict {
			fmt.Println("   确认:这条记录确实没有动态封面(结论不变)")
			return "unchanged"
		}
		// 这一支**必须往下走去写回**:进来时这条一位结论都没有(卡在死角里的那批),
		// 现在拿它真正在用的封面判出了"确实没有" —— 这是新结论,不落盘的话它每一轮都会
		// 被重新扫进来、重新发两次 HTTP,正是 MotionCoverChecked 那一位要防的事。
		fmt.Println("   定案:这条记录确实没有动态封面(此前一位结论都没有,这次记下来)")
		result = "recorded"
	case e.MotionCoverIdentityVerified:
		fmt.Printf("   翻案(专辑身份核验放行,首帧跟封面对不上):补上动态封面 %s\n", abbrev(e.MotionCoverURL, 72))
	default:
		fmt.Printf("   翻案:补上动态封面 %s\n", abbrev(e.MotionCoverURL, 96))
	}
	if !apply {
		return result
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
	cur.MotionCoverIdentityVerified = e.MotionCoverIdentityVerified
	enrichCache[key] = cur
	enrichDirty = true
	enrichMu.Unlock()
	fmt.Println("   已写入")
	return result
}
