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
/// 终态 (1, 1) 与 `NotchLyricsView` 里那道 `NotchHangingShape(bottomCornerRadius: 20)` 完全重合,所以动画
/// 结束后这道裁剪等于不存在。
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

extension EnvironmentValues {
    /// 出场动画期间内容(顶行 / 歌词行 / 展开区)的透明度,背景不受影响 —— 先看到卡片形状长出来,再看到字。
    /// 默认 1;只有 `NotchWindowRoot` 在动画那 0.3s 里改它,设置页编辑台等别的宿主永远是 1。
    var notchRevealContentOpacity: Double {
        get { self[NotchRevealContentOpacityKey.self] }
        set { self[NotchRevealContentOpacityKey.self] = newValue }
    }
}
