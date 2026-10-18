import Foundation

/// 副屏的 H.264 视频流:网页能硬解(`VideoDecoder`)时连接带 `codec=avc`,App 推视频帧,不推逐帧 JPEG。画面大部分时间
/// 几乎不变,视频只发跟上一帧的差别:同样 1512×900@2x、60 帧,JPEG 每秒 16MB,H.264 4Mbps 时每秒 0.33MB,画质
/// SSIM 0.996。见 19 章决策 25。
///
/// 每条二进制消息:1 字节类型 + 8 字节画帧时刻(毫秒,大端 Float64,网页按它匀速放)+ 数据。解码配置是 avcC
/// (`decoderConfiguration`),帧是 AVCC(每个 NAL 前 4 字节长度),都是 VideoToolbox 原样给的形状。
public enum WebLyricsVideo {
    public enum Message: UInt8, Sendable {
        /// avcC,每个关键帧之前跟一份,网页按它(重新)配解码器。
        case config = 1
        case keyFrame = 2
        case deltaFrame = 3
    }

    /// 连接查询串里请求视频流的那一项。
    public static let queryKey = "codec"
    public static let queryValue = "avc"

    public static func wantsVideo(_ query: [String: String]) -> Bool {
        query[queryKey] == queryValue
    }

    /// 一条消息的内容(还没包成 WebSocket 帧)。
    public static func message(_ type: Message, stamp: Double, payload: Data) -> Data {
        var data = Data(capacity: 9 + payload.count)
        data.append(type.rawValue)
        var bits = stamp.bitPattern.bigEndian
        data.append(Data(bytes: &bits, count: 8))
        data.append(payload)
        return data
    }

    /// 由 SPS、PPS(不带起始码)拼 avcC(ISO/IEC 14496-15 的 AVCDecoderConfigurationRecord),4 字节长度前缀。
    /// High 及以上档次按标准补色度格式和位深那几个字节(4:2:0、8 位)。SPS 短于 4 字节时 nil。
    public static func decoderConfiguration(sps: Data, pps: Data) -> Data? {
        let s = [UInt8](sps), p = [UInt8](pps)
        guard s.count >= 4, !p.isEmpty, s.count <= 0xFFFF, p.count <= 0xFFFF else { return nil }
        var out: [UInt8] = [1, s[1], s[2], s[3], 0xFF, 0xE1]
        out += [UInt8(s.count >> 8), UInt8(s.count & 0xFF)] + s
        out += [1, UInt8(p.count >> 8), UInt8(p.count & 0xFF)] + p
        if [100, 110, 122, 144].contains(s[1]) {
            out += [0xFC | 1, 0xF8, 0xF8, 0]
        }
        return Data(out)
    }

    /// WebCodecs 的 codec 字符串(`avc1.PPCCLL`:档次、约束标志、级别,取自 avcC 第 2～4 字节)。
    public static func codecString(decoderConfiguration avcC: Data) -> String? {
        let b = [UInt8](avcC)
        guard b.count >= 4, b[0] == 1 else { return nil }
        return String(format: "avc1.%02X%02X%02X", b[1], b[2], b[3])
    }

    /// 视频帧要不要发给这个网页。从关键帧起才解得开,所以刚连上、或者掉过一帧(上一帧还没发完、这一帧发不出去)的网页
    /// 要等下一个关键帧,其间的帧都不发,同时请编码器尽快出一个关键帧。逐帧 JPEG 每帧都当关键帧,行为不变。
    public struct Delivery: Equatable, Sendable {
        public let send: Bool
        public let needsKeyFrame: Bool
        public let wantsKeyFrame: Bool

        public init(send: Bool, needsKeyFrame: Bool, wantsKeyFrame: Bool) {
            self.send = send
            self.needsKeyFrame = needsKeyFrame
            self.wantsKeyFrame = wantsKeyFrame
        }
    }

    public static func deliver(isKeyFrame: Bool, needsKeyFrame: Bool, previousStillSending: Bool) -> Delivery {
        if previousStillSending {
            // 丢了哪一帧(关键帧也是后面那些帧的参照)后面的帧都解不开,等下一个关键帧
            return Delivery(send: false, needsKeyFrame: true, wantsKeyFrame: true)
        }
        if needsKeyFrame && !isKeyFrame {
            return Delivery(send: false, needsKeyFrame: true, wantsKeyFrame: true)
        }
        return Delivery(send: true, needsKeyFrame: false, wantsKeyFrame: false)
    }
}
