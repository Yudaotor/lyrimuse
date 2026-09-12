import LyrimuseCore
import SwiftUI

/// 一阵撒花,盖在宿主视图上面(2026-09-11,用户:「帮我在引导页的最后一页加入 Mac 很经典的
/// 那种撒花效果」)。目前只有引导页最后一页 `doneStep` 在用。
///
/// 几何全在 `ConfettiField`(core,连同"为什么放那儿"和两条被 selftest 钉住的性质);这一层
/// 只管三件事:
///
///  1. **一层 Canvas 画完所有纸片**,不是九十个 SwiftUI 视图。九十个视图各带一份
///     `.rotationEffect`/`.offset` 会让每帧的布局重算翻上两个量级,而这里每帧只是九十次
///     `fill`。同理不用 `context.drawLayer` 包每一片:路径先在原点画好、再整体仿射搬到落点,
///     一片一个 fill,省掉每帧九十个图层。
///
///  2. **到点把整个 TimelineView 摘掉**。`TimelineView(.animation)` 只要在视图树里就会按屏幕
///     刷新率一直重算 body —— 撒花是一次性的三四秒,不能让它在用户读完这一页之后继续按
///     60Hz 空转(歌词窗口那次"离屏探针实测五种不可见状态都还是 ~63 次/秒"就是这么发现的)。
///     `run` 置 nil 之后这棵子树整个不存在,不靠 `paused:` 兜。
///
///  3. **`reduceMotion` 下整个不画**。它是纯装饰、不承载任何状态含义(该说的话由那一页的
///     「一切就绪」和体检清单说),辅助功能设置里要求减少动态效果时没有任何理由折中 ——
///     跟灵动岛那批 `reduceMotion ? nil : .spring(...)` 不同,那些补间背后还有"点到了"的
///     功能反馈要保住,这里没有。
@MainActor
struct ConfettiOverlay: View {
    /// **换一个更大的值就重放一次**;0 = 还没触发过,什么都不画。
    ///
    /// 用计数器而不是 `Bool`:布尔在"已经 true 的时候再触发一次"这件事上表达不出来
    /// (用户从最后一页退回去、再翻回来,应该再撒一次)。
    var burst: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: Run?

    /// 正在放的这一阵:哪一场雪 + 从哪一刻起算。两个值必须一起换,所以捆在一个可选里 ——
    /// 分成两个 @State 会有"新场雪配旧起点"的中间帧。
    private struct Run {
        let field: ConfettiField
        let start: Date
    }

    /// 每场雪的 seed 基数。掺进 `burst` 之后:重跑引导时不是同一场雪,而给定 burst 仍然完全
    /// 确定(core 那边"同一个 seed 同一场雪"的断言照样成立)。
    private static let baseSeed: UInt64 = 0x436F_6E66_6574_7469
    /// 帧间隔上限 = 60Hz。ProMotion 屏上 `.animation` 不设上限就是 120Hz,而纸片下落这种
    /// 匀速平移在 60Hz 已经完全看不出台阶,多出来的一半帧是白花的合成开销。
    private static let frameInterval: TimeInterval = 1.0 / 60.0
    /// 纸片配色。
    ///
    /// 刻意写死 sRGB 而不是用 `.red` / `.green` 这些语义色:语义色会跟着「增强对比度」这类
    /// 辅助功能设置和深浅色一起变,而撒花的颜色不表达任何状态,没有理由跟着变;固定值也让
    /// 深色背景下这几片不至于被系统压暗成糊的一团。槽位数跟 `ConfettiField.colorCount`
    /// 对齐,取用时仍然 `%` 一次兜底(两边数目哪天不一致也不越界)。
    private static let palette: [Color] = [
        Color(.sRGB, red: 1.00, green: 0.23, blue: 0.19),  // 红
        Color(.sRGB, red: 1.00, green: 0.58, blue: 0.00),  // 橙
        Color(.sRGB, red: 1.00, green: 0.80, blue: 0.00),  // 黄
        Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35),  // 绿
        Color(.sRGB, red: 0.20, green: 0.68, blue: 0.90),  // 青
        Color(.sRGB, red: 0.00, green: 0.48, blue: 1.00),  // 蓝
        Color(.sRGB, red: 0.69, green: 0.32, blue: 0.87),  // 紫
    ]

    var body: some View {
        // Group 而不是 ZStack:不放的时候这一层要彻底是空的(ZStack 空着也仍是一个布局容器)。
        Group {
            if let run {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
                    Canvas { gc, size in
                        draw(&gc, size: size, run: run, now: context.date)
                    }
                }
            }
        }
        // 撒花从不吃点击:它盖在「开始使用」那颗按钮上面。
        .allowsHitTesting(false)
        .task(id: burst) { await play() }
    }

    private func play() async {
        guard burst > 0, !reduceMotion else {
            run = nil
            return
        }
        // 片数/落速/出场窗口是一组一起调出来的参数,连同调参依据都在 `ConfettiField` 那边,
        // 这里不复述也不覆盖(同一个数字两处写就会漂)。
        let field = ConfettiField(seed: Self.baseSeed &+ UInt64(burst))
        run = Run(field: field, start: Date())
        try? await Task.sleep(for: .seconds(field.duration))
        // ⚠️ 这道 guard 不能省。`.task(id:)` 换 id 时是"先取消旧任务、再起新任务",而被取消的
        // `Task.sleep` 只是抛错、`try?` 把它吞了,后面这行照样会跑 —— 于是旧任务的收尾把
        // 新任务刚设上的 `run` 清掉,表现成"退回去再翻到最后一页,撒花闪一下就没了"。
        guard !Task.isCancelled else { return }
        run = nil
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, run: Run, now: Date) {
        let elapsed = now.timeIntervalSince(run.start)
        for piece in run.field.pieces {
            guard let state = run.field.state(of: piece, elapsed: elapsed, in: size) else { continue }
            let rect = CGRect(x: -state.width / 2, y: -state.height / 2,
                              width: state.width, height: state.height)
            // 先绕原点转、再平移到落点(`concatenating` 是"先自己、后参数")。
            let placed = CGAffineTransform(rotationAngle: state.angle)
                .concatenating(CGAffineTransform(translationX: state.center.x, y: state.center.y))
            let path = Path(roundedRect: rect, cornerRadius: min(1.5, state.width / 3))
                .applying(placed)
            context.fill(path, with: .color(Self.palette[state.colorIndex % Self.palette.count]))
        }
    }
}
