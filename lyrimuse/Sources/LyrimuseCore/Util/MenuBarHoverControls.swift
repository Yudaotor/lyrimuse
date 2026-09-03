import Foundation

// 菜单栏歌词的「鼠标悬停就换成三个走带控制键」(2026-09-03)。用户原话:"就是可以选择是否
// 开启鼠标移动到菜单栏歌词的位置的时候歌词消失,变为三个控制键,点击就可以进行暂停,上下
// 切歌的控制;类似酷狗音乐的"(附酷狗菜单栏截图:图标 + ⏮ ⏸ ⏭)。
//
// ---- 这个文件只管几何 ----
//
// 三个键排在哪、点在哪一个上,是这条链路上唯一能脱离 AppKit 单独验证的部分,所以跟
// `OverlayControlHitTest`(悬浮窗那排按钮的命中测试)同一个理由下沉到 LyrimuseCore ——
// lyrimuse-selftest 只连 LyrimuseCore,app 是可执行 target 导不进来。
//
// 另外两半各在各的地方,别在这里长出第三份:
//   * 怎么画(模板图染色 / 深浅色菜单栏 / 菜单反白)= `MenuBarHoverControlsView`;
//   * 何时接管、点击怎么分派、接管期间怎么把槽宽冻住 = `MenuBarStatusItem`。
//
// ---- 为什么命中区是**连续**的格子,而不是三个 22pt 方块加间距 ----
//
// 菜单栏这一项整块只是**一个** NSStatusBarButton:三个键不是三个真按钮,而是同一个按钮上
// 按坐标分出来的三块(子视图一律 `hitTest -> nil`,点击必须落到按钮上才保得住 ⌘拖动换位置 /
// 右键完整菜单 / ⌃左键这些既有手势,见 MenuBarStatusItem.statusButtonClicked)。既然是按
// 坐标分派,键与键之间留"视觉间距"就等于留一道**死缝** —— 缝里那一下不属于任何键,会掉到
// 默认动作(弹面板)上去,而 22pt 高的菜单栏里用户根本瞄不准那 6pt。所以横向按 `pitch` 切
// 成三个紧邻的格子,间距只体现在**字形画多大**上,命中区始终连续、覆盖整块内容的宽和高。
public enum MenuBarTransportControl: String, CaseIterable, Sendable {
    case previous
    case playPause
    case next
}

public enum MenuBarHoverControls {
    /// 每个键横向占多宽(= 命中格宽)。24pt 是照灵动岛"耳朵"那三个键的命中尺寸取的
    /// (`hitSize: 22`)再放宽一点:菜单栏里没有耳朵那种边距兜着,格子挨着格子。
    public static let pitch: CGFloat = 24

    /// 字形画多大。跟灵动岛耳朵那三个键同一个字号(`glyphSize: 11.5`),这样"同一个软件的
    /// 三个走带键"在菜单栏和刘海上看着是一套东西。
    public static let glyphPointSize: CGFloat = 11.5

    /// 三个键一起至少要多宽。**接管的门槛**:比这个窄就不接管(照旧显示歌词)——
    /// 详见 `layout(in:)`。
    public static var minimumWidth: CGFloat { pitch * CGFloat(MenuBarTransportControl.allCases.count) }

    /// 在这一项的按钮矩形里排三个键:整块水平居中(跟歌词那一格在按钮里居中的算法一致,
    /// 见 `MenuBarScrollingLabel.layout`),纵向占满 —— 命中区在垂直方向上不设门槛,
    /// 菜单栏只有 22pt 高,让用户去瞄中间那 16pt 是自找的麻烦。
    ///
    /// 装不下返回 nil,调用方据此**放弃接管**。这不是"画窄一点"能糊过去的:自适应宽度模式下
    /// 一句 `♪` 的槽宽只有二三十点,硬塞三个键会挤成一坨谁也点不准,还把本来看得见的歌词
    /// 换掉了 —— 保持歌词是这种情况下唯一说得过去的行为。
    public static func layout(in bounds: CGRect) -> [MenuBarTransportControl: CGRect]? {
        guard bounds.width >= minimumWidth, bounds.height > 0 else { return nil }
        let total = minimumWidth
        // 居中留出来的边距取整:半个点的偏移会让字形落在半像素上,菜单栏这个尺寸下看着就是"糊"。
        let left = bounds.minX + ((bounds.width - total) / 2).rounded()
        var rects: [MenuBarTransportControl: CGRect] = [:]
        for (index, control) in MenuBarTransportControl.allCases.enumerated() {
            rects[control] = CGRect(x: left + CGFloat(index) * pitch, y: bounds.minY,
                                    width: pitch, height: bounds.height)
        }
        return rects
    }

    /// 这一点落在哪个键上;没落在任何键上返回 nil(调用方把这一下让回默认动作)。
    ///
    /// 按 `allCases` 的顺序取第一个命中的,而不是像 `OverlayControlHitTest` 那样取面积最小的:
    /// 这里三个矩形等宽等高、彼此紧邻,`CGRect.contains` 对共享的那条边只算给右边那一格
    /// (`minX <= x < maxX`),所以"第一个命中"本身就是唯一命中,顺序遍历即可,不用引入
    /// 一条在等面积时反而不确定的仲裁规则。
    public static func control(
        at point: CGPoint, in rects: [MenuBarTransportControl: CGRect]
    ) -> MenuBarTransportControl? {
        MenuBarTransportControl.allCases.first { rects[$0]?.contains(point) == true }
    }

    /// 某个键的字形该画在哪(命中格里居中的一个正方形)。画和测同一份格子算出来,
    /// 不会出现"看着在这儿、点着在那儿"。
    public static func glyphRect(in hitRect: CGRect, side: CGFloat) -> CGRect {
        CGRect(x: (hitRect.midX - side / 2).rounded(),
               y: (hitRect.midY - side / 2).rounded(),
               width: side, height: side)
    }

    /// 「歌词那一格」在按钮里的**横向**范围(x / 宽)。三个键就排在这一格里。
    ///
    /// ---- 为什么这份算式要在这里、而且只有一份 ----
    ///
    /// 2026-09-03 用户报"点了暂停,生效的是上一首"。日志坐实:同一个功能,三个键的矩形在
    /// `48.5/72.5/96.5` 和 `36/60/84` 两套之间跳 —— 差 12.5pt,正好够点到隔壁那个键。
    /// 病根是歌词格原先问**歌词层**要(它按 `plan.windowWidth` 算),而 `plan` 是**易失**的:
    /// 悬停接管时被清一次(只留图标)、暂停收成图标时又被清一次;而状态栏项的 `displayClass`
    /// 因为重建节流还停在陈旧的 `"fixed"`,于是"该不该接管"说是,"歌词格在哪"却答不上来,
    /// 退回整个按钮居中 —— 位置就跳了。
    ///
    /// 修法是换一个**不会失效**的输入:槽宽(`item.length`)。它是这一项的硬事实,重建才会变,
    /// 而重建期间本来就不接管。算式下沉到这里,`MenuBarScrollingLabel` 摆图层和状态栏项算
    /// 悬停三键都调它 —— 两个入口一份算式,而且能被 selftest 钉死。
    ///
    /// - Parameters:
    ///   - buttonWidth: 按钮(= 这一项)有多宽。
    ///   - contentWidth: 「图标 + 间距 + 歌词格」整块内容多宽。状态栏项那边 =
    ///     `item.length - 系统内边距`;歌词层那边 = `plan.windowWidth + reservedIconWidth`。
    ///   - reservedIconWidth: 歌词旁那枚图标额外占的宽(图标宽 + 间距);没开就是 0。
    ///   - iconLeading: 图标在左边(true)还是右边/没有(false)。
    /// - Returns: 歌词格的 x 与宽度;算不出来(宽度非正)返回 nil。
    public static func lyricsSlot(
        buttonWidth: CGFloat, contentWidth: CGFloat,
        reservedIconWidth: CGFloat, iconLeading: Bool
    ) -> (x: CGFloat, width: CGFloat)? {
        // 整块内容钳在按钮里(bounds 短暂陈旧时别把内容甩出去 —— 跟歌词层 layout 同一条防线)。
        let contentW = min(contentWidth, buttonWidth)
        guard contentW > 0, buttonWidth > 0 else { return nil }
        // 整块在按钮里居中;取整避免半像素。
        let left = max(0, ((buttonWidth - contentW) / 2).rounded())
        let clipW = max(0, contentW - reservedIconWidth)
        guard clipW > 0 else { return nil }
        return (x: iconLeading ? left + reservedIconWidth : left, width: clipW)
    }
}
