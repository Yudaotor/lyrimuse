import CoreAudio
import Foundation

/// 某个 App 此刻有没有在往输出设备送音频。问的是 CoreAudio 的进程对象,不起子进程,几微秒。
///
/// 判的是音频 IO 开没开:本机在出声时为真,暂停后还会开一阵才关;遥控别的设备(Spotify Connect)时为假。
/// 同一个 bundle id 有几个进程对象时,任一个在输出就算。读不到(没有这个进程对象、调用失败)一律当没在输出。
public enum ProcessAudioOutput {
    public static func isRunningOutput(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return processObjects().contains { object in
            stringProperty(object, kAudioProcessPropertyBundleID) == bundleID
                && (uint32Property(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
        }
    }

    /// 默认输出设备此刻在不在转(有没有哪个 App 在往它送声音)。蓝牙耳机闲着时为假,开始出声前那一刻才转起来。读不到时 nil。
    /// 有的设备出着声也一直报没在转(实测 AirPods Max),要信它的地方自己判(见 `LocalPlaybackSource.outputFlagBroken`)。
    public static func defaultOutputDeviceIsRunning() -> Bool? {
        defaultOutputDeviceState()?.running
    }

    /// 默认输出设备的设备号和此刻在不在转,见 defaultOutputDeviceIsRunning。读不到时 nil。
    public static func defaultOutputDeviceState() -> (device: UInt32, running: Bool)? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0, let running = uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return nil }
        return (device, running != 0)
    }

    /// 一个 App 此刻的出声状态,诊断用。判据同 `isRunningOutput`,另外分出读不到的两种。
    public enum OutputState: Equatable, Sendable {
        case outputting
        /// 有进程对象(开过音频),此刻没在输出。
        case silent
        /// 进程对象里没有它:没开过音频,或进程不在。
        case noAudioObject
        /// 读不到进程对象表(系统不支持或调用失败)。
        case unavailable
    }

    /// 进程对象表里每个对象的 bundle id 和在不在输出;读不到表为 nil。
    public static func processOutputTable() -> [(bundleID: String, outputting: Bool)]? {
        processObjectList()?.compactMap { object in
            stringProperty(object, kAudioProcessPropertyBundleID).map {
                ($0, (uint32Property(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
            }
        }
    }

    /// 这几个 bundle id(同一个播放器的各版本)合起来的出声状态:任一个在输出就是在出声。
    public static func outputState(bundleIDs: [String]) -> OutputState {
        outputState(bundleIDs: bundleIDs, table: processOutputTable())
    }

    /// 同上,进程对象表由调用方给。纯函数,selftest 覆盖。
    public static func outputState(bundleIDs: [String], table: [(bundleID: String, outputting: Bool)]?) -> OutputState {
        guard let table else { return .unavailable }
        let rows = table.filter { bundleIDs.contains($0.bundleID) }
        if rows.contains(where: \.outputting) { return .outputting }
        return rows.isEmpty ? .noAudioObject : .silent
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        processObjectList() ?? []
    }

    /// 读不到进程对象表(系统不支持、调用失败)为 nil;表是空的为空数组。
    private static func processObjectList() -> [AudioObjectID]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// 这个属性交回的 CFString 归调用方释放。
    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
