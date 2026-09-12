import CoreGraphics
import Foundation
import LyrimuseCore

// 引导页的纯逻辑。目前只有最后一页那阵撒花的几何(`ConfettiField`)——
// 引导页别的东西(步数怎么算、哪一步锁下一步、配对逻辑只有一份)靠 contracts 组的源码扫描
// 守着,那些断言留在那边,别搬。
func runOnboardingTests() {
    // ---- 撒花:同一个 seed 同一场雪 ----
    //
    // 这条是下面所有断言的前提:core 里那个 SplitMix64 是自己写的,一旦有人图省事换成
    // `Double.random(in:)`,下面每一条都会变成"这次跑过了、下次不一定",而不是当场红。
    do {
        let a = ConfettiField(pieceCount: 40, seed: 12345)
        let b = ConfettiField(pieceCount: 40, seed: 12345)
        expectEqual(a.pieces, b.pieces, "撒花: 同一个 seed 生成同一场雪")
        expectEqual(a.duration, b.duration, "撒花: 同一个 seed 生成同一个时长")
        let c = ConfettiField(pieceCount: 40, seed: 12346)
        expectNotEqual(c.pieces, a.pieces, "撒花: 换 seed 就该是另一场雪(引导重跑一次不撒同一阵)")
    }

    // ---- 撒花:片数与时长 ----
    do {
        expectEqual(ConfettiField(pieceCount: 90, seed: 7).pieces.count, 90, "撒花: 片数按参数来")
        let empty = ConfettiField(pieceCount: 0, seed: 7)
        expectEqual(empty.pieces.isEmpty, true, "撒花: 0 片就是空的")
        expectEqual(empty.duration, 0, "撒花: 空的一阵时长 0(View 那边拿它当 sleep 时长,不能是负数或 nan)")
        expectEqual(ConfettiField(pieceCount: -5, seed: 7).pieces.isEmpty, true, "撒花: 负数片数当 0,不崩")

        let field = ConfettiField(pieceCount: 90, seed: 7)
        let latest = field.pieces.map { $0.delay + $0.fall }.max() ?? 0
        expectEqual(field.duration, latest, "撒花: 时长 = 最后出场那片落完的时刻")
        // 出场窗口和落速都收在 core 的常量里;这条只钉"没有哪片会在整阵结束之后才出场"。
        let lateComers = field.pieces.filter { $0.delay > ConfettiField.spawnWindow || $0.fall <= 0 }.count
        expectEqual(lateComers, 0, "撒花: 每片都在出场窗口内出场、落速为正")
    }

    // ---- 撒花:两头都在画面外(整阵能自己收干净)----
    //
    // ⚠️ 这一组是这份几何存在的理由,别删。View 层是靠"`duration` 到点把整个 TimelineView
    // 摘掉"来停掉逐帧刷新的(`ConfettiOverlay`),所以:
    //  ① 到 `duration` 那一刻还有纸片停在画面里 = 用户看到"撒花撒了一半被整块抹掉";
    //  ② `elapsed == 0` 那一刻就有纸片在画面里 = 纸片凭空出现在画面中间,不是"落下来"。
    do {
        let size = CGSize(width: 480, height: 420)   // 引导窗那扇
        let field = ConfettiField(pieceCount: 90, seed: 7)

        var stillVisibleAtEnd: [String] = []
        var alreadyVisibleAtStart: [String] = []
        var neverCrossed: [String] = []
        var badColor: [String] = []
        var badWidth: [String] = []
        var wentBackUp: [String] = []

        for (index, piece) in field.pieces.enumerated() {
            if piece.colorIndex < 0 || piece.colorIndex >= ConfettiField.colorCount {
                badColor.append("#\(index)=\(piece.colorIndex)")
            }
            if let end = field.state(of: piece, elapsed: field.duration, in: size),
               end.center.y - piece.span < size.height {
                stillVisibleAtEnd.append("#\(index)@y=\(end.center.y)")
            }
            if let begin = field.state(of: piece, elapsed: 0, in: size),
               begin.center.y + piece.span > 0 {
                alreadyVisibleAtStart.append("#\(index)@y=\(begin.center.y)")
            }
            // 行程正中间那一刻必须真的在画面里 —— 不然这片纸屑等于没参与撒花
            // (比如把起点/终点算反、或者 fall 算成负的)。
            let middle = piece.delay + piece.fall / 2
            guard let mid = field.state(of: piece, elapsed: middle, in: size) else {
                neverCrossed.append("#\(index)=没落点")
                continue
            }
            if mid.center.y <= 0 || mid.center.y >= size.height {
                neverCrossed.append("#\(index)@y=\(mid.center.y)")
            }
            // 翻面只该让它变窄,不该变宽、也不该缩到零(缩到零那一帧看着像闪)。
            if mid.width > piece.width || mid.width < ConfettiField.minRenderedWidth {
                badWidth.append("#\(index)=\(mid.width)/\(piece.width)")
            }
            // 只往下落。飘摆走的是横轴,纵轴上任何回弹都是算错了。
            let quarter = field.state(of: piece, elapsed: piece.delay + piece.fall / 4, in: size)
            if let quarter, quarter.center.y > mid.center.y {
                wentBackUp.append("#\(index)")
            }
        }

        expectEqual(stillVisibleAtEnd, [], "撒花: 到 duration 那一刻每片都已整片落出下沿(否则收尾会被整块抹掉)")
        expectEqual(alreadyVisibleAtStart, [], "撒花: elapsed=0 时每片都还在上沿之外(不是凭空出现在画面中间)")
        expectEqual(neverCrossed, [], "撒花: 每片在自己行程的中点都在画面里(真的穿过画面)")
        expectEqual(badColor, [], "撒花: 色号都在调色板槽位内")
        expectEqual(badWidth, [], "撒花: 翻面只让纸片变窄,且不会缩到看不见")
        expectEqual(wentBackUp, [], "撒花: 纵轴只往下,不回弹")
    }

    // ---- 撒花:出场前 / 落完后 / 空画布都没有落点 ----
    do {
        let size = CGSize(width: 480, height: 420)
        let field = ConfettiField(pieceCount: 24, seed: 99)
        // 不写 `guard … else { return }`:这里 return 的是整个 runOnboardingTests(),
        // 以后在后面加小节会被静默跳过(拿到假绿)。
        if let piece = field.pieces.first(where: { $0.delay > 0.05 }) {
            expectEqual(field.state(of: piece, elapsed: piece.delay - 0.01, in: size) == nil, true,
                        "撒花: 还没到出场时间就没有落点")
            expectEqual(field.state(of: piece, elapsed: piece.delay + piece.fall + 0.01, in: size) == nil, true,
                        "撒花: 落完之后就没有落点(View 靠这个少画一片)")
            expectEqual(field.state(of: piece, elapsed: piece.delay + 0.1, in: .zero) == nil, true,
                        "撒花: 画布还没量出尺寸时不给落点,不拿 0 去除")
        } else {
            expectEqual(true, false, "撒花: 这场雪里没有一片是延迟出场的(样本不对)")
        }
    }
}
