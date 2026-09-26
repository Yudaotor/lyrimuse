package main

import (
	"log"
	"sync"
	"time"
)

// 电台(Apple Music Radio / 直播流)的**曲内**播放时钟。Swift 侧同款实现见
// LyrimuseCore/Local/RadioTrackClock.swift —— 两边判据、上限、语义必须一致,改一边就要改另一边。
//
// 实测事实(用户在放 Apple Music 电台时连续采样 30 次):
//   - `duration` 报的是**整档节目**(3390.122s = 56 分半),不是当前这首歌;
//   - `elapsedTime` / `player position` 同样是整档节目的位置,**换歌不复位** —— 锚点 07:15:35 归零,
//     07:20:39 换到 Clairo《Juna》,07:23:22 读到 467s,正好等于 07:23:22 − 07:15:35;
//     而《Juna》此刻真实的曲内位置是 163s,偏了 304 秒。
//
// 这种台系统这一层没有任何单曲级别的位置可取,唯一能标出曲目边界的就是"元数据换了"这一刻,所以自己起表:
// key 一变就归零,之后只在播放中按墙钟累加。也有报单曲位置的台,那种台换歌时用系统位置起表,见 radioPerTrackSeed。判据用载荷里的 `radioStationHash` 非空 —— 一个确定的
// 字段,不靠"歌手为空""时长特别长"这类启发式。
//
// 未验证项:元数据切换是不是跟声音严格同步。苹果若提前几秒推下一首,这块表会整体超前那几秒;
// 那要用耳朵核。真出现固定偏移就在这里补一个常量。

// radioMaxAdvancePerTick:单次推进上限。正常轮询 5s;超过说明中间休眠 / 长时间卡顿,
// 这时墙钟差不再等于"播了多久",宁可少算也不要凭空跳一大截。
const radioMaxAdvancePerTick = 30 * time.Second

// radioClockState 是这块表的全部状态。纯函数 advanceRadioClock 只读写它的值,不碰包级变量,
// 好让单测直接覆盖。
type radioClockState struct {
	trackKey string
	position float64
	tickedAt time.Time
	// playing:**上一拍**在不在播。决定这一拍要不要把 [上一拍, 现在] 这段算成播放时间,见 advanceRadioClock。
	playing bool
	// perTrack:这首起表时判成了「系统报单曲位置」(见 radioPerTrackSeed)。为真时这首余下的时间都以系统位置为准,
	// applyRadioClock 不再顶替快照,poller 照常问 Music.app 要精确播放头(见 radioWallClock)。
	perTrack bool
}

// advanceRadioClock 推进一拍并返回新状态。纯函数。
//   - 换歌(key 变了)或第一次见 → 重新起表,位置 = seed(调用方按 radioPerTrackSeed 判出来的,平常是 0);
//   - 否则按**上一拍**的播放状态决定要不要累加 [上一拍, 现在] 这段(单拍夹在 [0, radioMaxAdvancePerTick])。
//
// 判据是**上一拍**在不在播,不是这一拍(修一个真实回归)。按"这一拍在播"累加的话,
// 「上一拍暂停、这一拍恢复」会把整段暂停间隔当成播放时间加进去,停得越久跳得越多(App 侧暂停时轮询降到 6s、
// 空闲 10s;collector 是 5s)。现象是「暂停久一点再恢复,歌词进度就不正常」,App 日志里的 resume transition
// 逐条坐实跳了 3.5~5.8 秒。反过来「上一拍在播、这一拍暂停」照旧累加:那一段确实基本都在播。
// Swift 侧 RadioTrackClock.advance 必须同规则,改一边就要改另一边。
func advanceRadioClock(prev radioClockState, key string, playing bool, now time.Time, seed float64) radioClockState {
	if prev.trackKey != key || prev.tickedAt.IsZero() {
		return radioClockState{trackKey: key, position: seed, tickedAt: now, playing: playing}
	}
	if !prev.playing {
		return radioClockState{trackKey: key, position: prev.position, tickedAt: now, playing: playing}
	}
	step := now.Sub(prev.tickedAt)
	if step < 0 {
		step = 0
	}
	if step > radioMaxAdvancePerTick {
		step = radioMaxAdvancePerTick
	}
	return radioClockState{trackKey: key, position: prev.position + step.Seconds(), tickedAt: now, playing: playing}
}

// 报单曲位置的电台的判据常量,与 Swift 侧 RadioTrackClock.perTrackAnchorMaxAge / perTrackSeedMax /
// perTrackResetMargin 同值,两边一起改。
const (
	radioPerTrackAnchorMaxAge = 5 * time.Second
	radioPerTrackSeedMax      = 60.0
	radioPerTrackResetMargin  = 20.0
	// radioPerTrackMaxDuration:系统报的时长不超过这个值算「单曲量级」(整档节目口径的台报的是整档节目长度)。
	radioPerTrackMaxDuration = 900.0
	// radioPerTrackDecisionWindow:起表后多久之内还可以补判成单曲位置(「交叉渐入渐出」换歌时系统先推新标题、
	// 进度还是上一首的,约半秒后才推新歌自己的进度)。比较对象固定是换歌前上一首最后的系统位置。
	radioPerTrackDecisionWindow = 10 * time.Second
)

// radioPerTrackSeed:有的电台系统报的是**单曲**位置(换歌归零、每拍都对),「歌曲过渡」开着时新歌还会
// 跳过前奏、从十几秒处切进来。这种台换歌时直接用系统位置起表,否则从 0 起的表会整首慢一段前奏的长度。
// 判成之后这首余下的时间也都以系统位置为准(radioClockState.perTrack):起播缓冲时 Apple Music 会连报几次 0,
// 最后一个才是真起点,只在起表那一拍取一次会整首快几秒。
// 纯函数;Swift 侧 RadioTrackClock.perTrackSeed 同一套判据,两边一起改。
//
// 前两条必须成立、后两条至少成立一条才返回 (systemPos, true):读数来自换歌时新打的锚点(anchorAge 在
// [0, radioPerTrackAnchorMaxAge]);systemPos 在 [0, radioPerTrackSeedMax];相对上一首最后的系统位置归零了
// (hasPrevious 且 previous − systemPos ≥ radioPerTrackResetMargin);系统报的时长是单曲量级(reportedDuration 在
// (0, radioPerTrackMaxDuration]),开台第一首、重启后的第一首没有上一首的读数,靠这一条判。
func radioPerTrackSeed(systemPos float64, anchorAge time.Duration, previous float64, hasPrevious bool, reportedDuration float64) (float64, bool) {
	if anchorAge < 0 || anchorAge > radioPerTrackAnchorMaxAge || systemPos < 0 || systemPos > radioPerTrackSeedMax {
		return 0, false
	}
	reset := hasPrevious && previous-systemPos >= radioPerTrackResetMargin
	trackScale := reportedDuration > 0 && reportedDuration <= radioPerTrackMaxDuration
	if !reset && !trackScale {
		return 0, false
	}
	return systemPos, true
}

var (
	radioClockMu    sync.Mutex
	radioClockValue radioClockState
	// 上一拍电台快照里系统报的位置(按曲目 key 记),换歌那一拍拿它判「系统位置归零了没有」。
	radioLastSystemKey string
	radioLastSystemPos float64
	// 这首起表时记下的「上一首最后的系统位置」与起表时刻,补判单曲位置(radioPerTrackDecisionWindow 内)用。
	radioStartPrevPos   float64
	radioStartHasPrev   bool
	radioStartStartedAt time.Time
)

// applyRadioClock 把电台快照里那两个"整档节目"的值换成单曲口径:位置换成自己这块表,
// 锚点跟着一起换(留着原值会让下游"这是不是开播锚点"的判定按整档节目的钟去解读,自相矛盾)。
// 不是电台就原样不动。时长在 extract() 里就已经按"未知"处理了,见那边注释。
func applyRadioClock(s *snapshot, now time.Time) {
	if s == nil || !s.Radio {
		return
	}
	key := s.key()
	live := s.Elapsed
	if s.Playing && !s.McTS.IsZero() {
		live += now.Sub(s.McTS).Seconds()
	}
	radioClockMu.Lock()
	seed, seeded := 0.0, false
	starting := radioClockValue.trackKey != key
	if starting {
		radioStartHasPrev = radioLastSystemKey != "" && radioLastSystemKey != key
		radioStartPrevPos, radioStartStartedAt = radioLastSystemPos, now
	}
	deciding := starting || (!radioClockValue.perTrack && now.Sub(radioStartStartedAt) <= radioPerTrackDecisionWindow)
	if deciding && s.Playing {
		// 这里的系统位置是本拍现读的(media-control 的 elapsedTimeNow 或 AppleScript player position),锚点年龄按 0。
		if v, ok := radioPerTrackSeed(live, 0, radioStartPrevPos, radioStartHasPrev, s.ReportedDuration); ok {
			seed, seeded = v, true
			log.Printf("radio clock: per-track seed key=%q seed=%.3f prev=%.3f starting=%v", key, v, radioStartPrevPos, starting)
		}
	}
	radioLastSystemKey, radioLastSystemPos = key, live
	if !starting && seeded {
		radioClockValue = radioClockState{trackKey: key, position: live, tickedAt: now, playing: s.Playing, perTrack: true}
		radioClockMu.Unlock()
		return
	}
	if radioClockValue.trackKey == key && radioClockValue.perTrack {
		// 报单曲位置的台:快照保留系统原值,表只跟着记账。
		radioClockValue = radioClockState{trackKey: key, position: live, tickedAt: now, playing: s.Playing, perTrack: true}
		radioClockMu.Unlock()
		return
	}
	next := advanceRadioClock(radioClockValue, key, s.Playing, now, seed)
	if seeded {
		next.perTrack = true
	}
	perTrack := next.perTrack
	radioClockValue = next
	radioClockMu.Unlock()
	if perTrack {
		return
	}
	s.Elapsed, s.AnchorElapsed, s.McTS = next.position, next.position, now
}

// radioWallClock:这一拍的电台快照是不是还走自己起的墙钟表(整档节目口径的台)。报单曲位置的那首歌
// 返回 false,poller 据此照常向 Music.app 借精确播放头(borrowAppleScriptPosition 的 radio 参数)。
func radioWallClock(s snapshot) bool {
	if !s.Radio {
		return false
	}
	radioClockMu.Lock()
	defer radioClockMu.Unlock()
	return !(radioClockValue.trackKey == s.key() && radioClockValue.perTrack)
}
