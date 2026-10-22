import AppKit
import Combine
import CoreAudio
import Foundation
import OSLog

/// 音频输出设备的枚举/切换(歌词窗口音量胶囊左侧的 AirPlay/输出键,对照
/// AM 的同位按钮)。全部走公开 CoreAudio HAL API,不需要额外权限(SoundSource 一类
/// 输出切换工具同款做法)。切的是**系统默认输出设备** —— AM 那颗键的语义也是选播放
/// 目标,AirPlay 扬声器在 HAL 里同样以输出设备形式出现,能被这里枚举/选中。
enum AudioOutputDeviceManager {
    /// 设备类型(transportType 映射),UI 侧据此挑图标——AM 的输出面板每行左侧就是
    /// 设备类型图标。
    enum Kind: Equatable {
        case builtIn, airPlay, bluetooth, display, other
    }

    struct Device: Equatable {
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

    fileprivate static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 能选作系统默认输出的设备(含 AirPlay/蓝牙/内建扬声器):要有输出流、不是隐藏设备、
    /// `DeviceCanBeDefaultDevice` 为真(虚拟声卡里不能当默认输出的那类点了也切不过去),且有名字。
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
            guard hasOutputStreams(id), !isHidden(id), canBeDefaultOutput(id),
                  let name = deviceName(id), !name.isEmpty else { return nil }
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

    /// 这台设备是不是**非内建**设备(蓝牙耳机/AirPlay/显示器…)——键染红的条件是这个,不只 AirPlay:
    /// 输出到蓝牙 AirPods 时 AM 的键也是红的。
    static func isExternal(_ id: AudioDeviceID) -> Bool {
        kind(forTransport: transportType(id)) != .builtIn
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        uint32Property(id, address(kAudioDevicePropertyIsHidden)) ?? 0 != 0
    }

    private static func canBeDefaultOutput(_ id: AudioDeviceID) -> Bool {
        // 读不出来当作可以:这道只拦明确说「不能」的设备。
        uint32Property(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                   scope: kAudioObjectPropertyScopeOutput)) ?? 1 != 0
    }

    private static func uint32Property(_ id: AudioDeviceID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var addr = addr
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
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

/// 输出设备列表与当前默认输出的实时状态,歌词窗口的输出键(染红)与输出面板只读这里。挂 CoreAudio 的属性
/// 监听(默认输出换了 / 设备增减),系统一变就推过来,不轮询 —— 控制中心切换、AirPods 自动接管输出这类
/// App 自己看不见的切换全靠它跟上。监听随单例常驻,没有事件时零开销。
@MainActor
final class AudioOutputMonitor: ObservableObject {
    static let shared = AudioOutputMonitor()
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "audio-output")

    @Published private(set) var devices: [AudioOutputDeviceManager.Device] = []
    @Published private(set) var defaultID: AudioDeviceID?
    /// 默认输出是非内建设备。
    @Published private(set) var isExternal = false

    private init() {
        refresh()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioOutputDeviceManager.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
            if status != noErr {
                Self.logger.error("listener for \(selector, privacy: .public) failed: \(status, privacy: .public)")
            }
        }
    }

    func refresh() {
        let list = AudioOutputDeviceManager.outputDevices()
        let current = AudioOutputDeviceManager.defaultOutputDeviceID()
        if list != devices { devices = list }
        if current != defaultID { defaultID = current }
        let external = current.map(AudioOutputDeviceManager.isExternal) ?? false
        if external != isExternal { isExternal = external }
    }

    /// 把系统默认输出切到这台。失败返回 false(面板据此不关,勾留在原来那台),并记一行日志。
    @discardableResult
    func select(_ id: AudioDeviceID) -> Bool {
        let ok = AudioOutputDeviceManager.setDefaultOutput(id)
        if !ok { Self.logger.error("set default output \(id, privacy: .public) failed") }
        refresh()
        return ok
    }
}

extension AudioOutputDeviceManager.Device {
    /// 设备类型 → 图标(AM 的输出面板每行左侧是设备形状图标)。transportType 先分大类,AirPods 系按名称再细分
    /// (蓝牙传输层区分不出 Max / Pro)。歌词窗口的输出面板、灵动岛的输出菜单和切换横幅共用。
    var symbolName: String {
        let lowered = name.lowercased()
        switch kind {
        case .builtIn: return "laptopcomputer"
        case .airPlay: return "hifispeaker"
        case .display: return "display"
        case .bluetooth:
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            return "headphones"
        case .other: return "speaker.wave.2"
        }
    }
}

/// 灵动岛展开态快捷操作里那颗「输出设备」键弹出的菜单:列出能当系统默认输出的设备,勾着当前那台,点一行切过去
/// (`AudioOutputMonitor.select`)。
///
/// 菜单从卡片下沿弹出:灵动岛窗口在 `.screenSaver` 层,菜单窗口层级比它低,压在卡片上的那部分会被卡片挡住。
@MainActor
enum AudioOutputDeviceMenu {
    static func popUp(belowScreenY y: CGFloat?) {
        let monitor = AudioOutputMonitor.shared
        monitor.refresh()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in monitor.devices {
            let item = NSMenuItem(title: device.name, action: #selector(Target.select(_:)), keyEquivalent: "")
            item.target = Target.shared
            item.representedObject = device.id
            item.image = NSImage(systemSymbolName: device.symbolName, accessibilityDescription: nil)
            item.state = device.id == monitor.defaultID ? .on : .off
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x, y: y.map { min(mouse.y, $0 - 4) } ?? mouse.y)
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    private final class Target: NSObject {
        static let shared = Target()

        @objc func select(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? AudioDeviceID else { return }
            MainActor.assumeIsolated { _ = AudioOutputMonitor.shared.select(id) }
        }
    }
}

/// 默认输出设备换了(连上 AirPods、在控制中心切了扬声器)时在灵动岛上闪一条横幅:设备图标 + 设备名。启停跟着灵动岛总开关
/// (同音量横幅,见 `AppDelegate.startObservingVolumeBannerPreference`)。只报换,不报开始监听时的那一台;换设备那一下
/// `VolumeMonitor` 只记基线、不弹音量横幅,两条不会互相顶掉。
@MainActor
enum OutputDeviceAnnouncer {
    private static var subscription: AnyCancellable?
    static let duration: TimeInterval = 2

    static func apply(enabled: Bool) {
        guard enabled else {
            subscription = nil
            return
        }
        guard subscription == nil else { return }
        let monitor = AudioOutputMonitor.shared
        // `refresh` 先写 devices 再写 defaultID,这里收到新 id 时列表已经是新的。
        subscription = monitor.$defaultID.removeDuplicates().dropFirst().sink { id in
            guard let id, let device = monitor.devices.first(where: { $0.id == id }) else { return }
            NotchTransientCenter.shared.show(.init(icon: device.symbolName, text: device.name, progress: nil),
                                             for: duration)
        }
    }
}
