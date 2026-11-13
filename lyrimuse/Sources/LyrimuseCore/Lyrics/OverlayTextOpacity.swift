import Foundation

/// 悬浮歌词文字的不透明度(「颜色」那一组「文字不透明度」滑杆)。
///
/// 整块文字(歌词、读音、译文、下一句、描边、提示文字)当一层一起淡,背景、播放控制排不跟着淡。跟文字颜色从哪来无关:
/// 跟随封面、自定义、彩虹都吃这一项;自定义颜色自己带的透明度照旧,两者相乘。只有桌面悬浮歌词(和画它的编辑台预览)用。
/// 见 04 章决策 99。
public enum OverlayTextOpacity {
    /// 可调范围。下限不到 0:淡到看不见时窗口找不回来。
    public static let range: ClosedRange<Double> = 0.2...1
    /// 滑杆每一格。
    public static let step: Double = 0.05
    /// 默认值,也是加这项设置前的样子。
    public static let defaultValue: Double = 1

    /// 存着的值夹回范围;没存过或不是有限数时按默认值。
    public static func clamped(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 读数:「40%」。
    public static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
