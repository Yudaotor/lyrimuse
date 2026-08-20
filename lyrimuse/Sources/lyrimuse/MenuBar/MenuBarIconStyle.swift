import AppKit

// 菜单栏图标的可选样式(2026-08-17 加)。这个图标出现在**没在显示歌词**的时候 ——
// 没在放歌、还没解析出这一句、或者菜单栏歌词整个关掉。
//
// ---- 选型标准 ----
//
// 候选是先批量渲染成对照图、按**菜单栏真实尺寸**(而不是放大图)挑出来的:小尺寸下认不出
// 来的一律不要。据此淘汰掉的有 waveform.path / guitars / radio(线条太密,15pt 下糊成一
// 团)、airplayaudio(那是 AirPlay 的既有语义,摆在菜单栏上会被误读成投屏)。
//
// ---- 为什么全是矢量,没有一张 PNG ----
//
// 位图这条路在 2026-08-17 已经走死过一次:老图标是一张 36×36 的 PNG,字形只占 22×15,
// 想放大到正常大小必糊(详见 MenuBarStatusItem.menuBarIconImage 那段注释)。SF Symbol
// 是矢量的,而且跟系统自带图标共用同一套视觉重量,天然"合群";自制的那两个组合款也是
// 现画的,任意尺寸都清晰。
enum MenuBarIconStyle: String, CaseIterable, Codable, Hashable, Identifiable {
    // 2026-08-17 用户圈掉了五款:音符与歌词/音符与双行(组合款,跟 App 图标同构图但
    // 用户不喜欢)、卡拉OK(三线扫色)、引号、耳机。存储侧对已删 rawValue 有兜底
    // (AppSettings 解不出来回落 default),随删随安全。
    /// 老手绘线稿的矢量重制(经数轮打磨,见 classicArtwork)。2026-08-17 用户钦点:
    /// 默认款 + 网格第一位(CaseIterable 顺序就是设置网格的展示顺序)。
    case classic
    case note
    case noteList
    case quarternotes
    case waveform
    /// 自制:三根竖直音条。放歌时循环跳动、暂停/无播放时定格到静置帧 —— 2026-08-17 起
    /// **所有款式**播放时都会动(设置里有总开关),动效全在 MenuBarLiveIconView;这里只出
    /// 静态帧(设置网格 + 暂停态),音条的几何参数两边要保持一致。
    case equalizer
    case mic
    // ---- 2026-08-17 用户从候选页(9 选 5)拍板补进来的五款 ----
    /// 节拍器。动效是真·钟摆:绕靠近底部的支点摆,见 MenuBarLiveIconView.buildPendulum。
    case metronome
    /// 钢琴键。动效走通用摇摆。
    case pianokeys
    /// 音叉。动效是高频微颤(它在振动)。
    case tuningfork
    /// 光盘。动效是缓慢旋转。
    case disc
    /// 自绘:黑胶唱片(盘身 + 两圈沟纹 + 标芯)——呼应 App 的黑胶模式。动效同样是旋转。
    case vinyl

    var id: String { rawValue }

    static let `default`: MenuBarIconStyle = .classic

    var displayName: String {
        switch self {
        case .note: return L10n.t("音符")
        case .noteList: return L10n.t("歌词列表")
        case .quarternotes: return L10n.t("三连音符")
        case .waveform: return L10n.t("声波")
        case .equalizer: return L10n.t("跳动音条")
        case .mic: return L10n.t("麦克风")
        case .metronome: return L10n.t("节拍器")
        case .pianokeys: return L10n.t("钢琴键")
        case .tuningfork: return L10n.t("音叉")
        case .disc: return L10n.t("光盘")
        case .vinyl: return L10n.t("黑胶唱片")
        case .classic: return L10n.t("经典")
        }
    }

    /// 菜单栏上字形的点大小。15pt 是 SF Symbol 在菜单栏的常见档位 —— 画出来的字形高度
    /// 15pt 上下,跟旁边的 wifi/电池齐平(2026-08-17 真机截图比对过)。
    private static let pointSize: CGFloat = 15

    /// 按样式取模板图,带进程内缓存。
    ///
    /// 两个调用方都需要它:状态栏本体(refresh 是换句就调一次的热路径)和设置页那个
    /// 图标网格(每次 body 求值都会把十款全过一遍)。重画一次要过 SF Symbol 配置 +
    /// 一次离屏绘制,不缓存的话设置页光是滚动就在反复重画十张图。
    @MainActor
    static func cachedImage(for style: MenuBarIconStyle) -> NSImage {
        if let hit = cache[style] { return hit }
        let built = style.makeImage()
        cache[style] = built
        return built
    }

    @MainActor private static var cache: [MenuBarIconStyle: NSImage] = [:]

    /// 构建这一款的模板图。失败(理论上不会:用到的符号都从 macOS 11 就在)时返回一张
    /// 空图,不让状态栏那个位置崩掉。
    func makeImage() -> NSImage {
        let image: NSImage? = {
            switch self {
            case .note: return Self.symbol("music.note")
            case .noteList: return Self.symbol("music.note.list")
            case .quarternotes: return Self.symbol("music.quarternote.3")
            case .waveform: return Self.symbol("waveform")
            // 静置帧(设置网格里那张 / 暂停时定格的那张)。跳动帧在 equalizerFrames()。
            case .equalizer: return Self.equalizerImage(heights: [0.55, 0.85, 0.40])
            case .mic: return Self.symbol("music.mic")
            case .metronome: return Self.metronomeArtwork()
            case .pianokeys: return Self.pianoKeysArtwork()
            case .tuningfork: return Self.symbol("tuningfork")
            case .disc: return Self.discArtwork()
            case .vinyl: return Self.vinylArtwork()
            case .classic: return Self.classicArtwork()
            }
        }()
        let result = image ?? NSImage(size: NSSize(width: 16, height: 16))
        result.isTemplate = true
        return result
    }

    /// 「经典」= 老手绘线稿的矢量重制(2026-08-17 v3)。
    ///
    /// v1 直接用 Resources/MenuBarIconTemplate.png 裁剪放大 —— 源字形只有 22×15 像素,
    /// 显示在 14pt(Retina 28px 高)要放大近一倍,静态就糊,摆动动画的旋转插值再糊一层,
    /// 用户实测点名"很糊、动起来也不清晰",位图无解只能矢量化。
    /// v2 忠实拟合了原图"符尾和顶线连成一体"的结构、v3 改成分离对齐,用户都不满意;
    /// v4(现行)按用户点名的 **App 图标同款构图**来:音符左上居前,三道线在右下、
    /// 顶线明显低于符尾("放在它下面"),线从音符身后穿过 —— 单色模板图没法靠颜色分
    /// 前后,层次感靠"加粗一圈的音符剪影在线上抠缝"表达("被压着"的那道缝)。
    /// 那张 PNG 留在 Resources 里当历史资料,不再参与渲染。
    // ---- 「经典」的几何(动画层与静态帧共用;动效 E「线随乐伸缩」在
    // MenuBarLiveIconView.buildClassicStretch,三道线的位置/右缘必须两边一致) ----
    static let classicCanvas = NSSize(width: 20.5, height: 14)
    /// 三道线:y 中心 / 左起点 / 长度。顶线更短且右对齐(右缘统一 18.3)。
    static let classicLines: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
        (9.2, 10.9, 7.4), (5.7, 7.8, 10.5), (2.2, 7.8, 10.5),
    ]
    static let classicLineHeight: CGFloat = 1.9
    static let classicLineRightEdge: CGFloat = 18.3

    /// 音符三件(符头/符干/符尾)画进当前上下文。expand = 0 画本体;> 0 画加粗剪影
    /// (抠缝/蒙版用)。尺寸 2026-08-17 按用户逐轮调过:音符放大、符头 6.0×4.3。
    private static func classicNote(expand: CGFloat) {
        guard let ctx = NSGraphicsContext.current else { return }
        // 符头:斜置实心椭圆
        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 3.3, yBy: 3.0)
        t.rotate(byRadians: -0.32)
        t.concat()
        NSBezierPath(ovalIn: NSRect(x: -3.0 - expand, y: -2.15 - expand,
                                    width: 6.0 + expand * 2, height: 4.3 + expand * 2)).fill()
        ctx.restoreGraphicsState()
        // 符干
        NSBezierPath(rect: NSRect(x: 5.35 - expand, y: 3.0 - expand,
                                  width: 1.55 + expand * 2, height: 10.3 + expand * 2)).fill()
        // 小符尾
        ctx.saveGraphicsState()
        let f = NSAffineTransform()
        f.translateX(by: 6.9, yBy: 12.6)
        f.rotate(byRadians: -0.55)
        f.concat()
        NSBezierPath(roundedRect: NSRect(x: -0.4 - expand, y: -0.8 - expand,
                                         width: 3.4 + expand * 2, height: 1.65 + expand * 2),
                     xRadius: 0.8 + expand, yRadius: 0.8 + expand).fill()
        ctx.restoreGraphicsState()
    }

    /// 只有音符的一张(动画层的静件)。
    static func classicNoteArtwork() -> NSImage {
        let image = NSImage(size: classicCanvas, flipped: false) { _ in
            NSColor.black.setFill()
            classicNote(expand: 0)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 歌词线的**蒙版**:整幅不透明,把加粗一圈的音符剪影抠掉 —— 线层戴上它,伸到
    /// 音符跟前就被"缝"挡住,跟静态帧的压层缝一致。只看 alpha,不参与着色,非模板图。
    static func classicLinesMaskArtwork() -> NSImage {
        NSImage(size: classicCanvas, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current else { return true }
            NSColor.black.setFill()
            rect.fill()
            ctx.compositingOperation = .destinationOut
            classicNote(expand: 1.1)
            ctx.compositingOperation = .sourceOver
            return true
        }
    }

    private static func classicArtwork() -> NSImage? {
        NSImage(size: classicCanvas, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return true }
            NSColor.black.setFill()
            // ① 三道线(最底层)
            for l in classicLines {
                NSBezierPath(roundedRect: NSRect(x: l.x, y: l.y - classicLineHeight / 2,
                                                 width: l.w, height: classicLineHeight),
                             xRadius: 0.6, yRadius: 0.6).fill()
            }
            // ② 加粗剪影抠缝 —— "线从音符身后穿过"的那道缝
            ctx.compositingOperation = .destinationOut
            classicNote(expand: 1.1)
            // ③ 音符本体压在最上
            ctx.compositingOperation = .sourceOver
            classicNote(expand: 0)
            return true
        }
    }

    private static func symbol(_ name: String, pointSize: CGFloat = MenuBarIconStyle.pointSize) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // ---- 节拍器(2026-08-17 v2:用户点名"只有针在摆、机身不动才像在运作",SF 那张
    // 整图摆是错的隐喻;针和机身拆成两张,live 视图只转针,静态帧合成一张斜针的) ----
    static let metronomeCanvas = NSSize(width: 14, height: 15)
    /// 摆针支点在整图画布里的位置。
    static let metronomePivot = NSPoint(x: 7, y: 2.0)
    static let metronomeNeedleSize = NSSize(width: 6, height: 11)
    /// 摆针支点在针那张小图里的位置(live 视图按它设 anchorPoint)。
    static let metronomeNeedlePivotInImage = NSPoint(x: 3, y: 0.6)

    /// 机身:上窄下宽的梯形轮廓。
    static func metronomeBodyArtwork() -> NSImage {
        let image = NSImage(size: metronomeCanvas, flipped: false) { _ in
            NSColor.black.setStroke()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 1.4, y: 0.7))
            body.line(to: NSPoint(x: 5.1, y: 14.3))
            body.line(to: NSPoint(x: 8.9, y: 14.3))
            body.line(to: NSPoint(x: 12.6, y: 0.7))
            body.close()
            body.lineWidth = 1.2
            body.lineJoinStyle = .round
            body.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 摆针:竖线 + 针上的配重块。画在自己的小画布里,底部中央是支点。
    static func metronomeNeedleArtwork() -> NSImage {
        let image = NSImage(size: metronomeNeedleSize, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let needle = NSBezierPath()
            needle.move(to: metronomeNeedlePivotInImage)
            needle.line(to: NSPoint(x: metronomeNeedlePivotInImage.x, y: 10.4))
            needle.lineWidth = 1.1
            needle.lineCapStyle = .round
            needle.stroke()
            // 配重块
            NSBezierPath(roundedRect: NSRect(x: metronomeNeedlePivotInImage.x - 1.2, y: 6.8,
                                             width: 2.4, height: 1.7),
                         xRadius: 0.6, yRadius: 0.6).fill()
            // 支点轴
            NSBezierPath(ovalIn: NSRect(x: metronomeNeedlePivotInImage.x - 0.9,
                                        y: metronomeNeedlePivotInImage.y - 0.9,
                                        width: 1.8, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 静态帧:机身 + 微微偏一边的针(全竖直显得死板,SF 的节拍器也是斜针)。
    private static func metronomeArtwork() -> NSImage {
        let image = NSImage(size: metronomeCanvas, flipped: false) { _ in
            metronomeBodyArtwork().draw(in: NSRect(origin: .zero, size: metronomeCanvas))
            guard let ctx = NSGraphicsContext.current else { return true }
            ctx.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: metronomePivot.x, yBy: metronomePivot.y)
            t.rotate(byRadians: 0.22)
            t.translateX(by: -metronomePivot.x, yBy: -metronomePivot.y)
            t.concat()
            metronomeNeedleArtwork().draw(
                in: NSRect(x: metronomePivot.x - metronomeNeedlePivotInImage.x,
                           y: metronomePivot.y - metronomeNeedlePivotInImage.y,
                           width: metronomeNeedleSize.width, height: metronomeNeedleSize.height))
            ctx.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    // ---- 钢琴键(2026-08-17 v2:用户点名"键位被按压变色"而不是整图摇晃;静态图只画
    // 键盘,四个白键的按压高亮由 live 视图按 pianoPressRects 摆四个填充层轮流点亮) ----
    static let pianoCanvas = NSSize(width: 16, height: 12.5)
    /// 四个白键的按压高亮矩形(键面下半段,避开上方的黑键)。
    static let pianoPressRects: [NSRect] = {
        let edges: [CGFloat] = [0.6, 4.45, 8.3, 12.15, 15.4]
        return (0 ..< 4).map { i in
            NSRect(x: edges[i] + 0.9, y: 1.4,
                   width: edges[i + 1] - edges[i] - 1.8, height: 4.1)
        }
    }()

    static func pianoKeysArtwork() -> NSImage {
        let image = NSImage(size: pianoCanvas, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6),
                                     xRadius: 2.2, yRadius: 2.2)
            frame.lineWidth = 1.2
            frame.stroke()
            for x in [4.45, 8.3, 12.15] as [CGFloat] {
                // 白键分隔线:从底沿到黑键下缘
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: x, y: 0.6))
                divider.line(to: NSPoint(x: x, y: 6.8))
                divider.lineWidth = 0.8
                divider.stroke()
                // 黑键:骑在分隔线上、从顶沿垂下
                NSBezierPath(roundedRect: NSRect(x: x - 1.2, y: 6.8, width: 2.4, height: 5.1),
                             xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 自绘:光盘(2026-08-17 v2)。v1 用 SF 的 opticaldisc,用户实测两条都不行:高光
    /// 刻痕在 15pt 下小到看不见 —— 转了也等于没转;造型也读不出"CD"。这版为 15pt 现画:
    /// 大中孔(CD 区别于黑胶的标志特征)+ 两道对置的粗高光楔当不对称特征,旋转一眼可见。
    /// 方形画布、圆心=中心,绕层中心转不晃(buildSpin 的包围盒纠偏对它算出来≈0)。
    static func discArtwork() -> NSImage {
        // 15.5:第一版 13.2 被用户嫌小(2026-08-17)。菜单栏可用高度 ~22pt,SF 款在
        // pointSize 15 档的字形也在 14~16pt 这个量级,对齐着来。
        let s: CGFloat = 15.5
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSColor.black.setStroke()
            let c = s / 2
            let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            edge.lineWidth = 1.2
            edge.stroke()
            let hole = NSBezierPath(ovalIn: NSRect(x: c - 2.5, y: c - 2.5, width: 5.0, height: 5.0))
            hole.lineWidth = 1.0
            hole.stroke()
            // 两道对置高光:从孔沿伸到盘沿的粗圆头短线,CD 图标的惯用画法。
            for angle in [CGFloat.pi * 0.32, CGFloat.pi * 1.32] {
                let sheen = NSBezierPath()
                sheen.move(to: NSPoint(x: c + cos(angle) * 3.5, y: c + sin(angle) * 3.5))
                sheen.line(to: NSPoint(x: c + cos(angle) * 6.0, y: c + sin(angle) * 6.0))
                sheen.lineWidth = 1.5
                sheen.lineCapStyle = .round
                sheen.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // ---- 黑胶三件套(2026-08-17 v2:用户指出 v1 纯同心圆"转起来看不清、也认不出是唱片"
    // —— 旋转对称的图形转起来本来就不可见,必须有不对称特征 + 一个静止参照物) ----
    // 唱盘单独一张(旋转的就是它:方形画布、圆心=画布中心,绕层中心转不晃,盘面带一颗
    // 偏心标记点,旋转的可见性全靠它)+ 静止的唱臂(右上支点伸到盘面,一眼读出"唱机")。
    // 静态帧 = 两者合成;活体在 MenuBarLiveIconView.buildVinyl 里分两层,只转唱盘。
    // 尺寸 2026-08-17 放大过两轮(15×13.5 → 16.6×15 整体,再单独把盘从 12.6 → 14.4:
    // 用户点名"盘再大点、唱臂保持")。盘沿会探到唱臂线下面穿过,层序上臂在上,视觉正确。
    static let vinylCanvas = NSSize(width: 16.6, height: 15)
    static let vinylDiscSide: CGFloat = 14.4
    /// 唱盘中心在整图画布里的位置 —— 唱臂从右上伸过来,盘往左下让一点。
    static let vinylDiscCenter = NSPoint(x: 7.2, y: 7.4)

    static func vinylDiscArtwork() -> NSImage {
        let s = vinylDiscSide
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let full = rect.insetBy(dx: 0.6, dy: 0.6)
            let rim = NSBezierPath(ovalIn: full)
            rim.lineWidth = 1.2
            rim.stroke()
            let groove = NSBezierPath(ovalIn: full.insetBy(dx: 2.4, dy: 2.4))
            groove.lineWidth = 0.75
            groove.stroke()
            // 标芯
            NSBezierPath(ovalIn: full.insetBy(dx: 4.4, dy: 4.4)).fill()
            // 偏心标记点(在沟纹和盘沿之间):旋转的可见性全靠它。
            let c = s / 2
            let r = s / 2 - 1.7
            let a = CGFloat.pi * 0.28
            NSBezierPath(ovalIn: NSRect(x: c + cos(a) * r - 0.85, y: c + sin(a) * r - 0.85,
                                        width: 1.7, height: 1.7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func vinylArmArtwork() -> NSImage {
        let image = NSImage(size: vinylCanvas, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let pivot = NSPoint(x: 14.5, y: 12.9)
            let arm = NSBezierPath()
            arm.move(to: pivot)
            arm.line(to: NSPoint(x: 10.7, y: 8.0))   // 落点在盘面沟纹与盘沿之间
            arm.lineWidth = 1.35
            arm.lineCapStyle = .round
            arm.stroke()
            NSBezierPath(ovalIn: NSRect(x: pivot.x - 1.4, y: pivot.y - 1.4,
                                        width: 2.8, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func vinylArtwork() -> NSImage {
        NSImage(size: vinylCanvas, flipped: false) { _ in
            vinylDiscArtwork().draw(in: NSRect(x: vinylDiscCenter.x - vinylDiscSide / 2,
                                               y: vinylDiscCenter.y - vinylDiscSide / 2,
                                               width: vinylDiscSide, height: vinylDiscSide))
            vinylArmArtwork().draw(in: NSRect(origin: .zero, size: vinylCanvas))
            return true
        }
    }

    /// 画一帧音条(设置网格里的静置帧;跳动帧不走位图,见 MenuBarEqualizerView):
    /// 三个底对齐、圆头的竖条,高度按比例给。条宽的下限同时是高度下限
    /// (矮到极限就是一个圆点,不会画出比自身圆角还矮的"压扁胶囊")。
    private static func equalizerImage(heights: [CGFloat]) -> NSImage {
        let canvas = NSSize(width: pointSize * 0.80, height: pointSize * 0.90)
        let barWidth = canvas.width * 0.22
        let gap = (canvas.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        return NSImage(size: canvas, flipped: false) { _ in
            NSColor.black.setFill()
            for (i, ratio) in heights.enumerated() {
                let h = max(barWidth, canvas.height * ratio)
                let box = NSRect(x: CGFloat(i) * (barWidth + gap), y: 0,
                                 width: barWidth, height: h)
                NSBezierPath(roundedRect: box,
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
    }

}
