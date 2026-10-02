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

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
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
