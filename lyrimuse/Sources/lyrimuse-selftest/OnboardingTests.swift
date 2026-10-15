import CoreGraphics
import Foundation
import LyrimuseCore

// 引导页的纯逻辑:流程判断(`OnboardingFlow`:走哪几步、翻页夹下标、锁、收尾标记、体检清单、
// 收尾页顺序)、第一页开场的时间轴与月桂冠几何(`OnboardingIntro` / `LaurelWreath`)和最后一页那阵撒花的几何(`ConfettiField`)。
// 「两个宿主只有一份实现」「引导页走的是这些函数」这类跨文件约束靠 contracts 组的源码扫描守着,
// 那些断言留在那边;勾选切换与勾选即请求权限这两个共享判据在 players 组。
func runOnboardingTests() {
    checkOnboardingFlow()
    checkOnboardingIntro()
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
    // 这一组是这份几何存在的理由,别删。View 层是靠"`duration` 到点把整个 TimelineView
    // 摘掉"来停掉逐帧刷新的(`ConfettiOverlay`),所以:
    //  ① 到 `duration` 那一刻还有纸片停在画面里 = 用户看到"撒花撒了一半被整块抹掉";
    //  ② `elapsed == 0` 那一刻就有纸片在画面里 = 纸片凭空出现在画面中间,不是"落下来"。
    do {
        let size = CGSize(width: 480, height: 500)   // 引导窗那扇
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
        let size = CGSize(width: 480, height: 500)
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

private func checkOnboardingFlow() {
    typealias F = OnboardingFlow
    let allSteps: [OnboardingStep] = [.welcome, .playerChoice, .browserPairing, .background, .displayMode, .done]

    // ---- 步骤序列 ----
    do {
        print("\n== 引导流程:步骤序列 ==")
        let minimal = F.steps(.init(wantsBrowserPairing: false))
        expectEqual(minimal, [.welcome, .playerChoice, .background, .displayMode, .done],
                    "引导步骤: 没勾 YouTube Music 时是固定的五步")
        expectEqual(minimal.count, F.minimumStepCount, "引导步骤: 固定步数就是 minimumStepCount")
        expectEqual(F.steps(.init(wantsBrowserPairing: true)), allSteps,
                    "引导步骤: 勾了 YouTube Music 时配对浏览器紧跟选播放器,共六步")
        expectEqual(Set(allSteps).count, allSteps.count, "引导步骤: 没有重复的步骤")
    }

    // ---- 翻页与防越界 ----
    do {
        print("\n== 引导流程:翻页与防越界 ==")
        expectEqual(F.clampedIndex(-1, count: 5), 0, "引导翻页: 负下标夹到 0")
        expectEqual(F.clampedIndex(99, count: 5), 4, "引导翻页: 超出的下标夹到最后一步")
        expectEqual(F.clampedIndex(3, count: 5), 3, "引导翻页: 合法下标原样")
        expectEqual(F.clampedIndex(3, count: 0), 0, "引导翻页: 空序列不崩")
        expectEqual(F.step(at: -5, in: allSteps), .welcome, "引导翻页: 负下标取到第一步")
        expectEqual(F.step(at: 42, in: allSteps), .done, "引导翻页: 超出的下标取到最后一步")
        expectEqual(F.step(at: 0, in: []), .welcome, "引导翻页: 空序列不崩")

        // 真崩过的那条路:停在最后一步时,设置窗口里改了选择,序列短一截。
        let before = F.steps(.init(wantsBrowserPairing: true))
        let atDone = before.count - 1
        let after = F.steps(.init(wantsBrowserPairing: false))
        expectEqual(F.step(at: atDone, in: after), .done, "引导翻页: 停在最后一步时序列变短,取到的仍是最后一步(不越界)")
        let shrunk = F.clamped(.init(step: atDone, furthest: atDone), stepCount: after.count)
        expectEqual(shrunk, F.Position(step: after.count - 1, furthest: after.count - 1),
                    "引导翻页: 序列变短后两个存储值都拉回最后一步")
        expectEqual(F.clamped(.init(step: 2, furthest: 3), stepCount: 5), F.Position(step: 2, furthest: 3),
                    "引导翻页: 没越界的位置原样")
        expectEqual(F.clamped(.init(step: -1, furthest: -1), stepCount: 5), F.Position(step: 0, furthest: 0),
                    "引导翻页: 负数拉回 0")

        let start = F.Position(step: 0, furthest: 0)
        let forward = F.navigate(to: 1, from: start, stepCount: 5)
        expectEqual(forward, F.Position(step: 1, furthest: 1), "引导翻页: 下一步推进走到过的最远处")
        let farther = F.navigate(to: 3, from: forward, stepCount: 5)
        let back = F.navigate(to: 2, from: farther, stepCount: 5)
        expectEqual(back, F.Position(step: 2, furthest: 3), "引导翻页: 往回翻不缩小走到过的最远处")
        expectEqual(F.navigate(to: 99, from: back, stepCount: 5), F.Position(step: 4, furthest: 4),
                    "引导翻页: 翻过头夹到最后一步")
        expectEqual(F.navigate(to: -3, from: back, stepCount: 5), F.Position(step: 0, furthest: 3),
                    "引导翻页: 翻到负数夹到第一步,最远处不变")

        expectEqual(F.canJump(toDot: 2, furthest: 3), true, "引导进度点: 走到过的点能点回去")
        expectEqual(F.canJump(toDot: 3, furthest: 3), true, "引导进度点: 最远那一点能点")
        expectEqual(F.canJump(toDot: 4, furthest: 3), false, "引导进度点: 没走到的点不能点(会绕过歌词引擎那道锁)")
        expectEqual(F.canJump(toDot: -1, furthest: 3), false, "引导进度点: 负下标不能点")

        expectEqual(F.index(of: .browserPairing, in: allSteps), 2, "引导「去处理」: 在序列里就跳到它")
        expectEqual(F.index(of: .browserPairing, in: F.steps(.init(wantsBrowserPairing: false))), nil,
                    "引导「去处理」: 本轮没这一步就不跳")
    }

    // ---- 锁与收尾 ----
    do {
        print("\n== 引导流程:锁与收尾 ==")
        expectEqual(F.nextIsLocked(at: .background, engineRunning: false), true,
                    "引导锁: 「让它跑起来」那一页、歌词引擎没在跑时锁住下一步")
        expectEqual(F.nextIsLocked(at: .background, engineRunning: true), false,
                    "引导锁: 歌词引擎跑起来就解锁(那一页的权限小节不参与锁)")
        let lockedElsewhere = allSteps.filter { $0 != .background && F.nextIsLocked(at: $0, engineRunning: false) }
        expectEqual(lockedElsewhere, [], "引导锁: 除「让它跑起来」外哪一步都不锁")
        expectEqual(F.marksCompleted(engineRunning: true), true, "引导收尾: 歌词引擎在跑,点开始使用记成走完")
        expectEqual(F.marksCompleted(engineRunning: false), false,
                    "引导收尾: 歌词引擎没跑就不记走完(否则窗口不再出现、引擎也装不上)")
    }

    // ---- 体检清单 ----
    do {
        print("\n== 引导流程:体检清单 ==")
        let minimal = F.readinessItems(.init(engineRunning: true, automationTargets: [], authorized: [],
                                             fullDiskAccessGranted: nil, browserPaired: nil, displayModeEnabled: true))
        expectEqual(minimal.map(\.kind), [.engine, .displayMode], "体检清单: 没有权限要求、没勾 YouTube Music 时只有两行")
        expectEqual(minimal.allSatisfy(\.ok), true, "体检清单: 都好时全绿")

        let full = F.readinessItems(.init(engineRunning: false, automationTargets: [.appleMusic, .spotify],
                                          authorized: [.appleMusic], fullDiskAccessGranted: false,
                                          browserPaired: false, displayModeEnabled: false))
        expectEqual(full.map(\.kind), [.engine, .automation(.appleMusic), .automation(.spotify),
                                        .fullDiskAccess, .browser, .displayMode],
                    "体检清单: 该要的各一行,自动化权限一家一行、顺序跟那一页一致")
        expectEqual(full.map(\.ok), [false, true, false, false, false, false],
                    "体检清单: 每行好没好按对应事实判(只授权了 Apple Music)")
        expectEqual(full.map(\.target), [.background, .background, .background, .background, .browserPairing, .displayMode],
                    "体检清单: 歌词引擎和两类权限都跳回「让它跑起来」,其余跳回各自那一页")
        expectEqual(Set(full.map(\.id)).count, full.count, "体检清单: 每行 id 不重复(ForEach 靠它)")
        let granted = F.readinessItems(.init(engineRunning: true, automationTargets: [], authorized: [],
                                             fullDiskAccessGranted: true, browserPaired: true, displayModeEnabled: true))
        expectEqual(granted.map(\.kind), [.engine, .fullDiskAccess, .browser, .displayMode],
                    "体检清单: 走过且已就绪的照样列出(全绿时页面不显示清单,但判定要算进去)")
        expectEqual(granted.allSatisfy(\.ok), true, "体检清单: 都就绪时全绿")
        let withAX = F.readinessItems(.init(engineRunning: true, automationTargets: [], authorized: [],
                                            fullDiskAccessGranted: false, browserPaired: nil, displayModeEnabled: true,
                                            accessibilityGranted: false))
        expectEqual(withAX.map(\.kind), [.engine, .fullDiskAccess, .accessibility, .displayMode],
                    "体检清单: 勾了 Amazon Music 时多一行辅助功能,排在完全磁盘访问后面(跟那一页同序)")
        expectEqual(withAX.first { $0.kind == .accessibility }.map { [$0.target == .background, $0.isOptional] }, [true, true],
                    "体检清单: 辅助功能跳回「让它跑起来」,是推荐项")
        expectEqual(F.requiredReady(withAX), true, "体检清单: 只有辅助功能没开时仍是「一切就绪」")
        expectEqual(Set(withAX.map(\.id)).count, withAX.count, "体检清单: 加上辅助功能后 id 仍不重复")

        // 清单里每一条「去处理」都必须能跳到本轮真的存在的那一页,否则按钮点了没反应。
        var unreachable: [String] = []
        for browser in [false, true] {
            let items = F.readinessItems(.init(
                engineRunning: false, automationTargets: [.appleMusic], authorized: [],
                fullDiskAccessGranted: false, browserPaired: browser ? false : nil, displayModeEnabled: false))
            let list = F.steps(.init(wantsBrowserPairing: browser))
            unreachable += items.filter { F.index(of: $0.target, in: list) == nil }.map { "browser=\(browser): \($0.kind)" }
        }
        expectEqual(unreachable, [], "体检清单: 每条「去处理」的目标都在本轮步骤里")
    }

    // ---- 收尾页「你选的播放器」----
    do {
        print("\n== 引导流程:收尾页顺序 ==")
        let order: [PlaybackPlayer] = [.appleMusic, .spotify, .qqMusic, .netease, .auto]
        let yt = "youtubeMusic"
        expectEqual(F.chosenEntries(players: [.spotify, .appleMusic], displayOrder: order, webPlatformID: nil),
                    [.player(.appleMusic), .player(.spotify)], "收尾页: 具体播放器按 displayOrder 排,不按集合迭代顺序")
        expectEqual(F.chosenEntries(players: [.qqMusic], displayOrder: order, webPlatformID: yt),
                    [.player(.qqMusic), .webPlatform(yt)], "收尾页: 网页平台排在具体播放器后面")
        expectEqual(F.chosenEntries(players: [.auto, .spotify], displayOrder: order, webPlatformID: yt),
                    [.webPlatform(yt), .player(.auto)],
                    "收尾页: 勾着自动识别时单独勾的播放器不列;自动识别排在 YouTube Music 后面垫底")
        expectEqual(F.chosenEntries(players: [.auto], displayOrder: order.filter { $0 != .auto }, webPlatformID: nil),
                    [], "收尾页: 自动识别从 displayOrder 里取,那份顺序不收它时就不出现")
        expectEqual(F.chosenEntries(players: [.soda], displayOrder: order, webPlatformID: nil), [],
                    "收尾页: 不在 displayOrder 里的播放器不凭空出现")
    }

    // ---- 推荐项(自动化权限 / 完全磁盘访问没开不算没做完)----
    do {
        print("\n== 引导流程:推荐项 ==")
        let optionalOff = F.readinessItems(.init(engineRunning: true, automationTargets: [.spotify], authorized: [],
                                                 fullDiskAccessGranted: false, browserPaired: nil, displayModeEnabled: true))
        expectEqual(optionalOff.filter(\.isOptional).map(\.kind), [.automation(.spotify), .fullDiskAccess],
                    "推荐项: 自动化权限和完全磁盘访问是推荐项")
        expectEqual(F.requiredReady(optionalOff), true, "推荐项: 只有推荐项没开时仍是「一切就绪」")
        let browserMissing = F.readinessItems(.init(engineRunning: true, automationTargets: [], authorized: [],
                                                    fullDiskAccessGranted: nil, browserPaired: false, displayModeEnabled: true))
        expectEqual(F.requiredReady(browserMissing), false, "推荐项: 勾了 YouTube Music 却没配浏览器,是真没做完")
        let noEngine = F.readinessItems(.init(engineRunning: false, automationTargets: [], authorized: [],
                                                 fullDiskAccessGranted: nil, browserPaired: nil, displayModeEnabled: true))
        expectEqual(F.requiredReady(noEngine), false, "推荐项: 后台服务没跑是真没做完")
        let noDisplay = F.readinessItems(.init(engineRunning: true, automationTargets: [], authorized: [],
                                               fullDiskAccessGranted: nil, browserPaired: nil, displayModeEnabled: false))
        expectEqual(F.requiredReady(noDisplay), false, "推荐项: 显示方式全关是真没做完")
    }

    // ---- 歌词显示方式(触控栏只在这台 Mac 有触控栏时算)----
    do {
        print("\n== 引导流程:歌词显示方式 ==")
        func enabled(overlay: Bool = false, notch: Bool = false, menuBar: Bool = false,
                     touchBar: Bool = false, present: Bool = false) -> Bool {
            F.anyDisplayModeEnabled(overlay: overlay, notch: notch, menuBar: menuBar,
                                    touchBar: touchBar, touchBarPresent: present)
        }
        expectEqual(enabled(), false, "显示方式: 一种都没开")
        expectEqual(enabled(overlay: true), true, "显示方式: 只开悬浮歌词")
        expectEqual(enabled(notch: true), true, "显示方式: 只开灵动岛")
        expectEqual(enabled(menuBar: true), true, "显示方式: 只开菜单栏歌词")
        expectEqual(enabled(touchBar: true, present: true), true, "显示方式: 只开触控栏歌词、这台 Mac 有触控栏,算开着")
        expectEqual(enabled(touchBar: true), false, "显示方式: 触控栏歌词开着、这台 Mac 没有触控栏,不算(开着也不显示)")
        expectEqual(enabled(present: true), false, "显示方式: 有触控栏但没开,不算")
        expectEqual(enabled(menuBar: true, touchBar: true), true, "显示方式: 没有触控栏时别的照样算")
    }

    // ---- 后台服务自动启用 / 授权后带回前台 ----
    do {
        print("\n== 引导流程:自动启用与带回前台 ==")
        expectEqual(F.autoStartsBackgroundService(at: .background, engineRunning: false, installing: false, lastAttemptFailed: false),
                    true, "自动启用: 走到后台服务那一步、服务没跑就开始装")
        expectEqual(F.autoStartsBackgroundService(at: .background, engineRunning: true, installing: false, lastAttemptFailed: false),
                    false, "自动启用: 已经在跑不再装")
        expectEqual(F.autoStartsBackgroundService(at: .background, engineRunning: false, installing: true, lastAttemptFailed: false),
                    false, "自动启用: 正在装不重复发起")
        expectEqual(F.autoStartsBackgroundService(at: .background, engineRunning: false, installing: false, lastAttemptFailed: true),
                    false, "自动启用: 上次装失败了,翻回来不自动重试(等用户点重试)")
        let elsewhere = allSteps.filter { $0 != .background &&
            F.autoStartsBackgroundService(at: $0, engineRunning: false, installing: false, lastAttemptFailed: false) }
        expectEqual(elsewhere, [], "自动启用: 只在后台服务那一步发生")
        expectEqual(F.bringsBackAfterGrant(grantedBefore: 0, grantedNow: 1, appIsActive: false), true,
                    "带回前台: 窗口在后面时刚多授权了一项 → 带回来")
        expectEqual(F.bringsBackAfterGrant(grantedBefore: 1, grantedNow: 2, appIsActive: false), true,
                    "带回前台: 已有一项、又授权了一项 → 也带回来")
        expectEqual(F.bringsBackAfterGrant(grantedBefore: 0, grantedNow: 1, appIsActive: true), false,
                    "带回前台: 本来就在前台不用抢")
        expectEqual(F.bringsBackAfterGrant(grantedBefore: 2, grantedNow: 2, appIsActive: false), false,
                    "带回前台: 数量没变,每次刷新不重复抢焦点")
        expectEqual(F.bringsBackAfterGrant(grantedBefore: 2, grantedNow: 1, appIsActive: false), false,
                    "带回前台: 权限被撤不抢焦点")
    }

    // ---- 收尾页「放一首歌试试」----
    do {
        print("\n== 引导流程:放一首歌试试 ==")
        func input(_ title: String = "晴天", lyrics: Bool = false, instrumental: Bool = false, none: Bool = false,
                   ad: Bool = false, offline: Bool = false) -> F.LiveInput {
            F.LiveInput(title: title, artist: "周杰伦", hasLyrics: lyrics, instrumental: instrumental,
                        noLyrics: none, adBreak: ad, networkDown: offline)
        }
        expectEqual(F.liveCheck(input("")), .notPlaying, "放一首歌试试: 没读到曲目 → 提示放一首")
        expectEqual(F.liveCheck(input("", lyrics: true)), .notPlaying, "放一首歌试试: 没有曲目时其它标志都不算")
        expectEqual(F.liveCheck(input(ad: true, offline: true)), .adBreak, "放一首歌试试: 广告优先")
        expectEqual(F.liveCheck(input(lyrics: true, offline: true)), .lyricsReady, "放一首歌试试: 歌词在手时断网不影响")
        expectEqual(F.liveCheck(input(instrumental: true)), .instrumental, "放一首歌试试: 纯音乐")
        expectEqual(F.liveCheck(input(none: true, offline: true)), .noLyrics, "放一首歌试试: 确定没歌词排在断网前")
        expectEqual(F.liveCheck(input(offline: true)), .offline, "放一首歌试试: 还在找又断网 → 网络问题")
        expectEqual(F.liveCheck(input()), .searching, "放一首歌试试: 其余情况是还在找")
    }
}

// 第一页开场(14 章决策 109):时间轴的先后、光点可复现、光球落在图标上、月桂冠不压图标。
private func checkOnboardingIntro() {
    typealias I = OnboardingIntro

    // ---- 缓动曲线 ----
    for (name, curve) in [("ease", I.Curve.ease), ("soft", I.Curve.soft), ("easeInOut", I.Curve.easeInOut)] {
        expectEqual(abs(curve(0)) < 1e-6 && abs(curve(1) - 1) < 1e-6, true, "开场缓动: \(name) 两端是 0 和 1")
    }
    let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { I.Curve.soft($0) }
    let peak = samples.max() ?? 0
    expectEqual(peak > 1 && peak < 1.06, true, "开场缓动: soft 只带一点点回弹(过冲在 6% 以内),实际峰值 \(peak)")
    expectEqual(I.Segment(1, 2).progress(0), 0, "开场时间段: 段前是 0")
    expectEqual(I.Segment(1, 2).progress(5), 1, "开场时间段: 段后是 1")

    // ---- 时间轴的先后 ----
    expectEqual(I.islandEarsOpen.start < I.islandDrop.start, true, "开场时间轴: 灵动岛先长出耳朵,再往下长出歌词那一行")
    expectEqual(I.islandDrop.end <= I.sing.start + 0.35, true, "开场时间轴: 灵动岛基本展开了才开始唱")
    expectEqual(I.islandDropClose.start < I.islandEarsClose.start, true, "开场时间轴: 收回时先收歌词那一行,再收耳朵")
    expectEqual(I.sing.end <= I.burstStart, true, "开场时间轴: 唱完才碎成光点")
    expectEqual((0..<I.stringCount).allSatisfy { I.pluckStart($0) >= I.sing.start && I.pluckStart($0) <= I.sing.end }, true,
                "开场时间轴: 五根弦都在唱的那段里被拨响")
    expectEqual(I.bloomStart < I.orbFlight.start && I.orbFlight.start <= I.islandEarsClose.start
                    && I.orbFlight.end <= I.flash.start + 0.25, true,
                "开场时间轴: 灵动岛开始收回 → 收耳朵的同时挤出光球(不留空档) → 落地,落地前后闪光")
    expectEqual(I.nightOut.end <= I.handoff + 0.6, true, "开场时间轴: 底色基本褪掉时欢迎页才进场")
    expectEqual(I.flash.start < I.handoff && I.handoff < I.end && I.flash.end <= I.end && I.nightOut.end <= I.end, true,
                "开场时间轴: 闪光和亮灯在开场摘掉之前收干净")
    expectEqual(I.lyreStrokeDelays.count, 5 + I.stringCount, "开场时间轴: 里拉琴五笔琴身 + 五根弦各有描线延迟")

    // ---- 灵动岛:刘海 → 展开 → 收回刘海 ----
    let notch = CGSize(width: 110, height: 24)
    func island(_ t: Double) -> CGSize { I.islandSize(t, notch: notch, earsWidth: 202, openWidth: 260, openHeight: 58) }
    expectEqual(island(0), notch, "开场灵动岛: 一开始就是刘海大小")
    let earsOnly = island(I.islandDrop.start)
    expectEqual(earsOnly.height == notch.height && earsOnly.width > notch.width, true,
                "开场灵动岛: 往下展开之前只长耳朵(变宽),高度还是刘海那么高")
    expectEqual(island(I.islandDrop.end), CGSize(width: 260, height: 58), "开场灵动岛: 展开段结束时正好是唱歌的大小")
    expectEqual(island(I.end), notch, "开场灵动岛: 最后收回刘海大小")

    // ---- 光球最后正好是图标 ----
    let target = CGPoint(x: 240, y: 180)
    let landed = I.orbState(I.end, centerX: 240, notchBottom: 24, target: target)
    expectEqual(abs(landed.center.x - target.x) < 1e-6 && abs(landed.center.y - target.y) < 1e-6, true, "开场光球: 落在图标中心")
    expectEqual(abs(landed.diameter - 84) < 1e-6 && abs(landed.radius - 21) < 1e-6 && landed.icon == 1 && landed.stretch == 0, true,
                "开场光球: 落地是图标的大小和圆角,图标完全显出来,没有拉长")
    let midFlight = I.orbState(I.orbFlight.start + I.orbFlight.duration * 0.7, centerX: 240, notchBottom: 24, target: target)
    expectEqual(midFlight.icon > 0 && midFlight.icon < 1, true, "开场光球: 后半程图标和光球交叠着换过去,不是到点一下子换")
    expectEqual(I.orbState(0, centerX: 240, notchBottom: 24, target: target).opacity, 0, "开场光球: 滴出来之前看不见")

    // ---- 光点:可复现、个数、都在开场摘掉前到达 ----
    func evenSpans(count: Int, from start: Double, width: Double) -> [ClosedRange<Double>] {
        var spans: [ClosedRange<Double>] = []
        for index in 0..<count {
            let lower = start + Double(index) * width
            spans.append(lower...(lower + width))
        }
        return spans
    }
    let spans = evenSpans(count: 9, from: 100, width: 30)
    let island = CGPoint(x: 240, y: 20)
    let a = I.particles(charSpans: spans, lineTop: 380, lineHeight: 44, target: island, seed: 42)
    let b = I.particles(charSpans: spans, lineTop: 380, lineHeight: 44, target: island, seed: 42)
    expectEqual(a, b, "开场光点: 同一个 seed 同一阵光点")
    expectEqual(a.count, spans.count * I.particlesPerChar, "开场光点: 每个字 \(I.particlesPerChar) 颗")
    let lineRange = spans[0].lowerBound...spans[spans.count - 1].upperBound
    expectEqual(a.allSatisfy { lineRange.contains(Double($0.origin.x)) }, true,
                "开场光点: 都从这一行字里出发")
    expectEqual(I.burstStart + I.particlesDuration(a) < I.end, true, "开场光点: 开场摘掉之前全部飞到")
    let longLine = evenSpans(count: 26, from: 0, width: 16)
    let long = I.particles(charSpans: longLine, lineTop: 380, lineHeight: 44, target: island, seed: 7)
    expectEqual(I.burstStart + I.particlesDuration(long) < I.end, true, "开场光点: 英文那句(二十多个字符)也在开场摘掉之前飞到")
    if let first = a.first {
        expectEqual(I.particleState(first, sinceBurst: first.delay - 0.01, target: island) == nil, true, "开场光点: 出发前不画")
        if let mid = I.particleState(first, sinceBurst: first.delay + first.duration / 2, target: island) {
            expectEqual(mid.alpha > 0 && mid.alpha <= 1, true, "开场光点: 半路的不透明度在 0...1")
        } else {
            expectEqual(true, false, "开场光点: 半路应该画得出来")
        }
        expectEqual(I.particleState(first, sinceBurst: first.delay + first.duration + 0.01, target: island) == nil, true,
                    "开场光点: 到了就不画")
    }

    // ---- 月桂冠:叶子不压图标、不出画布 ----
    let icon = LaurelWreath.iconRect
    func distance(_ p: CGPoint, to rect: CGRect) -> Double {
        let dx = max(Double(rect.minX) - Double(p.x), 0, Double(p.x) - Double(rect.maxX))
        let dy = max(Double(rect.minY) - Double(p.y), 0, Double(p.y) - Double(rect.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
    let points = LaurelWreath.leaves.flatMap(LaurelWreath.outline)
    let closest = points.map { distance($0, to: icon) }.min() ?? 0
    expectEqual(closest >= LaurelWreath.minimumClearance, true,
                "月桂冠: 每片叶子离图标至少 \(LaurelWreath.minimumClearance)pt(不跟图标叠在一起),实际最近 \(closest)")
    var stemPoints: [CGPoint] = []
    for stem in LaurelWreath.stems {
        for step in 0...50 { stemPoints.append(LaurelWreath.point(on: stem, Double(step) / 50)) }
    }
    let stemClosest = stemPoints.map { distance($0, to: icon) }.min() ?? 0
    expectEqual(stemClosest >= LaurelWreath.minimumClearance, true, "月桂冠: 枝也不压图标")
    let box = CGRect(x: 0, y: 0, width: LaurelWreath.box, height: LaurelWreath.box)
    expectEqual((points + stemPoints).allSatisfy { box.contains($0) }, true, "月桂冠: 枝叶都在画布里(不被裁掉)")
    expectEqual(LaurelWreath.leaves.count, LaurelWreath.stems.count * (LaurelWreath.nodesPerStem * 2 + 1),
                "月桂冠: 每根枝每个节点一对叶子,枝头一片顶叶")
    // 左右两根枝镜像:同一位置的叶子以画布中线对称。
    let mid = LaurelWreath.box / 2
    let half = LaurelWreath.leaves.count / 2
    var mirrored = true
    for index in 0..<half {
        let left = LaurelWreath.leaves[index], right = LaurelWreath.leaves[index + half]
        let dx = (Double(left.base.x) - mid) + (Double(right.base.x) - mid)
        let dy = Double(left.base.y) - Double(right.base.y)
        if abs(dx) > 1e-6 || abs(dy) > 1e-6 { mirrored = false }
    }
    expectEqual(mirrored, true, "月桂冠: 左右两根枝镜像对称")
}
