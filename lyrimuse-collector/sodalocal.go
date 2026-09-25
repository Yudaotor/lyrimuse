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
	"strings"
	"sync"
	"time"
)

// 汽水音乐客户端的播放队列缓存 —— 只贡献一条信号:纯音乐判定的兜底。
//
// 文件格式:4 字节魔数 "LUNA" + 原生 gzip + 明文 JSON,无加密。
//
// 唯一取用的字段是 `vocal`,==2 表示纯音乐。依据是汽水自己的渲染代码里该字段仅有的
// 那处判断 —— `!lyric.content ? (vocal === 2 ? "纯音乐" : "暂无歌词")`,跟
// enrichEntry.Instrumental 是同一个区分。
//
// 这条**比另外四条本地路径薄**。那四条各自省掉一整跳网络或一整轮挑选(酷狗歌词正文
// 在盘上、QQ/网易云拿权威 songmid/songID、Apple Music 官方 TTML 全文);这条出两样东西:
// 纯音乐标记,以及 soda 歌词源唯一的身份入口 —— 曲目 id(见 sodaLocalTrackID)。
// 那个 id 经 notePlayingSodaTrackID 落进 playbackTrackIDs,soda 源据此直取歌词,
// 跟 amll 按 Apple/Spotify ID 直取是同一条路子。
//
// 关于汽水这几条路的结论,记在这里免得日后重挖:
//   - 歌词随播放接口下发,QueueCache 里没有;但客户端的音频缓存库 `LunaCacheV2/entries.db`
//     每条记录的 mediaDetail.lyrics.content 带着逐字正文(格式同 soda.go 头注),只覆盖缓存过的歌,
//     目前没有读。取词走 web 端的 SEO 接口(`seo_track`,无签名无 Cookie),按 track id 取全文,
//     见 soda.go。那份缓存库现在只用来看预载了哪几首(sodapreload.go)。
//   - 曲名/歌手/专辑/时长与 MediaRemote 逐字节一致(含毫秒),零增量。
//   - 服务端不下发 ISRC;缓存的音频是 CENC 加密的 M4A,ilst 只有 ©too。
//
// 全程 fail-soft:没装汽水 / 文件不在 / 魔数变了 / gzip 解不开 / JSON 结构改了,
// 一律当没命中。读的是另一个 App 的缓存,对方升级随时可能改格式。

// sodaLocalQueueOverride 让单测把队列文件指到临时路径。空 = 用真实路径。
var sodaLocalQueueOverride string

// sodaLocalMagic 是 LunaStorage 文件头的 4 字节魔数,其后紧跟原生 gzip 流。
var sodaLocalMagic = []byte("LUNA")

const (
	// sodaLocalRescanMin 压得很低的理由同 applemusiclocal.go:节流设大了会输掉自己
	// 要赢的竞速(客户端刚写完、这边还在节流窗口里,整轮落空)。解析是毫秒级。
	sodaLocalRescanMin = time.Second
	// sodaLocalMaxBytes 防着文件异常膨胀把内存吃光(gzip 炸弹或格式变更)。
	sodaLocalMaxBytes = 32 << 20
	// sodaLocalVocalInstrumental 是 vocal 表示"纯音乐"的取值,见头注。
	sodaLocalVocalInstrumental = 2
)

// sodaLocalQueuePath 是汽水音乐客户端的播放队列缓存。 这是**外部 App** 的路径,
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

// sodaLocalTrack 只摘这条路径用得上的字段。每首歌还带着几十个别的(音质档位、商业化
// 权益、配色、副歌位置……),都不相干。
type sodaLocalTrack struct {
	// ID 是汽水自己的曲目 id(JSON 里是字符串,不是数字)。soda 歌词源按它直取,见 soda.go。
	ID       string `json:"id"`
	Name     string `json:"name"`
	Duration int64  `json:"duration"` // 毫秒
	Vocal    int    `json:"vocal"`
	Artists  []struct {
		Name string `json:"name"`
	} `json:"artists"`
	Album struct {
		ID   string `json:"id"` // 同专辑兜底按它取汽水的专辑曲目表,见 sodaalbum.go
		Name string `json:"name"`
	} `json:"album"`
	// FirstVocal 是人声起始位置(毫秒),这里只用来给纯音乐结论做交叉校验,不取它的值
	// 本身。指针类型是必需的:要区分"字段缺失"(纯音乐的形状)和"存在但 start==0"
	// (有人声、位置未知)。
	FirstVocal *struct {
		Start int64 `json:"start"`
	} `json:"first_vocal"`
	// Preview 是非会员试听段(毫秒):从整首的第 Start 毫秒起、长 Duration 毫秒。见 sodapreview.go。
	Preview *struct {
		Start    int64 `json:"start"`
		Duration int64 `json:"duration"`
	} `json:"preview"`
}

// sodaLocalContradictsInstrumental 判断一条 vocal==2 的记录是否与别的字段自相矛盾。
// 矛盾就不认这条纯音乐结论 —— 取向是**宁可漏判不可误判**:误判(有词的被标成纯音乐)
// 让用户看到空白,比漏判(退回「无歌词」显示)糟得多。
//
// 判据只有"有明确的人声起始位置"一条。缺字段不算矛盾(纯音乐本就没有),start==0 也
// 不算(那是"位置未知"),只有 start > 0 才是跟"没有人声"直接互斥的断言。
//
// 刻意**不**把 lang_codes 纳入判据:它的缺失虽然也跟 vocal==2 对齐,但语种本来就可能
// 因为未标注/未识别而缺失,拿它否决会平白制造漏判;first_vocal 是位置断言,不一样。
func sodaLocalContradictsInstrumental(t sodaLocalTrack) bool {
	return t.FirstVocal != nil && t.FirstVocal.Start > 0
}

// sodaLocalQueueFile 的顶层是「队列 key 到 队列」。 **不止一个 key**:推荐流是
// "u_<uid>:feed",而每个「听歌模式」各有自己的 key(如
// "u_<uid>:feedMode:feedMode_scene_mode_focus"),互不覆盖、一起留在文件里。
// 所以按 map 遍历全部,别认死 "feed" 那一个。
type sodaLocalQueueFile map[string]sodaLocalQueue

// sodaLocalQueue 是文件里的一条队列。
//
// Playables 的**顺序就是播放顺序**,解析和传递的每一步都别打乱它 ——「接下来会播哪几首」
// 全靠这个顺序,而纯音乐判定那条路把所有队列压平成一张表、顺序无所谓,两者对这份数据的
// 要求不一样。
type sodaLocalQueue struct {
	// LastPlayedKey 指向 Playables 里最后播过的那一条(取值与 playable 的 key 相同),
	// 也就是这条队列的当前位置。空 = 这条队列还没播过。
	LastPlayedKey string `json:"lastPlayedKey"`
	// SavedAt 是这条队列最后一次落盘的毫秒时间戳。文件里同时存着好几条队列(推荐流 +
	// 每个听歌模式各一条),它是判断"哪条最近活跃"的唯一线索。
	SavedAt   int64 `json:"savedAt"`
	Playables []struct {
		// Key 形如 "track-<id>",与 LastPlayedKey 同一套取值。 别改成拿 Track.ID 自己拼:
		// 那是在假设一个由对方决定的格式,而这里本来就有现成的字段可比。
		Key   string         `json:"key"`
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

// decodeSodaLocalQueueFile 把 LUNA+gzip 的字节解成文件里的全部队列。魔数对不上就当不认识 ——
// 不去猜"也许没有魔数、直接是 gzip",格式判断保持严格,宁可不命中。
func decodeSodaLocalQueueFile(raw []byte) (sodaLocalQueueFile, error) {
	if !bytes.HasPrefix(raw, sodaLocalMagic) {
		return nil, nil
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw[len(sodaLocalMagic):]))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	// 多读 1 字节是为了能判出"超限"本身,而不是拿一份被截断的 JSON 去解。
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
	return f, nil
}

// decodeSodaLocalQueue 把文件里的全部队列压平成一张曲目表 —— 纯音乐判定只需要"这首歌在不在
// 汽水的缓存里、它的 vocal 是多少",不关心它属于哪条队列、排在第几。要顺序和位置的走
// decodeSodaLocalQueueFile。
func decodeSodaLocalQueue(raw []byte) ([]sodaLocalTrack, error) {
	f, err := decodeSodaLocalQueueFile(raw)
	if err != nil || f == nil {
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
		// 没装汽水 / 没登录过 / 路径变了 —— 正常情况,静默退回网络解析。
		// 被 TCC 拒了**不是**常态,那一种由 noteLocalCacheDenied 记一行,理由见它的头注。
		noteLocalCacheDenied("soda", path, err)
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
		// 但 stat 过了不代表这一步也过,被拒那一种要留痕。
		noteLocalCacheDenied("soda", path, err)
		return
	}
	// 读到了就撤掉「被拒」—— 授权之后设置页那个提示要能自己消失。
	noteLocalCacheReadable("soda")
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
// 时长闸在这条路径上尤其要紧:结论是"这首歌没有歌词",按错曲目的代价是用户看到空白。
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
// sodaLocalTrackID 查「正在播的这首歌」在汽水那边的曲目 id。查不到给空串,调用方据此
// 跳过 soda 源 —— 没装汽水 / 没用汽水放过这首,本来就不该有它的候选。
//
// 身份判据完全复用纯音乐那条路的 sodaLocalKey + pickSodaLocalEntry:同一份索引、同一套
// 专辑与时长挑选,不另立一套(两条路要是挑中不同的条目,就会出现"纯音乐标记来自 A、
// 歌词来自 B"的错配)。
func sodaLocalTrackID(artist, title, album string, durationSecs float64) string {
	key := sodaLocalKey(artist, title)
	if key == "" {
		return ""
	}
	sodaLocalMu.Lock()
	refreshSodaLocalIndexLocked()
	ents := append([]sodaLocalTrack(nil), sodaLocalIndex[key]...)
	sodaLocalMu.Unlock()
	if len(ents) == 0 {
		return ""
	}
	t, ok := pickSodaLocalEntry(ents, album, durationSecs)
	if !ok {
		return ""
	}
	return strings.TrimSpace(t.ID)
}

func sodaLocalInstrumental(artist, title, album string, durationSecs float64) bool {
	key := sodaLocalKey(artist, title)
	if key == "" {
		// 歌手名(或歌名)缺失时不做"只按另一个字段"的兜底:结论是"没有歌词",不靠猜。
		// 正确性上是冗余的(建索引那边同样跳过空键),留着是为了省下面那次加锁 +
		// os.Stat + 可能的整份重建。
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
	if sodaLocalContradictsInstrumental(t) {
		// 客户端数据自相矛盾(或字段语义变了)值得知道,所以不像上面那几条静默返回。
		log.Printf("soda local: %q - %q says vocal==2 but carries a first_vocal start of %dms; not trusting the instrumental verdict",
			artist, title, t.FirstVocal.Start)
		return false
	}
	// 命中少见,每次都记:这是"纯音乐结论来自客户端缓存、不是任何联网源给的"的唯一凭据。
	log.Printf("soda local: %q - %q (album %q) marked instrumental by client queue cache", artist, title, t.Album.Name)
	return true
}

// ---- 播放队列:接下来会播的几首(见 upcoming.go)----

// sodaUpcomingArtist 把一条曲目的全部署名拼成一串。
//
// 必须拼**全部**,不能只取主歌手:这个串会进 enrichKey,而真播到那首歌时用的是
// MediaRemote 报的完整串。少了后面几位,loosenEnrichKey 折平分隔符之后仍然是两个不同的
// 键(`a` vs `a&b`),预取好的条目命中不了,整轮白做。分隔符挑哪个不要紧 —— 那一层由
// isArtistCreditSep 统一折平。
//
// (注意跟 refreshSodaLocalIndexLocked 里"每个署名各挂一次"的区别:那是**查找**方向,
// 本地标签常只写其中一位;这里是**写入**方向,要跟播放器的完整串对得上。)
func sodaUpcomingArtist(t sodaLocalTrack) string {
	names := make([]string, 0, len(t.Artists))
	for _, a := range t.Artists {
		if a.Name != "" {
			names = append(names, a.Name)
		}
	}
	return strings.Join(names, "/")
}

// sodaUpcoming 从汽水的队列缓存里取接下来会播的几首。
//
// 认哪一条队列靠「它的 lastPlayedKey 指的正是此刻在播的这首」,而不是「savedAt 最大的那条」——
// 文件里同时存着推荐流和每个听歌模式各一条,切换模式时另一条的 savedAt 完全可能更新。
// 对不上就返回 ok=false 让调用方退回同专辑预取:队列文件停在上一次播放是常态,不是异常。
//
// 汽水这条是**推荐流**:queue 里 hasMore 恒为 true、后续曲目是播到附近才续拉的,
// 所以 lastPlayedKey 常常已经很靠后(实测 46/50、7/12),取不满 n 首是正常的,有几首算几首。
func sodaUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	path := sodaLocalQueuePath()
	if path == "" {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		noteLocalCacheDenied("soda", path, err)
		return nil, false
	}
	noteLocalCacheReadable("soda")
	f, err := decodeSodaLocalQueueFile(raw)
	if err != nil || len(f) == 0 {
		return nil, false
	}
	want := loosenEnrichKey(artist + "|" + title)
	if want == "|" {
		return nil, false
	}
	for _, q := range f {
		if q.LastPlayedKey == "" {
			continue
		}
		pos := -1
		for i, p := range q.Playables {
			if p.Key == q.LastPlayedKey {
				pos = i
				break
			}
		}
		if pos < 0 {
			continue // 指针指向一条已经不在队列里的曲目(队列被换过),这条不算数
		}
		cur := q.Playables[pos].Track
		if loosenEnrichKey(sodaUpcomingArtist(cur)+"|"+cur.Name) != want {
			continue // 这条队列停在别的歌上,不是用户此刻在听的那条
		}
		out := make([]upcomingTrack, 0, n)
		for i := pos + 1; i < len(q.Playables) && len(out) < n; i++ {
			t := q.Playables[i].Track
			if t.Name == "" {
				continue
			}
			out = append(out, upcomingTrack{
				artist: sodaUpcomingArtist(t),
				title:  t.Name,
				album:  t.Album.Name,
				// 队列里的 duration 是毫秒,upcomingTrack 要秒。
				duration: float64(t.Duration) / 1000,
			})
		}
		return out, len(out) > 0
	}
	return nil, false
}
