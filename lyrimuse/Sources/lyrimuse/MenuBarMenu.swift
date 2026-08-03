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
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        Group {
            if settings.showLyricsInMenuBar,
               coordinator.isPlayingNow,
               let text = coordinator.currentLine?.plainText,
               !text.isEmpty {
                // 状态栏空间有限,截断是必须的,不能像悬浮窗那样直接自动换行——但截断不该等于
                // "看不到剩下的部分",鼠标悬停时用系统原生 tooltip 把完整这一行显示出来。
                Text(truncated(text)).help(text)
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
                    AppActions.shared.openOnboarding?()
                }
            }
        }
    }

    private func truncated(_ text: String) -> String {
        let maxChars = settings.menuBarLyricsMaxChars
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "…"
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
        // 桌面悬浮歌词、灵动岛歌词互不排斥,菜单里各自的开关独立显示——只在 settings 里
        // 对应开关确实开着时才显示/构造那个控制器:两个控制器都是 `static let shared`,
        // 真正引用到才会执行 init() 建窗口,而 init() 里订阅 PlaybackCoordinator 的
        // Combine sink 在订阅瞬间就会用当下的 isVisible(默认 true)触发一次
        // orderFront——如果不管设置开没开都无条件持有两份 @ObservedObject,点开一次
        // 菜单就会把没启用的那个控制器也构造出来、连带显示窗口。SwiftUI 的 if 只会构建
        // 条件为真的那个分支,条件为假的分支连初始化都不会跑,借这个机制保证不会误碰
        // 不该碰的控制器(详见 NotchLyricsWindowController 顶部注释)。
        if settings.classicOverlayEnabled {
            ClassicOverlayMenuSection()
        }
        if settings.notchOverlayEnabled {
            NotchOverlayMenuSection()
        }
        // 跟悬浮窗样式(经典/灵动岛)正交——校准的是"当前这首歌的歌词该提前/延后多少",
        // 不管哪种样式在显示都适用,所以不放进上面两个按样式互斥的 Section 里,单独一份。
        LyricsOffsetMenuSection()
        Divider()
        Toggle(isOn: $settings.launchAtLoginEnabled) {
            Label(L10n.t("开机启动"), systemImage: "power")
        }
        // 单独一条分隔线,把"开机启动"这个持久状态开关跟下面几个"点一下跳转/触发一次性
        // 动作"的按钮分开——参考同类菜单栏工具(Bartender/AlDente 这类)常见的"开关一组、
        // 操作入口另一组"分区习惯,原来两者混在一起没有区分。
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
        // 跟"歌词管理…"同一个坑、同一个解法——正经的标题栏窗口,展示完整歌词并跟随
        // 播放自动滚动,见 UI/LyricsWindowView.swift。
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
            Label(L10n.t("检查更新"), systemImage: "arrow.triangle.2.circlepath")
        }
        // 跟"设置…"同一个坑,同一个解法:先激活 App 再打开——直接跳到设置窗口的
        // "关于"分类,复用 Onboarding 的 Last.fm 步骤已经在用的同一套一次性信箱
        // (AppActions.pendingSettingsSelection,见该文件注释),不用再点一次侧边栏。
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

// 经典悬浮窗样式生效时的菜单项——"显示悬浮歌词"+"锁定位置"。只在这个子 View 里持有
// LyricsOverlayWindowController.shared,不放在 MenuBarMenu 本体上:MenuBarMenu.body
// 的 if/else 只会构建被选中分支对应的 View,把控制器引用限制在这个分支专属的小
// View 里,才能保证灵动岛样式生效时永远不会误触构造经典控制器。
private struct ClassicOverlayMenuSection: View {
    @ObservedObject private var overlay = LyricsOverlayWindowController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { overlay.isVisible },
            set: { overlay.setVisible($0) }
        )) {
            Label(L10n.t("显示桌面悬浮歌词"), systemImage: "captions.bubble")
        }
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

// 灵动岛样式生效时的菜单项——只有"显示悬浮歌词"一项:灵动岛的位置是算出来的、贴死
// 在屏幕顶部,没有"锁定位置"这个概念(见 NotchLyricsWindow 里
// isMovableByWindowBackground = false 那段注释)。同理只在这个子 View 里持有
// NotchLyricsWindowController.shared,理由跟 ClassicOverlayMenuSection 对称。
private struct NotchOverlayMenuSection: View {
    @ObservedObject private var overlay = NotchLyricsWindowController.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { overlay.isVisible },
            set: { overlay.setVisible($0) }
        )) {
            Label(L10n.t("显示灵动岛歌词"), systemImage: "rectangle.topthird.inset.filled")
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
