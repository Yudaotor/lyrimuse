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
    ///
    /// `contentTopInset`(2026-09-11,位置预设「底部居中」引入):内容块顶边离窗口顶边多远。
    /// 上报的矩形都是**内容块自己**的坐标空间(`overlayContent`,原点在内容块左上角),原来
    /// 直接拿 `windowHeight - rect.maxY` 换算,隐含"内容块顶边 == 窗口顶边"—— 内容贴顶时成立
    /// (见 `LyricsOverlayView` 根部那条 `.frame(alignment:)` 的注释),内容贴底时内容块顶边在
    /// 窗口顶边下方 `windowHeight - contentHeight`,不扣掉的话整排按钮的命中区会整体上偏这么多。
    /// 默认 0 = 原口径,既有调用点一个字不用改。
    public static func windowLocalRect(
        swiftUI rect: CGRect, windowHeight: CGFloat, contentTopInset: CGFloat = 0
    ) -> CGRect {
        CGRect(x: rect.minX, y: windowHeight - contentTopInset - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 内容块顶边离窗口顶边多远(给上面那个换算用)。贴顶恒为 0;贴底 = 窗高 − 内容高(内容比
    /// 窗还高、被顶部裁掉时为负 —— SwiftUI 的 `.frame(alignment: .bottom)` 对超高的子视图正是
    /// 对齐底边、从顶上溢出,负值换算出来的位置才是真的)。
    public static func contentTopInset(
        anchorsBottom: Bool, windowHeight: CGFloat, contentHeight: CGFloat
    ) -> CGFloat {
        anchorsBottom ? windowHeight - contentHeight : 0
    }

    public static func control(
        at point: CGPoint, in rects: [OverlayControlID: CGRect]
    ) -> OverlayControlID? {
        rects
            .filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }

    /// 指针此刻**该高亮哪一颗**按钮(2026-09-11,用户:「悬浮歌词这上面的按钮帮我开一个鼠标
    /// 移上去有交互的动效视觉 ux 效果」)。nil = 不高亮任何一颗。
    ///
    /// 跟 `control(at:in:)` 分成两个函数,因为它们回答的是两个问题:那个是"这一下点击该派给
    /// 谁"(点击本来就只在按钮显示时才分发,调用点自己守着可见性);这个是"现在该把哪一颗画亮",
    /// 会在**每一次鼠标移动**上求值,所以可见性必须由它自己兜住 —— 画亮一颗其实没显示的按钮
    /// 是"看得见的 bug",画错方向比少画更糟。
    ///
    /// 两道闸:
    ///  ① 指针不在窗口里就不高亮。窗口常年点击穿透,监听器是**全局**的,指针早跑到别的 App
    ///     上去了照样有事件进来;只比矩形的话,窗口边上那颗按钮会在指针离开之后一直亮着。
    ///  ② 锁定态只认 `unlockPill`。那一格此刻只画得出解锁这一颗(见 `LyricsOverlayView`
    ///     的 `unlockPill` / `playbackControls` 两个分支),别的矩形要么压根没上报、要么是上
    ///     一轮布局的残留 —— 残留矩形亮起来就是"高亮浮在一颗看不见的按钮上"。
    public static func hoveredControl(
        at point: CGPoint, in rects: [OverlayControlID: CGRect],
        insideWindow: Bool, positionLocked: Bool
    ) -> OverlayControlID? {
        guard insideWindow, let id = control(at: point, in: rects) else { return nil }
        if positionLocked && id != .unlockPill { return nil }
        return id
    }

    /// 控制排「该不该露出来」的命中区域(2026-09-13 用户:「只有当鼠标悬浮到歌词实际范围内,
    /// 才会出现下面这个菜单栏;而不是鼠标放在整个悬浮歌词窗口内,就展示下面的菜单栏」)。
    ///
    /// 在此之前 `isHoveringForControls` 的判据是 `window.frame.contains(鼠标)` —— **整扇窗**。
    /// 窗口比字大得多(上下有卡片内边距和控制排槽位、左右是 `WrapLayout` 撑满留下的空白),
    /// 指针从窗口边缘那圈空白扫过就会把整排按钮叫出来。跟 2026-08-23「划过让开」收紧成
    /// `isHoveringLyrics` 是同一个病根,只是当时只收了那一半。
    ///
    /// 收紧后的区域 = 歌词文字矩形 ∪ 控制排胶囊热区 ∪ 各按钮矩形,取**包围盒**。三件事都要:
    ///  ① 按钮矩形/胶囊热区必须并进来。按钮在歌词**外面**(卡片内边距 + 槽位那 4+4pt),只留
    ///     歌词矩形的话,指针一往按钮挪就离开了区域 —— 控制排在指针抵达之前先消失,整排按钮
    ///     从此点不到。这是这次收紧唯一会致命的地方。
    ///  ② 取包围盒、而不是"命中其中任一个矩形",是为了把歌词与按钮之间那道缝包进去:分开判
    ///     的话指针穿过缝的那一两拍两边都不命中,控制排会闪一下再回来。
    ///  ③ 按钮矩形**单独**并(不只并胶囊热区)是给**锁定态**的:那一格只画得出"🔒 解锁"一颗,
    ///     胶囊热区(`ControlsFramePreferenceKey`)压根不上报,不并按钮矩形的话锁定之后就再也
    ///     没有解锁出路了。
    ///
    /// 三份都没有(刚显示、或这一轮没有任何文字)时返回 nil,调用点退回整窗判定 —— 别让功能
    /// 整个失灵,那是旧行为,至少按钮还点得到。
    ///
    /// `.zero`(以及任何空矩形)= "这一轮没有人报告位置",按缺席处理,不能让它把包围盒拉到
    /// 内容块左上角 —— 那会在窗口角上留下一块看不见的命中区。
    public static func chromeHoverZone(
        lyrics: CGRect?, controlsPill: CGRect?, controlRects: [OverlayControlID: CGRect]
    ) -> CGRect? {
        var zone: CGRect?
        // 字典遍历顺序不确定,但并集可交换、与顺序无关,结果稳定(有 selftest 守着)。
        for rect in [lyrics, controlsPill].compactMap({ $0 }) + Array(controlRects.values) {
            guard !rect.isEmpty else { continue }
            zone = zone.map { $0.union(rect) } ?? rect
        }
        return zone
    }
}
