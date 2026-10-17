package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

// 歌曲实体阶段 3:歌词按实体同步。开关 songEntitySharing()(`lyrimuse-features.json` 的 `song_entity_share_lyrics`,
// 默认关,界面不露出;阶段 0 的建表要开着)。见 18 章决策 26、27。
//   - 手改、采纳(采纳的那一份还在)同步到同一个共享组:改的当场同步(shareManualEditLocked),存量和后来才挂进组里的写法由
//     每次建表之后那一轮补上。只靠检索 id、只算计数连着的写法不在同一组,不跟(没把握是同一份录音的不同步,18 章决策 58)。
//     对方自己的手改原件、校准挡得住,标了纯音乐的不动;组里两份内容不同的原件不替用户选。副本带同样的手改标记,
//     lyrics_entity_origin 记原件。
//   - 组里没有手改时按共享组。组里钉着的写法、App 记下的校准正对着它现在这份歌词的(lyricsPinsFile.Content),其余写法
//     跟着用这一份、读穿那个偏移(sharePinnedPass),两份不同的这种校准不替用户选;组里钉着、校准却对着别的歌词的不动。
//     组里没有校准、歌词不止一份或有写法没词的(shareEvalGroups),以整首歌重搜一轮,冠军是整组那一份,每条写法的去留跟
//     正式空跑同一套(shareEvalPlan)。
//   - 同一首歌里歌词正是一份校准对着的写法(App 读穿那个偏移),后台不再自动给它换词(lyricsCalibratedLocked),按共享组
//     重搜时也留着自己那份。
//   - 写法第一次被同步覆盖之前整条存进 lyrimuse-song-entity-pre/(只存一次),synced 记同步最近一次要写进去的那份;开关
//     关掉时,歌词还是同步写进去那份的写法按它恢复(revertSongEntityShare)。第一次同步之前另把主缓存和正文小文件目录整份
//     克隆到 ~/.config/lyrimuse-backups/<时刻>-song-entity/,备份不成就不同步。
//   - 搜过的共享组记在 lyrimuse-song-entity-share.json:成员和各自的歌词都没变、打分版本也没变的,下一轮不再搜。

const (
	songShareStateVersion = 1
	// songShareCheckInterval:多久看一次开关有没有翻面。
	songShareCheckInterval = time.Minute
	// songShareRetryIncomplete:有写法因为来源没应答留着、或者这一轮有源被跳过的组,隔这么久再搜(赶上下一次建表)。
	songShareRetryIncomplete = 20 * time.Hour
	// songShareRetryNoWinner:这一轮没有可用候选的组隔这么久再搜。
	songShareRetryNoWinner = 7 * 24 * time.Hour
)

// songShareWait:两组之间、连不上歌词源时的等待,ctx 取消时立刻返回。测试换成不等。
var songShareWait = songShareSleep

// songShareSleep:songShareWait 的真身。等的时候来了拆开、恢复合并请的马上重建(songEntityRebuildNow)也立刻返回,请求放回去:
// 这一轮停在两组之间(songShareRebuildPending),常驻循环接着就建(18 章决策 28)。
func songShareSleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	case <-songEntityRebuildNow:
		requestSongEntityRebuild()
	}
}

// songShareRebuildPending:有拆开、恢复合并请的马上重建在排着。同步一轮跑在常驻循环里,一整轮要搜很多组(第一轮一个多小时),
// 等它跑完才重建的话,拆开之后实体表、共享组要等那么久才跟上;所以两组之间看到请求就停,没轮到的组重建之后那一轮接着搜
// (搜过的记在组的记录里,不会重搜)。只看不取,请求留给常驻循环。
func songShareRebuildPending() bool { return len(songEntityRebuildNow) > 0 }

// songEntitySharing:歌词同步这一刻开着没有。
func songEntitySharing() bool {
	f := features()
	return f.SongEntityShadow && f.SongEntityShareLyrics
}

func songSharePreDir() string    { return configFilePath(clientName + "-song-entity-pre") }
func songShareStatePath() string { return configFilePath(clientName + "-song-entity-share.json") }

// songShareBackupDir:第一次同步之前整份备份的去处:跟配置目录同级的 lyrimuse-backups 下按时刻建。
func songShareBackupDir(now time.Time) string {
	dir := configDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(dir), clientName+"-backups", now.Format("20060102-150405")+"-song-entity")
}

// songShareState:lyrimuse-song-entity-share.json。FullBackup 是第一次同步之前那份整份备份的目录;Groups 按成员算的签名
// (songShareGroupSig)记每个搜过的共享组。
type songShareState struct {
	Version    int                            `json:"version"`
	FullBackup string                         `json:"full_backup,omitempty"`
	Groups     map[string]songShareGroupState `json:"groups,omitempty"`
}

// songShareGroupState:一个共享组上一次搜完的样子。Members 是写法键 → 那之后的歌词指纹(没词为空);RetryAfter 非零时
// 到点再搜一次。
type songShareGroupState struct {
	At         int64             `json:"at"`
	Scoring    string            `json:"scoring"`
	Members    map[string]string `json:"members"`
	RetryAfter int64             `json:"retry_after,omitempty"`
}

// songShareGroupSig:一组写法的签名,成员变了签名就变。
func songShareGroupSig(keys []string) string {
	s := slices.Clone(keys)
	sort.Strings(s)
	sum := sha256.Sum256([]byte(strings.Join(s, "\x1f")))
	return hex.EncodeToString(sum[:16])
}

// due:这个组这一轮要不要搜。fps 是各写法现在的歌词指纹;成员变了签名就变,没有记录。
func (st *songShareState) due(sig string, fps map[string]string, now time.Time) bool {
	g, ok := st.Groups[sig]
	if !ok || g.Scoring != currentLyricsScoring.String() {
		return true
	}
	for k, fp := range fps {
		if g.Members[k] != fp {
			return true
		}
	}
	return g.RetryAfter > 0 && now.Unix() >= g.RetryAfter
}

// readSongShareState:读不到、解不开、版本对不上都当没有(只多搜一轮,不丢东西;整份备份会再做一份)。
func readSongShareState(path string) *songShareState {
	st := &songShareState{Version: songShareStateVersion, Groups: map[string]songShareGroupState{}}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return st
	}
	var f songShareState
	if err := json.Unmarshal(data, &f); err != nil || f.Version != songShareStateVersion {
		noteFileErr("decode", path, err)
		return st
	}
	if f.Groups == nil {
		f.Groups = map[string]songShareGroupState{}
	}
	return &f
}

func writeSongShareState(path string, st *songShareState) error {
	data, err := json.Marshal(st)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return writeFileAtomic(path, data)
}

// songSharePre:一条写法第一次被同步覆盖之前的样子(lyrimuse-song-entity-pre/<写法键哈希>.json)。Entry 是整条条目(带正文),
// 只写一次;Synced 是同步最近一次要写进去的那份的歌词指纹,每次同步前更新。
type songSharePre struct {
	Key     string          `json:"key"`
	SavedAt int64           `json:"saved_at"`
	Synced  string          `json:"synced"`
	Entry   json.RawMessage `json:"entry"`
}

func songSharePrePath(key string) string {
	return filepath.Join(songSharePreDir(), decisionSidecarName(key))
}

func readSongSharePre(path string) (*songSharePre, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p songSharePre
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	return &p, nil
}

// writeSongSharePre:同步要把 key 这条写法换成指纹为 synced 的那一份之前调,e 是它这一刻的样子。还没有留底时整条存进去
// (当前歌词的出处连候选明细一起:同步之后旁路文件里那一槽就换成同步那一轮了),已经有了只改 synced;created 说这次是不是
// 新建的。已有的文件读不出来时不覆盖、报错(那条写法这一轮不同步)。
func writeSongSharePre(key string, e enrichEntry, synced string, now time.Time) (created bool, err error) {
	return putSongSharePre(key, e, synced, now, true)
}

// stageSongSharePre:同 writeSongSharePre,只是已经有留底时什么都不改(synced 也不动)。按组重搜在锁外先把没有的留底建好,
// 已有的那份等持锁核对过、真要换词时才改 synced(writeSongSharePre):这一轮作废时已有的留底还对得上现在的歌词,关开关、
// 拆开照样恢复得了。
func stageSongSharePre(key string, e enrichEntry, synced string, now time.Time) (created bool, err error) {
	return putSongSharePre(key, e, synced, now, false)
}

// putSongSharePre:writeSongSharePre / stageSongSharePre 共用;update 为 false 时已有的留底原样留着。
func putSongSharePre(key string, e enrichEntry, synced string, now time.Time, update bool) (created bool, err error) {
	path := songSharePrePath(key)
	rec := &songSharePre{Key: key, SavedAt: now.Unix()}
	switch old, err := readSongSharePre(path); {
	case err == nil && old.Key == key && len(old.Entry) > 0:
		if !update {
			return false, nil
		}
		rec = old
	case err == nil:
		return false, fmt.Errorf("%s: belongs to %q", path, old.Key)
	case !errors.Is(err, os.ErrNotExist):
		return false, err
	default:
		e.LyricsDecisionApplied = withDecisionDetails(key, e.LyricsDecisionApplied)
		if rec.Entry, err = json.Marshal(e); err != nil {
			return false, err
		}
		created = true
	}
	rec.Synced = synced
	data, err := json.Marshal(rec)
	if err != nil {
		return false, err
	}
	if err := os.MkdirAll(songSharePreDir(), 0o700); err != nil {
		return false, err
	}
	return created, writeFileAtomic(path, data)
}

// songShareLyricsFields:同步与恢复动的字段,把 src 的搬到 dst:歌词选择(正文、译文、罗马音、逐字、背景人声、来源、分数、
// 打分版本、按多长的时长选的、演唱者标注、纯文本)、跟着正文走的语种与译文账、手改标记与原件、这份歌词出自哪一轮(出现过 /
// 应答过 / 跳过的源、当前歌词的出处)。引擎各处的闸看的就是这几项。字段归属登记(songEntityFieldClasses)里歌词选择那一类
// 加了字段,这里跟着加,TestSongShareFieldsCoverLyricsChoice 守着。
func songShareLyricsFields(dst *enrichEntry, src enrichEntry) {
	dst.Lyrics, dst.LyricsTr, dst.LyricsRoma, dst.LyricsYRC = src.Lyrics, src.LyricsTr, src.LyricsRoma, src.LyricsYRC
	dst.LyricsBG, dst.LyricsBGChecked = src.LyricsBG, src.LyricsBGChecked
	dst.LyricsSource, dst.LyricsScore = src.LyricsSource, src.LyricsScore
	dst.LyricsScoringVersion, dst.LyricsScoringRevision = src.LyricsScoringVersion, src.LyricsScoringRevision
	dst.ResolvedDurationSecs = src.ResolvedDurationSecs
	dst.LyricsSpeakers, dst.LyricsSpeakersChecked = src.LyricsSpeakers, src.LyricsSpeakersChecked
	dst.PlainLyrics, dst.PlainLyricsSource = src.PlainLyrics, src.PlainLyricsSource
	dst.SongLanguage = src.SongLanguage
	dst.LyricsTrSource, dst.LyricsTrLang = src.LyricsTrSource, src.LyricsTrLang
	dst.TranslationLang, dst.TranslationTS, dst.TranslationRetryCount = src.TranslationLang, src.TranslationTS, src.TranslationRetryCount
	dst.ManualLyrics, dst.ManualPickSHA, dst.LyricsEntityOrigin = src.ManualLyrics, src.ManualPickSHA, src.LyricsEntityOrigin
	dst.LyricsSourcesSeen, dst.LyricsSourcesResponded, dst.LyricsSourcesSkipped = src.LyricsSourcesSeen, src.LyricsSourcesResponded, src.LyricsSourcesSkipped
	dst.LyricsDecisionApplied = src.LyricsDecisionApplied
}

// songShareManualOriginal:手改原件:手改过或者采纳的那一份还在,有正文,不是同步出去的副本。
func songShareManualOriginal(e enrichEntry) bool {
	return e.LyricsEntityOrigin == "" && strings.TrimSpace(e.Lyrics) != "" && (e.ManualLyrics || songSharePickHeld(e))
}

// songShareCopyCurrent:e 已经是原件 origin(条目 src)现在这一份的副本。
func songShareCopyCurrent(e, src enrichEntry, origin string) bool {
	return e.LyricsEntityOrigin == origin && e.Lyrics == src.Lyrics && e.LyricsYRC == src.LyricsYRC && e.LyricsTr == src.LyricsTr &&
		e.LyricsRoma == src.LyricsRoma && e.LyricsSource == src.LyricsSource && e.ManualLyrics == src.ManualLyrics &&
		e.ManualPickSHA == src.ManualPickSHA
}

// songShareCopyManual:dst 改成原件 origin(条目 src)的副本。词曲作者描述的是这首歌,原件没有时留着自己的。
func songShareCopyManual(dst *enrichEntry, src enrichEntry, origin string, now time.Time) {
	songShareLyricsFields(dst, src)
	if len(src.LyricsSongwriters) > 0 {
		dst.LyricsSongwriters = src.LyricsSongwriters
	}
	dst.LyricsEntityOrigin = origin
	dst.LyricsDecisionApplied = &lyricsDecision{Path: lyricsDecisionPathSongEntityShare, DecidedAt: now.Unix(), ReusedFrom: origin}
}

// songShareCopyPinned:dst 改成同组校准那条 origin(条目 src)现在这一份。不是手改,不记 lyrics_entity_origin。
func songShareCopyPinned(dst *enrichEntry, src enrichEntry, origin string, now time.Time) {
	songShareCopyManual(dst, src, origin, now)
	dst.LyricsEntityOrigin = ""
}

// shareManualLocked:keys 是一个共享组的全部写法。from 非空时它是刚改的那条,其余写法跟着它;为空时(建表之后那一轮)组里
// 原件只有一份内容才跟,两份不同的不替用户选(conflict)。组里一个原件都没有时:原件已经不在缓存里的副本,挑键最小的一条
// 升成原件,其余照它同步;原件还在、却不在这个组里的副本(分到了别的组或别的实体),按留底恢复(releaseStaleCopiesLocked)。
// 返回改了的写法。调用方持 enrichMu。
func shareManualLocked(keys []string, from string, pins map[string]bool, now time.Time) (changed []string, conflict bool) {
	// 建表之后那一轮(from 为空)是自动改写,过翻转保险;用户自己的保存、统一两份手改不算。
	allow := func(string) bool { return true }
	if from == "" {
		allow = func(k string) bool { return songShareAutoWriteAllowedLocked(k, now) }
	}
	origin := from
	if origin == "" {
		contents := map[string]string{}
		for _, k := range keys {
			e := enrichCache[k]
			if !songShareManualOriginal(e) {
				continue
			}
			fp := songOffsetFingerprint(e.Lyrics, e.LyricsYRC)
			if cur, ok := contents[fp]; !ok || k < cur {
				contents[fp] = k
			}
		}
		switch len(contents) {
		case 0:
			if origin = promoteOrphanCopyLocked(keys, allow); origin == "" {
				return releaseStaleCopiesLocked(keys, allow), false
			}
			changed = append(changed, origin)
		case 1:
			for _, k := range contents {
				origin = k
			}
		default:
			return nil, true
		}
	}
	src := enrichCache[origin]
	if !songShareManualOriginal(src) {
		return changed, false
	}
	fp := songOffsetFingerprint(src.Lyrics, src.LyricsYRC)
	for _, k := range keys {
		e, ok := enrichCache[k]
		if !ok || k == origin || songShareManualOriginal(e) || pins[k] || e.Instrumental {
			continue
		}
		if songShareCopyCurrent(e, src, origin) || !allow(k) {
			continue
		}
		if _, err := writeSongSharePre(k, e, fp, now); err != nil {
			slog.Error("song entities: back up before syncing manual lyrics", "key", k, "err", err)
			continue
		}
		songShareCopyManual(&e, src, origin, now)
		enrichCache[k] = e
		changed = append(changed, k)
	}
	return changed, false
}

// promoteOrphanCopyLocked:原件已经不在缓存里(被删了)的副本里挑键最小的一条升成原件,返回它;没有这种副本时返回空串。
// 升上来的那条删掉留底:开关关掉时它留着用户的词,不恢复成同步之前的。allow 不让改的跳过。调用方持 enrichMu。
func promoteOrphanCopyLocked(keys []string, allow func(key string) bool) string {
	for _, k := range keys {
		e := enrichCache[k]
		if e.LyricsEntityOrigin == "" {
			continue
		}
		if _, live := enrichCache[e.LyricsEntityOrigin]; live {
			continue
		}
		e.LyricsEntityOrigin = ""
		if !songShareManualOriginal(e) || !allow(k) {
			continue
		}
		enrichCache[k] = e
		noteFileErr("remove", songSharePrePath(k), removeIfExists(songSharePrePath(k)))
		slog.Info("song entities: manual lyrics origin is gone, promoting a copy", "key", k)
		return k
	}
	return ""
}

// releaseStaleCopiesLocked:keys 这个实体里已经没有手改原件,剩下的副本(原件还在、却改回了自动匹配,或者分到了别的实体)
// 不再跟着谁:歌词还是同步写进去那份的按留底恢复、删掉留底;没有能用的留底时只去掉副本标记和手改标记,词留着、交回自动
// 流程。allow 不让改的跳过(nil 时都改)。返回改了的写法。调用方持 enrichMu。
func releaseStaleCopiesLocked(keys []string, allow func(key string) bool) []string {
	var changed []string
	for _, k := range keys {
		e := enrichCache[k]
		if e.LyricsEntityOrigin == "" || (allow != nil && !allow(k)) {
			continue
		}
		if pre, ok := songShareRestorable(k, e); ok {
			songShareRestore(&e, pre)
			noteFileErr("remove", songSharePrePath(k), removeIfExists(songSharePrePath(k)))
		} else {
			e.LyricsEntityOrigin, e.ManualLyrics, e.ManualPickSHA = "", false, ""
		}
		enrichCache[k] = e
		changed = append(changed, k)
	}
	return changed
}

// removeSongSharePre:条目删掉时把它的同步留底一起删。留底只写一次,留着的话这条写法再放回来、又被同步时会沿用删之前那份,
// 关开关或拆开时恢复成删掉的旧歌词。
func removeSongSharePre(key string) {
	noteFileErr("remove", songSharePrePath(key), removeIfExists(songSharePrePath(key)))
}

// songShareAutoCopyOf:e 是自动同步写进来的副本(按组重搜换成组里搜的那条、跟着校准、跟上重新匹配)时返回它跟的那条写法;
// 手改副本、自己搜的、出处不是同步的返回空串。
func songShareAutoCopyOf(e enrichEntry) string {
	d := e.LyricsDecisionApplied
	if e.LyricsEntityOrigin != "" || d == nil || d.Path != lyricsDecisionPathSongEntityShare {
		return ""
	}
	return d.ReusedFrom
}

// releaseStrayAutoCopiesLocked:keys 这个共享组里,自动同步写进来的副本跟的那条写法还在、却已经不在这一组(证据变了,分到了
// 别的组或别的实体):没把握是同一份录音就不共用歌词,歌词还是同步写进去那份的按留底恢复、删掉留底(18 章决策 60)。跟的那条
// 已经删了的不动:词本身没错。过翻转保险。返回改了的写法。调用方持 enrichMu。
func releaseStrayAutoCopiesLocked(keys []string, now time.Time) []string {
	var changed []string
	for _, k := range keys {
		e := enrichCache[k]
		from := songShareAutoCopyOf(e)
		if from == "" || from == k {
			continue
		}
		src, ok := enrichCache[from]
		if !ok || (src.Song == e.Song && src.SongShare == e.SongShare) {
			continue
		}
		pre, ok := songShareRestorable(k, e)
		if !ok || !songShareAutoWriteAllowedLocked(k, now) {
			continue
		}
		songShareRestore(&e, pre)
		enrichCache[k] = e
		noteFileErr("remove", songSharePrePath(k), removeIfExists(songSharePrePath(k)))
		changed = append(changed, k)
	}
	if len(changed) > 0 {
		slog.Info("song entities: released synced lyrics that no longer share a group with their source", "versions", len(changed))
	}
	return changed
}

// songShareRestorable:key 这条写法有留底,而且歌词还是同步写进去的那一份,返回留底里的条目。
func songShareRestorable(key string, e enrichEntry) (enrichEntry, bool) {
	p, err := readSongSharePre(songSharePrePath(key))
	if err != nil || p.Key != key || p.Synced != songOffsetFingerprint(e.Lyrics, e.LyricsYRC) {
		return enrichEntry{}, false
	}
	var pre enrichEntry
	if err := json.Unmarshal(p.Entry, &pre); err != nil {
		return enrichEntry{}, false
	}
	return pre, true
}

// songShareRestore:按留底把同步动过的字段改回去(词曲作者也回到原来的)。
func songShareRestore(e *enrichEntry, pre enrichEntry) {
	songShareLyricsFields(e, pre)
	e.LyricsSongwriters = pre.LyricsSongwriters
}

// shareManualEditLocked:歌词管理刚把 key 这条存成手改或采纳(applySaveEdit),开关开着时同步到同一个共享组,返回跟着改了的
// 写法。调用方持 enrichMu。
func shareManualEditLocked(key string, now time.Time) []string {
	e := enrichCache[key]
	if e.Song == "" || !songShareManualOriginal(e) {
		return nil
	}
	var keys []string
	for k, x := range enrichCache {
		if x.Song == e.Song && x.SongShare == e.SongShare {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	changed, _ := shareManualLocked(keys, key, lyricsPinnedKeys(), now)
	for _, k := range changed {
		cancelInFlightEnrichLocked(k)
	}
	if len(changed) > 0 {
		slog.Info("song entities: synced manual lyrics", "from", key, "to", len(changed))
	}
	return changed
}

// songShareRound:共享组这一轮的检索:搜的名字、时长、打过分的全部候选,连没连上歌词源、跳过了哪些源、问过的查询词。
type songShareRound struct {
	shareEvalRound
	reached    bool
	skipped    []string
	statsSkips map[string]string
	queries    []lyricQueryRecord
}

// complete:这一轮没有源被跳过(熔断冷却、后台暂停),结论按完整信息得出。
func (r *songShareRound) complete() bool { return len(r.skipped) == 0 }

// searchShareRound:以 key 那条写法的名字、时长 dur 重搜一轮。检索的上下文跟 rescoreLyricsWith 同一套;没有在放的播放器,
// 分数里不会有自家源加分。测试换成不联网的。
var searchShareRound = func(ctx context.Context, key, artist, title, album string, dur float64) songShareRound {
	enrichMu.Lock()
	listed, stored := enrichCache[key].YouTubeMusicAlbum, enrichCache[key].LyricsSearchTitle
	sctx := withCachedYouTubeMusicVideoIDLocked(ctx, key)
	enrichMu.Unlock()
	sctx = withLearnedAliasSelf(sctx, key)
	searchAlbum, _ := lyricsSearchAlbum(sctx, album, listed, dur, artist, title)
	roundCtx, round := withLyricSourceRound(sctx)
	roundCtx, queries := withLyricQueryLog(roundCtx)
	roundCtx = withLyricSourceTitle(roundCtx, lyricSearchTitleOrStored(sctx, stored, title), artist, title, searchAlbum)
	qa, qt, qal := searchQueryFields(artist, title, searchAlbum)
	_, scored := scoredLyricCandidatesStreaming(withSearchQueryOriginal(roundCtx, artist, title, searchAlbum), qa, qt, qal, dur, nil)
	return songShareRound{
		shareEvalRound: shareEvalRound{Key: key, Artist: artist, Title: title, Album: searchAlbum, Duration: dur, Scored: scored},
		reached:        round.reachedAny(),
		skipped:        round.skippedSources(),
		statsSkips:     round.statsSkips(),
		queries:        queries.queries(),
	}
}

// songShareApplyChoice:把这一轮的冠军 c 写进 e,字段跟自动重评换词那一支(rescoreLyricsWith)一样,当前歌词的出处记成 d。
// roma 是在锁外按冠军正文预先生成的罗马音(冠军自己带了就是空串)。
func songShareApplyChoice(e *enrichEntry, c *scoredLyricCandidateResult, r *songShareRound, roma string, d *lyricsDecision) {
	e.Lyrics = c.Lyrics
	e.LyricsTr, e.LyricsRoma, e.LyricsYRC = c.LyricsTr, c.LyricsRoma, c.LyricsYRC
	e.LyricsBG, e.LyricsBGChecked = c.LyricsBG, lyricsBGParserVersion
	e.SongLanguage = entrySongLanguage(c.Lyrics, r.Scored)
	e.dropHokkienRoma()
	e.dropUnusableCantoneseRoma()
	e.applyPregeneratedRoma(roma)
	e.LyricsTrLang, e.LyricsTrSource = c.LyricsTrLang, ""
	e.LyricsSource, e.LyricsScore = c.Source, c.Score
	if r.complete() {
		e.stampLyricsScoring()
	}
	e.ResolvedDurationSecs = r.Duration
	if seen := lyricSourcesWithCandidates(r.Scored); len(seen) > 0 {
		e.LyricsSourcesSeen = seen
	}
	if responded := lyricSourcesResponded(r.Scored); len(responded) > 0 {
		e.LyricsSourcesResponded = responded
	}
	e.LyricsSourcesSkipped = lyricSourcesSkippedForRetry(r.skipped)
	if sw := songwritersFromScored(r.Scored); len(sw) > 0 {
		e.LyricsSongwriters = sw
	}
	refreshSpeakers(e, r.Scored)
	e.LyricsEntityOrigin = ""
	e.LyricsDecisionApplied = d
}

// removeStagedSongSharePres:stageSongSharePre 这一轮新建的留底里,没有换成(不在 applied 里)的删掉。
func removeStagedSongSharePres(created, applied map[string]bool) {
	for k := range created {
		if !applied[k] {
			noteFileErr("remove", songSharePrePath(k), os.Remove(songSharePrePath(k)))
		}
	}
}

// songShareGroupOutcome:一个共享组这一轮的结局。state 为 nil:这一轮没做成(有写法正在被别的任务处理、开搜之后被改过),
// 下一轮再来。
type songShareGroupOutcome struct {
	offline, noWinner     bool
	changed, filled, kept int
	state                 *songShareGroupState
}

// songShareGroupStateLocked:这一组现在的样子,retry 非零时到点再搜。调用方持 enrichMu。
func songShareGroupStateLocked(keys []string, now, retry time.Time) *songShareGroupState {
	s := &songShareGroupState{At: now.Unix(), Scoring: currentLyricsScoring.String(), Members: map[string]string{}}
	for _, k := range keys {
		e := enrichCache[k]
		s.Members[k] = songOffsetFingerprint(e.Lyrics, e.LyricsYRC)
	}
	if !retry.IsZero() {
		s.RetryAfter = retry.Unix()
	}
	return s
}

// applyShareRound:按这一轮的检索改一个共享组。keys、own、snap 逐条对齐,snap 是开搜前那一刻的条目,stamp 是那一刻的
// 改动序号。整组的去留按 shareEvalPlan;要换的先把没有的留底建好(stageSongSharePre),再持锁核对开搜之后谁都没动过、组里
// 也没有手改或采纳(这种组不按重搜改,shareEvalGroups 不收),一次改完,已有留底的 synced 这时才改。作废时删掉这一轮新建的
// 留底,已有的原样留着。
func applyShareRound(keys []string, own []*songPlanLyrics, snap []enrichEntry, stamp uint64, round songShareRound, now time.Time) songShareGroupOutcome {
	var out songShareGroupOutcome
	top := pickLyricCandidatePreferring(round.Scored, "")
	if top == nil {
		out.noWinner = true
		enrichMu.Lock()
		out.state = songShareGroupStateLocked(keys, now, now.Add(songShareRetryNoWinner))
		enrichMu.Unlock()
		return out
	}
	index := make(map[string]int, len(keys))
	for i, k := range keys {
		index[k] = i
	}
	fp := songOffsetFingerprint(top.Lyrics, top.LyricsYRC)
	retry := !round.complete()
	var targets []int
	created := map[string]bool{}
	for _, l := range shareEvalPlan(keys, snap, own, round.Scored, top, features().LyricsAutoUpgrade) {
		i := index[l.key]
		switch {
		case l.action == "留":
			out.kept++
			retry = retry || l.why == songKeepUndecidable
			continue
		case snap[i].Instrumental:
			continue
		}
		made, err := stageSongSharePre(keys[i], snap[i], fp, now)
		if err != nil {
			slog.Error("song entities: back up before sharing lyrics", "key", keys[i], "err", err)
			retry = true
			continue
		}
		if made {
			created[keys[i]] = true
		}
		targets = append(targets, i)
		if snap[i].Lyrics == "" {
			out.filled++
		} else {
			out.changed++
		}
	}
	var roma string
	var d *lyricsDecision
	if len(targets) > 0 {
		if top.LyricsRoma == "" {
			roma = generatedRomaFor(top.Lyrics, "", entrySongLanguage(top.Lyrics, round.Scored))
		}
		d = buildLyricsDecision(lyricsDecisionPathSongEntityShare, round.Artist, round.Title, round.Album, round.Duration, round.Scored, top, true)
		d.SourcesSkipped, d.statsSkips, d.QueriesTried = round.skipped, round.statsSkips, round.queries
		traceLyricsDecision(round.Key, d)
	}
	// 组里钉着、手改或采纳的写法进不了这一轮(shareEvalGroups),开搜之后才钉住的、组里现在有手改或采纳的(开搜之前就改了的
	// 快照里也带着,光比快照跟现在比不出来)整轮作废。
	pins := lyricsPinnedKeys()
	enrichMu.Lock()
	for i, k := range keys {
		e, ok := enrichCache[k]
		if !ok || pins[k] || enrichEditedSinceLocked(k, stamp) || e.Song != snap[i].Song || e.SongShare != snap[i].SongShare ||
			e.Instrumental != snap[i].Instrumental || e.ManualLyrics != snap[i].ManualLyrics || e.ManualPickSHA != snap[i].ManualPickSHA ||
			e.ManualLyrics || songSharePickHeld(e) ||
			songOffsetFingerprint(e.Lyrics, e.LyricsYRC) != songOffsetFingerprint(snap[i].Lyrics, snap[i].LyricsYRC) {
			enrichMu.Unlock()
			removeStagedSongSharePres(created, nil)
			return songShareGroupOutcome{}
		}
	}
	changed := make([]string, 0, len(targets))
	applied := map[string]bool{}
	for _, i := range targets {
		k := keys[i]
		if !songShareAutoWriteAllowedLocked(k, now) {
			continue
		}
		e := enrichCache[k]
		if !created[k] {
			if _, err := writeSongSharePre(k, e, fp, now); err != nil {
				slog.Error("song entities: back up before sharing lyrics", "key", k, "err", err)
				retry = true
				continue
			}
		}
		applied[k] = true
		dd := *d
		if k != round.Key {
			dd.ReusedFrom = round.Key
		}
		songShareApplyChoice(&e, top, &round, roma, &dd)
		if k == round.Key {
			// 搜的就是这一条的名字:这一轮也是它最近一次评估,两槽同一份(同自动重评换词那一支)。见 18 章决策 71。
			e.LyricsDecision = e.LyricsDecisionApplied
		}
		enrichCache[k] = e
		translateAfterLyricsSwapLocked(k)
		changed = append(changed, k)
	}
	if len(changed) > 0 {
		markEnrichEditedLocked(false, changed...)
		enrichDirty = true
	}
	var retryAt time.Time
	if retry {
		retryAt = now.Add(songShareRetryIncomplete)
	}
	out.state = songShareGroupStateLocked(keys, now, retryAt)
	enrichMu.Unlock()
	// 翻转保险挡下、没换成的:这一轮新建的留底删掉,不留一份 synced 对着没写进去的歌词的。
	removeStagedSongSharePres(created, applied)
	if len(changed) > 0 {
		flushShareChanges(changed)
		slog.Info("song entities: shared group lyrics", "searched", round.Key, "winner", top.Source, "score", top.Score,
			"changed", out.changed, "filled", out.filled, "kept", out.kept)
	}
	return out
}

// shareGroup:搜一个共享组并按结果改。组里有写法正在被别的任务处理时这一轮跳过;搜的这段时间把整组占住,播放那一侧的
// 后台任务不会同时改它们。正在播的那首不占:播放那一侧这一刻要给它起设备封面、外围补全、重评这些后台任务,一次只起一路、
// 占着就跳过,这一次播放就全错过了(18 章决策 60)。它在搜的这段时间里歌词要是变了,applyShareRound 按指纹核对、整轮作废。
// own 是整轮开头按建表那一刻算的;判去留用开搜这一刻的(shareOwnAt)。
func (b *songEntityBuild) shareGroup(ctx context.Context, ms []int, own []*songPlanLyrics) songShareGroupOutcome {
	keys := make([]string, len(ms))
	for i, m := range ms {
		keys[i] = b.variants[m].key
	}
	rep, dur := b.shareEvalRep(ms, own)
	v := &b.variants[rep]
	pins, content := lyricsPinSnapshot()
	enrichMu.Lock()
	if slices.ContainsFunc(keys, func(k string) bool { return enrichInflight[k] }) {
		enrichMu.Unlock()
		return songShareGroupOutcome{}
	}
	snap := make([]enrichEntry, len(keys))
	for i, k := range keys {
		e, ok := enrichCache[k]
		// 建表之后(own 是那一刻的)才成了手改、采纳或钉住的:这一组不按重搜改,这一轮跳过,下一次建表走手改、校准那两步。
		if !ok || e.ManualLyrics || songSharePickHeld(e) || pins[k] {
			enrichMu.Unlock()
			return songShareGroupOutcome{}
		}
		snap[i] = e
	}
	calibrated := songShareCalibrationsLocked(pins, content)
	playing := ""
	if p := enrichPlayingKey.Load(); p != nil {
		playing = *p
	}
	held := make([]string, 0, len(keys))
	for _, k := range keys {
		if k != playing {
			enrichInflight[k] = true
			held = append(held, k)
		}
	}
	stamp := enrichEditStampLocked()
	enrichMu.Unlock()
	defer func() {
		enrichMu.Lock()
		for _, k := range held {
			delete(enrichInflight, k)
		}
		enrichMu.Unlock()
	}()
	groupOwn := b.shareOwnAt(ms, own, keys, snap, calibrated)
	round := searchShareRound(withBackgroundOutbound(ctx), v.key, v.artist, v.title, v.album, dur)
	switch {
	case ctx.Err() != nil:
		return songShareGroupOutcome{}
	case !round.reached:
		return songShareGroupOutcome{offline: true}
	}
	return applyShareRound(keys, groupOwn, snap, stamp, round, time.Now())
}

// shareOwnAt:开搜那一刻组里各写法的那份歌词(shareEvalPlan 判去留看它),跟 keys、snap 逐条对齐。歌词跟建表时一样的沿用 own
// 那一份,变过的按 snap 重算;读穿的校准再按这一刻的(calibrated)补上。
func (b *songEntityBuild) shareOwnAt(ms []int, own []*songPlanLyrics, keys []string, snap []enrichEntry, calibrated songShareCalibrations) []*songPlanLyrics {
	out := make([]*songPlanLyrics, len(ms))
	for i, m := range ms {
		e := snap[i]
		fp := songOffsetFingerprint(e.Lyrics, e.LyricsYRC)
		var l *songPlanLyrics
		switch {
		case fp == "":
			continue
		case own[m] != nil && own[m].fp == fp:
			c := *own[m]
			l = &c
		default:
			l = songPlanLyricsFor(keys[i], e.Lyrics, e.LyricsYRC, e.LyricsSource, e.ManualLyrics || songSharePickHeld(e), false,
				e.LyricsDecisionApplied, b.decisionsDir)
		}
		if !l.pinned {
			l.inherits = l.inherits || calibrated.holds(e)
		}
		out[i] = l
	}
	return out
}

// songShareTally:一轮同步的计数,记日志用。
type songShareTally struct {
	manualEntities, manualChanged, manualConflicts   int
	strays                                           int
	pinnedChanged, pinnedKept, pinnedConflicts       int
	groups, searched, unchanged, noWinner, abandoned int
	changed, filled, kept                            int
	stopped                                          bool
}

// runSongEntitySharePass:建完表、开关开着时跑一轮(见文件头)。先同步手改(不联网),再逐组重搜;ctx 取消、开关中途关掉、
// 拆开或恢复合并请了马上重建(songShareRebuildPending)、连着几组一个歌词源都连不上时停在两组之间,没轮到的下一轮再搜。
func runSongEntitySharePass(ctx context.Context, b *songEntityBuild) {
	start := time.Now()
	statePath := songShareStatePath()
	st := readSongShareState(statePath)
	if st.FullBackup == "" {
		dir, err := songShareFullBackup(start)
		if err != nil {
			slog.Error("song entities: full backup before sharing lyrics failed, not sharing", "err", err)
			return
		}
		st.FullBackup = dir
		if err := writeSongShareState(statePath, st); err != nil {
			slog.Error("song entities: write share state", "err", err)
			return
		}
		slog.Info("song entities: backed up before sharing lyrics", "dir", dir)
	}
	var t songShareTally
	pins, content := lyricsPinSnapshot()
	b.shareManualPass(pins, start, &t)
	enrichMu.Lock()
	picked := songPlanPicked(enrichCache)
	enrichMu.Unlock()
	own := make([]*songPlanLyrics, len(b.variants))
	for _, ms := range b.clusters {
		if len(ms) < 2 {
			continue
		}
		for _, m := range ms {
			own[m] = b.songPlanLyricsOf(m, picked)
		}
	}
	enrichMu.Lock()
	calibrated := songShareCalibrationsLocked(pins, content)
	for m, l := range own {
		if l != nil && !l.pinned {
			l.inherits = calibrated[enrichCache[b.variants[m].key].Song][l.fp]
		}
	}
	enrichMu.Unlock()
	b.sharePinnedPass(own, pins, content, start, &t)
	groups := b.shareEvalGroups(own)
	t.groups = len(groups)
	live := map[string]bool{}
	pace := lyricsFillSweepPace(true)
	offline := 0
	var wait time.Duration
	for i := 0; i < len(groups); {
		if wait > 0 {
			songShareWait(ctx, wait)
		}
		if ctx.Err() != nil || !songEntitySharing() {
			t.stopped = true
			break
		}
		if songShareRebuildPending() {
			slog.Info("song entities: a rebuild was requested, pausing the share pass", "groups_left", len(groups)-i)
			t.stopped = true
			break
		}
		keys := make([]string, len(groups[i]))
		for j, m := range groups[i] {
			keys[j] = b.variants[m].key
		}
		sig := songShareGroupSig(keys)
		live[sig] = true
		if !st.due(sig, songShareFingerprints(keys), time.Now()) {
			t.unchanged++
			i++
			continue
		}
		out := b.shareGroup(ctx, groups[i], own)
		if ctx.Err() != nil {
			t.stopped = true
			break
		}
		t.searched++
		if out.offline {
			if offline++; offline >= lyricsFillSweepOfflineLimit {
				slog.Warn("song entities: no lyric source reachable, stopping this pass", "attempts", offline, "group", keys[0])
				t.stopped = true
				break
			}
			wait = lyricsFillSweepOfflineWait
			continue
		}
		offline = 0
		switch {
		case out.state == nil:
			t.abandoned++
			delete(st.Groups, sig)
		default:
			st.Groups[sig] = *out.state
		}
		if out.noWinner {
			t.noWinner++
		}
		t.changed, t.filled, t.kept = t.changed+out.changed, t.filled+out.filled, t.kept+out.kept
		if t.searched%20 == 0 {
			if err := writeSongShareState(statePath, st); err != nil {
				slog.Error("song entities: write share state", "err", err)
			}
		}
		wait = pace
		i++
	}
	// 只建了一块(增量重算)时别的组都不在 live 里,不清;全量建表之后那一轮再清。
	if !t.stopped && !b.partial {
		for sig := range st.Groups {
			if !live[sig] {
				delete(st.Groups, sig)
			}
		}
	}
	if err := writeSongShareState(statePath, st); err != nil {
		slog.Error("song entities: write share state", "err", err)
	}
	if b.partial && t == (songShareTally{groups: t.groups, unchanged: t.unchanged}) {
		return
	}
	slog.Info("song entities: share pass", "manual_entities", t.manualEntities, "manual_changed", t.manualChanged, "strays_released", t.strays,
		"manual_conflicts", t.manualConflicts, "pinned_changed", t.pinnedChanged, "pinned_kept", t.pinnedKept,
		"pinned_conflicts", t.pinnedConflicts, "groups", t.groups, "searched", t.searched, "unchanged", t.unchanged,
		"no_winner", t.noWinner, "abandoned", t.abandoned, "changed", t.changed, "filled", t.filled, "kept", t.kept,
		"stopped", t.stopped, "took", time.Since(start).Round(time.Second))
}

// songShareFlapLimit / songShareFlapWindow:同步这一层的自动改写(建表之后那一轮的手改同步与恢复、跟着校准、按组重搜、
// 跟上重新匹配)在 songShareFlapWindow 里改同一条写法到了 songShareFlapLimit 次,就当它在来回翻:这个进程里不再自动改它,
// 记一行警告。正常的同步一条写法一个小时里改不了几次;来回翻是证据跟着同步结果变的那类缺陷(18 章决策 59),
// 不拦的话每次落盘后的增量重算都会再翻一次。用户自己的保存、统一两份手改、拆开、关开关恢复不算、也不挡。
const (
	songShareFlapLimit  = 6
	songShareFlapWindow = time.Hour
)

// songShareFlaps / songShareFlapStopped:每条写法最近的自动改写时刻、已经停手的写法。持 enrichMu 读写。
var (
	songShareFlaps       = map[string][]time.Time{}
	songShareFlapStopped = map[string]bool{}
)

// songShareAutoWriteAllowedLocked:同步这一层这一刻还能不能自动改 key;能就记下这一次。调用方持 enrichMu。
func songShareAutoWriteAllowedLocked(key string, now time.Time) bool {
	if songShareFlapStopped[key] {
		return false
	}
	recent := songShareFlaps[key][:0]
	for _, at := range songShareFlaps[key] {
		if now.Sub(at) < songShareFlapWindow {
			recent = append(recent, at)
		}
	}
	if len(recent) >= songShareFlapLimit {
		songShareFlapStopped[key] = true
		delete(songShareFlaps, key)
		slog.Warn("song entities: a version keeps being rewritten by sharing, leaving it alone for this run",
			"key", key, "writes", len(recent), "window", songShareFlapWindow)
		return false
	}
	songShareFlaps[key] = append(recent, now)
	return true
}

// songShareFingerprints:keys 这几条写法现在的歌词指纹。
func songShareFingerprints(keys []string) map[string]string {
	out := make(map[string]string, len(keys))
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, k := range keys {
		e := enrichCache[k]
		out[k] = songOffsetFingerprint(e.Lyrics, e.LyricsYRC)
	}
	return out
}

// shareManualPass:每个共享组过一遍 shareManualLocked,再把跟的那条已经不在这一组的自动同步副本按留底恢复
// (releaseStrayAutoCopiesLocked),改了的当场落盘、导出。只有一条写法的组只在它是副本时过(原件或跟的那条分到了别的组或
// 别的实体,要按留底恢复)。
func (b *songEntityBuild) shareManualPass(pins map[string]bool, now time.Time, t *songShareTally) {
	var all []string
	for _, ms := range b.shareGroupsOf() {
		keys := make([]string, len(ms))
		for i, m := range ms {
			keys[i] = b.variants[m].key
		}
		enrichMu.Lock()
		if one := enrichCache[keys[0]]; len(keys) == 1 && one.LyricsEntityOrigin == "" && songShareAutoCopyOf(one) == "" {
			enrichMu.Unlock()
			continue
		}
		changed, conflict := shareManualLocked(keys, "", pins, now)
		strays := releaseStrayAutoCopiesLocked(keys, now)
		if len(changed)+len(strays) > 0 {
			markEnrichEditedLocked(false, append(slices.Clone(changed), strays...)...)
			enrichDirty = true
		}
		enrichMu.Unlock()
		if conflict {
			t.manualConflicts++
		}
		if len(changed) > 0 {
			t.manualEntities++
			t.manualChanged += len(changed)
			all = append(all, changed...)
		}
		t.strays += len(strays)
		all = append(all, strays...)
	}
	flushShareChanges(all)
}

// shareGroupsOf:全部共享组(各写法下标,组内按下标、组按实体顺序和组根排),含只有一条写法的。
func (b *songEntityBuild) shareGroupsOf() [][]int {
	var out [][]int
	for _, members := range b.clusters {
		groups := map[int][]int{}
		for _, m := range members {
			groups[b.shareOf[m]] = append(groups[b.shareOf[m]], m)
		}
		roots := make([]int, 0, len(groups))
		for r := range groups {
			roots = append(roots, r)
		}
		sort.Ints(roots)
		for _, r := range roots {
			out = append(out, groups[r])
		}
	}
	return out
}

// flushShareChanges:同步改了的写法逐条落盘、导出歌词文件、推给 App。
func flushShareChanges(keys []string) {
	if len(keys) == 0 {
		return
	}
	for _, k := range keys {
		requestEnrichSaveFor(k)
	}
	exportLyricsFilesFor(keys...)
	nudgeEnrichPush()
}

// sharePinnedPass:组里没有手改时,共享组里钉着的写法、App 记下的校准正对着它现在这份歌词的(content,见
// lyricsPinsFile.Content),组里其余写法跟着用这一份,读穿那个偏移;组里两份不同的这种校准不替用户选。own 是建表那一刻
// 各写法的歌词。改了的当场落盘、导出。
func (b *songEntityBuild) sharePinnedPass(own []*songPlanLyrics, pins map[string]bool, content map[string]string, now time.Time, t *songShareTally) {
	var all []string
	for _, members := range b.clusters {
		if len(members) < 2 {
			continue
		}
		groups := map[int][]int{}
		for _, m := range members {
			groups[b.shareOf[m]] = append(groups[b.shareOf[m]], m)
		}
		for r, ms := range groups {
			if slices.ContainsFunc(ms, func(m int) bool { return own[m] != nil && own[m].manual }) {
				delete(groups, r)
			}
		}
		roots := make([]int, 0, len(groups))
		for r := range groups {
			roots = append(roots, r)
		}
		sort.Ints(roots)
		for _, r := range roots {
			changed, kept, conflict := b.sharePinnedGroup(groups[r], own, pins, content, now)
			if conflict {
				t.pinnedConflicts++
			}
			t.pinnedChanged, t.pinnedKept = t.pinnedChanged+len(changed), t.pinnedKept+kept
			all = append(all, changed...)
		}
	}
	flushShareChanges(all)
}

// sharePinnedGroup:一个共享组按 sharePinnedPass 改,返回改了的写法、按不变式 6 前四条留着自己那份的条数(songPlanKeep);
// conflict:组里两份不同的校准。对方自己钉着的、标了纯音乐的、手改的不动;建表之后歌词变过的写法这一轮不动。
func (b *songEntityBuild) sharePinnedGroup(ms []int, own []*songPlanLyrics, pins map[string]bool, content map[string]string,
	now time.Time) (changed []string, kept int, conflict bool) {
	if len(ms) < 2 {
		return nil, 0, false
	}
	var to *songPlanLyrics
	origin := ""
	for _, m := range ms {
		k, l := b.variants[m].key, own[m]
		if !pins[k] || l == nil || content[k] != l.fp {
			continue
		}
		if to != nil && to.fp != l.fp {
			return nil, 0, true
		}
		if origin == "" || k < origin {
			origin, to = k, l
		}
	}
	if to == nil {
		return nil, 0, false
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	src, ok := enrichCache[origin]
	if !ok || src.ManualLyrics || songSharePickHeld(src) || songOffsetFingerprint(src.Lyrics, src.LyricsYRC) != to.fp {
		return nil, 0, false
	}
	upgrade := features().LyricsAutoUpgrade
	for _, m := range ms {
		k, cur := b.variants[m].key, own[m]
		e, ok := enrichCache[k]
		if !ok || k == origin || pins[k] || e.Instrumental || e.ManualLyrics || songSharePickHeld(e) {
			continue
		}
		fp := songOffsetFingerprint(e.Lyrics, e.LyricsYRC)
		if fp == to.fp || (cur == nil) != (fp == "") || (cur != nil && cur.fp != fp) {
			continue
		}
		// 关着「随匹配算法更新重新选择」时已经有词的不换,只补没词的(18 章决策 59)。
		if cur != nil && (!upgrade || songPlanKeep(cur, to, false) != "") {
			kept++
			continue
		}
		if !songShareAutoWriteAllowedLocked(k, now) {
			continue
		}
		if _, err := writeSongSharePre(k, e, to.fp, now); err != nil {
			slog.Error("song entities: back up before following a calibration", "key", k, "err", err)
			continue
		}
		songShareCopyPinned(&e, src, origin, now)
		enrichCache[k] = e
		changed = append(changed, k)
	}
	if len(changed) > 0 {
		markEnrichEditedLocked(false, changed...)
		enrichDirty = true
		slog.Info("song entities: followed a calibration", "from", origin, "to", len(changed))
	}
	return changed, kept, false
}

// songShareCalibrations:歌词同步开着时,每首歌(实体 id)里钉着的写法的校准对着哪几份歌词(lyricsPinsFile.Content)。同一首
// 歌里歌词正是其中一份的写法在读穿那个偏移(App 的 LyricsOffsetStore 按实体读穿),换了词就读不到了。
type songShareCalibrations map[string]map[string]bool

// songShareCalibrationsLocked:pins、content 是 lyricsPinSnapshot。调用方持 enrichMu。
func songShareCalibrationsLocked(pins map[string]bool, content map[string]string) songShareCalibrations {
	if len(content) == 0 || !songEntitySharing() {
		return nil
	}
	out := songShareCalibrations{}
	for k := range pins {
		e, ok := enrichCache[k]
		if !ok || e.Song == "" || content[k] == "" {
			continue
		}
		if out[e.Song] == nil {
			out[e.Song] = map[string]bool{}
		}
		out[e.Song][content[k]] = true
	}
	return out
}

// holds:e 现在这份歌词是同一首歌里一份校准对着的。
func (c songShareCalibrations) holds(e enrichEntry) bool {
	fps := c[e.Song]
	return fps != nil && fps[songOffsetFingerprint(e.Lyrics, e.LyricsYRC)]
}

// lyricsCalibratedLocked:key 这条写法换了词会丢掉一份校准:自己钉着,或者在读穿同一首歌的一份(songShareCalibrations)。
// 后台自动换词的各道闸认它。调用方持 enrichMu。
func lyricsCalibratedLocked(key string) bool {
	pins, content := lyricsPinSnapshot()
	return pins[key] || songShareCalibrationsLocked(pins, content).holds(enrichCache[key])
}

// songShareFullBackup:第一次同步之前把主缓存和正文小文件目录整份克隆一份(APFS 上 cp -c 几乎不占空间),返回目录。
func songShareFullBackup(now time.Time) (string, error) {
	dst := songShareBackupDir(now)
	if dst == "" {
		return "", errors.New("no config directory")
	}
	if err := saveEnrichCacheChecked(); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dst, 0o700); err != nil {
		return "", err
	}
	enrichMu.Lock()
	cache := enrichPath
	enrichMu.Unlock()
	for _, src := range []string{cache, enrichBodiesDir()} {
		if src == "" {
			continue
		}
		if _, err := os.Stat(src); errors.Is(err, os.ErrNotExist) {
			continue
		}
		if out, err := exec.Command("/bin/cp", "-c", "-R", src, dst).CombinedOutput(); err != nil {
			return "", fmt.Errorf("cp %s: %v: %s", src, err, strings.TrimSpace(string(out)))
		}
	}
	return dst, nil
}

// revertSongEntityShare:开关关着时把同步动过的写法恢复成第一次同步之前的样子:歌词还是同步写进去那份的按留底恢复;之后
// 被用户或别的路径改过的留着现在的,只去掉副本标记。存盘成功后删掉留底和组的记录;没有留底也没有组的记录时什么都不做。
func revertSongEntityShare() {
	dir, statePath := songSharePreDir(), songShareStatePath()
	names, _ := os.ReadDir(dir)
	_, stateErr := os.Stat(statePath)
	if len(names) == 0 && stateErr != nil {
		return
	}
	// 留底在锁外读、解好(带正文,几千条时解码要一阵),持锁只比指纹、改字段。
	type decodedPre struct {
		key, synced string
		entry       enrichEntry
	}
	var pres []decodedPre
	var files []string
	for _, n := range names {
		if n.IsDir() || !strings.HasSuffix(n.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, n.Name())
		files = append(files, path)
		p, err := readSongSharePre(path)
		if err != nil {
			noteFileErr("read", path, err)
			continue
		}
		d := decodedPre{key: p.Key, synced: p.Synced}
		if err := json.Unmarshal(p.Entry, &d.entry); err != nil {
			continue
		}
		pres = append(pres, d)
	}
	var restored, released []string
	enrichMu.Lock()
	for _, p := range pres {
		e, ok := enrichCache[p.key]
		if !ok || p.synced != songOffsetFingerprint(e.Lyrics, e.LyricsYRC) {
			continue
		}
		songShareRestore(&e, p.entry)
		enrichCache[p.key] = e
		restored = append(restored, p.key)
	}
	for k, e := range enrichCache {
		if e.LyricsEntityOrigin != "" {
			e.LyricsEntityOrigin = ""
			enrichCache[k] = e
			released = append(released, k)
		}
	}
	touched := append(slices.Clone(restored), released...)
	if len(touched) > 0 {
		markEnrichEditedLocked(false, touched...)
		enrichDirty = true
	}
	enrichMu.Unlock()
	// 上一次恢复到一半存盘失败时,这一次 touched 为空、内存里却还有没落盘的恢复:不管改没改都先存盘,存成了才删留底。
	if err := saveEnrichCacheChecked(); err != nil {
		slog.Error("song entities: save after reverting shared lyrics, keeping backups", "err", err)
		return
	}
	if len(touched) > 0 {
		exportLyricsFilesFor(restored...)
		nudgeEnrichPush()
	}
	for _, f := range files {
		noteFileErr("remove", f, os.Remove(f))
	}
	if stateErr == nil {
		noteFileErr("remove", statePath, os.Remove(statePath))
	}
	slog.Info("song entities: switched off, reverted shared lyrics", "restored", len(restored),
		"kept", len(pres)-len(restored), "released", len(released))
}

// removeIfExists:删掉 path,本来就没有不算错。
func removeIfExists(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
