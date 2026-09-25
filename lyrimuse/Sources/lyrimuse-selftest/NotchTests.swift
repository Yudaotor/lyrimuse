import LyrimuseCore
import Foundation

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
        expectEqual(view.isEmpty, false, "广告态契约: 读到 NotchLyricsView.swift")
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
        expectEqual(view.contains("YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)"), true,
                    "广告态契约: 门槛走 Core 那份只读探测,不在 View 里另拼一套")
        // 门槛轮询**必须**挂 chrome 的 isAdBreakNow(预览恒 false),不准挂回 playback 那条订阅 ——
        // 挂回去的后果是设置页开着时,编辑台预览跟着真广告每 5 秒对用户的浏览器发一次 AppleScript
        // (真机日志坐实:每行打两遍)。这跟"预览不产生副作用"是同一条纪律。
        expectEqual(view.contains(".onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: on) }"), true,
                    "广告态契约: 门槛轮询由 chrome 的 isAdBreakNow 驱动(广告开始起、结束停)")
        expectEqual(view.contains("self?.syncAdSkipGate"), false,
                    "广告态契约: 门槛轮询不准挂回 $isCurrentTrackAdBreak 订阅(预览会跟着对浏览器发 AppleScript)")
        expectEqual(view.contains(".onAppear { playback.syncAdSkipGate(adBreak: controller.isAdBreakNow) }"), true,
                    "广告态契约: 窗口出现时已经在放广告也要起轮询(onChange 只认变化)")

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
        expectEqual(view.contains("guard !skipAdInFlight else { return }"), true, "广告态契约: 跳过广告同一时刻只跑一份")
        expectEqual(view.contains("case .needsAccessibility?:") && view.contains("AccessibilitySkipPress.promptForTrust()"), true,
                    "广告态契约: 没有辅助功能权限时弹系统授权对话框")
        expectEqual(view.contains("case .tabNotFrontmost?:"), true, "广告态契约: 标签页不在前面有专门的提示")
        expectEqual(view.contains(".disabled(playback.skipAdInFlight)"), true, "广告态契约: 跑着的时候键不接第二下")
        expectEqual(stage.contains("var isAdBreakNow: Bool { false }"), true, "广告态契约: 预览 chrome 的 isAdBreakNow 恒 false")
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
        expectEqual(view.contains("controller.isAdBreakNow || (playback.highResArtworkImage ?? playback.artworkImage) != nil"),
                    true, "广告态契约: 替代方块照样算「这一格占着位置」,别放行多余的布局动画")
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

        // 宽度下限(最小宽):保持居中,往里推 (earWidth − barsWidth − cardPadding) / 2 = 2.25pt。
        let inset = B.soloEqualizerInset(
            earWidth: earWidth, barsWidth: barsWidth, cardPadding: cardPadding,
            expanded: false, atMinimumWidth: true)
        expectEqual(inset, 1.75, "音浪(最小宽): 实测那组几何要往里推 (29.5 − 16 − 10) / 2 = 1.75pt")

        // 这条才是目的:推完之后音浪中心必须落在「刘海边沿 → 卡片外沿」正中。
        // 以耳朵容器左沿(= 刘海边沿)为原点。
        let leadingAfter = earWidth - barsWidth - inset
        let visibleCenter = (earWidth + cardPadding) / 2
        expectEqual(leadingAfter + barsWidth / 2, visibleCenter,
                    "音浪(最小宽): 推完之后音浪中心 == 可视耳朵中心")

        // 反例哨兵:不能图省事把 alignment 换成 .center —— 那是居中于 earWidth,会偏**内**
        // cardPadding/2,比原来错得更多。这两条钉住"居中于容器"不是答案。
        let centerInContainer = (earWidth - barsWidth) / 2 + barsWidth / 2
        expectNotEqual(centerInContainer, visibleCenter,
                       "音浪(最小宽反例): 居中于 earWidth 不等于居中于可视耳朵")
        expectEqual(visibleCenter - centerInContainer, cardPadding / 2,
                    "音浪(最小宽反例): 两者正好差半个 cardHorizontalPadding")

        // 窄耳朵兜底:装不下音浪 + 那半截边距时退回贴外缘,不许变成负 padding 把音浪推出卡片。
        expectEqual(B.soloEqualizerInset(earWidth: barsWidth + cardPadding, barsWidth: barsWidth,
                                         cardPadding: cardPadding,
                                         expanded: false, atMinimumWidth: true), 0,
                    "音浪(最小宽): 刚好装下时不推")
        expectEqual(B.soloEqualizerInset(earWidth: 20, barsWidth: barsWidth,
                                         cardPadding: cardPadding,
                                         expanded: false, atMinimumWidth: true), 0,
                    "音浪(最小宽): 窄耳朵夹 0")

        // 比下限宽:一律贴外缘,不再居中 —— 同一组几何,顶不顶在下限给出不同答案。
        expectEqual(B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth,
                                         cardPadding: cardPadding,
                                         expanded: false, atMinimumWidth: false), 0,
                    "音浪(稳态): 不顶在下限就贴外缘 —— 居中只在最小宽那一档成立")
        expectEqual(B.soloEqualizerInset(earWidth: 60, barsWidth: barsWidth,
                                         cardPadding: cardPadding,
                                         expanded: false, atMinimumWidth: false), 0,
                    "音浪(稳态): 耳朵再宽也是贴外缘,不会越推越多")
        expectNotEqual(B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth,
                                            cardPadding: cardPadding,
                                            expanded: false, atMinimumWidth: true),
                       B.soloEqualizerInset(earWidth: earWidth, barsWidth: barsWidth,
                                            cardPadding: cardPadding,
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
                                         cardPadding: cardPadding,
                                         expanded: true, atMinimumWidth: false), 0,
                    "音浪(展开): 展开一律贴外缘")
        expectEqual(B.soloEqualizerInset(earWidth: expandedEarWidth, barsWidth: barsWidth,
                                         cardPadding: cardPadding,
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
                           baseAgeMs: 0, fetchedAt: t0, fresh: true)
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
        expectEqual(view.contains("isPlaying: playback.isPlayingNow && surfaceVisible"), true,
                    "可见性契约: 顶行音浪看不见时按暂停处理")
        expectEqual(view.contains("if let anchor = playback.anchor, surfaceVisible {"), true,
                    "可见性契约: 顶行时间模块看不见时不排表")

        // 跳过广告:没确认能跳不给键;nil 之后不收摊;换条重判;bundle id 每拍现读。
        expectEqual(view.contains("guard let state, state != .notInAd else { return }"), false,
                    "跳过门槛契约: 脚本没跑成(nil)不许收摊(偶发超时会让整条广告再也探不到)")
        expectEqual(view.contains("if state == .notInAd { return }"), true, "跳过门槛契约: 只有广告结束才收摊")
        expectEqual(view.contains("let bundleID = await MainActor.run { LocalPlaybackSource.shared.lastResolvedBundleID }"), true,
                    "跳过门槛契约: 浏览器 bundle id 每一拍现读")
        expectEqual(view.contains(".onChange(of: playback.title) { _, _ in\n            if controller.isAdBreakNow { playback.syncAdSkipGate(adBreak: true) }"), true,
                    "跳过门槛契约: 插播里换到下一条广告(只有标题在变)时重新判")
        expectEqual(view.contains("guard gatedAdTitle != title else { return }"), true,
                    "跳过门槛契约: 同一条广告不重起轮询(开始那一拍两条 onChange 前后脚到)")
        expectEqual(view.contains("if nextAdInBreak { YouTubeMusicAdSkipper.invalidateGateCache() }"), true,
                    "跳过门槛契约: 换条时清掉上一条的缓存判定")

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
        expectEqual(view.contains("NotchClockPhase.tick(for: anchor, epoch: clockEpoch)"), true,
                    "秒表契约: App 侧的 schedule 由 Core 的 NotchClockPhase 算")
    }

    // ---- 窗口显示 / 隐藏决策 ----
    do {
        typealias V = NotchVisibility
        // 该不该在屏上
        expectEqual(V.shouldShow(isVisible: false, hideWhenNotPlaying: false, isPlaying: true, alertHold: true), false,
                    "显隐: 灵动岛关着,什么都不显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: false, isPlaying: false, alertHold: false), true,
                    "显隐: 没开「暂停时隐藏」时暂停也显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: false, alertHold: false), false,
                    "显隐: 开了「暂停时隐藏」且没在播 = 藏")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: true, alertHold: false), true,
                    "显隐: 开了「暂停时隐藏」但在播 = 显示")
        expectEqual(V.shouldShow(isVisible: true, hideWhenNotPlaying: true, isPlaying: false, alertHold: true), true,
                    "显隐: 「发现新播放器」提醒挂着时即使没在播也要显示")

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
        expectEqual(view.contains("tappable: !playback.album.isEmpty) { controller.toggleEditorial(.album) }"), true,
                    "专辑简介契约: 灵动岛展开态点专辑名开 / 关浮框")
        expectEqual(view.contains("tappable: !playback.artist.isEmpty) { controller.toggleEditorial(.artist) }"), true,
                    "歌手简介契约: 灵动岛展开态点歌手名开 / 关浮框")
        expectEqual(view.contains("let clickable = tappable && !text.isEmpty && store.card(kind) != nil"), true,
                    "简介契约: 灵动岛的歌手名 / 专辑名只在这首有对应简介时可点")
        expectEqual(controller.contains("let expanded = cardHovered || editorialHovered"), true,
                    "简介契约: 指针停在浮框上时卡片不收")
        expectEqual(controller.contains("NotchEditorialPanel.shared.close(ifOwner: window)"), true,
                    "简介契约: 卡片收起就关浮框,不单独留在屏幕上")
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
                    && window.contains("editorialSegment(playback.album, kind: .album)"), true,
                    "简介契约: 歌词窗口点歌手看歌手简介、点专辑看专辑简介")
        expectEqual(window.contains(".onAppear { if !previewMode { EditorialNotesStore.shared.retain() } }")
                    && window.contains(".onDisappear { if !previewMode { EditorialNotesStore.shared.release() } }"), true,
                    "专辑简介契约: 歌词窗口开着才预取,设置页预览不算")
        expectEqual(store.components(separatedBy: "AlbumEditorialNotes.fetchAlbumPage(").count - 1, 1,
                    "简介契约: 专辑页只有一处发请求")
        expectEqual(store.contains("album = nil\n            resolveArtistFromSiblings(track)"), true,
                    "歌手简介契约: 这首没有 Apple 链接时,从同歌手的别的专辑页找歌手")
        expectEqual(store.contains("Timer") || store.contains("Task.sleep"), false,
                    "专辑简介契约: 只在换歌 / 消费方来要时取,不轮询")
        expectEqual(store.contains("guard demand > 0, !track.title.isEmpty else {"), true,
                    "专辑简介契约: 没有消费方挂着时一个请求都不发")
    }
}
