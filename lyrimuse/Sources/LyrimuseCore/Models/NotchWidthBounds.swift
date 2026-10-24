import CoreGraphics
import Foundation

/// 灵动岛卡片「稳态宽 / 展开宽」这一对宽度的纯算术。
///
///   - **稳态宽**(`notchContentWidth`,下限):没 hover 时卡片的宽度;
///   - **展开宽**(`notchExpandedContentWidth`,上限):hover 展开后卡片撑到的宽度。
///
/// 两个值之间只有一条不变量:**展开宽 ≥ 稳态宽**,hover 不能把卡片挤窄。
/// 三个写入口(编辑台舞台里的双滑块调整条、「全部设置」抽屉、菜单栏快捷面板)和两处读取
/// (真窗口 `NotchLyricsWindowController.recomputeGeometry`、编辑台 `NotchEditorStage`)全部经这里,
/// 不各自写一份 `max`。
///
/// 放在 LyrimuseCore:selftest 只依赖这个 target,"展开不会比稳态窄"、"两只滑块不越过对方"是要被断言钉住的契约。
/// 见 05 章「宽度 → 展开态可以更宽」。
public enum NotchWidthBounds {
    /// 音浪**独占**一只耳朵时,把它从外缘往里推多少。
    ///
    /// 规则:**非展开态贴外缘**(左耳最左、右耳最右,音浪跟着耳朵外沿走),两个例外:
    ///  - **卡片顶在宽度下限上**(`atMinimumWidth`,耳朵窄到音浪几乎填满可视段):**居中**于可视的那段耳朵,两侧留白均衡。
    ///    判据是「稳态真实宽贴着宽度滑杆的下界」这个定义性宽度,不另挑阈值。
    ///  - **hover 展开态一律返回 0**(贴外缘):展开时耳朵宽出一大截,居中会飘在中间。稳态顶在下限的卡片 hover 展开时
    ///    `atMinimumWidth` 仍是 true,所以这条 guard 放在最前。
    ///
    /// 只对"这只耳朵除了音浪什么都没有"的情形用。耳朵里还有模块时音浪跟模块是一组、一起贴外缘:
    /// 文字跑马灯溢出时必须从外缘起排,居中会让开头几个字挂到容器外面。
    ///
    /// 居中那一档的算法,推导(以耳朵容器左沿 = 刘海边沿为原点,E = earWidth,
    /// W = barsWidth,P = cardPadding,S = shoulder):可视区 = `[0, E + P − S]`(卡片主体在顶边以下
    /// 两侧各收了一个肩膀半径,见 `NotchOutline`;音浪在顶行垂直居中,早在肩膀那几 pt 之下),居中时音浪
    /// 左沿 = `(E + P − S − W) / 2`;贴外缘时是 `E − W`。两者之差 `(E − W − P + S) / 2` 就是要往里推的量。
    /// 夹 0 是给窄卡片兜底 —— 耳朵窄到装不下音浪 + 那半截边距时宁可退回贴外缘,也不能变成
    /// 负 padding 把音浪推出卡片。
    ///
    /// 居中**不能**把 alignment 换成 `.center`:那是居中于 `earWidth`,会偏**内** `cardPadding / 2`。耳朵的
    /// `.frame(width: earWidth)` 到内容区边界就结束了,外面还有 `topRow` 那层 `cardHorizontalPadding` 才到卡片外沿,
    /// 要补的是两侧边距之差。实测数据见 05 章「顶行」里音浪独占耳朵那一条。
    public static func soloEqualizerInset(
        earWidth: CGFloat, barsWidth: CGFloat, cardPadding: CGFloat, shoulder: CGFloat,
        expanded: Bool, atMinimumWidth: Bool
    ) -> CGFloat {
        guard !expanded, atMinimumWidth else { return 0 }
        return max(0, (earWidth - barsWidth - cardPadding + shoulder) / 2)
    }

    /// 顶行(两只耳朵)两侧的内边距。非展开态是 `cardPadding`;展开态收到 `contentInset`(下面那一列内容 —— 曲目信息头部、
    /// 歌词、进度条、控制键 —— 的左右边界),左耳的左沿、右耳的右沿跟它们对齐。展开宽比稳态宽多出来的不够两侧各收这一份时,
    /// 只收多出来的那一半:耳朵在展开时不比稳态窄(稳态刚好装下的模块展开后照样装得下),两值相等时跟稳态一样。见 05 章决策 96。
    public static func topRowPadding(expanded: Bool, steadyWidth: CGFloat, expandedWidth: CGFloat,
                                     cardPadding: CGFloat, contentInset: CGFloat) -> CGFloat {
        guard expanded else { return cardPadding }
        return cardPadding + min(max(0, contentInset - cardPadding), max(0, (expandedWidth - steadyWidth) / 2))
    }

    /// 展开态卡片的**真实**宽度:展开设定值和稳态真实宽取大者。
    ///
    /// `steady` 传的是已经过耳朵下限的稳态真实宽(`NotchLyricsWindowController.contentWidth` 的结果),
    /// 所以这里不必再算一遍耳朵下限 —— 稳态 ≥ 下限,展开 ≥ 稳态,传递之下展开也 ≥ 下限。
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
