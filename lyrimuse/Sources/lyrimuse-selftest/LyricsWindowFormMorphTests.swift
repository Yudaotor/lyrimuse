import CoreGraphics
import Foundation
import LyrimuseCore

/// 进 / 出迷你变形动画的几何(`LyricsWindowFormMorphPlan`,07 章决策 125)。
func checkLyricsWindowFormMorph() {
    typealias Plan = LyricsWindowFormMorphPlan
    // 圆角:真机截图左上角对角线(2 倍屏,前 9 个像素透明、第 10 个 alpha 99、之后不透明)量出来约 16pt。
    let measured: [UInt8] = Array(repeating: 0, count: 9) + [99] + Array(repeating: 255, count: 20)
    let r = Plan.cornerRadius(diagonalAlpha: measured, scale: 2)
    expectEqual(r.map { (15...18).contains($0) } ?? false, true, "变形动画圆角: 真机对角线量出约 16pt(实际 \(String(describing: r)))")
    // 半径 10pt、2 倍屏:圆弧在对角线上第 5.86 像素处,第 6 个像素(中心 5.5)盖住约四分之一。
    let ten: [UInt8] = Array(repeating: 0, count: 5) + [64] + Array(repeating: 255, count: 20)
    let r10 = Plan.cornerRadius(diagonalAlpha: ten, scale: 2)
    expectEqual(r10.map { abs($0 - 10) < 0.5 } ?? false, true, "变形动画圆角: 合成的 10pt 圆角量回 10pt(实际 \(String(describing: r10)))")
    expectEqual(Plan.cornerRadius(diagonalAlpha: Array(repeating: 255, count: 30), scale: 2) == nil, true,
                "变形动画圆角: 角上就不透明(没有圆角)量不出来")
    expectEqual(Plan.cornerRadius(diagonalAlpha: Array(repeating: 0, count: 30), scale: 2) == nil, true,
                "变形动画圆角: 整条透明(背景透明)量不出来")
    expectEqual(Plan.cornerRadius(diagonalAlpha: measured, scale: 0) == nil, true, "变形动画圆角: 倍率为 0 不算")

    // 临时窗:新旧两个 frame 的并集,四周留出阴影。
    let full = CGRect(x: 0, y: 33, width: 1470, height: 861)
    let mini = CGRect(x: 1038, y: 108, width: 430, height: 359)
    expectEqual(Plan.overlayFrame(from: full, to: mini, margin: 60), CGRect(x: -60, y: -27, width: 1590, height: 981),
                "变形动画临时窗: 并集外扩 60")

    // 淡入:跟卡片同一刻落地,至少 0.12 秒。
    expectEqual(abs(Plan.crossfadeDuration(elapsed: 0.1) - 0.26) < 1e-9, true, "变形动画淡入: 剩多少走多少")
    expectEqual(Plan.crossfadeDuration(elapsed: 0.3), 0.12, "变形动画淡入: 快走完时至少 0.12")
    expectEqual(Plan.crossfadeDuration(elapsed: 0.9), 0.12, "变形动画淡入: 卡片已落地也留 0.12")

    // 同一块屏才做动画。
    let screens = [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 1470, y: 0, width: 1920, height: 1080)]
    expectEqual(Plan.sameScreen(full, mini, screens: screens), true, "变形动画: 新旧都在内建屏")
    expectEqual(Plan.sameScreen(full, CGRect(x: 2000, y: 100, width: 430, height: 359), screens: screens), false,
                "变形动画: 迷你在外接屏上不做")
    expectEqual(Plan.sameScreen(full, CGRect(x: -5000, y: -5000, width: 430, height: 359), screens: screens), false,
                "变形动画: 目标不在任何屏上不做")
}
