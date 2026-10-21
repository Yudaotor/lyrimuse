package main

import (
	"math"
	"regexp"
	"time"
)

// 另开「~durN」条目(resolveEnrichKeyForDuration)之前的去抖:这一拍的时长跟命中的条目差太多、要另开的那一位还空着时,
// 同一个时长(±1 秒)要连续观察满 durationVariantConfirm 才建。快速切歌时系统快照里的时长会停在上一首(歌名已经换了),
// 一闪而过;没满之前 trackEnrichment 这一拍返回空,轮询把这首挂起、下一拍再问(poller.go 的 pnPending)。时长跟命中的
// 条目对上就清掉记录。只在 enrichMu 临界区内读写。见 09 章决策 192。
const (
	durationVariantConfirm = 4 * time.Second
	// durationVariantMaxGap:两次观察隔得比这久就重新计时。挂起期间轮询一拍一问,远小于它。
	durationVariantMaxGap = 15 * time.Second
	// durationVariantSeenCap:记录条数上限,满了整个清掉。
	durationVariantSeenCap = 256
)

type durationVariantObs struct {
	durationSecs        float64
	firstSeen, lastSeen time.Time
}

var durationVariantSeen = map[string]durationVariantObs{}

// durationVariantSteadyLocked:key 是命中的那一条(还没换成变体)。满了返回 true 并清掉记录。
func durationVariantSteadyLocked(key string, durationSecs float64, now time.Time) bool {
	obs, ok := durationVariantSeen[key]
	if !ok || math.Abs(obs.durationSecs-durationSecs) > 1 || now.Sub(obs.lastSeen) > durationVariantMaxGap {
		if len(durationVariantSeen) >= durationVariantSeenCap {
			durationVariantSeen = map[string]durationVariantObs{}
		}
		durationVariantSeen[key] = durationVariantObs{durationSecs: durationSecs, firstSeen: now, lastSeen: now}
		return false
	}
	obs.lastSeen = now
	durationVariantSeen[key] = obs
	if now.Sub(obs.firstSeen) < durationVariantConfirm {
		return false
	}
	delete(durationVariantSeen, key)
	return true
}

// enrichCreatedThisPlay:正在播的那首首次解析时新建的条目,连同是哪一次播放(换歌那一拍 noteEnrichPlayingKey 存的指针,
// 每换一首一份新的)。开播头一两拍报的时长可能不对(汽水试听换回整首之前),主条目按它建了;同一次播放里时长稳定成另一个值,
// 是这条记录的时长记错了、不是另一段录音:原地改时长,不另开「~durN」(trackEnrichment 时长那段)。只在 enrichMu 临界区内读写。
// 见 09 章决策 234。
var enrichCreatedThisPlay struct {
	key  string
	play *string
}

// noteEnrichCreatedLocked:首次解析开跑时记一笔,只记正在播的那首。别再按 isNewTrack 挑:汽水试听段要先搜,
// 正在播的这首常常是挂起之后那一拍(isNewTrack=false)才起解析。
func noteEnrichCreatedLocked(key string) {
	if !isEnrichPlayingKey(key) {
		return
	}
	enrichCreatedThisPlay.key, enrichCreatedThisPlay.play = key, enrichPlayingKey.Load()
}

// enrichCreatedThisPlayLocked:key 是这一次播放里刚建的(播放还没换过歌)。
func enrichCreatedThisPlayLocked(key string) bool {
	return enrichCreatedThisPlay.key == key && enrichCreatedThisPlay.play != nil &&
		enrichPlayingKey.Load() == enrichCreatedThisPlay.play
}

// playingSongIDFor:这个播放器这一拍报的这首歌的曲目 id,跟条目里 PlayerSongIDs 记的是同一种(Apple Music 是目录锚点里的
// 曲目 id,QQ 音乐、网易云、酷狗是它们本机记的歌曲 id,洛雪是它本地库里那一条的 id)。别的播放器不报,返回空串。
func playingSongIDFor(bundleID, anchorLink string, ids playerCatalogIDs) string {
	switch bundleID {
	case appleMusicBundleID:
		return appleCatalogIDFromURL(anchorLink)
	case qqMusicBundleID, neteaseMusicBundleID, kugouMusicBundleID, lxMusicBundleID:
		return ids.songID
	}
	return ""
}

// sameRecordingAsPlaying:条目记下的这个播放器的曲目 id 就是这一拍报的那个 —— 同一段录音。时长对不上时,错的是这一拍的
// 时长(撕裂快照、预载窗口、开播头一拍),不是另一段录音:不另开「~durN」(trackEnrichment 时长那段)。id 为空判不了,
// 返回 false,照旧按时长分。见 09 章决策 251。
func sameRecordingAsPlaying(e enrichEntry, bundleID, songID string) bool {
	return songID != "" && e.PlayerSongIDs[bundleID] == songID
}

// sameRecordingEntries:两条记着同一个播放器的同一个曲目 id。只认播放器自己报的 id,不认 ISRC:ISRC 有一部分是按歌名搜
// 目录补的,不同版本之间会串。
func sameRecordingEntries(a, b enrichEntry) bool {
	for bundle, id := range a.PlayerSongIDs {
		if id != "" && b.PlayerSongIDs[bundle] == id {
			return true
		}
	}
	return false
}

// variantFoldsIntoBase:启动迁移把这条「~durN」并回基条目(planEnrichKeyMigration),不看时长,留哪一份按 betterEnrichEntry。
//   - 记着同一个播放器的同一个曲目 id:同一段音频,两边时长不一样只能是其中一边记错了(MV 跟音轨在播放器里是两个 id)。
//   - 基条目从没被哪个播放器放过、变体放过:基条目是预取 / 导入时按歌名猜的,不一定是放的那一首(猜成一小时的混音版这种)。
//     放过的那条更差(试听段按片段长度搜到的词)时留的是基条目。
//
// 见 09 章决策 251。
func variantFoldsIntoBase(variant, base enrichEntry) bool {
	if sameRecordingEntries(variant, base) {
		return true
	}
	return len(base.Players) == 0 && len(base.PlayerSongIDs) == 0 && len(variant.Players) > 0
}

var durationVariantSuffix = regexp.MustCompile(`~dur[0-9]+$`)

// splitEnrichKeyForSearch:从缓存 key 拆出拿去搜歌词的三段,歌名去掉「~durN」。实际放这首时歌名是播放器给的、不带这个标记,
// 按 key 重搜的后台路径(补空扫描、全量扫库、手动重新匹配)要跟它一样;写回照旧按原 key。带着标记去搜一条都搜不到,
// 标题反查再按时长换成同歌手的另一首。见 09 章决策 318。
func splitEnrichKeyForSearch(key string) (artist, title, album string) {
	artist, title, album = splitEnrichKey(key)
	return artist, titleWithoutDurationVariant(title), album
}

// titleWithoutDurationVariant 去掉歌名末尾的「~durN」(缓存键里的时长消歧位),拿曲名本身去搜;不是变体原样返回。
func titleWithoutDurationVariant(title string) string {
	loc := durationVariantSuffix.FindStringIndex(title)
	if loc == nil || loc[0] == 0 {
		return title
	}
	return title[:loc[0]]
}

// durationVariantBaseKey:「歌手|歌名~durN|专辑」→「歌手|歌名|专辑」(enrichKeyDurationVariant 的反向)。不是变体返回 false。
func durationVariantBaseKey(key string) (string, bool) {
	artist, title, album := splitEnrichKey(key)
	loc := durationVariantSuffix.FindStringIndex(title)
	if loc == nil || loc[0] == 0 {
		return "", false
	}
	return artist + "|" + title[:loc[0]] + "|" + album, true
}

// durationSameRecordingLogged:「同一段录音,留在这条上」那一行只记一次(同一首每几秒进来一次)。满了整个清掉。
var durationSameRecordingLogged = map[string]bool{}
