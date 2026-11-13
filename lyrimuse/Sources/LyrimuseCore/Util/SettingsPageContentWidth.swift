import CoreGraphics

/// 设置页滚动区里的内容按多宽排。
///
/// `visible` 是 ScrollView 提议给内容的宽（已扣掉安全区，常驻滚动条出现时也扣掉它那一条）；
/// `container` 是 `containerRelativeFrame(.horizontal)` 量到的容器宽。两者只差一条常驻滚动条以内时按容器宽排，
/// 滚动条出现与否卡片列都不挪；差得更多说明容器把浮动侧栏底下那一块也算了进来，按它排内容会比可见区宽、
/// 右侧被裁掉，这时只按可见区宽排。见 14 章决策 192。
public enum SettingsPageContentWidth {
    public static func resolve(visible: CGFloat, container: CGFloat, scrollerWidth: CGFloat) -> CGFloat {
        let strip = container - visible
        return strip >= 0 && strip <= scrollerWidth + 1 ? container : visible
    }
}
