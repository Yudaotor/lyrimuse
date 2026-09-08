import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// 设置搜索(2026-09-09,借鉴清单 S8):侧栏顶部一个搜索框,按 Core `SettingsSearchCatalog` 出结果,
// 命中后翻到那一页、切到那一段、展开那个抽屉、把那一行高亮一下并滚进视野。
//
// 三块拼起来:
//   - `SettingsSearchIndex`:把目录条目本地化成能搜的字段(当前语言标题 + 简体键 + 英文 / 繁体译文 +
//     关键词 + 面包屑),按 `SettingsSearchMatcher` 排序。三语一起索引是为了「英文界面打中文、中文界面
//     打英文」都能搜到——译文表从 bundle 里的 .lproj/Localizable.strings 读,跟 L10n.t 同一份文件。
//   - `SettingsSearchRouter`:命中后的"信号":高亮哪些标题、哪个抽屉该展开。SettingsView 根部把它
//     塞进 Environment,行组件(SettingsRow / SettingsSubRow / SettingsCardHeader)只读 Environment ——
//     不让一百多行各自订阅一个单例,也不让设置窗口之外(菜单栏面板)复用这些组件的地方被牵动。
//   - `SettingsSearchHighlight` + `SettingsRevealInScrollView`:行自己判"我是不是被点名的那一行",
//     是就画一层高亮并把自己滚进可见区。滚动走 AppKit 的 `NSView.scrollToVisible`(设置页的
//     ScrollView 底下就是 NSScrollView),不用给六个页面各挂 ScrollViewReader、也不用给一百多行
//     各写 `.id()`。
//
// 高亮拿**本地化后的标题字符串**相等来判,而不是给每一行发 id:调用点一行都不用改,代价是同一页上
// 两行同名会一起亮——目录按分段登记,同名行(三个面各有「对齐方式」)从不同时在屏,可接受。

// MARK: - 索引

struct SettingsSearchHit: Identifiable, Hashable {
    let entry: SettingsSearchEntry
    /// 当前语言下的标题(= 界面上那一行的 title),高亮就靠它相等。
    let title: String
    /// 标题随状态切换的行(菜单栏「文字颜色 / 未唱到的颜色」)的另外几种显示写法。
    let alternateTitles: [String]
    let subtitle: String?
    let breadcrumb: String
    /// 除标题外还能命中的全部文本。
    let secondary: [String]

    var id: String { entry.id }
    var highlightTitles: Set<String> { Set([title] + alternateTitles) }
}

@MainActor
final class SettingsSearchIndex {
    static let shared = SettingsSearchIndex()

    private var cached: (language: String, hits: [SettingsSearchHit])?
    private var tables: [String: [String: String]] = [:]

    func search(_ query: String) -> [SettingsSearchHit] {
        let all = hits()
        return SettingsSearchMatcher.ranked(all, query: query, title: { $0.title }, secondary: { $0.secondary })
    }

    private func hits() -> [SettingsSearchHit] {
        let language = L10n.current
        if let cached, cached.language == language { return cached.hits }
        let built = SettingsSearchCatalog.entries.map(localize)
        cached = (language, built)
        return built
    }

    private func localize(_ entry: SettingsSearchEntry) -> SettingsSearchHit {
        let title = L10n.t(entry.titleKey)
        let alternates = entry.alternateTitleKeys.map(L10n.t)
        let subtitle = entry.subtitleKey.map(L10n.t)
        let path = entry.pathKeys.map(L10n.t)
        var secondary: [String] = alternates + entry.keywords + path
        secondary.append(entry.titleKey)
        secondary.append(contentsOf: entry.alternateTitleKeys)
        secondary.append(contentsOf: entry.pathKeys)
        if let subtitle { secondary.append(subtitle) }
        // 其它两种语言的译文:界面是中文时也能打英文搜到,反过来也成立。
        for language in ["en", "zh-hant", "zh-hans"] where language != L10n.current {
            let table = stringsTable(language)
            for key in [entry.titleKey] + entry.alternateTitleKeys {
                if let translated = table[key] { secondary.append(translated) }
            }
        }
        return SettingsSearchHit(entry: entry, title: title, alternateTitles: alternates, subtitle: subtitle,
                                 breadcrumb: path.joined(separator: " › "), secondary: secondary)
    }

    /// 某个语言的 Localizable.strings 全表。跟 L10n.swift 找 bundle 的方式一致(目录名小写);
    /// `swift build` 直接跑、资源没打进 bundle 时拿到空表,搜索退化成只搜当前语言——不报错。
    private func stringsTable(_ language: String) -> [String: String] {
        if let table = tables[language] { return table }
        var table: [String: String] = [:]
        if let dir = Bundle.main.path(forResource: language, ofType: "lproj"),
           let dict = NSDictionary(contentsOfFile: dir + "/Localizable.strings") as? [String: String] {
            table = dict
        }
        tables[language] = table
        return table
    }
}

// MARK: - 路由(命中后的信号)

@MainActor
final class SettingsSearchRouter: ObservableObject {
    static let shared = SettingsSearchRouter()

    /// 正在高亮的行标题(本地化后)。行组件经 Environment 读它。
    @Published private(set) var highlightedTitles: Set<String> = []
    /// 待展开的「全部设置」抽屉;抽屉展开后调 `consumeDrawer` 清掉。
    @Published private(set) var pendingDrawer: LyricsSurface?

    private var clearHighlight: DispatchWorkItem?
    private var clearDrawer: DispatchWorkItem?

    /// 高亮停留多久。要盖住分段切换 + 抽屉展开动画(settingsCardReveal)+ 用户把目光挪过去的时间。
    static let highlightDuration: TimeInterval = 1.8

    func reveal(_ hit: SettingsSearchHit) {
        clearHighlight?.cancel()
        clearDrawer?.cancel()
        pendingDrawer = hit.entry.drawer
        highlightedTitles = hit.highlightTitles

        let highlightWork = DispatchWorkItem { [weak self] in self?.highlightedTitles = [] }
        clearHighlight = highlightWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDuration, execute: highlightWork)

        // 抽屉没接走(比如那一段没显示出来)也别让它悬着,下次正常打开那一段就会莫名展开。
        let drawerWork = DispatchWorkItem { [weak self] in self?.pendingDrawer = nil }
        clearDrawer = drawerWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: drawerWork)
    }

    func consumeDrawer(_ surface: LyricsSurface) {
        guard pendingDrawer == surface else { return }
        pendingDrawer = nil
        clearDrawer?.cancel()
    }
}

// MARK: - Environment

private struct SettingsSearchHighlightedTitlesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

private struct SettingsSearchPendingDrawerKey: EnvironmentKey {
    static let defaultValue: LyricsSurface? = nil
}

extension EnvironmentValues {
    /// 搜索命中后要高亮的行标题。只有设置窗口根部注入;别处默认空集,组件什么都不画。
    var settingsSearchHighlightedTitles: Set<String> {
        get { self[SettingsSearchHighlightedTitlesKey.self] }
        set { self[SettingsSearchHighlightedTitlesKey.self] = newValue }
    }

    /// 搜索命中后要展开的「全部设置」抽屉。
    var settingsSearchPendingDrawer: LyricsSurface? {
        get { self[SettingsSearchPendingDrawerKey.self] }
        set { self[SettingsSearchPendingDrawerKey.self] = newValue }
    }
}

// MARK: - 行高亮 + 滚进视野

/// 挂在 SettingsRow / SettingsSubRow / SettingsCardHeader 上:标题在被点名集合里就画一层高亮,
/// 同时把自己滚进可见区。`title` 为 nil(没标题的子行)时什么都不做。
struct SettingsSearchHighlight: ViewModifier {
    let title: String?
    @Environment(\.settingsSearchHighlightedTitles) private var highlightedTitles

    private var isHighlighted: Bool {
        guard let title, !title.isEmpty else { return false }
        return highlightedTitles.contains(title)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                    SettingsRevealInScrollView()
                }
            }
            // 只绑 isHighlighted:淡入淡出只跟高亮本身走,行里别的布局变化(开关联动长出一行)
            // 不会被顺带动起来。
            .animation(.easeOut(duration: 0.3), value: isHighlighted)
    }
}

extension View {
    func settingsSearchHighlight(title: String?) -> some View {
        modifier(SettingsSearchHighlight(title: title))
    }
}

/// 一进视图树就把宿主行滚进最近的 NSScrollView 可见区。做两次:立刻一次(行已经在屏就位),
/// 再过一个抽屉展开动画的时长一次(行是随抽屉长出来的,第一次时它的最终位置还没定)。
private struct SettingsRevealInScrollView: NSViewRepresentable {
    func makeNSView(context: Context) -> RevealView { RevealView() }
    func updateNSView(_ nsView: RevealView, context: Context) { nsView.scheduleReveal() }

    final class RevealView: NSView {
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReveal()
        }

        func scheduleReveal() {
            guard !scheduled, window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in self?.reveal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.reveal() }
        }

        private func reveal() {
            guard window != nil, enclosingScrollView != nil else { return }
            // 上下各留一截,别让目标行贴着可见区边缘。
            scrollToVisible(bounds.insetBy(dx: 0, dy: -72))
        }
    }
}

// MARK: - 搜索框与结果行

/// 侧栏顶部的搜索框。⌘F 聚焦;Esc 先清空、再按一次让出焦点;回车打开第一条结果。
///
/// 焦点状态由 SettingsView 持有再传进来(`FocusState<Bool>.Binding`),因为让出焦点的时机在它那边:
/// 用户点了侧栏别的分类、或打开了一条结果,光标就不该继续在这里闪(2026-09-09 用户实测提出)。
/// 窗口刚打开时它是键视图环里第一个文本框,AppKit 会默认把第一响应者给它——`onAppear` 里下一个
/// 运行环让掉,跟系统设置一致:搜索框没人碰就不闪光标。
struct SettingsSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.t("搜索设置"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .onSubmit(onSubmit)
                .onExitCommand {
                    if text.isEmpty { focused.wrappedValue = false } else { text = "" }
                }
                .onAppear {
                    // 初始第一响应者是窗口显示时同步指派的,这里晚一拍再让掉才生效。
                    DispatchQueue.main.async { focused.wrappedValue = false }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            // ⌘F 的落点。设置窗口是 accessory App 的 Settings scene,没有「编辑 → 查找」菜单可挂,
            // 用一个不可见的按钮接快捷键。
            Button("") { focused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// 侧栏里的一条搜索结果:标题 + 面包屑。整行可点。
struct SettingsSearchResultRow: View {
    let hit: SettingsSearchHit
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(hit.breadcrumb)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hit.title)
        .accessibilityValue(hit.breadcrumb)
    }
}
