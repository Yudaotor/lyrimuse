import LyrimuseCore
import Foundation

// 灵动岛:展开区 / 对齐接线 / 音浪包络。
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
}
