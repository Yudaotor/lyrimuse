import AppKit
import SwiftUI

// 设置页里那一小片「桌面」—— 真实壁纸的样图,以及取样/缩放它的那点缓存。
//
// (2026-08-31 从 OverlayLyricsCanvas.swift 拆出来。那个文件里另一半是悬浮歌词在**顶部钉条**
//  里的简化渲染 `OverlayLyricsCanvas`,而钉条 `OverlayPreviewBar` 在悬浮歌词改成编辑台之后
//  就没有任何实例化点了 —— 两个一起删掉,只留下这一半:它有三个活着的消费方,见下。)

/// 一片「桌面」:真实壁纸的样图,读不到就退回表示透明的棋盘格。
///
/// 抽成独立视图是 2026-08-30 第七步的产物。在那之前这段代码只长在
/// `OverlayLyricsCanvas.desktopUnderlay` 里,而编辑台舞台在窗外另画了一份(按舞台宽度裁的
/// 壁纸 + 高斯虚化)。两份各按各的宽度做 scaledToFill,缩放比对不上,窗口边缘上能看到同一张
/// 壁纸出现两次——窗外那圈虚化当初就是为了藏这道接缝;更要命的是拖宽度调整条时窗内那份的
/// 缩放比跟着变,壁纸内容跟着呼吸。第七步之后整块编辑台只画**一张**(按舞台宽度),窗口那块
/// 把自己的关掉让它透上来,虚化跟着一起删了:接缝不存在了,自然也没什么要藏。
///
/// 两个消费方(钉条自带的那份 / 编辑台舞台那张)共用这一份实现,别在任何一侧再手搓一遍——
/// 尤其是棋盘格:格子大小/相位/配色只要有一处不同,两块画面一对比就露馅(第五步那版编辑台
/// 在读不到壁纸时宁可什么都不画,正是因为当时没有这么一份共用实现可用)。
@MainActor
struct OverlayDesktopSurface: View {
    var body: some View {
        if let wallpaper = DesktopWallpaperSample.image {
            Image(nsImage: wallpaper)
                .resizable()
                .scaledToFill()
        } else {
            // 拿不到壁纸(读不到文件/没有权限)就退回棋盘格 —— 它至少明确表达了
            // 「这一块是透明的、透出的是底下的东西」,不会像纯色那样把人误导成不透明。
            Canvas { context, size in
                let cell: CGFloat = 8
                let cols = Int(size.width / cell) + 1
                let rows = Int(size.height / cell) + 1
                for row in 0 ..< rows {
                    for col in 0 ..< cols where (row + col).isMultiple(of: 2) {
                        let rect = CGRect(
                            x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell)
                        context.fill(Path(rect), with: .color(.gray.opacity(0.22)))
                    }
                }
            }
        }
    }
}


/// 预览里垫在悬浮歌词卡底下的那张桌面壁纸。
///
/// 只读一次并缩到预览用得着的尺寸:壁纸动辄几千像素,每次渲染都去读原图既慢又占内存。
/// 代价是换了壁纸要等下次启动才更新 —— 对一个"演示半透明效果"的垫底图来说够用了。
@MainActor
enum DesktopWallpaperSample {
    private static var loaded = false
    private static var cache: NSImage?

    static var image: NSImage? {
        if !loaded {
            loaded = true
            cache = load()
        }
        return cache
    }

    private static func load() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let original = NSImage(contentsOf: url)
        else { return nil }
        // 缩到预览条那么宽就够了(高度按比例)。
        let targetWidth: CGFloat = 640
        guard original.size.width > targetWidth else { return original }
        let scale = targetWidth / original.size.width
        let size = NSSize(
            width: targetWidth, height: (original.size.height * scale).rounded())
        return NSImage(size: size, flipped: false) { rect in
            original.draw(in: rect)
            return true
        }
    }
}
