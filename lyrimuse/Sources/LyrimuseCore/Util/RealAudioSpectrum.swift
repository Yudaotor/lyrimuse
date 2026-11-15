import Accelerate
import Foundation

/// 灵动岛音浪「跟随音乐跳动」的频谱数学:一段单声道采样 → 5 个对数频段的能量 → 每根条子 0…1 的高度。
/// 采样从哪来见 `ProcessAudioTap`,这里只有纯计算,selftest 用合成正弦钉住。见 05 章决策 146。
///
/// 只读能量,不留采样:分析完的那段采样不出这个函数,也不写盘。
public enum RealAudioSpectrum {
    /// FFT 点数。48 kHz 下窗长 42.7ms、频率分辨率 23.4Hz,最低一段(50～159Hz)也有 4～5 个频点。
    public static let fftSize = 2048
    public static let bandCount = 5
    /// 频段覆盖的范围,按对数等分成 `bandCount` 段(相邻两条边界之比约 3.17)。
    public static let lowestHz: Double = 50
    public static let highestHz: Double = 16000

    /// 第 i 根条子显示第几个频段:低频放中间、往两边依次升高,五根条子才有「中间鼓起」的轮廓;
    /// 按低到高从左往右排的话,大多数歌最左那根常年顶满、最右那根常年贴底。
    public static let barBand: [Int] = [3, 1, 0, 2, 4]

    /// 跟随音乐时条子的地板(满量程的比例)。静音时条子仍是一根短棍而不是一个点,
    /// 跟 `EqualizerBarCurve.floorLevel` 同一个道理,只是这里要让安静段明显矮下去,取得低一些。
    public static let liveFloorLevel: Double = 0.15

    /// 频段边界(Hz),共 `count + 1` 个,首尾是 `low` / `high`。
    public static func bandEdges(count: Int = bandCount, low: Double = lowestHz, high: Double = highestHz) -> [Double] {
        guard count > 0, low > 0, high > low else { return [] }
        let ratio = log(high / low) / Double(count)
        return (0...count).map { low * exp(ratio * Double($0)) }
    }

    /// 0…1 的频段电平 → 条子的高度比例(抬上地板)。
    public static func barLevel(_ level: Double) -> Double {
        let v = level.isFinite ? min(1, max(0, level)) : 0
        return liveFloorLevel + (1 - liveFloorLevel) * v
    }

    /// 2048 点 Hann 窗 FFT → 各频段的平均功率(线性值;只在同一个分析器内部互相比较,不是校准过的声压)。
    /// 不是线程安全的,一个分析器只在一条队列上用。
    public final class Analyzer {
        public let sampleRate: Double
        private let log2n: vDSP_Length
        private let setup: FFTSetup
        private var window: [Float]
        private var windowed: [Float]
        private var real: [Float]
        private var imag: [Float]
        private var magnitudes: [Float]
        /// 每个频段的 [起始频点, 结束频点](含),落不到任何频点的段是空区间。
        public let bandBins: [ClosedRange<Int>?]

        public init?(sampleRate: Double) {
            guard sampleRate.isFinite, sampleRate > 0 else { return nil }
            let n = RealAudioSpectrum.fftSize
            let log2n = vDSP_Length(log2(Double(n)))
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
            self.sampleRate = sampleRate
            self.log2n = log2n
            self.setup = setup
            window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            windowed = [Float](repeating: 0, count: n)
            real = [Float](repeating: 0, count: n / 2)
            imag = [Float](repeating: 0, count: n / 2)
            magnitudes = [Float](repeating: 0, count: n / 2)
            let binHz = sampleRate / Double(n)
            let edges = RealAudioSpectrum.bandEdges()
            bandBins = (0..<RealAudioSpectrum.bandCount).map { b in
                let lo = max(1, Int((edges[b] / binHz).rounded(.up)))
                let hi = min(n / 2 - 1, Int((edges[b + 1] / binHz).rounded(.down)))
                return hi >= lo ? lo...hi : nil
            }
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// `samples` 是时间顺序的最近 `fftSize` 个采样(多了取最后那些,少了前面补零)。
        public func bandPowers(_ samples: [Float]) -> [Double] {
            let n = RealAudioSpectrum.fftSize
            let tail = samples.count > n ? Array(samples.suffix(n)) : samples
            let pad = n - tail.count
            for i in 0..<n { windowed[i] = i < pad ? 0 : tail[i - pad] }
            for i in 0..<n where !windowed[i].isFinite { windowed[i] = 0 }
            vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
                }
            }
            let scale = Double(n) * Double(n)
            return bandBins.map { range in
                guard let range else { return 0 }
                var sum: Double = 0
                for k in range { sum += Double(magnitudes[k]) }
                return sum / Double(range.count) / scale
            }
        }
    }
}

/// 频段能量 → 条子电平 0…1:每个频段一个自适应上限(读到更响的立刻抬上去、之后慢慢往下放),
/// 电平是「这一刻比上限低多少分贝」在 `dynamicRangeDB` 里的位置;再做快升慢落的平滑。
///
/// 上限各段各管各的:低频的绝对能量比高频大几十分贝,共用一个上限的话高频那几根永远贴底。
/// tap 的单声道 mixdown 峰值会超过 1(左右声道相加),所以不能按满刻度 0 dBFS 归一。
public struct RealAudioBandFollower: Equatable, Sendable {
    /// 上限往下数多少分贝算 0:离上限 6dB 是半高。别放宽:压得很响的流行 / 电子歌各段一直贴着上限几分贝以内,
    /// 范围一宽五根条子就一直顶在上半截、看不出跟着拍子起落。取值和真机回放判据见 05 章决策 146。
    public static let dynamicRangeDB: Double = 12
    /// 上限每秒往下放多少分贝:一段响的过去之后,安静段大约十秒内重新跳得起来。
    public static let ceilingDecayDBPerSecond: Double = 3
    /// 上限最低放到这里,不再往下追:不然只剩底噪时底噪也会被放大成满格。
    public static let minimumCeilingDB: Double = -45
    /// 低于这个能量按静音算,电平直接是 0。
    public static let silenceDB: Double = -90
    /// 上升、回落的时间常数(秒)。快升慢落:鼓点那一下立刻顶上去,之后约 0.2 秒落回。
    public static let attackSeconds: Double = 0.025
    public static let releaseSeconds: Double = 0.2

    public private(set) var ceilingsDB: [Double]
    public private(set) var levels: [Double]

    public init(bandCount: Int = RealAudioSpectrum.bandCount) {
        ceilingsDB = Array(repeating: Self.minimumCeilingDB, count: max(0, bandCount))
        levels = Array(repeating: 0, count: max(0, bandCount))
    }

    /// 喂一帧各频段功率(线性值),返回平滑后的电平。`dt` 是距上一帧的秒数。
    @discardableResult
    public mutating func update(powers: [Double], dt: Double) -> [Double] {
        let step = dt.isFinite ? min(1, max(0, dt)) : 0
        for b in levels.indices {
            let p = b < powers.count && powers[b].isFinite ? max(0, powers[b]) : 0
            let db = p > 0 ? 10 * log10(p) : -.infinity
            let decayed = ceilingsDB[b] - Self.ceilingDecayDBPerSecond * step
            ceilingsDB[b] = max(Self.minimumCeilingDB, decayed, db.isFinite ? db : -.infinity)
            let target = Self.level(db: db, ceilingDB: ceilingsDB[b])
            let tau = target > levels[b] ? Self.attackSeconds : Self.releaseSeconds
            let k = step > 0 ? 1 - exp(-step / tau) : 0
            levels[b] += (target - levels[b]) * k
        }
        return levels
    }

    /// 一个频段此刻的能量(dB)在上限下面的位置 → 0…1,不含平滑。
    public static func level(db: Double, ceilingDB: Double) -> Double {
        guard db.isFinite, ceilingDB.isFinite, db >= silenceDB else { return 0 }
        return min(1, max(0, (db - (ceilingDB - dynamicRangeDB)) / dynamicRangeDB))
    }

    /// 换播放器、重建 tap 时从头来:上限按新声源重新学。
    public mutating func reset() {
        self = RealAudioBandFollower(bandCount: levels.count)
    }
}

/// 把条子电平按输出设备延迟往后推:tap 拿到的是送往输出设备之前的声音,
/// 蓝牙耳机要再过一两百毫秒才进耳朵,画面得等同样久才跟听到的对上。
public struct RealAudioDelayLine: Sendable {
    /// 最多攒这么多帧(30 帧/秒下够 1 秒的延迟)。
    public static let capacity = 40
    private var entries: [(time: Double, levels: [Double])] = []

    public init() {}

    public var count: Int { entries.count }

    public mutating func push(time: Double, levels: [Double]) {
        entries.append((time, levels))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// `now` 时该画的那一帧:采集时刻 + `delay` 已到的帧里最新的一帧;没有到点的返回 nil。
    /// 用掉的帧连同更早的一起丢掉。
    public mutating func pop(now: Double, delay: Double) -> [Double]? {
        let due = now - max(0, delay.isFinite ? delay : 0)
        guard let idx = entries.lastIndex(where: { $0.time <= due }) else { return nil }
        let levels = entries[idx].levels
        entries.removeFirst(idx + 1)
        return levels
    }

    public mutating func removeAll() { entries.removeAll() }
}

/// 什么时候用真实音频驱动音浪、什么时候退回按歌词时间轴的音浪(`EqualizerBarCurve`)。
///
/// 读到过一次有声的采样,说明授权在、tap 通;此后只要回调还在来就跟随(真安静的段落条子贴地板,
/// 是如实的)。回调停了(播放器不在本机出声:iPhone 桥接、遥控别的设备)就退回。
/// 从没读到过声音、而播放器明明在出声满 `deniedAfter` 秒,多半是没给授权,设置页据此提示。
public struct RealAudioLevelGate: Equatable, Sendable {
    /// 回调停了这么久就退回。
    public static let staleAfter: Double = 0.5
    /// 播放器在出声、tap 却一直只有静音满这么久,判作没拿到授权。
    public static let deniedAfter: Double = 3

    /// 这次运行里读到过有声的采样没有。授权是整机的,换播放器、重建 tap 都不清。
    public private(set) var everHeard = false
    public private(set) var tapStartedAt: Double?
    public private(set) var lastCallbackAt: Double?

    public init() {}

    public mutating func tapStarted(at time: Double) {
        tapStartedAt = time
        lastCallbackAt = nil
    }

    public mutating func tapStopped() {
        tapStartedAt = nil
        lastCallbackAt = nil
    }

    /// 自上次以来有新回调时调用;`heard` = 这批采样里有非零的。
    public mutating func noteCallbacks(at time: Double, heard: Bool) {
        lastCallbackAt = time
        if heard { everHeard = true }
    }

    public func isLive(now: Double) -> Bool {
        guard everHeard, tapStartedAt != nil, let last = lastCallbackAt else { return false }
        return now - last < Self.staleAfter
    }

    public func likelyDenied(now: Double, playerOutputting: Bool) -> Bool {
        guard !everHeard, playerOutputting, let started = tapStartedAt else { return false }
        return now - started >= Self.deniedAfter
    }
}
