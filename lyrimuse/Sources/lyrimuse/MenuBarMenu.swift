import SwiftUI
import AppKit

// 状态栏兜底图标——正式 App 图标(音符+三条歌词横线)的简笔剪影版,不是系统 SF Symbol。
// 不能直接把正式图标(带渐变背景/高光/阴影)缩小塞进状态栏——那样会糊成一团色块。
// 状态栏图标用纯剪影(`isTemplate = true`),系统会自动按明暗/悬停状态重新上色,不需要
// 分别做浅色/深色两份。这份 PNG(Resources/MenuBarIconTemplate.png)是照同一比例重新
// 画的矢量线稿,不是从正式图标里抠像素抠出来的——正式图标背景是浅粉/浅橙渐变,跟白色
// 符干很接近,直接阈值抠图边缘会发虚。
private let menuBarIconImage: NSImage = {
    // 用 Bundle.main 而不是 Bundle.module——SwiftPM 生成的 Bundle.module 访问器在别的
    // 机器上会直接 fatalError 崩溃(原因见 L10n.swift 顶部注释)。这份 PNG 由 build.sh
    // 直接拷进 Contents/Resources/。
    guard let path = Bundle.main.path(forResource: "MenuBarIconTemplate", ofType: "png"),
          let image = NSImage(contentsOfFile: path) else {
        // 找不到就退回系统符号兜底,不让状态栏图标位置裸奔成空白——正常情况下这个
        // 分支不会走到,build.sh 已经把这份 PNG 拷进 Contents/Resources/ 了,跟
        // Localizable.strings 是同一套查找路径。
        return NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) ?? NSImage()
    }
    image.isTemplate = true
    return image
}()

// 状态栏图标本体(MenuBarExtra 的 label)——设置里关掉、没在播放、或者还没解析出这一句
// 歌词时,退回固定的图标+文字;都满足时直接显示当前这一行,上限可以在设置里调
// (settings.menuBarLyricsMaxChars,见「歌词」tab「展示」分组)。
struct MenuBarLabel: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = PlaybackCoordinator.shared
    @ObservedObject private var marquee = MenuBarMarqueeTicker.shared
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        Group {
            if settings.showLyricsInMenuBar,
               coordinator.isPlayingNow,
               let text = coordinator.currentLine?.plainText,
               !text.isEmpty {
                // 状态栏空间有限,不能像悬浮窗那样自动换行。超宽时默认横向滚动(跑马灯,
                // 见 MenuBarMarqueeTicker;设置里可关,关掉就退回截断加省略号)——两种模式
                // 下真正显示哪一段都由 ticker 算好发布,这里只渲染。tooltip 始终给完整
                // 这一行,滚动/截断都不影响"想看全文就悬停"这条既有出路。
                Text(marquee.visibleText.isEmpty ? text : marquee.visibleText).help(text)
            } else {
                Label {
                    Text(L10n.t("Lyrimuse"))
                } icon: {
                    Image(nsImage: menuBarIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
            }
        }
        // label: 是 MenuBarExtra 真正常驻状态栏的部分,整个 App 运行期间只挂载一次
        // (不像 content: 那样只在点开菜单时才有内容),是"从非 View 上下文触发 SwiftUI
        // 环境 action"(见 AppActions.swift)这个问题里唯一确定只跑一次的挂载点。
        // accessory 策略(没有 Dock 图标)下,不先手动激活 App,openSettings()/
        // openWindow(id:) 都会静默没反应,跟 MenuBarMenu 里"设置…"按钮的写法一致。
        .onAppear {
            AppActions.shared.openSettings = {
                NSApp.activate(ignoringOtherApps: true)
                openSettingsAction()
            }
            AppActions.shared.openLyricsManager = {
                NSApp.activate(ignoringOtherApps: true)
                openWindowAction(id: "lyrics-manager")
            }
            AppActions.shared.openLyricsWindow = {
                NSApp.activate(ignoringOtherApps: true)
                openWindowAction(id: "lyrics-window")
            }
            AppActions.shared.openOnboarding = {
                NSApp.activate(ignoringOtherApps: true)
                openWindowAction(id: "onboarding")
            }
            // 首次启动的完整引导向导——放在这里而不是 AppDelegate.
            // applicationDidFinishLaunching 里直接调用,是因为 openWindow(id:) 这个
            // SwiftUI 环境 action 只有在某个 View 的挂载点才能拿到;AppDelegate 那个
            // 时机早于 MenuBarExtra 的 label 真正挂载,这时候调用会静默没反应。这个
            // onAppear 本身就是"整个 App 生命周期内确定只跑一次"的挂载点,直接在这里
            // 判断+打开,不需要再绕一层。
            //
            // 坑:直接在这个 onAppear 里同步调 NSApp.activate+openWindow 完全不生效——
            // 这一刻是启动过程里最早的时间点之一,系统还没走完 accessory 策略 App
            // 真正"启动完成"的流程,两个调用本身不报错,但窗口要么没建出来、要么建出来
            // 立刻被吞掉,肉眼看不到。"设置…"/"歌词管理…"这两个菜单按钮没踩到这个坑,
            // 是因为它们永远是用户手动点出来的、那时候 App 早已完全启动稳定。加一个
            // 不长的延迟,让启动流程先跑完再发起,就能稳定弹出来。
            if !settings.hasCompletedOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // 换电脑这条路先走一步:iCloud 里已经有配置就先问要不要导入,导入了
                    // 就重启(引导在重启之后照样走,理由见 ICloudConfigImportPrompt);
                    // 没有/跳过/还没下载好就原样走引导。
                    ICloudConfigImportPrompt.offerIfNeeded {
                        AppActions.shared.openOnboarding?()
                    }
                }
            }
        }
    }

}

struct MenuBarMenu: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // .labelStyle(.titleAndIcon) 套在最外层 Group 上,靠 SwiftUI 环境值沿子视图树
        // 一路往下传(包括下面几个独立 View 里的 Label)——实测坐实:这个菜单栏下拉菜单
        // 默认不会显示 Label 的图标(只显示文字),不加这一句图标会整个消失,不是漏写了
        // 某个具体图标名。
        Group {
        // 四种展示方式互不排斥,菜单里"显示…"开关都常驻——2026-08-05 把
        // "这个模式开没开"合并成单一开关之后,这两项就是那个开关本身,不能再拿它自己当
        // 显示条件:那样从菜单栏关掉之后这一项会跟着从菜单里消失,再也找不到打开的入口。
        //
        // 常驻的前提是它们的 get 只读 AppSettings、完全不碰 WindowController:两个控制器
        // 都是 `static let shared`,真正引用到才会执行 init() 建窗口,而 init() 里订阅
        // PlaybackCoordinator 的 Combine sink 在订阅瞬间就会按当下的 isVisible 显示/隐藏
        // 一次——菜单每次开合都会重新构造这些 View,get 里碰 .shared 就等于"点开一次菜单
        // 就把没启用的窗口也建出来"(详见 NotchLyricsWindowController 顶部注释)。set 里
        // 碰是可以的:那是用户主动在打开/关闭这个模式。
        // 2026-08-06:四个状态开关收进一个二级子菜单,顶层只留"点一下就发生一件事"的动作
        // 入口。原来开关和动作混在顶层、靠两条分隔线分区,菜单一共十一项、相当长;收起来
        // 之后顶层短得多,而"从菜单栏快速开关悬浮歌词"这个用法也没丢(多一层展开)。
        //
        // ⚠️ "锁定位置"仍然只在经典悬浮窗开着时才出现:它的 get 必须读控制器自己的
        // isPositionLocked(不是 AppSettings),而 SwiftUI 的 if 只构建条件为真的分支,
        // 关着时连 .shared 都不碰——这条不变量在子菜单里同样要守(详见
        // NotchLyricsWindowController 顶部注释)。
        Menu {
            DisplayModeMenuToggles()
            if settings.classicOverlayEnabled {
                ClassicOverlayLockMenuSection()
            }
            Divider()
            Toggle(isOn: $settings.launchAtLoginEnabled) {
                Label(L10n.t("开机启动"), systemImage: "power")
            }
        } label: {
            Label(L10n.t("快速开关"), systemImage: "switch.2")
        }
        // 跟悬浮窗样式(经典/灵动岛)正交——校准的是"当前这首歌的歌词该提前/延后多少",
        // 不管哪种样式在显示都适用,所以不收进上面那个"快速开关"子菜单:它是一组带子菜单的
        // 增减操作,不是开关。
        LyricsOffsetMenuSection()
        Divider()
        // 不用 SettingsLink——这个 App 是 .accessory 策略(没有 Dock 图标/常规激活),
        // SettingsLink 内部触发设置窗口时依赖应用正常激活的那套机制,在 accessory 策略下
        // 实测点了没反应(窗口没弹出来,不是被挡住)。改成手动先激活 App 再调
        // openSettings(),激活这一步是关键,少了这步同样打不开。
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            Label(L10n.t("设置…"), systemImage: "gearshape")
        }
        // 跟"设置…"同一个坑:accessory 策略(没有 Dock 图标)下打开任何新窗口都得先
        // 手动激活 App,不然 openWindow 调了也没反应。
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "lyrics-manager")
        } label: {
            Label(L10n.t("歌词管理…"), systemImage: "music.note.list")
        }
        // 「歌词窗口」跟上面两项各自单成一组:上面是"配置/管理"(改设置、整理歌词库),
        // 它是"看歌词"本身 —— 手上正在做的事不一样,不该看起来像同一串。
        Divider()
        // 2026-08-14 挪回顶层,并从 Toggle 改回普通菜单项。
        //
        // 2026-08-06 曾把它放进「快速开关」子菜单,理由是"它是四种歌词展示方式之一"。那个
        // 归类站不住:另外三种背后都有 AppSettings 里的持久化布尔(classicOverlayEnabled /
        // notchOverlayEnabled / showLyricsInMenuBar),是"常驻显示形态";而歌词窗口一个都
        // 没有 —— 它就是一扇 Window(id:),跟正上方的"歌词管理…"完全同构。把一扇窗口包装
        // 成开关,还要为此常驻一个观测窗口开合的单例(LyricsWindowPresence,已随之删除),
        // 是拿复杂度换了一个误导性的外观。
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "lyrics-window")
        } label: {
            Label(L10n.t("歌词窗口…"), systemImage: "text.quote")
        }
        // 单独一条分隔线,把上面"打开某个窗口做配置/管理"这两项,跟下面"检查更新/关于"
        // 这类"了解一下这个 App 本身"的入口分开——原来四项挤在一起没有区分,看着乱
        // (2026-07-30 用户反馈),跟上面"开机启动"单独一组同一个分区原则。
        Divider()
        // 跟"设置…"/"歌词管理…"同一个坑:.accessory 策略下 Sparkle 弹出的检查更新
        // UI 也得先手动激活 App,不然点了没反应(这里没有活跃窗口打底,不像"关于"页
        // 那个按钮——那边是在已经打开的设置窗口里点,App 早就是激活状态,不需要这一步)。
        Button {
            NSApp.activate(ignoringOtherApps: true)
            SparkleUpdaterManager.shared.checkForUpdates()
        } label: {
            Label(L10n.t("检查更新…"), systemImage: "arrow.triangle.2.circlepath")
        }
        // 跟"设置…"同一个坑,同一个解法:先激活 App 再打开——直接跳到设置窗口的
        // "关于"分类,复用 Onboarding 的 Last.fm 步骤已经在用的同一套一次性信箱
        // (AppActions.pendingSettingsSelection,见该文件注释),不用再点一次侧边栏。
        // 引导现在可以重来:关窗算"稍后",而走完的人后来想重新配一遍(换了播放器、
        // 服务被自己关掉了、想重新给权限)也得有入口。没有这个入口的话,上面那条
        // "关窗不算完成"就只是把死路换了个地方 —— 走完的人依然回不去。
        //
        // 不用在这里 NSApp.activate:openOnboarding 这个闭包自己第一句就是激活
        // (见本文件上方 AppActions.shared.openOnboarding 的注册处)。
        Button {
            AppActions.shared.openOnboarding?()
        } label: {
            Label(L10n.t("重新运行引导…"), systemImage: "sparkles")
        }
        Button {
            NSApp.activate(ignoringOtherApps: true)
            AppActions.shared.pendingSettingsSelection = .tab(.about)
            openSettings()
        } label: {
            Label(L10n.t("关于 Lyrimuse"), systemImage: "info.circle")
        }
        Divider()
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label(L10n.t("退出 Lyrimuse"), systemImage: "rectangle.portrait.and.arrow.right")
        }
        } // Group
        .labelStyle(.titleAndIcon)
    }
}

// 两种悬浮歌词的"显示…"开关,常驻。get 只读 AppSettings 里那个唯一的开关、不持有任何
// WindowController(理由见 MenuBarMenu.body 里那段注释);set 统一走各自控制器的
// setVisible(_:) —— 那是打开/关闭一种悬浮歌词的唯一入口,连"顺手把已配置好的隐藏偏好
// 也应用上"这一步都在那里面,菜单/设置页/全局快捷键三处不各自复制一遍。
private struct DisplayModeMenuToggles: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.classicOverlayEnabled },
            set: { LyricsOverlayWindowController.shared.setVisible($0) }
        )) {
            Label(L10n.t("显示桌面悬浮歌词"), systemImage: "captions.bubble")
        }
        Toggle(isOn: Binding(
            get: { settings.notchOverlayEnabled },
            set: { NotchLyricsWindowController.shared.setVisible($0) }
        )) {
            Label(L10n.t("显示灵动岛歌词"), systemImage: "rectangle.topthird.inset.filled")
        }
        // 菜单栏歌词跟上面两个不一样:它没有独立的 WindowController(就画在状态栏那一行
        // 文字上),所以直接绑 AppSettings 那个布尔值就够,不需要 setVisible 那一套
        // "写回开关 + 顺手应用隐藏偏好"的处理。
        Toggle(isOn: $settings.showLyricsInMenuBar) {
            Label(L10n.t("显示菜单栏歌词"), systemImage: "menubar.rectangle")
        }
        // 这里只放**有持久化布尔值的常驻显示形态**。"歌词窗口"2026-08-14 移出去了:它没有
        // 持久化开关,是一扇 Window(id:),现在跟"歌词管理…"一样在顶层用普通菜单项打开。
    }
}

// "锁定位置"——只有经典悬浮窗有这个概念(灵动岛的位置是算出来的、贴死在屏幕顶部,见
// NotchLyricsWindow 里 isMovableByWindowBackground = false 那段注释)。持有
// LyricsOverlayWindowController.shared 的部分收窄到这一个子 View,由调用处的
// `if settings.classicOverlayEnabled` 保证经典悬浮窗关着时它连初始化都不会跑。
private struct ClassicOverlayLockMenuSection: View {
    @ObservedObject private var overlay = LyricsOverlayWindowController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { overlay.isPositionLocked },
            set: { newValue in
                settings.lockPosition = newValue
                overlay.setLocked(newValue)
            }
        )) {
            // 图标跟着锁定状态动态换(锁上/打开),不是固定图标——跟"关于"tab 里状态图标
            // 那套"用图标本身表达当前状态"的做法一致。
            Label(L10n.t("锁定位置"), systemImage: overlay.isPositionLocked ? "lock.fill" : "lock.open.fill")
        }
    }
}

// 单曲歌词时间轴微调——针对"当前正在播的这首歌",往前/往后校准歌词跟人声的对齐,
// 校准值按歌曲记忆(LyricsOffsetStore),下次再放这首歌自动生效。没有任何曲目信息
// (title 是空字符串,从未播过任何 Apple Music 曲目)时整个 Section 不显示,不留一个
// 点了也没意义的死菜单项。
private struct LyricsOffsetMenuSection: View {
    @ObservedObject private var coordinator = PlaybackCoordinator.shared
    // 步长现在是用户在设置里可调的值(AppSettings.lyricsOffsetStepMs),不是写死的
    // 常量——两个按钮的文案跟着这个值动态拼,不能再用一句固定的本地化字符串。
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if !coordinator.title.isEmpty {
            Menu {
                Button {
                    coordinator.nudgeLyricsOffset(by: settings.lyricsOffsetStepMs)
                } label: {
                    Label(nudgeLabel(L10n.t("提前")), systemImage: "gobackward")
                }
                Button {
                    coordinator.nudgeLyricsOffset(by: -settings.lyricsOffsetStepMs)
                } label: {
                    Label(nudgeLabel(L10n.t("延后")), systemImage: "goforward")
                }
                if coordinator.currentLyricsOffsetMs != 0 {
                    Divider()
                    Button {
                        coordinator.resetLyricsOffset()
                    } label: {
                        Label(L10n.t("重置"), systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                Label(menuTitle, systemImage: "timer")
            }
        }
    }

    private func nudgeLabel(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: settings.lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    // 菜单标题里直接带上当前校准值(比如"歌词时间轴(+0.6s)"),不用另开一个 HUD 或者
    // 禁用态文字行专门显示这个数字——这个菜单本来就是"想调的时候才点开看"的入口,标题
    // 本身就是最省事的展示位置。
    private var menuTitle: String {
        let ms = coordinator.currentLyricsOffsetMs
        guard ms != 0 else { return L10n.t("歌词时间轴") }
        // 跟两个按钮共用同一份格式化(AppSettings.formattedSeconds)——不然步长设成
        // 比如 0.15s 时,按钮显示"0.15"、这里的累计值却按 %.1f 四舍五入成"0.2",两处
        // 数字风格对不上。
        let sign = ms > 0 ? "+" : ""
        return "\(L10n.t("歌词时间轴"))(\(sign)\(AppSettings.formattedSeconds(ms: ms))s)"
    }
}
