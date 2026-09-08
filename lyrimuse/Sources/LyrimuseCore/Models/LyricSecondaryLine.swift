import Foundation

/// 歌词「副行」:主歌词下面再放一行,内容四选一。
///
/// 2026-09-06 先为灵动岛做(用户拍板方案二,05 章决策 24),同日菜单栏歌词也接了同一套(用户从五档
/// HTML 对比里选了 B 方案,06 章决策 27),于是从 `NotchSecondaryLine` 改成这个通用名 —— 两个展示面
/// **同一个枚举、同一条取值规则**(`secondaryText(currentLine:nextLineText:)`),设置各存各的键
/// (`np:notchSecondaryLine` / `np:menuBarSecondaryLine`),默认值也各自定(灵动岛默认下一句、
/// 菜单栏默认不显示 —— 菜单栏开副行要把主行从 13pt 压到 10pt,是硬代价,按需开)。
///
/// 灵动岛:行高恒为 44pt,不随选项变 —— 两行(13pt 主行 + 11pt 副行 + 3pt 间距 = 31pt,见
/// `NotchLyricRowMetrics`)本来就塞得进去。所以这一项走 `NotchPlayback` 现读、不进 `NotchChromeSource`
/// 的几何链路:它不影响卡片任何一个尺寸。被否掉的另一条路(方案一:照悬浮歌词叠行,最多四行,行高
/// 44 / 58 / 74 按设置变)记在 05 章决策 22 —— 用户要的是"提前看到下一行",又不想灵动岛变高,一条
/// 副行三选一正好;代价是译文和下一句不能同时看,他接受。
///
/// 菜单栏:状态栏项按钮恒 22pt,两行字号由行高推出(主 10 / 副 9,见 `MenuBarLyricRows`),字号滑杆在
/// 双排下不生效;副行不滚、装不下尾部渐隐,主行照常滚动 / 卡拉OK染色。
///
/// 两个面共同的语义:副行开着时主行显示**正在唱的那一句**(`currentLine`,悬浮歌词语义),关着时照旧
/// `compactLine`(唱完就切、提前亮出下一句)—— 副行的译文 / 罗马音是"这一句"的、下一句是"这一句的下一
/// 句",主行若还按提前量抢跑,副行就跟主行对不上号。
///
/// ⚠️ rawValue 直接落 UserDefaults,改名就是改存量用户的配置,别动。
public enum LyricSecondaryLine: String, CaseIterable, Sendable {
    case off
    case nextLine
    case translation
    case romanization

    /// 副行那一行到底画不画 —— `.off` 时歌词行回到改动前"一行"的排法,逐像素不变。
    public var showsSecondaryRow: Bool { self != .off }

    /// 副行要显示的文字:下一句 / 当前句译文 / 当前句罗马音,首尾空白剔掉、空的算没有(nil)。
    /// 灵动岛(`NotchPlayback.secondaryText`)和菜单栏(`MenuBarStatusItem.refresh`)都调这一份,
    /// 两处各写一遍 switch 迟早漂开(比如一边 trim 一边不 trim)。
    public func secondaryText(currentLine: SyncedLyricLine?, nextLineText: String?) -> String? {
        let raw: String?
        switch self {
        case .off: raw = nil
        case .nextLine: raw = nextLineText
        case .translation: raw = currentLine?.translation
        case .romanization: raw = currentLine?.romanization
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - 灵动岛专用

    /// 展开区那行「下一句歌词预览」(`notchExpandedShowsNextLine`)在这个选项下是否被顶掉:
    /// 副行已经常显下一句时,hover 展开再画一行同一句是重复,所以强制不画。`nextLine` 以外的
    /// 选项(译文 / 罗马音 / 不显示)副行里没有下一句,展开区那行照旧由用户开关决定。
    /// (菜单栏没有展开区,用不到这两个。)
    public var hidesExpandedNextLinePreview: Bool { self == .nextLine }

    /// 展开区「下一句歌词预览」最终画不画的**唯一**判据:用户开关 && 没被副行顶掉。
    /// 真窗口(`NotchLyricsWindowController`)和设置页替身(`NotchPreviewChrome`)都调这一份,
    /// 两处各自写一遍 `&&` 迟早漂开(05 章「两处各自判断必然漂」那条纪律)。
    public static func expandedNextLinePreviewVisible(userToggle: Bool, secondary: LyricSecondaryLine) -> Bool {
        userToggle && !secondary.hidesExpandedNextLinePreview
    }
}

/// 灵动岛稳态歌词行(`NotchMetrics.compactRowHeight` 那 44pt)里两行文字的度量。放在 Core 是为了让
/// selftest 能钉住"两行加间距 ≤ 行高"这条不变量 —— 一旦有人把副行字号调大到塞不下,卡片高度公式
/// (`cardHeight`)就得多一个入参,那正是方案二刻意绕开的整片雷区(编辑台舞台常量、出场动画、
/// 展开区高度上限都挂在它下面),必须在 selftest 里红出来而不是真机上裁字。
/// 菜单栏那一套度量在 `MenuBarLyricRows`(按钮 22pt,约束完全不同,不共用)。
public enum NotchLyricRowMetrics {
    /// 稳态歌词行的高度。App 侧 `NotchMetrics.compactRowHeight` 转发这个值。
    public static let rowHeight: CGFloat = 44
    /// 主行字号。2026-09-09 起用户可调(设置页灵动岛「字体」组,`AppSettings.notchFontSize`):默认 13 = 加这组
    /// 设置之前的硬编码,范围 11…17。**上限是倒推出来的,不是拍的**:最大字号下两行 + 间距仍要塞进 `rowHeight`
    /// 且上下各留 ≥ 4pt(17 → 19 + 3 + 13 = 35,余 4.5),selftest 钉着这条不变量;想放宽范围先过那条闸。
    public static let defaultMainFontSize: CGFloat = 13
    public static let mainFontSizeRange: ClosedRange<CGFloat> = 11...17
    /// 副行(以及展开区那行「下一句」预览)的字号,**不随主行字号变**。不跟着放大是为了让主行的字号范围不依赖
    /// 「副行」开没开 —— 否则就得像菜单栏那样在副行开着时让字号失效(「由副行决定」),用户调好的值会因为翻了
    /// 另一个开关而自己变。副行只跟主行的字体族与粗细(细一档,`OverlayFontWeight.notchSecondarySteps`)。
    public static let secondaryFontSize: CGFloat = 11
    /// 一行文字给多高:字号 + 2。13pt 主行 = 15、11pt 副行 = 13,正是 2026-09-06 方案二定下的那两个数,默认字号下
    /// 逐像素不变。系统字体 13pt 的自然行高约 15.5,+2 是"够放、不留空"的最小整数;别的字体族上下伸展可能更大
    /// (PingFang 一类),两行会显得略挤但不裁切 —— `.frame(height:)` 不裁内容。
    public static func lineHeight(fontSize: CGFloat) -> CGFloat { fontSize.rounded() + 2 }
    /// 主行那一格的高度,按**夹回范围后的**字号算 —— 存量配置被手改成越界值时,行高也不能跟着越界。
    public static func mainLineHeight(fontSize: CGFloat) -> CGFloat {
        lineHeight(fontSize: clampedMainFontSize(fontSize))
    }
    /// 默认字号下的主行高度(15),给不关心字号的调用点和 selftest 用。
    public static var mainLineHeight: CGFloat { mainLineHeight(fontSize: defaultMainFontSize) }
    /// 副行一行文字的高度(13)。
    public static var secondaryLineHeight: CGFloat { lineHeight(fontSize: secondaryFontSize) }
    /// 主行与副行之间的间距。
    public static let lineSpacing: CGFloat = 3
    /// 副行开着时两行叠起来的总高度,竖直居中放进 `rowHeight`(默认字号下 15 + 3 + 13 = 31,上下各余 6.5)。
    public static func twoLineStackHeight(fontSize: CGFloat) -> CGFloat {
        mainLineHeight(fontSize: fontSize) + lineSpacing + secondaryLineHeight
    }
    public static var twoLineStackHeight: CGFloat { twoLineStackHeight(fontSize: defaultMainFontSize) }
    /// 越界字号夹回 `mainFontSizeRange`(rawValue 被手改坏 / 从别的 Mac 抄来的配置)。
    public static func clampedMainFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, mainFontSizeRange.lowerBound), mainFontSizeRange.upperBound)
    }
}
