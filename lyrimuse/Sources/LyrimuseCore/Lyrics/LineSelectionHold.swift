/// 选「显示哪一句」用的位置,碰到小幅往回纠正时停在原来那一刻,等实际位置追上来。
///
/// 播放位置会被往回小拉:开播时播放器的钟起步晚、伺服把外推往回校。拉回去的那一点要是跨过了一句的起点,
/// 刚亮出来的那句会被收回、过一会儿又出现(前奏的「•••」跟第一句来回切)。往回不超过 `maxHoldMs` 时这一拍
/// 选句用的位置照旧停在上一拍那里;往回更多(拖进度)或往前走,照实际位置。播放位置本身不改,逐字填色照实际
/// 位置走;切歌、重载歌词、App 自己发起的跳转、暂停时由调用方清掉 `held`。见 08 章决策 48。
public enum LineSelectionHold {
    public static let maxHoldMs = 800

    /// 这一拍选句用的位置。`held` 是上一拍选句用的位置,没有为 nil。
    public static func position(raw: Int, held: Int?, maxHoldMs: Int = maxHoldMs) -> Int {
        guard let held, raw < held, held - raw <= maxHoldMs else { return raw }
        return held
    }
}
