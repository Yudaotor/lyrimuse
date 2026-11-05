import AppKit
import SwiftUI
import LyrimuseCore

// 菜单栏面板钮块网格的编辑零件:编辑时每格外面那一层(「−」、右下角拉手、悬停)、空坑位、小标题。格子本身(KnobTile)
// 和每一格接什么动作在 MenuBarPanel.swift;坑位、落点、换尺寸的规则在 Core 的 `MenuBarPanelLayout` / `PanelGridGeometry`。
// 见 06 章决策 84。

private struct PanelTileSizeKey: EnvironmentKey {
    static let defaultValue = MenuBarPanelLayout.Size.medium
}

private struct PanelTileEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 格子按哪一档画(小、中:图标在上、名字在下;大:图标在左上、名字在左下)。
    var panelTileSize: MenuBarPanelLayout.Size {
        get { self[PanelTileSizeKey.self] }
        set { self[PanelTileSizeKey.self] = newValue }
    }

    /// 在编辑布局:格子不接点按 / 长按(手势归编辑那一层的拖动和角标)。
    var panelTileEditing: Bool {
        get { self[PanelTileEditingKey.self] }
        set { self[PanelTileEditingKey.self] = newValue }
    }
}

/// 格子的圆角,三档一样:跟右下角那道拉手的弧同心(弧半径 + 离边距离),拉手才贴着格子的圆角走,同控制中心。
let panelTileCornerRadius: CGFloat = PanelResizeCorner.radius + PanelResizeCorner.inset

extension MenuBarPanelLayout.Size {
    var panelName: String {
        switch self {
        case .small: return L10n.t("小")
        case .medium: return L10n.t("中")
        case .large: return L10n.t("大")
        case .wide: return L10n.t("加宽")
        case .bar: return L10n.t("长条")
        }
    }
}

/// 编辑时套在一格外面的那一层:左上「−」,悬停时右下角露出一道弧形拉手(同控制中心),拖它换尺寸。
/// 悬停状态存在这一格自己身上:存在面板上的话,指针每划过一格整块面板都要重算一遍。
/// `onHover` 挂在最外层(连拉手一起算):挂在内容上的话,指针一挪到拉手上内容就报「离开」,拉手跟着藏起来、点不到。
struct PanelEditableTile<Content: View>: View {
    let content: Content
    let cornerRadius: CGFloat
    /// 正在拖这一格的拉手(拖动中指针离开格子,拉手也留着)。
    let resizing: Bool
    let remove: () -> Void
    let resizeGesture: AnyGesture<Void>
    @State private var hovering = false

    var body: some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                PanelEditBadge(symbol: "minus", tint: Color(nsColor: .systemGray), label: L10n.t("移除"), action: remove)
                    .offset(x: -4, y: -4)
            }
            .overlay(alignment: .bottomTrailing) {
                PanelResizeCorner(cornerRadius: cornerRadius, visible: hovering || resizing, resizing: resizing)
                    .gesture(resizeGesture)
            }
            .onHover { hovering = $0 }
    }
}

/// 右下角那道弧形拉手,同控制中心编辑时那一道:贴着右下角的一整段四分之一圆弧(半径 22、离边 4、线宽 5,白色带一点影),
/// 整块 34pt 见方都能按。指针停在上面、按住拖动的全程都是斜向拉伸的指针(`PanelResizeCursor`)。
/// 藏起来时只把弧线调透明,可按的那块一直在:整个视图透明度为 0 时 SwiftUI 不再把点击交给它。
struct PanelResizeCorner: View {
    let cornerRadius: CGFloat
    let visible: Bool
    /// 正在拖这道拉手:拖动中指针离开了拉手,指针也保持拉伸的样子。
    let resizing: Bool
    @State private var hovering = false
    @State private var token = PanelResizeCursor.Token()

    /// 可按的那一块边长。网格那一层按它认按下的是不是拉手(`gridResizeGesture`)。
    static let side: CGFloat = 34
    static let radius: CGFloat = 22
    static let inset: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width - Self.inset - Self.radius, y: size.height - Self.inset - Self.radius)
            var path = Path()
            path.addArc(center: center, radius: Self.radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
        .opacity(visible ? 1 : 0)
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        // 每次移动都重设一次:指针在这一块里移动时 AppKit 会按窗口的光标区把它换回箭头,只在进来那一下设会闪。
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                PanelResizeCursor.hold(token, true)
            case .ended:
                hovering = false
                PanelResizeCursor.hold(token, resizing)
            }
        }
        .onChange(of: resizing) { _, now in PanelResizeCursor.hold(token, now || hovering) }
        .onDisappear { PanelResizeCursor.hold(token, false) }
        .accessibilityHidden(true)
    }
}

/// 面板拉手的斜向拉伸指针。几个拉手共用一份:按持有方记,从一格的拉手直接移到另一格时不会被前一格先换回箭头。
/// 持有期间每 0.05 秒重设一次,App 在后台时靠 `BackgroundCursor` 才设得上 —— 面板是不激活 App 的窗口,前台 App
/// 重绘、窗口的光标区都会把指针换回去,只设一次会一闪一闪。
@MainActor
enum PanelResizeCursor {
    final class Token {}

    private static var holders: Set<ObjectIdentifier> = []
    private static var timer: Timer?
    private static let owner = Token()

    /// 斜向拉伸的指针 macOS 15 起才有,更早的系统用十字。
    static var cursor: NSCursor {
        if #available(macOS 15.0, *) { return NSCursor.frameResize(position: .bottomRight, directions: .all) }
        return .crosshair
    }

    static func hold(_ token: Token, _ on: Bool) {
        let wasOn = !holders.isEmpty
        if on { holders.insert(ObjectIdentifier(token)) } else { holders.remove(ObjectIdentifier(token)) }
        let isOn = !holders.isEmpty
        if isOn { cursor.set() }
        guard isOn != wasOn else { return }
        BackgroundCursor.setEnabled(isOn, for: ObjectIdentifier(owner))
        timer?.invalidate()
        timer = nil
        if isOn {
            let t = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { cursor.set() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// 把网格给这一格的档位和在不在编辑交给内容(正在播放卡按档位换画法,编辑时不接点击)。
struct PanelTileSizeReader<Content: View>: View {
    @Environment(\.panelTileSize) private var size
    @Environment(\.panelTileEditing) private var editing
    let content: (MenuBarPanelLayout.Size, Bool) -> Content

    init(@ViewBuilder content: @escaping (MenuBarPanelLayout.Size, Bool) -> Content) {
        self.content = content
    }

    var body: some View { content(size, editing) }
}

/// 编辑时空着的坑位:一块淡淡的格子(同控制中心编辑时的空位)。
struct PanelEmptyCell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: panelTileCornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .accessibilityHidden(true)
    }
}

/// 编辑时压在格子角上的圆形小键:移除(−)、添加(+)。
struct PanelEditBadge: View {
    let symbol: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 编辑页里「可添加」「底栏」这类小标题。
struct PanelEditCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

extension MenuBarPanelLayout.TileGroup {
    var panelTitle: String {
        switch self {
        case .nowPlaying: return L10n.t("正在播放")
        case .overlay: return L10n.t("悬浮歌词")
        case .notch: return L10n.t("灵动岛歌词")
        case .menuBar: return L10n.t("菜单栏歌词")
        case .lyricsWindow: return L10n.t("歌词窗口")
        case .touchBar: return L10n.t("触控栏歌词")
        case .lyrics: return L10n.t("歌词")
        }
    }
}

/// 编辑时主面板和左边「可添加」那块面板之间的连线。两扇窗各是一份 `MenuBarPanelView`:左边那份点一格直接写设置,
/// 拖一格时把指针的屏幕坐标交给主面板那份,由它按自己网格的挤位排、松手落定。
@MainActor
final class PanelEditBridge {
    static let shared = PanelEditBridge()
    weak var mainWindow: NSWindow?
    weak var galleryWindow: NSWindow?
    /// 控制器挂上:进 / 出编辑时开关左边那块面板。
    var setGalleryVisible: ((Bool) -> Void)?
    /// 主面板编辑页挂上:左边拖着一格到了屏幕上哪儿(nil = 松手)。
    var galleryDrag: ((MenuBarPanelLayout.Tile, CGPoint?) -> Void)?
    /// 主面板此刻在平时那一页(空格、方向键归 `PanelPlaybackKeys`);编辑、快捷设置、简介页里是 false。
    var playbackKeysEnabled = false
}

extension MenuBarPanelLayout.FooterItem {
    var panelTitle: String {
        switch self {
        case .settings: return L10n.t("设置")
        case .lastfm: return "Last.fm"
        case .discord: return "Discord"
        case .version: return L10n.t("版本号")
        case .shortcuts: return L10n.t("快捷键")
        case .website: return L10n.t("官网")
        case .whatsNew: return L10n.t("查看本次更新…")
        case .feedback: return L10n.t("反馈问题…")
        case .about: return L10n.t("关于 Lyrimuse")
        case .quit: return L10n.t("退出 Lyrimuse")
        }
    }

    /// 底栏和编辑时那几处画的符号(Last.fm 平时画品牌图,这里是没有品牌图时的退路)。
    var panelSymbol: String {
        switch self {
        case .settings: return "gearshape"
        case .lastfm: return "dot.radiowaves.left.and.right"
        case .discord: return "bubble.left.and.bubble.right"
        case .version: return "info.circle"
        case .shortcuts: return "command"
        case .website: return "globe"
        case .whatsNew: return "newspaper"
        case .feedback: return "exclamationmark.bubble"
        case .about: return "info.square"
        case .quit: return "rectangle.portrait.and.arrow.right"
        }
    }
}
