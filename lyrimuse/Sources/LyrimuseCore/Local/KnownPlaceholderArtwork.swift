import CryptoKit
import Foundation

/// 播放器自己推给 MediaRemote 的**内置占位图**登记表。
///
/// 有的播放器换歌后先推一张自带的通用图(实测:酷狗 3.3.2 推一张 35427 字节的蓝底黑胶唱片,
/// 几秒后才换成真封面),而那是一张合法的 600×600 JPEG —— 取图路上的边长/长宽比门槛、
/// 载荷标识核对一道都识破不了它,挂上去就是一张跟这首歌无关的图。
///
/// 判据是**整份字节的 SHA-256**,不是"多首歌共用同一张图"那种猜测:合辑封面本来就共用,
/// 按共用去猜会误伤。表里只放亲手量过指纹的图(同一份字节在三首不同的歌上逐字节相同)。
///
/// 这张表会**过期**:播放器换一版内置图,指纹就对不上。失效是无害的 —— 对不上就当普通
/// 封面处理,退回没有这张表时的行为(占位图挂几秒,靠 `artworkConfirmDelays` 那张间隔表
/// 换掉),不会更糟。命中时留一条 notice 日志,好确认它还在生效。
public enum KnownPlaceholderArtwork {
    /// 一张登记在案的占位图。
    public struct Entry: Sendable {
        public let byteCount: Int
        public let sha256Hex: String
        /// 哪个播放器推的。只作记录,判定不看它 —— 取图那条路上拿不到 bundle id。
        public let player: String

        public init(byteCount: Int, sha256Hex: String, player: String) {
            self.byteCount = byteCount
            self.sha256Hex = sha256Hex
            self.player = player
        }
    }

    public static let entries: [Entry] = [
        Entry(byteCount: 35427,
              sha256Hex: "56301adc2c97955b3af286bb51f109cab83278da94b9bdb101374159fc866996",
              player: "com.kugou.mac.Music"),
    ]

    /// 这份封面字节是不是登记在案的占位图。纯函数,selftest 直接覆盖。
    ///
    /// 先比字节数再算指纹:字节数对不上就不用算 SHA-256,而绝大多数封面都对不上。
    public static func isPlaceholder(_ data: Data) -> Bool {
        let candidates = entries.filter { $0.byteCount == data.count }
        guard !candidates.isEmpty else { return false }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return candidates.contains { $0.sha256Hex == hex }
    }
}
