import CoreGraphics
import Foundation

/// 灵动岛卡片「稳态宽 / 展开宽」这一对宽度的纯算术。
///
/// 用户的想法:「把展开状态变为可以更宽,配置宽度的时候可以设置一个上限和一个下限,下限就是正常
/// 状态的宽度,上限就是悬浮展开时候的宽度」。于是灵动岛的宽度从一个数变成一对数:
///   - **稳态宽**(`notchContentWidth`,下限):没 hover 时卡片的宽度,也是老用户一直在调的那个值;
///   - **展开宽**(`notchExpandedContentWidth`,上限):hover 展开后卡片撑到的宽度。
///
/// 两个值之间只有一条不变量:**展开宽 ≥ 稳态宽**。hover 是"多给你看一点",不该反过来把卡片挤窄。
/// 三个写入口(编辑台舞台里的双滑块调整条、「全部设置」抽屉、菜单栏快捷面板)和两处读取
/// (真窗口 `NotchLyricsWindowController.recomputeGeometry`、编辑台 `NotchEditorStage`)全部经这里,
/// 不各自写一份 `max`。
///
/// 跟 `NotchExpandedMetrics` 同一个理由下沉到 LyrimuseCore:selftest 只依赖这个 target,而"展开不会
/// 比稳态窄"、"两只滑块不越过对方"是要被断言钉住的契约。
public enum NotchWidthBounds {
    /// 音浪**独占**一只耳朵时,把它从外缘往里推多少。
    ///
    /// 规则:**非展开态一律贴外缘**(左耳最左、右耳最右 —— 音浪跟着耳朵外沿走才有位置感,
    /// 宽度一放开,居中就成了"飘在中间"),唯二例外:
    ///  - **卡片顶在宽度下限上**(`atMinimumWidth`,用户把稳态宽拖到最小,耳朵窄到音浪几乎
    ///    填满可视段):保持**居中**。居中修的本来就是那个状态下的偏心(实测见下),耳朵那么窄
    ///    时贴外缘与居中只差两三个 pt,但居中是两侧留白均衡的那一档。判据用「稳态真实宽已经
    ///    贴着宽度滑杆的下界」这个**定义性宽度**,不是另挑的一个阈值。
    ///  - **hover 展开态一律返回 0**(「展开要在最边上」)。展开时耳朵宽出一大截(默认稳态
    ///    252 / 展开 482 → 单耳 26.5 → 141.5,同一个居中公式推出来是 58.25pt),那就不是
    ///    "正正好"而是"飘在中间"。展开宽 ≥ 稳态宽 ≥ 下限,但稳态顶在下限的用户 hover 展开
    ///    时 `atMinimumWidth` 仍会是 true,这条 guard 放在最前,保证展开永远贴外缘。
    ///
    /// 只对"这只耳朵除了音浪什么都没有"的情形用。耳朵里还有模块时音浪跟模块是一组、一起贴外缘:
    /// 文字跑马灯溢出时必须从外缘起排,居中会让开头几个字挂到容器外面。
    ///
    /// 居中那一档的算法,推导(以耳朵容器左沿 = 刘海边沿为原点,E = earWidth,
    /// W = barsWidth,P = cardPadding):可视区 = `[0, E + P]`,居中时音浪左沿 =
    /// `(E + P − W) / 2`;贴外缘时是 `E − W`。两者之差 `(E − W − P) / 2` 就是要往里推的量。
    /// 夹 0 是给窄卡片兜底 —— 耳朵窄到装不下音浪 + 那半截边距时宁可退回贴外缘,也不能变成
    /// 负 padding 把音浪推出卡片。
    ///
    /// ⚠️ 居中**不能**图省事把 alignment 换成 `.center`:那是居中于 `earWidth`,会偏**内**
    /// `cardPadding / 2`,比原来错得更多。要补的是两侧边距之差,不是重新选一个对齐方式。
    /// 实测(截图逐列亮度,258pt 卡片 / 179pt 刘海):音浪落在 839.0~854.0(宽 15.0,与
    /// `EqualizerBars.width` 逐位吻合),而耳朵在屏幕上可见的那一段是 824.5~864.0(刘海右沿 →
    /// 卡片右沿)、中心 844.25 —— 音浪中心 846.5,偏外 2.25pt;两侧留白 14.5 / 10.0。成因不是
    /// alignment 写错,是**布局容器比可视区窄**:耳朵的 `.frame(width: earWidth)` 到内容区边界
    /// 就结束了,外面还有 `topRow` 那层 `cardHorizontalPadding` 才到卡片外沿,贴外缘 = 贴内容区
    /// 边界,于是外侧看起来多留了那一截的一半。
    public static func soloEqualizerInset(
        earWidth: CGFloat, barsWidth: CGFloat, cardPadding: CGFloat,
        expanded: Bool, atMinimumWidth: Bool
    ) -> CGFloat {
        guard !expanded, atMinimumWidth else { return 0 }
        return max(0, (earWidth - barsWidth - cardPadding) / 2)
    }

    /// 展开态卡片的**真实**宽度:展开设定值和稳态真实宽取大者。
    ///
    /// `steady` 传的是已经过耳朵下限的稳态真实宽(`NotchLyricsWindowController.contentWidth` 的结果),
    /// 所以这里不必再算一遍耳朵下限 —— 稳态 ≥ 下限,展开 ≥ 稳态,传递之下展开也 ≥ 下限。
    /// 老用户升级(加这一对键时):展开设定默认跟稳态默认同为 360,而他们把稳态调到过 420
    /// 的话 `max(420, 360) = 420` —— hover 时一个像素都不多长,观感跟改动前逐字相同。⚠️
    /// 两个默认值拆成 252 / 482(用户把自己在用的那一对定为默认),这条"不多长"只对当时那批老配置成立。
    public static func expandedWidth(steady: CGFloat, expandedSetting: CGFloat) -> CGFloat {
        max(steady, expandedSetting)
    }

    /// 落盘前把一对设定值归一到不变量上:展开 = max(稳态, 展开)。
    ///
    /// 写稳态的入口(快捷面板 / 抽屉那两根单滑块)把稳态拖过了展开,就把展开**顶上去**;写展开的
    /// 入口拖到稳态以下,就停在稳态。两种情形一个公式。
    public static func normalized(steady: Double, expanded: Double) -> (steady: Double, expanded: Double) {
        (steady, max(steady, expanded))
    }
}

/// 编辑台那根**双滑块**宽度调整条的交互规则(纯函数,UI 在 App 侧 `RangeSlider`)。
///
/// 两只滑块:左 = 稳态宽(下限),右 = 展开宽(上限)。规则只有两条,都在这儿:
///   1. 按下时**离哪只近就拖哪只**;两只叠在一起(稳态 == 展开)分不出近远,看第一段位移的方向 ——
///      往右拖走的是上限,往左拖走的是下限。方向也没有(还没动)就先不认领,等下一帧。
///   2. 被拖的那只**不越过**另一只:拖到对面就停在对面的值上,不把对面推着走。推着走会让"调上限"
///      顺手改掉用户早就调好的稳态宽(那是老用户一直在用的那个值),停下比推走可预期。
public enum NotchWidthRangeDrag {
    public enum Thumb: Equatable, Sendable {
        case steady
        case expanded
    }

    /// 按下点该认领哪只滑块。`dx` 是按下以来的横向位移(用来给"两只重叠"的情形定方向)。
    /// 两只重叠且还没有位移时返回 nil —— 调用方保持"未认领",下一帧再问。
    public static func thumb(pressX: CGFloat, steadyX: CGFloat, expandedX: CGFloat, dx: CGFloat) -> Thumb? {
        let toSteady = abs(pressX - steadyX)
        let toExpanded = abs(pressX - expandedX)
        if toSteady < toExpanded { return .steady }
        if toExpanded < toSteady { return .expanded }
        // 等距(几乎只有两只重叠这一种情形):按位移方向。
        if dx > 0 { return .expanded }
        if dx < 0 { return .steady }
        return nil
    }

    /// 把某只滑块拖到 `value` 之后,两个值各是多少(被拖的那只被另一只挡住)。
    public static func dragging(_ thumb: Thumb, to value: Double,
                                steady: Double, expanded: Double) -> (steady: Double, expanded: Double) {
        switch thumb {
        case .steady: return (min(value, expanded), expanded)
        case .expanded: return (steady, max(value, steady))
        }
    }
}
