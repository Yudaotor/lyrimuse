import AppKit
import SwiftUI
import LyrimuseCore

/// 「歌词管理」那一格翻过来的背面:正在放的这首的三个动作(搜索歌词 / 重新自动匹配 / 标为纯音乐)。
/// 整个歌词库的批量匹配、扫描间隔、锁定手选歌词不收,走底栏「全部设置…」。见 06 章决策 43。
///
/// 重新匹配手改过 / 标了纯音乐 / 调过单曲时间轴的歌要先确认,在行内问,不弹确认框:确认框是另一扇窗,点它面板就收起了
/// (同 MenuBarPanelQuickSettings 头注那条)。
///
/// 每一项都跟歌词窗口右下那排按钮同一份实现:重新匹配走 `LyricsWindowRematch`(结论也发到同一条说明),
/// 标纯音乐写回同搜索面板(`setInstrumental`)。
struct PanelLyricsManagerRows: View {
    let close: () -> Void

    @ObservedObject private var rematch = LyricsWindowRematch.shared
    @ObservedObject private var notes = LyricsWindowActionNotes.shared

    /// 重新匹配要先确认的那一轮。
    @State private var rematchConfirm: LyricsWindowRematch.Confirm?
    /// 这一首刚标 / 撤过纯音乐时先按点下去的值画,不等缓存读取器跟上;换了歌(key 对不上)就作废。
    @State private var instrumentalOverride: InstrumentalOverride?
    @State private var settingInstrumental = false

    private struct InstrumentalOverride: Equatable {
        let key: String
        let value: Bool
    }

    private struct Song {
        let title: String
        let artist: String
        let album: String
        let stored: EnrichCacheReader.StoredEntry?
    }

    /// 正在放的是一首歌时才有(广告、电台串场不算,同歌词窗口那排按钮)。
    private var song: Song? {
        let p = PlaybackCoordinator.shared
        guard !p.title.isEmpty, !p.isCurrentTrackAdBreak, !p.isRadioTalkBreak else { return nil }
        return Song(title: p.title, artist: p.artist, album: p.album,
                    stored: EnrichCacheReader.storedEntry(artist: p.artist, title: p.title, album: p.album))
    }

    var body: some View {
        let song = song
        let confirm = rematchConfirm.flatMap { $0.key == song?.stored?.key ? $0 : nil }
        VStack(alignment: .leading, spacing: 4) {
            caption(song?.title ?? L10n.t("未在播放"))
            VStack(spacing: 1) {
                PanelQuickRow(L10n.t("搜索歌词…")) {
                    iconButton("magnifyingglass", label: L10n.t("搜索歌词…")) {
                        close()
                        AppActions.shared.openLyricsQuickSearch?()
                    }
                    // 自动匹配在飞时不开搜索面板:在面板里采纳的那份会让这一轮作废(同歌词窗口那颗)。
                    .disabled(song == nil || rematch.round != nil)
                }
                rematchRow(song)
                if let confirm {
                    confirmRow(title: String(format: L10n.t("重新匹配《%@》的歌词？"), confirm.title),
                               message: confirm.reasons.joined(separator: "\n"),
                               onConfirm: {
                                   rematchConfirm = nil
                                   rematch.start(key: confirm.key, title: confirm.title)
                               })
                }
                instrumentalRow(song)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // 重新匹配的结论(同歌词窗口胶囊上方那句)。快捷键回声不带歌名,不在这里说。
            if let note = notes.note, !note.title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: note.symbol).foregroundStyle(note.tint)
                    Text(note.text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .padding(.horizontal, 4)
            }
        }
    }

    private func rematchRow(_ song: Song?) -> some View {
        let round = rematch.round
        return PanelQuickRow(round == nil ? L10n.t("重新自动匹配") : L10n.t("停止重新匹配")) {
            HStack(spacing: 6) {
                if let round, round.total > 0 {
                    Text("\(round.done)/\(round.total)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if round != nil {
                    iconButton("stop.fill", label: L10n.t("停止重新匹配")) { rematch.toggle() }
                } else {
                    iconButton("arrow.triangle.2.circlepath", label: L10n.t("重新自动匹配")) {
                        guard let target = rematch.prepare() else { return }
                        if target.reasons.isEmpty {
                            rematch.start(key: target.key, title: target.title)
                        } else {
                            rematchConfirm = target
                        }
                    }
                    .disabled(song == nil)
                }
            }
        }
    }

    /// 撤标会记下「用户说过这首不是纯音乐」,之后的自动流程不再标回去。
    private func instrumentalRow(_ song: Song?) -> some View {
        let key = song?.stored?.key
        let stored = song?.stored?.instrumental ?? false
        let shown = instrumentalOverride.flatMap { $0.key == key ? $0.value : nil } ?? stored
        return PanelQuickRow(L10n.t("标为纯音乐")) {
            Toggle("", isOn: Binding(
                get: { shown },
                set: { value in
                    guard let key, let title = song?.title else { return }
                    settingInstrumental = true
                    Task {
                        let saved = await EnrichCacheStore.shared.setInstrumental(key: key, value)
                        settingInstrumental = false
                        if saved {
                            instrumentalOverride = InstrumentalOverride(key: key, value: value)
                            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                        } else {
                            notes.post(.failure, title: title, text: L10n.t("保存失败，请重试"))
                        }
                    }
                }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // 没有条目(还没解析过)时没地方记;自动匹配在飞时改了条目,引擎那一轮就作废(同搜索面板)。
            .disabled(key == nil || settingInstrumental || rematch.round != nil)
        }
    }

    // MARK: 组件

    private func caption(_ detail: String) -> some View {
        HStack(spacing: 6) {
            Text(L10n.t("正在播放"))
                .foregroundStyle(.secondary)
            Text(detail)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.leading, 4)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .settingsGlassButtons()
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(label)
        .accessibilityLabel(label)
    }

    /// 行内确认:问句 + 原因 + 两颗按钮,接在「重新自动匹配」那一行下面。文案同歌词窗口那个确认框。
    private func confirmRow(title: String, message: String, onConfirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    rematchConfirm = nil
                } label: {
                    Text(L10n.t("取消")).font(.system(size: 11))
                }
                .settingsGlassButtons()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
                Button(action: onConfirm) {
                    Text(L10n.t("重新自动匹配")).font(.system(size: 11, weight: .semibold))
                }
                .settingsProminentGlassButton(tint: .accentColor)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
    }
}
