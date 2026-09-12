import LyrimuseCore
import Foundation

// 灵动岛:展开区 / 对齐接线 / 音浪包络 / 出场几何 / 稳态宽-展开宽不变量。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runNotchTests() {
    // ---- 灵动岛展开区高度:按里面真正会渲染的东西算(2026-08-21) ----
    //
    // 用户报「没有歌词的时候这块太大、很多空的地方」:展开区原来恒高 76 且 alignment .top,
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

    // ---- 展开区「曲目信息头部」+「下一句预览」用户开关(2026-09-01) ----
    //
    // 两个新维度跟上面 hasLyricPreview/hasScrubber 那两个曲目级数据信号性质不同:是用户
    // 设置,设置一变会触发 NotchLyricsWindowController 重算几何(见该文件的六条订阅),
    // 所以 maxHeight 不必再像 hasScrubber 那样按"最坏情况"钉死——这组断言守的正是这条
    // 不对称:hasLyricPreviewPossible 能让 maxHeight 真的变小,trackInfoHeight 能让它真的变大。
    do {
        typealias M = NotchExpandedMetrics

        // trackInfoHeight 本身:0 = 四个开关全关,不占地方(⚠️ 封面 2026-09-01 并回歌词行过
        // 一轮、后来又被要求重新加回头部自己一枚——现在**参与**这个函数的算术,固定贴文字块
        // 左边,不是"并排/堆叠"两选一那种复杂度,见 trackInfoHeight 的⚠️)
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

        // 快捷操作(2026-09-07):头部右侧那排按钮是并排的第三块,同样取 max 不取和。
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
        // ⚠️ 两份间距(2026-09-01 第二轮,用户报"标题首行贴到上面边"):一份贴头部上边(离
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

    // ---- 展开区「播放控制键」用户开关(2026-09-01) ----
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

    // ---- 没有曲目时的空闲面板(2026-09-07,05 章决策 #31)----
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

    // MARK: - VocalEnvelope:灵动岛音浪的人声包络(2026-09-02,起音脉冲 + 换气泄放)
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

    // ---- EqualizerBarCurve:音浪柱高的 smoothstep 对比曲线(2026-09-03,借鉴清单 #22 取舍后的版本) ----
    do {
        let c = EqualizerBarCurve.contrast
        expectEqual(c(0), 0, "音浪曲线: 端点 0 不动(地板那条线永远在)")
        expectEqual(c(1), 1, "音浪曲线: 端点 1 不动(仍能顶到上限)")
        expectEqual(c(0.5), 0.5, "音浪曲线: 中点不动 —— 均值高度不变,不会重演「幅度太小」")
        expectEqual(c(0.25) < 0.25, true, "音浪曲线: 小幅晃动被压低")
        expectEqual(c(0.75) > 0.75, true, "音浪曲线: 大幅被拉伸")
        expectEqual(abs(c(0.25) + c(0.75) - 1) < 1e-12, true, "音浪曲线: 关于 0.5 对称,压低多少就拉高多少")
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map(c)
        expectEqual(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, true, "音浪曲线: 单调递增,不会出现「形状值升高柱子反而变矮」")
        expectEqual(c(-0.3), 0, "音浪曲线: 越界输入夹回 0")
        expectEqual(c(1.7), 1, "音浪曲线: 越界输入夹回 1")
        expectEqual(EqualizerBarCurve.level(unit: 0.5, amplitude: 0.6), 0.3, "音浪曲线: 换气地板 0.6 按比例压低")
        expectEqual(EqualizerBarCurve.level(unit: 0.9, amplitude: 1.25), 1, "音浪曲线: 起音脉冲 1.25 乘完再夹,能顶到上限")
        expectEqual(EqualizerBarCurve.level(unit: 0.9, amplitude: 0), 0, "音浪曲线: 振幅 0 → 只剩地板")
    }

    // ---- NotchReveal:出场「从刘海撑开」的起始几何与时序(2026-09-03) ----
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

    // ---- NotchWidthBounds / NotchWidthRangeDrag:稳态宽 / 展开宽这一对的不变量(2026-09-06) ----
    //
    // 用户:「配置宽度的时候可以设置一个上限和一个下限,下限就是正常状态的宽度,上限就是悬浮展开
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

    // ---- 歌词行「副行」四选一(2026-09-06,用户拍板方案二)----
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

        // 「字体」组(2026-09-09):主行字号可调、行高仍是 44。范围上限必须让两行 + 间距仍塞进去且上下各留 ≥ 4pt ——
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

    // ---- 灵动岛 hover 命中判定(2026-09-07)----
    //
    // 用户报「鼠标只是移到灵动岛下面就展开了」。真机探针实测:`.contentShape(Rectangle())`
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

    // ---- 广告态:「跳过广告」+ 头部让位(2026-09-08)----
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

        // 「不可跳过的广告不画那颗键」(2026-09-11,用户:「如果当前广告不支持跳过的话就不要显示那个
        // 跳过的按钮」)。门槛脚本的三种返回 → 该不该画,是纯映射,钉在这里。
        expectEqual(S.skippability(from: .skippable(desc: "BUTTON.ytp-ad-skip-button-modern", badge: "赞助商广告 1/2 ·", videoTime: 6)),
                    .ready, "跳过键门槛: 键有尺寸 = 现在就能跳")
        expectEqual(S.skippability(from: .notYet(seconds: 5)), .after(seconds: 5), "跳过键门槛: 读到倒计时 = 可跳,还没到点")
        // ⚠️ 这一条是这次改动的**核心判据**:页面那句「N 秒后可跳过」是可跳过广告独有的,
        // 读不到不是"读失败"、是"这条广告没有跳过这回事"。
        expectEqual(S.skippability(from: .notYet(seconds: nil)), .never, "跳过键门槛: 没键也没倒计时 = 这条广告不给跳")
        expectEqual(S.skippability(from: .notFound), .notInAd, "跳过键门槛: 没有标签页在放广告")

        expectEqual(S.showsSkipButton(.ready), true, "画不画: 能跳才画")
        expectEqual(S.showsSkipButton(.after(seconds: 3)), false, "画不画: 倒计时期间不画(按了也只会得到一句「还不能跳过」)")
        expectEqual(S.showsSkipButton(.never), false, "画不画: 不可跳过的广告不画 —— 这次改动要的就是这一条")
        expectEqual(S.showsSkipButton(.notInAd), false, "画不画: 广告已经结束就不画")
        // fail-**open**:脚本没跑成的原因(不是浏览器 / 没授权 / 超时)用户看不见,藏了键等于功能凭空消失,
        // 画出来按下去至少能拿到一句可诊断的「没能跳过这条广告」。跟本文件其它 fail-closed 的地方相反,故意的。
        expectEqual(S.showsSkipButton(nil), true, "画不画: 门槛脚本没跑成时照画(fail-open,留一条可诊断的路)")

        expectEqual(S.gateRetryDelay(after: .after(seconds: 5)), 5.4, "门槛节奏: 倒计时那一档等到点再问(多给 0.4s 渲染)")
        expectEqual(S.gateRetryDelay(after: .after(seconds: 0)), 1.4, "门槛节奏: 秒数为 0 也至少等 1s,不打转")
        expectEqual(S.gateRetryDelay(after: .after(seconds: 999)), 20.4, "门槛节奏: 离谱秒数被 20s 封顶")
        expectEqual(S.gateRetryDelay(after: .ready), YouTubeMusicAdProbe.adRefreshInterval, "门槛节奏: 已经能跳也继续心跳(一次插播可能连放两条)")
        expectEqual(S.gateRetryDelay(after: .never), YouTubeMusicAdProbe.adRefreshInterval,
                    "门槛节奏: 问出「不给跳」也继续心跳 —— 下一条可能就给跳")
        // 广告开头那几拍的 `never` 是"页面还没渲染出来",不是"这条不给跳"(2026-09-11 真机时间线:
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
        expectEqual(view.contains("hasTrack && !isAdBreakNow"), true, "广告态契约: 头部显隐判据含 !isAdBreakNow")
        expectEqual(view.contains("if playback.isCurrentTrackAdBreak {\n                    adStatusColumn"), true,
                    "广告态契约: 歌词行在 lyricRowContent 这一层分流到 adStatusColumn")
        expectEqual(view.contains("showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak"),
                    true, "广告态契约: 广告期间不画歌词校准控件")
        expectEqual(view.contains("YouTubeMusicAdSkipper.isYouTubeMusicAd(artist: artist, title: title)"), true,
                    "广告态契约: canSkipAd 读的是 YT Music 探针的强信号判定")
        expectEqual(view.contains("&& adSkipAvailable"), true,
                    "广告态契约: canSkipAd 还要过「页面此刻真的放出跳过键了」这道门槛(2026-09-11)")
        // ⚠️ 必须是 @Published。倒计时过完、键刚放出来的那一刻,广告态这一格没有任何别的东西在变
        // (「还剩 0:21」那截自己排了一张 TimelineView、只重画它自己),做成计算属性就永远不会被重估。
        expectEqual(view.contains("@Published private(set) var adSkipAvailable"), true,
                    "广告态契约: adSkipAvailable 是 @Published(计算属性不会在键放出来那一刻被重估)")
        expectEqual(view.contains("YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)"), true,
                    "广告态契约: 门槛走 Core 那份只读探测,不在 View 里另拼一套")
        // ⚠️ 门槛轮询**必须**挂 chrome 的 isAdBreakNow(预览恒 false),不准挂回 playback 那条订阅 ——
        // 挂回去的后果是设置页开着时,编辑台预览跟着真广告每 5 秒对用户的浏览器发一次 AppleScript
        // (2026-09-11 真机日志坐实:每行打两遍)。这跟"预览不产生副作用"是同一条纪律。
        expectEqual(view.contains(".onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: on) }"), true,
                    "广告态契约: 门槛轮询由 chrome 的 isAdBreakNow 驱动(广告开始起、结束停)")
        expectEqual(view.contains("self?.syncAdSkipGate"), false,
                    "广告态契约: 门槛轮询不准挂回 $isCurrentTrackAdBreak 订阅(预览会跟着对浏览器发 AppleScript)")
        expectEqual(view.contains(".onAppear { playback.syncAdSkipGate(adBreak: controller.isAdBreakNow) }"), true,
                    "广告态契约: 窗口出现时已经在放广告也要起轮询(onChange 只认变化)")

        // 稳态下那枚「可跳过」提示(2026-09-11,用户:「这个按钮目前只在展开状态有;帮我在灵动岛歌词行
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
        // 2026-09-09 用户要的两件(圈图:「广告时候的灵动岛的配色帮我设置为和机器刘海一样的
        // 纯黑色」「在左耳那边加上一个广告的标识图标」)。都钉住,因为它们各自很容易被后来的
        // 改动无声抹掉:纯黑那条是一个 `||` 分支,左耳那条夹在两个 else if 之间。
        expectEqual(view.contains("controller.isCollapsed || isIdleNoTrack || controller.isAdBreakNow"), true,
                    "广告态契约: 广告期间整卡盖成纯黑(跟收起态/无曲目同一层 Color.black)")
        // 「恒显示」是用户当天问答后定的(问「要不要任何广告都固定显示」,答「任何」),不是
        // 忘了加条件 —— 钉住它,免得以后有人看见"广告有缩略图时喇叭把图顶掉了"当成 bug 修回去。
        expectEqual(view.contains("} else if controller.isAdBreakNow {"), true,
                    "广告态契约: 左耳广告标识在广告期间恒显示,不看配置也不看原本有没有内容")
        expectEqual(view.contains("earShowsNothing"), false,
                    "广告态契约: 判空分支已随「恒显示」一起删干净,没留死代码")
        expectEqual(view.contains("adBreakEarIcon(alignment: .leading)"), true, "广告态契约: 左耳画的是广告标识")
        expectEqual(view.contains("Image(systemName: \"megaphone.fill\")"), true,
                    "广告态契约: 左耳与状态行共用同一枚 megaphone.fill")
        // 2026-09-09 第二轮(用户:「只要识别到是广告的话,封面部分都用这个替代,你扫一下」):
        // 全 App 一共四个「当前曲目封面」位,广告期间都让位给同一枚喇叭。第四个(灵动岛展开
        // 头部 trackInfoArtwork)不在这里钉 —— 广告期间整块头部本来就不画
        // (`showsExpandedTrackInfo` 含 `!isAdBreakNow`,上面已有断言),它是被那条覆盖的。
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
        // 广告计数「· 1/2」(2026-09-09,用户:「广告中,还剩几个广告可以在灵动岛上展开显示出来吗」)。
        // 钉两件:它排在「广告中」和倒计时**之间**(三段连起来才是一句话),以及拿不到时整段不画。
        expectEqual(view.contains("adSlotText\n                    .font(playback.mainDetailFont)\n                adCountdown"), true,
                    "广告态契约: 计数排在「广告中」与倒计时之间")
        expectEqual(view.contains("if let slot = playback.currentAdSlot {"), true,
                    "广告态契约: 拿不到广告计数就整段不画,不编数字")
    }
}
