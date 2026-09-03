import Foundation

/// 悬浮歌词的字重档位,2026-09-02(用户要求「帮我悬浮歌词模块加一个控制字体粗细的功能配置」)。
///
/// **为什么这个类型在 LyrimuseCore 而不是跟 `Font.overlayFont` 待在一起**:悬浮窗一次要画四种
/// 字重(主歌词 / 罗马音 / 译文 / 下一句预览),用户只选一个 —— 另外三种是**推导**出来的。推导
/// 规则(见 `lighter(by:)` 和下面那三个档位差)是纯逻辑,而且带一条必须钉住的不变量:
/// **默认档位 `.bold` 推出来的四个 AppKit 权重必须逐个等于加这个设置之前硬编码的那四个**
/// (9 / 6 / 5 / 6)——破了它,所有老用户的悬浮歌词会在升级后当场变样,而且没有任何报错。
/// selftest 只依赖 LyrimuseCore(见 Package.swift),判据下沉到这里才能被它覆盖,同
/// `ScrollForwardDecision`。
///
/// SwiftUI 的 `Font.Weight` 映射、`NSFontManager` 查族、以及本地化显示名都留在 App 层的
/// `Settings/AppearanceHelpers.swift` —— 这个 target 只 `import Foundation`,不认识 SwiftUI/AppKit,
/// 也不该认识 `L10n`。
///
/// ⚠️ **`allCases` 的顺序就是从细到粗的阶梯本身**,`lighter(by:)` 直接按下标走。重排 = 静默
/// 改掉所有推导结果,加档位只能往两头加、不能往中间插(往中间插会把"细几档"的含义整体挪位)。
public enum OverlayFontWeight: String, CaseIterable, Sendable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    /// AppKit 的 0...15 权重刻度,5 是标准 regular。
    ///
    /// ⚠️ 这是 `NSFontManager.font(withFamily:traits:weight:size:)` 认的那一套整数刻度,跟
    /// `NSFont.Weight` 那套浮点刻度**不是一回事**,别混用。刻度不是等距的(semibold 8 → bold 9,
    /// 但 medium 6 → semibold 8 跳了 2),这也正是推导要走**档位下标**而不是"权重减 N"的原因。
    public var appKitWeight: Int {
        switch self {
        case .light: return 4
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }

    /// 在阶梯上的位置(0 = 最细)。
    public var ladderIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// 比自己细 `steps` 档;细到头就停在最细那一档,不会绕回去。
    ///
    /// 为什么要**夹住**而不是继续往下:`.light` 已经是这个阶梯的底,再往下(thin/ultraLight)
    /// 配上悬浮窗那层描边基本糊成一片,而罗马音/译文本来就已经小一号(0.65x / 0.7x)。夹住的
    /// 代价是用户选最细档时四行会挤在同一档 —— 那正是"我要它整体很细"这个诉求本身。
    ///
    /// `steps` 传负数(要更粗)不在用法之内,但也照样夹在阶梯两端,不会越界崩。
    public func lighter(by steps: Int) -> OverlayFontWeight {
        let all = Self.allCases
        let target = min(max(ladderIndex - steps, 0), all.count - 1)
        return all[target]
    }

    // MARK: - 四行之间的档位差

    // 用户选的是**主歌词行**那一档,其余三行按下面这些固定差值跟着走。差值取的是加这个设置
    // 之前四行硬编码权重的实际关系:主 bold(9) / 罗马音 medium(6) / 译文 regular(5) /
    // 下一句 medium(6),在上面这个阶梯上正好是 0 / -2 / -3 / -2。
    //
    // ⚠️ 这几个数不是"看着差不多",它们是**兼容性契约**:默认档位下推导结果必须逐个等于
    // 改动前那四个硬编码值,selftest 有一组断言钉着(见 `OverlayFontWeight` 那一段)。

    /// 罗马音行比主歌词细几档。
    public static let romanizationSteps = 2
    /// 译文行比主歌词细几档。
    public static let translationSteps = 3
    /// 下一句预览行比主歌词细几档。跟罗马音同档 —— 它俩在改动前也是同一个 medium。
    public static let nextLinePreviewSteps = 2
}
