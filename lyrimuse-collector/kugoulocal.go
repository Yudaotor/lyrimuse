// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 酷狗客户端自己下载在本地的逐字歌词 —— 酷狗源的快速路径。
//
// 酷狗 Mac 客户端播放时会把这首歌的 KRC 逐字歌词落进自己容器的 Caches/kgLyric,
// 文件头就是 `krc1`、跟 lyrics.kugou.com 下载接口 fmt=krc 返回的**同一种加密格式**,
// 所以 decryptKRC 那套算法原样可用,不需要第二个解析器(本机实测 60 个文件 60 个解得开)。
//
// 为什么值得专门走一条:
//   - **零网络**。网络那条是"搜索 → KRC 库查候选 → 下载两次"四次往返,这条是读一个几 KB
//     的本地文件。
//   - **是客户端为用户正在听的那一版音频下的那一份**,不是搜索打分猜出来的最像的那个。
//     这个仓库为"匹配到错版本"付出的一整套代价(候选打分、版本限定词比对、时长吻合度)
//     在这条路径上天然不成立 —— 它就是对的那一份。
//   - 顺带拿到 [al:] 专辑名与 [offset:],以及 [language:] 里的译文 / 罗马音两轨(跟网络
//     那条走同一个 krcLanguageTracks)。
//
// 定位是**快速路径,不是替代**:只覆盖"用酷狗听过、且客户端下过歌词"的那些歌,命中不了
// 照常回落 resolveKugouLyric。
//
// 实测的形态(一份真实缓存的快照,数量会随听歌一直涨 —— 实测酷狗**每播一首就当场落盘**,
// 半小时内新增 27 个文件):目录里约七成是 .krc、其余是 `artistsInfo-` 歌手资料 plist;
// .krc **全部**能用现有算法解开;其中约三分之二带得出 [ar:]+[ti:],**剩下那些两个标签都
// 空的是酷狗 AI 语音识别生成的字幕**(有声书 / 没有官方歌词的曲目,正文首行就写着"本字幕
// 由酷狗AI语音识别技术生成")—— 跳过它们不是遗憾,是**正确的**:那不是这首歌的歌词。
// 带标签的那些去重后大约又少一半:同一首歌客户端会同时写好几份(一份
// `歌手 - 歌名_hash.krc`、一份 `<数字>.krc`),pickKugouLocalEntry 就是为这个存在的。拿到的候选仍然照常进 scoreLyricCandidate 打分,不搞
// "命中即采纳" —— 万一同名歌配错了,打分还有机会把它比下去。
//
// 全程 fail-soft:目录不在 / 读不动 / 格式变了 / 解不开,一律当作没命中。它读的是**另一个
// App 的缓存目录**,那个 App 升级随时可能改路径或换格式,不能让它拖垮歌词主流程。
//
// 读这个目录**不需要**「完全磁盘访问」—— 实测一个拿不到 TCC.db 的进程(即没有 FDA)
// 照样读得到:它不在 TCC 保护的那几个位置里。

// kugouLocalDirOverride 让单测把目录指到临时路径。空 = 用真实路径。
var kugouLocalDirOverride string

// kugouLocalLyricDir 是酷狗客户端的歌词缓存目录。 这是**外部 App** 的路径,不是这个项目
// 自己的数据位置,所以不走 paths.go 那套身份口径。
func kugouLocalLyricDir() string {
	if kugouLocalDirOverride != "" {
		return kugouLocalDirOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.kugou.mac.Music/Data/Library",
		"Application Support/com.kugou.mac.Music/Caches/kgLyric")
}

// kugouLocalMaxFileBytes:单个 KRC 的大小上限。实测本机最大 12KB 量级;设 1MB 是防"目录里
// 混进一个异常大的文件"时白读白解压,不是格式约束。
const kugouLocalMaxFileBytes = 1 << 20

// kugouLocalRescanMin:两次重扫之间的最小间隔。目录 mtime 变了才重扫,这个节流是防
// "酷狗正在连续写缓存"时每首歌都全量重扫一遍。
const kugouLocalRescanMin = 30 * time.Second

type kugouLocalEntry struct {
	path   string
	artist string
	title  string
	album  string
}

var (
	kugouLocalMu      sync.Mutex
	kugouLocalIndex   map[string][]kugouLocalEntry
	kugouLocalDirMod  time.Time
	kugouLocalScanned time.Time
	kugouLocalReady   bool
)

// kugouLocalKey 是索引键 —— 歌手与歌名各自 normLoose(繁简/大小写/标点/变音都折掉),
// 跟这个仓库其它跨源匹配用的是同一把尺子。
func kugouLocalKey(artist, title string) string {
	na, nt := normLoose(artist), normLoose(title)
	if na == "" || nt == "" {
		return ""
	}
	return na + "|" + nt
}

// refreshKugouLocalIndexLocked 在目录 mtime 变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 kugouLocalMu。
func refreshKugouLocalIndexLocked() {
	dir := kugouLocalLyricDir()
	if dir == "" {
		kugouLocalIndex, kugouLocalReady = nil, true
		return
	}
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		// 没装酷狗 / 没开过 / 路径变了 —— 都是正常情况,静默退回网络解析。
		// 被 TCC 拒了**不是**常态,那一种由 noteLocalCacheDenied 记一行,理由见它的头注。
		noteLocalCacheDenied("kugou", dir, err)
		kugouLocalIndex, kugouLocalReady = nil, true
		return
	}
	now := time.Now()
	if kugouLocalReady && st.ModTime().Equal(kugouLocalDirMod) {
		return
	}
	if kugouLocalReady && now.Sub(kugouLocalScanned) < kugouLocalRescanMin {
		return
	}
	kugouLocalDirMod, kugouLocalScanned, kugouLocalReady = st.ModTime(), now, true

	ents, err := os.ReadDir(dir)
	if err != nil {
		// stat 过了不代表这一步也过:TCC 允许 stat 一个目录却拒绝列它的内容。
		noteLocalCacheDenied("kugou", dir, err)
		kugouLocalIndex = nil
		return
	}
	// 读到了就撤掉「被拒」—— 授权之后设置页那个提示要能自己消失。
	noteLocalCacheReadable("kugou")
	idx := map[string][]kugouLocalEntry{}
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".krc") {
			// 同目录下还有 `artistsInfo-…` 那批 plist(歌手资料),不是歌词。
			continue
		}
		path := filepath.Join(dir, e.Name())
		krc := decryptKRCFile(path)
		if krc == "" {
			continue
		}
		_, body := splitKRCLanguageLine(krc)
		artist, title := krcTag(body, "ar"), krcTag(body, "ti")
		key := kugouLocalKey(artist, title)
		if key == "" {
			continue
		}
		idx[key] = append(idx[key], kugouLocalEntry{
			path: path, artist: artist, title: title, album: krcTag(body, "al"),
		})
	}
	kugouLocalIndex = idx
	if len(idx) > 0 {
		log.Printf("kugou local: indexed %d tracks from client cache", len(idx))
	}
}

// kugouLocalLyric 在酷狗客户端的本地缓存里找这首歌。第二个返回值 false = 没命中,
// 调用方照常走网络那条。
func kugouLocalLyric(artist, title, album string) (kugouResult, bool) {
	key := kugouLocalKey(artist, title)
	if key == "" {
		return kugouResult{}, false
	}
	kugouLocalMu.Lock()
	refreshKugouLocalIndexLocked()
	entries := append([]kugouLocalEntry(nil), kugouLocalIndex[key]...)
	if len(entries) == 0 {
		// 精确键对不上就退到宽松匹配 —— 缺了这一步,本地明明有这首歌也命中不了:酷狗
		// 的 [ti:] 常常**带着一长串副标题**(「我知道(电视剧《比赛开始》片尾曲 / LG冰淇淋
		// 手机代言曲)」「大梦(《归兰香故》电视剧主题曲)」),而播放器报的是干净歌名,
		// normLoose 之后两串仍然不相等。实测:干净歌名一首都命中不了,拿 KRC 里那串完整
		// 标题才命中。跟网易云 pick() 那次"打不平手就放弃、漏判候选"是同一个形态。
		entries = looseKugouLocalMatchesLocked(artist, title)
	}
	kugouLocalMu.Unlock()
	if len(entries) == 0 {
		return kugouResult{}, false
	}
	hit := pickKugouLocalEntry(entries, album)
	krc := decryptKRCFile(hit.path)
	if krc == "" {
		// 索引建好之后文件被删了 / 换了内容 —— 当作没命中,网络那条照样能救回来。
		return kugouResult{}, false
	}
	lang, body := splitKRCLanguageLine(krc)
	lrc := krcToLRC(body)
	if lrc == "" {
		return kugouResult{}, false
	}
	tr, roma := krcLanguageTracks(lang, body)
	// 每首歌最多一行:上游 kugouLyric 对同一个 (artist,title,album) 有缓存,不会重复问。
	// 这行是"这份歌词是从客户端缓存来的、没走网络"的唯一凭据 —— 决策面板只记得到源名。
	log.Printf("kugou local: hit %q - %q (album %q)", artist, title, hit.album)
	return kugouResult{
		lrc: lrc, yrc: krcToYRC(body), tr: tr, roma: roma,
		title: hit.title, artist: hit.artist, album: hit.album,
		// 身份来自客户端为这一版录音下的那份 KRC,不经搜索 —— 同源加权的准入条件。
		fromLocalClient: true,
		// durationSecs 留 0:KRC 的 [total:] 实测恒为 0,没有可信时长。打分那边把 0 当
		// "该源没给"处理(见 sourceReportedDurationSecs),不会因此扣分。
	}, true
}

// kugouLocalTitleMatches:宽松标题判据 —— **只认"多出来的是副标题"这一种差异**,不是裸的
// 互相包含。
//
// 用 looseContains 会误配,实测撞上:拿「周深 - 大梦」去查,命中的是缓存里的
// 「大梦归 (《兰香如故》电视剧主题曲)」—— 那是另一首歌,只是名字前两个字一样。判据因此改成
// "长的那个以短的那个开头,**而且紧接着必须是分隔符**":「我知道(电视剧…)」多出来的是
// `(`,是副标题;「大梦归」多出来的是`归`,是另一个词。
//
// 这同时顺手挡住了 Live / Remix 那类:「Song Name Live」多出来的是字母,不算副标题 ——
// 那本来就是另一个录音,不该拿它的歌词顶上。
//
// 这一层的误配比别处更难被下游发现:本地候选的 sourceReportedDurationSecs 是 0
// (KRC 的 [total:] 实测恒为 0),打分里最硬的那个"源报时长对不对得上"信号缺席,所以判据
// 必须在这里就收紧,不能指望打分兜底。
func kugouLocalTitleMatches(cached, want string) bool {
	fold := func(s string) string { return strings.ToLower(toSimplified(strings.TrimSpace(s))) }
	a, b := fold(cached), fold(want)
	if a == "" || b == "" {
		return false
	}
	if normLoose(a) == normLoose(b) {
		return true
	}
	long, short := a, b
	if len(long) < len(short) {
		long, short = short, long
	}
	if !strings.HasPrefix(long, short) {
		return false
	}
	rest := strings.TrimSpace(long[len(short):])
	if rest == "" {
		return true
	}
	return strings.ContainsRune("([{（【《<-–—/|·:：~", []rune(rest)[0])
}

// looseKugouLocalMatchesLocked:精确键落空时的兜底 —— **歌手仍然要精确相等**(normLoose 后),
// 只放宽歌名:两边互相包含就算数(looseContains,跟这个仓库跨源比标题用的是同一把尺子)。
//
// 只放宽歌名、不放宽歌手,是刻意的:歌名带副标题是酷狗的常态,而歌手名放宽会让
// 「周杰伦」匹配到「周杰伦、杨瑞代」这类合唱条目,那是**另一个录音**。
//
// 多个候选时挑 normLoose 长度跟查询最接近的那个 —— 查「我知道」时,「我知道(电视剧…)」
// 比「我知道你很难过」更可能是同一首。挑完照样进 scoreLyricCandidate,不在这里定生死。
//
// 调用方必须持有 kugouLocalMu。
func looseKugouLocalMatchesLocked(artist, title string) []kugouLocalEntry {
	na, nt := normLoose(artist), normLoose(title)
	if na == "" || nt == "" {
		return nil
	}
	best := []kugouLocalEntry(nil)
	bestGap := -1
	for _, entries := range kugouLocalIndex {
		for _, e := range entries {
			if normLoose(e.artist) != na || !kugouLocalTitleMatches(e.title, title) {
				continue
			}
			gap := len(normLoose(e.title)) - len(nt)
			if gap < 0 {
				gap = -gap
			}
			if bestGap < 0 || gap < bestGap {
				best, bestGap = []kugouLocalEntry{e}, gap
			} else if gap == bestGap {
				best = append(best, e)
			}
		}
	}
	return best
}

// pickKugouLocalEntry:同一个 (歌手,歌名) 在缓存里有多份时(同名不同专辑/不同版本),
// 优先挑专辑名也对得上的那一份;都对不上就取第一份 —— 交给下游打分去比,不在这里武断。
func pickKugouLocalEntry(entries []kugouLocalEntry, album string) kugouLocalEntry {
	if album != "" {
		for _, e := range entries {
			if e.album != "" && looseContains(e.album, album) {
				return e
			}
		}
	}
	return entries[0]
}

// decryptKRCFile 读一个本地 .krc 并解密成 KRC 正文。加密方式跟下载接口完全一样,只差
// 外面那层 base64(接口给的是 base64 字符串,本地文件直接就是字节),所以这里复用
// decryptKRCBytes、跟 decryptKRC 共享同一段异或+解压。任何一步失败都返回空串。
func decryptKRCFile(path string) string {
	st, err := os.Stat(path)
	if err != nil || st.Size() > kugouLocalMaxFileBytes {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return decryptKRCBytes(raw)
}

var krcTagRegex = map[string]*regexp.Regexp{}
var krcTagRegexMu sync.Mutex

// krcTag 读 KRC 头部的 `[ar:…]` / `[ti:…]` / `[al:…]` 这类标签。找不到返回空串。
func krcTag(krc, name string) string {
	krcTagRegexMu.Lock()
	re, ok := krcTagRegex[name]
	if !ok {
		re = regexp.MustCompile(`(?m)^\[` + regexp.QuoteMeta(name) + `:(.*?)\]\s*$`)
		krcTagRegex[name] = re
	}
	krcTagRegexMu.Unlock()
	m := re.FindStringSubmatch(krc)
	if m == nil {
		return ""
	}
	return strings.TrimSpace(m[1])
}

// krcLRCKeptTags:转成 LRC 时保留的标准元标签。KRC 头部另外那些(`[id:]` / `[hash:]` /
// `[sign:]` / `[qq:]` / `[total:]`)不是 LRC 的东西,留着只会变成下游眼里的垃圾行。
var krcLRCKeptTags = map[string]bool{"ti": true, "ar": true, "al": true, "by": true, "offset": true}

var krcMetaTagRegex = regexp.MustCompile(`^\[([a-zA-Z]+):(.*)\]$`)

// krcToLRC 把解密后的 KRC 正文压成逐行 LRC —— 丢掉行内的 `<相对ms,时长ms,flag>` 标记、
// 行始时间戳换成 `[mm:ss.xx]`。
//
// 网络那条路的 lrc 是 fmt=lrc 接口单独给的一份;本地只有 KRC 一份,整行歌词就从它压出来。
// 逐字数据仍然由 krcToYRC 单独产出,两者同源,行文字天然一致(网络那条反而要靠 700ms
// 最近邻把两份对起来)。
func krcToLRC(krc string) string {
	if krc == "" {
		return ""
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(krc, "\r\n", "\n"), "\r", "\n")
	var out []string
	timed := 0
	for _, line := range strings.Split(normalized, "\n") {
		if m := krcLineRegex.FindStringSubmatch(line); m != nil {
			start, err := strconv.Atoi(m[2])
			if err != nil {
				continue
			}
			text := strings.TrimSpace(krcWordRegex.ReplaceAllString(m[3], ""))
			out = append(out, lrcTimestamp(start)+text)
			timed++
			continue
		}
		if m := krcMetaTagRegex.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			if krcLRCKeptTags[strings.ToLower(m[1])] {
				out = append(out, strings.TrimSpace(line))
			}
			continue
		}
	}
	// 判据是"有没有计时行",不是"输出非空" —— 一份只剩头部标签、正文全丢了的 KRC
	// 照样能产出几行 `[ti:]`/`[ar:]`,那是一个**看着非空、其实一句歌词都没有**的壳,
	// 会被上游当成拿到候选而不再回落网络。
	if timed == 0 {
		return ""
	}
	return strings.Join(out, "\n")
}

// lrcTimestamp 把毫秒格成 LRC 的 `[mm:ss.xx]`。超过 99 分钟的曲目分钟位自然变三位,
// LRC 解析器都按数字读,不截断。
func lrcTimestamp(ms int) string {
	if ms < 0 {
		ms = 0
	}
	return fmt.Sprintf("[%02d:%02d.%02d]", ms/60000, ms/1000%60, ms%1000/10)
}

// ---- 播放队列:接下来会播的几首(见 upcoming.go)----

// kugouUpcomingOverride 让单测把队列库指到临时路径。空 = 用真实路径。
var kugouUpcomingOverride string

// kugouUpcomingSQL 只取拼 enrich key 用得上的那几个字段。
//
// 在 SQL 里 json_extract 而不是把整份 songInfo 拉回来:那个 BLOB 每行 91 个字段几 KB
// (音质档位、商业化权益、一堆 hash),100 行就是几百 KB,而这里只要 4 个值。
// songInfo 是 BLOB,不 cast 成 text 的话 json_extract 拿不到东西。
const kugouUpcomingSQL = `SELECT songIndex AS i,
  json_extract(cast(songInfo as text),'$.musicName') AS n,
  json_extract(cast(songInfo as text),'$.albumName') AS al,
  json_extract(cast(songInfo as text),'$.musicTime') AS d,
  json_extract(cast(songInfo as text),'$.singerInfo') AS s,
  json_extract(cast(songInfo as text),'$.showName') AS sn
FROM CurrentSongList ORDER BY songIndex LIMIT 2000`

// kugouUpcomingQueryTimeout:单次查询的墙钟上限,防"库被锁住 / 盘卡住"拖住主流程。
const kugouUpcomingQueryTimeout = 4 * time.Second

// kugouUpcomingPath 是另一份播放队列库,在读不到 userCurrentPlayList.plist 的队列
// (kugouQueuePlistPath)时兜底。两种情形会走到这里:
//
//   - 3.3.2 之前的客户端:队列只存在这份库里。
//   - 3.3.2 起播「首页 → 推荐」这类推荐流:plist 被清成 userLastNormalPlayList / userPreNormalPlayList
//     两个空列表,队列改写在这份库里,每换一首重写一次(实测 15 首的推荐队列,mtime 跟着换歌走)。
//
// 播普通歌单时 3.3.2 起**不写**这份库,它停在上一次推荐流 / 升级前的内容上(实测一个 50 首歌单播了
// 一整天,这份库一直是上一个歌单的 100 首)。那时 plist 读得到,走不到这里;万一走到,当前这首也
// 不在库里,反查不到就退回同专辑预取。
//
// 跟 kgLyric 那条快速路径是两份东西:那个是歌词正文缓存,这个是播放队列。
func kugouUpcomingPath() string {
	if kugouUpcomingOverride != "" {
		return kugouUpcomingOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Containers/com.kugou.mac.Music/Data/Library",
		"Preferences/currentPlayList.sqlite")
}

// kugouUpcomingRow 是 kugouUpcomingSQL 查出来的一行。
type kugouUpcomingRow struct {
	Index int64   `json:"i"`
	Name  string  `json:"n"` // "歌手 - 歌名"
	Album string  `json:"al"`
	Dur   float64 `json:"d"` // 秒
	// Singer 是**再一层 JSON 字符串**(不是嵌套对象),要二次解析才拿得到 name。
	Singer string `json:"s"`
	// ShowName 是播放器显示、也是报给系统的那个歌名。多数跟 musicName 后半截一样,带版本说明的歌
	// 只在这里有:实测 15 首的推荐队列里 3 首不同 —— musicName「aespa - UP」、showName「UP (KARINA Solo)」,
	// 播放器报的是后者。拿 musicName 那半截去预解析,真播到时 key 对不上,等于白解析。
	ShowName string `json:"sn"`
}

// kugouUpcomingArtist 从 singerInfo 那串 JSON 里取全部署名。
//
// 拼全部的理由同 sodaUpcomingArtist / qqUpcomingArtist。解不开就返回空串,由调用方
// 退回用 musicName 的前缀那一半。
func kugouUpcomingArtist(raw string) string {
	if raw == "" {
		return ""
	}
	var singers []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(raw), &singers); err != nil {
		return ""
	}
	names := make([]string, 0, len(singers))
	for _, s := range singers {
		if s.Name != "" {
			names = append(names, s.Name)
		}
	}
	return strings.Join(names, "/")
}

// kugouUpcomingSplit 把 "歌手 - 歌名" 拆成两半。
//
// 只切**第一个** " - ":歌名本身可能还带破折号(实测 "冬妍DYan - No photo of you left to
// survey (one day when I was twenty)"),多切一刀就把歌名截断了。没有分隔符时整串当歌名 ——
// 那一行的歌手交给 singerInfo 出。
func kugouUpcomingSplit(musicName string) (artist, title string) {
	if i := strings.Index(musicName, " - "); i >= 0 {
		return musicName[:i], musicName[i+len(" - "):]
	}
	return "", musicName
}

// kugouUpcoming 取酷狗接下来会播的几首。
//
// 先读 userCurrentPlayList.plist(当前队列 + 当前位置,见 kugouUpcomingFromPlist);那份文件
// **读不到队列**(没有这个文件 / plutil 解不开 / 结构不认识 —— 更老的客户端,或者正在播推荐流)
// 才退回 currentPlayList.sqlite(两种情形见 kugouUpcomingPath)。plist 读到了、只是当前这首不在里面时**不**退回 sqlite:plist 是
// 当前队列,它说不在就是不在,拿那份过期库去反查只会预取一批不会播的歌。
func kugouUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	if res, ok, handled := kugouUpcomingFromPlist(artist, title, n); handled {
		return res, ok
	}
	return kugouUpcomingFromSQLite(artist, title, n)
}

// kugouUpcomingFromSQLite 从旧的播放队列库里取接下来会播的几首(兜底,见 kugouUpcoming)。
//
// 这份表**没有"当前播到第几首"的指针**:`currentProgress` 看着像,其实每一行都有值
// (实测 59.7 / 180.6 / 59.6 / 120.7 …),不是当前进度 —— 别拿它定位。所以位置只能靠
// 正在播的那首歌反查 `musicName`,查不到就退回同专辑预取(这份库停在上一个歌单是常态)。
func kugouUpcomingFromSQLite(artist, title string, n int) ([]upcomingTrack, bool) {
	path := kugouUpcomingPath()
	if path == "" {
		return nil, false
	}
	if _, err := os.Stat(path); err != nil {
		// 没装酷狗 / 没播过是常态,静默;被 TCC 拒了不是,那一种要留痕(见 localcachefs.go)。
		noteLocalCacheDenied("kugou", path, err)
		return nil, false
	}
	noteLocalCacheReadable("kugou")
	ctx, cancel := context.WithTimeout(context.Background(), kugouUpcomingQueryTimeout)
	defer cancel()
	// mode=ro + net/url 组 URI 的理由同 queryQQLocalSongs:路径里带空格要转义,
	// 只读快照撞上客户端写锁就直接失败、fail-soft 退回。
	uri := (&neturl.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-json", uri, kugouUpcomingSQL).Output()
	if err != nil {
		return nil, false
	}
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, false // 零行时 sqlite3 -json 输出空串,不是 "[]"
	}
	var rows []kugouUpcomingRow
	if err := json.Unmarshal(trimmed, &rows); err != nil {
		return nil, false
	}
	want := loosenEnrichKey(artist + "|" + title)
	pos := -1
	tracks := make([]upcomingTrack, len(rows))
	for i, r := range rows {
		a, ti := kugouUpcomingSplit(r.Name)
		if s := kugouUpcomingArtist(r.Singer); s != "" {
			a = s
		}
		if pos < 0 && (loosenEnrichKey(a+"|"+ti) == want || r.ShowName != "" && loosenEnrichKey(a+"|"+r.ShowName) == want) {
			pos = i
		}
		if r.ShowName != "" {
			ti = r.ShowName
		}
		if ti == "" {
			continue
		}
		// musicTime 本来就是秒(实测 210),别当毫秒。
		tracks[i] = upcomingTrack{artist: a, title: ti, album: r.Album, duration: r.Dur}
	}
	if pos < 0 {
		return nil, false
	}
	return kugouPickUpcoming("sqlite", tracks, pos, n)
}
