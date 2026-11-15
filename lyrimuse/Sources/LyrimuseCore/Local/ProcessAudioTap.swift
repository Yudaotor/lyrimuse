import CoreAudio
import Foundation
import os

/// 读某个播放器此刻送出的声音(Core Audio 进程级 tap,macOS 14.2+):单声道 mixdown 的私有 tap 挂在一个私有聚合设备上,
/// IO 回调只把最近 `RealAudioSpectrum.fftSize` 个采样留在内存里的环形缓冲,给音浪算频段能量。
/// 不录制、不写盘;源 App 照常出声(`muteBehavior = .unmuted`)。见 05 章决策 146。
///
/// 第一次建 tap 并开始读时系统弹「录屏与系统录音 → 仅系统录音」授权(Info.plist 要有 `NSAudioCaptureUsageDescription`)。
/// 没给授权时回调照来、采样全是 0。被 tap 的进程不出声时回调不来。
@available(macOS 14.2, *)
public final class ProcessAudioTap: @unchecked Sendable {
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "audio-tap")

    public let sampleRate: Double
    /// 被 tap 的进程对象;全局 tap 是空数组。
    public let processObjects: [AudioObjectID]
    private let ring: SampleRing
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var stopped = false

    /// 读 `processObjects` 这几个进程的声音;`processObjects` 为空时读全部进程(只在开开关时触发授权用)。
    /// 任一步失败返回 nil(已清理干净、记过日志)。
    public init?(processObjects: [AudioObjectID], label: String) {
        self.processObjects = processObjects
        let desc = processObjects.isEmpty
            ? CATapDescription(monoGlobalTapButExcludeProcesses: [])
            : CATapDescription(monoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = "Lyrimuse \(label)"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            Self.logger.warning("audio-tap: create tap failed status=\(err, privacy: .public)")
            return nil
        }
        tapID = tap
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = Self.address(kAudioTapPropertyFormat)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format)
        guard err == noErr, format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            Self.logger.warning("audio-tap: unexpected tap format status=\(err, privacy: .public) rate=\(format.mSampleRate, privacy: .public) bits=\(format.mBitsPerChannel, privacy: .public)")
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let ring = SampleRing(capacity: RealAudioSpectrum.fftSize)

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            Self.logger.warning("audio-tap: no default output device")
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyrimuse \(label)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr, agg != kAudioObjectUnknown else {
            Self.logger.warning("audio-tap: create aggregate device failed status=\(err, privacy: .public)")
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, Self.ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            ring.write(data.assumingMemoryBound(to: Float.self), frames: frames, stride: channels)
        }
        guard err == noErr, let proc else {
            Self.logger.warning("audio-tap: create io proc failed status=\(err, privacy: .public)")
            AudioHardwareDestroyAggregateDevice(agg)
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else {
            Self.logger.warning("audio-tap: start failed status=\(err, privacy: .public)")
            AudioDeviceDestroyIOProcID(agg, proc)
            AudioHardwareDestroyAggregateDevice(agg)
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        // 这两样放到最后才赋值:前面任一步失败时对象还没初始化完,不会走 deinit 把已经拆掉的东西再拆一遍。
        sampleRate = format.mSampleRate
        self.ring = ring
        Self.logger.info("audio-tap: started label=\(label, privacy: .public) processes=\(processObjects.count, privacy: .public) rate=\(format.mSampleRate, privacy: .public)")
    }

    deinit { stop() }

    /// 停掉并拆掉聚合设备和 tap。可以重复调用。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        Self.logger.info("audio-tap: stopped processes=\(self.processObjects.count, privacy: .public)")
    }

    /// 最近 `fftSize` 个采样(时间顺序)和自开始以来的回调计数。
    public func snapshot() -> SampleRing.Snapshot { ring.snapshot() }

    private static let ioQueue = DispatchQueue(label: "lyrimuse.audio-tap.io", qos: .userInitiated)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDeviceUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// IO 回调写、分析队列读的环形缓冲。只存最近 `capacity` 个采样,另记回调次数和其中有声的次数。
public final class SampleRing: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var samples: [Float]
        public var callbacks: Int
        public var heardCallbacks: Int
    }

    private let capacity: Int
    private var buffer: [Float]
    private var writeIndex = 0
    private var callbacks = 0
    private var heardCallbacks = 0
    private var lock = os_unfair_lock()

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        buffer = [Float](repeating: 0, count: max(1, capacity))
    }

    /// 写入 `frames` 帧,每帧取第一个声道(`stride` = 声道数)。
    public func write(_ data: UnsafePointer<Float>, frames: Int, stride: Int) {
        guard frames > 0 else { return }
        let step = max(1, stride)
        os_unfair_lock_lock(&lock)
        var heard = false
        for i in 0..<frames {
            let s = data[i * step]
            if s != 0 { heard = true }
            buffer[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
        }
        callbacks += 1
        if heard { heardCallbacks += 1 }
        os_unfair_lock_unlock(&lock)
    }

    public func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let ordered = Array(buffer[writeIndex...] + buffer[..<writeIndex])
        return Snapshot(samples: ordered, callbacks: callbacks, heardCallbacks: heardCallbacks)
    }
}

extension ProcessAudioOutput {
    /// 播放器 `bundleID` 的声音从哪几个进程对象出来(`table` 是进程对象表的 bundle id 列,下标对应进程对象):
    /// 本体、它的辅助进程(bundle id 以「本体.」开头,如 `com.spotify.client.helper`),以及把声音放在
    /// 媒体代理进程里的(Safari → `com.apple.WebKit.GPU`,表见 `TrustedPlayers.mediaProxyOwners`)。
    /// 本机没有这个播放器的进程对象(iPhone 桥接、模拟播放)返回空。纯函数,selftest 覆盖。
    public static func tapTargetIndices(bundleID: String, table: [String]) -> [Int] {
        guard !bundleID.isEmpty else { return [] }
        let proxies = TrustedPlayers.mediaProxyOwners.filter { $0.value == bundleID }.map(\.key)
        let helperPrefix = bundleID + "."
        return table.indices.filter { i in
            let id = table[i]
            return id == bundleID || id.hasPrefix(helperPrefix) || proxies.contains(id)
        }
    }

    /// 同上,直接查此刻的进程对象表,返回进程对象号。
    public static func tapTargets(bundleID: String) -> [AudioObjectID] {
        guard let objects = processObjectListForTap() else { return [] }
        let ids = objects.map { tapStringProperty($0, kAudioProcessPropertyBundleID) ?? "" }
        return tapTargetIndices(bundleID: bundleID, table: ids).map { objects[$0] }
    }

    /// 默认输出设备从收到声音到出声大约晚多少秒(设备延迟 + 安全偏移 + 缓冲,按设备采样率折算)。读不到时 0。
    /// 蓝牙耳机常见一两百毫秒,内建扬声器几十毫秒。
    public static func defaultOutputLatencySeconds() -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return 0 }
        func frames(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &rateSize, &rate) == noErr, rate > 0 else { return 0 }
        let total = frames(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + frames(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
            + frames(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        return outputLatencySeconds(frames: total, sampleRate: rate)
    }

    /// 帧数 → 秒,夹在 0…0.5 秒。纯函数,selftest 覆盖。
    public static func outputLatencySeconds(frames: UInt32, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return min(0.5, max(0, Double(frames) / sampleRate))
    }

    private static func processObjectListForTap() -> [AudioObjectID]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// 这个属性交回的 CFString 归调用方释放。
    private static func tapStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
