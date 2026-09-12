package main

import (
	"sync"
	"time"
)

// 电台(Apple Music Radio / 直播流)的**曲内**播放时钟(2026-09-10)。Swift 侧同款实现见
// LyrimuseCore/Local/RadioTrackClock.swift —— 两边判据、上限、语义必须一致,改一边就要改另一边。
//
// 实测事实(2026-09-10,用户在放 Apple Music 电台时连续采样 30 次):
//   - `duration` 报的是**整档节目**(3390.122s = 56 分半),不是当前这首歌;
//   - `elapsedTime` / `player position` 同样是整档节目的位置,**换歌不复位** —— 锚点 07:15:35 归零,
//     07:20:39 换到 Clairo《Juna》,07:23:22 读到 467s,正好等于 07:23:22 − 07:15:35;
//     而《Juna》此刻真实的曲内位置是 163s,偏了 304 秒。
//
// 系统这一层没有任何单曲级别的位置可取,唯一能标出曲目边界的就是"元数据换了"这一刻,所以自己起表:
// key 一变就归零,之后只在播放中按墙钟累加。判据用载荷里的 `radioStationHash` 非空 —— 一个确定的
// 字段,不靠"歌手为空""时长特别长"这类启发式。
//
// ⚠️ 未验证项:元数据切换是不是跟声音严格同步。苹果若提前几秒推下一首,这块表会整体超前那几秒;
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
}

// advanceRadioClock 推进一拍并返回新状态。纯函数。
//   - 换歌(key 变了)或第一次见 → 归零重新起表,位置 0;
//   - 否则按**上一拍**的播放状态决定要不要累加 [上一拍, 现在] 这段(单拍夹在 [0, radioMaxAdvancePerTick])。
//
// ⚠️ 判据是**上一拍**在不在播,不是这一拍(2026-09-10 当天第二轮,修一个真实回归)。按"这一拍在播"累加的话,
// 「上一拍暂停、这一拍恢复」会把整段暂停间隔当成播放时间加进去,停得越久跳得越多(App 侧暂停时轮询降到 6s、
// 空闲 10s;collector 是 5s)。用户报「暂停久一点再恢复,歌词进度就不正常」,App 日志里的 resume transition
// 逐条坐实跳了 3.5~5.8 秒。反过来「上一拍在播、这一拍暂停」照旧累加:那一段确实基本都在播。
// Swift 侧 RadioTrackClock.advance 必须同规则,改一边就要改另一边。
func advanceRadioClock(prev radioClockState, key string, playing bool, now time.Time) radioClockState {
	if prev.trackKey != key || prev.tickedAt.IsZero() {
		return radioClockState{trackKey: key, position: 0, tickedAt: now, playing: playing}
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

var (
	radioClockMu    sync.Mutex
	radioClockValue radioClockState
)

// applyRadioClock 把电台快照里那两个"整档节目"的值换成单曲口径:位置换成自己这块表,
// 锚点跟着一起换(留着原值会让下游"这是不是开播锚点"的判定按整档节目的钟去解读,自相矛盾)。
// 不是电台就原样不动。时长在 extract() 里就已经按"未知"处理了,见那边注释。
func applyRadioClock(s *snapshot, now time.Time) {
	if s == nil || !s.Radio {
		return
	}
	radioClockMu.Lock()
	next := advanceRadioClock(radioClockValue, s.key(), s.Playing, now)
	radioClockValue = next
	radioClockMu.Unlock()
	s.Elapsed, s.AnchorElapsed, s.McTS = next.position, next.position, now
}
