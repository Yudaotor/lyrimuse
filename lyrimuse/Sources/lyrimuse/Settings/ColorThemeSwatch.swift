import AppKit

/// 「配色主题」下拉项与「我的配色主题」子行里的三段色条(2026-09-06,借鉴清单 #55)。
///
/// 一张 28×12 的小图:文字色 / 背景色 / 描边色三段竖条。**描边关着时第三段画灰斜线而不是省略**——
/// 「经典白字」与「白字描边」前景背景完全一样、只差描边开关,省掉第三段两者就长得一样。全透明或半透明的段
/// 底下垫棋盘格(六个内置预设里四个背景是透明的,不垫就是一段空白),四周与段间 0.5pt `separatorColor`,
/// 深浅菜单都看得见。用 `drawingHandler` 而不是 `lockFocus` 烤位图:每次绘制时重跑,`separatorColor` 这类
/// 动态色按当时的外观解析,分辩率也无关(WebPlatformIcon 同一理由)。
///
/// 只认这四个字段、不认 `ColorTheme`:一是它就该只描述配色,二是能单独编译成预览脚本离屏渲染核对观感。
enum ThemeSwatch {
    static let defaultSize = NSSize(width: 28, height: 12)

    static func image(
        foregroundHex: String, backgroundHex: String, strokeEnabled: Bool, strokeHex: String,
        size: NSSize = defaultSize
    ) -> NSImage {
        // 解析失败兜底成看得出来"坏了"的颜色组合(白 / 透明 / 黑),不崩、不空白。
        let foreground = NSColor(hexStringWithAlpha: foregroundHex) ?? .white
        let background = NSColor(hexStringWithAlpha: backgroundHex) ?? .clear
        let stroke = NSColor(hexStringWithAlpha: strokeHex) ?? .black
        let image = NSImage(size: size, flipped: false) { rect in
            let radius: CGFloat = 2
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

            // 棋盘格底:3pt 格,两档灰。只在半透明段透出来。
            let cell: CGFloat = 3
            var row = 0
            var y = rect.minY
            while y < rect.maxY {
                var col = 0
                var x = rect.minX
                while x < rect.maxX {
                    NSColor(white: (row + col) % 2 == 0 ? 0.94 : 0.76, alpha: 1).setFill()
                    NSRect(x: x, y: y, width: cell, height: cell).fill()
                    x += cell; col += 1
                }
                y += cell; row += 1
            }

            let bandWidth = rect.width / 3
            func band(_ index: Int) -> NSRect {
                NSRect(x: rect.minX + bandWidth * CGFloat(index), y: rect.minY, width: bandWidth, height: rect.height)
            }
            foreground.setFill(); band(0).fill()
            background.setFill(); band(1).fill()
            if strokeEnabled {
                stroke.setFill(); band(2).fill()
            } else {
                // 描边关:浅灰底 + 斜线,跟"某个具体颜色"区分开。
                let hatchRect = band(2)
                NSColor(white: 0.9, alpha: 1).setFill(); hatchRect.fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: hatchRect).addClip()
                NSColor(white: 0.55, alpha: 1).setStroke()
                let hatch = NSBezierPath()
                hatch.lineWidth = 1
                var x = hatchRect.minX - hatchRect.height
                while x < hatchRect.maxX {
                    hatch.move(to: NSPoint(x: x, y: hatchRect.minY))
                    hatch.line(to: NSPoint(x: x + hatchRect.height, y: hatchRect.maxY))
                    x += 3
                }
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }

            // 段间分隔 + 外框:同一个动态色,浅色菜单上是深灰、深色菜单上是浅灰。
            NSColor.separatorColor.setStroke()
            for index in 1..<3 {
                let x = rect.minX + bandWidth * CGFloat(index)
                let line = NSBezierPath()
                line.lineWidth = 0.5
                line.move(to: NSPoint(x: x, y: rect.minY))
                line.line(to: NSPoint(x: x, y: rect.maxY))
                line.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            border.lineWidth = 0.5
            border.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
