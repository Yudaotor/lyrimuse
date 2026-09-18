// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"log"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// 汽水音乐客户端的播放队列缓存 —— 只贡献一条信号:纯音乐判定的本地兜底。
//
// ⚠️ 这条**和另外四条本地路径不是一个分量**,别照着它们的分量理解它。那四条各自
// 省掉了一整跳网络或一整轮挑选:
//   - 酷狗(kugoulocal.go):歌词正文就在盘上,零网络。
//   - QQ / 网易云(qqlocal.go / neteaselocal.go):拿到客户端记的权威 songmid / songID,
//     省掉搜索那一跳连同它的挑选风险。
//   - Apple Music(applemusiclocal.go):官方 TTML 全文落盘。
//
// 汽水这边三条路全是断的,实测结论按证据列在这里,免得日后有人再挖一遍:
//   - **歌词不落盘**。把 ~/Library/Application Support/SodaMusic 整个目录(排除音频
//     缓存)逐文件扫 LRC 时间戳,零命中;`lyric` 只出现在 asar 代码里。歌词是随
//     track_player 播放接口下发的(渲染层 `lyrics: i.lyric`),只在内存。
//   - **曲目 id 无处可用**。QueueCache 里的 id 是字节自家的,lyrimuse 没有对接汽水
//     歌词源,拿到也没有下一步 —— 这正是它跟 QQ/网易云那两条的根本差别。
//   - **匹配维度零增量**。QueueCache 的 title / artist / album / duration 实测与
//     MediaRemote **逐字节一致**:《Rosy (15 Khalil Live in HK 2011)》两边 duration
//     都是 259947ms,album 都是 "15 Khalil Fong Live in Hong Kong 2011"。也就是说
//     走 media-control 已经拿到了这个文件里的全部匹配维度。
//   - 顺带排掉的:LunaCacheV2 的 .bin 是完整 M4A 容器,但 ilst 里只有 ©too(编码器名)、
//     没有任何曲目标签,音轨还是 CENC 加密(senc/saio/saiz 齐全);ISRC 服务端压根
//     不下发(QueueCache 里 `isrc` 零命中),所以 Spotify 那条 ISRC 线在这里复制不了。
//
// 剩下的唯一增量是 `vocal == 2`。汽水自己的渲染代码里这个字段只有一处判断:
//
//	!lyric.content ? (track.vocal === 2 ? "纯音乐，请欣赏" : "暂无歌词，请欣赏")
//
// 语义跟 enrichEntry.Instrumental 完全对齐 —— 两边都是"歌词为空时,把『纯音乐』跟
// 『没搜到』区分开"。所以它接在那个判定的**最后**,当兜底。
//
// ⚠️ 期望命中率很低,别高估。要用上它得同时满足四条:①正在用汽水播放 ②这首歌在
// feed 队列缓存里 ③它是纯音乐 ④lrclib / 网易云 / QQ / Musixmatch **都没有**给出
// instrumental 信号。第④条尤其苛刻 —— 纯音乐恰恰是 lrclib 标得最全的一类。
// 正因如此它只当兜底:不抢先、不省网络、不影响任何已有判定。
//
// 关于第②条的覆盖面,实测两次(别沿用"只有当前那一批"的直觉):
//   - 20:12 那份 savedAt 里 24 首;03:06 那份 30 首,新增 6 首、**一首都没移除**。
//   - 也就是说 feed 队列是**追加式增长**的,播过的歌会留在缓存里,覆盖面比
//     "当前队列那一批"要好。
//   - 但它**不是每首歌都写**:一次 5 分钟的连续监听(整首歌播完)期间文件 sha 纹丝
//     不动,写入发生在 feed 翻页拉下一批的时候。所以"刚播的这首一定在里面"并不
//     成立,拿不到就是拿不到,照常回落。
//
// ⚠️ **未实测验证**:本机 QueueCache 两次快照(24 首 / 30 首)里 vocal 全是 1,
// **一条 vocal==2 的真实样本都没有**。判定语义是从汽水自己的代码里读出来的
// (权威,且是该字段仅有的用法),但"真纯音乐上确实报 2"这一步没有真实数据撑着。
// 单测用构造数据覆盖。
// 另外别望文生义 `lang_codes`:实测 ['MU'] 那条是《味道（Feat. Zion.T/Crush）》,
// 有人声有歌词,MU 不是 music/纯音乐的意思。
//
// 文件格式(零加密,这点是这次挖掘唯一的长期收获,日后汽水若改版把歌词落盘就用得上):
// LunaStorage 下每个文件都是 4 字节魔数 "LUNA" + **原生 gzip** + 明文 JSON。
// 等价于 `tail -c +5 QueueCache | gunzip`。
//
// ⚠️ 全程 fail-soft:没装汽水 / 文件不在 / 魔数变了 / gzip 解不开 / JSON 结构改了,
// 一律当没命中。它读的是**另一个 App 的缓存**,对方升级随时可能改格式。

// sodaLocalQueueOverride 让单测把队列文件指到临时路径。空 = 用真实路径。
var sodaLocalQueueOverride string

// sodaLocalMagic 是 LunaStorage 文件头的 4 字节魔数,其后紧跟原生 gzip 流。
var sodaLocalMagic = []byte("LUNA")

const (
	// sodaLocalRescanMin 是两次重扫之间的最小间隔。文件很小(实测 22KB)、解压+解析
	// 是毫秒级,所以压得很低 —— 同 applemusiclocal.go 那条的理由:节流设大了会输掉
	// 自己要赢的竞速(客户端刚写完、这边还在节流窗口里,整轮落空)。
	sodaLocalRescanMin = time.Second
	// sodaLocalMaxBytes 是解压后的上限,防着文件异常膨胀把内存吃光(gzip 炸弹或
	// 格式变更)。实测 283KB,留足两个数量级。
	sodaLocalMaxBytes = 32 << 20
	// sodaLocalVocalInstrumental 是 vocal 字段表示"纯音乐"的取值,见头注里汽水
	// 自己那行三元表达式。
	sodaLocalVocalInstrumental = 2
)

// sodaLocalQueuePath 是汽水音乐客户端的播放队列缓存。⚠️ 这是**外部 App** 的路径,
// 不是这个项目自己的数据位置,所以不走 paths.go 那套身份口径。
func sodaLocalQueuePath() string {
	if sodaLocalQueueOverride != "" {
		return sodaLocalQueueOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Application Support/SodaMusic/LunaStorage/QueueCache")
}

// sodaLocalTrack 只摘这条路径用得上的字段。QueueCache 里每首歌还带着几十个字段
// (音质档位、商业化权益、配色、副歌位置、人声起始……),都跟这里无关,不摘。
type sodaLocalTrack struct {
	Name     string `json:"name"`
	Duration int64  `json:"duration"` // 毫秒
	Vocal    int    `json:"vocal"`
	Artists  []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Album struct {
		Name string `json:"name"`
	} `json:"album"`
}

// sodaLocalQueueFile 是整个文件的形状:顶层是「队列 key → 队列」,key 形如
// "u_<用户id>:feed"。实测只有 feed 一个,但按 map 解 —— 换成歌单/搜索结果播放时
// 多半会多出别的 key,按 map 解就不用跟着改。
type sodaLocalQueueFile map[string]struct {
	Playables []struct {
		Track sodaLocalTrack `json:"track"`
	} `json:"playables"`
}

var (
	sodaLocalMu      sync.Mutex
	sodaLocalIndex   map[string][]sodaLocalTrack
	sodaLocalMod     time.Time
	sodaLocalSize    int64
	sodaLocalScanned time.Time
	sodaLocalReady   bool
)

// sodaLocalKey 是索引键 —— 与 kugouLocalKey / qqLocalKey / neteaseLocalKey 同一把
// 尺子(normLoose)。
func sodaLocalKey(artist, title string) string {
	na, nt := normLoose(artist), normLoose(title)
	if na == "" || nt == "" {
		return ""
	}
	return na + "|" + nt
}

// decodeSodaLocalQueue 把 LUNA+gzip 的字节解成曲目表。魔数对不上就直接当不认识 ——
// 不去猜"也许没有魔数、直接是 gzip",格式判断保持严格,宁可不命中。
func decodeSodaLocalQueue(raw []byte) ([]sodaLocalTrack, error) {
	if !bytes.HasPrefix(raw, sodaLocalMagic) {
		return nil, nil
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw[len(sodaLocalMagic):]))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	// LimitReader 多读 1 字节:读满上限说明文件比预期大一个数量级以上,当格式异常放弃,
	// 而不是拿一份被截断的 JSON 去解(截断的 JSON 解不开,但没必要走到那一步)。
	body, err := io.ReadAll(io.LimitReader(zr, sodaLocalMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > sodaLocalMaxBytes {
		return nil, nil
	}
	var f sodaLocalQueueFile
	if err := json.Unmarshal(body, &f); err != nil {
		return nil, err
	}
	var tracks []sodaLocalTrack
	for _, q := range f {
		for _, p := range q.Playables {
			tracks = append(tracks, p.Track)
		}
	}
	return tracks, nil
}

// refreshSodaLocalIndexLocked 在文件变过、且距上次扫描超过节流间隔时重建索引。
// 调用方必须持有 sodaLocalMu。
func refreshSodaLocalIndexLocked() {
	path := sodaLocalQueuePath()
	if path == "" {
		sodaLocalIndex, sodaLocalReady = nil, true
		return
	}
	st, err := os.Stat(path)
	if err != nil || st.IsDir() {
		// 没装汽水 / 没登录过 / 路径变了 —— 正常情况,不记日志。
		sodaLocalIndex, sodaLocalReady = nil, true
		return
	}
	now := time.Now()
	if sodaLocalReady && st.ModTime().Equal(sodaLocalMod) && st.Size() == sodaLocalSize {
		return
	}
	if sodaLocalReady && now.Sub(sodaLocalScanned) < sodaLocalRescanMin {
		return
	}
	sodaLocalMod, sodaLocalSize = st.ModTime(), st.Size()
	sodaLocalScanned, sodaLocalReady = now, true

	raw, err := os.ReadFile(path)
	if err != nil {
		// 保留上一次的索引,理由同 qqlocal.go:重建失败是常态化的偶发(客户端正在写)。
		return
	}
	tracks, err := decodeSodaLocalQueue(raw)
	if err != nil {
		return
	}
	idx := map[string][]sodaLocalTrack{}
	for _, t := range tracks {
		if t.Name == "" || len(t.Artists) == 0 {
			continue
		}
		// 多歌手曲目每个署名各挂一次,同 neteaselocal.go:本地标签常只写其中一位。
		// 实测队列里就有《味道（Feat. Zion.T/Crush）》这种三人合唱。
		for _, a := range t.Artists {
			key := sodaLocalKey(a.Name, t.Name)
			if key == "" {
				continue
			}
			idx[key] = append(idx[key], t)
		}
	}
	sodaLocalIndex = idx
}

// pickSodaLocalEntry 在同名同歌手的多条记录里挑一条。判据与 pickQQLocalEntry /
// pickNeteaseLocalEntry 一致:先过时长闸(sourceDurationFits,12% 口径),全过不了
// 就不命中;再专辑优先、时长差最小。
//
// 时长闸在这条路径上尤其要紧:这里的结论是"这首歌没有歌词",一旦按错了曲目把有词的
// 歌标成纯音乐,用户看到的是空白而不是歌词,比不命中糟得多。
func pickSodaLocalEntry(entries []sodaLocalTrack, album string, durationSecs float64) (sodaLocalTrack, bool) {
	var best sodaLocalTrack
	var bestScore float64
	found := false
	for _, e := range entries {
		if !sourceDurationFits(durationSecs, float64(e.Duration)/1000) {
			continue
		}
		score := 0.0
		if album != "" && e.Album.Name != "" && normLoose(e.Album.Name) == normLoose(album) {
			score += 1000
		}
		if durationSecs > 0 && e.Duration > 0 {
			score -= math.Abs(float64(e.Duration)/1000 - durationSecs)
		}
		if !found || score > bestScore {
			best, bestScore, found = e, score, true
		}
	}
	return best, found
}

// sodaLocalInstrumental 回答"汽水客户端的队列缓存里,这首歌被标成纯音乐了吗"。
// 只在所有联网源都没给出歌词、也没给出 instrumental 信号时才问它 ——
// 见 instrumentalFromScored 的调用处。
func sodaLocalInstrumental(artist, title, album string, durationSecs float64) bool {
	key := sodaLocalKey(artist, title)
	if key == "" {
		// 歌手名(或歌名)缺失时不做"只按另一个字段"的兜底:这条路径的结论是"没有歌词",
		// 不靠猜。
		//
		// ⚠️ 这个早退在**正确性**上是冗余的 —— 建索引那边同样跳过空键,所以空键查
		// 索引本来也查不到(变异测试实测:去掉这个 if,全部用例照样通过,是个等价变异)。
		// 它省的是下面那次加锁 + os.Stat + 可能的整份重建,别因为"测试删了也不红"
		// 就把它当死代码删掉。
		return false
	}
	sodaLocalMu.Lock()
	refreshSodaLocalIndexLocked()
	ents := append([]sodaLocalTrack(nil), sodaLocalIndex[key]...)
	sodaLocalMu.Unlock()
	if len(ents) == 0 {
		return false
	}
	t, ok := pickSodaLocalEntry(ents, album, durationSecs)
	if !ok || t.Vocal != sodaLocalVocalInstrumental {
		return false
	}
	// 命中极少见(见头注那四个叠加条件),每次都记:这行是"这条纯音乐结论来自汽水
	// 客户端的本地队列、不是任何联网源给的"的唯一凭据。
	log.Printf("soda local: %q - %q (album %q) marked instrumental by client queue cache", artist, title, t.Album.Name)
	return true
}
