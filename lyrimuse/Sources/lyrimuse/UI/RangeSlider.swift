import LyrimuseCore
import SwiftUI

/// 双滑块区间滑杆(2026-09-06):一根轨道、两只滑块,左 = 下限、右 = 上限。
///
/// 为灵动岛编辑台「稳态宽 / 展开宽」那根调整条写的(用户:「配置宽度的时候可以设置一个上限和一个
/// 下限」)。SwiftUI 没有原生的双滑块控件,而两根单滑块叠着放会把"这是同一根轨道上的两个端点"
/// 这层意思丢掉 —— 用户要表达的正是一个**区间**。
///
/// 交互规则(纯函数在 `NotchWidthRangeDrag`,selftest 钉着):按下时离哪只近拖哪只,两只重叠时
/// 看第一段位移方向;被拖的那只**不越过**另一只。点在轨道空处 = 把较近的那只拖到这里(跟原生
/// Slider 一致)。
///
/// 值的流向跟 `SteppedSlider` 相同:本控件不持有状态,拖动中每一帧把**已量化、已归一**的一对值
/// 通过 `onChange` 交给调用方,调用方拿它更新自己的 @State;`onEditingChanged` 在按下(带滑块)和
/// 松手(nil)时各叫一次,调用方在松手那一下落盘(理由见 `NotchEditorStage.draggingSteady`)。
/// 量化走 `SteppedSlider.snap`(栅格锚在下界,跟设置页其它滑杆同一套语义)。
///
/// ⚠️ 视觉按 macOS `.small` 尺寸的原生 Slider 仿(轨道 4pt、滑块 12pt),压在编辑台那颗黑胶囊上用
/// `.white` tint —— 跟旁边其它元素一样不跟系统强调色走(壁纸上深浅不定)。没有刻度点(这个仓库
/// 为刻度点被用户报过两次,见 `SteppedSlider` 的注释)。
struct RangeSlider: View {
    typealias Thumb = NotchWidthRangeDrag.Thumb

    let lower: Double
    let upper: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    /// 无障碍:两只滑块各自的标签,以及把值读成带单位的文字。VoiceOver 上它们是两个可调节元素。
    let lowerLabel: String
    let upperLabel: String
    let valueText: (Double) -> String
    let onChange: (_ lower: Double, _ upper: Double) -> Void
    let onEditingChanged: (Thumb?) -> Void

    @State private var activeThumb: Thumb?

    private static let thumbSize: CGFloat = 12
    private static let activeThumbSize: CGFloat = 14
    private static let trackHeight: CGFloat = 4
    /// VoiceOver 一次增减走多少:原生 Slider 是区间的 10%,这里取 5 个 step —— 200…500 上 10pt,
    /// 跟菜单栏快捷面板那根的一格相同,比 10%(30pt)细。
    private var adjustableStep: Double { max(step, 1) * 5 }

    var body: some View {
        GeometryReader { geo in
            // 滑块中心能到的横向范围:两端各留半个滑块,滑块不出框。
            let travel = max(1, geo.size.width - Self.thumbSize)
            let lowerX = x(for: lower, travel: travel)
            let upperX = x(for: upper, travel: travel)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.28))
                    .frame(height: Self.trackHeight)
                    .padding(.horizontal, Self.thumbSize / 2)
                // 两只滑块之间那一段是"选中区间",实色。
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, upperX - lowerX), height: Self.trackHeight)
                    .offset(x: lowerX)
                    .padding(.horizontal, Self.thumbSize / 2)
                thumb(.steady, centerX: lowerX + Self.thumbSize / 2)
                thumb(.expanded, centerX: upperX + Self.thumbSize / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        drag(gesture, travel: travel,
                             lowerCenterX: lowerX + Self.thumbSize / 2,
                             upperCenterX: upperX + Self.thumbSize / 2)
                    }
                    .onEnded { _ in
                        guard activeThumb != nil else { return }
                        activeThumb = nil
                        onEditingChanged(nil)
                    }
            )
        }
        .frame(height: Self.activeThumbSize + 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 几何

    /// 值 → 滑块**左边缘**的 x(滑块中心 = 这个值 + 半个滑块)。
    private func x(for value: Double, travel: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return CGFloat(min(max(fraction, 0), 1)) * travel
    }

    /// 指针 x → 值(未量化)。
    private func value(atCenterX x: CGFloat, travel: CGFloat) -> Double {
        let fraction = Double((x - Self.thumbSize / 2) / travel)
        return range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
    }

    /// 一只滑块。无障碍修饰符挂在 `.position` **之前**:`.position` 会让视图占满整个容器,挂在它
    /// 之后 VoiceOver 的焦点框会画成整根滑杆而不是这只滑块。
    private func thumb(_ which: Thumb, centerX: CGFloat) -> some View {
        let active = activeThumb == which
        let size = active ? Self.activeThumbSize : Self.thumbSize
        return Circle()
            .fill(tint)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.1), value: active)
            .accessibilityElement()
            .accessibilityLabel(which == .steady ? lowerLabel : upperLabel)
            .accessibilityValue(valueText(which == .steady ? lower : upper))
            .accessibilityAdjustableAction { direction in adjust(which, direction: direction) }
            .position(x: centerX, y: Self.activeThumbSize / 2 + 2)
    }

    // MARK: - 交互

    private func drag(_ gesture: DragGesture.Value, travel: CGFloat,
                      lowerCenterX: CGFloat, upperCenterX: CGFloat) {
        if activeThumb == nil {
            // 认领滑块:按下点离谁近;重叠时等第一段位移定方向(NotchWidthRangeDrag.thumb)。
            guard let thumb = NotchWidthRangeDrag.thumb(
                pressX: gesture.startLocation.x, steadyX: lowerCenterX, expandedX: upperCenterX,
                dx: gesture.translation.width) else { return }
            activeThumb = thumb
            onEditingChanged(thumb)
        }
        guard let thumb = activeThumb else { return }
        let raw = value(atCenterX: gesture.location.x, travel: travel)
        let snapped = SteppedSlider.snap(raw, in: range, step: step)
        let pair = NotchWidthRangeDrag.dragging(thumb, to: snapped, steady: lower, expanded: upper)
        onChange(pair.steady, pair.expanded)
    }

    /// VoiceOver 增减:一次完整的"按下 → 改值 → 松手",调用方的落盘出口(松手)照常触发。
    private func adjust(_ thumb: Thumb, direction: AccessibilityAdjustmentDirection) {
        let current = thumb == .steady ? lower : upper
        let delta = direction == .increment ? adjustableStep : -adjustableStep
        let snapped = SteppedSlider.snap(current + delta, in: range, step: step)
        let pair = NotchWidthRangeDrag.dragging(thumb, to: snapped, steady: lower, expanded: upper)
        onEditingChanged(thumb)
        onChange(pair.steady, pair.expanded)
        onEditingChanged(nil)
    }
}
