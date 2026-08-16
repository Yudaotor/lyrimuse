import AppKit
// kAudioHardwareServiceDeviceProperty_VirtualMainVolume 声明在 AudioToolbox 的
// AudioHardwareService.h 里,不在 CoreAudio 里 —— 只 import CoreAudio 会报"找不到符号"。
import AudioToolbox
import CoreAudio
import OSLog

// 监听系统输出音量的变化,用来在灵动岛上闪一条音量提示。
//
// 为什么用 CoreAudio 的属性监听,而不是别的几种常见做法:
// - **不**拦截音量键(那需要 CGEventTap,要辅助功能权限,而且拦得不干净就把系统自己的
//   音量调节也吞了);
// - **不**轮询 `osascript -e "output volume of (get volume settings)"`(每秒 fork 一个
//   进程去问一件几乎从不变的事);
// - AudioObjectAddPropertyListenerBlock 是零权限、纯事件驱动的:值真的变了才回调,
//   平时一点开销都没有。
//
// 两个必须处理、少一个就出错的细节:
// 1. **默认输出设备会换**(插拔耳机、切 AirPods)。监听是挂在**某一个设备对象**上的,
//    设备一换,老监听就再也收不到东西了 —— 所以还得同时监听
//    kAudioHardwarePropertyDefaultOutputDevice,在它变化时把音量监听摘下来重挂到新设备上。
// 2. **注册瞬间不能当成一次"变化"**。刚挂上监听时读到的那个值是当前音量,不是用户刚调的;
//    不把它记成基线直接就报,插上耳机就会无缘无故弹一次音量提示。
//
// ⚠️ CoreAudio 的回调在它自己的队列上跑,不在主线程。所有回调都先跳回主线程再碰
// 任何 UI/@Published 状态。
@MainActor
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "volume")

    /// 音量或静音状态变化时回调,参数是 0...1 的音量和是否静音。
    private var onChange: ((Float, Bool) -> Void)?

    private var started = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    /// 实际找到的那个音量属性地址(不同设备支持的选择子不一样,见 volumeAddress(for:))。
    private var volumeAddr: AudioObjectPropertyAddress?
    private var muteAddr: AudioObjectPropertyAddress?
    /// 上一次已知的值。用来滤掉"值没变但系统还是回调了一次"的情况(切设备时常见)。
    private var lastVolume: Float?
    private var lastMuted: Bool?

    /// 回调派发队列。用自己的串行队列而不是 .main:CoreAudio 不保证在主线程调用者上下文里
    /// 回调,给它一个明确的串行队列,再由我们自己跳回主线程,顺序才是确定的。
    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.volume")

    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {}

    func start(onChange: @escaping (Float, Bool) -> Void) {
        guard !started else { return }
        started = true
        self.onChange = onChange

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebindToDefaultDevice(notify: false) }
        }
        deviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, queue, block)
        if status != noErr {
            Self.logger.error("failed to observe default output device: \(status)")
        }
        rebindToDefaultDevice(notify: false)
    }

    func stop() {
        guard started else { return }
        started = false
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, queue, deviceListener)
        }
        deviceListener = nil
        detachVolumeListener()
        onChange = nil
    }

    // MARK: - 设备绑定

    /// notify: 换设备本身不该弹提示(用户是插了个耳机,不是调了音量),所以这里恒传 false;
    /// 参数留着是为了让"为什么不报"这件事在调用点可见,而不是藏在函数体里。
    private func rebindToDefaultDevice(notify: Bool) {
        guard started else { return }
        detachVolumeListener()

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            Self.logger.error("no default output device (status \(status))")
            return
        }
        device = deviceID
        volumeAddr = Self.volumeAddress(for: deviceID)
        muteAddr = Self.muteAddress(for: deviceID)
        guard volumeAddr != nil || muteAddr != nil else {
            // 有些输出设备(HDMI、某些 USB DAC)音量归下游硬件管,系统这边根本没有可读的
            // 音量属性。这不是错误,只是这台设备上没法做这个提示。
            Self.logger.info("output device has no readable volume property; volume banner disabled for it")
            return
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleVolumeChanged() }
        }
        volumeListener = block
        for addr in [volumeAddr, muteAddr].compactMap({ $0 }) {
            var a = addr
            let st = AudioObjectAddPropertyListenerBlock(deviceID, &a, queue, block)
            if st != noErr { Self.logger.error("failed to observe volume property: \(st)") }
        }
        // 记基线但不通知 —— 见文件头第 2 条。
        lastVolume = readVolume()
        lastMuted = readMuted()
    }

    private func detachVolumeListener() {
        guard let volumeListener, device != kAudioObjectUnknown else {
            self.volumeListener = nil
            return
        }
        for addr in [volumeAddr, muteAddr].compactMap({ $0 }) {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, volumeListener)
        }
        self.volumeListener = nil
        volumeAddr = nil
        muteAddr = nil
        lastVolume = nil
        lastMuted = nil
    }

    private func handleVolumeChanged() {
        guard started else { return }
        let volume = readVolume()
        let muted = readMuted()
        // 音量属性在某些设备上会因为无关变化(采样率、通道布局)被一并通知。值真的动了才报。
        guard volume != lastVolume || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        guard let volume else { return }
        Self.logger.info("volume changed to \(Int(volume * 100), privacy: .public)% muted=\(muted ?? false, privacy: .public)")
        onChange?(volume, muted ?? false)
    }

    // MARK: - 读值

    private func readVolume() -> Float? {
        guard var addr = volumeAddr, device != kAudioObjectUnknown else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return min(1, max(0, value))
    }

    private func readMuted() -> Bool? {
        guard var addr = muteAddr, device != kAudioObjectUnknown else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    // MARK: - 属性地址

    /// 不同设备暴露的音量选择子不一样,按可用性挑一个:
    /// - VirtualMainVolume 是"系统音量滑块"那个语义(多声道设备上是各声道的统一代理),
    ///   优先用它 —— 用户按音量键动的就是这一个;
    /// - 没有的话退到 VolumeScalar 的主元素。
    private static func volumeAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        let candidates: [AudioObjectPropertySelector] = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
        ]
        for selector in candidates {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(device, &addr) { return addr }
        }
        return nil
    }

    private static func muteAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &addr) ? addr : nil
    }
}

extension VolumeMonitor {
    /// 按设置启停,并把变化渲染成灵动岛上的一条提示。
    ///
    /// ⚠️ 参数是显式传进来的,不在函数体里读 AppSettings —— 这个方法的调用方是 Combine 的
    /// sink,而 @Published 是在 willSet 时机发的,那一刻属性还是旧值,函数体里再读一次
    /// 会拿到上一轮的状态(这个坑在本项目"暂停/无播放时隐藏悬浮窗"那次已经实测踩过)。
    static func apply(enabled: Bool) {
        guard enabled else {
            shared.stop()
            return
        }
        shared.start { volume, muted in
            let percent = Int((volume * 100).rounded())
            let icon: String
            if muted || percent == 0 {
                icon = "speaker.slash.fill"
            } else if volume < 0.34 {
                icon = "speaker.wave.1.fill"
            } else if volume < 0.67 {
                icon = "speaker.wave.2.fill"
            } else {
                icon = "speaker.wave.3.fill"
            }
            NotchTransientCenter.shared.show(
                .init(
                    icon: icon,
                    text: muted ? L10n.t("已静音") : "\(percent)%",
                    progress: muted ? 0 : Double(volume)
                ),
                for: 1.2
            )
        }
    }
}
