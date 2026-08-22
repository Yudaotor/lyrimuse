import CoreAudio
import Foundation

/// 音频输出设备的枚举/切换(2026-08-21,歌词窗口音量胶囊左侧的 AirPlay/输出键,对照
/// AM 的同位按钮)。全部走公开 CoreAudio HAL API,不需要额外权限(SoundSource 一类
/// 输出切换工具同款做法)。切的是**系统默认输出设备** —— AM 那颗键的语义也是选播放
/// 目标,AirPlay 扬声器在 HAL 里同样以输出设备形式出现,能被这里枚举/选中。
enum AudioOutputDeviceManager {
    /// 设备类型(transportType 映射),UI 侧据此挑图标——AM 的输出面板每行左侧就是
    /// 设备类型图标。
    enum Kind {
        case builtIn, airPlay, bluetooth, display, other
    }

    struct Device {
        let id: AudioDeviceID
        let name: String
        let kind: Kind
    }

    private static func kind(forTransport transport: UInt32) -> Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return .display
        default: return .other
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 所有有输出流的设备(含 AirPlay/蓝牙/内建扬声器),聚合设备等无名者被名字守卫滤掉。
    static func outputDevices() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = deviceName(id), !name.isEmpty else { return nil }
            return Device(id: id, name: name, kind: kind(forTransport: transportType(id)))
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    /// 当前默认输出是不是**非内建**设备(蓝牙耳机/AirPlay/显示器…)——AM 把键染红的
    /// 条件实测是这个,不只 AirPlay:用户输出到蓝牙 AirPods 时 AM 的键也是红的
    /// (2026-08-21 截图对照订正,第一版只判 AirPlay 结果"没有变红")。
    static func isExternalOutputActive() -> Bool {
        guard let id = defaultOutputDeviceID() else { return false }
        return kind(forTransport: transportType(id)) != .builtIn
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue()
        else { return nil }
        return cf as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
