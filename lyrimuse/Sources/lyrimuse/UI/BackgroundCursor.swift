import AppKit

/// 让这个 App 在**后台**时设的光标生效。
///
/// macOS 只认前台 App 的 `NSCursor.set()`;Lyrimuse 是 LSUIElement、悬浮歌词窗和灵动岛都不激活 App,所以
/// 指针停在窗口上时光标一直归下层那个前台 App 管。CoreGraphics 的私有连接属性 `SetsCursorInBackground`
/// 打开之后,本进程设的光标在后台也生效。符号运行时查找:哪天系统拿掉了,`setEnabled` 什么也不做,
/// 只是光标不变,不影响别的。
///
/// 只在确实要换光标的那段时间打开(悬浮歌词「调整宽度」模式下指针在可拖的边上、指针在灵动岛卡片上),用完关掉。
/// 开关按持有方记:几处的开着时段可能交叠(从悬浮歌词的边上直接移到灵动岛上),最后一个持有方放手才真的关。
@MainActor
enum BackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let functions: (MainConnectionID, SetConnectionProperty)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID"),
              let set = dlsym(handle, "CGSSetConnectionProperty") else { return nil }
        return (unsafeBitCast(main, to: MainConnectionID.self), unsafeBitCast(set, to: SetConnectionProperty.self))
    }()

    private static var holders: Set<ObjectIdentifier> = []

    static func setEnabled(_ on: Bool, for owner: ObjectIdentifier) {
        let wasOn = !holders.isEmpty
        if on { holders.insert(owner) } else { holders.remove(owner) }
        let isOn = !holders.isEmpty
        guard isOn != wasOn, let (mainConnection, setProperty) = functions else { return }
        let cid = mainConnection()
        _ = setProperty(cid, cid, "SetsCursorInBackground" as CFString, isOn ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
