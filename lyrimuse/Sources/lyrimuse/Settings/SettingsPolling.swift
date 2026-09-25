import SwiftUI

extension View {
    /// 设置页里的定时刷新,替代 `.onReceive(Timer.publish(every:…).autoconnect())`。
    ///
    /// - 设置窗口看不见(被挡住 / 最小化 / 在别的桌面)时**整个循环停掉**,不是每拍醒来再跳过:
    ///   系统不会替被遮住的窗口停计时器,页面也不会因此销毁。可见性来自 `previewHostVisible`
    ///   (`SettingsWindowSurface`,见 PreviewHostVisibility.swift)。
    /// - 重新看得见时立刻补一次,界面上的状态不会停在离开那一刻。
    /// - 每拍带 25% 的误差,让系统把这次唤醒跟别的合并;这些刷新都是给人看的状态,早晚半秒无所谓。
    ///
    /// `runsOnAppear` = 页面第一次出现时也跑一次。已经有自己的 `.onAppear` 刷新的调用点传 false,
    /// 免得同一拍跑两遍。
    func settingsPolling(every seconds: TimeInterval, runsOnAppear: Bool = false,
                         perform action: @escaping @MainActor () -> Void) -> some View {
        modifier(SettingsPolling(interval: seconds, runsOnAppear: runsOnAppear, action: action))
    }
}

private struct SettingsPolling: ViewModifier {
    let interval: TimeInterval
    let runsOnAppear: Bool
    let action: @MainActor () -> Void
    @Environment(\.previewHostVisible) private var windowVisible
    /// 这个循环起过没有:第一次起(页面刚出现)按 runsOnAppear;之后再起都是「重新看得见」,一律先补一次。
    @State private var started = false

    func body(content: Content) -> some View {
        content.task(id: windowVisible) {
            guard windowVisible else { return }
            if started || runsOnAppear { action() }
            started = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 4))
                if Task.isCancelled { return }
                action()
            }
        }
    }
}
