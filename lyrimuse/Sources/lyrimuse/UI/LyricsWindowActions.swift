import LyrimuseCore
import SwiftUI

// 歌词窗口右下角「搜索歌词 / 重新自动匹配 / 用外部编辑器改歌词」三颗图标,和它们上方那句说明(07 章决策 112)。
// 状态都放在下面两个单例里,只有胶囊和说明条订阅:重新匹配跑着时进度一直在变,不能让整扇窗跟着重估。

/// 右下那排按钮发起的动作说的那一句(重新匹配的结论、外部编辑器的回执),几秒后自己收掉。
@MainActor
final class LyricsWindowActionNotes: ObservableObject {
    static let shared = LyricsWindowActionNotes()

    enum Tone {
        case info, success, warning, failure
    }

    struct Note: Equatable, Identifiable {
        let id = UUID()
        /// 说的是哪一首;已经换了歌时这一句前面带上歌名。
        let title: String
        let text: String
        let symbol: String
        let tint: Color
    }

    @Published private(set) var note: Note?

    private init() {}

    func post(title: String, text: String, symbol: String, tint: Color, seconds: Double) {
        let note = Note(title: title, text: text, symbol: symbol, tint: tint)
        self.note = note
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.note?.id == note.id { self?.note = nil }
        }
    }

    func post(_ tone: Tone, title: String, text: String) {
        switch tone {
        case .info: post(title: title, text: text, symbol: "info.circle", tint: .secondary, seconds: 6)
        case .success: post(title: title, text: text, symbol: "checkmark.circle.fill", tint: .green, seconds: 6)
        case .warning: post(title: title, text: text, symbol: "exclamationmark.circle.fill", tint: .orange, seconds: 10)
        case .failure: post(title: title, text: text, symbol: "exclamationmark.triangle.fill", tint: .orange, seconds: 10)
        }
    }

    /// 快捷键回声(`GlobalHotkeys.flashHint`):不带歌名,`seconds` 秒后收掉。见 07 章决策 132。
    func flashHint(_ text: String, symbol: String, seconds: Double) {
        post(title: "", text: text, symbol: symbol, tint: .secondary, seconds: seconds)
    }

    func dismiss() {
        note = nil
    }
}

/// 歌词窗口此刻能不能显示快捷键回声:有一扇开着、看得见(被整扇盖住、最小化不算)。完整那扇和迷你面板各有一份 controller,
/// 各报各的,关窗时只撤自己那一条:两种形态交接时是新窗先上屏、旧窗后关,共用一个布尔、关窗就清的话,旧窗关的那一下
/// 会把新窗刚报的「看得见」抹掉,要等新窗下一次遮挡变化才回来。设置页预览那份不报。见 07 章决策 132。
@MainActor
enum LyricsWindowHintSurface {
    /// 报了「看得见」的 controller。弱引用:controller 放掉了就自动不算。
    private static let visibleOwners = NSHashTable<AnyObject>.weakObjects()

    static var visible: Bool { !visibleOwners.allObjects.isEmpty }

    static func report(_ visible: Bool, from owner: AnyObject) {
        if visible { visibleOwners.add(owner) } else { visibleOwners.remove(owner) }
    }
}

/// 箭头往上弹的那颗小菜单开没开。胶囊开关它,说明条据此往上让开。
@MainActor
final class LyricsWindowActionMenu: ObservableObject {
    static let shared = LyricsWindowActionMenu()

    @Published var isOpen = false

    private init() {}
}

/// 歌词窗口里那颗「重新自动匹配」:绑在点下去那一刻在放的那首(缓存 key),跟歌词管理、搜索面板同一个
/// `LyricsRematchRunner`。手动改过、标了纯音乐、调过单曲时间轴的先问一句。
@MainActor
final class LyricsWindowRematch: ObservableObject {
    static let shared = LyricsWindowRematch()

    struct Round: Equatable {
        let id: String
        let key: String
        let title: String
        var done = 0
        var total = 0
    }

    struct Confirm: Equatable, Identifiable {
        let id = UUID()
        let key: String
        let title: String
        let reasons: [String]
    }

    @Published private(set) var round: Round?
    /// 要先确认的那一轮;胶囊上的确认框绑它。
    @Published var confirm: Confirm?

    private init() {}

    /// 在跑就叫停;没在跑就对当前这首开一轮(要确认的先确认)。
    func toggle() {
        if let round {
            stop(round)
            return
        }
        let playback = PlaybackCoordinator.shared
        let title = playback.title
        guard !title.isEmpty else { return }
        guard let stored = EnrichCacheReader.storedEntry(artist: playback.artist, title: title, album: playback.album) else {
            // 歌词库正在重读时查不到不代表没有记录。
            if EnrichCacheReader.isCurrent {
                LyricsWindowActionNotes.shared.post(.warning, title: title,
                                                    text: L10n.t("歌词库中尚无这首歌曲的记录，可先通过「搜索歌词」查找"))
            } else {
                EnrichCacheReader.refreshIfNeeded()
                LyricsWindowActionNotes.shared.post(.info, title: title, text: L10n.t("歌词库正在刷新，请稍后重试"))
            }
            return
        }
        var reasons: [String] = []
        if stored.manualLyrics {
            reasons.append(L10n.t("这首歌曲的歌词经过手动修改或选定，更换后将被覆盖。"))
        }
        if stored.instrumental {
            reasons.append(L10n.t("这首歌曲已标为纯音乐，找到歌词后将取消该标记。"))
        } else if playback.trackLyricsOffsetMs != 0 {
            reasons.append(String(format: L10n.t("这首歌曲调整过歌词时间轴（%@），更换歌词后该校准可能失效。"),
                                  AppSettings.signedSeconds(ms: playback.trackLyricsOffsetMs) + "s"))
        }
        if reasons.isEmpty {
            start(key: stored.key, title: title)
        } else {
            confirm = Confirm(key: stored.key, title: title, reasons: reasons)
        }
    }

    func start(key: String, title: String) {
        guard round == nil else { return }
        let id = UUID().uuidString
        round = Round(id: id, key: key, title: title)
        Task {
            let line = await LyricsRematchRunner.run(key: key, id: id, isCurrent: { round?.id == id }) { done, total in
                guard var progress = round, progress.id == id, progress.done != done || progress.total != total else { return }
                progress.done = done
                progress.total = total
                round = progress
            }
            guard let line, round?.id == id else { return }
            round = nil
            if LyricsRematchRunner.rewroteLyrics(line) { PlaybackCoordinator.shared.refreshLyricsForCurrentTrack() }
            LyricsWindowActionNotes.shared.post(
                title: title, text: LyricsRematchRunner.text(line), symbol: LyricsRematchRunner.icon(line.tone),
                tint: LyricsRematchRunner.tint(line.tone), seconds: line.tone == .changed ? 6 : 10)
        }
    }

    private func stop(_ round: Round) {
        LyricsRematch.cancel(id: round.id)
        self.round = nil
        LyricsWindowActionNotes.shared.post(.info, title: round.title, text: L10n.t("已停止重新匹配"))
    }
}

/// 三颗图标的胶囊,摆在翻译钮左边。只有图标,意思靠悬停提示和辅助功能名称。
struct LyricsWindowActionsCapsule: View {
    let onArtwork: Bool
    /// 广告、电台串场这类不是一首歌的时候三颗都不能点。
    let enabled: Bool
    let onSearch: () -> Void
    @ObservedObject private var rematch = LyricsWindowRematch.shared
    @ObservedObject private var menu = LyricsWindowActionMenu.shared
    /// 指针在箭头上 / 在弹出的小菜单上。两处都离开一会儿才收,从箭头往上挪到菜单的半路不收。
    @State private var overArrow = false
    @State private var overMenu = false
    @State private var hoverTask: Task<Void, Never>?

    private var iconColor: Color { onArtwork ? .white.opacity(0.9) : .primary.opacity(0.75) }
    private var rim: Color { onArtwork ? Color.white.opacity(0.28) : Color.primary.opacity(0.10) }

    var body: some View {
        HStack(spacing: 2) {
            slot(symbol: "magnifyingglass", label: L10n.t("搜索歌词…"), shortcut: "f", action: onSearch)
                // 自动匹配在飞时不开搜索面板:在面板里采纳的那份会让这一轮作废,结论跟面板里的回声说的不是一件事。
                .disabled(rematch.round != nil)
            rematchSlot
            arrowSlot
        }
        .padding(.horizontal, 3)
        .frame(height: 36)
        .clearGlassCapsule(rim: rim)
        // 小菜单挂在胶囊外面(挂进去就是玻璃套玻璃,采样不到背景),右缘对齐胶囊,正好居中在箭头上方。
        .overlay(alignment: .bottomTrailing) {
            if menu.isOpen {
                menuPanel
                    .offset(y: -36)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
            }
        }
        // ⌘E 不用先打开小菜单。
        .background {
            Button("", action: openEditor)
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onDisappear { menu.isOpen = false }
        .alert(rematch.confirm.map { String(format: L10n.t("重新匹配《%@》的歌词？"), $0.title) } ?? "",
               isPresented: Binding(get: { rematch.confirm != nil }, set: { if !$0 { rematch.confirm = nil } }),
               presenting: rematch.confirm) { confirm in
            Button(L10n.t("重新自动匹配")) { rematch.start(key: confirm.key, title: confirm.title) }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { confirm in
            Text(confirm.reasons.joined(separator: "\n"))
        }
    }

    private func slot(symbol: String, label: String, shortcut: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .keyboardShortcut(shortcut, modifiers: .command)
    }

    /// 第三格是个朝上的箭头:指针停上去一会儿、或点一下,往上弹出一颗小菜单(现在只有「用外部编辑器改歌词」),
    /// 箭头转成朝下;再点一下收起。
    private var arrowSlot: some View {
        // 左栏「⋯」那颗叫「更多」,这里别重名,旁白里分不出是哪一颗。
        let label = menu.isOpen ? L10n.t("收起") : L10n.t("更多歌词操作")
        return Button {
            setMenu(!menu.isOpen)
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .rotationEffect(.degrees(menu.isOpen ? 180 : 0))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { inside in
            overArrow = inside
            hoverChanged()
        }
    }

    private var menuPanel: some View {
        VStack(spacing: 2) {
            Button {
                setMenu(false)
                openEditor()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("在外部编辑器中编辑歌词"))
            .accessibilityLabel(L10n.t("在外部编辑器中编辑歌词"))
        }
        .padding(3)
        .clearGlassCapsule(rim: rim)
        // 菜单跟胶囊之间那 8pt 也算菜单的悬停区,指针从箭头往上挪时不会半路收掉。
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onHover { inside in
            overMenu = inside
            hoverChanged()
        }
    }

    /// 指针在箭头上停 0.15 秒才弹(只是路过不弹);箭头和菜单都离开 0.3 秒才收。
    private func hoverChanged() {
        hoverTask?.cancel()
        if overArrow || overMenu {
            guard overArrow, !menu.isOpen, enabled else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, overArrow else { return }
                setMenu(true)
            }
        } else if menu.isOpen {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, !overArrow, !overMenu else { return }
                setMenu(false)
            }
        }
    }

    private func setMenu(_ open: Bool) {
        if !open { overMenu = false }
        withAnimation(.easeOut(duration: 0.15)) { menu.isOpen = open }
    }

    private func openEditor() {
        let playback = PlaybackCoordinator.shared
        LyricsExternalEditor.shared.open(artist: playback.artist, title: playback.title, album: playback.album)
    }

    /// 跑着时换成进度圈 + 停止方块,再点一下叫停。
    private var rematchSlot: some View {
        let label = rematch.round == nil ? L10n.t("重新自动匹配") : L10n.t("停止重新匹配")
        return Button { rematch.toggle() } label: {
            Group {
                if let round = rematch.round {
                    ZStack {
                        Circle().stroke(iconColor.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: round.total > 0 ? max(0.08, CGFloat(round.done) / CGFloat(round.total)) : 0.08)
                            .stroke(iconColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 17, height: 17)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .keyboardShortcut("r", modifiers: .command)
    }
}

/// 胶囊上方那句:重新匹配跑着时是进度,跑完是结论;外部编辑器的回执。点一下收掉。
struct LyricsWindowActionCaption: View {
    /// 窗口此刻在放的那首;说明说的是别的歌(换了歌)时前面带《歌名》。
    let currentTitle: String
    let onArtwork: Bool
    @ObservedObject private var rematch = LyricsWindowRematch.shared
    @ObservedObject private var notes = LyricsWindowActionNotes.shared
    @ObservedObject private var menu = LyricsWindowActionMenu.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let round = rematch.round {
                row(text: titled(round.title, round.total > 0
                                 ? String(format: L10n.t("正在重新匹配…（%1$@/%2$@）"), "\(round.done)", "\(round.total)")
                                 : L10n.t("正在重新匹配…"))) {
                    ProgressView().controlSize(.small)
                }
            } else if let note = notes.note {
                row(text: titled(note.title, note.text)) {
                    Image(systemName: note.symbol).foregroundStyle(note.tint)
                }
                .onTapGesture { notes.dismiss() }
            }
        }
        .animation(.easeOut(duration: 0.15), value: rematch.round == nil)
        .animation(.easeOut(duration: 0.15), value: notes.note?.id)
        // 箭头弹出的小菜单开着时让到它上面去。
        .padding(.bottom, menu.isOpen ? 44 : 0)
        .animation(.easeOut(duration: 0.15), value: menu.isOpen)
    }

    private func titled(_ title: String, _ text: String) -> String {
        title.isEmpty || title == currentTitle ? text : String(format: L10n.t("《%1$@》：%2$@"), title, text)
    }

    private func row<Icon: View>(text: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            icon()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .environment(\.colorScheme, onArtwork ? .dark : colorScheme)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}
