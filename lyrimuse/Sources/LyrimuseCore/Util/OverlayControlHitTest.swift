import Foundation

// 悬浮歌词窗那排播放控制按钮的**命中测试**。
//
// 为什么这层纯逻辑要下沉到 LyrimuseCore:悬浮窗常年 ignoresMouseEvents=true(理由见
// LyricsOverlayWindowController 里「点击穿透 + 悬停热区 + 长按拖动」那一节),按钮点击不再
// 由 SwiftUI 处理,而是控制器拿全局鼠标监听里的屏幕坐标去比对各按钮上报的矩形。那段判定
// 是这条链路上唯一可以脱离窗口/事件系统单独验证的部分,而 lyrimuse-selftest 只依赖
// LyrimuseCore(app 是可执行 target,导不进来),所以放这里才测得到。

/// 胶囊里的按钮,外加锁定态下悬浮在歌词上方的"解锁"提示。
///
/// 2026-08-29 参考 QQ 音乐悬浮歌词加的四个:`expandToLyricsWindow`(展开到歌词窗口)、
/// `settingsMenu`(弹出快捷设置菜单)、`closeOverlay`(关闭桌面悬浮歌词)——这三个是胶囊里的
/// 新按钮,走跟原有五个完全一样的矩形上报+点击分发路径;`unlockPill` 不在胶囊里,是锁定态
/// hover 时悬浮在歌词上方那个居中的"🔒 解锁"提示,同样借这套 `[OverlayControlID: CGRect]`
/// 矩形分发机制,只是显示条件和位置不同(见 LyricsOverlayView 的对应视图)。
public enum OverlayControlID: String, Hashable, CaseIterable, Sendable {
    case previous
    case playPause
    case next
    case favorite
    case lock
    case expandToLyricsWindow
    case settingsMenu
    case closeOverlay
    case unlockPill
}

public enum OverlayControlHitTest {
    /// 屏幕坐标落在哪个按钮上;没落在任何按钮上返回 nil。
    ///
    /// 重叠时取**面积最小**的那个 —— 五个矩形理论上互不重叠(HStack 排开的),真出现重叠
    /// (布局改动、圆角误差、或者以后往胶囊里塞嵌套控件)时,命中更小的那个比命中更大的
    /// 那个更符合直觉。字典遍历顺序不确定,所以不能"取第一个命中的":那会让重叠情形下的
    /// 结果随机,是最难查的一类 bug。
    /// SwiftUI 内容坐标(左上原点、y 向下)→ AppKit 窗口本地坐标(左下原点、y 向上)。
    ///
    /// 抽出来是因为这套换算原先在控制器里抄了三遍(按钮矩形/控制热区/歌词热区),而且
    /// 三处都把换算结果**直接转成屏幕坐标存了起来** —— 窗口一移动,SwiftUI 布局没变、
    /// PreferenceKey 不重发,存的屏幕坐标就还停在旧位置,按钮和热区当场失效
    /// (2026-08-23 用户报的「移动之后按钮会失效」)。
    ///
    /// 修法是**只存窗口本地坐标**、判定时把鼠标点转进来 —— 窗口本地坐标不随窗口移动改变。
    public static func windowLocalRect(swiftUI rect: CGRect, windowHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: windowHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func control(
        at point: CGPoint, in rects: [OverlayControlID: CGRect]
    ) -> OverlayControlID? {
        rects
            .filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }
}
