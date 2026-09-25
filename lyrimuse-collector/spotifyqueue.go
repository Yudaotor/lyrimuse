package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"log"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Spotify 的「接下来会播的几首」——全部取自本机,不联网、不要登录。
//
// ## 两份文件
//
// 都在 PersistentCache/Users/<账号>-user/ 下(不是上一层 Users/ 那个目录——决策 66 当时只看了那一个,
// 所以得出了"Spotify 本地没有队列"的结论):
//
//  1. context_player_state_restore —— Spotify 用来「重启后恢复播放」的状态,换歌时重写(实测比 collector
//     的换歌日志还早一两秒)。格式是「13 位毫秒时间戳 + '#' + protobuf」,里面有当前上下文(专辑 / 歌单 /
//     已点赞的歌曲)的**完整曲目表**(实测 561 首一页放全)和当前这首。曲目表里每首只有 uid 和 16 字节 gid,
//     没有名字。
//  2. primary.ldb(LevelDB)—— 客户端的元数据缓存。`!xmeta#cache#<类型>#<曲目 uri>#` 这组 key 下面按类型
//     存着 Spotify 自己的元数据 protobuf:IdentityTrait(歌名 / 专辑 / 歌手)、spotify.metadata.Track
//     (带时长)。实测本机 15207 首,缓存里最大的 12 个歌单每首都有 —— 客户端自己要放那首歌,就得先有它的
//     元数据。按歌生成的电台(spotify:station:track:…)里接下来那几首常常只有 Track、没有 IdentityTrait
//     (实测后面 12 首里 11 首如此),而 Track 里本来就有歌名(2)、专辑{2=名}(3)、歌手{2=名}(4,可重复):
//     IdentityTrait 缺了就从它取。拿本机 enrich 缓存里带 spotify_track_id 的 368 条对过,专辑 368 条全对,
//     两份都在的 238 条里 235 条三样逐字相同(余下是大小写 / 异体字 / 单曲与合辑的专辑名,宽松比对折得平)。
//
// 这两份都是**没有公开 schema 的内部格式**:字段一律按「长得像什么」定位(uid 是十六进制串、gid 是
// 16 字节、元数据按 type_url 认),不按固定路径;任何一步认不出来就放弃,调用方退回同专辑那一层。
//
// ## 写进 enrich key 的三样必须跟播放器真报的一致
//
// 用本机 enrich 缓存里带 spotify_track_id 的条目跟这份元数据逐条对过(只取歌名也对得上的 188 条):
//   - **署名只取第一位**:多歌手的 24 首,Spotify 报给系统的全是第一位(「Taylor Swift」,不是
//     「Taylor Swift, Lana Del Rey」)。拼全部反而对不上 —— 跟 QQ / 网易云那几家相反,别照抄。
//   - 专辑名 183/188 逐字一致,余下是大小写 / 繁简(Twins vs TWINS、未来 vs 未來),宽松比对折得平。
//   - 时长在 Track 的第 7 个字段,是 **sint32 zigzag** 编码(实测原值 512248 = 256124 毫秒 × 2)。
//
// ## 随机播放
//
// 开着随机时上下文曲目表还是**原始顺序**(实测最近播的 10 首在表里的位置是 219、112、355、184……),
// 打乱后的顺序另存在 ContextNode 状态里的一张**只含 uid 的列表**:同样 561 项、每项 {1: 0, 2: uid},
// 最近播的 10 首在这张表里的位置恰好是 0、1、2……9。所以按 Spotify 自己的 AppleScript `shuffling`
// 判断:关着按上下文曲目表往后数,开着按这张打乱表往后数、再用 uid 换回曲目。开着却找不到打乱表(或它
// 不含当前这首)就放弃,退回同专辑那一层 —— 不拿原始顺序去冒充。
//
// ## 播放队列(「加入播放队列」)
//
// 手动加进队列的歌插在上下文前面先放,放完再回到上下文接着往下。状态文件里是 PlayQueueNode:一个带
// `"queue"` 字符串字段的消息,下面每项 {2: uid, 3: gid, 4: 元数据},uid 是 `q0`、`q1` 这种(不是上下文
// 那种十六进制串),正在放的那首也还留在里面。正在放队列里的歌时,「当前这首」的 uid 也是 `q0`,在上下文
// 里定位不到 —— 上下文接着从哪放,看播放历史里最近一首属于这个上下文的歌(实测插队前停在打乱表第 10 位,
// ContextNode 里记的下一个位置正是 11)。所以接下来 = 队列里排在当前这首后面的 + 上下文里那首之后的。

// spotifyStateMaxBytes:状态文件的读入上限。实测 561 首的歌单约 70KB。
const spotifyStateMaxBytes = 16 << 20

// spotifyMetaCacheCap 防无界增长。元数据按曲目 id 缓存(一首歌的名字不会变)。
const spotifyMetaCacheCap = 4096

// spotifyShuffling 问 Spotify 此刻开没开随机。单测替换它,不去真跑 osascript。
var spotifyShuffling = func() (on, ok bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e",
		`if application "Spotify" is running then tell application "Spotify" to return shuffling`).Output()
	if err != nil {
		return false, false
	}
	switch strings.TrimSpace(string(out)) {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

// spotifyShuffleMemory:问不到随机状态(换歌那一拍 osascript 偶尔 2 秒内回不来)时,最近一次问到的结果
// 在多久之内还能用。随机开关很少切换,沿用它比整轮退回同专辑预取好;太久没问到就不猜。
const spotifyShuffleMemory = 30 * time.Minute

// spotifyShuffleRetryDelay:一次都没问到过随机状态时,第一次问不到之后隔多久再问。
const spotifyShuffleRetryDelay = time.Second

var (
	spotifyShuffleMu   sync.Mutex
	spotifyLastShuffle struct {
		on bool
		at time.Time
	}
)

// spotifyShufflingRemembered 先问 Spotify;问不到就用 spotifyShuffleMemory 之内最近一次的答案。一次都没问到过
// (collector 刚启动)时隔 spotifyShuffleRetryDelay 再问一次 —— 超时多半是换歌那一拍 Spotify 正忙,过一秒就好。
func spotifyShufflingRemembered(now time.Time) (on, ok bool) {
	on, ok = spotifyShuffling()
	if !ok {
		spotifyShuffleMu.Lock()
		never := spotifyLastShuffle.at.IsZero()
		spotifyShuffleMu.Unlock()
		if never {
			spotifySleep(spotifyShuffleRetryDelay)
			on, ok = spotifyShuffling()
		}
	}
	spotifyShuffleMu.Lock()
	defer spotifyShuffleMu.Unlock()
	if ok {
		spotifyLastShuffle.on, spotifyLastShuffle.at = on, now
		return on, true
	}
	if !spotifyLastShuffle.at.IsZero() && now.Sub(spotifyLastShuffle.at) <= spotifyShuffleMemory {
		log.Printf("spotify upcoming: could not ask Spotify whether shuffle is on, using the answer from %s ago (shuffle=%v)",
			now.Sub(spotifyLastShuffle.at).Round(time.Second), spotifyLastShuffle.on)
		return spotifyLastShuffle.on, true
	}
	return false, false
}

// spotifyTrackMeta 是一首歌写进 enrich key 要用的那几样。
type spotifyTrackMeta struct {
	artist, title, album string
	seconds              float64
}

var (
	spotifyMetaMu    sync.Mutex
	spotifyMetaCache = map[string]spotifyTrackMeta{}
)

// spotifyStateRetryDelays:状态文件还停在上一首时,隔多久再读一次。
//
// 换歌那一拍 collector 和 Spotify 谁先谁后不固定:实测一次是状态文件比换歌日志早 1.8 秒写好,另一次两者
// 落在同一秒、collector 读到的还是上一首(一条广告),核对不上就整轮放弃了。这条路本来就跑在后台 goroutine
// 里(prefetchUpcoming),等几秒不耽误任何东西。单测把它换成零等待。
var spotifyStateRetryDelays = []time.Duration{time.Second, time.Second, 2 * time.Second}

// spotifySleep 是重试之间的等待。单测替换它 —— 在「等待」那一刻把新状态写进文件,不跟真实时钟抢时序。
var spotifySleep = time.Sleep

// spotifyUpcoming 取 Spotify 接下来会播的几首。
func spotifyUpcoming(artist, title string, n int) ([]upcomingTrack, bool) {
	userDir := spotifyActiveUserDir()
	if userDir == "" {
		return nil, false
	}
	shuffled, ok := spotifyShufflingRemembered(time.Now())
	if !ok {
		log.Printf("spotify upcoming: could not ask Spotify whether shuffle is on, falling back to album prefetch")
		return nil, false // 问不到随机状态:拿不准该按哪个顺序数,不猜
	}
	var upcoming []string
	for attempt := 0; ; attempt++ {
		next, current, ok := spotifyReadCurrentState(userDir, artist, title, shuffled)
		if !ok {
			return nil, false // 文件读不到 / 格式不认识 / 随机时没有打乱表:等也没用(原因由 spotifyReadCurrentState 记)
		}
		if current {
			upcoming = next
			break
		}
		if attempt >= len(spotifyStateRetryDelays) {
			log.Printf("spotify upcoming: state file still on another track after %d retries, falling back to album prefetch", attempt)
			return nil, false
		}
		spotifySleep(spotifyStateRetryDelays[attempt])
	}

	ids := upcoming
	if len(ids) > n {
		ids = ids[:n]
	}
	if len(ids) == 0 {
		return nil, false
	}
	metas := spotifyResolveMeta(userDir, ids)
	res := make([]upcomingTrack, 0, len(ids))
	for _, id := range ids {
		m, ok := metas[id]
		if !ok || m.title == "" {
			continue // 本地没有这首的元数据:不拿空名字去猜
		}
		res = append(res, upcomingTrack{artist: m.artist, title: m.title, album: m.album, duration: m.seconds})
	}
	if len(res) == 0 {
		log.Printf("spotify upcoming: none of the next %d tracks has local metadata, falling back to album prefetch", len(ids))
	}
	return res, len(res) > 0
}

// spotifyReadCurrentState 读一次状态文件,返回**实际播放顺序**(随机时是打乱后的顺序)、当前这首在里面的
// 位置,以及「它是不是此刻在播的这首」。ok=false 表示文件本身读不到或认不出来、或随机时没有可用的打乱表
// (这几种情况重试都没有意义)。ok=false 的每一种都记一行原因:这几条路原来是静默的,Spotify 换了 uid 格式时
// 日志里只剩一行同专辑预取,看不出预解析为什么没起。
//
// 核对优先比换曲时 AppleScript 记下的曲目 id(录音级身份,最硬);没有这个提示时退回比名字。
func spotifyReadCurrentState(userDir, artist, title string, shuffled bool) (upcoming []string, current, ok bool) {
	raw, err := ldbReadFile(filepath.Join(userDir, "context_player_state_restore"))
	if err == nil && len(raw) > spotifyStateMaxBytes {
		err = errors.New("larger than the read limit")
	}
	if err != nil {
		log.Printf("spotify upcoming: cannot read the state file (%v), falling back to album prefetch", err)
		return nil, false, false
	}
	st, err := spotifyParseState(raw)
	if err != nil {
		log.Printf("spotify upcoming: state file not recognized (%v), falling back to album prefetch", err)
		return nil, false, false
	}
	seq := st.tracks
	if shuffled {
		if seq = spotifyApplyShuffle(st.tracks, st.shuffle); seq == nil {
			log.Printf("spotify upcoming: shuffle is on but the state file has no usable shuffle order (context %d tracks), falling back to album prefetch", len(st.tracks))
			return nil, false, false
		}
	}
	var (
		curID     string
		ctxPos    = -1
		queueRest = st.queue
	)
	if spotifyIsQueueUID(st.cur.uid) {
		// 正在放队列里的歌:队列里排在它后面的先放,上下文从插队前最后一首之后接着放。
		curID = st.cur.id
		if qi := spotifyIndexUID(st.queue, st.cur.uid); qi >= 0 {
			queueRest = st.queue[qi+1:]
		}
		ctxPos = spotifyIndexUID(seq, st.lastCtxUID) // 找不到就只剩队列那几首
	} else {
		if ctxPos = spotifyLocateCurrent(seq, st.cur); ctxPos < 0 {
			log.Printf("spotify upcoming: current track not in the play order (shuffle=%v), falling back to album prefetch", shuffled)
			return nil, false, false
		}
		curID = seq[ctxPos].id
	}
	for _, t := range queueRest {
		if t.id != "" {
			upcoming = append(upcoming, t.id)
		}
	}
	if ctxPos >= 0 {
		for _, t := range seq[ctxPos+1:] {
			if t.id != "" {
				upcoming = append(upcoming, t.id)
			}
		}
	}
	if hint := spotifyTrackIDHintFor(artist, title); hint != "" {
		return upcoming, hint == curID, true
	}
	m, found := spotifyResolveMeta(userDir, []string{curID})[curID]
	return upcoming, found && loosenEnrichKey(m.artist+"|"+m.title) == loosenEnrichKey(firstCreditArtist(artist)+"|"+title), true
}

// spotifyIsContextUID:上下文里的曲目 uid,三种长度都要认,少认一种,那类上下文里当前这首、曲目表、打乱表
// 就全部认不出来(状态文件整份作废,只能退回同专辑预取):
//   - 歌单 / 专辑 / 单曲上下文:20 位十六进制;
//   - 电台(自动续播进入的 spotify:station:…):16 位;
//   - 按一首歌生成的电台(歌单放完自动接的 spotify:station:track:…):22 位,是 11 个可见字符的十六进制
//     (实测 `5078566d566a46577a586f` = "PxVmVjFWzXo",一整个 100 首的电台全是这种)。
func spotifyIsContextUID(s string) bool {
	return (len(s) == 16 || len(s) == 20 || len(s) == 22) && isHexString(s)
}

// spotifyIsQueueUID:播放队列里的曲目 uid 是 `q0`、`q1` 这种,跟上下文那种十六进制串不同。
func spotifyIsQueueUID(uid string) bool {
	if len(uid) < 2 || uid[0] != 'q' {
		return false
	}
	for _, c := range uid[1:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func spotifyIndexUID(tracks []spotifyCtxTrack, uid string) int {
	if uid == "" {
		return -1
	}
	for i, t := range tracks {
		if t.uid == uid {
			return i
		}
	}
	return -1
}

// firstCreditArtist 取合唱串的第一位 —— Spotify 自己就只报第一位,名字兜底比对时两边口径要一致。
func firstCreditArtist(s string) string {
	for i, r := range s {
		if isArtistCreditSep(r) {
			return strings.TrimSpace(s[:i])
		}
	}
	return s
}

// spotifyTrackIDHintFor 取换曲那一拍记下的 Spotify 曲目 id(见 spotifytrack.go)。
//
// 提示表按 enrichKey(artist, title, album) 存,这里拿不到 album,所以按前两段匹配 —— 同一首歌换曲那几秒
// 里提示表只会有它自己这一条。
func spotifyTrackIDHintFor(artist, title string) string {
	prefix := enrichKey(artist, title, "") // 专辑段为空,正好是「artist|title|」这个前缀
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for k, id := range spotifyTrackIDHints {
		if strings.HasPrefix(k, prefix) {
			return id
		}
	}
	return ""
}

// spotifyActiveUserDir 选状态文件最新的那个账号目录(多账号登录过就有多个)。
func spotifyActiveUserDir() string {
	root := spotifyISRCUsersDir()
	if root == "" {
		return ""
	}
	ents, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	best, bestMod := "", time.Time{}
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(root, e.Name())
		st, err := os.Stat(filepath.Join(dir, "context_player_state_restore"))
		if err == nil && st.ModTime().After(bestMod) {
			best, bestMod = dir, st.ModTime()
		}
	}
	return best
}

// ---- 状态文件 ----

// spotifyCtxTrack 是上下文曲目表里的一项。
type spotifyCtxTrack struct {
	uid, id string
}

// spotifyCurrent 是状态文件里「正在播的这首」。
type spotifyCurrent struct {
	uid, id string
}

// spotifyParseState 从状态文件里取出上下文曲目表(按顺序,分页拼起来)和当前这首。
//
// 定位全靠形状:
//   - **曲目项**:一个消息里 2 号字段是上下文 uid(spotifyIsContextUID)、3 号字段是 16 字节 gid(或 1 号字段直接是
//     spotify:track: uri)。
//   - **曲目表**:同一个消息里、同一个字段号下**至少两个**曲目项。播放历史里每条也挂着一首,但是外面每条
//     都包了一层(带时间戳),一个外层只有一首 —— 这条规则把历史排除在外。分页是同一个父消息下的几个
//     曲目表,按出现顺序拼起来。
//   - **当前这首**:1 号字段是 uid、2 号字段是 spotify:track: uri 的消息(跟曲目项的字段排法不同),取
//     第一个出现的。
//   - **打乱表**(见文件头注「随机播放」):同一个消息里、同一个字段号下至少两个**只有 uid**(2 号字段,
//     没有 gid)的项。取 uid 全部落在上下文里、又含当前这首的那一张;不止一张就取最长的。
func spotifyParseState(raw []byte) (spotifyState, error) {
	var st spotifyState
	hash := bytes.IndexByte(raw, '#')
	if hash <= 0 || hash > 20 {
		return st, errors.New("spotify state: no timestamp prefix")
	}
	for _, c := range raw[:hash] {
		if c < '0' || c > '9' {
			return st, errors.New("spotify state: bad timestamp prefix")
		}
	}
	root, err := pbParse(raw[hash+1:])
	if err != nil {
		return st, err
	}
	type histEntry struct {
		ts  uint64
		uid string
	}
	var (
		groups   [][]spotifyCtxTrack // 每个父消息一组(分页拼好)
		uidLists [][]string
		history  []histEntry
		queueSet bool
	)
	var walk func(fields []pbField, depth int)
	walk = func(fields []pbField, depth int) {
		if depth > 16 {
			return
		}
		if st.cur.id == "" {
			if c, ok := spotifyAsCurrent(fields); ok {
				st.cur = c
			}
		}
		if !queueSet {
			if q, ok := spotifyAsQueue(fields); ok {
				st.queue, queueSet = q, true
			}
		}
		if ts, uid, ok := spotifyAsHistoryEntry(fields); ok {
			history = append(history, histEntry{ts, uid})
		}
		var group []spotifyCtxTrack
		for _, f := range fields {
			if f.wire != 2 {
				continue
			}
			sub, err := pbParse(f.b)
			if err != nil {
				continue
			}
			if tracks := spotifyAsTrackList(sub); len(tracks) >= 2 {
				group = append(group, tracks...)
				continue
			}
			if uids := spotifyAsUIDList(sub); len(uids) >= 2 {
				uidLists = append(uidLists, uids)
				continue
			}
			walk(sub, depth+1)
		}
		if len(group) > 0 {
			groups = append(groups, group)
		}
	}
	walk(root, 0)
	if st.cur.id == "" && st.cur.uid == "" {
		return st, errors.New("spotify state: no current track")
	}
	queued := spotifyIsQueueUID(st.cur.uid)
	// 选上下文:含当前这首的那一组,几组都含就取最长的(上下文本身比任何别的列表都长)。正在放队列里的歌时
	// 当前这首不在任何一组里,取最长的那组。
	for _, g := range groups {
		if (queued || spotifyLocateCurrent(g, st.cur) >= 0) && len(g) > len(st.tracks) {
			st.tracks = g
		}
	}
	if st.tracks == nil {
		return st, errors.New("spotify state: current track not in any list")
	}
	inCtx := make(map[string]bool, len(st.tracks))
	for _, t := range st.tracks {
		inCtx[t.uid] = true
	}
	var lastTS uint64
	for _, h := range history {
		if inCtx[h.uid] && h.ts >= lastTS {
			st.lastCtxUID, lastTS = h.uid, h.ts
		}
	}
	// 打乱表:uid 全部落在上下文里、又含「上下文里的当前位置」的那一张。
	anchor := st.cur.uid
	if queued {
		anchor = st.lastCtxUID
	}
	for _, l := range uidLists {
		all, hasAnchor := true, false
		for _, u := range l {
			if !inCtx[u] {
				all = false
				break
			}
			hasAnchor = hasAnchor || u == anchor
		}
		if all && hasAnchor && len(l) > len(st.shuffle) {
			st.shuffle = l
		}
	}
	return st, nil
}

// spotifyState 是状态文件里预解析用得上的那几样。
type spotifyState struct {
	tracks     []spotifyCtxTrack // 上下文曲目表,原始顺序
	cur        spotifyCurrent
	shuffle    []string          // 打乱表(只有 uid),没开过随机时为空
	queue      []spotifyCtxTrack // 播放队列(手动加入),按播放顺序,正在放的那首也在里面
	lastCtxUID string            // 播放历史里最近一首属于上下文的曲目
}

// spotifyAsQueue:这个消息是不是播放队列本身 —— 带一个值恰好是 "queue" 的字符串字段,下面挂着 uid 为
// `qN` 的曲目项。认 "queue" 这个字段是为了跟播放历史分开:历史里也会出现 uid 为 q0 的那条。
func spotifyAsQueue(fields []pbField) ([]spotifyCtxTrack, bool) {
	isQueue := false
	var items []spotifyCtxTrack
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		if string(f.b) == "queue" {
			isQueue = true
			continue
		}
		sub, err := pbParse(f.b)
		if err != nil {
			continue
		}
		var t spotifyCtxTrack
		for _, x := range sub {
			if x.wire != 2 {
				continue
			}
			switch {
			case x.num == 2 && spotifyIsQueueUID(string(x.b)):
				t.uid = string(x.b)
			case x.num == 3 && len(x.b) == 16:
				t.id = spotifyGIDToID(x.b)
			case x.num == 1 && spotifyTrackIDFromURI(string(x.b)) != "":
				t.id = spotifyTrackIDFromURI(string(x.b))
			}
		}
		if t.uid != "" && t.id != "" {
			items = append(items, t)
		}
	}
	return items, isQueue && len(items) > 0
}

// spotifyAsHistoryEntry:播放历史的一条 —— 1 号字段是毫秒时间戳,2 号字段是一首曲目(带 uid)。
func spotifyAsHistoryEntry(fields []pbField) (ts uint64, uid string, ok bool) {
	for _, f := range fields {
		switch {
		case f.num == 1 && f.wire == 0 && f.v > 1_000_000_000_000:
			ts = f.v
		case f.num == 2 && f.wire == 2:
			if sub, err := pbParse(f.b); err == nil {
				for _, x := range sub {
					if x.num == 2 && x.wire == 2 && len(x.b) > 0 && len(x.b) <= 40 {
						uid = string(x.b)
					}
				}
			}
		}
	}
	return ts, uid, ts != 0 && uid != ""
}

// spotifyAsUIDList:这个消息里是否有一组「只有 uid、没有曲目」的项(打乱表的形状)。
func spotifyAsUIDList(fields []pbField) []string {
	byNum := map[int][]string{}
	order := []int{}
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		sub, err := pbParse(f.b)
		if err != nil {
			continue
		}
		uid, hasTrack := "", false
		for _, x := range sub {
			if x.wire != 2 {
				continue
			}
			switch {
			case x.num == 2 && spotifyIsContextUID(string(x.b)):
				uid = string(x.b)
			case x.num == 3 && len(x.b) == 16, x.num == 1 && spotifyTrackIDFromURI(string(x.b)) != "":
				hasTrack = true
			}
		}
		if uid == "" || hasTrack {
			continue
		}
		if _, seen := byNum[f.num]; !seen {
			order = append(order, f.num)
		}
		byNum[f.num] = append(byNum[f.num], uid)
	}
	for _, num := range order {
		if len(byNum[num]) >= 2 {
			return byNum[num]
		}
	}
	return nil
}

// spotifyApplyShuffle 按打乱表重排上下文曲目表;没有打乱表就返回 nil(调用方放弃,不拿原始顺序冒充)。
func spotifyApplyShuffle(tracks []spotifyCtxTrack, shuffle []string) []spotifyCtxTrack {
	if len(shuffle) == 0 {
		return nil
	}
	byUID := make(map[string]spotifyCtxTrack, len(tracks))
	for _, t := range tracks {
		byUID[t.uid] = t
	}
	out := make([]spotifyCtxTrack, 0, len(shuffle))
	for _, u := range shuffle {
		if t, ok := byUID[u]; ok {
			out = append(out, t)
		}
	}
	return out
}

// spotifyAsTrackList:这个消息里是否有一组曲目项(同一字段号下的曲目项按顺序返回)。
func spotifyAsTrackList(fields []pbField) []spotifyCtxTrack {
	byNum := map[int][]spotifyCtxTrack{}
	order := []int{}
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		sub, err := pbParse(f.b)
		if err != nil {
			continue
		}
		if t, ok := spotifyAsCtxTrack(sub); ok {
			if _, seen := byNum[f.num]; !seen {
				order = append(order, f.num)
			}
			byNum[f.num] = append(byNum[f.num], t)
		}
	}
	for _, num := range order {
		if len(byNum[num]) >= 2 {
			return byNum[num]
		}
	}
	return nil
}

func spotifyAsCtxTrack(fields []pbField) (spotifyCtxTrack, bool) {
	var t spotifyCtxTrack
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		switch f.num {
		case 1:
			if id := spotifyTrackIDFromURI(string(f.b)); id != "" {
				t.id = id
			}
		case 2:
			if spotifyIsContextUID(string(f.b)) {
				t.uid = string(f.b)
			}
		case 3:
			if len(f.b) == 16 && t.id == "" {
				t.id = spotifyGIDToID(f.b)
			}
		}
	}
	return t, t.uid != "" && t.id != ""
}

func spotifyAsCurrent(fields []pbField) (spotifyCurrent, bool) {
	var c spotifyCurrent
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		switch f.num {
		case 1:
			// 上下文里的歌是十六进制 uid(spotifyIsContextUID);播放队列里的是 q0、q1。
			if spotifyIsContextUID(string(f.b)) || spotifyIsQueueUID(string(f.b)) {
				c.uid = string(f.b)
			}
		case 2:
			c.id = spotifyTrackIDFromURI(string(f.b))
		}
	}
	return c, c.uid != "" && c.id != ""
}

// spotifyLocateCurrent 在曲目表里找当前这首。uid 优先:它在一个上下文里唯一,歌单里同一首歌出现两次也
// 认得出是哪一次;对不上 uid 再退回比 id。
func spotifyLocateCurrent(tracks []spotifyCtxTrack, cur spotifyCurrent) int {
	if cur.uid != "" {
		for i, t := range tracks {
			if t.uid == cur.uid {
				return i
			}
		}
	}
	for i, t := range tracks {
		if t.id == cur.id {
			return i
		}
	}
	return -1
}

// spotifyGIDToID 把 16 字节 gid 转成 22 位 base62 曲目 id(Spotify 的字母表是 0-9 a-z A-Z)。
func spotifyGIDToID(gid []byte) string {
	const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	n := new(big.Int).SetBytes(gid)
	base := big.NewInt(62)
	out := make([]byte, 22)
	mod := new(big.Int)
	for i := 21; i >= 0; i-- {
		n.DivMod(n, base, mod)
		out[i] = alphabet[mod.Int64()]
	}
	return string(out)
}

// ---- 元数据 ----

// Spotify 元数据缓存的 key:`!xmeta#cache#` + 类型 + `#` + 长度前缀的曲目 uri + `#`。类型这两段字节是
// 实测抄下来的(IdentityTrait = 01 d2,spotify.metadata.Track = 01 2a);取到的值还会再按 type_url 核对
// 一次,抄错了只会查不到,不会把别的类型当成它。
var (
	spotifyIdentityKind = []byte{0x01, 0xd2}
	spotifyTrackKind    = []byte{0x01, 0x2a}
)

func spotifyXmetaKey(kind []byte, id string) []byte {
	return spotifyXmetaKeyURI(kind, "spotify:track:"+id)
}

// spotifyXmetaKeyURI 同上,但 uri 由调用方给(专辑是 `spotify:album:<id>`)。
func spotifyXmetaKeyURI(kind []byte, uri string) []byte {
	k := []byte("!xmeta#cache#")
	k = append(k, kind...)
	k = append(k, '#', byte(len(uri)))
	k = append(k, uri...)
	return append(k, '#')
}

// spotifyResolveMeta 查这几首的元数据,已经查过的走内存缓存。
func spotifyResolveMeta(userDir string, ids []string) map[string]spotifyTrackMeta {
	out := make(map[string]spotifyTrackMeta, len(ids))
	var missing []string
	spotifyMetaMu.Lock()
	for _, id := range ids {
		if m, ok := spotifyMetaCache[id]; ok {
			out[id] = m
		} else {
			missing = append(missing, id)
		}
	}
	spotifyMetaMu.Unlock()
	if len(missing) == 0 {
		return out
	}
	keys := make([][]byte, 0, 2*len(missing))
	for _, id := range missing {
		keys = append(keys, spotifyXmetaKey(spotifyIdentityKind, id), spotifyXmetaKey(spotifyTrackKind, id))
	}
	vals := ldbGet(filepath.Join(userDir, "primary.ldb"), keys)
	spotifyMetaMu.Lock()
	defer spotifyMetaMu.Unlock()
	if len(spotifyMetaCache) >= spotifyMetaCacheCap {
		spotifyMetaCache = map[string]spotifyTrackMeta{}
	}
	for _, id := range missing {
		track := vals[string(spotifyXmetaKey(spotifyTrackKind, id))]
		m, ok := spotifyParseIdentity(vals[string(spotifyXmetaKey(spotifyIdentityKind, id))])
		if !ok {
			m, ok = spotifyParseTrackNames(track) // 电台里接下来那几首常常只有这一份,见文件头注
		}
		if !ok {
			continue // 不缓存「没查到」:这首之后可能会被客户端写进缓存
		}
		m.seconds = spotifyParseDuration(track)
		spotifyMetaCache[id] = m
		out[id] = m
	}
	return out
}

// spotifyFindAny 在一个值里找 type_url 以 suffix 结尾的 protobuf Any,返回它的 value。
func spotifyFindAny(b []byte, suffix string, depth int) []byte {
	fields, err := pbParse(b)
	if err != nil || depth > 4 {
		return nil
	}
	var typeURL string
	var value []byte
	for _, f := range fields {
		if f.wire == 2 && f.num == 1 {
			typeURL = string(f.b)
		}
		if f.wire == 2 && f.num == 2 {
			value = f.b
		}
	}
	if strings.HasPrefix(typeURL, "type.googleapis.com/") && strings.HasSuffix(typeURL, suffix) {
		return value
	}
	for _, f := range fields {
		if f.wire == 2 {
			if v := spotifyFindAny(f.b, suffix, depth+1); v != nil {
				return v
			}
		}
	}
	return nil
}

// spotifyParseIdentity 解 IdentityTrait:2=歌名,4=专辑{1=名},5=歌手{1=名}(可重复,只取第一位)。
func spotifyParseIdentity(v []byte) (spotifyTrackMeta, bool) {
	val := spotifyFindAny(v, "IdentityTrait", 0)
	if val == nil {
		return spotifyTrackMeta{}, false
	}
	fields, err := pbParse(val)
	if err != nil {
		return spotifyTrackMeta{}, false
	}
	var m spotifyTrackMeta
	firstName := func(b []byte) string {
		sub, err := pbParse(b)
		if err != nil {
			return ""
		}
		for _, f := range sub {
			if f.num == 1 && f.wire == 2 {
				return string(f.b)
			}
		}
		return ""
	}
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		switch f.num {
		case 2:
			m.title = string(f.b)
		case 4:
			m.album = firstName(f.b)
		case 5:
			if m.artist == "" {
				m.artist = firstName(f.b)
			}
		}
	}
	return m, m.title != "" && m.artist != ""
}

// spotifyParseTrackNames 从 spotify.metadata.Track 取名字:2=歌名,3=专辑{2=名},4=歌手{2=名}(可重复,只取
// 第一位,理由同 spotifyParseIdentity)。IdentityTrait 缺了才用它,见文件头注。
func spotifyParseTrackNames(v []byte) (spotifyTrackMeta, bool) {
	val := spotifyFindAny(v, "spotify.metadata.Track", 0)
	if val == nil {
		return spotifyTrackMeta{}, false
	}
	fields, err := pbParse(val)
	if err != nil {
		return spotifyTrackMeta{}, false
	}
	name := func(b []byte) string {
		sub, err := pbParse(b)
		if err != nil {
			return ""
		}
		for _, f := range sub {
			if f.num == 2 && f.wire == 2 {
				return string(f.b)
			}
		}
		return ""
	}
	var m spotifyTrackMeta
	for _, f := range fields {
		if f.wire != 2 {
			continue
		}
		switch f.num {
		case 2:
			m.title = string(f.b)
		case 3:
			m.album = name(f.b)
		case 4:
			if m.artist == "" {
				m.artist = name(f.b)
			}
		}
	}
	return m, m.title != "" && m.artist != ""
}

// spotifyParseDuration 取 spotify.metadata.Track 的时长(第 7 个字段,sint32 zigzag,毫秒)。拿不到是 0,
// 交给解析路径自己去问。
func spotifyParseDuration(v []byte) float64 {
	val := spotifyFindAny(v, "spotify.metadata.Track", 0)
	if val == nil {
		return 0
	}
	fields, err := pbParse(val)
	if err != nil {
		return 0
	}
	for _, f := range fields {
		if f.num == 7 && f.wire == 0 {
			ms := int64(f.v>>1) ^ -int64(f.v&1)
			if ms > 0 {
				return float64(ms) / 1000
			}
		}
	}
	return 0
}

// ---- 最小的 protobuf 解码 ----

type pbField struct {
	num  int
	wire int
	v    uint64 // varint / fixed
	b    []byte // length-delimited
}

// pbParse 把一段字节按 protobuf wire format 拆成字段;任何一处不合法就整体报错(说明它不是一个消息)。
func pbParse(b []byte) ([]pbField, error) {
	var out []pbField
	for i := 0; i < len(b); {
		key, n := binary.Uvarint(b[i:])
		if n <= 0 {
			return nil, errors.New("pb: bad key")
		}
		i += n
		f := pbField{num: int(key >> 3), wire: int(key & 7)}
		if f.num == 0 {
			return nil, errors.New("pb: field 0")
		}
		switch f.wire {
		case 0:
			v, m := binary.Uvarint(b[i:])
			if m <= 0 {
				return nil, errors.New("pb: bad varint")
			}
			f.v = v
			i += m
		case 1:
			if i+8 > len(b) {
				return nil, errors.New("pb: short fixed64")
			}
			f.v = binary.LittleEndian.Uint64(b[i:])
			i += 8
		case 5:
			if i+4 > len(b) {
				return nil, errors.New("pb: short fixed32")
			}
			f.v = uint64(binary.LittleEndian.Uint32(b[i:]))
			i += 4
		case 2:
			l, m := binary.Uvarint(b[i:])
			if m <= 0 || uint64(i+m)+l > uint64(len(b)) {
				return nil, errors.New("pb: bad length")
			}
			f.b = b[i+m : i+m+int(l)]
			i += m + int(l)
		default:
			return nil, errors.New("pb: unsupported wire type")
		}
		out = append(out, f)
	}
	return out, nil
}
