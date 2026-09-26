import AppKit

/// 让这个 App 在**后台**时设的光标生效。
///
/// macOS 只认前台 App 的 `NSCursor.set()`;Lyrimuse 是 LSUIElement、悬浮歌词窗不激活 App,所以指针
/// 停在窗口上时光标一直归下层那个前台 App 管。CoreGraphics 的私有连接属性 `SetsCursorInBackground`
/// 打开之后,本进程设的光标在后台也生效。符号运行时查找:哪天系统拿掉了,`setEnabled` 什么也不做,
/// 只是光标不变,不影响别的。
///
/// 只在确实要换光标的那段时间打开(悬浮歌词「调整宽度」模式下指针在可拖的边上),用完关掉。
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

    private static var enabled = false

    static func setEnabled(_ on: Bool) {
        guard on != enabled, let (mainConnection, setProperty) = functions else { return }
        enabled = on
        let cid = mainConnection()
        _ = setProperty(cid, cid, "SetsCursorInBackground" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
