package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// 酷狗 3.3.2 把**当前这一句歌词**发布成 MediaRemote 的 artist。
//
// 别把它归到「Mac Catalyst」头上:这个 App 在**正常工作**的那些版本上同样是 Catalyst 构建
// (见 docs/features/02-playback-source.md「别把它归到『Mac Catalyst』头上」),那是共同点、不是
// 差异点。哪次变更引入的没有验证过,所以判据只认**实际观测到的行为**,不认版本号。
//
// # 现象
//
// 同一首歌播放期间,`title` 与 `duration` 纹丝不动,`artist` 每唱一句换一次,
// `contentItemIdentifier` 跟着一起换。实测一首歌的连续读数:
//
//	title='甲乙丙丁 (你我怎么两清)' dur=210 artist='假装你还在身旁'
//	title='甲乙丙丁 (你我怎么两清)' dur=210 artist='墙上的合照剩一半'
//	title='甲乙丙丁 (你我怎么两清)' dur=210 artist='你晾的衣服还没干'
//
// 推出来的不只是歌词正文:LRC 头部那几行制作信息照发,于是开播头十几秒的"歌手"依次是
// `原唱：谈柒柒` `作曲：廖伟志` `艺人统筹：小帅` `发行：华声时代` `【版权所有 未经许可 不得翻`。
// 这个版本还**从不上报专辑**(载荷里根本没有 album 键)。
//
// 不修的话每一句歌词都是一次"换歌":曲目身份 key 变 到 重跑一整轮十源检索、重推 relay、
// 而且把歌词当歌手名提交进 Last.fm / ListenBrainz 的收听记录 —— 站外那份是收不回来的。
//
// 别指望用户能关掉:酷狗设置里那个"桌面歌词"开关管的是悬浮窗,实测关掉之后这条
// 推送照旧。原生 macOS 版(20.x 那条线)没有这个行为。
//
// # 判据只认结构,不认内容
//
// 判"这个 artist 像不像歌词"是条死路(歌名式的歌词、纯英文歌词、上面那些制作信息行,
// 没有一个稳定特征)。这里只看一件事:**同一个 (title, duration) 之内 artist 从一个
// 非空值变成了另一个非空值**。正常播放下这不可能发生 —— 真换歌 title 必变。
//
// 只对酷狗的 bundle id 生效。原生版不会在一首歌里换署名,所以这套判定对它永不触发;
// 收窄到实测过的播放器,同"改播放进度只改触发它的那个播放器"是同一条规矩。
//
// 空串不参与判定:有的播放器先报 title 后补 artist,那是补全不是污染。

// kugouNowPlayingTimeout:单次 plutil 调用的墙钟上限,防"盘卡住 / 文件被写爆"拖住轮询。
const kugouNowPlayingTimeout = 4 * time.Second

// kugouNowPlayingMaxBytes 是 plutil 输出的大小上限。本机单首队列转出来 7.7KB,
// 上限是防"队列被塞进上万首"时把内存吃光,不是格式约束。
const kugouNowPlayingMaxBytes = 16 << 20

// kugouNowPlayingOverride 让单测把文件指到临时路径。空 = 用真实路径。
var kugouNowPlayingOverride string

// kugouNowPlayingPath 是酷狗记"此刻在播哪一首"的那份 plist。
//
// 跟 kugouUpcomingPath 的队列库是两份东西:那个是整条播放队列(切歌那一秒重写),
// 这个只记当前曲目,而且**播放中不写** —— 只在切歌和暂停这两个时刻落盘,里面的
// `currentProgress` 是那一刻的起播位置,不是实时进度,别拿它当播放头。
func kugouNowPlayingPath() string {
	if kugouNowPlayingOverride != "" {
		return kugouNowPlayingOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.kugou.mac.Music/Data/Library",
		"Preferences/userCurrentPlayList.plist")
}

// kugouNowPlayingTrack 从解析好的 plist 里取当前曲目的署名与歌名。
//
// 结构是 `userPlayList => [ [队列...], {当前曲目}, "0" ]` —— 当前曲目是**直接挂在
// 数组上的那个 dict**,不在队列数组里面。所以这里扫的是"第一个带 musicName 的 dict",
// 队列那一项是数组、会被跳过。
//
// 署名优先 singerName:它是主歌手,跟这个播放器**没被污染时**报的 artist 逐字一致
// (实测 media-control 报 `Stake`,musicName 是 `Stake、TwoP - 爱情慢慢来`)。拿全署名
// 换上去会凭空造出一个与历史缓存 key 对不上的写法。singerName 空了才退回拆 musicName。
//
// credit 一并带出来只为一件事:判"播放器报的这个署名是不是这首歌的某种写法"。
// 见 kugouLocalContradicts。
func kugouNowPlayingTrack(root any) (kugouLocalTrack, bool) {
	m, _ := root.(map[string]any)
	if m == nil {
		return kugouLocalTrack{}, false
	}
	list, _ := m["userPlayList"].([]any)
	for _, item := range list {
		d, _ := item.(map[string]any)
		if d == nil {
			continue
		}
		name, _ := d["musicName"].(string)
		if name == "" {
			continue
		}
		credit, t := kugouUpcomingSplit(name)
		if t == "" {
			continue
		}
		artist := credit
		if s, _ := d["singerName"].(string); s != "" {
			artist = s
		}
		return kugouLocalTrack{artist: artist, credit: credit, title: t}, true
	}
	return kugouLocalTrack{}, false
}

// kugouLocalTrack 是本地那份 plist 里记的当前曲目。
type kugouLocalTrack struct {
	// artist:singerName(主歌手)。**纠正用它** —— 跟这个播放器没被污染时报的 artist
	// 逐字一致(实测 media-control 报 `Stake`,musicName 是 `Stake、TwoP - 爱情慢慢来`)。
	artist string
	// credit:musicName 里 "歌手 - 歌名" 的那一半,多人时是全署名(`Stake、TwoP`)。
	// **只用来比对**,不拿它换上去 —— 那会凭空造出一个与历史缓存 key 对不上的写法。
	credit string
	title  string
}

// kugouReadNowPlaying 读那份 plist 并取出当前曲目。零外部依赖:用系统自带的 plutil
// 转成 XML 再解,同 qqUpcoming 的路数。
//
// 路径由调用方 Stat 过(它要那个 mtime 做缓存),"被 TCC 拒"也在那边留痕,所以这里
// 不再 Stat 第二次 —— plutil 自己对读不到的文件只给退出码,拿不到 fs.ErrPermission。
func kugouReadNowPlaying(path string) (kugouLocalTrack, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), kugouNowPlayingTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", path).Output()
	if err != nil {
		return kugouLocalTrack{}, false
	}
	if len(out) > kugouNowPlayingMaxBytes {
		return kugouLocalTrack{}, false
	}
	root, err := parsePlistXML(out)
	if err != nil {
		return kugouLocalTrack{}, false
	}
	return kugouNowPlayingTrack(root)
}

// kugouLyricArtistState 是这套判定的全部状态。纯函数 advanceKugouLyricArtist 只读写它的值,
// 不碰包级变量,好让单测直接覆盖。
type kugouLyricArtistState struct {
	bundle   string
	title    string
	duration float64
	// first:这首歌**第一次**见到的非空署名。判定成立后拿它兜底 —— 实测切歌头几拍
	// 的 artist 通常还是真署名(歌词要等第一句唱出来才顶上去)。
	//
	// 别把它当可靠真值:有的歌第一拍就已经是歌词(开头即有词,或者接着上一首的
	// 歌词窗口),那时 first 存的就是一句歌词。它的作用是**让身份稳定下来**,不是保证
	// 署名正确;署名正确要靠 resolved。
	first    string
	poisoned bool
	// resolved:从本地 plist 读到的这首歌。一首歌只认一次,hasResolved 为真时它才有效。
	resolved    kugouLocalTrack
	hasResolved bool
	// probedAt / probed:上次真正解析 plist 时它的 mtime。那份文件只在切歌/暂停时重写,
	// 所以同一版解析过一次没匹配上,就不必每拍再 exec 一次 plutil。
	probedAt time.Time
	probed   bool
}

// advanceKugouLyricArtist 推进一拍并返回新状态。纯函数。
//
//   - 不是酷狗 / 没有曲名 到 空状态(这套判定不参与);
//   - 换曲目(title 或 duration 变了)到 重新起判,记下这一拍的署名;
//   - 同一曲目内署名从一个非空值变成另一个非空值 到 判定成立,之后本曲一直成立。
func advanceKugouLyricArtist(prev kugouLyricArtistState, bundle, title, artist string, duration float64, confirmed bool) kugouLyricArtistState {
	if bundle != kugouMusicBundleID || title == "" {
		return kugouLyricArtistState{}
	}
	if prev.bundle != bundle || prev.title != title || prev.duration != duration {
		// confirmed:这台机器上的这个播放器**这次运行里已经被坐实**会拿歌词冒充署名。
		// 污染是播放器的属性、不是某一首歌的,所以换歌之后直接从"已判定"起步 —— 不必
		// 再等它换第二次署名,那十来秒的脏署名同样会推给网页和收听记录。
		return kugouLyricArtistState{
			bundle: bundle, title: title, duration: duration, first: artist, poisoned: confirmed,
		}
	}
	next := prev
	switch {
	case next.first == "":
		// 先报曲名后补署名是补全,不是污染。
		next.first = artist
	case artist != "" && artist != next.first:
		next.poisoned = true
	}
	return next
}

var (
	kugouLyricArtistMu    sync.Mutex
	kugouLyricArtistValue kugouLyricArtistState
	// kugouArtistPoisonConfirmed:这次运行里判定过一次就一直为真。原生 macOS 版不会
	// 触发判定,所以它也永远不会被置上 —— 判据仍然只认实际观测到的行为,不认版本号。
	kugouArtistPoisonConfirmed bool
)

// kugouFixedArtist 判定这一拍的署名是不是被歌词顶掉了,是就给出该用的那个。
// ok=false 表示不必改(不是这个播放器 / 还没判定成立 / 什么都问不出来)。
//
// 换在**原始载荷刚解析出来**那一层(fetchRawMediaControlState),不是等 extract 出
// snapshot 之后 —— 那之前还有两处拿原始署名算 key:播放锚点表 / 位置记忆的
// `raw.Artist + "|" + raw.Title`,以及 `currentPositionBias` 查 App 写来的偏置记录
// (App 那边写的是**纠正后**的署名)。在 snapshot 层换,这两处会静默地对不上,
// 表现是位置每唱一句歌词重置一次、锚点滞后补偿查不到。
func kugouFixedArtist(bundle, title, artist string, duration float64) (string, bool) {
	kugouLyricArtistMu.Lock()
	defer kugouLyricArtistMu.Unlock()
	next := advanceKugouLyricArtist(kugouLyricArtistValue, bundle, title, artist, duration, kugouArtistPoisonConfirmed)
	defer func() { kugouLyricArtistValue = next }()
	// advanceKugouLyricArtist 只在两种情况下置 poisoned:结构证据成立,或者这个播放器
	// 早就坐实过。所以此刻它为真就意味着**看到过署名在同一首歌里变**。
	structural := next.poisoned
	if !next.poisoned {
		// 还没看见署名变过。本地那份是唯一能提前分辨的证据,见 kugouLocalContradicts。
		if next.bundle == "" || !kugouLocalContradicts(&next, title, artist) {
			return "", false
		}
		next.poisoned = true
	}
	// 只有结构证据才升级成**播放器级**结论。
	//
	// 两条判据强度不一样:结构证据是亲眼看到同一首歌里署名换了个值,正常播放器做不出来;
	// 交叉验证则依赖本地那份和播放器报的写法能对上 —— loosenEnrichKey 折得平繁简 / 大小写 /
	// 空格 / 多歌手分隔符,**折不平写法本身的差异**(播放器报 `A feat. B`、本地记 `A、B`
	// 就会判成对不上)。让弱证据也置上这个标志,一次窄条件误判就会从"这一首歌"扩散成
	// "这个播放器一直这样",之后每首歌第一拍都按被污染处理。
	if structural {
		kugouArtistPoisonConfirmed = true
	}
	fixed := ""
	local, haveLocal := resolveKugouLocalTrack(&next, title)
	switch {
	case haveLocal && kugouArtistMatchesLocal(next.first, local):
		// 这首歌第一次见到的署名跟本地那份对得上 —— 它是干净的,而且是**播放器自己的写法**。
		// 优先用它:本地那份的 singerName 只有主歌手,拿它顶上去会把一个正确的多人署名削掉
		// 合唱者(实测 media-control 报 `少司命、新乐尘符`,singerName 只有 `少司命`)。
		fixed = next.first
	case haveLocal && local.artist != "":
		fixed = local.artist
	case next.first != "":
		fixed = next.first
	default:
		return "", false
	}
	// App 侧**必须**用同一个署名:它自己也读 media-control,而歌词缓存的 key 是
	// `artist|title|album`。这边换了、那边没换,App 就再也查不到 collector 刚写进去的
	// 那条歌词。见 playerartistfix.go。
	publishPlayerArtistFix(bundle, title, fixed, kugouArtistPoisonConfirmed)
	return fixed, true
}

// restoreKugouArtistPoisonConfirmed 把上一个进程留在 lyrimuse-player-artist-fix.json 里的播放器级
// 结论恢复进这次运行,见 setPlayerArtistFixPath。
func restoreKugouArtistPoisonConfirmed() {
	kugouLyricArtistMu.Lock()
	kugouArtistPoisonConfirmed = true
	kugouLyricArtistMu.Unlock()
}

// kugouKnownArtistFix 只查已经判定下来的结论,自己不判定。
//
// 给**另外再问一次 media-control** 的调用点对齐用(封面就是这么一条:fetchNowPlayingArtwork
// 会重新 exec 一次拿 artworkData,再拿载荷里的署名跟当前曲目核对)。那种调用一首歌只发生
// 一次,看不到署名在变,让它参与判定只会把状态机搅乱;它要的也只是"主路径此刻用的是哪个
// 署名",好让两边用同一把尺子。
//
// 漏了这一步的后果很隐蔽:核对恒不相等 → 系统直送封面每次都被丢掉 → 悄悄退回网络
// 检索,没有任何错误日志。
func kugouKnownArtistFix(bundle, title string) (string, bool) {
	kugouLyricArtistMu.Lock()
	defer kugouLyricArtistMu.Unlock()
	st := kugouLyricArtistValue
	if !st.poisoned || st.bundle != bundle || st.title != title {
		return "", false
	}
	if st.hasResolved && st.resolved.artist != "" {
		return st.resolved.artist, true
	}
	if st.first != "" {
		return st.first, true
	}
	return "", false
}

// resolveKugouLocalTrack 查本地 plist 要这首歌,查不到返回 ok=false。
//
// 那份 plist 比 MediaRemote 晚一步:换曲时 MediaRemote 会先报出新曲名(载荷里还没有
// duration、playing 仍是 false),plist 要等这首歌真的开始播才重写。所以歌名对不上就
// 什么都不给、等下一拍 —— 别拿上一首的署名往这一首身上按。
func resolveKugouLocalTrack(st *kugouLyricArtistState, title string) (kugouLocalTrack, bool) {
	if st.hasResolved {
		return st.resolved, true
	}
	path := kugouNowPlayingPath()
	if path == "" {
		return kugouLocalTrack{}, false
	}
	fi, err := os.Stat(path)
	if err != nil {
		noteLocalCacheDenied("kugou", path, err)
		return kugouLocalTrack{}, false
	}
	if st.probed && fi.ModTime().Equal(st.probedAt) {
		return kugouLocalTrack{}, false // 这一版解析过了,没匹配上;等它下次重写
	}
	noteLocalCacheReadable("kugou")
	st.probedAt, st.probed = fi.ModTime(), true
	local, ok := kugouReadNowPlaying(path)
	if !ok || local.artist == "" {
		return kugouLocalTrack{}, false
	}
	if loosenEnrichKey(local.title) != loosenEnrichKey(title) {
		return kugouLocalTrack{}, false
	}
	st.resolved, st.hasResolved = local, true
	return local, true
}

// kugouLocalContradicts 在本地那份说"这首歌的署名不长这样"时为真。
//
// 结构判据(同一首歌里署名换了个值)要等它**唱到第二句**才成立,而那之前的十来秒照样
// 会推给网页和收听记录、还会在歌词缓存里留下一条以歌词为歌手名的条目 —— 实测撞上过
// 一次:一首歌开播第一拍报的是 LRC 头部的 `词：方木`,先走完了一整轮十源检索。本地那份
// 在换歌那一刻就重写好了,是唯一能**提前**分辨的证据。
//
// 比**两种**写法(主歌手 singerName 与 musicName 里的全署名),少比一种就会误伤原生
// macOS 版:它报哪一种都是对的,而这里判错的代价是把一个正确的多人署名换成主歌手、
// 悄悄丢掉合唱者。两种都对不上的才是歌词。
func kugouLocalContradicts(st *kugouLyricArtistState, title, artist string) bool {
	if title == "" || artist == "" {
		return false
	}
	local, ok := resolveKugouLocalTrack(st, title)
	if !ok {
		return false
	}
	return !kugouArtistMatchesLocal(artist, local)
}

// kugouArtistMatchesLocal:播放器报的这个署名是不是本地那份记的**某一种写法**。
//
// 比两种:主歌手 singerName 与 musicName 里的全署名。两种都认,是因为没被污染时播放器
// 报哪一种都对 —— 只认一种会把另一种判成歌词。
func kugouArtistMatchesLocal(artist string, local kugouLocalTrack) bool {
	if artist == "" {
		return false
	}
	got := loosenEnrichKey(artist)
	if got == loosenEnrichKey(local.artist) {
		return true
	}
	return local.credit != "" && got == loosenEnrichKey(local.credit)
}
