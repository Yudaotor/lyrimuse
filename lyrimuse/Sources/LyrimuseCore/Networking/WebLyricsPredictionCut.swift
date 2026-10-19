import Foundation

/// 副屏提前画押错的那一下(见 19 章决策 28):在播时画的是「此刻 + 提前量」,暂停或跳转时,之前画出来、还排在网页里没放的帧
/// 画的是没发生的往下放。App 发现暂停、跳转时通知网页 `{"type":"cut","from":画帧时刻毫秒,"t":画帧时刻毫秒}`,网页把画帧时刻
/// 落在 (from, t] 里的帧丢掉不放(视频照解不放,后面的帧要参照它们),画面停在那一刻真实的位置,接着放暂停 / 跳转之后画的帧。
/// 见 19 章决策 31。
public enum WebLyricsPredictionCut {
    /// 位置比按上一次外推的偏出去这么多以上算跳转;锚点平时的小幅校正在这以内。
    public static let seekToleranceMs = 250
    /// 起点再往前多留这么多:App 估的暂停位置跟播放器真停下的差一两百毫秒,宁可早停一点(之后往前补上一小段),
    /// 别押过头(之后往回退,看得出来)。
    public static let marginMs = 200.0
    /// 终点往后多留这么多:主线程把新状态交出去之后,出帧线程还要几帧才画得出来(本机实测约 70ms),这几帧照旧押着。
    public static let settleMs = 100.0
    /// 提前量不到这么多不丢:押过头也就这么一点看不出,丢帧却要停「提前量 + 余量」那么久,得不偿失。
    public static let minLeadMs = 300
    /// 跳到一首歌开头这么多以内不算跳转:开播时播放器会连着校正几次回到 0 附近,自动换下一首也落在这里,开头多半是前奏,
    /// 押过头看不出,每次都丢就是开头几秒一卡一卡。
    public static let trackStartMs = 3000

    /// 上一次提交时的播放位置和这一刻的比,押错了的话返回要丢的画帧时刻区间(毫秒)。`leadMs` 是到这一刻为止画帧用的提前量。
    ///
    /// 窗口起点别取「发现的时刻 − 提前量」:App 知道暂停比播放器真停下晚一截(本机约 0.3 秒),这一截里画的帧照样押过了头。
    /// 暂停时按「照原样放该到哪」减「实际停在哪」把起点再往前挪这么多;跳转发生在两次提交之间,起点取上一次提交的时刻。
    public static func window(leadMs: Int, previous: (positionMs: Int, at: TimeInterval, playing: Bool)?,
                              positionMs: Int, now: TimeInterval, playing: Bool, rate: Double) -> (from: Double, to: Double)? {
        guard leadMs >= minLeadMs, let previous, previous.playing else { return nil }
        let r = rate > 0 ? rate : 1
        let expected = previous.positionMs + Int((now - previous.at) * 1000 * r)
        let to = now * 1000
        guard playing else {
            let late = Double(max(0, expected - positionMs)) / r
            return (to - Double(leadMs) - late - marginMs, to)
        }
        guard abs(positionMs - expected) > seekToleranceMs, positionMs >= trackStartMs else { return nil }
        return (previous.at * 1000 - Double(leadMs) - marginMs, to)
    }

    public static func message(_ window: (from: Double, to: Double)) -> String {
        "{\"type\":\"cut\",\"from\":\(window.from),\"t\":\(window.to)}"
    }
}
