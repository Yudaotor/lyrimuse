// 生成 DMG 窗口的背景图(dist/dmg-background.tiff)。
//
// 为什么是脚本生成而不是丢一张设计稿进仓库:这张图只有几何图形,用代码描述比用
// 二进制资产描述更好审阅、也能跟窗口尺寸/图标坐标保持单一来源 —— 下面这几个常量跟
// scripts/dmg_settings.py 里的必须一致,写在代码里至少能在一处看到两边的关系。
//
// 输出 TIFF 而不是 PNG:TIFF 能在一个文件里装下 1x 和 2x 两份位图,Finder 会按屏幕
// 自动挑。只给 PNG 的话 Retina 上就是一张糊图。
//
// 刻意不画任何文字:这个 DMG 面向中英文用户都有,背景图上的文字没法跟着系统语言变,
// 写哪种语言都会有人看不懂。图标位置 + 箭头本身就说清了"往右拖"这件事。
//
// 用法:swift scripts/make_dmg_background.swift <输出路径.tiff>
//
// ---- 2026-09-02 美化(用户"参考一些其他软件"要求) ----
//
// 原来是一层近乎无色的灰白渐变 + 一圈几乎看不见的虚线 + 一条 30% 透明度的细灰箭头——
// 干净但没有任何"这是 Lyrimuse"的辨识度,旁边随便换个 App 名字都说得通。这一轮改成
// 直接从 AppIcon.icns 里量出来的真实像素色(见下面 brand* 那几个常量的注释,不是配出来
// 的近似色),让背景跟图标本身呼应成一套。三处具体变化:
//   1. 背景从平面灰白渐变换成三团柔和的粉/橘/藕色径向光晕叠加——效果类似图标自己那种
//      "暖色渐变"观感,但淡了很多(每团峰值透明度只有 16~20%),不会跟 Finder 的深色
//      文件名标签抢对比度。
//   2. Applications 那侧的落点提示从纯灰虚线环换成:底下一层暖橘光晕("这里能放")+
//      上面一圈用品牌色画的虚线环(不再是快看不见的浅灰)。
//   3. 箭头从 30% 透明度的细灰线换成用图标本身的珊瑚色(粉+橘混出来的那个中间色)、
//      更粗、边缘加了一圈淡淡阴影,同时保留原来"留出图标半径、不压在图标上"那条规则。
// 没有改的:画布尺寸、两枚图标的坐标(跟 dmg_settings.py 严格一致)、"不烧文字"这条
// 决策——上面这条理由依然成立,美化不等于开始往图里塞语言相关的东西。
import AppKit

let width = 660.0
let height = 400.0
/// 两枚图标的中心点(跟 dmg_settings.py 的 icon_locations 一致,那边的坐标系原点在左上)。
let appIconCenter = CGPoint(x: 180, y: 170)
let applicationsCenter = CGPoint(x: 480, y: 170)
/// dmg_settings.py 里的 icon_size,只用来算"光晕/虚线环该比图标大多少"这类相对尺寸。
let iconRadius = 64.0

// ---- 品牌色板:直接从 AppIcon.icns(1024×1024)量出来的真实像素值,不是配出来的 ----
// 量法:sips 把 .icns 转成 PNG,再用一个几行的 NSBitmapImageRep.colorAt 脚本在图标身上
// 挑几处"纯色渐变面"(避开圆角高光和白色音符/线条)采样。四个点分别对应图标的
// 左侧粉、右上桃橘、里面那根黄色横条、底部粉紫——这样背景跟图标是同一套色系,而不是
// "看着搭"的巧合。
let brandPink = NSColor(calibratedRed: 254 / 255, green: 190 / 255, blue: 214 / 255, alpha: 1)
let brandPeach = NSColor(calibratedRed: 254 / 255, green: 217 / 255, blue: 170 / 255, alpha: 1)
let brandYellow = NSColor(calibratedRed: 255 / 255, green: 247 / 255, blue: 169 / 255, alpha: 1)
let brandLavender = NSColor(calibratedRed: 251 / 255, green: 209 / 255, blue: 229 / 255, alpha: 1)
/// 箭头用的珊瑚色:粉+桃橘各半混出来的中间色,比单独用粉或橘都更"暖"、跟图标里
/// 音符到歌词线之间那道过渡色最接近。
let brandCoral = blend(brandPink, brandPeach, 0.5)

/// 两个 calibratedRGB 颜色按比例线性混合(t=0 纯 a,t=1 纯 b)。
func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    NSColor(calibratedRed: a.redComponent * (1 - t) + b.redComponent * t,
            green: a.greenComponent * (1 - t) + b.greenComponent * t,
            blue: a.blueComponent * (1 - t) + b.blueComponent * t,
            alpha: 1)
}

/// 一团从 `color`(在中心,透明度 `peakAlpha`)向外径向淡出到全透明的光晕,半径 `radius`。
/// 全靠透明度渐变自然收边,没有硬边缘需要另外羽化。
func glow(_ color: NSColor, center: CGPoint, radius: CGFloat, peakAlpha: CGFloat) {
    let gradient = NSGradient(colors: [
        color.withAlphaComponent(peakAlpha),
        color.withAlphaComponent(0),
    ])
    gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let pixelsWide = Int(width * scale)
    let pixelsHigh = Int(height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("cannot allocate bitmap") }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 底色:极淡的暖白(不是纯白)——这样上面叠的几团光晕不会显得"浮在死白上",
    // 而是像从同一块材质里透出来的。
    NSColor(calibratedRed: 1.0, green: 0.992, blue: 0.988, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

    // AppKit 的绘图原点在左下角,而上面两个中心点、以及 dmg_settings.py 用的都是
    // "原点在左上"的坐标系,这里翻一次 y。
    func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
    let appCenter = flipped(appIconCenter)
    let appsCenter = flipped(applicationsCenter)

    // 三团大而淡的色块,呼应图标本身"左粉、右上橘黄、底部粉紫"的对角渐变,但淡了
    // 5~6 倍(峰值透明度 16~20% vs 图标本身接近不透明)——背景该是气氛,不是抢戏。
    glow(brandPink, center: CGPoint(x: 40, y: height - 40), radius: 420, peakAlpha: 0.20)
    glow(brandYellow, center: CGPoint(x: width - 60, y: height - 20), radius: 380, peakAlpha: 0.18)
    glow(brandLavender, center: CGPoint(x: width * 0.55, y: 30), radius: 420, peakAlpha: 0.16)

    // App 图标背后的"聚光"——比上面三团更集中、更浓一点,让图标看起来是画面焦点而不是
    // 随便摆在一片渐变上。半径比图标本身(64pt 半径)大出一大截,边缘早在图标轮廓之前
    // 就已经淡下去,不会在图标周围留出一圈看得见的色环。
    glow(brandCoral, center: appCenter, radius: iconRadius + 90, peakAlpha: 0.30)

    // Applications 落点:先垫一层暖橘光晕("放这里"的引导),再叠一圈跟图标同心、
    // 半径比图标大一点的虚线环。环本身也从原来的浅灰换成品牌色。
    glow(brandPeach, center: appsCenter, radius: iconRadius + 24, peakAlpha: 0.20)
    let ringRadius = iconRadius + 6
    let ring = NSBezierPath(ovalIn: NSRect(
        x: appsCenter.x - ringRadius, y: appsCenter.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = 1.5
    brandCoral.withAlphaComponent(0.5).setStroke()
    ring.setLineDash([6, 6], count: 2, phase: 0)
    ring.stroke()

    // 两枚图标之间的箭头:珊瑚色实心箭头,比原来那条 30% 透明度的细灰线更清楚地
    // 传达"往这边拖"。留出图标本身的半径,别让线压在图标上;箭身带一圈淡淡的
    // 投影,让它看起来"浮"在背景上而不是画在背景里。
    let inset = iconRadius + 20
    let start = CGPoint(x: appCenter.x + inset, y: appCenter.y)
    let end = CGPoint(x: appsCenter.x - inset, y: appsCenter.y)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.4, alpha: 0.22)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = NSSize(width: 0, height: -1.5)
    shadow.set()

    brandCoral.withAlphaComponent(0.68).setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: CGPoint(x: end.x - 12, y: end.y))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    shaft.stroke()

    brandCoral.withAlphaComponent(0.75).setFill()
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: CGPoint(x: end.x - 16, y: end.y + 8))
    head.line(to: CGPoint(x: end.x - 16, y: end.y - 8))
    head.close()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make_dmg_background.swift <out.tiff>\n".data(using: .utf8)!)
    exit(2)
}
let reps = [draw(scale: 1), draw(scale: 2)]
// ⚠️ 刻意**不**压缩这张 TIFF,尽管裸写出来有 5.2MB。
//
// 直觉是"先 LZW 压到 398KB 再放进镜像",实测反了:最终 DMG 用 LZW 背景是 10.58MB,
// 用未压缩背景是 10.45MB。原因是外层 UDZO 本身就是 zlib —— 一层平渐变它压得极狠,
// 而 LZW 压过的数据熵已经高了,再压一遍反而挤不动。用户下载的是最终那个 .dmg,
// 所以以它为准。
guard let data = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:]) else {
    FileHandle.standardError.write("failed to encode tiff\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: args[1]))
