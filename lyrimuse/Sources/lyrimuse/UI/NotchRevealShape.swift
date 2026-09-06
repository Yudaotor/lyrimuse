import LyrimuseCore
import SwiftUI

/// 出场动画每一帧的三个量:可见宽度比例、可见高度比例、内容透明度。`settled` = 终态(全露、内容全显),
/// 也是 keyframeAnimator 的 initialValue —— 视图第一次出现时不播、trigger 变了才从起始态长起(见 NotchWindowRoot)。
struct NotchRevealState {
    var widthFraction: CGFloat
    var heightFraction: CGFloat
    var contentOpacity: Double

    static let settled = NotchRevealState(widthFraction: 1, heightFraction: 1, contentOpacity: 1)
}

/// 出场动画用的裁剪形状:卡片顶部居中的一块「挂着的胶囊」—— 宽 = 卡宽 × widthFraction、高 = 卡高 ×
/// heightFraction、顶边贴刘海、底部两角圆角(半径随可见高度收:矮的时候是半圆,长满时回到卡片自己的 20)。
/// 终态 (1, 1) 与 `NotchLyricsView` 自己那道 `NotchHangingShape(bottomCornerRadius: 20)` 完全重合 —— 所以
/// 2026-09-06 起真窗口里**只留这一道**:`NotchWindowRoot` 通过环境值 `notchHostClipsCard` 让卡片自己那道
/// 不再裁(两层同形状的 mask 在尺寸动画里每帧各重设一次路径,是白付的),平时这道裁剪就是卡片的外形。
///
/// 用 clipShape 而不是 mask:mask 要把整卡渲染成一张离屏纹理再合成,而这扇窗口播放期间逐字高亮每帧都在
/// 重绘,常驻多一道离屏就是每帧的税;clipShape 是路径裁剪,常驻成本可忽略。也**不能**在动画结束后换成
/// "不裁剪"的另一个分支 —— 分支切换会让 SwiftUI 重建 NotchLyricsView、丢掉它的全部 @State(跑马灯位置等)。
struct NotchRevealShape: Shape {
    var widthFraction: CGFloat
    var heightFraction: CGFloat

    static let bottomCornerRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(1, max(0, widthFraction))
        let height = rect.height * min(1, max(0, heightFraction))
        let visible = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        // NotchHangingShape 自己会把圆角半径夹到 min(r, w/2, h/2),矮的时候自然是半圆底。
        return NotchHangingShape(bottomCornerRadius: Self.bottomCornerRadius).path(in: visible)
    }
}

private struct NotchRevealContentOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private struct NotchHostClipsCardKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NotchCardLayerActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 出场动画期间内容(顶行 / 歌词行 / 展开区)的透明度,背景不受影响 —— 先看到卡片形状长出来,再看到字。
    /// 默认 1;只有 `NotchWindowRoot` 在动画那 0.3s 里改它,设置页编辑台等别的宿主永远是 1。
    var notchRevealContentOpacity: Double {
        get { self[NotchRevealContentOpacityKey.self] }
        set { self[NotchRevealContentOpacityKey.self] = newValue }
    }

    /// 宿主是否已经替卡片裁好了外形(2026-09-06)。`NotchWindowRoot` 设 true:它挂在卡片外面的那道
    /// `NotchRevealShape` 终态就是 `NotchHangingShape(20)`,`NotchLyricsView` 再裁一遍是重复的一层 mask,
    /// 尺寸动画期间每帧多重设一次路径。默认 false —— 设置页编辑台等没有这层壳的宿主,卡片自己裁。
    /// ⚠️ 这个值对某个宿主是**常量**,不要在运行期切换:`NotchLyricsView` 按它选 clipShape 分支,切换会
    /// 重建子树、丢掉跑马灯等 @State。
    var notchHostClipsCard: Bool {
        get { self[NotchHostClipsCardKey.self] }
        set { self[NotchHostClipsCardKey.self] = newValue }
    }

    /// 灵动岛顶行以下的某一块内容(曲目头部 / 两份歌词行变体 / 展开区)此刻是不是可见的那份
    /// (2026-09-06,`NotchLyricsView.cardBodyLayer`)。藏着的那份按它停掉逐字填色 / 迷你进度条的 TimelineView。
    /// 默认 true —— 别的宿主 / 单份渲染时不受影响。
    var notchCardLayerActive: Bool {
        get { self[NotchCardLayerActiveKey.self] }
        set { self[NotchCardLayerActiveKey.self] = newValue }
    }
}
