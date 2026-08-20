import AppKit
import QuartzCore

// 菜单栏图标的"活体"渲染层(2026-08-17):播放时所有款式都能动(设置里有总开关
// menuBarIconAnimates),暂停/无播放/显示歌词文字时这一层整个退场,由静态模板图接管。
//
// ---- 为什么是 Core Animation,不是 Timer 换帧 ----
//
// 第一版「跳动音条」是 10fps 的主线程 Timer 换帧(RunCat 的做法),用户当场反馈
// "卡卡的":正弦起伏这种**连续**运动,10fps 的台阶肉眼可见;而且主线程上还有 20Hz
// 逐字高亮在跑,Timer 间隔一被挤就一顿一顿。RunCat 的卡通跑步帧吃得消低帧率,
// 平滑形变吃不消 —— 跟 MenuBarScrollingLabel 头注里记录的滚动歌词是同一课。
// 改成动画全部交给渲染层插值:主线程只在"开播/暂停/换款/换色"时各干一次活。
//
// ---- 四种动效 ----
//
//   * 音条(equalizer):三根 CALayer 各挂一条相位错开的高度动画,双正弦,循环无缝。
//   * 声波(waveform):SF Symbol 原生的 variable-color 流动(NSImageView 符号效果,
//     系统驱动,跟 macOS 自家图标同一个质感)。
//   * 其余(音符系/麦克风/经典):统一的轻微摇摆(±5° 正弦),NSImageView 的图层
//     转起来 —— 模板图交给 imageView 上色,省掉自绘着色那套。
//
// 颜色/高亮机制同 MenuBarScrollingLabel:自绘图层享受不到模板图的系统着色,
// labelColor / selectedMenuItemTextColor 自己解析、菜单开合时换色,换色绝不打断动画。
// 退场时动画全部摘掉 —— 别留无穷动画在隐藏图层上让渲染层空转。
@MainActor
final class MenuBarLiveIconView: NSView {
    private static let animationKey = "lyrimuse.liveicon"

    private var currentStyle: MenuBarIconStyle?
    private var highlighted = false

    // ---- 呈现体:一个 imageView(摇摆/声波/旋转)+ 自绘图层(音条、黑胶双层) ----
    private let imageView = NSImageView()
    private var equalizerBars: [CALayer] = []
    /// "动件"层(黑胶唱盘/光盘旋转、节拍器摆针):**裸 CALayer,几何完全归这里管**。
    /// 结构动画绝不能挂在 imageView 的视图背板层上 —— AppKit 拥有那个层的几何,布局
    /// 随时改写,变换叠上去实测就是"画圈不自转"(2026-08-17 用户连报三轮,换了三版字形
    /// 都没救,根因在机制:黑胶走裸层没事、光盘走视图层不行,对照坐实)。图层 contents
    /// 享受不到系统模板着色,颜色由 applyColor 里的 tintedContents 现染。
    private let movingPart = CALayer()
    /// "静件"层(黑胶唱臂、节拍器机身、钢琴键盘):静止参照物。
    private let staticPart = CALayer()
    /// 钢琴键的四个按压高亮(纯色圆角块,轮流点亮 —— "有人在弹")。
    private var pressKeys: [CALayer] = []
    /// 「经典」的三道歌词线:右锚点、宽度动画向左伸缩(动效 E,用户 2026-08-17 从
    /// 六版候选里选定)。装在容器里统一戴"压层缝"蒙版 —— 线伸到音符跟前被抠掉,
    /// 跟静态帧的缝一致;音符本体是 staticPart,纹丝不动。
    private let classicLinesHost = CALayer()
    private var classicLineBars: [CALayer] = []
    private let classicLinesMask = CALayer()

    // ---- 几何(跟 MenuBarIconStyle 里对应静态帧的画法保持一致,pointSize 15) ----
    /// 音条字形:15 × (0.80, 0.90);条宽 0.22,静置高度 [0.55, 0.85, 0.40]。
    static let equalizerGlyphSize = NSSize(width: 12, height: 13.5)
    private static let barWidth: CGFloat = equalizerGlyphSize.width * 0.22
    private static let barGap: CGFloat = (equalizerGlyphSize.width - barWidth * 3) / 2
    private static let barPhases: [Double] = [0.0, 2.1, 4.2]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        imageView.imageScaling = .scaleNone
        imageView.isHidden = true
        // 摇摆是旋转,直边转斜了要抗锯齿,否则边缘一格一格的又是另一种"卡"。
        imageView.wantsLayer = true
        imageView.layer?.allowsEdgeAntialiasing = true
        addSubview(imageView)
        for _ in 0 ..< 3 {
            equalizerBars.append(Self.roundedBar(width: Self.barWidth))
        }
        equalizerBars.forEach {
            $0.isHidden = true
            layer?.addSublayer($0)
        }
        for _ in 0 ..< 4 {
            let key = CALayer()
            key.cornerRadius = 1.0
            key.opacity = 0
            pressKeys.append(key)
        }
        for _ in 0 ..< 3 {
            let bar = CALayer()
            // 右锚点:宽度变化时右缘钉死、往左伸缩(经典款的线是右对齐的)。
            bar.anchorPoint = CGPoint(x: 1, y: 0.5)
            bar.cornerRadius = 0.95
            classicLineBars.append(bar)
            classicLinesHost.addSublayer(bar)
        }
        classicLinesHost.mask = classicLinesMask
        // 层序 = 加入顺序:动件在下、静件在上 —— 黑胶的唱臂要压住盘沿、节拍器的机身
        // 轮廓要压住摆针、经典款的音符要压住歌词线;按压高亮再往上。
        for l in [movingPart, classicLinesHost, staticPart] + pressKeys {
            l.isHidden = true
            l.contentsScale = 2
            layer?.addSublayer(l)
        }
        applyColor()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    private static func roundedBar(width: CGFloat) -> CALayer {
        let bar = CALayer()
        bar.anchorPoint = .zero   // position = 左下角,长高只往上、扫色只往右
        bar.cornerRadius = width / 2
        return bar
    }

    // 点击要落到底下的 NSStatusBarButton 上去弹菜单,同 MenuBarScrollingLabel。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: - 对外

    /// 让这一款动起来。同款重复调用是空操作(refresh 会因换句/进度反复走到这里,
    /// 不能每次都把动画打回相位起点)。调用方保证只在"开关开着 × 正在播放"时才调。
    func present(style: MenuBarIconStyle) {
        isHidden = false
        guard style != currentStyle else { return }
        teardown()
        currentStyle = style
        switch style {
        case .equalizer: buildEqualizer()
        case .waveform: buildWaveform()
        case .metronome: buildMetronome()
        case .pianokeys: buildPianoKeys()
        case .tuningfork: buildVibrate()
        case .disc: buildDisc()
        case .vinyl: buildVinyl()
        case .classic: buildClassicStretch()
        default: buildSway(style)
        }
        needsLayout = true
    }

    /// 退场(暂停/关开关/要显示歌词文字/换回静态渲染)。摘光动画再隐藏,理由见头注。
    func clear() {
        guard currentStyle != nil || !isHidden else { return }
        teardown()
        currentStyle = nil
        isHidden = true
    }

    /// 菜单开合换色,不碰动画。
    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        applyColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    // MARK: - 搭台

    private func teardown() {
        imageView.removeAllSymbolEffects()
        imageView.layer?.removeAnimation(forKey: Self.animationKey)
        imageView.image = nil
        imageView.isHidden = true
        for bar in equalizerBars + [movingPart, staticPart, classicLinesHost] + pressKeys + classicLineBars {
            bar.removeAnimation(forKey: Self.animationKey)
            bar.isHidden = true
        }
        // 摆针款会改动件的 anchorPoint,退场时归位,别让下一款(绕中心转的盘)继承歪轴。
        movingPart.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    private func buildEqualizer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in equalizerBars.enumerated() {
            bar.isHidden = false
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth,
                                height: Self.equalizerGlyphSize.height * 0.5)
            bar.add(Self.sampledAnimation(keyPath: "bounds.size.height", duration: 1.2) { t in
                // 双正弦打破机械感;下限 0.20 保住圆头(低于条宽的一半就画不圆了)。
                let a = 2 * Double.pi * t
                let raw = 0.55 + 0.30 * sin(a + Self.barPhases[i]) + 0.12 * sin(2 * a + Self.barPhases[i] * 1.7)
                return Self.equalizerGlyphSize.height * CGFloat(min(0.97, max(0.20, raw)))
            }, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    private func buildWaveform() {
        imageView.isHidden = false
        imageView.image = MenuBarIconStyle.cachedImage(for: .waveform)
        applyColor()
        // SF 原生的 variable-color 流动。⚠️ 必须显式给 repeat 选项:variableColor 同时
        // 是 Discrete/Indefinite 两种效果,addSymbolEffect 默认按"播一轮就停"处理 ——
        // 2026-08-17 用户实测:不带选项时流动一轮之后就冻住了。
        if #available(macOS 15.0, *) {
            imageView.addSymbolEffect(.variableColor.iterative, options: .repeat(.continuous))
        } else {
            imageView.addSymbolEffect(.variableColor.iterative, options: .repeating)
        }
    }

    private func buildSway(_ style: MenuBarIconStyle) {
        imageView.isHidden = false
        imageView.image = MenuBarIconStyle.cachedImage(for: style)
        applyColor()
        // 轻微摇摆:±5° 正弦。这些是"物件"型图标,能做的运动只有律动本身,幅度收着点,
        // 常驻视野里大动作三天就烦了。
        imageView.layer?.add(
            Self.sampledAnimation(keyPath: "transform.rotation.z", duration: 1.6) { t in
                CGFloat(sin(2 * Double.pi * t) * 0.09)
            }, forKey: Self.animationKey)
    }

    /// 节拍器 v2:机身(静件)纹丝不动,只有摆针(动件)绕支点摆 —— "正常运作中"。
    /// v1 整图摇摆被用户点名不对(2026-08-17)。anchorPoint 设在针图里的支点位置,
    /// 摆动就是一条绕支点的旋转动画;teardown 时 anchor 会归位。
    private func buildMetronome() {
        staticPart.isHidden = false
        movingPart.isHidden = false
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.metronomeCanvas)
        let needleSize = MenuBarIconStyle.metronomeNeedleSize
        let pivot = MenuBarIconStyle.metronomeNeedlePivotInImage
        movingPart.bounds = CGRect(origin: .zero, size: needleSize)
        movingPart.anchorPoint = CGPoint(x: pivot.x / needleSize.width,
                                         y: pivot.y / needleSize.height)
        applyColor()
        movingPart.add(Self.sampledAnimation(keyPath: "transform.rotation.z", duration: 1.1) { t in
            CGFloat(sin(2 * Double.pi * t) * 0.30)   // ±17°,一次全摆 1.1s
        }, forKey: Self.animationKey)
    }

    /// 钢琴键 v2:键盘(静件)不动,四个白键的按压高亮轮流点亮 —— "有人在弹"。
    /// v1 整图摇摆被用户点名不对(2026-08-17)。顺序 1-3-2-4,比顺序扫过更像旋律。
    private func buildPianoKeys() {
        staticPart.isHidden = false
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.pianoCanvas)
        applyColor()
        let order: [Int] = [0, 2, 1, 3]
        let period = 1.8
        for (slot, keyIndex) in order.enumerated() {
            let key = pressKeys[keyIndex]
            key.isHidden = false
            key.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.pianoPressRects[keyIndex].size)
            // 每键在自己的时隙里快起慢落:0→1(按下)保持一拍→0(抬起)。
            let s0 = Double(slot) * 0.25
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 0, 1, 1, 0, 0]
            animation.keyTimes = [0, NSNumber(value: s0), NSNumber(value: s0 + 0.04),
                                  NSNumber(value: s0 + 0.16), NSNumber(value: s0 + 0.23), 1]
            animation.duration = period
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            key.add(animation, forKey: Self.animationKey)
        }
    }

    /// 音叉:高频微颤(±0.6pt 横向,0.18s 一个来回)—— 它在振动,不是在摇。
    private func buildVibrate() {
        imageView.isHidden = false
        imageView.image = MenuBarIconStyle.cachedImage(for: .tuningfork)
        applyColor()
        imageView.layer?.add(
            Self.sampledAnimation(keyPath: "transform.translation.x", duration: 0.18) { t in
                CGFloat(sin(2 * Double.pi * t) * 0.6)
            }, forKey: Self.animationKey)
    }

    /// 光盘:裸层 + 匀速转(机制理由见 spinDisc 声明:视图背板层转不出干净的自转)。
    private func buildDisc() {
        movingPart.isHidden = false
        movingPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.cachedImage(for: .disc).size)
        applyColor()
        movingPart.add(Self.spinAnimation(secondsPerTurn: 4.0), forKey: Self.animationKey)
    }

    /// 黑胶:唱盘层转、唱臂层静止 —— 一整张图转的话唱臂跟着转,而唱臂正是让旋转"可见"
    /// 的静止参照物。唱盘图是方形画布、圆心即中心,绕层中心转天然不晃;旋转的可见性
    /// 靠盘面那颗偏心标记点。
    private func buildVinyl() {
        movingPart.isHidden = false
        staticPart.isHidden = false
        movingPart.bounds = CGRect(x: 0, y: 0, width: MenuBarIconStyle.vinylDiscSide,
                                   height: MenuBarIconStyle.vinylDiscSide)
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.vinylCanvas)
        applyColor()
        movingPart.add(Self.spinAnimation(secondsPerTurn: 3.2), forKey: Self.animationKey)
    }

    /// 「经典」动效 E:音符不动,三道线保持右对齐、向左伸缩、相位错开(伸缩到 72%)。
    private func buildClassicStretch() {
        staticPart.isHidden = false
        staticPart.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.classicCanvas)
        classicLinesHost.isHidden = false
        classicLinesHost.bounds = CGRect(origin: .zero, size: MenuBarIconStyle.classicCanvas)
        if classicLinesMask.contents == nil {
            // 蒙版只看 alpha、与外观无关,首次搭台时灌一次就够。
            classicLinesMask.contentsScale = 2
            classicLinesMask.frame = classicLinesHost.bounds
            classicLinesMask.contents = tintedContents(MenuBarIconStyle.classicLinesMaskArtwork())
        }
        applyColor()
        for (i, bar) in classicLineBars.enumerated() {
            let line = MenuBarIconStyle.classicLines[i]
            bar.isHidden = false
            bar.bounds = CGRect(x: 0, y: 0, width: line.w, height: MenuBarIconStyle.classicLineHeight)
            // 右锚点:position 是右缘中心,三道线共用同一条右缘。
            bar.position = CGPoint(x: MenuBarIconStyle.classicLineRightEdge, y: line.y)
            let phase = Double(i) * 1.03
            bar.add(Self.sampledAnimation(keyPath: "bounds.size.width", duration: 1.4) { t in
                line.w * CGFloat(0.86 + 0.14 * sin(2 * Double.pi * t + phase))
            }, forKey: Self.animationKey)
        }
    }

    private static func spinAnimation(secondsPerTurn: TimeInterval) -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // 顺时针(唱片/光盘的转向),层坐标里是负角;-2π 与 0 同相,循环无缝。
        spin.toValue = -2 * Double.pi
        spin.duration = secondsPerTurn
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        return spin
    }

    /// 一条按曲线密集采样(48 点/轮)的无缝循环动画 —— 渲染层在采样点之间继续插值,
    /// 肉眼上就是连续曲线。
    private static func sampledAnimation(
        keyPath: String, duration: TimeInterval, curve: (Double) -> CGFloat
    ) -> CAKeyframeAnimation {
        let samples = 48
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        // f % samples:首尾同值,循环无缝。
        animation.values = (0 ... samples).map { curve(Double($0 % samples) / Double(samples)) }
        animation.keyTimes = (0 ... samples).map { NSNumber(value: Double($0) / Double(samples)) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    // MARK: - 摆位 / 颜色

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch currentStyle {
        case .equalizer:
            let x0 = ((bounds.width - Self.equalizerGlyphSize.width) / 2).rounded()
            let y0 = ((bounds.height - Self.equalizerGlyphSize.height) / 2).rounded()
            for (i, bar) in equalizerBars.enumerated() {
                // 只摆位置,高度归动画管。
                bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.barGap), y: y0)
            }
        case .vinyl:
            let canvas = MenuBarIconStyle.vinylCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            // 两层的 anchor 都是默认的中心:唱臂盖满整个画布,唱盘钉在它的圆心位。
            staticPart.position = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            movingPart.position = CGPoint(x: x0 + MenuBarIconStyle.vinylDiscCenter.x,
                                          y: y0 + MenuBarIconStyle.vinylDiscCenter.y)
        case .disc:
            movingPart.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        case .metronome:
            let canvas = MenuBarIconStyle.metronomeCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            staticPart.position = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            // 动件的 anchor 已设在支点上,position 直接钉到支点的画布坐标。
            movingPart.position = CGPoint(x: x0 + MenuBarIconStyle.metronomePivot.x,
                                          y: y0 + MenuBarIconStyle.metronomePivot.y)
        case .pianokeys:
            let canvas = MenuBarIconStyle.pianoCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            staticPart.position = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            for (i, rect) in MenuBarIconStyle.pianoPressRects.enumerated() {
                pressKeys[i].position = CGPoint(x: x0 + rect.midX, y: y0 + rect.midY)
            }
        case .classic:
            let canvas = MenuBarIconStyle.classicCanvas
            let x0 = ((bounds.width - canvas.width) / 2).rounded()
            let y0 = ((bounds.height - canvas.height) / 2).rounded()
            let center = CGPoint(x: x0 + canvas.width / 2, y: y0 + canvas.height / 2)
            staticPart.position = center
            classicLinesHost.position = center
        default:
            if let image = imageView.image {
                imageView.frame = NSRect(
                    x: ((bounds.width - image.size.width) / 2).rounded(),
                    y: ((bounds.height - image.size.height) / 2).rounded(),
                    width: image.size.width, height: image.size.height)
            }
        }
        CATransaction.commit()
    }

    private var tintColor: NSColor {
        highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    private func applyColor() {
        // 动态颜色要按当前 appearance 解析,理由见 MenuBarScrollingLabel.rebuildImage。
        var solid = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solid = self.tintColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        equalizerBars.forEach { $0.backgroundColor = solid }
        // 图层 contents 吃不到模板着色,现染。只在对应款在场时做 —— 染一次是一趟
        // 位图渲染,别让其它款换色也白付这个钱。
        switch currentStyle {
        case .vinyl:
            movingPart.contents = tintedContents(MenuBarIconStyle.vinylDiscArtwork())
            staticPart.contents = tintedContents(MenuBarIconStyle.vinylArmArtwork())
        case .disc:
            movingPart.contents = tintedContents(MenuBarIconStyle.discArtwork())
        case .metronome:
            movingPart.contents = tintedContents(MenuBarIconStyle.metronomeNeedleArtwork())
            staticPart.contents = tintedContents(MenuBarIconStyle.metronomeBodyArtwork())
        case .pianokeys:
            staticPart.contents = tintedContents(MenuBarIconStyle.pianoKeysArtwork())
            pressKeys.forEach { $0.backgroundColor = solid }
        case .classic:
            staticPart.contents = tintedContents(MenuBarIconStyle.classicNoteArtwork())
            classicLineBars.forEach { $0.backgroundColor = solid }
        default:
            break
        }
        CATransaction.commit()
        imageView.contentTintColor = tintColor
    }

    /// 把模板图按当前 tint 染成 2x 位图,给自绘图层当 contents。
    private func tintedContents(_ image: NSImage) -> CGImage? {
        let scale: CGFloat = 2
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // 在 rep 的绘制上下文里,动态颜色按**视图当前** appearance 解析。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
            self.tintColor.set()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
