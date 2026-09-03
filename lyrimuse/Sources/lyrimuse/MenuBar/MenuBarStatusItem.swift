import AppKit
import Combine
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-item")

// 状态栏兜底图标(没在放歌 / 关掉菜单栏歌词时显示的那个):音符 + 三条歌词横线,
// 跟正式 App 图标同一个构图。纯剪影(`isTemplate = true`),系统按明暗/悬停自动上色,
// 不用分别做浅色深色两份。
//
// ---- 为什么是"SF Symbol 的音符 + 自己画的三条线",而不是一张 PNG ----
//
// 2026-08-17 用户报"图标怎么变成这个鬼样子了,这么小"。量下来是两次缩小**乘在了一起**:
//   * 2026-07-20 那次(commit 579f8b3)为了让图标别比旁边的系统图标大,做了两件事 ——
//     重新生成一张四周带内边距的 PNG,**并且**把显示尺寸从 16 缩到 14;
//   * 而那张 PNG 里字形只占画布的 61% 宽 / **42% 高**(实测:36×36 的画布,字形只有
//     22×15,上下各留了 10 px 空白)。
// 两者相乘,字形的实际视觉高度只剩 14 × 0.42 ≈ 5.9pt,而菜单栏里系统图标的字形普遍在
// 13pt 上下 —— 看着就是"小了一大圈"。
//
// 光把显示尺寸调大治不了本:字形只占 42% 高,要让它到 13pt,画布得 31pt,菜单栏
// (thickness 22pt)根本放不下。而那张 PNG 的字形本身只有 22×15 像素,放大必糊 ——
// 位图这条路走到头了,只能矢量。
//
// 于是拆成两半各交给合适的人画:
//   * **音符**用 SF Symbol `music.note` —— 造型(圆头在左下、符干、右上一面旗)跟原来那张
//     一模一样,但它是矢量的,且跟系统自带图标共用同一套视觉重量,天然"合群"。
//     不用 `music.note.list`:那个是三条线在**左**、音符在右,跟这里的构图正好左右相反。
//   * **三条歌词横线**自己画 —— 三个圆角矩形而已,不存在画不准的风险,还能保住
//     "音符在左、歌词线在右"这个原有构图。
// 菜单栏那个图标(没在显示歌词时才出现)长什么样、有哪几款可选、以及选型标准,
// 全在 MenuBarIconStyle 里。

// 菜单栏那一项的总控(2026-08-16 加,取代 MenuBarExtra + MenuBarLabel + MenuBarMarqueeTicker)。
//
// 为什么不再用 MenuBarExtra:它把 label **快照成一张图**塞进状态栏按钮(探针读出来的
// 实况),视图侧没有活的图层,滚动只能靠"每帧换一张图"驱动,顺滑度受主线程调度摆布。
// 自建 NSStatusItem 之后拿到真的 NSView/CALayer,滚动交给 Core Animation ——
// 详见 MenuBarScrollingLabel 顶部那段实测记录。
//
// 这个类同时接管了原来 MenuBarMarqueeTicker 的活,但**没有计时器了**:它只在"换句 /
// 改宽度 / 开关变化 / 播放状态变化"这四件事发生时算一次该显示什么,然后交给
// 三条互斥的展示路径之一。滚动那条路装完动画就撒手。
//
// 生命周期自持:靠 Combine 订阅 AppSettings/PlaybackCoordinator,不依赖任何视图的
// onAppear —— 状态栏这一项从 App 启动到退出一直都在。
@MainActor
final class MenuBarStatusItem: NSObject {
    static let shared = MenuBarStatusItem()

    private var statusItem: NSStatusItem?
    private let scrollingLabel = MenuBarScrollingLabel()
    private let menuController = MenuBarStatusMenu()
    private var cancellables: [AnyCancellable] = []
    private var started = false
    /// 上一次用过的透明占位图(见 spacerImage)。只存一张:尺寸只在用户拖设置里那根
    /// 宽度滑杆时才变,同一时刻用得上的永远只有一个。
    /// (顺带绕开一件事:NSSize 直到 macOS 15 才 Hashable,拿它当字典键会在 14 上报警告。)
    private var spacer: (size: NSSize, image: NSImage)?
    /// 图标的"活体"渲染层(播放时所有款式都能动,见 MenuBarLiveIconView 头注)。
    /// 何时动/停由这里的展示状态决定,怎么动全在视图里 —— 全部 CA 驱动,
    /// 这个类保住了"没有计时器"的承诺。
    private let liveIconView = MenuBarLiveIconView()
    /// 左键面板(2026-08-19,「控制中心风」,见 MenuBarPanel.swift)。右键仍是完整菜单。
    private let panelController = MenuBarPanelController()
    /// 首次启动的一次性「⌘+拖拽可以挪位置」提示(2026-09-01,见 MenuBarPositionHint.swift
    /// 头注的调研背景)。
    private let positionHintController = MenuBarPositionHintController()
    /// 悬停三键那一层(2026-09-03,见 MenuBarHoverControlsView 头注)。默认隐藏,
    /// 只在接管时露出来;它同时是 hover 事件的收口(tracking area 的 owner)。
    private let hoverControls = MenuBarHoverControlsView()

    private override init() { super.init() }

    /// AppDelegate 启动时调一次。
    func start() {
        guard !started else { return }
        started = true

        // 这里**不**预建状态栏项:末尾那次 refresh() 会让它以正确的形态+宽度出生
        // (macOS 26 只认出生宽度,见 buttonForDisplayClass 头注)。原来"先 variableLength
        // 出生、refresh 再拆掉重建"等于启动就白白多一次邻居重排。
        panelController.onVisibilityChange = { [weak self] on in
            self?.scrollingLabel.setHighlighted(on)
            self?.liveIconView.setHighlighted(on)
            self?.hoverControls.setHighlighted(on)
            self?.setPanelOpen(on)
        }
        hoverControls.onHoverChange = { [weak self] inside in self?.handleHoverChange(inside) }

        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared
        // ⚠️ 每一条订阅都必须 .receive(on: RunLoop.main),不能直接 sink —— 这个项目已经
        // 实测踩过两次:@Published 的 publisher 在 **willSet** 时机发射,回调执行时属性
        // 本身还是**旧值**。下面这些回调都不用发射值、而是转头去读 AppSettings/
        // PlaybackCoordinator 的当前状态(refresh() 内部这么做),直接 sink 会读到旧值:
        // isPlayingNow 从 false 变 true 时 refresh() 读到的仍是 false,菜单栏永远不显示
        // 歌词。挪到下一个 runloop 循环再跑,属性此时已经落定成新值。
        // ⚠️ 这里订阅的是 compactLine(决定**显示哪一句**);下面另有一条 currentLine 的
        // 订阅,那条管的是"逐字填色路径此刻可不可用" —— 提前量窗口里显示的是下一句、但它
        // 还没开唱,karaokeFillPath 那道 `line.plainText == text` 守卫会不给路径(正确:
        // 没唱就不该有填色);等真的开唱时 currentLine 才变,那一下要重画一次把填色挂上。
        // 两个事件在短间隙里相差不到一秒,文本相同 → 槽宽相同 → 不触发状态项重建。
        coordinator.$compactLine
            // 同一句内部会因为逐字之外的原因被重新赋值(译文/罗马音中途补上),去重掉 ——
            // 不去重的话滚动会被反复打回开头。⚠️ 去重键是「首词时间戳#纯文本」,不能只看
            // 纯文本(2026-08-22 审阅抓出):副歌里相邻两行**同词不同时**,只看文本第二行
            // 的换行事件会被吞掉,菜单栏挂着第一行的填色路径 —— 第一行唱完动画停在全填,
            // 第二行一出场就整句强调色。同理「先无逐字、解析中途补上」(words nil→非 nil)
            // 也必须算换句,否则这句到换行前都不会开始染色。
            .map { line -> String in
                guard let line else { return "" }
                return "\(line.words?.first?.startMs ?? -1)#\(line.plainText ?? "")"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // 见上面那段:开唱那一刻要重画一次,好把逐字填色路径挂上。只关心"有没有词可染",
        // 所以去重键只取首词时间戳。
        coordinator.$currentLine
            .map { $0?.words?.first?.startMs ?? -1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.$showLyricsInMenuBar.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 宽度改了可能从"要滚"变成"装得下"(或者反过来)。
        //
        // ⚠️ 订阅的必须是**现在真正在用的那个**设置。2026-08-15 把宽度从字数改成点时
        // 这里一度还挂在旧的 maxChars 上,后果是拖宽度滑杆完全不生效。
        //
        // debounce 而不是 receive(on:):宽度变化现在会触发状态栏项**重建**(macOS 26
        // 原地改 length 不给邻居重排,见 buttonForDisplayClass),拖滑杆时每个中间值都
        // 重建一次就是一场重排风暴。停手 250ms 后按最终值重建一次。
        // (debounce 本身也把回调推迟到了下一个 runloop 之后,willSet 旧值坑照样躲开。)
        settings.$menuBarLyricsWidth.dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 同理:切固定/自适应会改变**当前这一句**该走哪条显示路径,不能等下一次换句
        // 才生效 —— 那样用户在设置里点一下,菜单栏上看着像没反应。
        settings.$menuBarLyricsWidthMode.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 「对齐模式」跟宽度模式同一条路(2026-09-01)。⚠️ 必须走 refresh() 而不是
        // refreshColors():后者只重排位图 + 重放填色,**不碰 position** —— 而对齐改的正是
        // position。refresh 会一路走到 present(),Plan 里带着 alignment、比出不同,静止分支
        // 就会按新对齐重新落位(见 MenuBarScrollingLabel.restartAnimation)。
        settings.$menuBarLyricsAlignment.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 换图标样式要立刻看到 —— 用户是在设置里一个个点着挑的,等下次换歌才生效
        // 等于挑不了。
        settings.$menuBarIconStyle.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 「随播放律动」开关拨动要立刻生效 —— 用户就是盯着菜单栏拨的。
        settings.$menuBarIconAnimates.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 歌词旁那枚带进度的图标:开/关/换边要立刻看到(用户就是盯着菜单栏点的)。
        // ⚠️ 必须走 refresh():它改的是这一项的**槽宽**(多让出 图标宽 + 5pt),而槽宽只在
        // 项出生那一刻算数 —— refreshColors 那条只重画不重建,换过去菜单栏上会是"图标画出来
        // 了但格子没变宽",歌词右边被挤出去(见 present 头注两条铁律)。
        settings.$menuBarLyricsIconPosition.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        coordinator.$isPlayingNow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 悬停三键(2026-09-03)。两条订阅:
        //
        // ① 开关本身 —— 拨掉的时候如果正接管着,要立刻把歌词放回来(用户就是盯着菜单栏拨的)。
        settings.$menuBarHoverShowsControls.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateHoverEngagement() }.store(in: &cancellables)
        // ② 中间那个键画 ⏸ 还是 ▶。用**观感层** isPlayingSmoothed 而不是 isPlayingNow:
        // 这三个键最典型的用法就是"点一下暂停",而真实链路(命令→播放器切状态→分布式通知→
        // poll→apply)实测 0.5~1s,等真值回读图标才翻,手指还压在键上却看着像没生效
        // (见 PlaybackCoordinator.userTogglePlayPause 的乐观回声)。
        // ⚠️ 这条**不能**走 refresh():接管期间 refresh 是早退的(见它开头那道 guard),
        // 图标要在接管期间照样跟得上,所以直接推给那一层自己重画。
        coordinator.$isPlayingSmoothed.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in self?.hoverControls.setPlaying(on) }.store(in: &cancellables)
        // 逐字染色开关:用户就是盯着菜单栏拨的,当前句要立刻上色/褪色。
        settings.$menuBarLyricsKaraoke.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 粗细(2026-09-03):字重一变文字宽度就变(拉丁字 heavy 比 regular 宽约 9%),自适应模式下
        // 槽宽跟着变 —— 所以必须走 refresh()(重排、必要时重建槽位),不能像颜色那样只
        // refreshColors。图层那条路的位图与滚动距离由 Plan.fontWeight 参与 present 判定来保证重排。
        settings.$menuBarLyricsFontWeight.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 字号(2026-09-03):除了宽度,行高也变 —— 固定宽度模式下槽宽不变、present(class:length:) 不重建,
        // 但 render 闭包照样跑,showFixedWidth 里那张占位图会按新的 lineHeight 重画;图层那条路由
        // Plan.fontSize 保证重排。
        settings.$menuBarLyricsFontSize.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 两个自定义颜色:refreshColors 管图层渲染那条路(只换位图,不打断滚动/填色动画),
        // refresh 管自适应模式 button.title 那条退化路(颜色进的是 attributedTitle,
        // 得重画标题;对图层路径它是 present 同参数空操作,无副作用)。
        settings.$menuBarLyricsTextColorHex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scrollingLabel.refreshColors()
                self?.refresh()
            }.store(in: &cancellables)
        settings.$menuBarLyricsFillColorHex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scrollingLabel.refreshColors() }.store(in: &cancellables)
        // 逐字染色的对表通道:锚点(每次 poll ~2s 重发一次 + seek/暂停/恢复)、暂停位置、
        // 时间轴偏移任一变化都重新对一次表。这条**不走 refresh**(不涉及槽位/内容,只是
        // 时钟),标签内部有 250ms 漂移门,逐 poll 的锚点更新几乎都被无声吸收,不会打断
        // 正在跑的填色动画。偏移微调(默认步长 200ms)在漂移门之下,必须 force 立即生效。
        // ⚠️ 锚点/暂停位置这两条同时喂**两条**对表通道:逐字染色(对歌词时间轴)和进度图标
        // (对播放位置)。两者的位置口径差一个歌词时间轴偏移,见 syncProgressClock 头注。
        coordinator.$anchor.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncKaraokeClock()
                self?.syncProgressClock()
            }.store(in: &cancellables)
        coordinator.$pausedPositionMs.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncKaraokeClock()
                self?.syncProgressClock()
            }.store(in: &cancellables)
        // 歌词时间轴偏移**只**喂染色那条:它挪的是歌词,歌本身放到第几秒没变。
        coordinator.$currentLyricsOffsetMs.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncKaraokeClock(force: true) }.store(in: &cancellables)
        // 曲长**只**喂进度那条(染色的终点是这一行唱完,不看曲长)。换歌、或者播放器晚一步
        // 才报出时长,都要按新曲长重算 —— force 是因为曲长一变,旧动画描述的整段行程就作废了,
        // 而位置可能一点没动(过不了漂移门)。
        coordinator.$currentDurationMs.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncProgressClock(force: true) }.store(in: &cancellables)

        refresh()

        // 首次启动的一次性拖拽引导提示(2026-09-01,见 MenuBarPositionHint.swift 头注)。
        // 上面这次 refresh() 是同步的(见 present() 的"没有旧项就无条件重建"分支),此刻
        // statusItem?.button 已经是真的按钮了。延迟 1.5s 只是让图标先在视觉上落定,不在
        // 启动的第一帧就糊用户一脸提示。标记提前到"决定要展示"这一刻就置真,而不是等用户
        // 点了「知道了」才置真——这样即使用户在提示消失前就退出 App,也不会下次启动又弹
        // 一遍(跟 hasSeenChineseLyrics 类那种"条件成立就一直显示"刻意反过来,这个是
        // "展示过一次就永远不再显示")。
        //
        // ⚠️ **引导还没走完时整个不弹**(2026-09-03)。首启的时间线是:T+0.5s 弹引导窗口
        // (MenuBarSceneActions,过 iCloud 导入询问那一道之后)、T+1.5s 弹这个气泡、T+9.5s
        // 它自动消失(MenuBarPositionHint.autoDismissSeconds = 8)。也就是说这个"一辈子只
        // 出现一次"的提示,恰好在用户正盯着引导向导读第一屏的时候在旁边闪 8 秒然后**永久
        // 消失** —— 而上面那条"提前置真"的规则会照样把标记烧掉,用户再也见不到它。
        //
        // 判据用 hasCompletedOnboarding(= 这台机器走完引导了没有,只由 OnboardingView.finish()
        // 置位)而不是"引导窗口现在开着没有":后者要去问窗口状态,而且用户把引导关掉当"稍后
        // 再说"时它下次启动还会再弹,气泡照样会跟它撞上。没走完就直接**不置真、不展示**,
        // 留到下一次启动 —— 那时用户已经认识这个图标了,"⌘+拖拽可以挪位置"才真正读得懂。
        //
        // 引导本身不靠这个气泡交代"App 在菜单栏":doneStep 那一步已经把图标位置和 ⌘+拖拽
        // 都写进去了(见 OnboardingView.doneStep),两条路互为兜底而不是互相等待。
        if !AppSettings.shared.hasShownMenuBarPositionHint,
           AppSettings.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                AppSettings.shared.hasShownMenuBarPositionHint = true
                self.positionHintController.show(relativeTo: button)
            }
        }
    }

    /// 把播放时钟(外推位置 + 歌词时间轴校准)喂给标签的填色动画。位置公式与歌词窗口
    /// KaraokeWordText 逐字填色完全同一条:anchor 外推 ?? 暂停位置,再加偏移校准。
    private func syncKaraokeClock(force: Bool = false) {
        let coordinator = PlaybackCoordinator.shared
        let raw: Int?
        if let anchor = coordinator.anchor {
            raw = anchor.extrapolatedPositionMs(now: Date())
        } else {
            raw = coordinator.pausedPositionMs
        }
        scrollingLabel.updateKaraokeClock(
            positionMs: raw.map { $0 + coordinator.currentLyricsOffsetMs },
            rate: coordinator.anchor?.rate ?? 0,
            playing: coordinator.isPlayingNow,
            force: force)
    }

    /// 把播放时钟喂给歌词旁那枚进度图标。跟 `syncKaraokeClock` 是**两条**通道,差别只有
    /// 一处,但那一处正是这个功能对不对的关键:
    ///
    /// ⚠️ **这里不加 `currentLyricsOffsetMs`**。那个偏移是把歌词往前/往后挪(让字跟得上
    /// 人声),歌本身放到第几秒并没有变 —— 加上去的话,用户把歌词调快 2 秒,进度图标也跟着
    /// 虚报 2 秒。染色那条**必须**加(它对的是歌词时间轴),这条**必须**不加(它对的是
    /// 播放位置)。两个函数长得像,改其中一个之前先看清是哪一条。
    ///
    /// 曲长优先取锚点里那份(跟位置是同一次采样、最配套),它缺/为 0 时退回
    /// `currentDurationMs`;两个都没有就传 nil —— 标签那边会整枚只画基础色,不假装有进度。
    private func syncProgressClock(force: Bool = false) {
        let coordinator = PlaybackCoordinator.shared
        let anchor = coordinator.anchor
        let raw: Int? = anchor.map { $0.extrapolatedPositionMs(now: Date()) }
            ?? coordinator.pausedPositionMs
        let duration = [anchor?.durationMs, coordinator.currentDurationMs]
            .compactMap { $0 }.first { $0 > 0 }
        scrollingLabel.updateProgressClock(
            positionMs: raw, durationMs: duration,
            rate: anchor?.rate ?? 0, playing: coordinator.isPlayingNow, force: force)
    }

    /// 歌词旁那枚带播放进度的图标(nil = 设置里关着)。
    ///
    /// 款式跟"图标独占那一格"时用的是**同一个** `menuBarIconStyle` —— 那本来就是这个 App
    /// 在菜单栏上的脸,没有理由在两个地方各挑一款。这个函数只回答"要不要画、画哪款、摆哪边";
    /// 进度画到哪儿由 syncProgressClock 那条通道管。
    private func lyricsIconBadge() -> MenuBarScrollingLabel.IconBadge? {
        let settings = AppSettings.shared
        let position = settings.menuBarLyricsIconPosition
        guard position != .off else { return nil }
        return MenuBarScrollingLabel.IconBadge(style: settings.menuBarIconStyle,
                                               position: position)
    }

    /// 当前句的逐字填色路径。nil = 不染:开关关着、这句没有逐字数据、或标签文本跟逐字
    /// 数据对不上号(理论上 plainText 就是 words 拼接,这层守卫防的是两者在换句瞬间
    /// 读到不同代的数据 —— 对不上宁可不染,染错位置比不染难看得多)。
    private func karaokeFillPath(for text: String) -> [MenuBarMarquee.KaraokeFillPoint]? {
        guard AppSettings.shared.menuBarLyricsKaraoke else { return nil }
        guard let line = PlaybackCoordinator.shared.currentLine,
              let words = line.words, !words.isEmpty,
              line.plainText == text else { return nil }
        let path = MenuBarMarquee.karaokeFillPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words))
        return path.isEmpty ? nil : path
    }

    /// 把按钮的全套装配(字体/两个内容子视图/点击路由)应用到一个状态栏项上。
    /// start() 首次建项和 rebuildStatusItem() 重建都走这里,保证两处一字不差。
    /// 状态栏项 autosaveName 的基名。第 0 代就是它本身(兼容既有的存位,包括 27 上系统
    /// MenuBarAgent 里已经记着的那条);老机制(27 以前)上每次重建换一代:`<基名>-g<N>`,见
    /// `rebuildStatusItem` 头注。
    private static let statusItemAutosaveBaseName = "lyrimuse-status-item"
    private static let autosaveGenerationDefaultsKey = "np:menuBarAutosaveGeneration"

    /// 当前这一代的 autosaveName(跨启动持久,这样重启后首次建项用的还是上次那个名字、
    /// 能读到用户最后拖过的位置)。
    private static var currentAutosaveName: String {
        let gen = UserDefaults.standard.integer(forKey: autosaveGenerationDefaultsKey)
        return gen <= 0 ? statusItemAutosaveBaseName : "\(statusItemAutosaveBaseName)-g\(gen)"
    }

    /// macOS 27 以前(本 App 支持的 14 / 15 / 26 全在内)AppKit 记这一项位置用的 UserDefaults
    /// 键(值 = 项右边缘到屏幕右缘的距离,pt;2026-09-02 在 26.5.1 真机上核对过:拖到
    /// origin.x=1146、宽 55、屏宽 1512 → 存值 313 ≈ 1512 − 1201)。macOS 27 起位置改由系统
    /// MenuBarAgent 集中管理(`com.apple.MenuBarAgent` → `TrailingItemPreferredPositions`),
    /// 这个键不再出现。
    private static func preferredPositionDefaultsKey(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// 这台机器记状态栏项位置用的是不是老机制(App 自有 defaults 键)。按**机制**判、不按版本号
    /// 判:读得到系统 MenuBarAgent 的那份 dict 就是新机制(27+),读不到就是老机制(26.x 及
    /// 更早,直到本 App 的最低支持版本 14)。不用 `operatingSystemVersion` 硬编码 27 这个数——
    /// 万一哪个小版本把机制挪了,按机制判仍然是对的。
    /// ⚠️ 这个判断只做一次缓存:同一进程里机制不会变,而每次重建都去读一遍别的 App 的 defaults
    /// 没有必要。
    private static let usesLegacyPositionDefaults: Bool = {
        CFPreferencesCopyAppValue(
            "TrailingItemPreferredPositions" as CFString,
            "com.apple.MenuBarAgent" as CFString) == nil
    }()

    private func attachButtonChrome(to item: NSStatusItem) {
        // 位置要在系统的状态栏排序记忆里保持同一身份,重建后才不会跳位。
        item.autosaveName = Self.currentAutosaveName
        guard let button = item.button else { return }
        // 退化路径(showStaticText)用按钮自己画文字时的字体,跟图层那条路画图用的是
        // 同一个 —— 两条路之间切换时字号不能跳。
        button.font = MenuBarMarqueeRenderer.font
        scrollingLabel.removeFromSuperview()
        scrollingLabel.frame = button.bounds
        scrollingLabel.autoresizingMask = [.width, .height]
        scrollingLabel.isHidden = true
        button.addSubview(scrollingLabel)
        liveIconView.removeFromSuperview()
        liveIconView.frame = button.bounds
        liveIconView.autoresizingMask = [.width, .height]
        button.addSubview(liveIconView)
        // 悬停三键那一层**加在最后** = z 序最上。前两层是互斥的歌词层/图标层,这一层跟它们
        // 不是同一维度:接管时那两层被 clear 掉,它自己露出来画三个键。
        hoverControls.removeFromSuperview()
        hoverControls.frame = button.bounds
        hoverControls.autoresizingMask = [.width, .height]
        button.addSubview(hoverControls)
        // ⚠️ hover 的 tracking area 装在**按钮**身上(owner 是上面那一层,理由见
        // MenuBarHoverControlsView 头注),所以必须在这里跟着重装:按钮每次重建都是新的,
        // 旧按钮身上的区域跟它一起没了 —— 漏了这一行的症状是"重建过一次之后悬停再没反应"。
        hoverControls.installTracking(on: button)
        // 2026-08-19 起不再把菜单常挂在 item.menu 上(挂着=任何点击都弹菜单):
        // 左键弹「控制中心风」面板,右键(或 ⌃左键)才弹完整菜单 —— 弹菜单时临时挂上、
        // 弹完摘掉(见 popUpFullMenu)。
        button.target = self
        button.action = #selector(statusButtonClicked)
        // 左键**按下**就弹面板(2026-09-03 用户要求「点了马上弹出」):原来只在松开时触发,
        // 一次点击按下到松开本身就有 ~100ms,再叠上弹出动画和首帧大图解码就是可感知的
        // 一拍。系统控制中心/原生状态栏菜单也都是按下即出。右键和 ⌃左键仍走松开:那条是
        // popUpFullMenu 用 performClick 借原生菜单弹出,在真实按下的追踪循环里再合成一次
        // 点击,行为没实测过,不冒这个险。松开事件也要收——⌃左键的菜单就靠它,普通左键的
        // 松开在 statusButtonClicked 里直接忽略(按下那一下已经处理过)。
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
    }

    /// 当前展示形态("icon"/"text"/"fixed")。形态或槽宽一变,项就整个拆掉重建
    /// (见 present 头注),这里只是重建判定的缓存键之一。
    private var displayClass = ""

    /// 歌词固定宽度态的槽宽:窗口宽 + 系统内边距(实测健康态 160 → 178)。
    private static let fixedSlotPadding: CGFloat = 18

    /// 两次重建之间的最小静默间隔,兼作歌词间隙的收缩观察窗(见 present 头注)。
    /// 卡死的那次实测两发相隔 1.1s,取 3s 留余量。
    private static let rebuildQuietSecs: TimeInterval = 3
    private var lastRebuildAt = Date.distantPast
    private var pendingRefresh: DispatchWorkItem?

    /// 左键面板(popover)开着没有。开着期间**一律不重建**状态栏项 —— 详见 present()
    /// 里那段分支。收起时补一次 refresh(),把期间挡下来的几何变化一次性落地。
    private var panelIsOpen = false

    private func setPanelOpen(_ open: Bool) {
        panelIsOpen = open
        // notice 级:面板开合要能跟上面那些 slot rebuild 日志对到同一条时间线上 ——
        // "面板自己消失了"这类问题只有对上时间线才看得出是谁拆了锚点。
        logger.notice("panel \(open ? "opened" : "closed", privacy: .public)")
        if !open { refresh() }
        // 面板开 = 退出悬停接管(面板自己就有三键,而且这一项正是它的锚点视图);
        // 面板收 = 指针大概率还停在这一项上,补一次判定把三键接回来。
        // 顺序在 refresh() 之后:接管态的进/出各自要一次内容重画,合在一起会互相盖。
        evaluateHoverEngagement()
    }
    /// 本轮收缩观察窗的起点。⚠️ 必须记住起点而不是每次给满窗:推迟的重跑走的还是
    /// refresh() → present(),不记起点的话每次重算都重新发满一个观察窗,收缩被无限
    /// 顺延 —— 暂停后槽永远缩不回去(实现当天差点带着这个 bug 部署)。
    /// 目标不再是收缩(歌词回来了 / 几何已一致 / 用户手动关开关)时清零。
    private var collapseObserveBegan: Date?

    /// 把"形态 cls、槽宽 length、内容 render"呈现到状态栏上。macOS 26 菜单栏的两条
    /// 实测铁律(2026-08-19,六轮排查 AX 全图 + 像素截图坐实):
    ///
    /// 1. **只在项出生那一刻**按当时的宽度给邻居排位 —— 事后换 image、原地改 length、
    ///    重踢 length,邻居一概不让位(加宽=歌词压到别家图标头上,收窄=留个空椭圆)。
    ///    所以形态或槽宽的**任何**变化都整项重建,且出生就带显式 length,绝不留直赋
    ///    捷径(第六轮用户"只是把菜单设置重改了一下就不正常"=命中当时仅剩的宽度直赋)。
    /// 2. **重建不能连发**:单次重建从未观察到排坏,但两次重建相隔 ~1s(实测 1.1s 的
    ///    歌词间隙收放、或用户连着改几项设置)会把**邻居的像素**晾在旧位置上不动 ——
    ///    此时 AX 账面已是新位置(AX 全图看着完全健康!),屏幕像素却是旧布局,歌词
    ///    画在新槽里正好压到邻居的残影头上,且这个错位**保持住不自愈**,直到下一次
    ///    从容的重排才恢复。验证这条 bug 只能靠**截图像素**,AX 会说谎。
    ///
    /// 所以这里对几何变化做节流:距上次重建不足 rebuildQuietSecs 就先换内容、把几何
    /// 变化推迟到静默窗之后(推迟期间目标又变了就合并成最新目标);歌词间隙/暂停的
    /// 收缩额外恒等一个观察窗(collapseDelay)——间隙常在 1~2s 内结束,歌词回来时
    /// 几何目标恢复原样,这对"缩了又扩"的重建就整个省掉了,期间图标居中画在还没缩
    /// 的宽槽里顶着。
    ///
    /// 重建/推迟各落一条 notice 级日志(info 不落盘,上次排查就是因此拿不到现场):
    /// 再出错位,`/usr/bin/log show --predicate 'subsystem == "me.yudaotor.lyrimuse"
    /// && category == "menubar-item"'` 能对出完整时间线。
    private func present(class cls: String, length: CGFloat, collapseDelay: TimeInterval,
                         dwellSeconds: TimeInterval? = nil,
                         interim: ((NSStatusBarButton) -> Void)? = nil,
                         render: (NSStatusBarButton) -> Void) {
        // 每次都从最新状态重算目标,历史挂起的目标一律作废。
        pendingRefresh?.cancel()
        pendingRefresh = nil

        // 短命行不缩槽(2026-09-03,用户报"自适应模式换行时抖动")。为一句活不过静默窗的
        // 短句收窄槽位,对可读性零收益(文字本来就装得下),却花掉了一次重建配额 —— 下一句
        // (往往长得多)的加宽因此撞进静默窗,被推迟到**句中**才落地,槽宽当着用户的面跳一下。
        // 判据与论证见 MenuBarSlotPolicy(那里记着实测抓到的现行和 37% 那组统计)。
        //
        // ⚠️ 只在**两个歌词槽之间**成立(text/fixed 互相之间也算,不要求同态):图标↔歌词
        // 那次重建跟"这一句活多久"无关,而且收进图标槽走的是收缩观察窗(collapseDelay)
        // 自己的节奏,不受这条影响。跨态放行是刻意的 —— 「装不下要滚」的 fixed 槽恒等于
        // 最大宽度,长短句交替时 fixed↔text 正是幅度最大的那种跳(实测 268 ↔ 100),把它
        // 排除在外等于把最该管的一种漏掉。代价是跳过期间 displayClass 停在旧态、跟屏幕上
        // 画的不完全对应,这没问题:它只是重建判定的缓存键,而跳过期间的内容由 interim
        // 按**当前槽宽**重新排版,不读这个键。
        let lyricSlotClasses: Set<String> = ["text", "fixed"]
        if let item = statusItem, let button = item.button, let interim,
           lyricSlotClasses.contains(cls), lyricSlotClasses.contains(displayClass),
           MenuBarSlotPolicy.skipsShrink(currentLength: item.length, targetLength: length,
                                         dwellSeconds: dwellSeconds,
                                         quietSecs: Self.rebuildQuietSecs)
        {
            logger.debug("""
                slot shrink skipped (brief line \(dwellSeconds ?? -1, privacy: .public)s): \
                \(item.length, privacy: .public) -> \(length, privacy: .public)
                """)
            // ⚠️ 跟这条早退之外的每一条路径口径一致:歌词还在(collapseDelay 恒为 0),
            // 收缩观察窗就该清零。漏了这一句的话,"间隙里刚起了一个观察窗 → 歌词回来但
            // 全是短句 → 一路走这条早退"时,那个起点会一直挂着;等下次真要收进图标槽时
            // observeRemaining 已经被算成 0,收缩当场就发生 —— 观察窗(专治"缩了又扩"
            // 那对重建)等于白设。
            collapseObserveBegan = nil
            // 内容照常实时画进当前这个(偏宽的)槽里 —— 收缩跳过的只是几何。
            interim(button)
            return
        }

        let needsRebuild: Bool
        if let item = statusItem {
            needsRebuild = cls != displayClass || item.length != length
        } else {
            needsRebuild = true
        }
        guard needsRebuild else {
            collapseObserveBegan = nil
            if let button = statusItem?.button { render(button) }
            return
        }

        // ⚠️ 面板开着时把几何变化整个挡下来。状态栏这一项的按钮**就是那张 popover 的锚点
        // 视图**,而重建 = removeStatusItem + 新建一项,等于把锚连根拔掉:轻则面板当场自己
        // 消失(用户手还在上面),重则内容按新槽宽画出去、槽却还是旧宽度,歌词压到左边邻居
        // 的图标上(2026-08-19 用户报过这一幕,当时只当成"面板开着切开关"的个例,用调用侧
        // 先收面板绕过去了 —— 触发源其实不止那一个:自适应宽度模式下**每换一句**都改槽宽,
        // 歌词间隙/暂停的收缩也改,面板开着时这些都会踩到)。
        //
        // 不排期补做,交给 setPanelOpen(false) 收面板那一刻的 refresh() —— 面板还开着就
        // 重建这件事本身没有安全的时机。期间内容照旧就地换(目标是图标才换,理由同下面
        // 那条推迟分支),歌词最多晚到面板收起。
        if panelIsOpen, statusItem != nil {
            logger.notice("slot rebuild suppressed (panel open): \(self.displayClass, privacy: .public) -> \(cls, privacy: .public)(\(length, privacy: .public))")
            // 内容不等几何(2026-08-19 补,与下面推迟分支对齐):目标是图标就地画;目标是
            // 歌词就按当前(被锚住不许动的)槽宽画一版过渡 —— renderInterimLyrics 只改
            // button 内容、零重建零碰锚点,面板开着时调用同样安全。原来 text/fixed 直接
            // return,自适应宽度模式下面板开着期间状态栏歌词会冻在旧句(当时注释里"歌词
            // 最多晚到面板收起"的取舍,在 interim 机制就绪后已无必要)。
            if let button = statusItem?.button {
                if cls == "icon" { render(button) } else { interim?(button) }
            }
            return
        }

        if statusItem != nil {
            let now = Date()
            let observeRemaining: TimeInterval
            if collapseDelay > 0 {
                let began = collapseObserveBegan ?? now
                collapseObserveBegan = began
                observeRemaining = max(0, collapseDelay - now.timeIntervalSince(began))
            } else {
                collapseObserveBegan = nil
                observeRemaining = 0
            }
            let delay = max(observeRemaining, Self.rebuildQuietSecs - now.timeIntervalSince(lastRebuildAt))
            if delay > 0 {
                // debug 级(2026-08-19 降噪):推迟是自适应模式的**常态**节流路径,每换一句
                // 都走到,notice 级会让它逐句落盘。错位排查真正要对时间线的是"重建何时
                // 执行"(下面那条,3s 至多一次,保持 notice);推迟细节要看时开 debug 采集。
                logger.debug("slot rebuild deferred \(delay, privacy: .public)s: \(self.displayClass, privacy: .public) -> \(cls, privacy: .public)(\(length, privacy: .public))")
                // 推迟的只是**几何**,内容不等(2026-08-19 用户反馈"3s 延迟之后歌词
                // 有时不及时更新"——自适应模式逐句都是几何变化,内容跟着几何一起等
                // 就是逐句都可能晚 3s):目标是图标就把图标画进还没变的槽里(图标在
                // 任意槽宽下都居中,见 showIcon);目标是歌词就按**当前槽宽**先画一版
                // 过渡(interim,装得下居中静止、装不下就地滚),槽宽跟上后 refresh
                // 会按目标重画。
                if let button = statusItem?.button {
                    if cls == "icon" {
                        render(button)
                    } else {
                        interim?(button)
                    }
                }
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                pendingRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: work)
                return
            }
        }

        collapseObserveBegan = nil
        logger.notice("slot rebuild: \(self.displayClass, privacy: .public)(\(self.statusItem?.length ?? -1, privacy: .public)) -> \(cls, privacy: .public)(\(length, privacy: .public))")
        displayClass = cls
        lastRebuildAt = Date()
        rebuildStatusItem(length: length)
        if let button = statusItem?.button { render(button) }
    }

    /// 整项销毁重建(为什么必须重建而不能原地改宽度,见 present() 头注)。
    ///
    /// ## macOS 27 以前(14 / 15 / 26):重建会把这一项"记住的位置"抹掉,必须自己保住(2026-09-02)
    ///
    /// 用户报"另一台 macOS 26.5.1 的机器上,状态栏项每次重建都跳到菜单栏最左侧,⌘拖回去
    /// 下次重建又跳",这台 27 的开发机复现不出来。往两台机器各部署了七轮文件日志(系统日志
    /// 在那台机器上已损坏、走不通)才钉死,证据链:
    ///
    ///  - 两台机器重建后都是先出现在 x=0、约 0.3~1s 后落位;27 上落位时**右边缘守住不动**
    ///    (1253→1253),26.5.1 上不管用户之前把它拖到哪(1059 / 1146 两次实测),落点都是
    ///    同一个固定位置(右边缘 1028,离屏幕右缘 484pt,即"新项默认插入点"=最左)。
    ///  - 27 以前记位置用的是 AppKit 老式的 App 自有 UserDefaults 键
    ///    `NSStatusItem Preferred Position <autosaveName>`(值 = 右边缘到屏幕右缘的距离,
    ///    实测拖到 1146 后存值 313 ≈ 1512−1201);27 起改由系统 MenuBarAgent 集中管理
    ///    (`com.apple.MenuBarAgent` → `TrailingItemPreferredPositions`),App 这边的键不再出现。
    ///  - **决定性的一条**:重建前这个键在(而且跟着用户的拖拽在更新),重建之后它**没了**,
    ///    之后 5 秒内也没被写回。新项设 autosaveName 时查不到任何记住的位置 → 按默认插入点
    ///    放到最左。App 启动那一次之所以正常,是因为还没发生过 remove、上一次会话留下的键完好。
    ///  - 删键的时机不是 `removeStatusItem` 当场,而是**旧项 dealloc**(`statusItem = item`
    ///    赋值、最后一个强引用消失那一刻)——"remove 之后立刻把键写回"那版实测仍然被删。
    ///
    /// 修法:与其猜 AppKit 什么时候删、删几次,不如让新旧两项**不同名**。老机制下每次重建换
    /// 一代 autosaveName(`<基名>-g<N>`,N 持久化,重启后首次建项沿用),并在建新项**之前**把
    /// 位置写到新名字的键下——旧项 dealloc 删的是自己那条,碰不到新项的;新项第一次登记这个
    /// 名字,系统一定去 defaults 里读。写的是 App 自己的 defaults,不碰私有 API。
    /// 27+(MenuBarAgent 机制)不换代:位置在系统 plist 里、按固定名字管,换名字只会往那里多
    /// 登记垃圾、App 自己清不掉,而且 27 上本来就没这个 bug。老机制下键还不存在(装完还没
    /// 拖过)时没什么可带,也不换代,等用户拖过一次就有了。
    ///
    /// 2026-09-02 在 26.5.1 真机上验证通过:重建前右边缘 1115,重建后 1s 起稳定在 1115
    /// (存值 399 ≈ 1512−1115),图标留在用户拖的位置。
    ///
    /// ⚠️ 排查期间走过几条岔路,记一笔免得重走:①"下一个 runloop 就读 window.frame"两台
    /// 都读 0,那是采样太早不是卡死,至少要 0.3s 才落位;②一度把"1s 后稳定"当成"归位",其实
    /// 是稳定在错的位置,"稳"和"对"要分开看;③"推迟到下一拍再建"没用,病根不在时序在删键。
    private func rebuildStatusItem(length: CGFloat) {
        let defaults = UserDefaults.standard
        let preservedPosition = Self.usesLegacyPositionDefaults
            ? defaults.object(forKey: Self.preferredPositionDefaultsKey(for: Self.currentAutosaveName))
            : nil
        if preservedPosition != nil {
            let gen = defaults.integer(forKey: Self.autosaveGenerationDefaultsKey) + 1
            defaults.set(gen, forKey: Self.autosaveGenerationDefaultsKey)
            defaults.set(preservedPosition, forKey: Self.preferredPositionDefaultsKey(for: Self.currentAutosaveName))
        }
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: length)
        statusItem = item
        attachButtonChrome(to: item) // 用的是换代后的 currentAutosaveName
        // 上一代及更早的键过几秒清掉(旧项 dealloc 多半已经删了自己那条,这里兜底),别让每次
        // 重建都往 plist 里多留一条。当前代的键不动。
        if preservedPosition != nil {
            let keep = Self.preferredPositionDefaultsKey(for: Self.currentAutosaveName)
            let prefix = Self.preferredPositionDefaultsKey(for: Self.statusItemAutosaveBaseName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for key in UserDefaults.standard.dictionaryRepresentation().keys
                where key.hasPrefix(prefix) && key != keep {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - 点击路由

    @objc private func statusButtonClicked() {
        guard let button = statusItem?.button, let event = NSApp.currentEvent else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.type {
        case .rightMouseUp:
            popUpFullMenu()
        case .leftMouseUp:
            // ⌃左键 = 右键(松开时弹菜单,理由见 attachButtonChrome)。普通左键的松开忽略——
            // 面板在按下那一下已经弹了/收了。
            if flags.contains(.control) { popUpFullMenu() }
        case .leftMouseDown:
            // ⌘按下是系统的「拖动状态栏图标换位置」手势(见 MenuBarPositionHint),不能在
            // 拖的起点先弹一个面板出来;⌃按下是菜单的前半段,等松开。
            guard !flags.contains(.command), !flags.contains(.control) else { return }
            // 悬停三键接管着、且这一下正落在某个键上:走播放控制,不弹面板。
            //
            // 分派放在这里(而不是让那一层自己收 mouseDown)是为了不动上面那三条既有手势:
            // ⌘拖拽换位置、右键/⌃左键弹完整菜单、普通左键按下即弹面板,全都靠"整项只有
            // 一个点击目标"成立(两个自绘层都 hitTest -> nil)。落在三个键之外照旧弹面板:
            // 槽比三个键宽,两侧那块空地本来就是"点开面板"的语义,让它变成死区只会让人
            // 以为点坏了。**开着「歌词旁的图标」时点那枚图标同样落在这条兜底上** —— 三个键
            // 只占歌词那一格(见 evaluateHoverEngagement 里 setSlot 那一行),图标那一块不在
            // 任何一个键的矩形里,不用为它单开分支(2026-09-03 用户要求"点击图标范围之后
            // 依旧是唤起面板")。
            // ⚠️ 点击位置**必须**从屏幕坐标换算,**不能**用 `event.locationInWindow`
            // (2026-09-03 实测坐实,用户报"点了暂停,实际是上一首")。同一次点击两条路的结果:
            //   viaEvent  = (72, 11)      —— 而且**连点两次恒为同一个值**,真实点击不可能
            //                                像素级相同,说明这个坐标根本不在 button.window
            //                                这个坐标系里(macOS 26 起菜单栏由 MenuBarAgent 托管)
            //   viaScreen = (83.5, 15.2)  —— 与指针实际位置一致
            // 差约 11.5pt,而每个键只有 24pt 宽 —— 正好够把"点暂停"判成"上一首"。
            // 屏幕坐标这条是仓库里被实战验证过的那条(悬浮歌词那排按钮的命中一直用它,见
            // LyricsOverlayWindowController:`window.convertPoint(fromScreen: NSEvent.mouseLocation)`)。
            // 拿不到 window 就不认这一下的控制键,落回下面弹面板 —— 按钮不在窗口里本来也点不着。
            let pointInButton = button.window.map {
                button.convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            }
            if let point = pointInButton, let control = hoverControls.control(at: point) {
                performTransportControl(control)
                return
            }
            panelController.toggle(relativeTo: button)
        default:
            break
        }
    }

    /// 把完整菜单按老样子弹出来:临时挂到 item.menu 上借 performClick 的原生弹出
    /// (位置/反白/键盘导航都是系统行为),弹完立刻摘掉,不然下次左键也变成菜单。
    private func popUpFullMenu() {
        guard let item = statusItem else { return }
        let menu = menuController.makeMenu(
            onHighlightChange: { [weak self] on in
                self?.scrollingLabel.setHighlighted(on)
                self?.liveIconView.setHighlighted(on)
                // 右键菜单是**可以**跟悬停接管同时在场的(指针停在这一项上按右键):反白
                // 蓝底上那三个字形也得跟着换成选中色,不然跟旁边的系统菜单项对不上。
                self?.hoverControls.setHighlighted(on)
            })
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - 悬停三键(2026-09-03)

    /// 指针在不在这一项上(由 MenuBarHoverControlsView 的 tracking area 上报)。
    private var hoverInside = false
    /// 正在接管中:歌词收掉、三个键画着、refresh() 早退。
    private var hoverControlsEngaged = false

    /// 进出都**不等**:指针一进来当场换成三个键,一离开当场变回歌词。
    ///
    /// ⚠️ 2026-09-03 第一版在进入这一侧压了 0.2s 的延时(照灵动岛 hover 展开那档
    /// `hoverEnterDelay` 0.12s 取的),理由是"菜单栏上路过比停下常见,指针横穿去点右边别的
    /// App 图标时会扫过这一项,不等一下就是歌词闪一下变三个键再闪回来"。用户实测后要求
    /// **去掉延迟**("我们这个悬浮上去目前有个延迟在变成控制键,帮我去掉延迟")——手感上
    /// "点得到才算数",慢半拍比偶尔闪一下更难受。所以这里不再有等待队列;横穿时会闪一下,
    /// 那是这条取舍换来的,别当 bug 修回去。
    private func handleHoverChange(_ inside: Bool) {
        hoverInside = inside
        evaluateHoverEngagement()
    }

    /// 现在到底该不该接管。所有进出接管态的路径都收口在这里(hover 进出、开关拨动、
    /// 面板开合),各自算一遍完整条件而不是各改一半状态。
    ///
    /// 五个条件缺一不可:
    ///  1. 指针在这一项上(不等待,见 handleHoverChange);
    ///  2. 用户开了这个开关;
    ///  3. 面板没开 —— 面板自己就有三键,而且状态栏这一项**就是那张 popover 的锚点视图**;
    ///  4. 当前是歌词形态(text/fixed)。图标形态不接管:那个槽只有 38pt 上下,三个键画不下,
    ///     而且那时候本来就没在放歌;
    ///  5. **歌词那一格**装得下三个键(见 MenuBarHoverControls.layout —— 自适应宽度模式下
    ///     一句 ♪ 的槽宽只有二三十点)。开着「歌词旁的图标」时这一格比整个按钮窄一截
    ///     (图标宽 + 5pt 间距),门槛按窄的那个算。
    ///
    /// ⚠️ 第 4、5 条合起来还有一个副作用值得知道:**暂停之后歌词槽会收成图标槽**(refresh()
    /// 里那道 lyricsActive guard,收缩延时 3s),所以"暂停 → 想再点播放"这条路只在指针
    /// 一直停在这一项上时才走得通 —— 接管期间 refresh() 早退,那次收缩根本不会发生,三个
    /// 键就停在原地等着。指针一离开,收缩才照旧进行。
    private func evaluateHoverEngagement() {
        // 先把"三个键该落在哪一格"喂进去,再判装不装得下 —— 顺序反了就是拿整个按钮的宽度去
        // 过门槛、结果画出一排压在图标上的键。**只在没接管时取**:接管期间几何是冻住的,
        // 没有重算的理由。
        if !hoverControlsEngaged { hoverControls.setSlot(currentLyricsSlot()) }
        let want = hoverInside
            && AppSettings.shared.menuBarHoverShowsControls
            && !panelIsOpen
            && (displayClass == "text" || displayClass == "fixed")
            && hoverControls.fitsControls
        guard want != hoverControlsEngaged else { return }
        hoverControlsEngaged = want
        // notice 级:跟上面那些 slot rebuild / panel 日志对同一条时间线 —— "歌词莫名不见了"
        // 这类反馈只有对上时间线才分得清是接管、是收缩、还是重建错位。
        logger.notice("hover controls \(want ? "engaged" : "released", privacy: .public) (class=\(self.displayClass, privacy: .public))")
        if want {
            hoverControls.setPlaying(PlaybackCoordinator.shared.isPlayingSmoothed)
            hideLyricsForHoverControls()
            hoverControls.setEngaged(true)
        } else {
            hoverControls.setEngaged(false)
            hoverControls.setSlot(nil)
            // 接管期间 refresh() 一直早退,歌词和几何都停在接管那一刻。这里补一次,把这段
            // 时间里换过的句子、被挡下来的槽宽变化一次性落地 —— 跟面板收起那一刻补一次
            // refresh() 是同一个模型(见 present 头注的 panelIsOpen 分支)。
            refresh()
        }
    }

    /// 歌词那一格在按钮里的位置(纵向给满)。三个键就排在这一格里。
    ///
    /// ⚠️ **从槽宽 `item.length` 反推,绝不问歌词层要**(2026-09-03 修 bug 时改的)。
    /// 歌词层那份几何按 `plan` 算,而 `plan` 是易失的:悬停接管时被清一次(只留图标)、
    /// 暂停收成图标那条路又清一次;偏偏 `displayClass` 因为重建节流还停在陈旧的 `"fixed"`,
    /// 于是"该不该接管"说是、"歌词格在哪"却答不上来,退回整个按钮居中 —— 三个键的位置
    /// 就在两套之间跳(实测 `48.5/72.5/96.5` ↔ `36/60/84`,差 12.5pt 正好够点到隔壁键,
    /// 用户报的"点了暂停,生效的是上一首")。槽宽是这一项的硬事实,只有重建才变,而重建
    /// 期间本来就不接管。算式与歌词层摆图层共用一份,在 `MenuBarHoverControls.lyricsSlot`。
    ///
    /// `item.length - fixedSlotPadding` 这个反推口径跟 `renderInterimLyrics` 里那条一致
    /// (那边也是从当前槽宽反推歌词能用多宽)。
    private func currentLyricsSlot() -> CGRect? {
        guard let item = statusItem, let button = item.button else { return nil }
        let icon = lyricsIconBadge()
        guard let slot = MenuBarHoverControls.lyricsSlot(
            buttonWidth: button.bounds.width,
            contentWidth: item.length - Self.fixedSlotPadding,
            reservedIconWidth: MenuBarProgressIcon.reservedWidth(for: icon?.style),
            iconLeading: icon?.position == .leading)
        else { return nil }
        // 纵向给满:22pt 高的菜单栏里再按行高抠掉上下各 2pt,只会让人觉得"边上点不中"。
        return CGRect(x: slot.x, y: button.bounds.minY,
                      width: slot.width, height: button.bounds.height)
    }

    /// 接管那一刻把歌词收掉。**只碰内容,一点不碰几何**:槽宽(item.length)、按钮上那张
    /// 撑宽度的透明占位图都原样留着 —— 否则 hover 一进一出就是连发两次状态栏项重建,正撞
    /// present 头注第 2 条铁律(两次重建相隔 ~1s 会把邻居的**像素**晾在旧位置且不自愈)。
    private func hideLyricsForHoverControls() {
        // ⚠️ 开着「歌词旁的图标」时只收歌词、**把图标留在原地**(2026-09-03 用户要求:"如果有
        // 开启左右侧图标的话,悬浮之后图标依旧保留,只是歌词部分变为控制键")。那枚图标就画在
        // scrollingLabel 自己的图层上,`clear()` 会连它一起抹掉 —— 这也正是刚接上时它会跟着
        // 歌词一起消失的原因。判据读**这一层的实际状态**而不是设置值:设置刚改完、还没走到
        // 重画时两者会短暂不一致。
        if scrollingLabel.showsIconBadge {
            scrollingLabel.clearLyricsKeepingIcon()
        } else {
            scrollingLabel.clear()
        }
        liveIconView.clear()
        // 退化路径(showStaticText)的文字是**按钮自己**画的,不清掉会跟三个键叠在一起。
        // 两条都要清:attributedTitle 是自定义文字色那一支设的,title 是没设自定义色那一支。
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.button?.title = ""
        // toolTip 刻意不动:它挂的是完整这一行歌词,"想读全文就悬停"这条出路照旧;而且
        // NSView.toolTip 的 setter 会自己偷偷装一个 tracking area(见
        // MenuBarPanelQuickSettings 里那段实测),在 hover 这条高频路径上反复置空再设回来
        // 等于反复动 tracking 机制,不值当。
    }

    /// 悬停三键点下去干什么。跟悬浮歌词那排按钮逐字同一套语义:
    ///  - 播放/暂停走 PlaybackCoordinator 的**乐观回声版**(见 userTogglePlayPause),不直接
    ///    调 MusicPlaybackController.playPause();
    ///  - 三个动作都套"点了才校验权限"的守卫。
    private func performTransportControl(_ control: MenuBarTransportControl) {
        switch control {
        case .previous: withMusicPermission { MusicPlaybackController.previousTrack() }
        case .playPause: withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
        case .next: withMusicPermission { MusicPlaybackController.nextTrack() }
        }
    }

    /// "点了才校验权限":没问过就顺手弹一次系统授权对话框,已经拒绝过就 NSSound.beep() 给
    /// 一个"没有生效"的听觉反馈。必须用异步版 checkForCurrentPlayerSafely(同步版可能永久
    /// 挂起主线程,坑在它定义处)。
    ///
    /// ⚠️ 这已经是这段守卫的第四份(另三份在 LyricsOverlayWindowController.withMusicPermission、
    /// NotchLyricsView.controlButton、GlobalHotkeys)。抽成公共函数要同时动那三个文件、且它们
    /// 各自的 Task 隔离标注不同,不在这次改动的范围里 —— 记一笔,下次碰到这三处之一时一起收。
    private func withMusicPermission(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                NSSound.beep()
                return
            }
            action()
        }
    }

    // MARK: - 决定现在该显示什么

    private func refresh() {
        guard started else { return }
        // 悬停三键接管期间**什么都不动**。下面三条展示路径(showIcon / showStaticText /
        // showFixedWidth)都会无条件把另一个子层 clear 掉、重设 button.image/title ——
        // 而 refresh() 被十几条订阅高频调用(换句、开关、颜色、字重字号、播放状态…),
        // 不早退的话换一句歌词就把三个键冲掉了。
        //
        // 歌词和几何都停在接管那一刻,退出接管时 evaluateHoverEngagement 补一次 refresh()
        // 把这段时间的变化一次性落地(跟面板开着期间挡下几何变化同一个模型)。
        // ⚠️ 中间那个键的 ⏸/▶ 不靠这条路更新 —— 它有自己的订阅(isPlayingSmoothed)。
        guard !hoverControlsEngaged else { return }
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared
        // 单行展示面取 compactLine(唱完就切走,见 CompactLyricLead)。
        //
        // ⚠️ 长间奏中段 compactLine 是 nil,这里**必须**给一个非空的 ♪ 而不是空串:空串会
        // 落进下面那条 `guard ... lyricsActive` 把整个歌词槽收回成小图标(一次状态项重建),
        // 而长间奏动辄十几秒 —— 表现就是菜单栏歌词塌掉、过一会儿又弹回来。给 ♪ 则槽位留着,
        // 视觉上也跟灵动岛那边的占位一致。
        let text = coordinator.compactLine?.plainText
            ?? (coordinator.compactShowsPlaceholder ? MenuBarMarqueeRenderer.placeholderGlyph : "")
        let lyricsActive = coordinator.isPlayingNow && !text.isEmpty

        // 没开菜单栏歌词 / 没在播放 / 当前句为空:收回小图标槽。槽宽 = 当前图标款式的
        // 图宽 + 系统内边距,跟歌词态同一套"出生就带显式宽度"规则(2026-08-19 第五轮:
        // variableLength + 图片事后设 = 踩"出生后不重排",收不回去留大缺口)。
        //
        // 收缩观察窗只给"开关开着但此刻没词"(歌词间隙/暂停/广告,常在 1~2s 内结束);
        // 用户手动关开关是明确意图,立刻缩回(仍受重建静默节流保护)。
        guard settings.showLyricsInMenuBar, lyricsActive else {
            let iconWidth = MenuBarIconStyle.cachedImage(for: settings.menuBarIconStyle).size.width
            present(class: "icon", length: iconWidth + Self.fixedSlotPadding,
                    collapseDelay: settings.showLyricsInMenuBar ? Self.rebuildQuietSecs : 0) {
                showIcon($0)
            }
            return
        }
        // "装得下还是要滚"这个判定跟设置页那条预览共用同一个函数,两边不可能漂 ——
        // 见 MenuBarMarqueeRenderer.Presentation。
        switch MenuBarMarqueeRenderer.presentation(
            for: text,
            windowWidth: settings.menuBarLyricsWidth,
            // 让长句子在换到下一句之前滚完,而不是永远按固定速度爬。
            // compactDwellSeconds 而不是 currentLineDwellSeconds:显示窗口变了(唱完就
            // 切走),用旧口径会把 dwell 算大 —— 长句后面接长间奏时按偏大的 dwell 配速,
            // 句子会在只滚出开头一小截时就被换掉,比改动前更糟。见 CompactLyricLead
            // .displayDurationMs。
            dwellSeconds: coordinator.compactDwellSeconds,
            // 提前量窗口里这一句已经显示、但还没开唱(所以也还没染色)——滚动得等它走完
            // 才准起步,否则就是用户 2026-08-24 报的"还没染色就已经在滚"。
            leadInSeconds: coordinator.compactLeadInSeconds,
            widthMode: settings.menuBarLyricsWidthMode
        ) {
        case .text(let visible):
            // 自适应态:槽宽跟着这一句的文字宽走 —— 每次变宽都是一次重建
            // (macOS 26 下这是唯一能让邻居让位的做法,见 present 头注)。
            //
            // visible != text 只发生在 windowWidth<=0 的截断退化路径 —— 那里既不染色也不
            // 画图标(格子小到画不出来),所以 icon 直接跟着这个条件取 nil,槽宽自然也不会
            // 白让出一块空地。
            let icon = visible == text ? lyricsIconBadge() : nil
            let reserved = MenuBarProgressIcon.reservedWidth(for: icon?.style)
            let textW = MenuBarMarqueeRenderer.width(of: visible)
            let w = textW + reserved + Self.fixedSlotPadding
            let fillPath = visible == text ? karaokeFillPath(for: text) : nil
            if fillPath != nil || icon != nil {
                // 逐字染色画不进 button.title(那条路是 AppKit 自绘的单色文字,没有图层
                // 可以叠强调色) —— 改走图层渲染,窗口宽就取文字自身宽:槽宽公式跟上面
                // 完全一致,footprint 逐像素不变,只是画的人从按钮换成了 scrollingLabel。
                // ⚠️ 2026-09-03 起**进度图标也走这条岔路**,理由一模一样:一枚要按进度
                // 半染色的图标同样塞不进 button.title/image 那条 AppKit 自绘的路。
                present(class: "text", length: w, collapseDelay: 0,
                        dwellSeconds: coordinator.compactDwellSeconds,
                        interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                    showFixedWidth($0, text: text, windowWidth: textW,
                                   pacing: nil, fillPath: fillPath, icon: icon)
                }
            } else {
                present(class: "text", length: w, collapseDelay: 0,
                        dwellSeconds: coordinator.compactDwellSeconds,
                        interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                    showStaticText($0, visible: visible, full: text)
                }
            }
        case .fixed(let lineText, let windowWidth, let pacing):
            let icon = lyricsIconBadge()
            let slotWidth = windowWidth + MenuBarProgressIcon.reservedWidth(for: icon?.style)
            present(class: "fixed", length: slotWidth + Self.fixedSlotPadding, collapseDelay: 0,
                    dwellSeconds: coordinator.compactDwellSeconds,
                    interim: { [weak self] in self?.renderInterimLyrics($0, text: text) }) {
                showFixedWidth($0, text: lineText, windowWidth: windowWidth, pacing: pacing,
                               fillPath: karaokeFillPath(for: lineText), icon: icon)
            }
        }
    }

    /// 几何变化被推迟期间的过渡渲染:把**最新**这句歌词按当前(还没变的)槽宽画出来,
    /// 让内容永远实时、只有槽宽在等静默窗。装得下→居中静止;装不下→在当前槽里滚。
    /// 只在当前已是歌词槽(text/fixed)时有意义 —— 当前是图标槽(38pt)时不硬塞:
    /// 20pt 的窗里滚歌词只会闪成一条缝,保持图标到重建(首句最多晚一个静默窗,只发生
    /// 在"收缩后 3s 内歌词又回来"的边缘场景)。
    private func renderInterimLyrics(_ button: NSStatusBarButton, text: String) {
        guard displayClass == "text" || displayClass == "fixed", let item = statusItem else { return }
        // 图标占的那一块要先扣掉:item.length 是**当前**(还没让改的)槽宽,歌词能用的只有
        // 剩下那截。扣错的方向是安全的那一侧 —— 用户刚打开这个开关时当前槽还没让出图标的
        // 位置,这里扣了之后歌词只是画窄一点点,总比画出格子外压到邻居头上强。
        let icon = lyricsIconBadge()
        let usable = item.length - Self.fixedSlotPadding
            - MenuBarProgressIcon.reservedWidth(for: icon?.style)
        guard usable > 0 else { return }
        // widthMode 固定传 .fixed:过渡期间槽宽就是钉死的(它正是"还没让改"的那个宽),
        // 按固定宽语义排版;等重建后 refresh 会按用户真实的模式/宽度重画。
        switch MenuBarMarqueeRenderer.presentation(
            for: text, windowWidth: usable,
            dwellSeconds: PlaybackCoordinator.shared.compactDwellSeconds,
            // 过渡渲染画的是同一句,提前量口径也必须同一份 —— 这里给 0 的话,几何推迟期间
            // (自适应模式下逐句都有,最多 3s)那一句又会在开唱前先滚起来。
            leadInSeconds: PlaybackCoordinator.shared.compactLeadInSeconds,
            widthMode: .fixed
        ) {
        case .text(let visible):
            showStaticText(button, visible: visible, full: text)
        case .fixed(let lineText, let win, let pacing):
            // 过渡渲染同样带上填色和图标 —— 自适应模式逐句都有一段几何推迟窗(最多 3s),
            // 不带的话每句开头 3 秒都没有染色/没有图标,槽宽落地那一刻才突然冒出来。
            showFixedWidth(button, text: lineText, windowWidth: win, pacing: pacing,
                           fillPath: karaokeFillPath(for: lineText), icon: icon)
        }
    }

    /// 没开菜单栏歌词 / 没在播放 / 还没解析出这一句:图标(槽位由 showIconSlot 管,
    /// 这里只管内容)。静态图靠按钮自己居中,活体渲染靠 MenuBarLiveIconView.layout()
    /// 按 bounds 居中,两条路都天然适应槽宽。
    /// 「随播放律动」开着且正在播放时走活体渲染:按钮里只放一张撑尺寸的透明占位图
    /// (footprint 跟静态款逐像素一致),真身画在 liveIconView 的图层上,动画全部
    /// 交给 Core Animation(见 MenuBarLiveIconView 头注)。其余情况就是一张静态模板图。
    private func showIcon(_ button: NSStatusBarButton) {
        scrollingLabel.clear()
        let settings = AppSettings.shared
        let style = settings.menuBarIconStyle
        let staticImage = MenuBarIconStyle.cachedImage(for: style)
        if settings.menuBarIconAnimates, PlaybackCoordinator.shared.isPlayingNow {
            button.image = spacerImage(width: staticImage.size.width,
                                       height: staticImage.size.height)
            liveIconView.frame = button.bounds
            liveIconView.present(style: style)
        } else {
            liveIconView.clear()
            button.image = staticImage
        }
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = nil
        button.setAccessibilityLabel(L10n.t("Lyrimuse"))
    }

    /// 退化路径:宽度被设成 0 或更小,画不出格子,交给按钮自己画一段截断文字。
    /// 正常情况走不到这里(滑杆下限 80pt),留着是不想让极端配置变成一块空白。
    private func showStaticText(_ button: NSStatusBarButton, visible: String, full: String) {
        scrollingLabel.clear()
        liveIconView.clear()
        button.image = nil
        // imagePosition 是按钮上的**持久**属性,滚动那条路会把它设成 .imageOnly(那边靠
        // 一张透明占位图撑宽度、文字画在图层上),这里显式改回来,让"这一模式只有文字"
        // 这件事写在代码里,而不是靠别处的残留值。
        //
        // ⚠️ 老实说一句:实测(2026-08-16 离线位图探针,逐像素数非透明占比)**不改也能画出
        // 文字** —— image 为 nil 时 AppKit 会无视 .imageOnly 照样画 title,两种写法的
        // 渲染结果和按钮宽度完全一样。所以这一行不是在修一个看得见的 bug,是不想把
        // "两个模式之间靠遗留状态碰巧对上"这件事留在代码里。
        button.imagePosition = .noImage
        // 自定义文字颜色走 attributedTitle(button.title 由 AppKit 按系统外观自动上色,
        // 塞不进自定义色);没自定义就设 title —— 它会顺带清掉之前可能设过的富文本,
        // 两种写法互相收拾干净,不靠遗留状态。
        // 字重随设置走,且按这段文字取(占位符 ♪ 恒默认字重,见 MenuBarMarqueeRenderer.font(for:));
        // attachButtonChrome 里那一次赋值只是出生值,这里每次显示都重设,换粗细才能立刻生效。
        button.font = MenuBarMarqueeRenderer.font(for: visible)
        let textHex = AppSettings.shared.menuBarLyricsTextColorHex
        if textHex.isEmpty {
            button.title = visible
        } else {
            button.attributedTitle = NSAttributedString(string: visible, attributes: [
                .font: MenuBarMarqueeRenderer.font(for: visible),
                .foregroundColor: NSColor(Color(hexWithAlpha: textHex,
                                                fallback: Color(nsColor: .labelColor))),
            ])
        }
        // tooltip 始终给完整这一行:"想看全文就悬停"这条出路在三种模式下都在。
        button.toolTip = full
        button.setAccessibilityLabel(full)
    }

    /// 正常路径:这一格恒占 windowWidth,文字画在图层上。装得下就静止(pacing == nil),
    /// 装不下就交给 Core Animation 滚。
    ///
    /// ⚠️ 装得下的句子**也**走这里,不走 button.title —— 这正是"固定宽度"的实现点。
    /// button.title 那条路的宽度跟着文字走(实测同一首歌连着三句是 231/145/207pt),
    /// 长短句来回切时菜单栏项就会伸缩、把右边的图标顶得左右晃(2026-08-17 用户反馈)。
    private func showFixedWidth(_ button: NSStatusBarButton, text: String, windowWidth: CGFloat,
                                pacing: MenuBarMarquee.ScrollPacing?,
                                fillPath: [MenuBarMarquee.KaraokeFillPoint]? = nil,
                                icon: MenuBarScrollingLabel.IconBadge? = nil) {
        liveIconView.clear()
        // ⚠️ 这张**全透明**的占位图是整个固定宽度方案的支点,不是残留:variableLength 的
        // 状态栏项按 button.image 的尺寸算自己该占多宽。给它一张宽度恒为 windowWidth 的
        // 空图,这一项的 footprint 就跟内容彻底脱钩了,而且不用去猜系统给状态栏按钮留了
        // 多少内边距(那是算不出来的,只能让 AppKit 自己算)。
        // 图本身没有任何像素,画上去什么都看不见,真正的文字在 scrollingLabel 那一层。
        // 图标占的那一块也算进占位图:这一项的可视内容是"图标 + 间距 + 歌词格"整块,
        // 占位图要跟它一样宽,才不会在按钮里画偏(槽宽那边加的是同一个数,见 refresh)。
        button.image = spacerImage(
            width: windowWidth + MenuBarProgressIcon.reservedWidth(for: icon?.style),
            height: MenuBarMarqueeRenderer.lineHeight)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = text
        // 图层上的文字读屏软件读不到,这里显式补上这一行歌词。
        button.setAccessibilityLabel(text)

        scrollingLabel.frame = button.bounds
        scrollingLabel.present(text: text, windowWidth: windowWidth, pacing: pacing,
                               fillPath: fillPath, icon: icon)
        // 换句后立刻对一次表,填色从此刻的真实播放位置起步,不等下一次锚点更新(~2s)。
        if fillPath != nil { syncKaraokeClock(force: true) }
        // 进度图标同理:重排位图会把裁剪层的几何重设,不立刻对表的话它会停在 0 直到下一次
        // 锚点更新。force 是因为位置往往一点没变(换句而已),过不了漂移门。
        if icon != nil { syncProgressClock(force: true) }
    }

    private func spacerImage(width: CGFloat, height: CGFloat) -> NSImage {
        let size = NSSize(width: ceil(width), height: ceil(height))
        if let spacer, spacer.size == size { return spacer.image }
        // drawingHandler 里什么都不画,只 return true —— 得到的是一张有正确尺寸、
        // 但完全透明的图。
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        spacer = (size, image)
        return image
    }
}
