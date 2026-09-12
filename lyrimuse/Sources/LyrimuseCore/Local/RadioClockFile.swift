import Foundation
import os

/// 电台曲内表的落盘副本(2026-09-11,用户拍板「都做」)。
///
/// 起因:那块表(`RadioTrackClock`)只活在进程内存里,App 一重启就从 0 起。2026-09-10 当晚
/// 两次装机(23:29 别的会话、23:44 我)都坐实了:后一次《Step Up》其实已经播了 12.6 秒,新进程
/// 从 0.284 秒起表,整首歌的歌词都对不上。电台**没有任何单曲级位置可查**(系统报的
/// duration/elapsedTime 都是整档节目的,见 RadioTrackClock 头注),重启之后除了这份自己记的账,
/// 再没有第二个地方能问"这首放到哪了"。
///
/// # 恢复判据(三条都要成立)
///
///  1. **曲目 key 一致** —— 换了歌,上一首的位置一点参考价值都没有;
///  2. **记录不老于 `maxRestoreGap`** —— App 关了半小时再开,就算 key 碰巧一样,那也多半是
///     另一次播放;宁可从 0 起,也不要接一个错的位置(错的位置比没有位置更难看:歌词会稳定地
///     停在错的地方,用户以为是功能坏了);
///  3. **落盘那一刻在播** —— 停着的时候关的 App,中间过了多久都不该算成播放时间。
///
/// 三条都过就把它当"上一拍"喂给 `RadioTrackClock.advance`,追上的量由那边既有的
/// `maxAdvancePerTick` 夹住(宁可少算),这里不另开一套算法。
///
/// # 只有 App 写这份文件
///
/// collector 那边有一块同样的表(`radioclock.go`),但**不共用这个文件** —— 两个进程各写各的会
/// 互相覆盖,而 collector 的位置只喂状态中继(网页/预览)那条路,重启后从 0 起的代价远小于
/// 引入一个跨进程写冲突。真要给 collector 也接上,得先定谁是唯一写方。
public struct RadioClockRecord: Codable, Equatable, Sendable {
    public var trackKey: String
    public var position: Double
    public var tickedAtMs: Int64
    public var playing: Bool

    enum CodingKeys: String, CodingKey {
        case trackKey = "track_key"
        case position
        case tickedAtMs = "ticked_at_ms"
        case playing
    }

    public init(trackKey: String, position: Double, tickedAtMs: Int64, playing: Bool) {
        self.trackKey = trackKey
        self.position = position
        self.tickedAtMs = tickedAtMs
        self.playing = playing
    }
}

public enum RadioClockFile {
    public static let fileName = "lyrimuse-radio-clock.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "radio-clock")

    /// 记录再老就不敢接了。给它比一次装机(实测 build.sh 从停到起 ~8 秒)宽裕得多的余量,
    /// 又远小于这个台的换歌间隔(实测 230~310 秒),免得跨了一首歌还在接。
    public static let maxRestoreGap: TimeInterval = 60

    /// 两次落盘之间至少隔这么久 —— 位置每 2 秒推进一拍,每拍都写盘纯属浪费。换歌 / 播放状态
    /// 翻转时无条件写(见 shouldWrite),所以这个间隔只影响"同一首歌播放中"那条最平凡的路径。
    public static let minWriteInterval: TimeInterval = 15

    /// 纯函数,selftest 直接覆盖:键按字母序、不带缩进,输出稳定可比。
    public static func encode(_ record: RadioClockRecord) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(record)
    }

    public static func decode(_ data: Data) -> RadioClockRecord? {
        try? JSONDecoder().decode(RadioClockRecord.self, from: data)
    }

    /// 这份记录能不能当"上一拍"接回去。纯函数,selftest 直接覆盖 —— 三条判据见类型头注。
    public static func restorable(_ record: RadioClockRecord?, trackKey: String, now: Date) -> RadioTrackClock.State? {
        guard let record, record.trackKey == trackKey, record.playing else { return nil }
        let tickedAt = Date(timeIntervalSince1970: Double(record.tickedAtMs) / 1000)
        let gap = now.timeIntervalSince(tickedAt)
        guard gap >= 0, gap <= maxRestoreGap else { return nil }
        return RadioTrackClock.State(trackKey: record.trackKey, position: record.position,
                                     tickedAt: tickedAt, playing: true)
    }

    /// 要不要现在写盘。纯函数,selftest 直接覆盖。
    ///
    /// 换歌和播放状态翻转必须立刻写:这两件事一旦漏写,文件里留着的就是一份"曲目对不上"或者
    /// "以为还在播"的记录 —— 前者恢复时被判据 1 挡掉(只是白丢一次),后者会让下次恢复把停着的
    /// 那段算成播放时间(判据 3 就是防它,但前提是暂停这件事真的写进去了)。
    public static func shouldWrite(previous: RadioClockRecord?, next: RadioClockRecord, now: Date) -> Bool {
        guard let previous else { return true }
        if previous.trackKey != next.trackKey || previous.playing != next.playing { return true }
        let since = now.timeIntervalSince(Date(timeIntervalSince1970: Double(previous.tickedAtMs) / 1000))
        return since >= minWriteInterval || since < 0
    }

    public static func load() -> RadioClockRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// 原子写(临时文件 + rename)。失败只记日志 —— 这是"重启后能接上"的锦上添花,
    /// 绝不能反过来影响正在播的这一拍。
    public static func write(_ record: RadioClockRecord) {
        do {
            try encode(record).write(to: url, options: .atomic)
        } catch {
            logger.notice("radio clock file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
