import LyrimuseCore
import Foundation
import CoreGraphics

// 灵动岛:展开区 / 对齐接线 / 音浪包络 / 出场几何 / 稳态宽-展开宽不变量。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runNotchTests() {
    // ---- 灵动岛展开区高度:按里面真正会渲染的东西算 ----
    //
    // 现象是「没有歌词的时候这块太大、很多空的地方」:展开区原来恒高 76 且 alignment .top,
    // 而三样内容里两样是条件渲染的(没歌词就没有预览行、没时长就没有进度条),两样都缺时
    // 里面只剩一排三键,剩下 41pt 全是底部空白。
    //
    // 这一组断言守两件事:①三样齐时**跟改动前逐字相等**(76),不是顺手改了既有布局;
    // ②每一段的增量正好是当初推出 76 时用的那几个数,不能被随手调松。
    do {
        typealias M = NotchExpandedMetrics
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true), 76,
                    "岛展开区: 有歌词有时长 = 76(必须跟改动前逐字相等)")
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true),
                    M.maxHeight(),
                    "岛展开区: 三样齐就等于窗口/预览容器用的那个 Max(默认参数)")
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: true), 59,
                    "岛展开区: 没歌词省掉预览行的 17pt")
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: false), 52,
                    "岛展开区: 没时长省掉进度条那 24pt")
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false), 35,
                    "岛展开区: 两样都没有只剩三键+底边距(用户截图里那个状态)")
        // 恒有的那一段必须够放下三键(22)+底边距(10),不然最下面那排会被 alignment .top 裁掉
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false) >= 32, true,
                    "岛展开区: 最小高度仍装得下三键+底边距,不会裁按钮")
        // 单调:多一样内容不能反而变矮
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: false)
                    > M.height(hasLyricPreview: false, hasScrubber: false), true,
                    "岛展开区: 加一段内容必须变高")
    }

    // ---- 展开区「曲目信息头部」+「下一句预览」用户开关 ----
    //
    // 两个新维度跟上面 hasLyricPreview/hasScrubber 那两个曲目级数据信号性质不同:是用户
    // 设置,设置一变会触发 NotchLyricsWindowController 重算几何(见该文件的六条订阅),
    // 所以 maxHeight 不必再像 hasScrubber 那样按"最坏情况"钉死——这组断言守的正是这条
    // 不对称:hasLyricPreviewPossible 能让 maxHeight 真的变小,trackInfoHeight 能让它真的变大。
    do {
        typealias M = NotchExpandedMetrics

        // trackInfoHeight 本身:0 = 四个开关全关,不占地方( 封面并回歌词行过
        // 一轮、后来又被要求重新加回头部自己一枚——现在**参与**这个函数的算术,固定贴文字块
        // 左边,不是"并排/堆叠"两选一那种复杂度,见 trackInfoHeight 的提醒)
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: false, showsArtist: false, showsAlbum: false), 0,
                    "曲目信息头部: 四个开关全关 = 0")
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: false, showsAlbum: false),
                    M.trackInfoTitleLineHeight,
                    "曲目信息头部: 只开歌名 = 歌名行高本身,没有多余间距")
        expectEqual(M.trackInfoHeight(showsArtwork: true, showsTitle: false, showsArtist: false, showsAlbum: false),
                    M.trackInfoArtworkSide,
                    "曲目信息头部: 只开封面 = 封面边长本身")
        // 三行文字都开:三档行高之和 + 两条行间距
        let threeLines = M.trackInfoTitleLineHeight + M.trackInfoArtistLineHeight + M.trackInfoAlbumLineHeight
            + 2 * M.trackInfoLineSpacing
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: true),
                    threeLines, "曲目信息头部: 三行文字 = 三档行高之和 + 两条行间距")
        // 单调:多开一行不能反而变矮
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: false)
                    > M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: false, showsAlbum: false),
                    true, "曲目信息头部: 多开一行文字必须变高")
        // 封面固定贴文字块左边,取 max 不取和:封面(32)比三行文字矮时,加封面不改变总高度;
        // 封面比文字高时,总高度等于封面高度,不是"封面+文字"叠加。
        expectEqual(M.trackInfoHeight(showsArtwork: true, showsTitle: true, showsArtist: true, showsAlbum: true),
                    max(M.trackInfoArtworkSide, threeLines),
                    "曲目信息头部: 封面+三行文字 = 两者较大值(并排,不是堆叠)")
        expectEqual(M.trackInfoHeight(showsArtwork: true, showsTitle: false, showsArtist: false, showsAlbum: false)
                    <= M.trackInfoHeight(showsArtwork: true, showsTitle: true, showsArtist: true, showsAlbum: true),
                    true, "曲目信息头部: 加文字不能让总高度比只有封面时矮")

        // 快捷操作:头部右侧那排按钮是并排的第三块,同样取 max 不取和。
        // 不传 = false,老调用点算出来的高度一个数都不变(上面那几条断言就是没传的)。
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: false, showsArtist: false, showsAlbum: false,
                                      showsActions: true),
                    M.trackInfoActionsHeight, "曲目信息头部: 四项全关只开快捷操作 = 按钮行高本身(22)")
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: true,
                                      showsActions: true),
                    threeLines, "曲目信息头部: 三行文字比按钮行高,开快捷操作不改高度")
        expectEqual(M.trackInfoHeight(showsArtwork: false, showsTitle: false, showsArtist: false, showsAlbum: true,
                                      showsActions: true),
                    max(M.trackInfoAlbumLineHeight, M.trackInfoActionsHeight),
                    "曲目信息头部: 只开一行矮文字时由按钮行撑高(max,不是叠加)")
        expectEqual(M.trackInfoActionsHeight, 22, "曲目信息头部: 按钮行高跟展开区播放控制三键的命中尺寸同档")

        // height(...) 把 trackInfoHeight 原样加一整块(含它自己的间距),0 = 完全不影响原有契约
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, trackInfoHeight: 0), 76,
                    "展开区高度: trackInfoHeight 传 0 必须跟原有契约逐字相等")
        // 两份间距(现象是"标题首行贴到上面边"):一份贴头部上边(离
        // topRow 的间距)、一份贴下边(离歌词行的间距),不是原来的一份。
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, trackInfoHeight: threeLines),
                    76 + threeLines + M.trackInfoTopSpacing + M.trackInfoSpacing,
                    "展开区高度: 有头部时整块 + 上下各一份间距一次性加上")

        // maxHeight 的两个新维度各自独立生效,且跟对应的 height(...) 严丝合缝(真正的不变量:
        // 窗口按 max 开、内容按当前设置算,给定同一组设置,两者必须相等,否则要么裁按钮要么白留空)
        expectEqual(M.maxHeight(hasLyricPreviewPossible: true, trackInfoHeight: 0), 76,
                    "岛展开区: 默认设置下 maxHeight 仍是 76")
        expectEqual(M.maxHeight(hasLyricPreviewPossible: false, trackInfoHeight: 0),
                    M.height(hasLyricPreview: false, hasScrubber: true, trackInfoHeight: 0),
                    "岛展开区: 关掉「下一句预览」开关后,maxHeight 必须真的变矮,且等于此时的 height(...)")
        expectEqual(M.maxHeight(hasLyricPreviewPossible: false, trackInfoHeight: 0), 59,
                    "岛展开区: 关掉「下一句预览」省下 17pt,跟没歌词时是同一个数(同一块内容)")
        expectEqual(M.maxHeight(hasLyricPreviewPossible: true, trackInfoHeight: threeLines),
                    M.height(hasLyricPreview: true, hasScrubber: true, trackInfoHeight: threeLines),
                    "岛展开区: 开着「下一句预览」+ 曲目信息头部拉满时,maxHeight 必须等于此时的 height(...)")
        // 单调性延伸到新维度:多一块内容(头部)不能反而让 max 变矮
        expectEqual(M.maxHeight(trackInfoHeight: threeLines) > M.maxHeight(trackInfoHeight: 0), true,
                    "岛展开区: 开曲目信息头部必须让 maxHeight 变高,不能纹丝不动")
    }

    // ---- 展开区「播放控制键」用户开关 ----
    //
    // 跟上面 hasLyricPreviewPossible 同一个性质:纯用户设置,不是曲目级数据信号,maxHeight
    // 不必按"最坏情况"钉死,关掉之后窗口真的能变矮。这组断言守:①默认(不传 hasControls)
    // 必须逐字维持改动前的既有契约,不能因为加了这个参数悄悄改变默认行为;②关掉之后正好
    // 省下 controlsBlock 这一整块,不多不少;③maxHeight 的新维度跟 height(...) 严丝合缝。
    do {
        typealias M = NotchExpandedMetrics
        // 默认参数(不传 hasControls)必须跟改动前逐字相等——这两条是上面第一组断言已经
        // 覆盖过的数字,这里重复断言是为了明确"加新参数没有偷偷改默认值"这件事本身。
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true), 76,
                    "播放控制键: 不传 hasControls 时必须维持改动前的默认值 76")
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false), 35,
                    "播放控制键: 不传 hasControls 时两样都没有仍是 35(默认开)")
        // 关掉播放控制键:整块(含它的 10pt 底边距)不占地方
        expectEqual(M.height(hasLyricPreview: false, hasScrubber: false, hasControls: false), 0,
                    "播放控制键: 三样(预览/进度条/控制键)都关 = 0,不留任何空白")
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, hasControls: false),
                    76 - M.controlsBlock,
                    "播放控制键: 关掉之后正好省下 controlsBlock 这一整块,不多不少")
        // 单调:关掉控制键不能反而变高
        expectEqual(M.height(hasLyricPreview: true, hasScrubber: true, hasControls: false)
                    < M.height(hasLyricPreview: true, hasScrubber: true, hasControls: true), true,
                    "播放控制键: 关掉之后总高度必须变矮")
        // maxHeight 的新维度:能让窗口真的变矮,且跟对应的 height(...) 严丝合缝
        expectEqual(M.maxHeight(hasControlsPossible: false),
                    M.height(hasLyricPreview: true, hasScrubber: true, hasControls: false),
                    "播放控制键: 关掉后 maxHeight 必须真的变矮,且等于此时的 height(...)")
        expectEqual(M.maxHeight(hasControlsPossible: false) < M.maxHeight(hasControlsPossible: true), true,
                    "播放控制键: maxHeight 关掉控制键必须比开着时矮")
    }

    // ---- 没有曲目时的空闲面板(05 章决策 #31)----
    //
    // 窗口恒按「顶行 + 歌词行 + maxHeight」开,而空闲面板是 !hasTrack 时展开唯一长出的一块。它必须
    // 放得进**最省配置**(下一句预览关、控制键关、头部全关 → maxHeight 只剩进度条 24pt)下的窗口,
    // 否则关了那几个开关的用户 hover 上去面板底部会被窗口边界硬裁。
    do {
        typealias M = NotchExpandedMetrics
        let roomiestFloor = NotchLyricRowMetrics.rowHeight
            + M.maxHeight(hasLyricPreviewPossible: false, hasControlsPossible: false, trackInfoHeight: 0)
        expectEqual(M.idlePanelHeight <= roomiestFloor, true,
                    "空闲面板: 高度 \(M.idlePanelHeight) 必须放得进最省配置下的窗口(歌词行 + maxHeight = \(roomiestFloor))")
        // 两行字 + 上下留白的账,跟头部的行高常量同源 —— 改任何一个常量这里都会跟着动,不钉死具体数字。
        expectEqual(M.idlePanelHeight,
                    M.trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: false,
                                      showsActions: true) + M.trackInfoTopSpacing + M.idlePanelBottomSpacing,
                    "空闲面板: 高度 = 头部两行字(含快捷键那一档) + 顶部间距 + 底部间距")
        expectEqual(M.idlePanelBottomSpacing > M.trackInfoSpacing, true,
                    "空闲面板: 贴底那份间距要比头部接歌词行的 4pt 宽,不然贴底太紧")
    }

    // MARK: - VocalEnvelope:灵动岛音浪的人声包络(起音脉冲 + 换气泄放)
    //
    // 钉住形状,不钉具体常数值(四个常数是按手感调的起点):字内稳态 1、起音那一拍 1+onsetBoost、
    // 按 attackMs 指数衰回、字间从 1 按 releaseMs 指数泄到 gapFloor、行首之前按地板、没有逐字 1。
    do {
        func w(_ text: String, _ start: Int, _ dur: Int) -> SyncedLyricWord {
            SyncedLyricWord(text: text, startMs: start, durationMs: dur)
        }
        let words = [w("a", 1000, 400), w("b", 1400, 400), w("c", 2400, 300)]
        let amp: (Int) -> Double = { VocalEnvelope.amplitude(atMs: $0, words: words) }
        let boost = VocalEnvelope.onsetBoost
        let floor = VocalEnvelope.gapFloor

        expectEqual(VocalEnvelope.amplitude(atMs: 1200, words: []), VocalEnvelope.idleAmplitude, "人声包络: 没有逐字 → idle 幅度")
        expectEqual(amp(1000), 1 + boost, "人声包络: 字起音那一刻 = 1 + onsetBoost")
        let tau = Int(VocalEnvelope.attackMs)
        expectEqual(abs(amp(1000 + tau) - (1 + boost * exp(-1))) < 1e-9, true, "人声包络: 一个 attack 时间常数后衰到 1 + boost/e")
        expectEqual(amp(1000 + 3 * tau) < 1.02, true, "人声包络: 三个时间常数后基本回到稳态 1")
        expectEqual(amp(1000 + 3 * tau) >= 1, true, "人声包络: 字内永不低于稳态 1")
        expectEqual(amp(1400), 1 + boost, "人声包络: 紧接的下一个字起音重新给满脉冲")
        // 字间空档:从 1 泄放,单调递减,趋向地板,不低于地板
        let g0 = amp(1800), g1 = amp(1900), g2 = amp(2100), g3 = amp(2399)
        expectEqual(abs(g0 - 1) < 1e-9, true, "人声包络: 上一字刚结束那一刻仍是 1(泄放从 1 开始)")
        expectEqual(g0 > g1 && g1 > g2 && g2 > g3, true, "人声包络: 空档里单调泄放")
        expectEqual(g3 > floor && g3 < floor + 0.05, true, "人声包络: 泄放趋向地板 gapFloor(599ms ≈ 2.4τ 时已在地板上方 0.05 内),不穿透")
        let rt = Int(VocalEnvelope.releaseMs)
        expectEqual(abs(amp(1800 + rt) - (floor + (1 - floor) * exp(-1))) < 1e-9, true, "人声包络: 一个 release 时间常数后 = floor + (1-floor)/e")
        expectEqual(amp(500), floor, "人声包络: 行首第一个字之前没有上一字终点,按地板")
        expectEqual(amp(2900) < 1 && amp(2900) > floor, true, "人声包络: 最后一个字之后 200ms 同样在泄放中")
        expectEqual(VocalEnvelope.releaseMs <= 300, true, "人声包络: 泄放时间常数 ≤300ms,上一行尾巴不能盖住下一行第一个字的起音")
        expectEqual(VocalEnvelope.attackMs < VocalEnvelope.releaseMs, true, "人声包络: 上升快于回落")
    }

    // ---- EqualizerBarCurve:音浪柱高曲线(每根条子各走各的、平滑、不塌底) ----
    do {
        let count = 5
        let t0 = 800_000_000.0
        let times = (0..<3000).map { t0 + Double($0) / 30.0 }

        // 速度按条序铺开 —— "一条条单独在动"靠的就是这个,收成一样快就只剩相位差
        let rates = (0..<count).map { EqualizerBarCurve.rate(bar: $0, barCount: count) }
        expectEqual(rates.first!, EqualizerBarCurve.rateSlowest, "音浪速度: 第一根走最慢那档")
        expectEqual(rates.last!, EqualizerBarCurve.rateFastest, "音浪速度: 最后一根走最快那档")
        expectEqual(zip(rates, rates.dropFirst()).allSatisfy { $0 < $1 }, true, "音浪速度: 按条序单调变快")
        expectEqual(EqualizerBarCurve.rate(bar: 0, barCount: 1), 1, "音浪速度: 只有一根时不做铺开,避免除零")
        expectEqual(EqualizerBarCurve.rate(bar: 99, barCount: count), EqualizerBarCurve.rateFastest,
                    "音浪速度: 条序越界夹到最快那档")

        // 黄金角递推:任意根数都不会有两根落到同一个相位上(等分相位则会"依次推过去")
        let wrapped = (0..<count).map { EqualizerBarCurve.phase(bar: $0).truncatingRemainder(dividingBy: 2 * .pi) }
        let closest = (0..<count).flatMap { i in ((i + 1)..<count).map { abs(wrapped[i] - wrapped[$0]) } }.min() ?? 0
        expectEqual(closest > 0.5, true, "音浪相位: 五根条子的相位两两拉得开,没有两根同步")

        // 形状值与纯函数性
        let shapes = times.flatMap { t in (0..<count).map { EqualizerBarCurve.shape(bar: $0, barCount: count, time: t) } }
        expectEqual(shapes.allSatisfy { $0 >= 0 && $0 <= 1 }, true, "音浪形状: 形状值恒在 0…1")
        expectEqual(shapes.max()! > 0.95 && shapes.min()! < 0.05, true, "音浪形状: 真的走得满,不是缩在中间一小段")
        expectEqual(EqualizerBarCurve.shape(bar: 2, barCount: count, time: t0),
                    EqualizerBarCurve.shape(bar: 2, barCount: count, time: t0),
                    "音浪形状: 同一时刻永远同一个值(纯函数,重算 body 不会无故抽动)")

        // 振幅口径:只压缩能跳多高,乘完再夹
        expectEqual(EqualizerBarCurve.level(bar: 0, barCount: count, time: t0, amplitude: 0), 0,
                    "音浪柱高: 振幅 0 → 只剩地板")
        let levels = times.flatMap { t in (0..<count).map { EqualizerBarCurve.level(bar: $0, barCount: count, time: t, amplitude: 1) } }
        expectEqual(levels.allSatisfy { $0 >= 0 && $0 <= 1 }, true, "音浪柱高: 比例恒在 0…1")
        expectEqual(times.contains { t in (0..<count).contains { EqualizerBarCurve.level(bar: $0, barCount: count, time: t, amplitude: 1.25) >= 1 } }, true,
                    "音浪柱高: 起音脉冲 1.25 乘完再夹,顶得到上限")
        expectEqual(EqualizerBarCurve.level(bar: 2, barCount: count, time: t0, amplitude: 0.6)
                        < EqualizerBarCurve.level(bar: 2, barCount: count, time: t0, amplitude: 1), true,
                    "音浪柱高: 换气地板 0.6 把柱高按比例压低")

        // 下面四条是这套曲线的身份,改坏任何一条观感都会退回被否掉的形态
        var spreads: [Double] = []
        var jumps: [Double] = []
        var perBar = Array(repeating: [Double](), count: count)
        var previous: [Double]? = nil
        for t in times {
            let row = (0..<count).map { EqualizerBarCurve.level(bar: $0, barCount: count, time: t, amplitude: 1) }
            spreads.append(row.max()! - row.min()!)
            if let p = previous {
                jumps.append(zip(row, p).map { abs($0 - $1) }.reduce(0, +) / Double(count))
                for b in 0..<count { perBar[b].append(abs(row[b] - p[b])) }
            }
            previous = row
        }
        let meanJump = jumps.reduce(0, +) / Double(jumps.count)
        let meanSpread = spreads.reduce(0, +) / Double(spreads.count)
        let barSpeeds = perBar.map { $0.reduce(0, +) / Double($0.count) }

        expectEqual(levels.min()! >= EqualizerBarCurve.floorLevel - 1e-9, true,
                    "音浪身份: 地板托着 —— 低谷的条子仍是一根短棍,不会缩成一个点(去掉地板会有 16.6% 的时间贴在满量程 12% 以下)")
        expectEqual(meanJump < 0.055, true,
                    "音浪身份: 逐帧位移有上限 —— 换成「快速冲顶 + 指数泄放」的非对称脉冲会到 0.082,那是一直在抽搐")
        expectEqual(meanJump > 0.025, true,
                    "音浪身份: 逐帧位移有下限 —— 再慢下去就是黏稠地漂,看不出在动")
        expectEqual(barSpeeds.max()! / barSpeeds.min()! > 2, true,
                    "音浪身份: 最快那根比最慢那根快一倍以上 —— 各走各的,不是整排一个节奏")
        expectEqual(meanSpread > 0.35, true,
                    "音浪身份: 柱间落差够大 —— 加一条全组共享的驱动会把它压到 0.31,那时五根同起同落")

        // 预排关键帧(交给 Core Animation 播的那一段)必须逐点等于按时刻现算的值 ——
        // 换成关键帧只是换了「谁来按帧推」,曲线本身一个点都不能变。
        let step = 1.0 / 30
        let amp: (Double) -> Double = { t in t - t0 < 1 ? 1.25 : 0.6 }
        let frames = EqualizerBarCurve.keyframes(barCount: count, start: t0, step: step, count: 61, amplitude: amp)
        expectEqual(frames.count, count, "音浪关键帧: 每根条子一条序列")
        expectEqual(frames.allSatisfy { $0.count == 61 }, true, "音浪关键帧: 每条序列点数 = count")
        let exact = (0..<count).allSatisfy { b in
            (0..<61).allSatisfy { i in
                let t = t0 + Double(i) * step
                return frames[b][i] == EqualizerBarCurve.level(bar: b, barCount: count, time: t, amplitude: amp(t))
            }
        }
        expectEqual(exact, true, "音浪关键帧: 逐点等于 level(time:amplitude:) 现算的值,振幅按每个采样时刻各求一次")
        expectEqual(EqualizerBarCurve.keyframes(barCount: count, start: t0, step: 0, count: 10, amplitude: amp).isEmpty, true,
                    "音浪关键帧: 步长非正时不排(防死循环 / 除零)")
    }

    // ---- NotchReveal:出场「从刘海撑开」的起始几何与时序 ----
    do {
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 180, cardWidth: 360), 0.5,
                    "出场: 从真刘海两侧撑开,起始宽 = 刘海 / 卡宽")
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 0, cardWidth: 360), 0.12,
                    "出场: 无刘海屏给 12% 细缝,不能凭空出现")
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 400, cardWidth: 360), 0.9,
                    "出场: 刘海比卡宽还宽时夹到 0.9,仍留撑开量")
        expectEqual(NotchReveal.startWidthFraction(notchWidth: 180, cardWidth: 0), 1,
                    "出场: 卡宽 0 不做除法,直接终态")
        expectEqual(abs(NotchReveal.startHeightFraction(topRowHeight: 32, cardHeight: 76) - 32.0 / 76.0) < 1e-9, true,
                    "出场: 起始高只露顶行")
        expectEqual(NotchReveal.startHeightFraction(topRowHeight: 32, cardHeight: 32), 0.9,
                    "出场: 只有顶行(收起态)时夹到 0.9,仍有一点纵向动作")
        expectEqual(NotchReveal.startHeightFraction(topRowHeight: 32, cardHeight: 0), 1,
                    "出场: 卡高 0 直接终态")
        expectEqual(NotchReveal.heightDelay < NotchReveal.contentDelay, true,
                    "出场: 先开始往下长,再淡入内容")
        expectEqual(abs(NotchReveal.totalDuration - 0.30) < 1e-9, true,
                    "出场: 总时长 0.30s(最晚一条轨)")
        expectEqual(NotchReveal.totalDuration < 0.4, true,
                    "出场: 比退场 0.2s 长但不拖沓")
    }

    // ---- NotchWidthBounds / NotchWidthRangeDrag:稳态宽 / 展开宽这一对的不变量 ----
    //
    // 「配置宽度的时候可以设置一个上限和一个下限,下限就是正常状态的宽度,上限就是悬浮展开
    // 时候的宽度」。唯一的不变量是**展开 ≥ 稳态**;这组断言守的是它在读侧(真窗口 / 编辑台)、
    // 写侧(三个入口落盘前的归一)、以及编辑台双滑块的两条交互规则上都成立。
    do {
        typealias B = NotchWidthBounds
        expectEqual(B.expandedWidth(steady: 360, expandedSetting: 460), 460,
                    "宽度对: 展开设定比稳态宽就用展开设定")
        expectEqual(B.expandedWidth(steady: 420, expandedSetting: 360), 420,
                    "宽度对: 老用户稳态调到过 420、展开还是默认 360 → hover 不变窄也不多长")
        expectEqual(B.expandedWidth(steady: 360, expandedSetting: 360), 360,
                    "宽度对: 两值相等 = 展开不加宽(升级前的观感)")
        expectEqual(B.normalized(steady: 400, expanded: 360) == (400, 400), true,
                    "宽度对: 稳态拖过展开,落盘前把展开顶上去")
        expectEqual(B.normalized(steady: 300, expanded: 360) == (300, 360), true,
                    "宽度对: 稳态往下调不碰展开")
        expectEqual(B.normalized(steady: 360, expanded: 300) == (360, 360), true,
                    "宽度对: 展开拖到稳态以下停在稳态")

        typealias D = NotchWidthRangeDrag
        expectEqual(D.thumb(pressX: 40, steadyX: 30, expandedX: 120, dx: 0), .steady,
                    "双滑块: 按下点离哪只近就认领哪只(左)")
        expectEqual(D.thumb(pressX: 110, steadyX: 30, expandedX: 120, dx: -5), .expanded,
                    "双滑块: 离右边近就认领右边,位移方向不参与")
        expectEqual(D.thumb(pressX: 80, steadyX: 80, expandedX: 80, dx: 0), nil,
                    "双滑块: 两只重叠且还没动 → 先不认领")
        expectEqual(D.thumb(pressX: 80, steadyX: 80, expandedX: 80, dx: 3), .expanded,
                    "双滑块: 两只重叠往右拖走的是上限")
        expectEqual(D.thumb(pressX: 80, steadyX: 80, expandedX: 80, dx: -3), .steady,
                    "双滑块: 两只重叠往左拖走的是下限")
        expectEqual(D.dragging(.steady, to: 300, steady: 360, expanded: 460) == (300, 460), true,
                    "双滑块: 拖下限,上限不动")
        expectEqual(D.dragging(.steady, to: 480, steady: 360, expanded: 460) == (460, 460), true,
                    "双滑块: 下限拖过上限被挡住,不把上限推走")
        expectEqual(D.dragging(.expanded, to: 500, steady: 360, expanded: 460) == (360, 500), true,
                    "双滑块: 拖上限,下限不动")
        expectEqual(D.dragging(.expanded, to: 340, steady: 360, expanded: 460) == (360, 360), true,
                    "双滑块: 上限拖过下限被挡住,不把下限推走")
    }

    // ---- 歌词行「副行」四选一----
    //
    // 两条不变量:① rawValue 直接落 UserDefaults,四个值和顺序改了就是改存量配置;② 两行叠起来必须塞进
    // 44pt 的行高 —— 一旦塞不下,卡片高度公式就得多一个入参,那正是方案二刻意绕开的整片雷区。
    // 展开区「下一句预览」的顶掉判据只有 Core 这一份,真窗口和设置页替身都调它(contracts 组守着调用点)。
    do {
        expectEqual(LyricSecondaryLine.allCases.map(\.rawValue), ["off", "nextLine", "translation", "romanization"],
                    "副行: 四个 rawValue 与声明顺序是存量配置的一部分,别动")
        expectEqual(LyricSecondaryLine.off.showsSecondaryRow, false, "副行: 不显示 → 歌词行回到单行排法")
        expectEqual(LyricSecondaryLine.allCases.filter(\.showsSecondaryRow).count, 3, "副行: 其余三档都画副行")
        expectEqual(LyricSecondaryLine.allCases.filter(\.hidesExpandedNextLinePreview), [.nextLine],
                    "副行: 只有「下一句」会顶掉展开区的下一句预览(译文 / 罗马音里没有下一句,不该顶)")
        for secondary in LyricSecondaryLine.allCases {
            expectEqual(LyricSecondaryLine.expandedNextLinePreviewVisible(userToggle: false, secondary: secondary), false,
                        "副行: 用户关了展开区预览,任何副行选项下都不画(\(secondary.rawValue))")
            expectEqual(LyricSecondaryLine.expandedNextLinePreviewVisible(userToggle: true, secondary: secondary),
                        secondary != .nextLine,
                        "副行: 用户开着展开区预览,只有「下一句」把它顶掉(\(secondary.rawValue))")
        }
        typealias R = NotchLyricRowMetrics
        expectEqual(R.rowHeight, 44, "副行: 稳态歌词行仍是 44(方案二的前提:行高不变)")
        expectEqual(R.twoLineStackHeight, 31, "副行: 15 + 3 + 13 = 31")
        expectEqual(R.twoLineStackHeight <= R.rowHeight, true,
                    "副行: 两行叠起来必须塞进行高,否则卡片高度公式要多一个入参")
        expectEqual((R.rowHeight - R.twoLineStackHeight) / 2 >= 4, true, "副行: 上下各留至少 4pt,别贴边")

        // 「字体」组:主行字号可调、行高仍是 44。范围上限必须让两行 + 间距仍塞进去且上下各留 ≥ 4pt ——
        // 这条不变量比"17 这个数"更重要,改范围先过这里;默认字号下三个度量逐个等于改动前的硬编码(升级不变样)。
        expectEqual(R.mainLineHeight(fontSize: R.defaultMainFontSize), 15, "字体: 默认 13pt 的主行高度仍是 15")
        expectEqual(R.mainLineHeight, 15, "字体: 不带字号的默认主行高度也是 15")
        expectEqual(R.secondaryLineHeight, 13, "字体: 副行 11pt 高度仍是 13")
        expectEqual(R.secondaryFontSize, 11, "字体: 副行字号固定 11,不随主行变")
        expectEqual(R.mainFontSizeRange.contains(R.defaultMainFontSize), true, "字体: 默认字号落在合法区间内")
        expectEqual(R.mainFontSizeRange.lowerBound < R.defaultMainFontSize, true, "字体: 区间要能往小调")
        let maxStack = R.twoLineStackHeight(fontSize: R.mainFontSizeRange.upperBound)
        expectEqual(maxStack <= R.rowHeight, true, "字体: 最大字号下两行仍塞进 44(\(maxStack))")
        expectEqual((R.rowHeight - maxStack) / 2 >= 4, true, "字体: 最大字号下上下仍各留 ≥ 4pt(\(maxStack))")
        expectEqual(R.clampedMainFontSize(99), R.mainFontSizeRange.upperBound, "字体: 越界字号夹回上限")
        expectEqual(R.clampedMainFontSize(1), R.mainFontSizeRange.lowerBound, "字体: 越界字号夹回下限")
        expectEqual(R.mainLineHeight(fontSize: 99), R.mainLineHeight(fontSize: R.mainFontSizeRange.upperBound),
                    "字体: 行高按夹回后的字号算,越界配置不把行撑破")
        expectEqual(R.lineHeight(fontSize: 16.6), 19, "字体: 行高先把字号取整再 +2")
        expectEqual(OverlayFontWeight.semibold.lighter(by: OverlayFontWeight.notchSecondarySteps), .medium,
                    "字体: 默认档 semibold 推出的副行粗细 = 改动前硬编码的 medium")
    }

    // ---- 灵动岛 hover 命中判定----
    //
    // 现象是「鼠标只是移到灵动岛下面就展开了」。真机探针实测:`.contentShape(Rectangle)`
    // 只管住了横向,纵向的命中区仍是整扇窗(卡片 77pt 高,hover 进入事件的 y 给到 177),
    // 于是卡片下方那片透明区(压在用户自己的窗口上)也能把它捅开。判据因此改成自己拿
    // 坐标比,理由与那四条实测记录在 `NotchHoverHit` 头注里。
    do {
        typealias H = NotchHoverHit
        let steady = (w: CGFloat(257), h: CGFloat(77))   // 实测的稳态卡片
        expectEqual(H.isInside(point: CGPoint(x: 127, y: 40), cardWidth: steady.w, cardHeight: steady.h),
                    true, "灵动岛命中: 卡片正中算在里面")
        expectEqual(H.isInside(point: CGPoint(x: 127, y: 76), cardWidth: steady.w, cardHeight: steady.h),
                    true, "灵动岛命中: 贴着下沿(76 < 77)仍算在里面")
        // 这四个点就是修复前把卡片捅开的那四条实测记录 —— 修复后必须全部判在外面。
        for p in [CGPoint(x: 11, y: 140), CGPoint(x: 177, y: 145),
                  CGPoint(x: 120, y: 176), CGPoint(x: 124, y: 177)] {
            expectEqual(H.isInside(point: p, cardWidth: steady.w, cardHeight: steady.h),
                        false, "灵动岛命中: 卡片下方透明区(\(Int(p.x)),\(Int(p.y)))不算在里面")
        }
        expectEqual(H.isInside(point: CGPoint(x: 300, y: 40), cardWidth: steady.w, cardHeight: steady.h),
                    false, "灵动岛命中: 卡片右侧之外不算")
        expectEqual(H.isInside(point: CGPoint(x: -1, y: 40), cardWidth: steady.w, cardHeight: steady.h),
                    false, "灵动岛命中: 负坐标不算")
        // 展开态卡片长到整扇窗那么大,同样那几个点这时就该算在里面(否则一展开就抖回去)。
        for p in [CGPoint(x: 120, y: 176), CGPoint(x: 124, y: 177)] {
            expectEqual(H.isInside(point: p, cardWidth: 482, cardHeight: 191),
                        true, "灵动岛命中: 展开后同一个点算在里面(展开卡片包含稳态卡片)")
        }
    }

    // ---- 广告态:「跳过广告」+ 头部让位----
    //
    // 用户圈出广告期间的展开卡「太呆了」,拍板「选用可以跳过广告的方案」。落地三件事:① 广告期间展开头部
    // 整块不画(状态与倒计时由歌词行接管);② 歌词行右端一颗「跳过广告」,去点 YT Music 页面自己的跳过按钮;
    // ③ 时间行不画歌词校准控件。下面钉的是 JS 契约(同 YouTubeMusicAdProbe 那套的规矩)和几条源码契约。
    do {
        typealias S = YouTubeMusicAdSkipper
        let skipJS = S.skipJS
        for js in [skipJS, S.verifyJS] {
            expectEqual(js.contains("\""), false, "跳过广告 JS: 不含双引号(要嵌进 AppleScript 的双引号字符串)")
            expectEqual(js.contains("\\"), false, "跳过广告 JS: 不含反斜杠(AppleScript 会先当转义吃掉)")
        }
        for marker in ["ad-showing", "'SKIPPABLE|'", "'NOTYET|'", "'NOTFOUND'", ".ytp-ad-skip-button-modern", ".ytp-skip-ad-button",
                       "getBoundingClientRect", "/[0-9]+/", ".ytp-ad-simple-ad-badge"] {
            expectEqual(skipJS.contains(marker), true, "跳过广告 JS: 含 \(marker)")
        }
        for marker in ["ad-showing", "'STILL|'", "'CLEAR'", "'NOTFOUND'", ".ytp-ad-simple-ad-badge"] {
            expectEqual(S.verifyJS.contains(marker), true, "跳过广告复核 JS: 含 \(marker)")
        }
        // 门槛脚本必须**只读**:不派事件、不点、不 seek(前五版试过的路,DOM 事件 YouTube 不认、seek 会让广告从头重放)。
        for forbidden in ["click()", "dispatchEvent", "currentTime =", "onAdUxClicked"] {
            expectEqual(skipJS.contains(forbidden), false, "跳过广告门槛 JS: 只读,不含 \(forbidden)")
        }
        expectEqual(S.verifyJS.contains("currentTime ="), false, "跳过广告复核 JS: 只读,不给 video.currentTime 赋值")
        // AX 侧按 DOM class 认键,前缀要跟门槛脚本的选择器同源
        for prefix in AccessibilitySkipPress.skipButtonClassPrefixes {
            expectEqual(skipJS.contains("." + prefix), true, "跳过广告: AX class 前缀 \(prefix) 在门槛脚本的选择器里")
        }
        expectEqual(AccessibilitySkipPress.matchesSkipClass(["ytp-ad-skip-button-modern", "ytp-button", "ytp-ad-skip-button-icon-delhi"]), true,
                    "AX 认键: 真机抓到的那颗按钮的 class 命中")
        expectEqual(AccessibilitySkipPress.matchesSkipClass(["ytp-skip-ad-button"]), true, "AX 认键: 新版命名命中")
        expectEqual(AccessibilitySkipPress.matchesSkipClass(["ytp-ad-skip-button"]), true, "AX 认键: 旧版命名命中")
        for wrapper in [["ytp-ad-skip-button-slot"], ["ytp-ad-skip-button-container", "ytp-ad-skip-button-container-detached"],
                        ["ytp-ad-text", "ytp-ad-skip-button-text"], ["ytp-skip-ad-button__text"], ["style-scope", "yt-icon-button"], []] {
            expectEqual(AccessibilitySkipPress.matchesSkipClass(wrapper), false, "AX 认键: 包裹 / 子元素 / 无关 class 不命中 \(wrapper)")
        }
        expectEqual(AccessibilitySkipPress.matchesSkipTitle("跳过"), true, "AX 认键(标题兜底): 跳过")
        expectEqual(AccessibilitySkipPress.matchesSkipTitle(" Skip "), true, "AX 认键(标题兜底): Skip 带空白")
        expectEqual(AccessibilitySkipPress.matchesSkipTitle("跳过广告设置"), false, "AX 认键(标题兜底): 只认整词")

        // 「不可跳过的广告不画那颗键」(「如果当前广告不支持跳过的话就不要显示那个
        // 跳过的按钮」)。门槛脚本的三种返回 → 该不该画,是纯映射,钉在这里。
        expectEqual(S.skippability(from: .skippable(desc: "BUTTON.ytp-ad-skip-button-modern", badge: "赞助商广告 1/2 ·", videoTime: 6)),
                    .ready, "跳过键门槛: 键有尺寸 = 现在就能跳")
        expectEqual(S.skippability(from: .notYet(seconds: 5)), .after(seconds: 5), "跳过键门槛: 读到倒计时 = 可跳,还没到点")
        // 这一条是**核心判据**:页面那句「N 秒后可跳过」是可跳过广告独有的,
        // 读不到不是"读失败"、是"这条广告没有跳过这回事"。
        expectEqual(S.skippability(from: .notYet(seconds: nil)), .never, "跳过键门槛: 没键也没倒计时 = 这条广告不给跳")
        expectEqual(S.skippability(from: .notFound), .notInAd, "跳过键门槛: 没有标签页在放广告")

        expectEqual(S.showsSkipButton(.ready), true, "画不画: 能跳才画")
        expectEqual(S.showsSkipButton(.after(seconds: 3)), false, "画不画: 倒计时期间不画(按了也只会得到一句「还不能跳过」)")
        expectEqual(S.showsSkipButton(.never), false, "画不画: 不可跳过的广告不画 —— 这次改动要的就是这一条")
        expectEqual(S.showsSkipButton(.notInAd), false, "画不画: 广告已经结束就不画")
        expectEqual(S.showsSkipButton(nil), false, "画不画: 门槛脚本没跑成时不画 —— 没确认能跳就不给键")
        expectEqual(S.gateRetryDelay(after: nil, round: 0), S.fastStartDelay, "门槛节奏: 脚本没跑成也继续探(开头快探)")
        expectEqual(S.gateRetryDelay(after: nil), YouTubeMusicAdProbe.adRefreshInterval, "门槛节奏: 脚本没跑成之后按心跳重试,不放弃")

        expectEqual(S.gateRetryDelay(after: .after(seconds: 5)), 5.4, "门槛节奏: 倒计时那一档等到点再问(多给 0.4s 渲染)")
        expectEqual(S.gateRetryDelay(after: .after(seconds: 0)), 1.4, "门槛节奏: 秒数为 0 也至少等 1s,不打转")
        expectEqual(S.gateRetryDelay(after: .after(seconds: 999)), 20.4, "门槛节奏: 离谱秒数被 20s 封顶")
        expectEqual(S.gateRetryDelay(after: .ready), YouTubeMusicAdProbe.adRefreshInterval, "门槛节奏: 已经能跳也继续心跳(一次插播可能连放两条)")
        expectEqual(S.gateRetryDelay(after: .never), YouTubeMusicAdProbe.adRefreshInterval,
                    "门槛节奏: 问出「不给跳」也继续心跳 —— 下一条可能就给跳")
        // 广告开头那几拍的 `never` 是"页面还没渲染出来",不是"这条不给跳"(真机时间线:
        // t+0.2 never → 按 5s 心跳等 → t+8.4 才 ready,而页面第 5 秒就放出了键)。
        expectEqual(S.gateRetryDelay(after: .never, round: 0), S.fastStartDelay, "门槛节奏: 开头第一拍的「不给跳」快探")
        expectEqual(S.gateRetryDelay(after: .never, round: S.fastStartRounds - 1), S.fastStartDelay,
                    "门槛节奏: 快探窗口内都按快节奏")
        expectEqual(S.gateRetryDelay(after: .never, round: S.fastStartRounds), YouTubeMusicAdProbe.adRefreshInterval,
                    "门槛节奏: 出了快探窗口,「不给跳」才当真、退回心跳")

        // 灵动岛审计那一批的几处接线(契约)。
        do {
            let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lyrimuse/UI")
            func src(_ name: String) -> String {
                (try? String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            let controller = src("NotchLyricsWindowController.swift")
            let stage = src("NotchEditorStage.swift")
            let view = src("NotchLyricsView.swift")
            expectEqual(src("NotchLyricsWindow.swift").contains("becomesKeyOnlyIfNeeded = true"), true,
                        "灵动岛接线: 点按钮不抢键盘焦点")
            expectEqual(stage.contains("controller.setHideWhenNotPlaying(settings.notchHideWhenNotPlaying)")
                        && stage.contains("controller.applyScreenSetting()"), true,
                        "灵动岛接线: 恢复默认后主实例按新值同步屏幕与自动隐藏")
            expectEqual(controller.contains("return ScreenIdentity.notched ?? NSScreen.screens.first"), true,
                        "灵动岛接线: 没有刘海时固定主屏,不跟着键盘焦点跳")
            expectEqual(controller.contains("var hideWhenNotPlaying: Bool = AppSettings.shared.notchHideWhenNotPlaying"), true,
                        "灵动岛接线: 暂停时隐藏的初值读设置,冷启动不闪")
            expectEqual(controller.components(separatedBy: "resetHoverAfterHide()").count - 1, 3,
                        "灵动岛接线: 两条收走窗口的路都清悬停状态")
            expectEqual(view.contains("p.$currentLyricsOffsetMs") && view.contains("timingEpoch: playback.lyricsOffsetMs"), true,
                        "灵动岛接线: 订阅总偏移,偏移一变当前行重装")
            // 先算几何再建 hostingView:SwiftUI 第一次排版就拿终值,卡片不从占位窗口里那份旧版位置弹过去。见 05 章决策 64。
            let initBody = controller.components(separatedBy: "convenience init(pinnedScreenID: String?) {").last ?? ""
            let geometryAt = initBody.range(of: "recomputeGeometry(animate: false)")?.lowerBound
            let hostingAt = initBody.range(of: "NSHostingView(rootView: NotchWindowRoot(controller: self))")?.lowerBound
            expectEqual(geometryAt != nil && hostingAt != nil && geometryAt! < hostingAt!, true,
                        "灵动岛接线: 初始化先算几何再建 hostingView")
            expectEqual(initBody.contains("hosting.frame = NSRect(origin: .zero, size: panel.frame.size)"), true,
                        "灵动岛接线: hostingView 按算好的窗口尺寸建,不按占位尺寸")
        }

        // 跟随封面背景:换图两层交叉淡入,旧图不透明地留在下面 —— 直接换 Image 内容会让旧图当场消失、
        // 露出打底色,同一首歌换上高清封面时整卡暗一下再亮回来(真机逐帧:均值 −7.6 再 +7.7)。
        do {
            let v = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lyrimuse/UI/NotchLyricsView.swift"), encoding: .utf8)) ?? ""
            expectEqual(v.contains("NotchCrossfadeBackdrop(image: image, size: size)"), true, "封面背景契约: 模糊图走两层交叉淡入")
            expectEqual(v.contains("case .solidBlack, .coverArt:\n            return AnyShapeStyle(Color.black)"), true,
                        "封面背景契约: 跟随封面没有封面时是纯黑,跟机器刘海融成一块")
            expectEqual(v.contains("case .darkGradient, .coverArt:"), false, "封面背景契约: 没有封面时不再退回深色渐变")
            expectEqual(v.contains(".animation(.easeInOut(duration: 0.5), value: playback.blurredArtworkImage)"), false,
                        "封面背景契约: 不再直接换 Image 内容做过渡(会露出打底色)")
            expectEqual(v.contains("if let back { layer(back) }\n            if let front { layer(front).opacity(frontOpacity) }"), true,
                        "封面背景契约: 旧图在下、不透明;只有新图做透明度动画")
            expectEqual(v.contains("} completion: {\n                if generation == fadeGeneration { back = nil }"), true,
                        "封面背景契约: 淡完才撤旧图,而且只撤最新那一次的(连着换两次不暗闪)")
        }

        // 卡片外轮廓:照机器刘海 —— 跟刘海一样高时底部圆角 = 高 × 0.25,展开封顶 20;顶边两侧内凹肩膀 = 刘海高 × 0.125。
        typealias O = NotchOutline
        expectEqual(O.bottomRadius(height: 32, bodyWidth: 300), 8, "外轮廓: 32pt 高(14 寸刘海)底部圆角 8pt")
        expectEqual(O.bottomRadius(height: 38, bodyWidth: 300), 9.5, "外轮廓: 38pt 高(16 寸刘海)按比例 9.5pt")
        expectEqual(O.bottomRadius(height: 190, bodyWidth: 460), O.maxBottomRadius, "外轮廓: 展开态封顶 20pt")
        expectEqual(O.bottomRadius(height: 60, bodyWidth: 300), 15, "外轮廓: 介于两者之间按高度连续变,展开/收起动画里不跳")
        expectEqual(O.bottomRadius(height: 32, bodyWidth: 10), 5, "外轮廓: 主体太窄时半径不超过半宽(出场动画起始那条缝)")
        expectEqual(O.shoulderRadius(notchHeight: 32), 4, "外轮廓: 32pt 刘海(14 寸)肩膀 4pt")
        expectEqual(O.shoulderRadius(notchHeight: 38), 4.75, "外轮廓: 38pt 刘海(16 寸)肩膀按比例 4.75pt")
        expectEqual(O.shoulder(width: 256, height: 32, notchHeight: 32), 4, "外轮廓: 常规尺寸用标称肩膀")
        expectEqual(O.shoulder(width: 468, height: 190, notchHeight: 38), 4.75, "外轮廓: 展开态肩膀不随卡片变大,只看刘海高度")
        expectEqual(O.shoulder(width: 8, height: 32, notchHeight: 32), 2, "外轮廓: 太窄时肩膀收小,不把主体吃没")
        expectEqual(O.shoulder(width: 256, height: 4, notchHeight: 32), 2, "外轮廓: 太矮时肩膀收小")
        expectEqual(O.shoulder(width: 0, height: 0, notchHeight: 32), 0, "外轮廓: 零尺寸不出负数")
        expectEqual(O.shoulder(width: 256, height: 32, notchHeight: 0), 0, "外轮廓: 刘海高度未知(0)时没有肩膀")
        // 「圆角 / 展开圆角」:三种规则(默认按高度 / 跟随刘海 / 固定),圆角只由这一帧的卡片高度决定。
        typealias Rule = NotchCornerRule
        expectEqual(Rule(setting: O.defaultRadiusSetting), .proportional, "圆角: 默认的存盘值 → 按高度算")
        expectEqual(Rule(setting: O.notchRadiusSetting), .notch, "圆角: 跟随刘海的存盘值 → 刘海本身的底角")
        expectEqual(Rule(setting: 12), .fixed(12), "圆角: 非负数 → 固定值")
        expectEqual(Rule(setting: 0), .fixed(0), "圆角: 0 是合法的固定值(直角),不当成默认")
        expectEqual(Rule(setting: 99), .fixed(CGFloat(O.customRadiusRange.upperBound)), "圆角: 超出范围夹回上限")
        expectEqual(Rule(setting: -7), .proportional, "圆角: 认不出的负数按默认")
        expectEqual(O.notchCornerRadius(notchHeight: 32), 8, "圆角: 跟随刘海 = 32pt 刘海的 8pt 底角")
        expectEqual(O.notchCornerRadius(notchHeight: 38), 9.5, "圆角: 16 寸 38pt 刘海 9.5pt")
        expectEqual(O.proportionalRadius(height: 76), 19, "圆角: 默认按高度,76pt 卡片 19pt")
        expectEqual(O.cornerProfile(collapsedSetting: O.defaultRadiusSetting, expandedSetting: O.defaultRadiusSetting,
                                    collapsedHeight: 76, expandedHeight: 190, notchHeight: 32, isExpanded: false) == nil, true,
                    "圆角: 两个都是默认时交给形状按高度算,跟没有这两个设置时一样")
        // 跟随刘海:没展开、展开、中间的尺寸动画,全程同一个值。
        let notchBoth = O.cornerProfile(collapsedSetting: O.notchRadiusSetting, expandedSetting: O.notchRadiusSetting,
                                        collapsedHeight: 76, expandedHeight: 190, notchHeight: 32, isExpanded: true)!
        for h in [32, 76, 120, 190] as [CGFloat] {
            expectEqual(notchBoth.radius(height: h), 8, "圆角: 两态都跟随刘海,高 \(h) 也是 8")
        }
        // 只改展开那一态:没展开的卡片(以及出场动画那几帧更矮的)一点不变 —— 拖「展开圆角」碰不到它。
        let mixed = O.cornerProfile(collapsedSetting: O.defaultRadiusSetting, expandedSetting: 6,
                                    collapsedHeight: 76, expandedHeight: 190, notchHeight: 32, isExpanded: false)!
        for h in [32, 50, 76] as [CGFloat] {
            expectEqual(mixed.radius(height: h), O.proportionalRadius(height: h), "圆角: 改展开那一态,高 \(h) 的没展开卡片照旧按默认")
        }
        expectEqual(mixed.radius(height: 190), 6, "圆角: 展开到底就是「展开圆角」的值")
        expectEqual(mixed.radius(height: 133), (O.proportionalRadius(height: 133) + 6) / 2,
                    "圆角: 尺寸动画走到一半,两条规则(都按这一帧的高度算)各占一半")
        // 两态一样高(展开区什么都不显示):按形态挑。
        let flat = O.cornerProfile(collapsedSetting: 4, expandedSetting: 10, collapsedHeight: 76, expandedHeight: 76,
                                   notchHeight: 32, isExpanded: true)!
        expectEqual(flat.radius(height: 76), 10, "圆角: 两态一样高时按当前形态挑规则")
        // 设了圆角时画多大:上限是「卡片高 − 肩膀」(侧边整段是圆弧),不是半高 —— 32pt 卡片能到 28,不停在 16。
        expectEqual(O.clampedCornerRadius(28, height: 32, bodyWidth: 244, shoulder: 4), 28, "圆角夹取: 32pt 卡片画得出 28")
        expectEqual(O.clampedCornerRadius(30, height: 32, bodyWidth: 244, shoulder: 4), 28, "圆角夹取: 再大停在 高 − 肩膀")
        expectEqual(O.clampedCornerRadius(20, height: 133, bodyWidth: 30, shoulder: 4), 15, "圆角夹取: 太窄时按主体半宽")
        expectEqual(O.clampedCornerRadius(-3, height: 32, bodyWidth: 244, shoulder: 4), 0, "圆角夹取: 不出负数")
        expectEqual(O.clampedCornerRadius(8, height: 3, bodyWidth: 244, shoulder: 1.5), 1.5, "圆角夹取: 出场动画只有一条缝时收小")
        expectEqual(O.cornerRadiusLimit(height: 32, notchHeight: 32), 28, "圆角上限: 32pt 刘海、32pt 卡片 = 28")
        expectEqual(O.cornerRadiusLimit(height: 38, notchHeight: 38), 33.25, "圆角上限: 16 寸 38pt = 38 − 4.75")
        expectEqual(O.customRadiusRange(cardHeight: 32, notchHeight: 32), 0...28, "圆角滑杆: 关着歌词行(32pt)拖到 28 为止")
        expectEqual(O.customRadiusRange(cardHeight: 50, notchHeight: 32), O.customRadiusRange, "圆角滑杆: 卡片够高时就是整段 0～32")
        expectEqual(O.customRadiusRange(cardHeight: 38, notchHeight: 38), O.customRadiusRange, "圆角滑杆: 上限取整后再跟 32 取小")
        expectEqual(O.customRadiusRange(cardHeight: 0, notchHeight: 0), 0...1, "圆角滑杆: 量不到屏幕时也是个能用的区间")
        // 滑杆上每一格都真的会动(没有拖了不变的那一段):32pt 卡片从 0 到上限,画出来的圆角就是滑杆上的值。
        let plateauRange = O.customRadiusRange(cardHeight: 32, notchHeight: 32)
        let shoulder32 = O.shoulder(width: 252, height: 32, notchHeight: 32)
        let drawn = stride(from: plateauRange.lowerBound, through: plateauRange.upperBound, by: 1).map {
            O.clampedCornerRadius(CGFloat($0), height: 32, bodyWidth: 252 - 2 * shoulder32, shoulder: shoulder32)
        }
        expectEqual(drawn, stride(from: plateauRange.lowerBound, through: plateauRange.upperBound, by: 1).map { CGFloat($0) },
                    "圆角滑杆: 32pt 卡片上滑杆每一格画出来都不一样")
        // 默认那套本来就在这个上限以下,两项里有一项是默认、走到 clampedCornerRadius 时也不会被夹变。
        for h in [2, 4, 8, 16, 32, 50, 76, 133, 190] as [CGFloat] {
            expectEqual(O.proportionalRadius(height: h) <= O.cornerRadiusLimit(height: h, notchHeight: 32), true,
                        "圆角夹取: 默认那套(高 \(h))不会被新上限夹")
        }
        // 换歌翻牌:掉歌名只认真的换了一首。
        typealias DR = NotchTrackDropRules
        let songA = DR.key(title: "晴天", artist: "周杰伦", isAdBreak: false)
        expectEqual(DR.shouldDrop(previousKey: nil, title: "晴天", artist: "周杰伦", isAdBreak: false), false,
                    "换歌翻牌: 这个实例看到的第一首不掉")
        expectEqual(DR.shouldDrop(previousKey: songA, title: "夜曲", artist: "周杰伦", isAdBreak: false), true,
                    "换歌翻牌: 换了一首掉")
        expectEqual(DR.shouldDrop(previousKey: songA, title: "晴天", artist: "周杰伦", isAdBreak: false), false,
                    "换歌翻牌: 同一首(单曲循环从头放)不掉")
        expectEqual(DR.shouldDrop(previousKey: DR.key(title: "", artist: "", isAdBreak: false), title: "夜曲",
                                  artist: "周杰伦", isAdBreak: false), false, "换歌翻牌: 从没在放到开始放不掉")
        expectEqual(DR.shouldDrop(previousKey: songA, title: "Advertisement", artist: "", isAdBreak: true), false,
                    "换歌翻牌: 广告不掉")
        expectEqual(DR.shouldDrop(previousKey: DR.key(title: "晴天", artist: "周杰伦", isAdBreak: true), title: "晴天",
                                  artist: "周杰伦", isAdBreak: false), true,
                    "换歌翻牌: 广告结束回到歌掉(哪怕跟广告同名)")
        expectEqual(DR.shouldDrop(previousKey: songA, title: "", artist: "周杰伦", isAdBreak: false), false,
                    "换歌翻牌: 没有歌名不掉")
        // 换歌翻牌:揭晓时条子里还露着的那条被新的推出去;收回开始超过 replaceWindow 就当条子收着。
        let shownDrop = NotchTrackDrop(id: 1, title: "晴天", artist: "周杰伦")
        let clearedAt = Date(timeIntervalSince1970: 500)
        let pushedOut = NotchTrackDrop.Replaced(title: "晴天", artist: "周杰伦")
        expectEqual(DR.replaced(showing: shownDrop, cleared: nil, clearedAt: nil, now: clearedAt), pushedOut,
                    "换歌翻牌: 停着时又换了一首,新的把旧的推出去")
        expectEqual(DR.replaced(showing: nil, cleared: shownDrop, clearedAt: clearedAt, now: clearedAt + 0.1), pushedOut,
                    "换歌翻牌: 刚开始收回(还没缩进顶行)时揭晓,照推出去处理")
        expectEqual(DR.replaced(showing: nil, cleared: shownDrop, clearedAt: clearedAt, now: clearedAt + DR.replaceWindow + 0.01), nil,
                    "换歌翻牌: 收回超过 replaceWindow,条子当收着,新的跟着条子拉出来")
        expectEqual(DR.replaced(showing: nil, cleared: nil, clearedAt: nil, now: clearedAt), nil,
                    "换歌翻牌: 条子从没露过,新的跟着条子拉出来")
        expectEqual(DR.revealOpacity(progress: 0), 0, "换歌翻牌: 条子收着时字透明")
        expectEqual(abs(DR.revealOpacity(progress: 0.4) - 0.5) < 1e-9, true, "换歌翻牌: 拉开不到一半时字半透明")
        expectEqual(DR.revealOpacity(progress: 0.8), 1, "换歌翻牌: 拉开四分之三起字全显")
        expectEqual(DR.revealOpacity(progress: 1.04), 1, "换歌翻牌: 弹簧略过拉满时不透明度不超过 1")
        // 换歌翻牌:声音还没走起来(加载、前贴片广告)时先不判,走起来那一拍按那时的曲目判。每拍是(歌名, 广告, 在等开播)。
        func dropOutcomes(_ ticks: [(String, Bool, Bool)]) -> [NotchTrackDropTracker.Outcome] {
            var tracker = NotchTrackDropTracker()
            return ticks.map { tracker.observe(title: $0.0, artist: "周杰伦", isAdBreak: $0.1, isWaitingToPlay: $0.2) }
        }
        expectEqual(dropOutcomes([("夜曲", false, false), ("晴天", false, true), ("晴天", true, true), ("晴天", false, false)]),
                    [.clear, .clear, .clear, .drop], "换歌翻牌: 前贴片广告(先加载、广告标记晚到)只在正片走起来时掉一次")
        expectEqual(dropOutcomes([("夜曲", false, false), ("晴天", false, true), ("晴天", false, false)]),
                    [.clear, .clear, .drop], "换歌翻牌: 没有广告时等加载完、声音走起来再掉")
        expectEqual(dropOutcomes([("夜曲", false, false), ("晴天", false, true), ("七里香", false, true), ("七里香", false, false)]),
                    [.clear, .clear, .clear, .drop], "换歌翻牌: 加载中又换了一首,只掉真放起来的那首")
        expectEqual(dropOutcomes([("夜曲", false, false), ("晴天", false, false), ("晴天", false, true), ("晴天", false, false)]),
                    [.clear, .drop, .none, .none], "换歌翻牌: 同一首中途卡住又接着走不再掉")
        expectEqual(dropOutcomes([("晴天", false, true), ("晴天", false, false)]), [.clear, .clear],
                    "换歌翻牌: 第一首等到走起来也不掉")
        expectEqual(dropOutcomes([("夜曲", false, false), ("晴天", true, false), ("晴天", false, false)]),
                    [.clear, .clear, .drop], "换歌翻牌: 广告期间暂停着(不算在等)也只在回到歌时掉")
        // 换歌翻牌:封面等新图到了才翻,旧图(含退回来的上一首系统封面)不算;同一张画面不翻。
        typealias FP = NotchArtworkFlipPlanner<Int>
        let t0 = Date(timeIntervalSince1970: 1_000)
        let samePicture: (Int, Int) -> Bool = { $0 / 10 == $1 / 10 }  // 十位相同 = 同一张画面
        var flipper = FP(shown: .artwork(10))
        flipper.trackChanged(staleArtwork: [10, 11], now: t0)
        expectEqual(flipper.update(target: .artwork(11), now: t0, samePicture: samePicture), nil,
                    "翻牌: 换歌后退回上一首的系统封面(旧图),先不换")
        expectEqual(flipper.shown, .artwork(10), "翻牌: 等新封面期间接着显示原来那张")
        expectEqual(flipper.recheckAt, t0.addingTimeInterval(FP.awaitWindow), "翻牌: 等不来就到点再看一眼")
        flipper.reveal()
        expectEqual(flipper.update(target: .artwork(20), now: t0 + 0.5, samePicture: samePicture), .flip,
                    "翻牌: 新封面到了翻")
        expectEqual(flipper.update(target: .artwork(21), now: t0 + 1, samePicture: samePicture), .cut,
                    "翻牌: 之后换上的高清版原地换,不再翻")
        var sameAlbum = FP(shown: .artwork(30))
        sameAlbum.trackChanged(staleArtwork: [30], now: t0)
        sameAlbum.reveal()
        expectEqual(sameAlbum.update(target: .artwork(31), now: t0 + 0.4, samePicture: samePicture), .cut,
                    "翻牌: 同一张专辑的下一首(同一张画面)不翻")
        var noArtwork = FP(shown: .artwork(40))
        noArtwork.trackChanged(staleArtwork: [40], now: t0)
        noArtwork.reveal()
        expectEqual(noArtwork.update(target: .empty, now: t0 + 1, samePicture: samePicture), nil,
                    "翻牌: 刚换歌就没图了,先留几秒等新封面")
        expectEqual(noArtwork.update(target: .empty, now: t0 + FP.shortHold, samePicture: samePicture), .fade,
                    "翻牌: 等不来就淡出")
        expectEqual(noArtwork.update(target: .artwork(50), now: t0 + 6, samePicture: samePicture), .fade,
                    "翻牌: 从没图到有图淡入,不翻")
        var adBreak = FP(shown: .artwork(60))
        adBreak.trackChanged(staleArtwork: [60], now: t0)
        expectEqual(adBreak.update(target: .adIcon, now: t0, samePicture: samePicture), .cut,
                    "翻牌: 进广告直接换成喇叭")
        adBreak.trackChanged(staleArtwork: [61], now: t0 + 30)
        adBreak.reveal()
        expectEqual(adBreak.update(target: .artwork(61), now: t0 + 30, samePicture: samePicture), nil,
                    "翻牌: 广告刚结束、封面还是旧图,先留着喇叭")
        expectEqual(adBreak.update(target: .artwork(70), now: t0 + 31, samePicture: samePicture), .flip,
                    "翻牌: 新封面到了,喇叭翻成封面")
        var adLate = FP(shown: .adIcon)
        adLate.trackChanged(staleArtwork: [61], now: t0)
        adLate.reveal()
        expectEqual(adLate.update(target: .artwork(61), now: t0 + FP.shortHold, samePicture: samePicture), .flip,
                    "翻牌: 新封面迟迟不来,喇叭最多留几秒")
        var expired = FP(shown: .artwork(80))
        expired.trackChanged(staleArtwork: [80], now: t0)
        expectEqual(expired.update(target: .artwork(90), now: t0 + FP.awaitWindow + 1, samePicture: samePicture), .cut,
                    "翻牌: 换歌太久之后才来的图原地换")
        var steady = FP(shown: .artwork(100))
        expectEqual(steady.update(target: .artwork(110), now: t0, samePicture: samePicture), .cut,
                    "翻牌: 没换歌时换图原地换")
        // 前贴片广告报的就是接下来那首(Kaset):广告结束回到的还是这首,广告期间到的封面不算旧图。
        var preRoll = FP(shown: .artwork(120))
        preRoll.trackChanged(staleArtwork: [120], now: t0)
        expectEqual(preRoll.update(target: .adIcon, now: t0 + 2, samePicture: samePicture), .cut,
                    "翻牌: 前贴片广告开始换成喇叭")
        preRoll.adBreakEnded(now: t0 + 8)
        expectEqual(preRoll.update(target: .artwork(121), now: t0 + 8, samePicture: samePicture), nil,
                    "翻牌: 前贴片广告结束,喇叭等正片揭晓")
        preRoll.reveal()
        expectEqual(preRoll.update(target: .artwork(121), now: t0 + 8.3, samePicture: samePicture), .flip,
                    "翻牌: 前贴片广告结束、这首的封面广告期间就到了,正片揭晓那一拍翻成封面")
        var preRollEarly = FP(shown: .artwork(140))
        preRollEarly.trackChanged(staleArtwork: [140], now: t0)
        expectEqual(preRollEarly.update(target: .artwork(141), now: t0 + 0.5, samePicture: samePicture), nil,
                    "翻牌: 加载时这首的封面先到了,还没揭晓先不翻")
        _ = preRollEarly.update(target: .adIcon, now: t0 + 2, samePicture: samePicture)
        preRollEarly.adBreakEnded(now: t0 + 20)
        preRollEarly.reveal()
        expectEqual(preRollEarly.update(target: .artwork(141), now: t0 + 20.3, samePicture: samePicture), .flip,
                    "翻牌: 封面进广告前就到了,正片揭晓那一拍翻回来")
        var preRollLate = FP(shown: .artwork(130))
        preRollLate.trackChanged(staleArtwork: [130], now: t0)
        _ = preRollLate.update(target: .adIcon, now: t0 + 2, samePicture: samePicture)
        preRollLate.adBreakEnded(now: t0 + 8)
        expectEqual(preRollLate.update(target: .artwork(130), now: t0 + 8, samePicture: samePicture), nil,
                    "翻牌: 前贴片广告结束、手上还是上一首的封面,先留着喇叭")
        expectEqual(preRollLate.recheckAt, t0.addingTimeInterval(8 + FP.shortHold), "翻牌: 广告结束后从结束那一刻重新计时")
        preRollLate.reveal()
        expectEqual(preRollLate.update(target: .artwork(131), now: t0 + 9, samePicture: samePicture), .flip,
                    "翻牌: 广告结束后新封面到了翻成封面")
        // 换歌翻牌的揭晓:换歌后封面等控制器揭晓(歌名掉下来的那一拍)才换;换成喇叭不等;揭晓等满 awaitWindow 还没来就原地换。
        var revealLater = FP(shown: .artwork(150))
        revealLater.trackChanged(staleArtwork: [150], now: t0)
        expectEqual(revealLater.update(target: .artwork(160), now: t0 + 0.2, samePicture: samePicture), nil,
                    "揭晓: 新封面比揭晓先到,先不翻")
        expectEqual(revealLater.shown, .artwork(150), "揭晓: 揭晓之前接着显示原来那张")
        revealLater.reveal()
        expectEqual(revealLater.update(target: .artwork(160), now: t0 + 0.3, samePicture: samePicture), .flip,
                    "揭晓: 揭晓那一拍翻")
        var revealFirst = FP(shown: .artwork(170))
        revealFirst.trackChanged(staleArtwork: [170], now: t0)
        revealFirst.reveal()
        expectEqual(revealFirst.update(target: .artwork(180), now: t0 + 1.2, samePicture: samePicture), .flip,
                    "揭晓: 先揭晓的,新封面一到就翻")
        var adNotGated = FP(shown: .artwork(190))
        adNotGated.trackChanged(staleArtwork: [190], now: t0)
        expectEqual(adNotGated.update(target: .adIcon, now: t0 + 0.1, samePicture: samePicture), .cut,
                    "揭晓: 换成喇叭不等揭晓")
        var fadeIn = FP(shown: .empty)
        fadeIn.trackChanged(staleArtwork: [], now: t0)
        expectEqual(fadeIn.update(target: .artwork(200), now: t0 + 0.2, samePicture: samePicture), nil,
                    "揭晓: 上一首没封面,这首的封面也等揭晓再淡入")
        fadeIn.reveal()
        expectEqual(fadeIn.update(target: .artwork(200), now: t0 + 0.3, samePicture: samePicture), .fade,
                    "揭晓: 揭晓那一拍淡入")
        var neverRevealed = FP(shown: .artwork(210))
        neverRevealed.trackChanged(staleArtwork: [210], now: t0)
        expectEqual(neverRevealed.update(target: .artwork(220), now: t0 + 1, samePicture: samePicture), nil,
                    "揭晓: 迟迟不揭晓,先不翻")
        expectEqual(neverRevealed.recheckAt, t0.addingTimeInterval(FP.awaitWindow), "揭晓: 等不来揭晓,到点再看一眼")
        expectEqual(neverRevealed.update(target: .artwork(220), now: t0 + FP.awaitWindow, samePicture: samePicture), .cut,
                    "揭晓: 等满 awaitWindow 还没揭晓,原地换")
        // 控制器那一侧:判成要掉时等这首的封面,封面到了跟掉歌名同一拍;最多等 artworkWait;判成不掉当场揭晓。
        typealias RG = NotchTrackRevealGate
        var gate = RG()
        gate.trackChanged()
        expectEqual(gate.decided(key: "B", wantsDrop: true, now: t0), nil, "揭晓: 判成要掉、封面还没到,先等")
        expectEqual(gate.deadline, t0.addingTimeInterval(RG.artworkWait), "揭晓: 最多等 artworkWait")
        expectEqual(gate.artworkArrived(), RG.Reveal(key: "B", drops: true), "揭晓: 封面到了,掉歌名跟翻封面同一拍")
        expectEqual(gate.artworkArrived(), nil, "揭晓: 揭晓过了,之后再换图不再揭晓")
        gate.trackChanged()
        _ = gate.artworkArrived()
        expectEqual(gate.decided(key: "C", wantsDrop: true, now: t0 + 5), RG.Reveal(key: "C", drops: true),
                    "揭晓: 封面比判定先到,判定那一拍就揭晓")
        gate.trackChanged()
        _ = gate.decided(key: "D", wantsDrop: true, now: t0 + 10)
        expectEqual(gate.artworkWaitExpired(), RG.Reveal(key: "D", drops: true), "揭晓: 封面等不来,到点先掉歌名")
        expectEqual(gate.deadline, nil, "揭晓: 到点揭晓之后不再等")
        gate.trackChanged()
        expectEqual(gate.decided(key: "E", wantsDrop: false, now: t0 + 20), RG.Reveal(key: "E", drops: false),
                    "揭晓: 判成不掉(第一首、广告、开关关着、卡片看不见),当场揭晓")
        gate.trackChanged()
        _ = gate.decided(key: "F", wantsDrop: true, now: t0 + 30)
        gate.trackChanged()
        expectEqual(gate.artworkArrived(), nil, "揭晓: 等封面时又换了一首,上一次判定作废")
        expectEqual(gate.artworkWaitExpired(), nil, "揭晓: 作废的判定到点也不揭晓")
        var preRollGate = RG()
        preRollGate.trackChanged()
        _ = preRollGate.artworkArrived()
        expectEqual(preRollGate.decided(key: "ad:G", wantsDrop: false, now: t0), RG.Reveal(key: "ad:G", drops: false),
                    "揭晓: 前贴片广告那一拍判成不掉,当场揭晓")
        expectEqual(preRollGate.decided(key: "G", wantsDrop: true, now: t0 + 20), RG.Reveal(key: "G", drops: true),
                    "揭晓: 前贴片广告结束、歌名没变,封面广告期间就到了,正片那一拍就掉歌名")
        let flipViewSrc = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/UI/NotchTrackChangeViews.swift"),
            encoding: .utf8)) ?? ""
        expectEqual(flipViewSrc.contains("if !old.isAdBreak, new.isAdBreak { trackBeforeAd = old.track }")
                    && flipViewSrc.contains("new.track == trackBeforeAd {")
                    && flipViewSrc.contains("planner.adBreakEnded(now: now)"), true,
                    "翻牌契约: 广告结束回到进广告前那首,走「广告结束」不走「换歌」")
        // 换歌翻牌:同一张图的两种分辨率算同一张,不同封面不算。
        func syntheticCover(side: Int, paint: (CGContext, CGFloat) -> Void) -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            paint(ctx, CGFloat(side))
            return ctx.makeImage()
        }
        let gradient: (CGContext, CGFloat) -> Void = { ctx, s in
            for x in 0..<Int(s) {
                let f = CGFloat(x) / s
                ctx.setFillColor(red: f, green: 0.35, blue: 1 - f, alpha: 1)
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: s))
            }
        }
        let split: (CGContext, CGFloat) -> Void = { ctx, s in
            ctx.setFillColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s / 2))
            ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
            ctx.fill(CGRect(x: 0, y: s / 2, width: s, height: s / 2))
        }
        if let big = syntheticCover(side: 600, paint: gradient).flatMap(ArtworkFingerprint.init(image:)),
           let small = syntheticCover(side: 90, paint: gradient).flatMap(ArtworkFingerprint.init(image:)),
           let other = syntheticCover(side: 600, paint: split).flatMap(ArtworkFingerprint.init(image:)) {
            expectEqual(big.isSamePicture(as: small), true, "封面指纹: 同一张图的高清 / 低清两份算同一张")
            expectEqual(big.isSamePicture(as: other), false, "封面指纹: 不同的封面不算同一张")
        } else {
            expectEqual(false, true, "封面指纹: 合成图建不出来")
        }
        // 换歌翻牌那枚音符:封面里最鲜艳的那种颜色,调亮到深底上读得清;封面里没有够鲜艳的颜色就是 nil(画白)。
        let vividSide = ArtworkVividColor.side
        let vividCount = vividSide * vividSide
        func vividPixels(_ fill: (Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(vividCount * 4)
            for i in 0..<vividCount {
                let c = fill(i)
                out += [c.0, c.1, c.2, 255]
            }
            return out
        }
        let redOnGray = vividPixels { $0 < vividCount / 10 ? (200, 30, 40) : (120, 118, 115) }
        if let red = ArtworkVividColor.color(rgba: redOnGray) {
            expectEqual(red.r > red.g && red.r > red.b, true, "音符色: 灰封面上一块红,取到的是红")
            var sum = (r: 0.0, g: 0.0, b: 0.0)
            for i in stride(from: 0, to: redOnGray.count, by: 4) {
                sum.r += Double(redOnGray[i])
                sum.g += Double(redOnGray[i + 1])
                sum.b += Double(redOnGray[i + 2])
            }
            let dim = (1 - LocalPlaybackSource.notchCoverArtOverlayOpacity) / Double(vividCount) / 255
            let backdrop = LocalPlaybackSource.relativeLuminance(r: sum.r * dim, g: sum.g * dim, b: sum.b * dim)
            let own = LocalPlaybackSource.relativeLuminance(r: red.r, g: red.g, b: red.b)
            expectEqual(LocalPlaybackSource.contrastRatio(backdrop, own) >= 4.5 - 1e-6, true,
                        "音符色: 跟压暗后的封面底拉开 4.5:1")
            expectEqual(own > 0.3, true, "音符色: 调成亮色,不是封面里原来那块暗红")
        } else {
            expectEqual(false, true, "音符色: 灰封面上一块红,应该取得到")
        }
        expectEqual(ArtworkVividColor.color(rgba: vividPixels { _ in (128, 128, 128) }) == nil, true,
                    "音符色: 纯灰封面没有鲜艳色,画白")
        expectEqual(ArtworkVividColor.color(rgba: vividPixels { $0 < vividCount / 100 ? (220, 20, 30) : (40, 40, 40) }) == nil,
                    true, "音符色: 鲜艳的像素不到 2% 不算")
        if let gold = ArtworkVividColor.color(rgba: vividPixels { _ in (200, 150, 40) }) {
            expectEqual(gold.r >= gold.g && gold.g > gold.b, true, "音符色: 金色封面取到的还是金色")
        } else {
            expectEqual(false, true, "音符色: 金色封面应该取得到")
        }
        // 收听里程碑:单曲 100 / 1,000 / 10,000……;累计不到 1 万时 1,000、5,000,之后每满 1 万。
        typealias MR = ListenMilestoneRules
        expectEqual([99, 100, 101, 500, 1_000, 5_000, 10_000, 100_000].map(MR.isTrackMilestone),
                    [false, true, false, false, true, false, true, true], "里程碑: 单曲只认 100 起的 10 的整数次幂")
        expectEqual([999, 1_000, 2_000, 5_000, 9_000, 10_000, 15_000, 20_000, 30_000].map(MR.isTotalMilestone),
                    [false, true, false, true, false, true, false, true, true], "里程碑: 累计 1,000 / 5,000 / 每满 1 万")
        expectEqual(MR.totalMilestoneCrossed(from: 29_117, to: 29_118), nil, "里程碑: 没跨档不报")
        expectEqual(MR.totalMilestoneCrossed(from: 29_999, to: 30_000), 30_000, "里程碑: 正好到 3 万")
        expectEqual(MR.totalMilestoneCrossed(from: 4_999, to: 5_001), 5_000, "里程碑: 不到 1 万时的 5,000 档")
        expectEqual(MR.totalMilestoneCrossed(from: 900, to: 1_000), 1_000, "里程碑: 1,000 档")
        expectEqual(MR.totalMilestoneCrossed(from: 0, to: 25_000), 20_000, "里程碑: 一次跨好几档只报最大的")
        expectEqual(MR.totalMilestoneCrossed(from: 30_001, to: 30_000), nil, "里程碑: 累计数变小不报")
        var totals = ListenMilestoneLedger()
        expectEqual(totals.takeTotalMilestone(ordinal: 29_118), nil, "里程碑: 第一次看到累计数只记下,不补报之前的档")
        expectEqual(totals.lastSeenTotal, 29_118, "里程碑: 第一次看到就记下基线")
        expectEqual(totals.takeTotalMilestone(ordinal: 29_999), nil, "里程碑: 没到下一档")
        expectEqual(totals.takeTotalMilestone(ordinal: 30_000), 30_000, "里程碑: 跨过 3 万那一首报")
        expectEqual(totals.takeTotalMilestone(ordinal: 30_001), nil, "里程碑: 同一档不报第二次")
        var late = ListenMilestoneLedger(lastSeenTotal: 29_990)
        expectEqual(late.takeTotalMilestone(ordinal: 30_049), 30_000, "里程碑: 晚几十首看到也还报")
        var stale = ListenMilestoneLedger(lastSeenTotal: 15_000)
        expectEqual(stale.takeTotalMilestone(ordinal: 30_200), nil, "里程碑: 跨过太久的档不补")
        expectEqual(stale.lastSeenTotal, 30_200, "里程碑: 不补报也把基线挪到现在")
        var switched = ListenMilestoneLedger(lastSeenTotal: 29_000)
        expectEqual(switched.takeTotalMilestone(ordinal: 900), nil, "里程碑: 累计数大幅变小(换了账号)不报")
        expectEqual(switched.takeTotalMilestone(ordinal: 1_000), 1_000, "里程碑: 换账号后从新的数重新起算")
        var dip = ListenMilestoneLedger(lastSeenTotal: 29_118)
        expectEqual(dip.takeTotalMilestone(ordinal: 29_110), nil, "里程碑: 删了几条记录、累计数小幅变小时不报")
        expectEqual(dip.lastSeenTotal, 29_118, "里程碑: 小幅变小时基线不往回退")
        let k100 = ListenMilestoneLedger.trackKey(familyKey: "稻香|周杰伦", count: 100)
        var tracks = ListenMilestoneLedger()
        expectEqual(tracks.allowsTrack(k100, today: "2026-10-03"), true, "里程碑: 新的一档可以报")
        tracks.recordTrack(k100, today: "2026-10-03")
        expectEqual(tracks.allowsTrack(k100, today: "2026-10-09"), false, "里程碑: 同一首同一档一辈子只报一次")
        tracks.recordTrack("b#100", today: "2026-10-03")
        expectEqual(tracks.allowsTrack("c#100", today: "2026-10-03"), false, "里程碑: 单曲每天最多报两次")
        expectEqual(tracks.allowsTrack("c#100", today: "2026-10-04"), true, "里程碑: 第二天名额重置")
        tracks.recordTrack("c#100", today: "2026-10-04")
        expectEqual(tracks.shownToday, 1, "里程碑: 换天时当天计数从零起")
        let roundTrip = try? JSONDecoder().decode(ListenMilestoneLedger.self, from: JSONEncoder().encode(tracks))
        expectEqual(roundTrip, tracks, "里程碑: 记账存取一来一回不丢东西")
        do {
            let uiDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lyrimuse/UI")
            func src(_ n: String) -> String { (try? String(contentsOf: uiDir.appendingPathComponent(n), encoding: .utf8)) ?? "" }
            let v = src("NotchLyricsView.swift"), reveal = src("NotchRevealShape.swift"), stageSrc = src("NotchEditorStage.swift")
            let rootSrc = src("NotchWindowRoot.swift"), liveSrc = src("NotchCornerLive.swift")
            // 四处外形都从 chrome 的 cardOutline + NotchCornerLive 拼同一个形状。
            expectEqual(liveSrc.contains(".card(notchHeight: notchHeight, corner: corner(live))"), true, "外轮廓契约: 外形统一由 NotchCardOutline 拼成 .card")
            expectEqual(v.contains("content.clipShape(outline.shape(live))"), true, "外轮廓契约: 卡片自己那道裁剪用 .card")
            expectEqual(v.contains("NotchCardClip(enabled: !hostClipsCard, outline: controller.cardOutline)"), true,
                        "外轮廓契约: 卡片裁剪的肩膀按这块屏的刘海高度、圆角按设置")
            expectEqual(v.contains("NotchCardOutlineReader(outline: controller.cardOutline) { $0.fill(playback.notchCardStyle.fill) }"), true,
                        "外轮廓契约: 纯色底用 .card")
            expectEqual(reveal.contains("return NotchHangingShape.card(notchHeight: notchHeight, corner: corner).path(in: visible)"), true,
                        "外轮廓契约: 出场裁剪终态与卡片同形(真窗口里只留这一道)")
            expectEqual(reveal.contains("notchHeight: outline.notchHeight, corner: outline.corner(live))"), true,
                        "外轮廓契约: 出场裁剪的圆角也从 NotchCornerLive 取")
            expectEqual(rootSrc.contains(".modifier(NotchRevealClip(widthFraction: state.widthFraction,")
                        && rootSrc.contains("outline: controller.cardOutline))"), true,
                        "外轮廓契约: 出场裁剪传的是同一个刘海高度和圆角")
            expectEqual(stageSrc.contains("NotchCardOutlineReader(outline: chrome.cardOutline) {\n            $0.stroke("), true,
                        "外轮廓契约: 编辑台拖宽度那圈虚线跟卡片同形")
            // 圆角按这一帧的高度算,不靠动画插值:两道形状都不该再声明 animatableData(插值的起点会把没展开那张卡片拉成直角再长回来)。
            expectEqual(v.contains("r = NotchOutline.clampedCornerRadius(corner.radius(height: rect.height), height: rect.height,"), true,
                        "圆角契约: 卡片形状按这一帧的高度取圆角、按 高 − 肩膀 夹")
            let shapeDecl: String = {
                guard let a = v.range(of: "struct NotchHangingShape: Shape {"),
                      let b = v.range(of: "\n}\n", range: a.upperBound..<v.endIndex) else { return "" }
                return String(v[a.lowerBound..<b.lowerBound])
            }()
            expectEqual(shapeDecl.isEmpty, false, "圆角契约: 切得出 NotchHangingShape")
            expectEqual(shapeDecl.contains("animatableData") || reveal.contains("animatableData"), false,
                        "圆角契约: 卡片形状与出场裁剪都不靠插值")
            expectEqual(stageSrc.contains("slot: .collapsed,\n                            cardHeight: card.cardHeight(expanded: false))")
                        && stageSrc.contains("slot: .expanded,\n                            cardHeight: card.cardHeight(expanded: true))")
                        && stageSrc.contains("slot == .collapsed ? \\.notchCornerRadius : \\.notchExpandedCornerRadius"), true,
                        "圆角契约: 「风格」里两行分别接两个设置,各按自己那一态的卡片高度")
            // 拖动中不写 AppSettings(每一格都会打醒所有观察它的界面),松手才写回;滑杆上限跟着这一态的卡片高度走。
            expectEqual(stageSrc.contains("set: { corners.drag(slot, to: $0) }")
                        && stageSrc.contains("if editing { corners.beginDrag(slot) } else { corners.endDrag() }")
                        && stageSrc.contains("let range = NotchOutline.customRadiusRange(cardHeight: cardHeight, notchHeight: notchHeight)")
                        && stageSrc.contains("), in: range, step: 1, onEditingChanged: { editing in"), true,
                        "圆角契约: 滑杆拖动只改 NotchCornerLive、松手提交,上限按卡片高度")
            expectEqual(stageSrc.contains(".onDisappear {\n            corners.endDrag()\n            corners.clearHover()\n        }"), true,
                        "圆角契约: 拖到一半、或指针还停在行上时页面没了,值写回去、预览放开")
            let dragBody: String = {
                guard let a = liveSrc.range(of: "func drag(_ slot: NotchCornerSlot, to value: Double) {"),
                      let b = liveSrc.range(of: "\n    }\n", range: a.upperBound..<liveSrc.endIndex) else { return "" }
                return String(liveSrc[a.lowerBound..<b.lowerBound])
            }()
            expectEqual(dragBody.isEmpty, false, "圆角契约: 切得出 NotchCornerLive.drag")
            expectEqual(dragBody.contains("AppSettings") || dragBody.contains("settings."), false, "圆角契约: 拖动中的一格不碰 AppSettings")
            expectEqual(liveSrc.contains("if settings.notchCornerRadius != collapsed { settings.notchCornerRadius = collapsed }")
                        && liveSrc.contains("if settings.notchExpandedCornerRadius != expanded { settings.notchExpandedCornerRadius = expanded }"), true,
                        "圆角契约: 松手按正在拖的那一态写回 AppSettings(带相等守卫)")
            expectEqual(liveSrc.contains("settings.$notchCornerRadius.removeDuplicates().sink")
                        && liveSrc.contains("settings.$notchExpandedCornerRadius.removeDuplicates().sink"), true,
                        "圆角契约: NotchCornerLive 跟着 AppSettings 从别处来的改动走")
            // 只有画外形的那几层观察 NotchCornerLive:拖动时不重算整张卡片。
            let observesLive = "@ObservedObject private var live = NotchCornerLive.shared"
            expectEqual(liveSrc.contains(observesLive) && v.contains(observesLive) && reveal.contains(observesLive), true,
                        "圆角契约: 纯色底 / 虚线框、卡片自裁、出场裁剪三处各自观察 NotchCornerLive")
            let ctrlSrc = src("NotchLyricsWindowController.swift")
            expectEqual(ctrlSrc.contains("CornerRadius"), false, "圆角契约: 真窗口控制器不镜像圆角(镜像的话每一格都重算整张卡片)")
            // 调「展开圆角」时(按着滑杆,或指针停在那一行上)预览摆成展开态,移开交还给指针 / 浮层。
            expectEqual(stageSrc.contains("var isExpanded: Bool { cornerFocus.map { $0 == .expanded } ?? pointerExpanded }")
                        && stageSrc.contains("NotchCornerLive.shared.focusPublisher")
                        && liveSrc.contains("Publishers.CombineLatest($adjusting, $hovered).map { $0 ?? $1 }"), true,
                        "圆角契约: 正拖着或指针停在哪一态那一行上,预览就摆成哪一态(拖着的优先)")
            expectEqual(stageSrc.contains(".onHover { inside in corners.hover(slot, inside: inside) }"), true,
                        "圆角契约: 圆角两行都报指针进出")
            expectEqual(liveSrc.contains("} else if hovered == slot {"), true, "圆角契约: 指针离开一行只清自己,不清相邻那一行先报的「进」")
            let designSrc = (try? String(contentsOf: uiDir.deletingLastPathComponent().appendingPathComponent("Settings/SettingsDesignSystem.swift"),
                                         encoding: .utf8)) ?? ""
            expectEqual(designSrc.contains("), in: range, onEditingChanged: onEditingChanged)"), true,
                        "圆角契约: SteppedSlider 把按下 / 松手转出来")
            expectEqual(stageSrc.contains("settings[keyPath: stored] = NotchOutline.notchRadiusSetting")
                        && stageSrc.contains("settings[keyPath: stored] = NotchOutline.defaultRadiusSetting"), true,
                        "圆角契约: 菜单里能选回「默认」和「跟随刘海」")
            expectEqual(stageSrc.contains("settings.notchCornerRadius = AppSettings.defaultNotchCornerRadius")
                        && stageSrc.contains("settings.notchExpandedCornerRadius = AppSettings.defaultNotchExpandedCornerRadius"), true,
                        "圆角契约: 「恢复默认」把两个圆角也恢复成默认")
            expectEqual(v.contains("NotchHangingShape(bottomCornerRadius: 20)") || reveal.contains("NotchHangingShape(bottomCornerRadius: 20)")
                        || stageSrc.contains("NotchHangingShape(bottomCornerRadius: 20)"), false,
                        "外轮廓契约: 卡片不再有写死 20pt 圆角的那一份")
            // 没放歌时预览跟真窗口画同一套(空闲面板):有没有曲目只有一个判据。
            expectEqual(stageSrc.contains("var hasTrack: Bool { true }"), false, "预览契约: 有没有曲目不写死成 true")
            expectEqual(stageSrc.contains("NotchLyricsWindowController.trackPresent(title: title, artist: artist, isAdBreak: isAd)")
                        && ctrlSrc.contains("Self.trackPresent(title: title, artist: artist, isAdBreak: isAd)"), true,
                        "预览契约: 预览和真窗口按同一个判据、同一组输入判断有没有曲目")
            // 收听里程碑:灵动岛自己撑开报喜的接线。
            let centerSrc = src("ListenMilestoneCenter.swift")
            expectEqual(ctrlSrc.contains("let next = hoverExpanded || alertHold || milestoneHold")
                        && ctrlSrc.contains("ListenMilestoneCenter.shared.$current.removeDuplicates().sink")
                        && ctrlSrc.contains("milestoneObserver?.cancel()"), true,
                        "里程碑契约: 控制器镜像报喜、撑开卡片,收尾取消订阅")
            expectEqual(ctrlSrc.contains("geo.notchHeight + NotchMetrics.milestonePanelHeight))"), true,
                        "里程碑契约: 窗口高度兜得住报喜卡片")
            expectEqual(v.contains("if milestone != nil { return contentTopInset + NotchMetrics.milestonePanelHeight }"), true,
                        "里程碑契约: 报喜时卡片高度换成报喜面板那一档")
            expectEqual(stageSrc.contains("var milestone: ListenMilestone? { nil }"), true, "里程碑契约: 预览不报里程碑")
            expectEqual(centerSrc.contains("settings.notchOverlayEnabled && settings.notchListenMilestones")
                        && centerSrc.contains("!playback.isCurrentTrackAdBreak")
                        && centerSrc.contains("guard stats.isConnected else { return }"), true,
                        "里程碑契约: 灵动岛开着、开关开着、连着 Last.fm、不在广告里才报")
            expectEqual(centerSrc.contains("NotchLyricsWindowController.shared"), false,
                        "里程碑契约: 里程碑中心不碰灵动岛控制器的 .shared(碰一下就会建窗口)")
            let panelSrc = src("NotchMilestonePanel.swift")
            expectEqual(panelSrc.contains(".allowsHitTesting(false)\n        .accessibilityHidden(true)")
                        && rootSrc.contains("NotchMilestoneConfetti(milestone: controller.milestone"), true,
                        "里程碑契约: 碎屑挂在裁剪外面、不吃点击")
            let portabilitySrc = (try? String(contentsOf: uiDir.deletingLastPathComponent()
                .appendingPathComponent("Settings/ConfigPortability.swift"), encoding: .utf8)) ?? ""
            expectEqual(portabilitySrc.contains("\"np:listenMilestoneLedger\","), true,
                        "里程碑契约: 报喜记账是机器本地状态,不随配置导出")
            // 换歌翻牌:掉歌名的接线与卡片高度;左耳的翻牌连广告时的喇叭一起画。
            expectEqual(v.contains(": (trackDrop != nil ? NotchMetrics.trackDropHeight : 0))"), true,
                        "换歌翻牌契约: 关着歌词行时卡片为掉出来的歌名多长一截")
            expectEqual(stageSrc.contains("var trackDrop: NotchTrackDrop? { nil }"), true, "换歌翻牌契约: 预览不掉歌名")
            expectEqual(ctrlSrc.contains("&& AppSettings.shared.notchShowsTrackDrop")
                        && ctrlSrc.contains("!isCollapsed && !isExpanded && milestone == nil && !alertHold")
                        && ctrlSrc.contains("trackDropObserver?.cancel()"), true,
                        "换歌翻牌契约: 开关开着、卡片看得见、不在收起 / 展开 / 报喜 / 提醒里才掉,收尾取消订阅")
            expectEqual(v.contains("NotchCardLayerActive(active: !expanded && shownTrackDrop == nil"), true,
                        "换歌翻牌契约: 开着歌词行时歌名盖上来,稳态那份歌词行让开")
            expectEqual(v.contains("flippingEarArtwork(alignment: .leading, showsAdIcon: controller.isAdBreakNow)"), true,
                        "换歌翻牌契约: 左耳的翻牌连广告时的喇叭一起画(广告结束才能翻成封面)")
            expectEqual(v.contains("} else if leftModule == .artwork {\n")
                        && v.contains("case .artwork:\n            flippingEarArtwork(alignment: alignment, showsAdIcon: false)")
                        && !v.contains("notchShowsTrackDrop"), true,
                        "换歌翻牌契约: 耳朵里的封面一直走翻牌,「换歌时显示歌名」只管歌名条")
            let dropSrc = src("NotchTrackChangeViews.swift")
            expectEqual(dropSrc.contains("Image(systemName: \"music.note\")")
                        && dropSrc.contains(".foregroundStyle(.white.opacity(0.96))")
                        && dropSrc.contains("scrim.modifier(NotchTrackDropReveal(progress: progress, travel: 0))"), true,
                        "换歌翻牌契约: 歌名白字、颜色只给音符,暗晕只在有歌名时出现")
            expectEqual(rootSrc.contains("if controller.trackDrop != nil {\n            return NotchTrackDropStrip.revealAnimation")
                        && rootSrc.contains("if wasDropping {\n            return NotchTrackDropStrip.retractAnimation")
                        && rootSrc.contains(".onChange(of: controller.trackDrop != nil) { _, dropping in wasDropping = dropping }")
                        && dropSrc.contains(".animation(animated ? (drop == nil ? Self.retractAnimation : Self.revealAnimation)")
                        && dropSrc.contains(".modifier(NotchTrackDropReveal(progress: progress, travel: animated ? height : 0))"), true,
                        "换歌翻牌契约: 歌名条和卡片高度走同一对弹簧,字的位置只看条子拉开多少")
            expectEqual(ctrlSrc.contains("NotchTrackDropRules.replaced(showing: trackDrop, cleared: clearedTrackDrop?.drop,")
                        && ctrlSrc.contains("clearedTrackDrop = (shown, Date())")
                        && dropSrc.contains("NotchTrackDropRoll(drop: drop ?? lastShown, travel: height, animated: animated)"), true,
                        "换歌翻牌契约: 收回时接着画刚才那条;停着时换歌,新的把旧的推出去")
            expectEqual(dropSrc.contains("Text(Image(systemName: \"music.note\"))")
                        && dropSrc.contains("trigger: drop?.replacing == nil ? -1 : drop?.id ?? -1"), true,
                        "换歌翻牌契约: 音符包在 Text 里跟歌名一起收;关键帧只在推出旧行时跑")
            expectEqual(ctrlSrc.contains(".debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)\n        .sink { [weak self] title, artist, isAd, isWaiting in"), true,
                        "换歌翻牌契约: 掉歌名前的去抖挂主队列,菜单栏菜单开着时也照常走")
            expectEqual(v.contains("playback.notchCardStyle == .coverArt ? (playback.vividAccent ?? .white) : .white"), true,
                        "换歌翻牌契约: 音符只在「跟随封面」风格下取封面色,其余风格白")
            let coordinatorSrc = (try? String(contentsOf: uiDir.deletingLastPathComponent()
                .appendingPathComponent("PlaybackCoordinator.swift"), encoding: .utf8)) ?? ""
            let playbackSrc = (try? String(contentsOf: uiDir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("LyrimuseCore/Local/LocalPlaybackSource.swift"), encoding: .utf8)) ?? ""
            expectEqual(ctrlSrc.contains("PlaybackCoordinator.shared.$isWaitingToPlay")
                        && ctrlSrc.contains("trackDropTracker.observe(title: title, artist: artist, isAdBreak: isAdBreak,")
                        && coordinatorSrc.contains("s.$isWaitingToPlay.assign(to: \\.isWaitingToPlay, on: self),")
                        && playbackSrc.contains("let newIsWaitingToPlay = snapshot.isWaitingToPlay == true")
                        && playbackSrc.contains("if isWaitingToPlay { isWaitingToPlay = false }"), true,
                        "换歌翻牌契约: 声音还没走起来时先不判(播放源发布、协调器转出、控制器接进判定),停播清掉")
            expectEqual(ctrlSrc.contains("PlaybackCoordinator.shared.$artworkImage.dropFirst().map { _ in () }")
                        && ctrlSrc.contains("PlaybackCoordinator.shared.$highResArtworkImage.dropFirst().compactMap { $0 }")
                        && ctrlSrc.contains(".sink { [weak self] _ in self?.trackIdentityChanged() }")
                        && ctrlSrc.contains(".sink { [weak self] in self?.artworkArrived() }")
                        && ctrlSrc.contains("revealGate.decided(key: key, wantsDrop: wantsDrop, now: now)")
                        && ctrlSrc.contains("if revealedTrackKey != reveal.key { revealedTrackKey = reveal.key }")
                        && ctrlSrc.contains("func revealsTrack(_ key: String) -> Bool { revealedTrackKey == key }")
                        && ctrlSrc.contains("artworkArrivalObserver?.cancel()"), true,
                        "换歌翻牌契约: 揭晓接线(歌名一变当封面没到、封面到了、去抖后的判定),收尾取消订阅")
            expectEqual(stageSrc.contains("func revealsTrack(_ key: String) -> Bool { true }"), true,
                        "换歌翻牌契约: 预览不等揭晓")
            expectEqual(v.contains("isRevealed: controller.revealsTrack(NotchTrackDropRules.key(")
                        && dropSrc.contains("if new.isRevealed { planner.reveal() }"), true,
                        "换歌翻牌契约: 耳朵里的封面按揭晓翻")
        }

        // 自动跳过:只在页面确认能跳时按,一条广告最多两次,跳过了 / 缺权限就不再试。
        typealias A = YouTubeMusicAdAutoSkip
        expectEqual(A.shouldAttempt(enabled: true, state: .ready, attempts: 0, stopped: false), true, "自动跳过: 开着 + 能跳 = 按")
        expectEqual(A.shouldAttempt(enabled: false, state: .ready, attempts: 0, stopped: false), false, "自动跳过: 关着不按")
        expectEqual(A.shouldAttempt(enabled: true, state: .after(seconds: 3), attempts: 0, stopped: false), false,
                    "自动跳过: 倒计时期间不按(按了也只是「还不能跳过」)")
        expectEqual(A.shouldAttempt(enabled: true, state: .never, attempts: 0, stopped: false), false, "自动跳过: 不可跳过的广告不按")
        expectEqual(A.shouldAttempt(enabled: true, state: nil, attempts: 0, stopped: false), false, "自动跳过: 门槛没跑成不按")
        expectEqual(A.shouldAttempt(enabled: true, state: .notInAd, attempts: 0, stopped: false), false, "自动跳过: 广告已结束不按")
        expectEqual(A.shouldAttempt(enabled: true, state: .ready, attempts: A.maxAttemptsPerAd - 1, stopped: false), true,
                    "自动跳过: 第一次没成还能再试一次")
        expectEqual(A.shouldAttempt(enabled: true, state: .ready, attempts: A.maxAttemptsPerAd, stopped: false), false,
                    "自动跳过: 一条广告按满次数就停(不对按不动的页面反复发 AppleEvent)")
        expectEqual(A.shouldAttempt(enabled: true, state: .ready, attempts: 0, stopped: true), false, "自动跳过: 判定不必再试就不按")
        expectEqual(A.stopsRetrying(after: .skipped), true, "自动跳过: 跳过了就不再试")
        expectEqual(A.stopsRetrying(after: .needsAccessibility), true, "自动跳过: 缺辅助功能权限再按也一样,不再试")
        expectEqual(A.stopsRetrying(after: .clickedNoEffect), false, "自动跳过: 按了没生效可以再试")
        expectEqual(A.stopsRetrying(after: .tabNotFrontmost), false, "自动跳过: 标签页不在前面,用户切过去之后还能再试")
        expectEqual(A.stopsRetrying(after: nil), false, "自动跳过: 脚本没跑成可以再试")
        expectEqual(A.feedback(for: .skipped, alreadyPromptedAccessibility: false), .skipped, "自动跳过反馈: 跳过了要说一声")
        expectEqual(A.feedback(for: .needsAccessibility, alreadyPromptedAccessibility: false), .needsAccessibility,
                    "自动跳过反馈: 第一次缺权限提示授权")
        expectEqual(A.feedback(for: .needsAccessibility, alreadyPromptedAccessibility: true), .none,
                    "自动跳过反馈: 缺权限每段运行只提示一次,不每条广告弹一次框")
        expectEqual(A.feedback(for: .clickedNoEffect, alreadyPromptedAccessibility: false), .none, "自动跳过反馈: 没按成不打扰")
        expectEqual(A.feedback(for: .tabNotFrontmost, alreadyPromptedAccessibility: false), .none,
                    "自动跳过反馈: 标签页不在前面不打扰(手动那颗键才提示切过去)")
        expectEqual(A.feedback(for: .notYetSkippable(secondsUntilSkippable: 2), alreadyPromptedAccessibility: false), .none,
                    "自动跳过反馈: 还不能跳不打扰")

        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: "com.spotify.client"), true,
                    "门槛: Spotify 桌面版的广告不是浏览器,轮询收手")
        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: "com.apple.Safari"), false, "门槛: Safari 照常探")
        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: "com.brave.Browser"), false, "门槛: Brave 照常探")
        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: nil), false,
                    "门槛: 还没解析到播放器不算(广告刚开始那一拍),下一拍可能就是浏览器")
        expectEqual(YouTubeMusicAdSkipper.isKnownNonBrowser(reportedBundleID: ""), false, "门槛: 空串同上")

        // 后台标签页:临时切过去按、按完切回;用户正在看的那扇窗口不切。
        typealias F = BrowserTabFocus
        expectEqual(F.parse("ALREADY"), .alreadyCurrent, "切标签页: 本来就是当前页")
        expectEqual(F.parse("\"FRONTWINDOW\"\n"), .frontWindow, "切标签页: 用户正在看的窗口(脱掉 AppleScript 的引号)")
        expectEqual(F.parse("NOTFOUND"), .notFound, "切标签页: 没有标签页在放广告")
        expectEqual(F.parse("SWITCHED|4127|2|5"), .switched(windowID: "4127", previousIndex: 2, tabIndex: 5), "切标签页: 切过去了,记下怎么切回")
        expectEqual(F.parse("SWITCHED|x|y|5"), nil, "切标签页: 字段坏了不当成切过去(不然会拿垃圾值去切回)")
        expectEqual(F.parse("SWITCHED|A1B2-C3|2|5"), .switched(windowID: "A1B2-C3", previousIndex: 2, tabIndex: 5),
                    "切标签页: Arc 的窗口 id 是文本,照样认")
        expectEqual(F.parse("garbage"), nil, "切标签页: 看不懂的返回是 nil")
        expectEqual(F.adTabJS.contains("\"") || F.adTabJS.contains("\\"), false,
                    "切标签页: JS 里没有双引号 / 反斜杠(要嵌进 AppleScript 双引号串)")
        let safariFocus = F.focusScript(bundleID: "com.apple.Safari", family: .safari, hostMarker: "music.youtube.com",
                                        avoidFrontWindow: true, eventTimeoutSeconds: 4)
        let chromeFocus = F.focusScript(bundleID: "com.google.Chrome", family: .chromium, hostMarker: "music.youtube.com",
                                        avoidFrontWindow: false, eventTimeoutSeconds: 4)
        expectEqual(safariFocus.contains("if true and wi is 1 then return \"FRONTWINDOW\""), true,
                    "切标签页: 浏览器在前台时,最前面那扇窗口不切")
        expectEqual(chromeFocus.contains("if false and wi is 1 then return \"FRONTWINDOW\""), true,
                    "切标签页: 浏览器在后台时哪扇窗口都能切")
        expectEqual(safariFocus.contains("if curIdx is ti then return \"ALREADY\""), true, "切标签页: 已经是当前页就不动")
        expectEqual(safariFocus.contains("set current tab of window wi to tab ti of window wi"), true, "切标签页: Safari 用 current tab")
        expectEqual(chromeFocus.contains("set active tab index of window wi to ti"), true, "切标签页: Chromium 用 active tab index")
        expectEqual(safariFocus.contains("activate") || chromeFocus.contains("activate"), false,
                    "切标签页: 只换当前标签页,不激活浏览器")
        let safariRestore = F.restoreScript(bundleID: "com.apple.Safari", family: .safari, windowID: "7", previousIndex: 2, tabIndex: 5)
        let chromeRestore = F.restoreScript(bundleID: "com.google.Chrome", family: .chromium, windowID: "7", previousIndex: 2, tabIndex: 5)
        // Arc:字典里没有 `active tab index`(编译不过),窗口 id 是文本。
        let arcFocus = F.focusScript(bundleID: F.arcBundleID, family: .chromium, hostMarker: "music.youtube.com",
                                     avoidFrontWindow: false, eventTimeoutSeconds: 4)
        let arcRestore = F.restoreScript(bundleID: F.arcBundleID, family: .chromium, windowID: "A1B2", previousIndex: 2, tabIndex: 5)
        expectEqual(arcFocus.contains("active tab index") || arcRestore.contains("active tab index"), false,
                    "切标签页: Arc 不用 active tab index")
        expectEqual(arcFocus.contains("select tab ti of window wi") && arcRestore.contains("set w to window id \"A1B2\""), true,
                    "切标签页: Arc 用 select,窗口 id 按文本写")
        expectEqual(chromeRestore.contains("set w to window id 7"), true, "切回: Chrome 的窗口 id 仍按数字写")
        expectEqual(safariRestore.contains("if (index of current tab of w) is 5 then set current tab of w to tab 2 of w"), true,
                    "切回: 那扇窗口的当前页还是 YT Music 才切回(用户自己点走了就不管)")
        expectEqual(chromeRestore.contains("if (active tab index of w) is 5 then set active tab index of w to 2"), true,
                    "切回: Chromium 同一道判断")
        let skipperSrc = (try? String(contentsOfFile: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LyrimuseCore/Local/YouTubeMusicAdSkipper.swift").path, encoding: .utf8)) ?? ""
        expectEqual(skipperSrc.contains("let avoidFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host"), true,
                    "切标签页: 「用户正在用这个浏览器」按前台 App 判")
        if let a = skipperSrc.range(of: "press = pressAfterFocus(browserBundleID: host)"),
           let b = skipperSrc.range(of: "BrowserTabFocus.restore(bundleID: host"),
           let c = skipperSrc.range(of: "Thread.sleep(forTimeInterval: verifyDelay)") {
            expectEqual(a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound, true,
                        "切标签页: 按完立刻切回,不等复核那 0.8s(用户看到的闪动越短越好)")
        } else {
            expectEqual(true, false, "切标签页: skip 里找不到切过去 / 切回 / 复核三处(改名了?)")
        }
        expectEqual(S.fastStartDelay * Double(S.fastStartRounds) < YouTubeMusicAdProbe.adRefreshInterval, true,
                    "门槛节奏: 整个快探窗口要短于一个心跳,否则等于把心跳改快了")
        expectEqual(S.gateRetryDelay(after: .after(seconds: 5), round: 0), 5.4,
                    "门槛节奏: 读到倒计时就精确等到点,不受快探窗口影响")
        expectEqual(S.gateMaxRounds >= 6, true, "门槛节奏: 轮数上限够覆盖一整条插播")
        expectEqual(AccessibilitySkipPress.matchesSkipTitle("播放"), false, "AX 认键(标题兜底): 无关标题不命中")
        expectEqual(S.verifyDelay >= 0.3 && S.verifyDelay <= 2, true, "跳过广告复核: 等待时长在 0.3～2s 之间")
        expectEqual(S.parseClick("SKIPPABLE|BUTTON.ytp-ad-skip-button-modern|赞助商广告 1/2 ·|8"),
                    .skippable(desc: "BUTTON.ytp-ad-skip-button-modern", badge: "赞助商广告 1/2 ·", videoTime: 8),
                    "跳过广告 parseClick: SKIPPABLE 四段")
        expectEqual(S.parseClick("SKIPPABLE|x"), nil, "跳过广告 parseClick: SKIPPABLE 段数不够给 nil")
        expectEqual(S.parseClick("SKIPPED|BUTTON.x|b|8"), nil, "跳过广告 parseClick: 旧版 SKIPPED 形状不再认")
        expectEqual(S.parseClick("NOTYET|3"), .notYet(seconds: 3), "跳过广告 parseClick: NOTYET 带秒数")
        expectEqual(S.parseClick("\"NOTYET|\"\n"), .notYet(seconds: nil), "跳过广告 parseClick: 带引号带换行也能解,没有秒数是 nil")
        expectEqual(S.parseClick("NOTFOUND"), .notFound, "跳过广告 parseClick: NOTFOUND")
        expectEqual(S.parseClick("garbage"), nil, "跳过广告 parseClick: 不认识的形状给 nil(不猜)")
        expectEqual(S.parseClick(""), nil, "跳过广告 parseClick: 空串给 nil")
        expectEqual(S.parseVerify("STILL|赞助商广告 2/2 ·|0"), .still(badge: "赞助商广告 2/2 ·", videoTime: 0), "跳过广告 parseVerify: STILL 三段")
        expectEqual(S.parseVerify("CLEAR"), .clear, "跳过广告 parseVerify: CLEAR")
        expectEqual(S.parseVerify("NOTFOUND"), .notFound, "跳过广告 parseVerify: NOTFOUND")
        expectEqual(S.parseVerify("STILL"), nil, "跳过广告 parseVerify: STILL 缺段给 nil")
        // 「广告走了没」判据:离开广告态算走了;仍在广告态但徽章翻页 / 视频时间倒回也算(插播里的下一条接上了)。
        let clicked = S.ClickResult.skippable(desc: "b", badge: "赞助商广告 1/2 ·", videoTime: 9)
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .clear), true, "跳过广告判据: 离开广告态 = 走了")
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .notFound), true, "跳过广告判据: 播放器没了也算走了")
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 1/2 ·", videoTime: 10)), false,
                    "跳过广告判据: 同一条广告继续走 = 没生效")
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 2/2 ·", videoTime: 10)), true,
                    "跳过广告判据: 徽章 1/2 → 2/2 = 跳到下一条了")
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 1/2 ·", videoTime: 0)), false,
                    "跳过广告判据: 同一条广告视频时间倒回 0 = 被重放,不算跳过(第五版 seek 真机坐实)")
        expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "", videoTime: -1)), false,
                    "跳过广告判据: 徽章为空时只认离开广告态")
        expectEqual(S.adAdvanced(afterClick: .notFound, verify: .still(badge: "x", videoTime: 0)), false,
                    "跳过广告判据: 没点到就谈不上生效")
        let script = BrowserTabProbeScript.build(
            bundleID: "com.google.Chrome", family: .chromium,
            hostMarker: YouTubeMusicAdProbe.hostMarker, js: skipJS,
            eventTimeoutSeconds: YouTubeMusicAdProbe.eventTimeoutSeconds)
        expectEqual(script.contains("music.youtube.com"), true, "跳过广告 AppleScript: 按 YT Music 域名找标签页")
        expectEqual(script.contains("with timeout of"), true, "跳过广告 AppleScript: 套 with timeout")
        // isYouTubeMusicAd 只读探针缓存:没探过的曲目身份一定是 false —— Spotify 的广告走的就是这一条,键不出现。
        expectEqual(S.isYouTubeMusicAd(artist: "selftest-artist-\(UUID().uuidString)", title: "selftest"), false,
                    "跳过广告: 没有探针判定的曲目不算 YT Music 广告")

        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        let view = (try? String(contentsOfFile: ui.appendingPathComponent("NotchLyricsView.swift").path,
                                encoding: .utf8)) ?? ""
        let stage = (try? String(contentsOfFile: ui.appendingPathComponent("NotchEditorStage.swift").path,
                                 encoding: .utf8)) ?? ""
        let center = (try? String(contentsOfFile: ui.appendingPathComponent("YouTubeMusicAdSkipCenter.swift").path,
                                  encoding: .utf8)) ?? ""
        expectEqual(view.isEmpty, false, "广告态契约: 读到 NotchLyricsView.swift")
        expectEqual(center.isEmpty, false, "广告态契约: 读到 YouTubeMusicAdSkipCenter.swift")
        expectEqual(view.contains("var isAdBreakNow: Bool { get }"), true, "广告态契约: NotchChromeSource 声明 isAdBreakNow")
        // 广告期间头部只剩快捷操作那排键:四项曲目字段被 trackInfoShowsTrackFields 挡掉,快捷操作不受它管。
        // 高度算术与渲染两侧都得读这个值,漏一侧就是留一截空白或裁掉半截。
        expectEqual(view.contains("var trackInfoShowsTrackFields: Bool { !isAdBreakNow }"), true,
                    "广告态契约: 头部四项曲目字段在广告期间不画")
        expectEqual(view.contains("|| expandedShowsQuickActions)"), true,
                    "广告态契约: 快捷操作不受广告态挡(广告期间头部照样画那四颗键)")
        expectEqual(view.contains("showsArtwork: fields && expandedTrackInfoShowsArtwork"), true,
                    "广告态契约: 头部高度算术按广告态去掉四项曲目字段")
        expectEqual(view.contains("if controller.trackInfoShowsTrackFields, controller.expandedTrackInfoShowsArtwork"), true,
                    "广告态契约: 头部封面渲染读同一个判据")
        expectEqual(view.contains("if fields && controller.expandedTrackInfoShowsTitle"), true,
                    "广告态契约: 头部文字渲染读同一个判据")
        expectEqual(view.contains("if playback.isCurrentTrackAdBreak {\n                    adStatusColumn"), true,
                    "广告态契约: 歌词行在 lyricRowContent 这一层分流到 adStatusColumn")
        expectEqual(view.contains("showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak"),
                    true, "广告态契约: 广告期间不画歌词校准控件")
        expectEqual(view.contains("YouTubeMusicAdSkipper.isYouTubeMusicAd(artist: artist, title: title)"), true,
                    "广告态契约: canSkipAd 读的是 YT Music 探针的强信号判定")
        expectEqual(view.contains("&& adSkipAvailable"), true,
                    "广告态契约: canSkipAd 还要过「页面此刻真的放出跳过键了」这道门槛(2026-09-11)")
        // 必须是 @Published。倒计时过完、键刚放出来的那一刻,广告态这一格没有任何别的东西在变
        // (「还剩 0:21」那截自己排了一张 TimelineView、只重画它自己),做成计算属性就永远不会被重估。
        expectEqual(view.contains("@Published private(set) var adSkipAvailable"), true,
                    "广告态契约: adSkipAvailable 是 @Published(计算属性不会在键放出来那一刻被重估)")
        expectEqual(center.contains("YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)"), true,
                    "广告态契约: 门槛走 Core 那份只读探测,不另拼一套")
        expectEqual(view.contains("YouTubeMusicAdSkipCenter.shared.$adSkipAvailable"), true,
                    "广告态契约: 灵动岛读 App 里唯一那份门槛结果(每块屏不再各跑一轮)")
        // 门槛轮询**必须**挂 chrome 的 isAdBreakNow、且只有真窗口登记(drivesAdSkipGate),不准挂回 playback 那条订阅 ——
        // 预览也会进广告态,让它登记的后果是设置页开着时,编辑台预览跟着真广告每 5 秒对用户的浏览器发一次 AppleScript
        // (真机日志坐实:每行打两遍)。这跟"预览不产生副作用"是同一条纪律。
        expectEqual(view.contains(".onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: drivesAdSkipGate && on) }"), true,
                    "广告态契约: 门槛轮询由 chrome 的 isAdBreakNow 驱动(广告开始起、结束停),只有真窗口登记")
        expectEqual(view.contains("self?.syncAdSkipGate"), false,
                    "广告态契约: 门槛轮询不准挂回 $isCurrentTrackAdBreak 订阅(预览会跟着对浏览器发 AppleScript)")
        expectEqual(view.contains(".onAppear { playback.syncAdSkipGate(adBreak: drivesAdSkipGate && controller.isAdBreakNow) }"), true,
                    "广告态契约: 窗口出现时已经在放广告也要起轮询(onChange 只认变化)")
        let root = (try? String(contentsOfFile: ui.appendingPathComponent("NotchWindowRoot.swift").path, encoding: .utf8)) ?? ""
        expectEqual(root.contains("reportsLineLayout: true, drivesAdSkipGate: true)") && !stage.contains("drivesAdSkipGate: true"), true,
                    "广告态契约: 只有真窗口替门槛轮询登记,编辑台预览不传")
        expectEqual(view.contains(".onDisappear { playback.syncAdSkipGate(adBreak: false) }"), true,
                    "广告态契约: 窗口没了要撤掉需求,不然灵动岛关了轮询还在跑")
        expectEqual(view.contains("YouTubeMusicAdSkipCenter.shared.setNotchDemand(ObjectIdentifier(self), active: adBreak)"), true,
                    "广告态契约: 灵动岛只是登记需求,轮询在 center")
        // 轮询只在「广告中」且有人要结果时跑:自动跳过开着,或至少一扇真灵动岛在广告态。
        expectEqual(center.contains("let wanted = adBreak && (autoSkipEnabled || !notchDemand.isEmpty)"), true,
                    "广告态契约: 灵动岛关着、自动跳过也关着时一次 AppleEvent 都不发")
        expectEqual(center.contains("if !skipInFlight,\n           YouTubeMusicAdAutoSkip.shouldAttempt(enabled: autoSkipEnabled"), true,
                    "自动跳过契约: 门槛读数走 Core 判据,且不跟正在跑的那次叠")
        let appDelegate = (try? String(contentsOfFile: ui.deletingLastPathComponent().appendingPathComponent("AppDelegate.swift").path,
                                       encoding: .utf8)) ?? ""
        expectEqual(appDelegate.contains("_ = YouTubeMusicAdSkipCenter.shared"), true,
                    "自动跳过契约: 启动就建 center(灵动岛没开过自动跳过也要生效)")

        // 稳态下那枚「可跳过」提示(「这个按钮目前只在展开状态有;帮我在灵动岛歌词行
        // 那里也加一个…可以起到提示可以跳过的作用」)。三道门缺一条就会变成"同一件事说两遍"。
        expectEqual(view.contains("playback.canSkipAd && !controller.isExpanded && !controller.showsLyrics"), true,
                    "广告态契约: 稳态「可跳过」提示三道门都在(展开态、以及稳态歌词行已经有真键时都不画)")
        if let earStart = view.range(of: "private func adBreakEarIcon"),
           let earEnd = view.range(of: "private var showsAdSkipHint") {
            let ear = String(view[earStart.lowerBound ..< earEnd.lowerBound])
            expectEqual(ear.contains("megaphone.fill"), true, "广告态契约: 左耳那枚喇叭还在(提示是加在它旁边,不是顶掉它)")
            expectEqual(ear.contains("forward.end.fill"), true,
                        "广告态契约: 提示用的是跟「跳过广告」键同一枚 forward.end.fill(同一件事不画两种)")
            expectEqual(ear.contains("accessibilityHidden(!hint)"), true,
                        "广告态契约: 带提示时这一组要念给读屏(稳态下它是唯一能知道「能跳」的地方)")
        } else {
            expectEqual(true, false, "广告态契约: 找不到 adBreakEarIcon / showsAdSkipHint(改名了?)")
        }
        expectEqual(center.contains("guard !skipInFlight else { return }"), true, "广告态契约: 跳过广告同一时刻只跑一份(手动与自动共用)")
        expectEqual(center.contains("case .needsAccessibility?:") && center.contains("AccessibilitySkipPress.promptForTrust()"), true,
                    "广告态契约: 没有辅助功能权限时弹系统授权对话框")
        expectEqual(center.contains("case .tabNotFrontmost?:"), true, "广告态契约: 标签页不在前面有专门的提示")
        expectEqual(view.contains(".disabled(playback.skipAdInFlight)"), true, "广告态契约: 跑着的时候键不接第二下")
        expectEqual(!stage.contains("var isAdBreakNow: Bool { false }")
                    && stage.contains("if self.isAdBreakNow != isAd { self.isAdBreakNow = isAd }"), true,
                    "广告态契约: 预览 chrome 的 isAdBreakNow 跟真窗口同源(预览也画广告态)")
        // 用户要的两件(圈图:「广告时候的灵动岛的配色帮我设置为和机器刘海一样的
        // 纯黑色」「在左耳那边加上一个广告的标识图标」)。都钉住,因为它们各自很容易被后来的
        // 改动无声抹掉:纯黑那条是一个 `||` 分支,左耳那条夹在两个 else if 之间。
        expectEqual(view.contains("controller.isCollapsed || isIdleNoTrack || controller.isAdBreakNow"), true,
                    "广告态契约: 广告期间整卡盖成纯黑(跟收起态/无曲目同一层 Color.black)")
        // 「恒显示」是定好的口径(任何广告都固定显示),不是忘了加条件 ——
        // 钉住它,免得以后有人看见"广告有缩略图时喇叭把图顶掉了"当成 bug 修回去。
        expectEqual(view.contains("} else if controller.isAdBreakNow {"), true,
                    "广告态契约: 左耳广告标识在广告期间恒显示,不看配置也不看原本有没有内容")
        expectEqual(view.contains("earShowsNothing"), false,
                    "广告态契约: 判空分支已随「恒显示」一起删干净,没留死代码")
        expectEqual(view.contains("adBreakEarIcon(alignment: .leading)"), true, "广告态契约: 左耳画的是广告标识")
        expectEqual(view.contains("Image(systemName: \"megaphone.fill\")"), true,
                    "广告态契约: 左耳与封面替代方块共用同一枚 megaphone.fill")
        // 状态行不画喇叭(左耳已经有一枚)。钉住它:
        // 左耳那枚是恒显示的,状态行再画一枚就是同一件事说两遍 —— 别当成"图标掉了"改回去。
        if let colStart = view.range(of: "private var adStatusColumn"),
           let colEnd = view.range(of: "private var adCountdown") {
            let col = String(view[colStart.lowerBound ..< colEnd.lowerBound])
            expectEqual(col.contains("Image(systemName: \"megaphone"), false,
                        "广告态契约: 状态行不画喇叭(左耳那枚恒显示,这里再来一枚是重复)")
            expectEqual(col.contains("Text(L10n.t(\"广告中\"))"), true,
                        "广告态契约: 状态行仍以「广告中」开头")
        } else {
            expectEqual(true, false, "广告态契约: 找不到 adStatusColumn / adCountdown(改名了?)")
        }
        // 全 App 一共四个「当前曲目封面」位,广告期间都让位给同一枚喇叭。第四个(灵动岛展开
        // 头部 trackInfoArtwork)不在这里钉 —— 广告期间头部四项曲目字段一律不画
        // (`trackInfoShowsTrackFields`,上面已有断言),它是被那条覆盖的。
        expectEqual(view.contains("adBreakArtworkTile(side:"), true,
                    "广告态契约: 灵动岛歌词行末尾那枚封面在广告期间换成替代方块")
        expectEqual(view.contains("controller.isAdBreakNow\n                || (radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage) != nil"),
                    true, "广告态契约: 替代方块照样算「这一格占着位置」,别放行多余的布局动画(电台口白的台标也算)")
        let window = (try? String(contentsOfFile: ui.appendingPathComponent("LyricsWindowView.swift").path,
                                  encoding: .utf8)) ?? ""
        let panel = (try? String(contentsOfFile: ui.deletingLastPathComponent()
                                    .appendingPathComponent("MenuBar/MenuBarPanel.swift").path,
                                 encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false, "广告态契约: 读到 LyricsWindowView.swift")
        expectEqual(panel.isEmpty, false, "广告态契约: 读到 MenuBarPanel.swift")
        expectEqual(window.contains("if playback.isCurrentTrackAdBreak {") && window.contains("megaphone.fill"),
                    true, "广告态契约: 歌词窗口封面卡在广告期间换成同一枚喇叭")
        expectEqual(panel.contains("if playback.isCurrentTrackAdBreak {") && panel.contains("megaphone.fill"),
                    true, "广告态契约: 菜单栏面板那枚封面在广告期间换成同一枚喇叭")
        // 广告计数「· 1/2」。
        // 钉两件:它排在「广告中」和倒计时**之间**(三段连起来才是一句话),以及拿不到时整段不画。
        expectEqual(view.contains("adSlotText\n                    .font(playback.mainDetailFont)\n                adCountdown"), true,
                    "广告态契约: 计数排在「广告中」与倒计时之间")
        expectEqual(view.contains("if let slot = playback.currentAdSlot {"), true,
                    "广告态契约: 拿不到广告计数就整段不画,不编数字")
    }

    // ---- 音浪独占一只耳朵时的位置:非展开贴外缘,仅卡片顶在宽度下限(最小宽)时居中 ----
    //
    // 居中那组实测几何(截图逐列亮度):卡片 258 / 刘海 179 → earWidth = (258 − 179 − 20) / 2 = 29.5。
    // 音浪宽后来从 15 改到 16(条宽对齐整物理像素,见 EqualizerBars.barWidth),下面的
    // 推入量跟着从 2.25 变成 1.75 —— 公式没变,变的是代进去的那个宽度。
    // 那正是卡片顶在下限上的状态 —— 居中修的就是彼时 2.25pt 的偏心;宽度一放开,居中就成了
    // 「飘在中间」,一律贴外缘。
    do {
        typealias B = NotchWidthBounds
        // 这两个数住在 app target(NotchMetrics / EqualizerBars),selftest 够不着,所以这里
        // 抄一份**并在下面用源码契约钉住它们没被改** —— 只抄不钉的话,哪天常量动了这一组会
        // 悄悄变成在测一组不存在的几何。
        let barsWidth: CGFloat = 16      // EqualizerBars.width = 5×2.0 + 4×1.5
        let cardPadding: CGFloat = 10    // NotchMetrics.cardHorizontalPadding
        let earWidth: CGFloat = 29.5
        let shoulder = NotchOutline.shoulderRadius(notchHeight: 32)   // 卡片主体两侧各收的那一截,可视耳朵外沿跟着往里 4pt

        // 宽度下限(最小宽):保持居中,往里推 (earWidth − barsWidth − cardPadding + shoulder) / 2。
        let inset = B.soloEqualizerInset(
            earWidth: earWidth, barsWidth: barsWidth, cardPadding: cardPadding, shoulder: shoulder,
            expanded: false, atMinimumWidth: true)
        expectEqual(inset, 3.75, "音浪(最小宽): 实测那组几何要往里推 (29.5 − 16 − 10 + 4) / 2 = 3.75pt")
        expectEqual(B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth, cardPadding: cardPadding, shoulder: 0,
                                         expanded: false, atMinimumWidth: true), 1.75,
                    "音浪(最小宽): 不算肩膀会少推 2pt —— 音浪偏外(右耳即偏右)正是加肩膀后漏算的这一截")

        // 这条才是目的:推完之后音浪中心必须落在「刘海边沿 → 卡片外沿」正中。
        // 以耳朵容器左沿(= 刘海边沿)为原点。
        let leadingAfter = earWidth - barsWidth - inset
        let visibleCenter = (earWidth + cardPadding - shoulder) / 2
        expectEqual(leadingAfter + barsWidth / 2, visibleCenter,
                    "音浪(最小宽): 推完之后音浪中心 == 可视耳朵中心")

        // 反例哨兵:不能图省事把 alignment 换成 .center —— 那是居中于 earWidth,会偏**内**
        // cardPadding/2,比原来错得更多。这两条钉住"居中于容器"不是答案。
        let centerInContainer = (earWidth - barsWidth) / 2 + barsWidth / 2
        expectNotEqual(centerInContainer, visibleCenter,
                       "音浪(最小宽反例): 居中于 earWidth 不等于居中于可视耳朵")
        expectEqual(visibleCenter - centerInContainer, (cardPadding - shoulder) / 2,
                    "音浪(最小宽反例): 两者正好差 (cardHorizontalPadding − 肩膀) 的一半")

        // 窄耳朵兜底:装不下音浪 + 那半截边距时退回贴外缘,不许变成负 padding 把音浪推出卡片。
        expectEqual(B.soloEqualizerInset(earWidth: barsWidth + cardPadding - shoulder, barsWidth: barsWidth,
                                         cardPadding: cardPadding, shoulder: shoulder,
                                         expanded: false, atMinimumWidth: true), 0,
                    "音浪(最小宽): 刚好装下时不推")
        expectEqual(B.soloEqualizerInset(earWidth: 20, barsWidth: barsWidth,
                                         cardPadding: cardPadding, shoulder: shoulder,
                                         expanded: false, atMinimumWidth: true), 0,
                    "音浪(最小宽): 窄耳朵夹 0")

        // 比下限宽:一律贴外缘,不再居中 —— 同一组几何,顶不顶在下限给出不同答案。
        expectEqual(B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth,
                                         cardPadding: cardPadding, shoulder: shoulder,
                                         expanded: false, atMinimumWidth: false), 0,
                    "音浪(稳态): 不顶在下限就贴外缘 —— 居中只在最小宽那一档成立")
        expectEqual(B.soloEqualizerInset(earWidth: 60, barsWidth: barsWidth,
                                         cardPadding: cardPadding, shoulder: shoulder,
                                         expanded: false, atMinimumWidth: false), 0,
                    "音浪(稳态): 耳朵再宽也是贴外缘,不会越推越多")
        expectNotEqual(B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth,
                                            cardPadding: cardPadding, shoulder: shoulder,
                                            expanded: false, atMinimumWidth: true),
                       B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth,
                                            cardPadding: cardPadding, shoulder: shoulder,
                                            expanded: false, atMinimumWidth: false),
                       "音浪: 同一组几何,顶不顶在下限给出不同答案(判据是「卡片是否最小宽」这个定义性宽度)")

        // ---- hover 展开态贴外缘(「展开要在最边上」) ----
        //
        // 展开态耳朵宽出一大截(默认稳态 252 / 展开 482,单耳 26.5 → 141.5),居中就是
        // 飘在中间。稳态顶在下限的用户 hover 展开时 atMinimumWidth 仍为 true,展开这条
        // guard 排在最前,保证那种情形也贴外缘。
        let expandedEarWidth = (482 - 179 - 20) / 2.0        // 展开默认宽 482,实测刘海 179
        expectEqual(expandedEarWidth, 141.5, "音浪(展开): 展开态单耳 141.5pt")
        expectEqual(B.soloEqualizerInset(earWidth: expandedEarWidth, barsWidth: barsWidth,
                                         cardPadding: cardPadding, shoulder: shoulder,
                                         expanded: true, atMinimumWidth: false), 0,
                    "音浪(展开): 展开一律贴外缘")
        expectEqual(B.soloEqualizerInset(earWidth: expandedEarWidth, barsWidth: barsWidth,
                                         cardPadding: cardPadding, shoulder: shoulder,
                                         expanded: true, atMinimumWidth: true), 0,
                    "音浪(展开): 稳态顶在下限时 hover 展开,展开仍然贴外缘(guard 先看展开)")

        // 源码契约:上面抄的两个常量、以及"只在音浪独占时才推"这条边界。
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        let viewSrc = (try? String(contentsOf: ui.appendingPathComponent("NotchLyricsView.swift"),
                                   encoding: .utf8)) ?? ""
        let barsSrc = (try? String(contentsOf: ui.appendingPathComponent("EqualizerBars.swift"),
                                   encoding: .utf8)) ?? ""
        expectEqual(viewSrc.isEmpty, false, "音浪居中(契约): 读到 NotchLyricsView.swift")
        expectEqual(barsSrc.isEmpty, false, "音浪居中(契约): 读到 EqualizerBars.swift")
        expectEqual(viewSrc.contains("static let cardHorizontalPadding: CGFloat = 10"), true,
                    "音浪居中(契约): cardHorizontalPadding 仍是 10(上面抄的那份还成立)")
        expectEqual(barsSrc.contains("static let barCount = 5")
                    && barsSrc.contains("static let barWidth: CGFloat = 2.0")
                    && barsSrc.contains("static let spacing: CGFloat = 1.5"), true,
                    "音浪居中(契约): 音浪宽的三个因子仍是 5 / 2.0 / 1.5(合计 16),且条宽与间距都落在整物理像素上")
        expectEqual(viewSrc.contains("NotchWidthBounds.soloEqualizerInset("), true,
                    "音浪居中(契约): 顶行确实走 Core 里那个公式,没在视图里另写一份")
        expectEqual(viewSrc.contains("soloEqualizerLeft ? soloInset : 0")
                    && viewSrc.contains("soloEqualizerRight ? soloInset : 0"), true,
                    "音浪居中(契约): 两只耳朵都接上了,且只在音浪独占时才推")
        expectEqual(viewSrc.contains("&& leftModule == .none")
                    && viewSrc.contains("equalizerOnRight && rightModule == .none"), true,
                    "音浪居中(契约): 边界是「这只耳朵没有模块」——有模块时仍跟模块一起贴外缘")
        expectEqual(viewSrc.contains("shoulder: NotchOutline.shoulderRadius(notchHeight: controller.contentTopInset),"), true,
                    "音浪居中(契约): 顶行把卡片肩膀传进公式(漏传 = 最小宽时音浪偏外 2pt)")
        expectEqual(viewSrc.contains("atMinimumWidth: controller.isCardAtMinimumWidth"), true,
                    "音浪居中(契约): 「顶在下限」判据确实从 chrome 传进来了 —— 漏传等于最小宽那档也贴外缘")
        expectEqual(viewSrc.contains("expanded: controller.isExpanded"), true,
                    "音浪居中(契约): 展开态那一档确实接上了 —— 漏传等于展开时又飘回中间")
    }

    // ---- 时间类模块的秒表节拍:相位对齐曲目位置的整秒,不对齐墙钟 ----
    do {
        typealias C = NotchClockPhase
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let epoch = Date(timeIntervalSince1970: 0)
        // baseAgeMs: 0 = 锚点刚收到;外推只看 fetchedAt 之后走过的相对时间,测试不受本机时钟影响。
        func anchor(_ progressMs: Int, rate: Double = 1) -> ProgressAnchor {
            ProgressAnchor(durationMs: 600_000, progressMs: progressMs, rate: rate, progressTs: nil,
                           baseAgeMs: 0, fetchedAt: t0)
        }
        func secondAt(_ a: ProgressAnchor, _ date: Date) -> Int { a.extrapolatedPositionMs(now: date) / 1000 }

        let a = anchor(1234)
        let tick = C.tick(for: a, epoch: epoch)
        expectEqual(abs(tick.start.timeIntervalSince(t0) - 0.766) < 1e-6, true, "秒表节拍: 第一次跳秒 = 位置走到下一个整秒(1.234s → 2s,差 0.766s)")
        expectEqual(tick.interval, 1, "秒表节拍: 1 倍速每秒跳一次")
        expectEqual(secondAt(a, tick.start.addingTimeInterval(-0.002)), 1, "秒表节拍: 跳秒前一刻位置还在 1s")
        expectEqual(secondAt(a, tick.start.addingTimeInterval(0.002)), 2, "秒表节拍: 跳秒后一刻位置正好到 2s")
        expectEqual(secondAt(a, tick.start.addingTimeInterval(tick.interval + 0.002)), 3, "秒表节拍: 下一拍正好到 3s")

        let fast = anchor(1234, rate: 2)
        let fastTick = C.tick(for: fast, epoch: epoch)
        expectEqual(abs(fastTick.interval - 0.5) < 1e-12, true, "秒表节拍: 2 倍速半秒跳一次")
        expectEqual(secondAt(fast, fastTick.start.addingTimeInterval(-0.002)), 1, "秒表节拍: 2 倍速跳秒前一刻还在 1s")
        expectEqual(secondAt(fast, fastTick.start.addingTimeInterval(0.002)), 2, "秒表节拍: 2 倍速跳秒后一刻到 2s")

        let onBoundary = C.tick(for: anchor(3000), epoch: epoch)
        expectEqual(abs(onBoundary.start.timeIntervalSince(t0) - 1) < 1e-6, true, "秒表节拍: 正好在整秒上时下一拍排在 1s 之后")
        expectEqual(C.tick(for: anchor(1234, rate: 0), epoch: epoch), C.Tick(start: epoch, interval: 1),
                    "秒表节拍: 暂停(速率 0)钉在兜底起点上按 1 秒走")

        expectEqual(C.mmss(ms: 0), "0:00", "时间格式: 0")
        expectEqual(C.mmss(ms: 999), "0:00", "时间格式: 不足一秒向下取整")
        expectEqual(C.mmss(ms: 61_999), "1:01", "时间格式: 秒两位补零")
        expectEqual(C.mmss(ms: -5), "0:00", "时间格式: 负数按 0")
        expectEqual(C.mmss(ms: 3_600_000), "60:00", "时间格式: 超过一小时仍按分钟累计")
    }

    // ---- 主行显示哪一句:副行开着看当前句,关着看提前亮出的那句(灵动岛与菜单栏共用) ----
    do {
        let current = SyncedLyricLine(romanization: nil, translation: nil, mainText: "当前句", words: nil, wordGroups: nil, side: nil)
        let lead = SyncedLyricLine(romanization: nil, translation: nil, mainText: "提前亮出的下一句", words: nil, wordGroups: nil, side: nil)
        expectEqual(LyricSecondaryLine.off.displayedLine(compactLine: lead, currentLine: current), lead,
                    "主行取句: 副行关着 = 单行展示面提前亮出的那句")
        for kind in [LyricSecondaryLine.nextLine, .translation, .romanization] {
            expectEqual(kind.displayedLine(compactLine: lead, currentLine: current), current,
                        "主行取句: 副行开着(\(kind))= 当前句,不抢跑")
        }
        expectEqual(LyricSecondaryLine.nextLine.displayedLine(compactLine: lead, currentLine: nil), nil,
                    "主行取句: 副行开着、前奏里还没有当前句 = nil(显示间奏占位),不退回提前量那句")
        expectEqual(LyricSecondaryLine.off.displayedLine(compactLine: nil, currentLine: current), nil,
                    "主行取句: 副行关着、长间奏中段没有提前量 = nil,不退回当前句")

        // 够格的间奏里当前句当作没有:副行开着时主行画「•••」,副行的下一句照旧,译文跟着没有。
        let sung = SyncedLyricLine(romanization: nil, translation: "译文", mainText: "唱完的那句", words: nil, wordGroups: nil, side: nil)
        let masked = LyricSecondaryLine.currentLine(sung, inMarkedInterlude: true)
        expectEqual(masked, nil, "够格间奏: 当前句当作没有")
        expectEqual(LyricSecondaryLine.currentLine(sung, inMarkedInterlude: false), sung, "句间短空档: 当前句照旧")
        expectEqual(LyricSecondaryLine.nextLine.displayedLine(compactLine: nil, currentLine: masked), nil,
                    "够格间奏 + 副行下一句: 主行画「•••」")
        expectEqual(LyricSecondaryLine.nextLine.secondaryText(currentLine: masked, nextLineText: "下一句"), "下一句",
                    "够格间奏 + 副行下一句: 副行照旧显示下一句")
        expectEqual(LyricSecondaryLine.translation.secondaryText(currentLine: masked, nextLineText: "下一句"), nil,
                    "够格间奏 + 副行译文: 不挂唱完那句的译文")

        // 「•••」的窗口:只有单行面的占位才提前 reveal 走完。
        let raw = LyricsGapWindow(startMs: 15_200, endMs: 40_000)
        expectEqual(LyricSecondaryLine.off.gapDotsWindow(raw, compactPlaceholder: true),
                    LyricsGapWindow(startMs: 15_200, endMs: 40_000 - CompactLyricLead.revealMs),
                    "三点窗口: 单行面占位,下一句提前亮出那一刻走完")
        expectEqual(LyricSecondaryLine.off.gapDotsWindow(raw, compactPlaceholder: false), raw,
                    "三点窗口: 单行面前奏,画到第一句开始")
        for kind in [LyricSecondaryLine.nextLine, .translation, .romanization] {
            expectEqual(kind.gapDotsWindow(raw, compactPlaceholder: true), raw,
                        "三点窗口: 副行开着(\(kind)),画到下一句开始")
        }
    }

    // ---- 跳过广告门槛的短缓存 ----
    do {
        typealias G = YouTubeMusicAdSkipper.GateCache
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var cache = G()
        expectEqual(cache.lookup(host: "com.google.Chrome", now: t0), nil, "门槛缓存: 空缓存查不到")
        cache.store(.ready, host: "com.google.Chrome", now: t0)
        expectEqual(cache.lookup(host: "com.google.Chrome", now: t0.addingTimeInterval(G.ttl - 0.01)), .ready,
                    "门槛缓存: TTL 以内同一浏览器复用")
        expectEqual(cache.lookup(host: "com.google.Chrome", now: t0.addingTimeInterval(G.ttl)), nil,
                    "门槛缓存: 到 TTL 就失效")
        expectEqual(cache.lookup(host: "com.apple.Safari", now: t0), nil, "门槛缓存: 换了浏览器不复用")
        cache.invalidate()
        expectEqual(cache.lookup(host: "com.google.Chrome", now: t0), nil,
                    "门槛缓存: 插播换到下一条时清掉,上一条的「能跳」不延续")
        expectEqual(G.ttl < YouTubeMusicAdProbe.adRefreshInterval, true,
                    "门槛缓存: TTL 必须短于 5 秒心跳,否则心跳会读到上一拍的旧判定")
        expectEqual(G.ttl < YouTubeMusicAdSkipper.fastStartDelay * 2, true,
                    "门槛缓存: TTL 盖不住两拍快探,开头快探不会全被缓存吃掉")
    }

    // ---- 源码契约:停表 / 窗口可见性 / 跳过广告门槛 / 快捷操作 ----
    do {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        func read(_ name: String) -> String {
            (try? String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let view = read("NotchLyricsView.swift")
        let root = read("NotchWindowRoot.swift")
        let controller = read("NotchLyricsWindowController.swift")
        for (name, text) in [("NotchLyricsView", view), ("NotchWindowRoot", root),
                             ("NotchLyricsWindowController", controller)] {
            expectEqual(text.isEmpty, false, "灵动岛契约: 读到 \(name).swift")
        }

        // 悬停边沿跟控制器对账:窗口收走时控制器清了悬停、视图却还记着「在卡片上」,下一次移上去必须重新算作进入。
        expectEqual(root.contains("let stale = inside && hoveringCard && !controller.isCardHovered"), true,
                    "悬停契约: 视图的边沿记忆跟控制器对账")
        expectEqual(root.contains("let changed = inside != hoveringCard || stale"), true,
                    "悬停契约: 对不上时这一次算边沿")

        // 层内停表:NotchLyricsView 自己属性上的 @Environment 读到的是根上的值,拿不到 body 里
        // NotchCardLayerActive 设的层值(同构复现:属性上读 63 次/2 秒不停,子视图里读 0 次)。
        // 只看 NotchLyricsView 结构体本身:NotchScrubber 这类独立子视图在自己的属性上读是对的。
        let viewStruct: String = {
            guard let a = view.range(of: "struct NotchLyricsView<"),
                  let b = view.range(of: "private struct QuickActionHint", range: a.upperBound..<view.endIndex)
            else { return "" }
            return String(view[a.lowerBound..<b.lowerBound])
        }()
        expectEqual(viewStruct.isEmpty, false, "停表契约: 切得出 NotchLyricsView 结构体那一段")
        expectEqual(viewStruct.contains("private var cardLayerActive"), false,
                    "停表契约: NotchLyricsView 不许在自己的属性上按层读 notchCardLayerActive(那样藏着的那份永不停表)")
        expectEqual(view.components(separatedBy: "NotchLayerActiveReader {").count - 1 >= 2, true,
                    "停表契约: 主歌词行与广告倒计时都经 NotchLayerActiveReader 在层内读")
        expectEqual(view.contains("layerKaraokeLine(words: words, layerActive: layerActive)")
                    && view.contains("lyricContent(layerActive: layerActive)"), true,
                    "停表契约: 逐字歌词行与其余占位吃的是层内读到的值")
        expectEqual(view.contains("currentLineFillSettled || !layerActive,"), true,
                    "停表契约: 逐字歌词行按层内的值停表")
        expectEqual(view.contains("isVisible: layerActive"), true, "停表契约: 间奏三点按层内的值停表")
        expectEqual(view.contains(".transformEnvironment(\\.notchCardLayerActive) { $0 = $0 && active }"), true,
                    "停表契约: 层修饰器与外层取与,不覆盖(外层是窗口可见性)")
        expectEqual(view.contains(".environment(\\.notchCardLayerActive, active)"), false,
                    "停表契约: 层修饰器不许直接覆盖成本层的值(会把窗口不可见时的停表冲掉)")

        // 迷你进度条:时钟走 FrameTimeline,只包住已播段和两个时间数字,偏移按钮那组不在时钟里(05 章决策 62)。
        expectEqual(view.contains("TimelineView(.animation("), false,
                    "进度条契约: 灵动岛不用 TimelineView(.animation) —— 进程里有 SwiftUI ScrollView 时每拍要渲染两次")
        expectEqual(view.components(separatedBy: "FrameTimeline(minimumInterval: WordKaraokeGradient.refreshInterval, paused: !ticking)").count - 1, 3,
                    "进度条契约: 已播段和两个时间数字各一个时钟")
        expectEqual(view.contains("if showsLyricsOffsetControls {\n                    lyricsOffsetControls"), true,
                    "进度条契约: 偏移按钮直接排在时间行里,不在时钟闭包里")
        expectEqual(root.contains(".environment(\\.frameClock, frameClock)"), true, "进度条契约: 时钟挂在这扇灵动岛窗口上")

        // 窗口看不见时整卡停表:SwiftUI 不会因遮挡 / orderOut 自己停 TimelineView(.animation)。
        expectEqual(root.contains(".environment(\\.notchCardLayerActive, controller.isSurfaceVisible)"), true,
                    "可见性契约: 根上把窗口可见性注入成层值的根")
        expectEqual(controller.contains("NSWindow.didChangeOcclusionStateNotification, object: panel"), true,
                    "可见性契约: 每扇灵动岛窗口(含镜像副本)都监听自己的遮挡变化")
        expectEqual(controller.contains("@Published private(set) var isSurfaceVisible = true"), true,
                    "可见性契约: 初值按可见算(上屏前 occlusionState 也是不可见,不能先停表)")
        expectEqual(controller.components(separatedBy: "removeObserver(occlusionObserver)").count - 1, 2,
                    "可见性契约: deinit 与 teardown 两处都摘掉遮挡通知")
        expectEqual(controller.contains("let step = NotchVisibility.step(") && controller.contains("let stillShow = NotchVisibility.shouldShow("), true,
                    "显隐契约: 控制器按 Core 的 NotchVisibility 决定显示 / 隐藏,延迟隐藏到点的复核也走同一份")
        expectEqual(controller.contains("(!hideWhenNotPlaying || isPlayingNow || alertHold)")
                    || controller.contains("(!self.hideWhenNotPlaying || PlaybackCoordinator.shared.isPlayingSmoothed"), false,
                    "显隐契约: 控制器里不许再内联写一份「该不该显示」的判据")
        expectEqual(controller.components(separatedBy: "coveredByFullScreen: coveredByFullScreen)").count - 1
                    + controller.components(separatedBy: "coveredByFullScreen: self.coveredByFullScreen)").count - 1, 2,
                    "全屏契约: 立刻判定与延迟隐藏到点的复核都带上全屏条件")
        expectEqual(controller.contains("AppSettings.shared.$notchHideInFullScreen\n            .combineLatest(FullScreenSpaceMonitor.shared.$fullScreenDisplays)"), true,
                    "全屏契约: 每个实例(含镜像副本)自己订阅开关与全屏表,值从 sink 参数拿")
        expectEqual(controller.contains("let screen = resolvedScreen()\n        let covered = FullScreenSpaces.covers("), true,
                    "全屏契约: 按这扇窗自己所在的屏判,不看别的屏")
        expectEqual(controller.contains("let hide = NotchVisibility.fullScreenHides(enabled: enabled, coveredByFullScreenApp: covered)"), true,
                    "全屏契约: 全屏一律整卡隐藏,判据走 Core")
        expectEqual(controller.contains("safeAreaInsets.top ?? 0) > 0") || controller.contains("lyricsOffByFullScreen"), false,
                    "全屏契约: 不再按有没有刘海区别对待(刘海屏也整卡隐藏,不是只收歌词行)")
        expectEqual(controller.contains("fullScreenObserver?.cancel()"), true, "全屏契约: teardown 摘掉订阅")
        expectEqual(view.contains("isPlaying: playback.isPlayingNow && surfaceVisible"), true,
                    "可见性契约: 顶行音浪看不见时按暂停处理")
        expectEqual(view.contains("if let anchor = playback.anchor, surfaceVisible {"), true,
                    "可见性契约: 顶行时间模块看不见时不排表")

        // 跳过广告:没确认能跳不给键;nil 之后不收摊;换条重判;bundle id 每拍现读。
        let center = read("YouTubeMusicAdSkipCenter.swift")
        expectEqual(center.contains("guard let state, state != .notInAd else { return }"), false,
                    "跳过门槛契约: 脚本没跑成(nil)不许收摊(偶发超时会让整条广告再也探不到)")
        expectEqual(center.contains("if state == .notInAd { return }"), true, "跳过门槛契约: 只有广告结束才收摊")
        expectEqual(center.contains("let bundleID = await MainActor.run { LocalPlaybackSource.shared.lastResolvedBundleID }"), true,
                    "跳过门槛契约: 浏览器 bundle id 每一拍现读")
        expectEqual(center.contains("p.$title.removeDuplicates().sink"), true,
                    "跳过门槛契约: 插播里换到下一条广告(只有标题在变)时重新判")
        expectEqual(center.contains("guard gatedAdTitle != title else { return }"), true,
                    "跳过门槛契约: 同一条广告不重起轮询(开始那一拍两条订阅前后脚到)")
        expectEqual(center.contains("if nextAdInBreak { YouTubeMusicAdSkipper.invalidateGateCache() }"), true,
                    "跳过门槛契约: 换条时清掉上一条的缓存判定")
        expectEqual(center.contains("autoAttempts = 0\n        autoStopped = false"), true,
                    "自动跳过契约: 换到下一条广告时按键次数清零")

        // 快捷操作:Last.fm 那颗只在连着账号时出现,落点是设置 › Last.fm。
        expectEqual(view.contains("if LastfmStatsService.shared.isConnected {\n                    quickActionButton(\"chart.bar.fill\""), true,
                    "快捷操作契约: Last.fm 键只在连着账号时画")
        expectEqual(view.contains("AppActions.shared.requestSettings(.account(.lastfm))"), true,
                    "快捷操作契约: Last.fm 键翻到设置 › Last.fm 详情页")

        // 主行取句的规则只有 Core 一份。
        expectEqual(view.contains("secondary.displayedLine(compactLine: compact, currentLine: current)"), true,
                    "主行取句契约: 灵动岛调 Core 的 displayedLine")
        expectEqual(view.contains("showsSecondaryRow ? current : compact"), false,
                    "主行取句契约: 灵动岛不许再内联写一份取句规则")
        expectEqual(view.contains("Publishers.CombineLatest4(p.$notchLyrics.map(\\.compactLine), shownCurrentLine,"), true,
                    "间奏三点契约: 主行取句吃的是间奏里当作没有的当前句")
        expectEqual(view.contains("Publishers.CombineLatest3(shownCurrentLine, p.$notchLyrics.map(\\.nextText)"), true,
                    "间奏三点契约: 副行文本吃同一份当前句")
        expectEqual(view.contains("raw?.isMarked(in: markers) ?? false"), true,
                    "间奏三点契约: 只有够格的间奏才换成「•••」")
        expectEqual(view.contains("playback.secondaryLine.gapDotsWindow(raw, compactPlaceholder: playback.compactShowsPlaceholder)"), true,
                    "间奏三点契约: 三点窗口走 Core 的 gapDotsWindow")
        expectEqual(view.contains("NotchClockPhase.tick(for: anchor, epoch: clockEpoch)"), true,
                    "秒表契约: App 侧的 schedule 由 Core 的 NotchClockPhase 算")
    }

    // ---- 窗口显示 / 隐藏决策 ----
    do {
        typealias V = NotchVisibility
        // 该不该在屏上
        expectEqual(V.shouldShow(isVisible: false, hideWhenNotPlaying: false, isPlaying: true, alertHold: true, coveredByFullScreen: false), false,
                    "显隐: 灵动岛关着,什么都不显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: false, isPlaying: false, alertHold: false, coveredByFullScreen: false), true,
                    "显隐: 没开「暂停时隐藏」时暂停也显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: false, alertHold: false, coveredByFullScreen: false), false,
                    "显隐: 开了「暂停时隐藏」且没在播 = 藏")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: true, alertHold: false, coveredByFullScreen: false), true,
                    "显隐: 开了「暂停时隐藏」但在播 = 显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: false, alertHold: true, coveredByFullScreen: false), true,
                    "显隐: 「发现新播放器」提醒挂着时即使没在播也要显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: false, isPlaying: true, alertHold: false,
                                 coveredByFullScreen: true), false,
                    "显隐: 全屏 Space = 藏,在播也藏")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: false, alertHold: true,
                                 coveredByFullScreen: true), false,
                    "显隐: 全屏压过「发现新播放器」提醒")

        expectEqual(V.fullScreenHides(enabled: true, coveredByFullScreenApp: true), true,
                    "全屏处理: 全屏 Space 整卡隐藏,刘海屏也一样(不再只收歌词行)")
        expectEqual(V.fullScreenHides(enabled: false, coveredByFullScreenApp: true), false, "全屏处理: 开关关着不处理")
        expectEqual(V.fullScreenHides(enabled: true, coveredByFullScreenApp: false), false, "全屏处理: 不在全屏 Space 不处理")

        // 哪块屏的当前 Space 是全屏(CGSCopyManagedDisplaySpaces 的形状)
        typealias F = FullScreenSpaces
        func space(_ id: Int, full: Bool) -> [String: Any] {
            full ? ["ManagedSpaceID": id, "TileLayoutManager": ["TileSpaces": []]] : ["ManagedSpaceID": id]
        }
        func display(_ id: String, current: Int, _ spaces: [[String: Any]]) -> [String: Any] {
            ["Display Identifier": id, "Current Space": ["ManagedSpaceID": current], "Spaces": spaces]
        }
        let spaces = [space(1, full: false), space(1124, full: true), space(14, full: false)]
        expectEqual(F.fullScreenDisplays(in: [display("abcd-1", current: 1, spaces)]), [],
                    "全屏判定: 当前是普通桌面,别的 Space 里有全屏 App 不算")
        expectEqual(F.fullScreenDisplays(in: [display("abcd-1", current: 1124, spaces)]), ["ABCD-1"],
                    "全屏判定: 当前 Space 带 TileLayoutManager = 全屏,标识转大写")
        expectEqual(F.fullScreenDisplays(in: [display("A", current: 1124, spaces), display("B", current: 14, spaces)]), ["A"],
                    "全屏判定: 各屏各算,只收当前是全屏的那块")
        expectEqual(F.fullScreenDisplays(in: [["Display Identifier": "A"], display("B", current: 99, spaces)]), [],
                    "全屏判定: 字段缺失 / 当前 Space 不在列表里 = 不算全屏")
        expectEqual(F.covers(screenID: "a", isMainScreen: false, fullScreenDisplays: ["A"]), true,
                    "全屏判定: 屏幕 UUID 大小写不敏感")
        expectEqual(F.covers(screenID: "B", isMainScreen: true, fullScreenDisplays: ["A"]), false,
                    "全屏判定: 别的屏全屏,这块屏照常显示")
        expectEqual(F.covers(screenID: "B", isMainScreen: true, fullScreenDisplays: ["MAIN"]), true,
                    "全屏判定: 不分屏幕 Space 时的 Main 对应主屏")
        expectEqual(F.covers(screenID: "B", isMainScreen: false, fullScreenDisplays: ["MAIN"]), false,
                    "全屏判定: Main 只对应主屏")
        expectEqual(F.covers(screenID: nil, isMainScreen: false, fullScreenDisplays: ["A"]), false,
                    "全屏判定: 取不到屏幕标识 = 不隐藏")

        func step(_ show: Bool, visible: Bool = true, last: Bool?, vanished: Bool = false,
                  reduce: Bool = false, pending: Bool = false) -> V.Step {
            V.step(shouldShow: show, isVisible: visible, lastApplied: last, isVanished: vanished,
                   reduceMotion: reduce, hasPendingHide: pending)
        }
        // 显示
        expectEqual(step(true, last: nil), .show(orderFront: true, replayReveal: true), "显隐: 冷启动上屏 + 播出场动画")
        expectEqual(step(true, last: false), .show(orderFront: true, replayReveal: true), "显隐: 从藏着到显示 = 上屏 + 出场动画")
        expectEqual(step(true, last: true), .show(orderFront: false, replayReveal: false),
                    "显隐: 已经在屏上又进来一次 = 一次 WindowServer 事务都不发、不重播动画")
        expectEqual(step(true, last: true, vanished: true), .show(orderFront: false, replayReveal: true),
                    "显隐: 缩回动画中途又播放了 = 窗口还在屏上,只让卡片从刘海里重新撑开")
        // 隐藏
        expectEqual(step(false, last: false), .alreadyHidden, "显隐: 本来就藏着 = 只作废挂着的延迟隐藏")
        expectEqual(step(false, last: true), .startVanish, "显隐: 暂停时隐藏 = 先缩回刘海再 orderOut")
        expectEqual(step(false, last: true, pending: true), .keepPendingVanish, "显隐: 已经在等缩回动画 = 不重排")
        expectEqual(step(false, visible: false, last: true), .hideNow, "显隐: 用户关掉灵动岛 = 立刻隐藏,不做缩回动画")
        expectEqual(step(false, last: nil), .hideNow, "显隐: 窗口还没显示过 = 立刻隐藏")
        expectEqual(step(false, last: true, reduce: true), .hideNow, "显隐: 减弱动态效果 = 立刻隐藏")
        expectEqual(step(false, visible: false, last: true, pending: true), .hideNow,
                    "显隐: 等缩回动画期间用户关掉灵动岛 = 立刻隐藏,不等那条动画")
    }

    // ---- 源码契约:专辑简介的三个入口 ----
    do {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        func read(_ name: String) -> String {
            (try? String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let view = read("NotchLyricsView.swift"), stage = read("NotchEditorStage.swift")
        let controller = read("NotchLyricsWindowController.swift"), window = read("LyricsWindowView.swift")
        let store = read("EditorialNotes.swift")
        for (name, text) in [("NotchLyricsView", view), ("NotchEditorStage", stage), ("NotchLyricsWindowController", controller),
                             ("LyricsWindowView", window), ("EditorialNotes", store)] {
            expectEqual(text.isEmpty, false, "专辑简介契约: 读到 \(name).swift")
        }
        expectEqual(view.contains("if fields && controller.expandedTrackInfoShowsAlbum {\n                trackInfoAlbumLine"), true,
                    "专辑简介契约: 灵动岛只在开了「显示专辑」时画那一行")
        expectEqual(view.contains("tappable: !playback.album.isEmpty || !playback.youtubeMusicAlbum.isEmpty) { controller.toggleEditorial(.album) }"),
                    true,
                    "专辑简介契约: 灵动岛展开态点专辑名开 / 关浮框")
        expectEqual(view.contains("tappable: !playback.artist.isEmpty) { controller.toggleEditorial(.artist) }"), true,
                    "歌手简介契约: 灵动岛展开态点歌手名开 / 关浮框")
        expectEqual(view.contains("let clickable = tappable && !text.isEmpty && store.card(kind) != nil"), true,
                    "简介契约: 灵动岛的歌手名 / 专辑名只在这首有对应简介时可点")
        expectEqual(controller.contains("let expanded = cardHovered || editorialHovered"), true,
                    "简介契约: 指针停在浮框上时卡片不收")
        expectEqual(controller.contains("NotchEditorialPanel.shared.close(ifOwner: window)"), true,
                    "简介契约: 卡片收起就关浮框,不单独留在屏幕上")
        let panelSrc = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI/NotchEditorialPanel.swift"), encoding: .utf8)) ?? ""
        expectEqual(panelSrc.contains("guard event.window !== self.panel else { return }"), true,
                    "简介契约: 点灵动岛任何地方都关浮框,只有点浮框自己不关")
        expectEqual(panelSrc.contains("if closed.kind == card.kind, Date().timeIntervalSince(closed.at) < Self.clickWindow { return }"), true,
                    "简介契约: 再点同一个专辑名 / 歌手名 = 关(按下已经关掉,松手不重开)")
        expectEqual(panelSrc.contains("if event.timestamp != eventTime { MainActor.assumeIsolated { self?.forgetOwnerClick() } }"), true,
                    "简介契约: 那笔记录只对这一下点击有效(先点空白、再点专辑名要能重新打开)")
        expectEqual(controller.contains("map { visible, album, artist in visible && (album || artist) }"), true,
                    "简介契约: 灵动岛开着、头部画歌手名或专辑名时才登记预取")
        expectEqual(stage.contains("func toggleEditorial(_ kind: EditorialCard.Kind) {}"), true,
                    "专辑简介契约: 编辑台预览里是空实现,不从预览弹真浮框")
        expectEqual(controller.contains("NotchEditorialPanel.shared.toggle(card: card, cardFrame: frame, owner: window)"), true,
                    "专辑简介契约: 真窗口按卡片在屏幕上的位置打开浮框")
        expectEqual(window.contains("if editorial.album != nil {\n                MoreMenuRow(title: L10n.t(\"显示专辑简介\"))"), true,
                    "专辑简介契约: 歌词窗口「⋯」菜单只在这首有专辑简介时出现「显示专辑简介」")
        expectEqual(window.contains("if editorial.artist != nil {\n                MoreMenuRow(title: L10n.t(\"显示歌手简介\"))"), true,
                    "歌手简介契约: 歌词窗口「⋯」菜单只在这首有歌手简介时出现「显示歌手简介」")
        expectEqual(window.contains(".onTapGesture { if available { action() } }")
                    && window.contains("EditorialLinkText(text: text, available: editorial.card(kind) != nil,"), true,
                    "简介契约: 歌词窗口「歌手 — 专辑」两段各自只在有对应简介时接点击")
        expectEqual(window.components(separatedBy: "EditorialLinkText(text:").count - 1, 2,
                    "简介契约: 完整布局「歌手 — 专辑」与迷你顶部都用同一个可点文字组件(悬停手形光标 + 下划线)")
        expectEqual(window.contains("NSCursor.pointingHand.push()") && window.contains("NSCursor.pop()")
                    && window.contains(".onDisappear {\n                if cursorPushed {"), true,
                    "简介契约: 手形光标成对 push / pop,视图消失时也还回去")
        expectEqual(window.contains("miniHeaderPart(lines[i][j], color: color)")
                    && window.contains(".popover(isPresented: Binding(get: { miniEditorialKind != nil },"), true,
                    "简介契约: 迷你尺寸顶部的歌手 / 专辑也能点开简介")
        expectEqual(window.contains("editorialSegment(playback.displayArtist, kind: .artist)")
                    && window.contains("editorialSegment(playback.displayAlbum, kind: .album)"), true,
                    "简介契约: 歌词窗口点歌手看歌手简介、点专辑看专辑简介")
        expectEqual(window.contains(".onAppear { if !previewMode { EditorialNotesStore.shared.retain() } }")
                    && window.contains(".onDisappear { if !previewMode { EditorialNotesStore.shared.release() } }"), true,
                    "专辑简介契约: 歌词窗口开着才预取,设置页预览不算")
        expectEqual(store.components(separatedBy: "AlbumEditorialNotes.fetchAlbumPage(").count - 1, 1,
                    "简介契约: 专辑页只有一处发请求")
        expectEqual(store.contains("album = nil\n            fallbackAlbum(track)\n            resolveArtistFromSiblings(track)"), true,
                    "歌手简介契约: 这首没有 Apple 链接时,专辑退 Last.fm、歌手从同歌手的别的专辑页找")
        expectEqual(store.contains("Timer") || store.contains("Task.sleep"), false,
                    "专辑简介契约: 只在换歌 / 消费方来要时取,不轮询")
        expectEqual(store.contains("guard demand > 0, !track.title.isEmpty else {"), true,
                    "专辑简介契约: 没有消费方挂着时一个请求都不发")
        expectEqual(store.components(separatedBy: "guard self.currentKey == track.key else { return self.refreshCurrent() }").count - 1, 4,
                    "简介契约: 专辑页 / 同歌手专辑页 / 歌手页 / Last.fm 回来时已经换歌,都按当前曲目重查(同专辑连切时新歌不会整首拿不到)")
        expectEqual(store.contains("guard self.currentKey == track.key else { return self.refreshCurrent() }\n            self.artist = card"), true,
                    "简介契约: 歌手页回来时已经换歌,同样按当前曲目重查")
        expectEqual(store.contains("appleAlbumRefs(forArtist: track.artist, limit: 3)")
                    && store.contains("return self.trySiblings(refs.dropFirst(), name: name, track: track)"), true,
                    "简介契约: 同歌手的别的专辑最多试 3 张,对不上换下一张")
        expectEqual(store.contains("case .failed:\n                return\n            }\n            self.albumPages[ref.id] = .some(fetched)"), true,
                    "简介契约: 失败不记(下次再试),取到和都 404 都记")
    }

    // ---- 藏着的那一层歌词行不重画(源码契约) ----
    // 灵动岛的稳态 / 展开两份歌词行常驻、靠透明度轮流显示;藏着的那份换句时不该照样重画位图、重装动画。
    do {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        let row = (try? String(contentsOf: ui.appendingPathComponent("OverlayScrollingLyricRow.swift"),
                               encoding: .utf8)) ?? ""
        expectEqual(row.contains("@Environment(\\.notchCardLayerActive) private var layerActive"), true,
                    "隐藏层契约: 共用歌词行把「这一层显示着没有」当输入读(翻回 true 才会重新 updateNSView)")
        expectEqual(row.contains("guard layerActive else { return }\n        view.apply(spec: spec, nowMs: nowMs())"), true,
                    "隐藏层契约: 藏着时不调 apply(不重画位图、不装动画)")
    }

    // ---- 自画图标:灵动岛、触控栏两枚(系统符号里没有,`SurfaceGlyph`) ----
    //
    // 灵动岛那一格、设置页开关卡、右键菜单那一项都从 SurfaceGlyph 取名字;按名字画图标的几处(面板格子、快捷设置
    // 头部、两种设置行、菜单项)都先认自画的名字。哪一处还拿 Image(systemName:) 画,那一枚就是空白,不报错。
    do {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: appDir.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        let glyph = read("UI/SurfaceGlyph.swift")
        let quick = read("MenuBar/MenuBarPanelQuickSettings.swift")
        let panel = read("MenuBar/MenuBarPanel.swift")
        let menu = read("MenuBar/MenuBarStatusMenu.swift")
        let settingsView = read("SettingsView.swift")
        let design = read("Settings/SettingsDesignSystem.swift")
        expectEqual(glyph.contains("case notch = \"lyrimuse.notch\"")
                        && glyph.contains("case touchBar = \"lyrimuse.touchbar\""), true,
                    "自画图标: 灵动岛、触控栏两枚在 SurfaceGlyph 里")
        // SwiftUI 里用它自己的形状拼:把菜单用的那张模板图塞进 Image(nsImage:),着色比旁边的系统符号暗一截。
        // 判的是调用(冒号后带参数),写理由的注释里也出现这个名字。
        expectEqual(glyph.contains("SurfaceGlyphView(glyph: glyph, size: size, weight: weight)")
                        && !glyph.contains("Image(nsImage: "), true,
                    "自画图标: SwiftUI 里按共用几何拼形状,不用模板图")
        // 实心的药丸、长条画成圆头粗线描边:磨砂底上 SwiftUI 的实心填充比描边、系统符号浅一截。
        expectEqual(glyph.contains("RoundBar(rect: layout.island)") && glyph.contains("RoundBar(rect: layout.bar)")
                        && !glyph.contains(" Capsule()\n"), true,
                    "自画图标: 药丸、长条用描边画,不用 Capsule 填充")
        expectEqual(quick.contains("case .notch: return SurfaceGlyph.notch.rawValue")
                        && settingsView.contains("icon: SurfaceGlyph.notch.rawValue")
                        && menu.contains("symbol: SurfaceGlyph.notch.rawValue"), true,
                    "自画图标: 灵动岛那一格、设置页开关卡、右键菜单那一项都用自画的灵动岛图标")
        expectEqual(panel.contains("SymbolImage(name: symbol, size: 16, weight: .semibold)")
                        && quick.contains("SymbolImage(name: target.symbolName, size: 12, weight: .semibold)")
                        && menu.contains("item.image = NSImage.symbol(named: symbol, pointSize: 14, weight: .regular)"), true,
                    "自画图标: 面板格子、快捷设置头部、菜单项都按名字认自画图标")
        expectEqual(design.components(separatedBy: "SymbolImage(name: icon, size: 13)").count - 1, 2,
                    "自画图标: SettingsRow、SettingsRawRow 两种设置行都按名字认自画图标")
        expectEqual(design.contains("Image(systemName: icon)") || quick.contains("Image(systemName: target.symbolName)")
                        || menu.contains("NSImage(systemSymbolName: symbol"), false,
                    "自画图标: 设置行、快捷设置头部、菜单项不再直接拿符号名画系统符号")
    }
}
