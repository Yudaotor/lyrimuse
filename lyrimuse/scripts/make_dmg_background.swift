// 生成 DMG 窗口的背景图(dist/dmg-background.tiff)。
//
// 为什么是脚本生成而不是丢一张设计稿进仓库:这张图只有几个几何图形,用代码描述比用
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
import AppKit

let width = 660.0
let height = 400.0
/// 两枚图标的中心点(跟 dmg_settings.py 的 icon_locations 一致,那边的坐标系原点在左上)。
let appIconCenter = CGPoint(x: 180, y: 170)
let applicationsCenter = CGPoint(x: 480, y: 170)

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

    // 底色:一层很淡的竖向渐变。深色不合适 —— Finder 的文件名标签在浅色背景上是深字,
    // 深底会让它变成"深字压深底"。
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.976, green: 0.973, blue: 0.969, alpha: 1),
            NSColor(calibratedRed: 0.925, green: 0.918, blue: 0.910, alpha: 1),
        ]
    )
    gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // AppKit 的绘图原点在左下角,而上面那两个中心点用的是"原点在左上"的坐标系
    // (跟 dmg_settings.py 对齐),这里翻一次 y。
    func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
    let from = flipped(appIconCenter)
    let to = flipped(applicationsCenter)

    // 目标位置底下画一枚淡淡的圆环,暗示"放到这里"。
    let ringRadius = 62.0
    let ring = NSBezierPath(ovalIn: NSRect(
        x: to.x - ringRadius, y: to.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = 1.5
    NSColor(calibratedWhite: 0.45, alpha: 0.16).setStroke()
    ring.setLineDash([6, 6], count: 2, phase: 0)
    ring.stroke()

    // 两枚图标之间的箭头。留出图标本身的半径,别让线压在图标上。
    let inset = 84.0
    let start = CGPoint(x: from.x + inset, y: from.y)
    let end = CGPoint(x: to.x - inset, y: to.y)
    NSColor(calibratedWhite: 0.35, alpha: 0.30).setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: CGPoint(x: end.x - 10, y: end.y))
    shaft.lineWidth = 2
    shaft.lineCapStyle = .round
    shaft.stroke()

    NSColor(calibratedWhite: 0.35, alpha: 0.30).setFill()
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: CGPoint(x: end.x - 14, y: end.y + 7))
    head.line(to: CGPoint(x: end.x - 14, y: end.y - 7))
    head.close()
    head.fill()

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
