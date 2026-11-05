import AppKit
import Combine
import SwiftUI
import LyrimuseCore

// 菜单栏面板的「声音」「今日收听」两格的数据和画法。格子接在 MenuBarPanel.swift 的 tileView 里;
// 「声音」的背面(输出设备)在 MenuBarPanelQuickSettings.swift。见 06 章决策 93。

/// 系统输出音量,面板里那一格开着时才盯:音量、静音、当前输出设备名。音量 nil = 这台设备的音量归下游硬件管、调不了。
@MainActor
final class PanelSystemVolume: ObservableObject {
    @Published private(set) var volume: Float?
    @Published private(set) var muted = false
    @Published private(set) var deviceName: String?
    private var deviceSubscription: AnyCancellable?

    func start() {
        refresh()
        VolumeMonitor.shared.subscribe(self) { [weak self] _, _ in self?.refresh() }
        // 换了输出设备(插上耳机、切 AirPods):音量、静音都按新设备重读。@Published 在 willSet 时发,推到下一拍再读。
        deviceSubscription = AudioOutputMonitor.shared.$defaultID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func stop() {
        VolumeMonitor.shared.unsubscribe(self)
        deviceSubscription = nil
    }

    func refresh() {
        let state = VolumeMonitor.readSystemVolume()
        if state.volume != volume { volume = state.volume }
        if state.muted != muted { muted = state.muted }
        let monitor = AudioOutputMonitor.shared
        let name = monitor.devices.first { $0.id == monitor.defaultID }?.name
        if name != deviceName { deviceName = name }
    }

    func set(_ value: Float) {
        VolumeMonitor.setSystemVolume(value)
        volume = value
        if value > 0 { muted = false }
    }

    func toggleMute() {
        VolumeMonitor.setSystemMuted(!muted)
        muted.toggle()
    }

    /// 同灵动岛音量横幅那一套:静音或 0 是划掉的喇叭,其余按音量分三档声波。
    var symbolName: String {
        guard let volume else { return "speaker.slash" }
        if muted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// 小号格子上那一行字:百分比,静音时「已静音」。
    var label: String {
        if muted { return L10n.t("已静音") }
        return volume.map { "\(Int(($0 * 100).rounded()))%" } ?? L10n.t("声音")
    }
}

/// 把那一格的音量模型交给内容,格子在的时候盯着、走了就撒手。
struct PanelVolumeReader<Content: View>: View {
    @StateObject private var model = PanelSystemVolume()
    let content: (PanelSystemVolume) -> Content

    init(@ViewBuilder content: @escaping (PanelSystemVolume) -> Content) {
        self.content = content
    }

    var body: some View {
        content(model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

/// 中号、大号、长条的「声音」:标题、右上角一颗翻到输出设备的键,一条滑杆(左边喇叭点一下静音);大号底下、长条标题右边
/// 再写当前输出设备。小号用面板的圆钮块(`knobTile`),不在这里。
struct PanelVolumeSlider: View {
    @ObservedObject var model: PanelSystemVolume
    let size: MenuBarPanelLayout.Size
    let openDevices: () -> Void
    private var large: Bool { size == .large || size == .wide }
    /// 正按着滑杆。只在按着时写系统音量:滑杆刚出现、换尺寸重排时 SwiftUI 也会调一次 set,带进来的可能是 0,
    /// 不拦的话一换布局就把系统音量写成 0(到 0 系统还会自己静音)。
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 6) {
            HStack(spacing: 4) {
                Text(L10n.t("声音"))
                    .font(.system(size: 12, weight: .semibold))
                if size == .bar, let name = model.deviceName {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                Button(action: openDevices) {
                    Image(systemName: "airplay.audio")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("输出设备"))
                .accessibilityLabel(L10n.t("输出设备"))
            }
            HStack(spacing: 6) {
                Button(action: model.toggleMute) {
                    Image(systemName: model.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.muted ? L10n.t("取消静音") : L10n.t("静音"))
                Slider(value: Binding(get: { Double(model.muted ? 0 : (model.volume ?? 0)) },
                                      set: { value in if dragging { model.set(Float(value)) } }),
                       in: 0...1,
                       onEditingChanged: { dragging = $0 })
                    .controlSize(.small)
                    .accessibilityLabel(L10n.t("声音"))
            }
            .disabled(model.volume == nil)
            if large {
                Spacer(minLength: 0)
                Text(model.deviceName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .menuBarPanelCardBackground(cornerRadius: panelTileCornerRadius)
        .modifier(OptionalHelp(text: model.volume == nil ? L10n.t("当前输出设备不支持调节音量") : nil))
    }
}

/// 「今日收听」:今天在 Last.fm 上听了几首,中号再带近 7 天,大号再带总数;点了打开设置里 Last.fm 的收听统计。
/// 数字来自 `LastfmStatsService.overview`(引擎每 15 秒落盘的那份最近记录持续更新「今天」),这里不另发请求。
struct PanelTodayListeningTile: View {
    let size: MenuBarPanelLayout.Size
    let open: () -> Void
    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        Button(action: open) { content }
            .buttonStyle(.plain)
            .menuBarPanelCardBackground(cornerRadius: panelTileCornerRadius)
            .help(L10n.t("今日收听"))
    }

    /// 「近 7 天」跟设置页 Last.fm 统计、歌词窗口待机页同一个口径(按天的收听数 + 今天,自然日对齐),三处显示同一个数。
    /// 别读 `overview.week`:它只在统计页的基线刷新时更新,引擎那份最近记录一直新鲜时一直不动。
    private var weekValue: Int? {
        guard !stats.dailyFullSyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
    }

    private func number(_ value: Int?) -> String {
        value.map { $0.formatted(.number) } ?? "—"
    }

    @ViewBuilder private var content: some View {
        let overview = stats.overview
        switch size {
        case .bar:
            // 长条:今天、近 7 天、总数横着三个。
            HStack(alignment: .center) {
                figure(number(overview?.today), L10n.t("今日收听"), size: 22)
                Spacer(minLength: 8)
                figure(number(weekValue), L10n.t("近 7 天"), size: 15)
                Spacer(minLength: 8)
                figure(number(overview?.total), L10n.t("总 Scrobble"), size: 15, trailing: true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .small:
            VStack(spacing: 3) {
                Text(number(overview?.today))
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                caption(L10n.t("今日收听"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .medium:
            HStack(alignment: .center) {
                figure(number(overview?.today), L10n.t("今日收听"), size: 22)
                Spacer(minLength: 6)
                figure(number(weekValue), L10n.t("近 7 天"), size: 15, trailing: true)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .large, .wide:
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                figure(number(overview?.today), L10n.t("今日收听"), size: 30)
                Spacer(minLength: 8)
                row(L10n.t("近 7 天"), number(weekValue))
                row(L10n.t("总 Scrobble"), number(overview?.total))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func figure(_ value: String, _ title: String, size: CGFloat, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            caption(title)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
