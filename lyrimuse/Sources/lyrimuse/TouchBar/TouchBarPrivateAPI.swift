import AppKit
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "touchbar")

/// 触控栏的系统级入口:功能栏(Control Strip)里那枚图标,和轻点它之后盖住整条触控栏的系统模态条。
/// 两样都只有私有接口:公开的 `NSApp.touchBar` 只在本 App 处于前台时显示,而菜单栏 App 平时不在前台。
/// 用的是 `NSTouchBarItem` / `NSTouchBar` 上的四个类方法,加 DFRFoundation 里的两个 C 函数(LyricsX、MTMR、
/// Pock 用的也是这一套)。
///
/// 符号运行时查找(同 `BackgroundCursor`)。六个缺任何一个就整体不可用:`isAvailable` 为 false,各入口什么都不做,
/// 日志里点名缺的是哪几个;设置页「触控栏」那一段据此提示开关不会生效。「展开时隐藏功能栏」和 App 自己的收起键
/// 另要两个类方法,单独查(`supportsHidingControlStrip`),缺了只是这两样没有。
@MainActor
enum TouchBarPrivateAPI {
    private typealias ClassMethod1 = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias ClassMethod2 = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
    private typealias PresentPlaced = @convention(c) (AnyObject, Selector, AnyObject, Int64, AnyObject) -> Void
    private typealias SetPresence = @convention(c) (NSString, Bool) -> Void
    private typealias SetFlag = @convention(c) (Bool) -> Void
    private typealias GetMainTouchBar = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias WantsEscOverrides = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias StatusChangeHandler = @convention(block) () -> Void
    private typealias RegisterStatusChange = @convention(c) (StatusChangeHandler) -> Void

    /// 一个类方法的选择子和实现。
    private struct ClassCall<F> {
        let selector: Selector
        let call: F
    }

    private struct Entries {
        /// `+[NSTouchBarItem addSystemTrayItem:]` / `removeSystemTrayItem:`:登记 / 注销功能栏里的一项。
        let addTrayItem: ClassCall<ClassMethod1>
        let removeTrayItem: ClassCall<ClassMethod1>
        /// `DFRElementSetControlStripPresenceForIdentifier(identifier, present)`:登记过的那一项露不露面。
        let setPresence: SetPresence
        /// `+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]` / `dismissSystemModalTouchBar:`。
        let presentModal: ClassCall<ClassMethod2>
        let dismissModal: ClassCall<ClassMethod1>
        /// `DFRSystemModalShowsCloseBoxWhenFrontMost(flag)`:照名字是「本 App 在前台时,系统模态条左端也给收起的 ✕」。
        /// Xcode 触控栏模拟器上实测传 true / false、在什么时候传都一样:发起的 App 在前台时不给,转到后台就给。
        let setCloseBoxWhenFrontmost: SetFlag
    }

    private static let entries: Entries? = {
        var missing: [String] = []
        let framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)
        if framework == nil { missing.append("DFRFoundation") }
        func cFunction<F>(_ name: String, as type: F.Type) -> F? {
            guard let framework, let symbol = dlsym(framework, name) else {
                missing.append(name)
                return nil
            }
            return unsafeBitCast(symbol, to: type)
        }
        func classMethod<F>(_ cls: AnyClass, _ name: String, as type: F.Type) -> ClassCall<F>? {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(cls, selector) else {
                missing.append(name)
                return nil
            }
            return ClassCall(selector: selector, call: unsafeBitCast(method_getImplementation(method), to: type))
        }
        // 六个都先查一遍再判,缺几个就在日志里点名几个。
        let presence = cFunction("DFRElementSetControlStripPresenceForIdentifier", as: SetPresence.self)
        let closeBox = cFunction("DFRSystemModalShowsCloseBoxWhenFrontMost", as: SetFlag.self)
        let add = classMethod(NSTouchBarItem.self, "addSystemTrayItem:", as: ClassMethod1.self)
        let remove = classMethod(NSTouchBarItem.self, "removeSystemTrayItem:", as: ClassMethod1.self)
        let present = classMethod(NSTouchBar.self, "presentSystemModalTouchBar:systemTrayItemIdentifier:",
                                  as: ClassMethod2.self)
        let dismiss = classMethod(NSTouchBar.self, "dismissSystemModalTouchBar:", as: ClassMethod1.self)
        guard let presence, let closeBox, let add, let remove, let present, let dismiss else {
            logger.error("[TouchBarPrivateAPI] missing entry points: \(missing.joined(separator: ", "), privacy: .public)")
            return nil
        }
        return Entries(addTrayItem: add, removeTrayItem: remove, setPresence: presence,
                       presentModal: present, dismissModal: dismiss, setCloseBoxWhenFrontmost: closeBox)
    }()

    static var isAvailable: Bool { entries != nil }

    /// 「展开时隐藏功能栏」要的两个入口,跟上面那六个分开:缺了只是这一项不生效,照常展开。
    private struct FullWidthEntries {
        /// `+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`:placement 传 1 时展开条占满
        /// 整条触控栏,功能栏和系统左端的 ✕ 一起收起;传 0 跟不带这个参数的那一个一样(Xcode 触控栏模拟器实测)。
        let presentPlaced: ClassCall<PresentPlaced>
        /// `+[NSTouchBar minimizeSystemModalTouchBar:]`:收回成功能栏里那一项,同系统的 ✕。两种展开方式都管用
        /// (不占满整条时也是,模拟器实测)。
        let minimize: ClassCall<ClassMethod1>
    }

    /// 占满整条触控栏的那个 placement。
    private static let fullWidthPlacement: Int64 = 1

    private static let fullWidthEntries: FullWidthEntries? = {
        let presentSelector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        let minimizeSelector = NSSelectorFromString("minimizeSystemModalTouchBar:")
        guard let present = class_getClassMethod(NSTouchBar.self, presentSelector),
              let minimize = class_getClassMethod(NSTouchBar.self, minimizeSelector)
        else {
            logger.error("[TouchBarPrivateAPI] missing full-width entry points")
            return nil
        }
        return FullWidthEntries(
            presentPlaced: ClassCall(selector: presentSelector,
                                     call: unsafeBitCast(method_getImplementation(present), to: PresentPlaced.self)),
            minimize: ClassCall(selector: minimizeSelector,
                                call: unsafeBitCast(method_getImplementation(minimize), to: ClassMethod1.self)))
    }()

    /// 能不能「展开时隐藏功能栏」、放 App 自己的收起键(收起靠 `minimizeSystemModalTouchBar:`):那两个入口在、
    /// 常规的六个也在。
    static var supportsHidingControlStrip: Bool { entries != nil && fullWidthEntries != nil }

    /// 查「这台 Mac 此刻有没有触控栏」的两个入口,跟上面那六个分开:缺了它们只是判不了(`TouchBarPresence`
    /// 退回只看 ControlStrip),不影响展开歌词。
    private struct PresenceEntries {
        /// `DFRTouchBarGetMain()`:系统此刻的主触控栏,没有时 NULL(Xcode 模拟器关着时也是 NULL)。
        let getMainTouchBar: GetMainTouchBar
        /// `DFRRegisterStatusChangeCallback(block)`:触控栏出现 / 消失时在框架自己的队列里调这个 block。
        /// block 带的参数不用,被调到时重新查一遍。
        let registerStatusChange: RegisterStatusChange
    }

    private static let presenceEntries: PresenceEntries? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
              let getMain = dlsym(framework, "DFRTouchBarGetMain"),
              let register = dlsym(framework, "DFRRegisterStatusChangeCallback")
        else {
            logger.error("[TouchBarPrivateAPI] missing touch bar presence entry points")
            return nil
        }
        return PresenceEntries(getMainTouchBar: unsafeBitCast(getMain, to: GetMainTouchBar.self),
                               registerStatusChange: unsafeBitCast(register, to: RegisterStatusChange.self))
    }()

    /// 系统报告的主触控栏此刻在不在;查不了时 nil。它要连 TouchBarServer(按需启动的守护进程),只在系统的
    /// ControlStrip 在跑时调(见 `TouchBarPresence`)。
    static func touchBarReported() -> Bool? {
        guard let e = presenceEntries else { return nil }
        return e.getMainTouchBar() != nil
    }

    /// `DFRTouchBarWantsEscOverrides(touchBar)`:这块触控栏左端有没有一颗能让 App 换掉的虚拟 Esc 键。跟上面几组分开查,
    /// 缺了只是不补 esc 键(`TouchBarEscapeKey`)。
    private static let wantsEscOverrides: WantsEscOverrides? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
              let symbol = dlsym(framework, "DFRTouchBarWantsEscOverrides")
        else {
            logger.error("[TouchBarPrivateAPI] missing escape key entry point")
            return nil
        }
        return unsafeBitCast(symbol, to: WantsEscOverrides.self)
    }()

    /// 系统此刻的主触控栏左端是不是一颗虚拟 Esc 键(1st generation 是,2nd generation 是实体键);查不了时 nil。
    /// 框架里就是「触控栏样式 ≠ 3」:1st generation 样式 2、2nd generation 样式 3(见 17 章决策 36)。同
    /// `touchBarReported`,只在 ControlStrip 在跑时调。
    static func touchBarHasEscapeKey() -> Bool? {
        guard let e = presenceEntries, let wants = wantsEscOverrides, let main = e.getMainTouchBar() else { return nil }
        return wants(main)
    }

    /// 注册触控栏出现 / 消失的回调,`handler` 在框架自己的队列里被调。注册不了时返回 false。
    /// 同样只在 ControlStrip 在跑时调;注册一次管整个进程。
    static func registerStatusChange(_ handler: @escaping @Sendable () -> Void) -> Bool {
        guard let e = presenceEntries else { return false }
        let block: StatusChangeHandler = { handler() }
        e.registerStatusChange(block)
        return true
    }

    /// 这一项进 / 出功能栏。进:先登记再露面;出:先藏起再注销。
    static func setInControlStrip(_ item: NSTouchBarItem, _ present: Bool) {
        guard let e = entries else { return }
        let identifier = item.identifier.rawValue as NSString
        if present {
            e.addTrayItem.call(NSTouchBarItem.self as AnyObject, e.addTrayItem.selector, item)
            e.setPresence(identifier, true)
        } else {
            e.setPresence(identifier, false)
            e.removeTrayItem.call(NSTouchBarItem.self as AnyObject, e.removeTrayItem.selector, item)
        }
        logger.notice("[TouchBarPrivateAPI.setInControlStrip] \(item.identifier.rawValue, privacy: .public) present=\(present)")
    }

    /// 已登记的那一项重新露一次面:先藏再露。占满整条的展开条收起后功能栏重新排,放歌时这一项那一格会给系统的
    /// 「正在播放」;重新露面的那一项排回去(17 章决策 42)。
    static func reassertInControlStrip(_ item: NSTouchBarItem) {
        guard let e = entries else { return }
        let identifier = item.identifier.rawValue as NSString
        e.setPresence(identifier, false)
        e.setPresence(identifier, true)
        logger.notice("[TouchBarPrivateAPI.reassertInControlStrip] \(item.identifier.rawValue, privacy: .public)")
    }

    /// 把 `bar` 当系统模态条展开,收起时缩回 `trayIdentifier` 那一项。不管哪个 App 在前台都显示。
    /// `hidingControlStrip` 为 true 时占满整条触控栏(功能栏和系统的 ✕ 一起收起,收起键要 App 自己给);
    /// 入口缺了就照常展开。
    static func presentSystemModal(_ bar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier,
                                   hidingControlStrip: Bool) {
        guard let e = entries else { return }
        if hidingControlStrip, let f = fullWidthEntries {
            f.presentPlaced.call(NSTouchBar.self as AnyObject, f.presentPlaced.selector, bar, fullWidthPlacement,
                                 trayIdentifier.rawValue as NSString)
            return
        }
        e.presentModal.call(NSTouchBar.self as AnyObject, e.presentModal.selector, bar,
                            trayIdentifier.rawValue as NSString)
    }

    /// 收回成功能栏里那一项(同系统的 ✕)。左端是 App 自己的收起键时用得到(隐藏功能栏、本 App 在前台,
    /// 见 `TouchBarSlot.showsCollapseKey`)。
    static func minimizeSystemModal(_ bar: NSTouchBar) {
        guard let f = fullWidthEntries else { return }
        f.minimize.call(NSTouchBar.self as AnyObject, f.minimize.selector, bar)
    }

    static func dismissSystemModal(_ bar: NSTouchBar) {
        guard let e = entries else { return }
        e.dismissModal.call(NSTouchBar.self as AnyObject, e.dismissModal.selector, bar)
    }

    static func showCloseBoxWhenFrontmost(_ shows: Bool) {
        entries?.setCloseBoxWhenFrontmost(shows)
    }
}
