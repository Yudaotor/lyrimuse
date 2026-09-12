import CoreAudio
import Foundation

/// 系统默认音频输出设备的身份与传输类型,外加"默认输出换了"的监听(2026-09-09)。
///
/// 给 `LocalPlaybackSource` 的 Spotify 探针领先量用:那个领先量(AppleScript `player position` 比
/// 出声位置领先多少)是**输出链路**的属性 —— 内建约 0.1s、蓝牙约 0.55s —— 所以按设备分别记、
/// 按设备取,切换输出时立刻换成那台设备学过的值(没学过就用按传输类型给的先验),不能等用户再
/// 暂停一次才慢慢收敛。全部走公开 CoreAudio HAL API,不需要权限;App 侧 `AudioOutputDeviceManager`
/// (歌词窗口的输出切换键)是同一套 API 的另一份用法,那边在 UI 层、这边在 Core 层,刻意不合并:
/// 这里只要"身份 + 类型 + 变化通知"三样。
public enum AudioOutputRoute {
    public enum Transport: String, Sendable {
        case builtIn, bluetooth, airPlay, display, usb, other
    }

    public struct Current: Equatable, Sendable {
        /// `kAudioDevicePropertyDeviceUID`:同一台设备稳定不变(蓝牙设备是按地址生成的),换机器不同。
        public let uid: String
        public let name: String
        public let transport: Transport
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func transport(forType type: UInt32) -> Transport {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return .display
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// 此刻的默认输出设备;拿不到(没有输出设备 / HAL 出错)返回 nil。
    public static func current() -> Current? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        var typeAddr = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var typeSize = UInt32(MemoryLayout<UInt32>.size)
        let transport: Transport = AudioObjectGetPropertyData(id, &typeAddr, 0, nil, &typeSize, &type) == noErr
            ? Self.transport(forType: type) : .other
        guard let uid = string(kAudioDevicePropertyDeviceUID, of: id), !uid.isEmpty else { return nil }
        return Current(uid: uid, name: string(kAudioObjectPropertyName, of: id) ?? "", transport: transport)
    }

    /// 默认输出设备变化时回调(在主队列上)。只装一次;重复调用忽略。
    private static var listening = false
    public static func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        guard !listening else { return }
        listening = true
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
            onChange()
        }
    }
}
