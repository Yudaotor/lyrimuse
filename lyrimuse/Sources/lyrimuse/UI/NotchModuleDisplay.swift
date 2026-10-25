import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

extension NotchEarModule {
    /// 不能存成 `static let`/常量字典:`L10n.t` 要在每次取值时现算,存进去等于把首次访问
    /// 时的语言冻在里面(同 OverlayAlignmentSegmentedControl.label(for:) 那条)。
    var displayName: String {
        switch self {
        case .title: return L10n.t("歌名")
        case .artist: return L10n.t("歌手")
        case .album: return L10n.t("专辑")
        case .artwork: return L10n.t("封面")
        case .controls: return L10n.t("播放控制")
        case .elapsed: return L10n.t("已播时长")
        case .remaining: return L10n.t("剩余时长")
        case .playCount: return L10n.t("收听次数")
        case .player: return L10n.t("播放器")
        case .none: return L10n.t("不显示")
        }
    }

    /// 这个模块要不要每秒重算一次(时间类才要)。用它把 TimelineView 圈在真正需要的那一格里:顶行别的模块不随播放进度重绘,
    /// 给它们也套一个周期时钟纯属白付。
    var isClock: Bool { self == .elapsed || self == .remaining }

    /// 这个模块塞进一只耳朵里最少要多宽。不含朝刘海那侧的 `earNotchInset`,也不含右耳外缘那簇音浪,那两样由
    /// `NotchLyricsWindowController.minEarWidth(...)` 加。
    ///
    /// 判据是"再窄就真的被裁",不是"再窄就不好看"。宽度滑杆的下界完全按它算(`NotchLyricsWindowController.contentWidth`),
    /// 往上多给一个 pt 就是替用户把岛的下限抬高一个 pt。
    ///
    /// 歌名 / 歌手 / 专辑给 0,这是有意的:它们跑马灯,窄了只是滚得更勤、再窄就是什么都不显示,不会坏,所以不该参与决定下限。
    /// 别给 24pt("可读窗口还剩两个汉字"),那是拿"好看"当"会坏"用,会把默认配置(歌名/歌手)的下界钉在 300pt,而 300pt 下那两个
    /// 词旁边明显还空着。给 0 之后,默认配置的下界落到跟「不显示/不显示」同一个数,下限完全由右耳外缘那簇音浪撑着。代价:拖到最底
    /// 那一格,右耳的文字会被音浪挤成 0 宽(左耳还剩 20pt 在滚),这是滑杆上肉眼可见的连续过程,想要文字就往回拖两格。
    ///
    /// 剩下三类是真的会被裁的,数字都是离屏实测:
    ///   - 三键 = 命中框 15 + 18 + 15,`spacing: 0`(见 `earControls` 的横向账)= 48
    ///   - 时间 = 11.5pt 等宽数字下 "-12:34" / "-88:88" 实测 39.0
    ///   - 封面 = `NotchMetrics.earArtworkSide` 现算,不给估计值(菜单栏 32 时 22pt)
    func minEarContentWidth(contentTopInset: CGFloat) -> CGFloat {
        switch self {
        case .none, .title, .artist, .album: return 0
        case .controls: return 48
        case .artwork: return NotchMetrics.earArtworkSide(contentTopInset: contentTopInset)
        // 时间**不能**靠跑马灯兜底 —— 一秒一跳的数字滚起来根本读不了,所以这一档必须
        // 真的放得下。超过一小时的曲目("-1:23:45" 实测 50.1pt)在最窄处仍会滚:那是极少数,
        // 不值得为它把所有人的下限再抬 11pt。
        case .elapsed, .remaining: return 39
        case .playCount: return NotchEarPlayCount.minWidth
        case .player: return NotchMetrics.earAppIconSide(contentTopInset: contentTopInset)
        }
    }

    /// 主要信息给 semibold + 更高不透明度,次要信息压一档。**样式跟着模块走、不跟着哪只耳朵走**:
    /// 把歌名换到右耳时它还是那个最显眼的东西,不会因为换了个位置就变次要。
    /// (这也正是改动前的样子:左耳歌名 semibold/0.85、右耳歌手 medium/0.6。)
    var isPrimary: Bool { self == .title }
}

extension NotchLyricRowArtworkPosition {
    var displayName: String {
        switch self {
        case .left: return L10n.t("左")
        case .right: return L10n.t("右")
        }
    }
}

extension LyricSecondaryLine {
    /// 「副行」四选一在设置页里的标签。「不显示 / 译文 / 罗马音」三个词跟悬浮歌词那边同键复用,
    /// 只有「下一句」是新键。
    var displayName: String {
        switch self {
        case .off: return L10n.t("不显示")
        case .nextLine: return L10n.t("下一句")
        case .translation: return L10n.t("译文")
        case .romanization: return L10n.t("读音")
        }
    }
}

extension NotchCardStyle {
    var displayName: String {
        switch self {
        case .solidBlack: return L10n.t("纯黑")
        case .frostedGlass: return L10n.t("毛玻璃")
        case .darkGradient: return L10n.t("深色渐变")
        case .coverArt: return L10n.t("跟随封面")
        }
    }

    // .coverArt 的真实渲染(封面模糊图)是在 NotchLyricsView.backgroundLayer 里单独
    // 处理的,这里给它的只是"没有封面数据时的兜底":纯黑,跟机器刘海融成一块。不代表
    // .coverArt 的实际效果,不要在其它地方依赖这条分支来渲染 .coverArt。
    //
    // 三种都是不套形状的整块视图,圆角交给外层那道统一的裁剪:形状填充是 CG 路径光栅化,卡片每变一次尺寸
    // 就重画整卡;纯色、渐变、材质视图尺寸变了只改图层边界(05 章决策 98)。
    @ViewBuilder
    var backdrop: some View {
        switch self {
        case .solidBlack, .coverArt:
            Color.black
        case .frostedGlass:
            Rectangle().fill(.thickMaterial)
        case .darkGradient:
            // 从左上到右下过渡,比纯黑多一点点冷色调层次感,又不像磨砂玻璃那样会透出
            // 桌面背景色。
            LinearGradient(
                colors: [
                    Color(hexWithAlpha: "#1C1A24FF", fallback: .black),
                    Color(hexWithAlpha: "#14212AFF", fallback: .black),
                    Color(hexWithAlpha: "#10161CFF", fallback: .black),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
