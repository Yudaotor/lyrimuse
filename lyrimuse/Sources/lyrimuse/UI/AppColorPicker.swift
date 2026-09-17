import AppKit
import SwiftUI

/// 自制的轻量取色器,取代系统 `ColorPicker` 弹出的 `NSColorPanel`。
///
/// 为什么不用系统的:`NSColorPanel` 是全系统共用的那一个(Preview / Keynote / Xcode 点开都是它),
/// 5 个 tab(轮盘/滑块/调色板/图像/蜡笔)是 Apple 焊死的,对"给歌词选个颜色"这件事来说太乱、
/// 功能也太多,而且没有公开 API 能只留其中几个、把其余藏起来,
/// 所以"不乱"只能自己做一个替代控件。方向:「自己做一个轻量版本，只保留一些会用到的，
/// 用不到的就不要放进去」。
///
/// **保留的**(选任意颜色这个能力本身不能少,只是换一套呈现):
///   - 饱和度/明度方块 + 色相条 —— 这两样合起来就能选到色轮上任意一点,是"轮盘"tab 的等价物。
///   - Hex 输入框 —— 精确输入/粘贴一个颜色值,回车应用。
///   - 屏幕取色(`NSColorSampler`,系统"滴管"能力本身不难接,不是要重做的那五个 tab 之一)。
///   - 不透明度滑杆 —— 只在 `supportsOpacity` 开着时出现,跟系统 `ColorPicker` 的同名参数
///     语义完全对齐(为 false 时选出来的颜色强制不透明,菜单栏那两处颜色靠这个保证可读性,
///     见 `MenuBarEditorStage` 的调用点)。
///
/// **不做的**,以及不做的理由:
///   - 「调色板」tab(保存/管理一组自定义色卡)—— 这个 App 已经有更高一层的等价物
///     (`ColorTheme` /「我的配色主题」,存的是一整套配色而不是单个颜色),per-field 再叠一套
///     色卡管理是重复概念。
///   - 「图像」tab(从一张图提取调色板)—— 跟已有的「跟随封面」是同一个问题的更高层答案
///     (直接把封面主色接管过来,不需要用户自己从图上挑一个像素)。
///   - 灰度 / CMYK 模式 —— 这个 App 里的颜色全部只用于屏幕渲染,没有印刷场景,不需要。
///
/// API 形状照抄系统 `ColorPicker` 的常用调用方式(`selection: Binding<Color>`、
/// `supportsOpacity: Bool`),换掉调用点时只用改类型名,不用碰绑定逻辑。
struct AppColorPicker: View {
    var selection: Binding<Color>
    var supportsOpacity: Bool = true

    @State private var isPresented = false
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1
    @State private var opacity: Double = 1
    @State private var hexText: String = ""

    var body: some View {
        Button {
            loadFromSelection()
            isPresented = true
        } label: {
            ColorSwatch(color: selection.wrappedValue, cornerRadius: 5)
                .frame(width: 32, height: 20)
                // ⚠️ 必须显式给一个矩形命中区(现象是「点击不了了」实测坐实):
                // SwiftUI 的 Shape 默认按"画出来的内容"命中,`RoundedRectangle.fill(color)`
                // 在 color 是全透明(alpha 0,「背景颜色」默认就是它)时等于**没画东西**,那一整块
                // 就成了点不到的死区。不加这一句时颜色不透明还点得开,一拖到全透明就点不开了——
                // 复现条件跟这次踩中的场景分毫不差,同一族坑见 FontFamilyPicker.row() 的
                // `.contentShape(Rectangle())`(那边是本仓已经验证过的解法,这里照抄)。
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { picker }
    }

    private var picker: some View {
        VStack(spacing: 10) {
            saturationBrightnessField
                .frame(height: 130)
            hueSlider
                .frame(height: 14)
            HStack(spacing: 8) {
                ColorSwatch(color: currentColor, cornerRadius: 4)
                    .frame(width: 28, height: 22)
                hexField
                eyedropperButton
            }
            if supportsOpacity {
                opacityRow
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: - 饱和度/明度方块

    /// 横轴饱和度、纵轴明度,拖一下/点一下都直接定位(`minimumDistance: 0`)。叠色用经典的
    /// 双层渐变技巧:底色是当前色相在 S=1/B=1 的纯色,上面叠一层"白→透明"(横向,表达饱和度
    /// 变化)、再叠一层"透明→黑"(纵向,表达明度变化)——不用逐像素算 HSB→RGB,三层 SwiftUI
    /// 渐变叠加出来的视觉效果跟真正的 HSB 平面等价。
    private var saturationBrightnessField: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                thumb(color: Color(hue: hue, saturation: saturation, brightness: brightness))
                    .position(
                        x: CGFloat(saturation) * geo.size.width,
                        y: (1 - CGFloat(brightness)) * geo.size.height
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = Double(clamp(value.location.x / geo.size.width))
                    brightness = Double(1 - clamp(value.location.y / geo.size.height))
                    commit()
                }
            )
        }
    }

    // MARK: - 色相条

    /// 12 个整色相点连成的渐变近似一条完整色相光谱 —— SwiftUI 的 `LinearGradient` 只会在色标间
    /// 做线性 RGB 插值,没有"按色相角度插值"这个概念,取样点够密就看不出跟真色相环的差别
    /// (同样的技巧也在别处的色相类渐变里用过,不是这里独创)。
    private static let hueStops: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }

    private var hueSlider: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(colors: Self.hueStops, startPoint: .leading, endPoint: .trailing)
                thumb(color: Color(hue: hue, saturation: 1, brightness: 1))
                    .position(x: CGFloat(hue) * geo.size.width, y: geo.size.height / 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    hue = Double(clamp(value.location.x / geo.size.width))
                    commit()
                }
            )
        }
    }

    private func thumb(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 1.5)
    }

    // MARK: - Hex 输入 + 屏幕取色

    /// 只认 6 位 RGB,不透明度另有滑杆管 —— 用户不用记「RRGGBBAA 最后两位是透明度」这种格式。
    /// ⚠️ 只在**回车**时应用(`onSubmit`),不做"每敲一个字就实时解析":那样会在还没打完
    /// 一个合法值的中途反复用半成品覆盖 hue/saturation/brightness,输入体验会一直"抖"。
    private var hexField: some View {
        HStack(spacing: 2) {
            Text("#").foregroundStyle(.secondary)
            TextField("", text: $hexText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(applyHexText)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var eyedropperButton: some View {
        Button(action: pickFromScreen) {
            Image(systemName: "eyedropper")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L10n.t("从屏幕取色"))
    }

    private func pickFromScreen() {
        // 系统的屏幕取色能力本身(截屏放大镜 + 吸色),不是要拆掉的那五个 tab 之一 ——
        // `NSColorSampler` 是独立于 `NSColorPanel` 的一个小工具类,拿它不等于走回头路。
        NSColorSampler().show { picked in
            guard let picked, let rgb = picked.usingColorSpace(.sRGB) else { return }
            hue = Double(rgb.hueComponent)
            saturation = Double(rgb.saturationComponent)
            brightness = Double(rgb.brightnessComponent)
            commit()
        }
    }

    // MARK: - 不透明度

    private var opacityRow: some View {
        HStack(spacing: 8) {
            Text(L10n.t("不透明度"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { opacity }, set: { opacity = $0; commit() }), in: 0...1)
            Text("\(Int(opacity * 100))%")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - 状态同步

    private var currentColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness, opacity: supportsOpacity ? opacity : 1)
    }

    /// 每次弹出面板时,把 `selection` 现在的值拆成 hue/saturation/brightness/opacity 这份内部
    /// 工作状态 —— 面板内部的拖拽/输入全部只读写这份状态,只有 `commit()` 才回写 `selection`,
    /// 这样面板打开期间的每一次微小拖动不用反复做"Color → HSB → Color"的有损往返。
    private func loadFromSelection() {
        let rgb = NSColor(selection.wrappedValue).usingColorSpace(.sRGB) ?? .white
        hue = Double(rgb.hueComponent)
        saturation = Double(rgb.saturationComponent)
        brightness = Double(rgb.brightnessComponent)
        opacity = supportsOpacity ? Double(rgb.alphaComponent) : 1
        syncHexText()
    }

    /// 把当前 hue/saturation/brightness/opacity 写回 `selection`,并让 hex 输入框跟着显示
    /// 最新值 —— 拖方块/拖色相条这两个手势不会跟"敲键盘"抢同一个文本框的焦点,所以这里
    /// 覆盖 hexText 是安全的(真正会跟输入抢的是「敲字符的半途」,那种情况只在 `applyHexText`
    /// 里发生,不会由这个函数触发)。
    private func commit() {
        selection.wrappedValue = currentColor
        syncHexText()
    }

    private func syncHexText() {
        let full = currentColor.hexStringWithAlpha // "#RRGGBBAA"
        hexText = String(full.dropFirst().dropLast(2))
    }

    /// 解析失败(没打完、粘贴了带 alpha 的 8 位、纯手滑)就原样弹回当前的合法值,不崩、
    /// 不静默吞掉、也不留一个解析不出来的半成品字符串卡在输入框里。
    private func applyHexText() {
        var s = hexText.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            syncHexText()
            return
        }
        let ns = NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
        hue = Double(ns.hueComponent)
        saturation = Double(ns.saturationComponent)
        brightness = Double(ns.brightnessComponent)
        commit()
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
}

/// 色块本体:圆角矩形填色。触发按钮和面板内的预览色块共用同一份画法。
///
/// ⚠️ **刻意不垫棋盘格**(垫过,观感是「太丑了」)。垫它的理由本来是
/// (跟 `ColorThemeSwatch.swift` 的三段色条同一个理由:半透明看着像"空白"),但那份色条
/// 有 28×12 的整段横条铺开,这里的色块只有 22~28pt 见方,格子数太少,棋盘格在这么小的
/// 面积里不读作"透明度提示",读作一小块脏兮兮的方格纹理。透明度本身已经有 `opacityRow`
/// 的百分比数字和滑杆在说,色块不透明地"变浅"(直接叠在行/面板背景上)已经够当视觉线索,
/// 不需要棋盘格再抢一遍这份信息。
private struct ColorSwatch: View {
    var color: Color
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }
}
