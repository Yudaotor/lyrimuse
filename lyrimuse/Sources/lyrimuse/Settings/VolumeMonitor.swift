import AppKit
// kAudioHardwareServiceDeviceProperty_VirtualMainVolume 声明在 AudioToolbox 的
// AudioHardwareService.h 里,不在 CoreAudio 里 —— 只 import CoreAudio 会报"找不到符号"。
import AudioToolbox
import CoreAudio
import LyrimuseCore
import OSLog
import os

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
// 所有 CoreAudio 调用(挂监听、绑设备、读写音量和静音)都在 `SystemVolumeIO.queue` 这一条串行队列上,
// CoreAudio 的回调也派到这条队列上;主线程只往这条队列上派活、拿结果回来再碰 UI 状态。别在主线程上直接调
// `AudioObject…`:coreaudiod 忙时这些调用会同步等几十秒(见 15 章决策 113)。

private let volumeLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "volume")

@MainActor
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    /// 音量或静音状态变化时回调,参数是 0...1 的音量和是否静音。按订阅方各记一份(灵动岛的音量横幅、菜单栏面板的音量格),
    /// 最后一个订阅方走了才拆监听。
    private var subscribers: [ObjectIdentifier: (Float, Bool) -> Void] = [:]
    /// 灵动岛音量横幅那一份订阅的持有方(`start` / `stop` 用)。
    private let bannerOwner = NSObject()

    private var started = false
    private let listener = SystemVolumeListener()

    private init() {}

    /// 灵动岛音量横幅那一份(`apply(enabled:)`)。
    func start(onChange: @escaping (Float, Bool) -> Void) {
        subscribe(bannerOwner, onChange: onChange)
    }

    func stop() {
        unsubscribe(bannerOwner)
    }

    /// 按持有方订阅音量变化;同一个持有方再订阅就换掉它那一份。
    func subscribe(_ owner: AnyObject, onChange: @escaping (Float, Bool) -> Void) {
        subscribers[ObjectIdentifier(owner)] = onChange
        startListening()
    }

    func unsubscribe(_ owner: AnyObject) {
        subscribers[ObjectIdentifier(owner)] = nil
        if subscribers.isEmpty { stopListening() }
    }

    private func startListening() {
        guard !started else { return }
        started = true
        listener.start { [weak self] volume, muted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(volume: volume, muted: muted) }
            }
        }
    }

    private func stopListening() {
        guard started else { return }
        started = false
        listener.stop()
    }

    /// 监听那边读到的值真的变了。停听之后才到的丢掉。
    private func deliver(volume: Float, muted: Bool) {
        guard started else { return }
        volumeLogger.info("volume changed to \(Int(volume * 100), privacy: .public)% muted=\(muted, privacy: .public)")
        for onChange in subscribers.values { onChange(volume, muted) }
    }

    // MARK: - 调音量

    /// 把系统输出音量加减 `delta`(0...1 的量纲),灵动岛手势、菜单栏面板声音格的滚动用。排到 `SystemVolumeIO.queue` 上写、
    /// 不等;连着几下按调用顺序写,一次滑动的累加按调用时刻判(`SystemVolumeIO.adjust`)。
    static func adjustSystemVolume(by delta: Float) {
        let at = Date()
        SystemVolumeIO.queue.async { SystemVolumeIO.adjust(by: delta, at: at) }
    }

    /// 在 `SystemVolumeIO.queue` 上读默认输出设备此刻的音量和静音,回主线程交给 `completion`;这台设备的音量归下游硬件管
    /// (没有可写的音量属性)时音量是 nil。排在它前面的写入都已写完。菜单栏面板音量格用。
    static func readSystemVolume(_ completion: @escaping @MainActor (SystemVolumeIO.State) -> Void) {
        SystemVolumeIO.queue.async {
            let state = SystemVolumeIO.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(state) } }
        }
    }

    /// 把系统输出音量设成 `value`(0...1),菜单栏面板音量格的滑杆用;大于 0 时顺手解除静音。排到队列上写、不等。
    static func setSystemVolume(_ value: Float) {
        SystemVolumeIO.queue.async { SystemVolumeIO.set(volume: value) }
    }

    /// 静音 / 取消静音(菜单栏面板音量格)。排到队列上写、不等。
    static func setSystemMuted(_ muted: Bool) {
        SystemVolumeIO.queue.async { SystemVolumeIO.set(muted: muted) }
    }
}

/// 系统输出音量的 CoreAudio 读写。每个函数都只能在 `queue` 上调(`dispatchPrecondition` 守着)。
enum SystemVolumeIO {
    typealias State = (volume: Float?, muted: Bool)

    /// 系统音量的全部 CoreAudio 调用和监听回调都在这条串行队列上。
    static let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.volume", qos: .userInitiated)

    /// 一串连着的调节在上一次写下的目标上累加(`adjust`)。只在 `queue` 上读写。
    private static var adjustBurst: (device: AudioObjectID, target: Float32, at: Date)?
    private static let ownAdjust = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// 本 App 上一次写系统音量或静音的时刻(灵动岛手势、面板声音格)。写音量之前记下,「按音量键时提示」关着时灵动岛
    /// 靠它认出是自己调的(`NotchVolumeBannerPolicy`)。哪个线程都能读。
    static var lastOwnAdjustAt: Date? { ownAdjust.withLock { $0 } }

    private static func noteOwnAdjust() {
        ownAdjust.withLock { $0 = Date() }
    }

    static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// 加减 `delta`,调大时顺手解除静音(`SystemVolumeStep`)。`now` 是调用方发起这一下的时刻。默认输出设备的音量归下游硬件管
    /// (没有可写的音量属性,HDMI、部分 USB DAC)时什么都不做。
    static func adjust(by delta: Float, at now: Date) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = defaultOutputDevice(), var addr = volumeAddress(for: device) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        var value = Float32(0)
        // 一串连着的调节(一次滑动)在上一次写下的目标上累加,不每次重读:蓝牙、按 dB 粗分档的设备会把小步取整回原值,
        // 读回来还是原值,慢慢滑就一直不动。隔久了或换了设备再按设备上的值起算。
        if let burst = adjustBurst, burst.device == device, now.timeIntervalSince(burst.at) < 0.4 {
            value = burst.target
        } else {
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return }
        }
        var muted = UInt32(0)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if delta > 0, var mute = muteAddress(for: device),
           AudioObjectGetPropertyData(device, &mute, 0, nil, &muteSize, &muted) != noErr {
            muted = 0
        }
        let step = SystemVolumeStep.apply(current: value, muted: muted != 0, delta: delta)
        if step.unmute, var mute = muteAddress(for: device) {
            var off = UInt32(0)
            noteOwnAdjust()
            AudioObjectSetPropertyData(device, &mute, 0, nil, muteSize, &off)
        }
        var next = step.volume
        adjustBurst = (device, next, now)
        guard next != value else { return }
        noteOwnAdjust()
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &next)
        if status != noErr { volumeLogger.error("set volume failed: \(status)") }
    }

    /// 默认输出设备此刻的音量和静音;音量属性不可写时音量是 nil。
    static func read() -> State {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = defaultOutputDevice() else { return (nil, false) }
        var muted = false
        if var mute = muteAddress(for: device) {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &mute, 0, nil, &size, &value) == noErr { muted = value != 0 }
        }
        guard var addr = volumeAddress(for: device) else { return (nil, muted) }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return (nil, muted) }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return (nil, muted) }
        return (min(1, max(0, value)), muted)
    }

    /// 设成 `value`(0...1),大于 0 时顺手解除静音。设备不让写时什么都不做。
    static func set(volume value: Float) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = defaultOutputDevice(), var addr = volumeAddress(for: device) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        var next = Float32(min(1, max(0, value)))
        noteOwnAdjust()
        if next > 0 { setMuted(false, on: device) }
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &next)
        if status != noErr { volumeLogger.error("set volume failed: \(status)") }
    }

    static func set(muted: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let device = defaultOutputDevice() else { return }
        noteOwnAdjust()
        setMuted(muted, on: device)
    }

    private static func setMuted(_ muted: Bool, on device: AudioObjectID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var mute = muteAddress(for: device) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        dispatchPrecondition(condition: .onQueue(queue))
        var deviceAddr = defaultDeviceAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddr, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown else { return nil }
        return device
    }

    // MARK: - 属性地址

    /// 不同设备暴露的音量选择子不一样,按可用性挑一个:
    /// - VirtualMainVolume 是"系统音量滑块"那个语义(多声道设备上是各声道的统一代理),
    ///   优先用它 —— 用户按音量键动的就是这一个;
    /// - 没有的话退到 VolumeScalar 的主元素。
    static func volumeAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        dispatchPrecondition(condition: .onQueue(queue))
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

    static func muteAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        dispatchPrecondition(condition: .onQueue(queue))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &addr) ? addr : nil
    }
}

/// 默认输出设备的音量 / 静音监听。状态只在 `SystemVolumeIO.queue` 上读写,CoreAudio 的回调也派到那条队列上。
private final class SystemVolumeListener: @unchecked Sendable {
    private var started = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    /// 实际找到的那个音量属性地址(不同设备支持的选择子不一样,见 `SystemVolumeIO.volumeAddress(for:)`)。
    private var volumeAddr: AudioObjectPropertyAddress?
    private var muteAddr: AudioObjectPropertyAddress?
    /// 上一次已知的值。用来滤掉"值没变但系统还是回调了一次"的情况(切设备时常见)。
    private var lastVolume: Float?
    private var lastMuted: Bool?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    /// 值真的变了时调,在 `SystemVolumeIO.queue` 上。
    private var onChange: ((Float, Bool) -> Void)?

    private var queue: DispatchQueue { SystemVolumeIO.queue }

    func start(onChange: @escaping (Float, Bool) -> Void) {
        queue.async { self.startOnQueue(onChange: onChange) }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func startOnQueue(onChange: @escaping (Float, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !started else { return }
        started = true
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebindToDefaultDevice() }
        deviceListener = block
        var addr = SystemVolumeIO.defaultDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        if status != noErr {
            volumeLogger.error("failed to observe default output device: \(status)")
        }
        rebindToDefaultDevice()
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        started = false
        onChange = nil
        if let deviceListener {
            var addr = SystemVolumeIO.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, deviceListener)
        }
        deviceListener = nil
        detachVolumeListener()
    }

    // MARK: - 设备绑定

    /// 换设备本身不通知(用户是插了个耳机,不是调了音量),只记新设备的基线。
    private func rebindToDefaultDevice() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        detachVolumeListener()

        guard let deviceID = SystemVolumeIO.defaultOutputDevice() else {
            volumeLogger.error("no default output device")
            return
        }
        device = deviceID
        volumeAddr = SystemVolumeIO.volumeAddress(for: deviceID)
        muteAddr = SystemVolumeIO.muteAddress(for: deviceID)
        guard volumeAddr != nil || muteAddr != nil else {
            // 有些输出设备(HDMI、某些 USB DAC)音量归下游硬件管,系统这边根本没有可读的
            // 音量属性。这不是错误,只是这台设备上没法做这个提示。
            volumeLogger.notice("output device has no readable volume property; volume banner disabled for it")
            return
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleVolumeChanged() }
        volumeListener = block
        for addr in [volumeAddr, muteAddr].compactMap({ $0 }) {
            var a = addr
            let st = AudioObjectAddPropertyListenerBlock(deviceID, &a, queue, block)
            if st != noErr { volumeLogger.error("failed to observe volume property: \(st)") }
        }
        // 记基线但不通知 —— 见文件头第 2 条。
        lastVolume = readVolume()
        lastMuted = readMuted()
    }

    private func detachVolumeListener() {
        dispatchPrecondition(condition: .onQueue(queue))
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
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        let volume = readVolume()
        let muted = readMuted()
        // 音量属性在某些设备上会因为无关变化(采样率、通道布局)被一并通知。值真的动了才报。
        guard volume != lastVolume || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        guard let volume else { return }
        onChange?(volume, muted ?? false)
    }

    // MARK: - 读值

    private func readVolume() -> Float? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var addr = volumeAddr, device != kAudioObjectUnknown else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return min(1, max(0, value))
    }

    private func readMuted() -> Bool? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var addr = muteAddr, device != kAudioObjectUnknown else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
}

extension VolumeMonitor {
    /// 按设置启停,并把变化渲染成灵动岛上的一条提示。
    ///
    /// 参数是显式传进来的,不在函数体里读 AppSettings —— 这个方法的调用方是 Combine 的
    /// sink,而 @Published 是在 willSet 时机发的,那一刻属性还是旧值,函数体里再读一次
    /// 会拿到上一轮的状态(这个坑在本项目"暂停/无播放时隐藏悬浮窗"那次已经实测踩过)。
    static func apply(enabled: Bool) {
        guard enabled else {
            shared.stop()
            return
        }
        shared.start { volume, muted in
            // 回调时现读设置(不是 Combine sink,读到的就是当前值)。
            guard NotchVolumeBannerPolicy.shows(
                forVolumeKeys: AppSettings.shared.notchVolumeBannerForVolumeKeys,
                sinceOwnAdjust: SystemVolumeIO.lastOwnAdjustAt.map { Date().timeIntervalSince($0) }) else { return }
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
