import Combine
import LyrimuseCore
import SwiftUI

/// 「圆角 / 展开圆角」的哪一态。
enum NotchCornerSlot: Equatable {
    case collapsed
    case expanded
}

/// 卡片底部圆角此刻按哪两个设置画(存盘值的含义同 `AppSettings.notchCornerRadius`)。
///
/// 平时跟 AppSettings 里那两个设置一致,从哪条路改的都跟上(菜单里的两个模式、恢复默认、导入配置)。
/// 拖滑杆的过程中是滑杆上的值,松手(`endDrag`)才写回 AppSettings —— 拖动中别直接写 AppSettings:它每变一次
/// 都会打醒所有观察它的界面(整页设置、编辑台、菜单栏面板、别的窗口)并写一次 UserDefaults,滑杆一格一卡。
///
/// 只有画卡片外形的那几层观察这里(`NotchCardOutlineReader`、`NotchCardClip`、`NotchRevealClip`),拖动时只重画外形、
/// 卡片内容不重算。真窗口和编辑台读的是同一份,拖的时候两边一起变。
@MainActor
final class NotchCornerLive: ObservableObject {
    static let shared = NotchCornerLive()

    @Published private(set) var collapsed: Double
    @Published private(set) var expanded: Double
    /// 正按着哪一态的滑杆(nil = 没在拖)。
    @Published private(set) var adjusting: NotchCornerSlot?
    /// 指针正停在哪一态的那一行上(nil = 都不在)。
    @Published private(set) var hovered: NotchCornerSlot?

    /// 编辑台预览此刻该摆成哪一态:正拖着的那一态优先,其次指针所在的那一行;nil = 交还给预览自己(`NotchPreviewChrome.isExpanded`)。
    var focusPublisher: AnyPublisher<NotchCornerSlot?, Never> {
        Publishers.CombineLatest($adjusting, $hovered).map { $0 ?? $1 }.removeDuplicates().eraseToAnyPublisher()
    }

    private var collapsedObserver: AnyCancellable?
    private var expandedObserver: AnyCancellable?

    private init() {
        let settings = AppSettings.shared
        collapsed = settings.notchCornerRadius
        expanded = settings.notchExpandedCornerRadius
        // 两态各订各的:一个设置变了只改自己那一态,不会把另一态正拖着的值盖回去。存 sink 参数值(@Published 在 willSet 发布)。
        collapsedObserver = settings.$notchCornerRadius.removeDuplicates().sink { [weak self] value in
            guard let self, self.collapsed != value else { return }
            self.collapsed = value
        }
        expandedObserver = settings.$notchExpandedCornerRadius.removeDuplicates().sink { [weak self] value in
            guard let self, self.expanded != value else { return }
            self.expanded = value
        }
    }

    func value(_ slot: NotchCornerSlot) -> Double {
        switch slot {
        case .collapsed: return collapsed
        case .expanded: return expanded
        }
    }

    func beginDrag(_ slot: NotchCornerSlot) {
        if adjusting != slot { adjusting = slot }
    }

    /// 指针进出某一态的那一行。离开时只清自己:相邻那一行的「进」可能先到。
    func hover(_ slot: NotchCornerSlot, inside: Bool) {
        if inside {
            if hovered != slot { hovered = slot }
        } else if hovered == slot {
            hovered = nil
        }
    }

    func clearHover() {
        if hovered != nil { hovered = nil }
    }

    /// 拖动中的一格:只改这里,不写 AppSettings。
    func drag(_ slot: NotchCornerSlot, to value: Double) {
        beginDrag(slot)
        switch slot {
        case .collapsed: if collapsed != value { collapsed = value }
        case .expanded: if expanded != value { expanded = value }
        }
    }

    /// 松手:把正在拖的那一态写回 AppSettings。
    func endDrag() {
        guard let slot = adjusting else { return }
        adjusting = nil
        let settings = AppSettings.shared
        switch slot {
        case .collapsed:
            if settings.notchCornerRadius != collapsed { settings.notchCornerRadius = collapsed }
        case .expanded:
            if settings.notchExpandedCornerRadius != expanded { settings.notchExpandedCornerRadius = expanded }
        }
    }
}

/// 卡片外形要的几何:刘海高、两种形态的卡片高度、此刻是否展开(chrome 的 `cardOutline`)。两个圆角设置不在这里,
/// 画的时候从 `NotchCornerLive` 取。
struct NotchCardOutline: Equatable {
    var notchHeight: CGFloat
    var collapsedHeight: CGFloat
    var expandedHeight: CGFloat
    var isExpanded: Bool

    @MainActor
    func corner(_ live: NotchCornerLive) -> NotchCornerProfile? {
        NotchOutline.cornerProfile(collapsedSetting: live.collapsed, expandedSetting: live.expanded,
                                   collapsedHeight: collapsedHeight, expandedHeight: expandedHeight,
                                   notchHeight: notchHeight, isExpanded: isExpanded)
    }

    @MainActor
    func shape(_ live: NotchCornerLive) -> NotchHangingShape {
        .card(notchHeight: notchHeight, corner: corner(live))
    }
}

/// 按 `NotchCornerLive` 此刻的两个设置拼出卡片外形交给 `content`(纯色底、编辑台虚线框用)。
/// 圆角变时只重算这一小块。
struct NotchCardOutlineReader<Content: View>: View {
    var outline: NotchCardOutline
    var content: (NotchHangingShape) -> Content
    @ObservedObject private var live = NotchCornerLive.shared

    init(outline: NotchCardOutline, @ViewBuilder content: @escaping (NotchHangingShape) -> Content) {
        self.outline = outline
        self.content = content
    }

    var body: some View {
        content(outline.shape(live))
    }
}
