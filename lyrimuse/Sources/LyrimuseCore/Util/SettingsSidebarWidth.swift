import AppKit

/// 设置窗的侧栏要多宽,才放得下当前语言里每一行的文字(不出省略号)。
///
/// 各类行文字前后占的宽度是照 `List(.sidebar)` 实测的(系统「侧栏图标大小」中档):行左右各留 16pt;20pt 图标的行
/// 文字从 40pt 起;状态图标 15pt,离文字 6pt;计数徽标最窄 18pt;身份区 36pt 头像那一行文字从 62pt 起。「大」档图标行
/// 文字换成 15pt、从 44pt 起,状态图标 18pt。间距跟各行视图里的 HStack 一一对应(`SettingsView.sidebarLabel`、
/// `AccountSidebarRow`、`SoftwareUpdateSidebarRow`、`LastfmIdentityRow`),改了那边这里一起改。见 14 章决策 58。
public enum SettingsSidebarWidth {
    public enum Row: Equatable {
        /// 20pt 图标 + 文字:六个分类、「关联平台」。
        case label(String)
        /// 图标 + 文字 + 行尾计数徽标:有健康警告时的「播放器」。
        case labelWithBadge(String)
        /// 图标 + 文字 + 状态图标:「实验室功能」里的账号。
        case account(String)
        /// 13pt 文字 + 行尾计数徽标,没有图标:「有软件更新可用」「Last.fm 账号建议」。
        case badge(String)
        /// 身份区标题,15pt 半粗。
        case identityTitle(String)
        /// 身份区副标题,12pt。
        case identitySubtitle(String)
    }

    /// 下限:中文这几行都放得下,宽度照这个。
    public static let designWidth: CGFloat = 205
    /// 能拖到的最宽;放得下要的宽度比它还宽时,侧栏就固定在那个宽度。
    public static let designMaxWidth: CGFloat = 240
    /// 侧栏拉到最宽时右边内容区至少留这么宽:灵动岛编辑台的舞台 = 内容区 − 40,要 ≥ 499(NotchEditorStage 工具栏那段
    /// 横向账是按 499 量的,再窄四个入口的标题会被截)。
    public static let minDetailWidth: CGFloat = 540
    /// 系统「侧栏图标大小」的全局偏好:1 小 / 2 中 / 3 大,没设过读到 0(中档)。
    public static let sizeModeDefaultsKey = "NSTableViewDefaultSizeMode"

    /// 侧栏能拖到的最宽:fitting 的结果比 designMaxWidth 还宽时就是它本身。
    public static func maxWidth(_ width: CGFloat) -> CGFloat { max(width, designMaxWidth) }

    /// 设置窗最窄多宽:侧栏拉到最宽 + minDetailWidth(中文 780、英文 790)。
    public static func windowMinWidth(_ width: CGFloat) -> CGFloat { maxWidth(width) + minDetailWidth }

    /// 侧栏上一次按哪个默认宽度排的。不用 `np:` 前缀:那是配置导出的白名单,这是这台机器上的界面状态,不该跟着配置搬家。
    public static let lastDefaultWidthKey = "settings:sidebarDefaultWidth"

    /// 侧栏该放回的宽度:默认宽度(切界面语言、系统「侧栏图标大小」换档会变)跟上一次记下的不一样时是新的默认宽度;
    /// 一样、或者还没记过时是 nil(不动,用户拖出来的宽度照旧)。
    public static func widthToRestore(lastDefault: CGFloat?, currentDefault: CGFloat) -> CGFloat? {
        guard let lastDefault, lastDefault != currentDefault else { return nil }
        return currentDefault
    }

    /// 放得下 rows 里每一行的宽度,不低于 designWidth。sizeMode 是 sizeModeDefaultsKey 的值;小档按中档算(只会宽一点)。
    public static func fitting(_ rows: [Row], sizeMode: Int) -> CGFloat {
        let large = sizeMode == 3
        let labelFont = NSFont.systemFont(ofSize: large ? 15 : 13)
        let iconLead: CGFloat = large ? 44 : 40
        let indicator: CGFloat = large ? 18 : 15
        var needed: CGFloat = 0
        for row in rows {
            let width: CGFloat
            switch row {
            case .label(let text):
                width = iconLead + textWidth(text, labelFont)
            case .labelWithBadge(let text):
                width = iconLead + textWidth(text, labelFont) + 6 + minSpacer + 6 + badgeWidth
            case .account(let text):
                width = iconLead + textWidth(text, labelFont) + 6 + indicator
            case .badge(let text):
                width = edge + textWidth(text, .systemFont(ofSize: 13)) + 8 + minSpacer + 8 + badgeWidth
            case .identityTitle(let text):
                width = identityLead + textWidth(text, .systemFont(ofSize: 15, weight: .semibold))
            case .identitySubtitle(let text):
                width = identityLead + textWidth(text, .systemFont(ofSize: 12))
            }
            needed = max(needed, width + edge)
        }
        return max(designWidth, (needed + slack).rounded(.up))
    }

    private static let edge: CGFloat = 16
    private static let identityLead: CGFloat = 62
    private static let badgeWidth: CGFloat = 18
    private static let minSpacer: CGFloat = 4
    /// 这样算出来的文字宽度跟 SwiftUI 排出来的差不到 0.1pt;留 2pt,别让最长那一行卡在出省略号的边上。
    private static let slack: CGFloat = 2

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
