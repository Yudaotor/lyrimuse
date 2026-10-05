import Foundation

/// 图层歌词行的时间基准指纹(`OverlayScrollingLyricRow.Spec.timingEpoch`):锚点(拿到的时刻 / 进度 / 速率)、
/// 暂停冻结的位置、歌词时间轴偏移任一变了,值就跟着变,图层行按新基准重装动画,不等它自己的漂移门。
///
/// 悬浮歌词和触控栏共用这一份,别各算各的。灵动岛只看偏移(`NotchPlayback.lyricsOffsetMs`),是另一套口径。
public enum LyricsTimingEpoch {
    public static func of(anchor: ProgressAnchor?, pausedPositionMs: Int?, offsetMs: Int) -> Int {
        var h = Hasher()
        h.combine(anchor?.fetchedAt)
        h.combine(anchor?.progressMs)
        h.combine(anchor?.rate)
        h.combine(pausedPositionMs)
        h.combine(offsetMs)
        return h.finalize()
    }
}
