import Foundation

// 悬浮歌词窗那排播放控制按钮的**命中测试**。
//
// 为什么这层纯逻辑要下沉到 LyrimuseCore:悬浮窗常年 ignoresMouseEvents=true(理由见
// LyricsOverlayWindowController 里「点击穿透 + 悬停热区 + 长按拖动」那一节),按钮点击不再
// 由 SwiftUI 处理,而是控制器拿全局鼠标监听里的屏幕坐标去比对各按钮上报的矩形。那段判定
// 是这条链路上唯一可以脱离窗口/事件系统单独验证的部分,而 lyrimuse-selftest 只依赖
// LyrimuseCore(app 是可执行 target,导不进来),所以放这里才测得到。

/// 胶囊里的五个按钮。
public enum OverlayControlID: String, Hashable, CaseIterable, Sendable {
    case previous
    case playPause
    case next
    case favorite
    case lock
}

public enum OverlayControlHitTest {
    /// 屏幕坐标落在哪个按钮上;没落在任何按钮上返回 nil。
    ///
    /// 重叠时取**面积最小**的那个 —— 五个矩形理论上互不重叠(HStack 排开的),真出现重叠
    /// (布局改动、圆角误差、或者以后往胶囊里塞嵌套控件)时,命中更小的那个比命中更大的
    /// 那个更符合直觉。字典遍历顺序不确定,所以不能"取第一个命中的":那会让重叠情形下的
    /// 结果随机,是最难查的一类 bug。
    public static func control(
        at point: CGPoint, in rects: [OverlayControlID: CGRect]
    ) -> OverlayControlID? {
        rects
            .filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }
}
